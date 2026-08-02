#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# baton_watchdog.sh — 類型B（バトン喪失）検知デーモン (cmd_171/T3)
#
# 「未読合計0・稼働中タスク0・未完了cmdあり」が baton_lost_after_sec
# 継続した場合に将軍へ通知する。エージェントごとに1本起動される
# inbox_watcher.sh とは別に、単一インスタンスのグローバル watcher として
# scripts/watcher_supervisor.sh から起動される（9本の inbox_watcher に
# 同一の大域判定を持たせると9重通知になるため）。
#
# 【対処は通知のみ・絶対厳守】
# tmux 送信・タスク再割当・ファイル書き換えは一切行わない。
# 破壊的作用ゼロゆえ主の裁可を要さぬ、という設計上の根拠そのものである。
#
# 判定条件（3条件AND、baton_lost_after_sec 継続で発動）:
#   B-1: 全エージェントの未読合計が0   (queue/inbox/*.yaml の `read: false` 件数)
#   B-2: 稼働中のタスクが1件も無い     (queue/tasks/*.yaml の status: assigned/in_progress)
#   B-3: 未完了の cmd が存在する       (queue/shogun_to_karo.yaml の status != done)
#
# 読むのは queue/ 配下のファイルのみ。dashboard.md（二次データ）は見ない。
# tmux には一切触れない（テストで固定：TC-BATON-006）。
#
# 【通知経路（cmd_172・二重化）】
# 主経路: 将軍inbox（baton_watchdog_notify_shogun）。baton_lost_after_sec
#   （既定900秒）継続で無条件に発火する。ntfy_topic の設定有無に一切
#   依存しない（2026-07-29の事故 — ntfy_topic未設定によりntfy.shがexit 1
#   し、通知が誰にも届かなかった件の是正）。
# 副経路: ntfy（主のスマホ・branch_policy_notify）。より長い
#   baton_ntfy_after_sec（既定1800秒）継続で初めて試みる。失敗許容
#   （失敗してもログに残すのみ・将軍inbox通知には無関係）。
# 両経路は独立したガード変数・独立した閾値を持ち、一方が死んでも他方は
# 生きる。
#
# 【M-2是正・軍師発見】check_d1_once（D-1・配送機構死亡検知）にも同型の
# 二経路化を適用する（詳細はcheck_d1_once直前のコメントを参照）。
#
# 【periodic /clear (cmd_172/P7) — 同プロセスへの並存拡張】
# 上記B-1/B-2/B-3判定（check_once）とは完全に独立した別機能を同居させる。
# karo/軍師それぞれが「手隙」を periodic_clear_idle_sec 以上継続した場合に
# 限り、既存の clear_command 配送経路（inbox_write.sh → inbox_watcher.sh）
# へ1回だけ書き込み、文脈をリセットさせる。opt-in（既定 disabled）。
# 詳細は periodic_clear_* 関数群（check_once 定義の直前）を参照。
#
# 【B-4b: 無進捗検知 (cmd_179/T-B) — check_d1_once と同様の独立OR条件】
# 「バトンを保持したまま止まっている」（未読・稼働タスク数を問わず、
# 特定エージェントのtask/report/inbox一式が長時間無更新）を検知する。
# 詳細は check_b4b_once 直前のコメントを参照。
# ═══════════════════════════════════════════════════════════════

# ─── Testing guard ───
# __BATON_WATCHDOG_TESTING__=1 のときは関数定義のみ読み込み、
# 引数解釈・メインループを走らせない（inbox_watcher.sh と同じ様式）。
if [ "${__BATON_WATCHDOG_TESTING__:-}" != "1" ]; then
    set -euo pipefail
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# ROOT はテスト時にフィクスチャの queue/ を指すよう上書きできる。
ROOT="${BATON_WATCHDOG_ROOT:-$SCRIPT_DIR}"

source "$SCRIPT_DIR/lib/stall_policy.sh"
source "$SCRIPT_DIR/lib/branch_policy.sh"
source "$SCRIPT_DIR/lib/usage_limit.sh"
source "$SCRIPT_DIR/lib/agent_registry.sh"

# ─── プロセスローカル状態 ───
BATON_LOST_SINCE=0     # 3条件が揃い始めた epoch（揃っていなければ0）
BATON_NOTIFIED=0       # 将軍inbox通知を同一継続停止で二重送信しないためのガード
BATON_NTFY_NOTIFIED=0  # ntfy通知（cmd_172/急報）を同一継続停止で二重送信しないためのガード

# ─── 使用量監視 (cmd_181) プロセスローカル状態 ───
USAGE_LAST_CHECK_AT=0
declare -A USAGE_WARNED_WINDOW=()   # label -> 予告済み枠の reset epoch
declare -A USAGE_WARNED_AT=()       # label -> 予告を出した epoch
declare -A USAGE_RESUMED_WINDOW=()  # label -> 再開号令済み枠の reset epoch
declare -A USAGE_WARNED_FLAGGED=()  # label -> 予告時点のLIMITS_FLAGGED値（finding_3の契約変更検知に使用）

# ─── periodic /clear (cmd_172/P7) プロセスローカル状態 ───
# エージェントごとに独立（B-1/B-2/B-3の全体判定とは完全に並存する別機能）。
declare -A PERIODIC_CLEAR_IDLE_SINCE=()  # agent -> idle条件が揃い始めた epoch（0なら未計測）
declare -A PERIODIC_CLEAR_SENT=()        # agent -> 同一idle windowで送信済みか(1/0)

# queue/inbox/*.yaml の read:false 件数を数える。ただし
# from が agent_registry_agents()（正規エージェント一覧・shogun/karo/
# ashigaru1-7/gunshi）に含まれない行（＝番犬・inbox_watcher・
# watcher_supervisor等、機械の書き手からの発信。「誰かが保持しておるか」
# という問いにとって証拠でなくノイズ）は除外する（cmd_180/T-1・軍師検証1
# を起点に、cmd_187/SF-2・SF-3でdenylistからallowlistへ設計転換——
# 新しい機械の書き手が増えてもコード変更が要らぬ形にした）。
# from 欠落は除外せぬ（数える。安全側）。
# python/yaml が使えない場合は現行 grep 方式（除外なし）へフォールバックする。
# unread=0 に倒すと誤って baton_condition が真になり誤発火するため、
# フォールバックは「除外をやめる」方向にする（3-b。D-1側と倒す向きが逆）。
baton_watchdog_count_unread() {
    local python_bin unread allowed_agents
    python_bin="$(stall_policy_python)"
    allowed_agents="$(agent_registry_agents_joined ",")"

    if [ -n "$python_bin" ] && unread=$("$python_bin" - "$ROOT" "$allowed_agents" 2>/dev/null <<'PY'
import glob
import os
import sys

try:
    import yaml
except Exception:
    sys.exit(1)

root = sys.argv[1]
# allowlist: 正規エージェント一覧（agent_registry_agents()）に含まれる
# 送信者だけを「保持・応答しうる主体からの発信」として数える。
# denylist（機械の書き手名を列挙して除外）ではなく allowlist を採る理由は
# PR本文・タスクYAML（cmd_187）を参照——新しい機械の書き手が増えても
# コード変更が要らない。fromが欠落したメッセージは安全側（除外せぬ）とする。
ALLOWED = set(a for a in sys.argv[2].split(",") if a) if len(sys.argv) > 2 else set()

total = 0
for path in glob.glob(os.path.join(root, "queue", "inbox", "*.yaml")):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = yaml.safe_load(fh) or {}
    except Exception:
        continue
    if not isinstance(data, dict):
        continue
    messages = data.get("messages")
    if not isinstance(messages, list):
        continue
    for msg in messages:
        if not isinstance(msg, dict):
            continue
        if msg.get("read") is not False:
            continue
        sender = msg.get("from")
        if sender is not None and sender not in ALLOWED:
            continue
        total += 1

print(total)
PY
    ) && [[ "$unread" =~ ^[0-9]+$ ]]; then
        echo "$unread"
        return 0
    fi

    local total=0 f n
    for f in "$ROOT"/queue/inbox/*.yaml; do
        [ -f "$f" ] || continue
        n=$(grep -c 'read: false' "$f" 2>/dev/null || true)
        total=$((total + ${n:-0}))
    done
    echo "$total"
}

baton_watchdog_count_active_tasks() {
    local active=0 agent
    while IFS= read -r agent; do
        [ -n "$agent" ] || continue
        if baton_watchdog_agent_holds_baton "$agent"; then
            active=$((active + 1))
        fi
    done < <(baton_watchdog_list_agents)
    echo "$active"
}

# shogun_to_karo.yaml の commands のうち status != done の件数。
# ファイル欠損・壊れた YAML でも 0 を返し、決して非0で落ちない
# （TC-BATON-008: cmd_163 BL-3 と同じ「安全な既定値」教訓の再適用）。
baton_watchdog_count_open_cmds() {
    local python_bin
    python_bin="$(stall_policy_python)"
    "$python_bin" - "$ROOT/queue/shogun_to_karo.yaml" <<'PY'
import sys

try:
    import yaml
except Exception:
    print(0)
    raise SystemExit(0)

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = yaml.safe_load(fh) or {}
except Exception:
    data = {}

if not isinstance(data, dict):
    data = {}

cmds = data.get("commands")
if cmds is None:
    cmds = data.get("cmds")
if isinstance(cmds, dict):
    cmds = list(cmds.values())
if not isinstance(cmds, list):
    cmds = []

print(sum(1 for c in cmds if isinstance(c, dict) and c.get("status") != "done"))
PY
}

# ═══════════════════════════════════════════════════════════════
# periodic /clear (cmd_172/P7) — karo/軍師の定期文脈切断
#
# 既存のB-1/B-2/B-3判定（check_once）とは完全に独立した別機能。
# 「手隙が長時間続いた」ことを検知して clear_command を1回だけ書き込む。
# tmux には一切触れない（inbox_write.sh はファイル書き込みのみ）。
# periodic_clear_enabled=false（既定）なら常に no-op。
# ═══════════════════════════════════════════════════════════════

periodic_clear_count_unread() {
    local file="$1" n
    if [ -f "$file" ]; then
        n=$(grep -c 'read: false' "$file" 2>/dev/null || true)
    else
        n=0
    fi
    echo "${n:-0}"
}

# karo の安全判定用: ashigaru*.yaml と gunshi.yaml のうち
# assigned/in_progress が1件でもあれば非0を返す。
periodic_clear_count_active_ashigaru_gunshi() {
    local active=0 f
    for f in "$ROOT"/queue/tasks/ashigaru*.yaml "$ROOT"/queue/tasks/gunshi.yaml; do
        [ -f "$f" ] || continue
        if grep -qE '^  status: (assigned|in_progress)' "$f" 2>/dev/null; then
            active=$((active + 1))
        fi
    done
    echo "$active"
}

# karo の安全判定用: shogun_to_karo.yaml の commands のうち
# status: in_progress の件数（baton_watchdog_count_open_cmds は != done で
# 別目的のため流用しない）。ファイル欠損・壊れたYAMLでも0を返す。
periodic_clear_count_in_progress_cmds() {
    local python_bin
    python_bin="$(stall_policy_python)"
    "$python_bin" - "$ROOT/queue/shogun_to_karo.yaml" <<'PY'
import sys

try:
    import yaml
except Exception:
    print(0)
    raise SystemExit(0)

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = yaml.safe_load(fh) or {}
except Exception:
    data = {}

if not isinstance(data, dict):
    data = {}

cmds = data.get("commands")
if cmds is None:
    cmds = data.get("cmds")
if isinstance(cmds, dict):
    cmds = list(cmds.values())
if not isinstance(cmds, list):
    cmds = []

print(sum(1 for c in cmds if isinstance(c, dict) and c.get("status") == "in_progress"))
PY
}

# agent(karo|gunshi) を1つ受け取り、「今すぐ/clearしてよい」条件を真偽で返す。
# instructions/karo.md の既存「Karo Self-/clear」節（未読0・assigned/in_progress
# タスクなし・in_progress cmdなし）と同じ考え方をkaro/軍師それぞれに適用する。
periodic_clear_agent_idle() {
    local agent="$1"
    local unread
    unread=$(periodic_clear_count_unread "$ROOT/queue/inbox/${agent}.yaml")
    [ "${unread:-0}" -eq 0 ] || return 1

    case "$agent" in
        karo)
            local active in_progress
            active=$(periodic_clear_count_active_ashigaru_gunshi)
            [ "${active:-0}" -eq 0 ] || return 1
            in_progress=$(periodic_clear_count_in_progress_cmds)
            [ "${in_progress:-0}" -eq 0 ] || return 1
            ;;
        gunshi)
            local f="$ROOT/queue/tasks/gunshi.yaml"
            if [ -f "$f" ] && grep -qE '^  status: (assigned|in_progress)' "$f" 2>/dev/null; then
                return 1
            fi
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

# 1回だけ判定する。check_once の直後（メインループ・--once どちらからも）
# 毎サイクル呼ばれる。periodic_clear_enabled=false なら即座に何もしない。
periodic_clear_check_once() {
    if [ "$(baton_watchdog_query periodic_clear_enabled)" != "true" ]; then
        return 0
    fi

    local now threshold agent agents_raw
    now=$(date +%s)
    threshold=$(baton_watchdog_query periodic_clear_idle_sec)
    agents_raw=$(baton_watchdog_query periodic_clear_agents)

    while IFS= read -r agent; do
        [ -n "$agent" ] || continue
        if periodic_clear_agent_idle "$agent"; then
            if [ "${PERIODIC_CLEAR_IDLE_SINCE[$agent]:-0}" -eq 0 ]; then
                PERIODIC_CLEAR_IDLE_SINCE[$agent]=$now
            fi
            if [ $(( now - PERIODIC_CLEAR_IDLE_SINCE[$agent] )) -ge "$threshold" ] \
                && [ "${PERIODIC_CLEAR_SENT[$agent]:-0}" -eq 0 ]; then
                bash "$ROOT/scripts/inbox_write.sh" "$agent" "定期メンテナンスによる文脈整理" clear_command baton_watchdog
                PERIODIC_CLEAR_SENT[$agent]=1
            fi
        else
            # 条件が崩れた＝busyになった・新規タスク・未読発生。
            # 次のidle windowで再送可能にするため状態をリセットする
            # （BATON_NOTIFIEDのリセットと同じ考え方）。
            PERIODIC_CLEAR_IDLE_SINCE[$agent]=0
            PERIODIC_CLEAR_SENT[$agent]=0
        fi
    done <<< "$agents_raw"
}

# 将軍inboxへの通知（主経路）。ntfy_topic の設定有無・ntfy 到達可否には
# 一切依存しない。ファイル書き込みのみ・tmux不使用（既存の不変条件のまま）。
baton_watchdog_notify_shogun() {
    local message="$1"
    baton_watchdog_notify_inbox shogun "$message"
}

# 任意の宛先へ番犬警報を書く（cmd_180/T-3・T-4）。「番犬は、停滞を診断
# した当人のinboxへ通知を書いてはならない」という原則（軍師
# principle_never_write_to_the_diagnosed）の実装土台。自らの通知が
# 対象自身の新たな未読になり、条件が崩れず通知ガードが永久に1のまま
# 張り付く（一度吠えたきり永久に黙る）ことを構造的に防ぐ。
baton_watchdog_notify_inbox() {
    local target="$1" message="$2"
    bash "$ROOT/scripts/inbox_write.sh" "$target" "$message" baton_alert baton_watchdog
}

# 1回だけ判定する。メインループ・--once どちらからも呼ばれる。
check_once() {
    local now unread active open_cmds condition
    local shogun_threshold ntfy_threshold elapsed

    if [ "$(baton_watchdog_query enabled)" != "true" ]; then
        return 0
    fi

    now=$(date +%s)
    unread=$(baton_watchdog_count_unread)
    active=$(baton_watchdog_count_active_tasks)
    open_cmds=$(baton_watchdog_count_open_cmds)

    if [ "${unread:-0}" -eq 0 ] && [ "${active:-0}" -eq 0 ] && [ "${open_cmds:-0}" -gt 0 ]; then
        condition=true

        if [ "$BATON_LOST_SINCE" -eq 0 ]; then
            BATON_LOST_SINCE=$now
        fi
        elapsed=$((now - BATON_LOST_SINCE))

        # 主経路: 将軍inbox通知。900秒(既定)継続で無条件に発火する。
        # ntfy_topic の設定有無やntfy到達可否には一切影響されない。
        shogun_threshold=$(baton_watchdog_query baton_lost_after_sec)
        if [ "$elapsed" -ge "$shogun_threshold" ] && [ "$BATON_NOTIFIED" -eq 0 ]; then
            baton_watchdog_notify_shogun "baton_lost: unread=0 active=0 open_cmds=${open_cmds} (${shogun_threshold}s+継続)"
            BATON_NOTIFIED=1
        fi

        # 副経路: ntfy（主のスマホ）。長引いた場合のみ・独立した閾値
        # (既定1800秒)。失敗許容 — 失敗してもログに残すのみで将軍inbox
        # 通知には一切影響させない。
        ntfy_threshold=$(baton_watchdog_query baton_ntfy_after_sec)
        if [ "$elapsed" -ge "$ntfy_threshold" ] && [ "$BATON_NTFY_NOTIFIED" -eq 0 ]; then
            if ! branch_policy_notify "baton_lost: unread=0 active=0 open_cmds=${open_cmds} (${ntfy_threshold}s+継続・ntfy)"; then
                echo "[$(date)] [baton_watchdog] ntfy notify failed (branch_policy_notify non-zero); shogun inbox notification unaffected" >&2
            fi
            BATON_NTFY_NOTIFIED=1
        fi
    else
        condition=false
        # 条件が崩れた＝バトンは持たれている。両トラッカーをリセットし、
        # 次に条件が揃った際は新たな継続として独立して計測し直す。
        BATON_LOST_SINCE=0
        BATON_NOTIFIED=0
        BATON_NTFY_NOTIFIED=0
    fi

    echo "[$(date)] [baton_watchdog/check_once] unread=${unread} active=${active} open_cmds=${open_cmds} baton_condition=${condition}"
}

# ═══════════════════════════════════════════════════════════════
# D-1: 配送機構死亡検知（既存B-1〜B-3とは独立したOR条件）(cmd_171/FU-1)
#
# PR #14（cmd_172）のQCで判明: B-1〜B-3は「配送機構（watcher群）自体が
# 死ぬ」形の停止を検知できない。watcher群が死ねば nudge が届かず未読が
# 溜まる一方であり、B-1（未読合計0）が常に偽になってしまうため。
#
# D-1はこれを補う独立したOR条件: read:false のまま
# BATON_D1_STALE_AFTER_SEC 秒以上放置されたメッセージを持つ inbox が
# 1件でもあり、**かつ**その agent の inbox_watcher.sh プロセスが
# 生きていなければ、「配送が停止している」とみなし即座に通知する
# （軍師QC §SC-5・PR #16再QC分）。
#
# watcher が生きたまま未読が滞留するのは、当該 agent が長い turn を
# 回している間の正常な滞留でありうる（send_wakeup は busy 中 nudge を
# スキップするため）。それを「配送死亡」と誤検知しないよう、
# プロセス生存確認を AND 条件として要求する。pgrep はプロセス確認で
# あり tmux ではないため、通知のみ・裁可を要さぬという性質は保たれる。
#
# メッセージ自身の timestamp が既に停止の継続時間を表しているため、
# 主経路（将軍inbox）の発火判定にB-1〜B-3のような別途の継続時間計測
# （BATON_LOST_SINCE相当）は不要である。
#
# 既存の check_once()（B-1〜B-3判定）の内部は一切変更しない。
#
# 【M-2是正・軍師発見】develop統合後、check_d1_once は branch_policy_notify
# （ntfy）を直接・単独で呼ぶ作りのままだった。これはcheck_once是正前の
# 「通知経路がntfy一本」構造そのものであり、ntfy_topic未設定時に同型の
# 事故を再現しかねない。check_onceと同じ二経路化パターンをここにも適用:
#   主経路: baton_watchdog_notify_shogun。既存どおりBATON_D1_STALE_AFTER_SEC
#     （600秒）分stale化したメッセージの検知＝継続の証拠とし、追加の待機を
#     挟まず無条件・即座に発火する（既存の即時発火という設計判断を維持）。
#   副経路: ntfy。D-1は「配送機構自体の死亡」＝既存のB-1〜B-3より緊急度が
#     高い検知であるため、check_once用のbaton_ntfy_after_sec（既定1800秒）
#     をそのまま流用するのは緊急度に見合わないと判断し、より短い専用閾値
#     baton_d1_ntfy_after_sec（既定900秒）を新設する。この閾値は
#     「dead_stale_count>0の状態が観測され始めてからの継続時間」で計測する
#     （BATON_D1_CONDITION_SINCE。check_onceのBATON_LOST_SINCEと同型）。
# ═══════════════════════════════════════════════════════════════
BATON_D1_STALE_AFTER_SEC=600     # 10分。既存baton_lost_after_secとは独立した固定値
BATON_D1_NOTIFIED=0              # 主経路（将軍inbox）の二重通知防止ガード
BATON_D1_CONDITION_SINCE=0       # dead_stale_count>0 になり始めたepoch（0なら未計測）
BATON_D1_NTFY_NOTIFIED=0         # 副経路（ntfy）の二重通知防止ガード

# queue/inbox/*.yaml のうち、read: false かつ timestamp が
# threshold 秒以上前のメッセージを1件以上含む inbox の
# agent名（ファイル名から拡張子を除いたもの）を、1行1件で標準出力へ返す。
# naive（tzinfo無し）timestamp は「ローカル時刻」として解釈する
# （書き手 scripts/inbox_write.sh:46 は `date "+%Y-%m-%dT%H:%M:%S"` で
#   ローカル時刻・オフセット表記なしのnaive文字列を書くため）。
# 読むのは queue/inbox/*.yaml のみ。tmux には一切触れない（TC-D1-005）。
#
# 第2・第3引数（省略可・cmd_189）: 呼び出し側が対象を名指しした場合に
# 限り、その対象の inbox でのみ機械由来（agent_registry_agentsに非該当の
# from）の未読を別扱いにできる。
#   exempt_agents_csv        : この対象名リストに含まれる agent のみ
#                               機械由来を通常閾値と別に扱う（CSV）
#   machine_stale_after_sec  : 機械由来に適用する専用閾値。0なら
#                               「機械由来は永久にstaleと数えぬ」
# 省略時（第2・第3引数なし）は現行と完全に同一の挙動——全 from を
# threshold のみで判定する。D-1（check_d1_once）はこの省略形のまま
# 呼び出し、一文字も変えない。
baton_watchdog_list_stale_inbox_agents() {
    local threshold="${1:-$BATON_D1_STALE_AFTER_SEC}"
    local exempt_agents_csv="${2:-}"
    local machine_stale_after_sec="${3:-}"
    local python_bin allowed_agents
    python_bin="$(stall_policy_python)"
    allowed_agents="$(agent_registry_agents_joined ",")"
    "$python_bin" - "$ROOT" "$threshold" "$exempt_agents_csv" "$machine_stale_after_sec" "$allowed_agents" <<'PY'
import glob
import os
import sys
from datetime import datetime, timezone

root, threshold = sys.argv[1], int(sys.argv[2])
EXEMPT = set(a for a in sys.argv[3].split(",") if a)
MACHINE_THRESHOLD = int(sys.argv[4]) if sys.argv[4] != "" else None
ALLOWED = set(a for a in sys.argv[5].split(",") if a)
# この関数は count_unread とは異なり、既定では allowlist フィルタを
# 適用しない（cmd_187/QC45-F1是正）。count_unread が問うのは「誰かが
# バトンを保持しておるか」——機械の書き込みは保持の証拠ではないため除外が
# 正しい。list_stale_inbox_agents が問うのは「この inbox は読まれずに
# 滞留しておるか」——この問いにとって書き手が誰かは無関係。機械が
# 書いた auto-recovery 通知も、当人が読むべき未読である。
# 【cmd_189】ただし呼び出し側（B-4c）が対象を名指しした場合に限り、
# その対象についてのみ機械由来の未読を専用閾値（またはstaleと数えぬ）で
# 別扱いできる。D-1は名指しせぬためこの分岐に入らず、従来どおり全fromを
# threshold のみで判定する。
#
# ── 未読を数える3関数の問いと規律（対応表） ──────────────
#   関数                              | 問い                      | 機械書き手
#   baton_watchdog_count_unread       | 誰かがバトンを保持中か      | 除外する
#   baton_watchdog_list_stale_inbox_agents | inboxが滞留しているか  | 既定は除外しない。
#                                       呼び出し側が対象を名指しした場合のみ、
#                                       その対象について機械由来を別閾値で扱う
#   periodic_clear_count_unread       | inboxに未読が残っているか  | 除外しない
# D-1（check_d1_once）は名指ししない: 配送機構死亡の問いにとって書き手は
#   無関係、かつ watcher死亡というAND条件が偽陽性を潰すため変更不要。
# B-4c（check_b4c_once）は将軍を名指しする: 「読んでおらぬか」という問い
#   にとって、主ご不在中の将軍が機械由来の通知を読まぬのは正常であるため。
# ─────────────────────────────────────────────────────

try:
    import yaml
except Exception:
    raise SystemExit(0)


def parse_ts(value):
    if not isinstance(value, str):
        return None
    s = value.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(s)
    except Exception:
        return None
    if dt.tzinfo is None:
        # naive はローカル時刻として書かれている（inbox_write.sh:46）。
        # astimezone() は naive をシステムのローカルタイムゾーンとみなして aware 化する。
        dt = dt.astimezone()
    return dt.astimezone(timezone.utc)


now = datetime.now(timezone.utc)
for path in glob.glob(os.path.join(root, "queue", "inbox", "*.yaml")):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = yaml.safe_load(fh) or {}
    except Exception:
        continue
    if not isinstance(data, dict):
        continue
    messages = data.get("messages")
    if not isinstance(messages, list):
        continue
    agent_name = os.path.splitext(os.path.basename(path))[0]
    agent_is_exempt = agent_name in EXEMPT
    stale_here = False
    for msg in messages:
        if not isinstance(msg, dict):
            continue
        if msg.get("read") is not False:
            continue
        dt = parse_ts(msg.get("timestamp"))
        if dt is None:
            continue
        elapsed = (now - dt).total_seconds()
        sender = msg.get("from")
        # from欠落は「機械ではない」＝通常閾値で判定する（安全側。
        # baton_watchdog_count_unread がfrom欠落を除外せぬのと同じ
        # 向きに揃える。倒す向きを二つの関数で違えてはならぬ）。
        if agent_is_exempt and sender is not None and sender not in ALLOWED:
            if MACHINE_THRESHOLD is None:
                # 呼び出し側が第3引数を省略＝現行どおりthresholdで判定
                is_stale = elapsed >= threshold
            elif MACHINE_THRESHOLD == 0:
                is_stale = False
            else:
                is_stale = elapsed >= MACHINE_THRESHOLD
        else:
            is_stale = elapsed >= threshold
        if is_stale:
            stale_here = True
            break
    if stale_here:
        print(agent_name)
PY
}

# agent の inbox_watcher.sh が生きていれば真を返す。
# watcher_supervisor.sh の重複起動防止判定と同一パターンを用いる
# （末尾スペースは ashigaru1 が ashigaru10 等に部分一致するのを防ぐ）。
baton_watchdog_watcher_alive() {
    local agent="$1"
    pgrep -f "scripts/inbox_watcher.sh ${agent} " >/dev/null 2>&1
}

# queue/inbox/*.yaml が存在するエージェント名を1行1件で返す
# （ファイル名から拡張子を除いたもの）。karo/shogunを含む点で
# baton_watchdog_list_agents（queue/tasks/*.yaml ベース。B-4b専用）とは
# 別物であり、混ぜてはならない（B-4bがtask YAMLを持たぬkaro/shogunを
# 拾おうとして崩れる。軍師検証2 q3）。B-4c対象列挙・
# WATCHER_ALIVE_SNAPSHOT更新対象列挙の双方で使う。
baton_watchdog_list_inbox_agents() {
    local f
    for f in "$ROOT"/queue/inbox/*.yaml; do
        [ -f "$f" ] || continue
        basename "$f" .yaml
    done
}

# ─── watcher生死スナップショット（cmd_180/T-2） ───
# D-1・B-4cが別々のタイミングでpgrepを叩くと、その間にwatcher_supervisorが
# 死んだwatcherを再起動した場合、両方が発火し得る（軍師検証2・是正1）。
# サイクル冒頭（メインループ・--once分岐の先頭、check_onceより前）で
# 生死を1度だけ測り凍結することで、同一サイクル内ではD-1・B-4cが必ず
# 同じ値を参照するようにする。
declare -A WATCHER_ALIVE_SNAPSHOT=()

baton_watchdog_refresh_watcher_snapshot() {
    local agent
    WATCHER_ALIVE_SNAPSHOT=()
    while IFS= read -r agent; do
        [ -n "$agent" ] || continue
        if baton_watchdog_watcher_alive "$agent"; then
            WATCHER_ALIVE_SNAPSHOT[$agent]=1
        else
            WATCHER_ALIVE_SNAPSHOT[$agent]=0
        fi
    done < <(baton_watchdog_list_inbox_agents)
}

# D-1を1回だけ判定する。check_once()（B-1〜B-3）とは完全に独立した関数であり、
# check_once() を呼ばない・その内部にも触れない。
#
# 条件はAND: (i) stale unread な inbox がある **かつ**
#            (ii) その agent の inbox_watcher.sh プロセスが生きていない
check_d1_once() {
    local agent dead_stale_count=0
    local now elapsed ntfy_threshold notify_target
    local -a dead_stale_agents=()

    if [ "$(baton_watchdog_query enabled)" != "true" ]; then
        return 0
    fi

    while IFS= read -r agent; do
        [ -n "$agent" ] || continue
        if [ "${WATCHER_ALIVE_SNAPSHOT[$agent]:-0}" -eq 0 ]; then
            dead_stale_count=$((dead_stale_count + 1))
            dead_stale_agents+=("$agent")
        fi
    done < <(baton_watchdog_list_stale_inbox_agents)

    if [ "$dead_stale_count" -gt 0 ]; then
        now=$(date +%s)
        if [ "$BATON_D1_CONDITION_SINCE" -eq 0 ]; then
            BATON_D1_CONDITION_SINCE=$now
        fi
        elapsed=$((now - BATON_D1_CONDITION_SINCE))

        # 通知先の決定規則（診断した当人へは書かぬ・cmd_180/T-4）:
        # dead_stale_agentsにshogunが含まれる場合、将軍inboxへ書くとその
        # 通知自身が将軍inboxの新たなstale未読になり、BATON_D1_NOTIFIED
        # （グローバルスカラ）が永久に1のまま張り付く（軍師OBS-180-1）。
        # 単独か否かは無関係——含まれてさえいれば起きる（軍師QC39-F1・
        # 是正前は「shogun単独」の場合しか救っておらず、shogunが他の者と
        # 並んで診断対象に入ると将軍inboxへ書いてしまい病が再発した）。
        # ゆえにkaro宛へ切り替える。それ以外は従来どおり将軍inbox。
        #
        # 【残余・塞げていない一点】shogunとkaroが同時に診断対象となる
        # 場合、inbox経路はどちらへ書いても診断対象自身であり原理的に
        # 自己給餌になる。本PRの射程では塞げない。ただし副経路ntfy
        # （baton_d1_ntfy_after_sec、既定900秒）は独立した閾値・独立した
        # ガードで動くため、900秒継続すれば必ず1回は主のスマホへ届く。
        # 「主へは届く。番犬の再武装（inbox経路によるkaro/shogunの覚醒）
        # だけが失われる」という限定的な残余であり、これを「塞いだ」と
        # 記録してはならない（CLAUDE.md「ACが原理的に充足不能と判明した
        # 場合」節と同じ規律）。
        if [[ " ${dead_stale_agents[*]} " == *" shogun "* ]]; then
            notify_target=karo
        else
            notify_target=shogun
        fi

        # 主経路: 通知先inbox書き込み。既存どおり、検知した時点で無条件・
        # 即座に発火する（メッセージ自身が既にBATON_D1_STALE_AFTER_SEC秒分
        # staleであることが継続の証拠であり、追加の待機は挟まない）。
        # ntfy_topic の設定有無やntfy到達可否には一切影響されない。
        if [ "$BATON_D1_NOTIFIED" -eq 0 ]; then
            baton_watchdog_notify_inbox "$notify_target" "delivery_stall: dead_watcher_stale_inboxes=${dead_stale_count} (${BATON_D1_STALE_AFTER_SEC}s+未読放置 かつ watcherプロセス不在。配送機構死亡の疑い)"
            BATON_D1_NOTIFIED=1
        fi

        # 副経路: ntfy（主のスマホ）。D-1専用の閾値（既定900秒。check_once用
        # baton_ntfy_after_secの1800秒より短い — D-1は配送機構死亡という
        # より緊急度の高い検知であるため）を、検知が継続した時間で計測する。
        # 失敗許容 — 失敗してもログに残すのみで将軍inbox通知には無関係。
        ntfy_threshold=$(baton_watchdog_query baton_d1_ntfy_after_sec)
        if [ "$elapsed" -ge "$ntfy_threshold" ] && [ "$BATON_D1_NTFY_NOTIFIED" -eq 0 ]; then
            if ! branch_policy_notify "delivery_stall: dead_watcher_stale_inboxes=${dead_stale_count} (${BATON_D1_STALE_AFTER_SEC}s+未読放置 かつ watcherプロセス不在。配送機構死亡の疑い。${ntfy_threshold}s+検知継続・ntfy)"; then
                echo "[$(date)] [baton_watchdog] D-1 ntfy notify failed (branch_policy_notify non-zero); shogun inbox notification unaffected" >&2
            fi
            BATON_D1_NTFY_NOTIFIED=1
        fi
    else
        BATON_D1_CONDITION_SINCE=0
        BATON_D1_NOTIFIED=0
        BATON_D1_NTFY_NOTIFIED=0
    fi
}

# ═══════════════════════════════════════════════════════════════
# B-4b: 無進捗検知（バトンを保持したまま停止）(cmd_179/T-B)
#
# 発端: 足軽7号が使用量制限中に報告執筆で中断し、status:assignedのまま
# 5時間41分誰にも検知されなかった。既存のB-1〜B-3（check_once）は
# 「未読合計0・稼働タスク0」を見るため、「タスクを持ったまま止まって
# いる」（バトンを握ったまま倒れている）状態を検知できない。D-1
# （check_d1_once）とも独立したOR条件であり、check_once/check_d1_once
# 本体には一切触れない。
#
# 条件はAND（2つのみ。当初案にあった「未読0」条件は誤りと判明し削除
# 済み——escalation ladder（inbox_watcher.shのnudge→Escape→/clear）には
# 通知経路が一切無いため、「未読ありならladderに任せる」は実際には
# 「誰にも任せていない」に等しく、未読が残ったまま止まっているケース
# （2026-07-31、家老自身が13:31〜17:29の約4時間この状態にあった）が
# 永久に検知漏れになる）:
#
#   (i)  queue/tasks/<agent>.yaml の status が assigned/in_progress、
#        かつ queue/reports/<agent>_report.yaml が「同一task_id・
#        status:done」という形の“既に納品済み”の反証を示していない
#        （＝バトンを保持中）。
#        【是正】単に status:assigned だけを見ると、仕事を終えたが
#        自分のtask YAMLのstatus欄を更新し忘れたエージェント（本日
#        実際に3体発生）に誤発火する。「バトンを保持している」の
#        正しい定義は「任を負い、かつまだ納めていない」こと。
#   (ii) 「progress artifact」（queue/tasks/<agent>.yaml・
#        queue/reports/<agent>_report.yaml・queue/inbox/<agent>.yaml
#        のmtime最大値）が progress_stall_after_sec（既定5400秒/90分）
#        以上更新されていない。
#
# 対象エージェントは queue/tasks/*.yaml が存在するものに限る
# （baton_watchdog_count_active_tasksと同じglob）。karo・shogunは
# queue/tasks/にファイルを持たないため対象外——既知の限界（B-4c等
# 別課題）。
#
# 通知はcheck_d1_onceと同型の二経路化。ただしB-4bはエージェント単位の
# 検知のため、閾値到達判定・NOTIFIEDガードの双方をエージェントごとの
# 連想配列で管理する。
# ═══════════════════════════════════════════════════════════════
declare -A B4B_CONDITION_SINCE=()  # agent -> 条件(i)(ii)が揃い始めたepoch(0なら未計測)
declare -A B4B_NOTIFIED=()         # 主経路(将軍inbox)の二重通知防止ガード（agentごと）
declare -A B4B_NTFY_NOTIFIED=()    # 副経路(ntfy)の二重通知防止ガード（agentごと）

# queue/tasks/*.yaml が存在するエージェント名を1行1件で返す
# （ファイル名から拡張子を除いたもの）。
baton_watchdog_list_agents() {
    local f
    for f in "$ROOT"/queue/tasks/*.yaml; do
        [ -f "$f" ] || continue
        basename "$f" .yaml
    done
}

# agent の queue/tasks/<agent>.yaml の task_id を返す（無ければ空文字）。
baton_watchdog_task_id() {
    local agent="$1" f
    f="$ROOT/queue/tasks/${agent}.yaml"
    [ -f "$f" ] || return 0
    grep -m1 '^  task_id:' "$f" 2>/dev/null | sed -E "s/^  task_id:[[:space:]]*//; s/^['\"]//; s/['\"]\$//"
}

# agent の task が assigned/in_progress であれば真。
baton_watchdog_task_active() {
    local agent="$1" f
    f="$ROOT/queue/tasks/${agent}.yaml"
    [ -f "$f" ] || return 1
    grep -qE '^  status: (assigned|in_progress)' "$f" 2>/dev/null
}

# ファイル1件のmtime（epoch秒）を返す。取得できなければ非0で終了する
# （呼び出し元は `|| return 1` 等で「取れなかった」を伝播させること）。
# 【cmd_188/③】report_delivered と agent_progress_mtime の両方が
# 同じ2ファイル（task/report）のmtimeを見るため、statの呼び出しを
# ここへ括り出し、片方だけ直る分岐が生まれないようにする。
baton_watchdog_file_mtime() {
    stat -c %Y "$1" 2>/dev/null
}

# agent の queue/reports/<agent>_report.yaml が「task_idが一致し、かつ
# status:done」であれば真（＝既に納品済み）。report yaml のフィールドは
# task yaml と異なりトップレベル（0-indent）である点に注意。
baton_watchdog_report_delivered() {
    local agent="$1" task_id="$2" f t report_task_id report_mtime task_mtime
    f="$ROOT/queue/reports/${agent}_report.yaml"
    [ -f "$f" ] || return 1
    [ -n "$task_id" ] || return 1
    report_task_id=$(grep -m1 '^task_id:' "$f" 2>/dev/null | sed -E "s/^task_id:[[:space:]]*//; s/^['\"]//; s/['\"]\$//")
    [ "$report_task_id" = "$task_id" ] || return 1
    grep -qE '^status: done' "$f" 2>/dev/null || return 1

    # 【cmd_188】同一task_idで差し戻された場合、報告は前回分の古い証拠
    # である。task YAMLが報告より後に書き換えられておれば、その報告を
    # 納品の証拠として採らない。statが取れなければreturn 1（＝納品と
    # 認めない＝activeに数える。迷ったら多く数える——count_activeが
    # 多い方へ倒れるとB-1は黙る〔誤発火せぬ〕。少なく倒れると早鳴きする）。
    t="$ROOT/queue/tasks/${agent}.yaml"
    report_mtime=$(baton_watchdog_file_mtime "$f") || return 1
    task_mtime=$(baton_watchdog_file_mtime "$t") || return 1
    # 【QC48-F1是正】同秒は秒粒度statでは順序不明ゆえ納品と認めぬ（fail-high）。
    [ "$task_mtime" -lt "$report_mtime" ] || return 1
    return 0
}

# 条件(i)【是正版】: 「assigned/in_progressであり、かつreportが既に
# 納品済みという反証を示していない」ことをもって「バトンを保持中」とする。
baton_watchdog_agent_holds_baton() {
    local agent="$1" task_id
    baton_watchdog_task_active "$agent" || return 1
    task_id=$(baton_watchdog_task_id "$agent")
    baton_watchdog_report_delivered "$agent" "$task_id" && return 1
    return 0
}

# progress artifact（task/reportのmtime最大値、epoch秒）を返す。
# いずれのファイルも無ければ0を返す（安全側＝進捗ありとみなし発火させない）。
#
# 【cmd_187/SF-1是正】以前はinboxのmtimeも含めていたが、inboxは
# 「当人が書くもの」ではなく「他人（家老・番犬・inbox_watcher等）が
# 当人へ書くもの」であるため、他者が1件書くだけで当人が一文字も
# 動いていなくとも stalled_for が0へ巻き戻る欠陥があった（軍師の
# A/B実測：queue/reports/gunshi_183_self_feed_audit.yaml SF-1）。
# read: true への更新時刻のみを進捗と認める代替案（read_at方式）も
# 検討したが、新規タイムスタンプ基盤が要り全エージェントの既読処理を
# 横断して変更する必要があるため見送り、inboxを進捗根拠から完全に
# 除外する単純な方式を採った（トレードオフの詳細はPR本文を参照）。
baton_watchdog_agent_progress_mtime() {
    local agent="$1" f max=0 m
    for f in "$ROOT/queue/tasks/${agent}.yaml" "$ROOT/queue/reports/${agent}_report.yaml"; do
        [ -f "$f" ] || continue
        m=$(baton_watchdog_file_mtime "$f") || continue
        [ -n "$m" ] && [ "$m" -gt "$max" ] && max=$m
    done
    echo "$max"
}

# B-4bを1回だけ判定する。check_once()・check_d1_once()とは完全に独立した
# 関数であり、それらを呼ばない・その内部にも触れない。
check_b4b_once() {
    local agent now stall_threshold ntfy_threshold
    local progress_mtime stalled_for elapsed task_id

    if [ "$(baton_watchdog_query enabled)" != "true" ]; then
        return 0
    fi

    now=$(date +%s)
    stall_threshold=$(baton_watchdog_query progress_stall_after_sec)
    ntfy_threshold=$(baton_watchdog_query baton_b4b_ntfy_after_sec)

    while IFS= read -r agent; do
        [ -n "$agent" ] || continue

        if baton_watchdog_agent_holds_baton "$agent"; then
            progress_mtime=$(baton_watchdog_agent_progress_mtime "$agent")
            stalled_for=$((now - progress_mtime))

            if [ "$stalled_for" -ge "$stall_threshold" ]; then
                if [ "${B4B_CONDITION_SINCE[$agent]:-0}" -eq 0 ]; then
                    B4B_CONDITION_SINCE[$agent]=$now
                fi
                elapsed=$((now - B4B_CONDITION_SINCE[$agent]))

                # 主経路: 将軍inbox通知。既存どおり検知した時点で無条件・
                # 即座に発火する（progress_stall_after_sec秒分の無更新
                # 自体が継続の証拠であり、追加の待機は挟まない）。
                if [ "${B4B_NOTIFIED[$agent]:-0}" -eq 0 ]; then
                    task_id=$(baton_watchdog_task_id "$agent")
                    baton_watchdog_notify_shogun "no_progress: agent=${agent} task_id=${task_id} stalled_for=${stalled_for}s (バトン保持のまま${stall_threshold}s+無進捗)"
                    B4B_NOTIFIED[$agent]=1
                fi

                # 副経路: ntfy（主のスマホ）。エージェントごとに独立した
                # 閾値・ガードで管理する。失敗許容——失敗してもログに
                # 残すのみで将軍inbox通知には無関係。
                if [ "$elapsed" -ge "$ntfy_threshold" ] && [ "${B4B_NTFY_NOTIFIED[$agent]:-0}" -eq 0 ]; then
                    if ! branch_policy_notify "no_progress: agent=${agent} stalled_for=${stalled_for}s (${ntfy_threshold}s+検知継続・ntfy)"; then
                        echo "[$(date)] [baton_watchdog] B-4b ntfy notify failed (branch_policy_notify non-zero); shogun inbox notification unaffected" >&2
                    fi
                    B4B_NTFY_NOTIFIED[$agent]=1
                fi
            else
                # 条件(ii)が崩れた＝進捗が観測された。次に条件が揃った
                # 際は新たな継続として独立して計測し直す。
                B4B_CONDITION_SINCE[$agent]=0
                B4B_NOTIFIED[$agent]=0
                B4B_NTFY_NOTIFIED[$agent]=0
            fi
        else
            # 条件(i)が崩れた＝バトンを保持していない（未着手 or 納品済み）。
            B4B_CONDITION_SINCE[$agent]=0
            B4B_NOTIFIED[$agent]=0
            B4B_NTFY_NOTIFIED[$agent]=0
        fi
    done < <(baton_watchdog_list_agents)
}

# ═══════════════════════════════════════════════════════════════
# B-4c: stale未読 かつ watcher生存 検知（cmd_180/T-3）
#
# 発端: 2026-07-31 20:52:25 からの6時間23分の自己沈黙インシデント。
# 既存のB-1〜B-3（check_once）・D-1（check_d1_once・watcher死亡が前提）
# のいずれも、「watcherは生きているが、対象がinboxを読んでいない」形の
# 停止を検知できない。B-4cはこれを埋める独立したOR条件である。
#
# 条件はAND:
#   (i)  stale未読が baton_b4c_stale_after_sec（既定5400秒/90分）以上
#   (ii) WATCHER_ALIVE_SNAPSHOT[agent] == 1（サイクル冒頭で凍結した値を
#        読む。D-1と別々にpgrepを叩くと、その間にwatcher_supervisorが
#        死んだwatcherを再起動した場合に両方が発火し得るため。
#        軍師検証2・是正1）
#
# 対象エージェント列挙は baton_watchdog_list_stale_inbox_agents を
# 閾値パラメタ化して流用する（D-1が使うものと同一関数。D-1の無引数
# 呼び出しは挙動不変。軍師検証2 q3）。
#
# 【最重要・自己給餌ラッチの防止】通知先は「番犬は、停滞を診断した
# 当人のinboxへ通知を書いてはならない」原則（軍師
# principle_never_write_to_the_diagnosed）に従う。将軍inboxへ書くと、
# その通知自身が将軍inboxの新たなstale未読になり、B4C_NOTIFIED[shogun]
# が永久に1のまま張り付く（一度吠えたきり永久に黙る＝本cmdが塞ごうと
# している当の病そのもの）ため:
#   対象がshogun          → 主経路はkaroのinboxへ
#   対象がkaro            → 主経路はshogunのinboxへ
#   対象がそれ以外(足軽/軍師) → 従来どおりshogunのinboxへ
#   副経路(ntfy)          → 対象を問わず常に試みる（失敗許容）
# ntfyの副経路閾値はB-4bのbaton_b4b_ntfy_after_secを流用する（B-4cは
# 「90分無進捗」という尺度をB-4bと共有する設計であり、専用キーは新設しない）。
#
# 【既知の残余・軍師OBS-180-3】B-4cが将軍を検知できるのは「将軍宛に
# 未読が在る」時に限る。将軍inboxへ書く者はbaton_watchdogと
# watcher_supervisorの2者のみであり、平時は将軍宛の未読が発生しない。
# 「番犬が吠える理由も無いまま将軍が居らぬ」形は依然として検知できない。
#
# check_once/check_d1_once/check_b4b_once本体には一切触れない。
# ═══════════════════════════════════════════════════════════════
declare -A B4C_CONDITION_SINCE=()  # agent -> 条件(i)(ii)が揃い始めたepoch(0なら未計測)
declare -A B4C_NOTIFIED=()         # 主経路の二重通知防止ガード（agentごと）
declare -A B4C_NTFY_NOTIFIED=()    # 副経路(ntfy)の二重通知防止ガード（agentごと）

# 診断した当人のinboxへは書かぬ、という原則に基づき通知先を決める
# （cmd_180・軍師 principle_never_write_to_the_diagnosed。T-3/T-4共通）。
baton_watchdog_notify_target_for() {
    local agent="$1"
    case "$agent" in
        shogun) echo karo ;;
        karo)   echo shogun ;;
        *)      echo shogun ;;
    esac
}

# B-4cを1回だけ判定する。check_once()・check_d1_once()・check_b4b_once()
# とは完全に独立した関数であり、それらを呼ばない・その内部にも触れない。
check_b4c_once() {
    local agent now stale_threshold ntfy_threshold notify_target
    local elapsed stale_agent exempt_csv machine_threshold
    local -A stale_agent_set=()
    local -A stale_agent_set_no_safety_net=()

    if [ "$(baton_watchdog_query enabled)" != "true" ]; then
        return 0
    fi

    now=$(date +%s)
    stale_threshold=$(baton_watchdog_query baton_b4c_stale_after_sec)
    ntfy_threshold=$(baton_watchdog_query baton_b4b_ntfy_after_sec)
    # cmd_189: 将軍inboxに限り、機械由来（agent_registry_agents非該当の
    # from）の未読を通常閾値では数えず、24時間の安全網のみで発火させる。
    # D-1（check_d1_once）はこの除外を一切適用しない無引数呼び出しのまま。
    exempt_csv=$(baton_watchdog_query baton_b4c_machine_exempt_agents | paste -sd, -)
    machine_threshold=$(baton_watchdog_query baton_b4c_machine_stale_after_sec)

    while IFS= read -r stale_agent; do
        [ -n "$stale_agent" ] || continue
        stale_agent_set[$stale_agent]=1
    done < <(baton_watchdog_list_stale_inbox_agents "$stale_threshold" "$exempt_csv" "$machine_threshold")

    # cmd_189・通知文言の書き分け用（risks節）: 安全網(machine_threshold)を
    # 0に固定して同じ判定をやり直す。stale_agent_set にのみ現れ、こちらに
    # 現れないagentは「安全網のみが理由でstaleとなった」＝機械由来のみ。
    # 非exempt agentや、exempt agentでもagent由来の未読がある場合は両集合が
    # 一致するため、この判定は自然にexemptかつ機械由来のみの場合だけに絞られる。
    while IFS= read -r stale_agent; do
        [ -n "$stale_agent" ] || continue
        stale_agent_set_no_safety_net[$stale_agent]=1
    done < <(baton_watchdog_list_stale_inbox_agents "$stale_threshold" "$exempt_csv" 0)

    # 全inboxエージェントを固定の母集合として毎回走査する（B-4bと同じ
    # 規律）。stale集合のみを走査すると、staleから外れたエージェントの
    # ガードが二度とリセットされず、再武装（TC-B4C-LATCH-002）が壊れる。
    while IFS= read -r agent; do
        [ -n "$agent" ] || continue

        if [ "${stale_agent_set[$agent]:-0}" = "1" ] && [ "${WATCHER_ALIVE_SNAPSHOT[$agent]:-0}" -eq 1 ]; then
            if [ "${B4C_CONDITION_SINCE[$agent]:-0}" -eq 0 ]; then
                B4C_CONDITION_SINCE[$agent]=$now
            fi
            elapsed=$((now - B4C_CONDITION_SINCE[$agent]))

            notify_target=$(baton_watchdog_notify_target_for "$agent")

            # 主経路: 検知した時点で無条件・即座に発火する（stale未読
            # 自体が継続の証拠であり、追加の待機は挟まない）。
            # cmd_189: 安全網(machine_stale_after_sec)のみが理由で発火した
            # 場合、家老が「対象が停止した」と読み違えぬよう、機械由来のみ
            # である旨と次に何をすべきかを文言に含める（risks節）。
            if [ "${B4C_NOTIFIED[$agent]:-0}" -eq 0 ]; then
                if [ "${stale_agent_set_no_safety_net[$agent]:-0}" != "1" ]; then
                    baton_watchdog_notify_inbox "$notify_target" "inbox_stall: agent=${agent} (machine-origin only, ${machine_threshold}s+。主の長期ご不在の可能性が高い。${agent} paneの実見で切り分けよ)"
                else
                    baton_watchdog_notify_inbox "$notify_target" "inbox_stall: agent=${agent} (${stale_threshold}s+未読放置 かつ watcherプロセス生存。読まれていない疑い)"
                fi
                B4C_NOTIFIED[$agent]=1
            fi

            # 副経路: ntfy（主のスマホ）。エージェントごとに独立した
            # 閾値・ガードで管理する。失敗許容——失敗してもログに残す
            # のみで主経路の通知には無関係。
            if [ "$elapsed" -ge "$ntfy_threshold" ] && [ "${B4C_NTFY_NOTIFIED[$agent]:-0}" -eq 0 ]; then
                if ! branch_policy_notify "inbox_stall: agent=${agent} (${ntfy_threshold}s+検知継続・ntfy)"; then
                    echo "[$(date)] [baton_watchdog] B-4c ntfy notify failed (branch_policy_notify non-zero); shogun inbox notification unaffected" >&2
                fi
                B4C_NTFY_NOTIFIED[$agent]=1
            fi
        else
            # 条件(i)(ii)いずれかが崩れた＝watcherが死んでいる（D-1の
            # 担当領域）か、もはやstaleでない。次に条件が揃った際は
            # 新たな継続として独立して計測し直す。
            B4C_CONDITION_SINCE[$agent]=0
            B4C_NOTIFIED[$agent]=0
            B4C_NTFY_NOTIFIED[$agent]=0
        fi
    done < <(baton_watchdog_list_inbox_agents)
}

# ═══════════════════════════════════════════════════════════════
# 使用量制限 事前予告(a)・猶予(b)・事後自動再開(c) (cmd_181)
#
# check_once/check_d1_once/check_b4b_once/check_b4c_once とは完全に
# 独立した機能。それらを呼ばず、その内部状態にも触れない。
#
# 前提誤り2件（実装前に是正済み）:
#   1. resets_at のUTC切り詰め対策として lib/usage_limit.sh が新たに
#      出力する 5H_RESET_EPOCH/7D_RESET_EPOCH（既にepoch化済み）のみを
#      用いる。bashで文字列を解釈しない。
#   2. 再開の関門に usage_limit_state は使わない（「制限が近いか」を
#      答える関数であり「いま塞がれているか」ではない）。関門は
#      「予告時に記録した reset epoch と、いま取得した reset epoch が
#      異なること」＝枠そのものの巻き直り。
#
# 重複防止は枠の同一性そのものを鍵にする（NOTIFIEDブール＋明示リセット
# 様式は踏襲しない。cmd_180 OBS-180-1の教訓）:
#   USAGE_WARNED_WINDOW[label] = <その時の reset epoch>
# 条件は「いまの reset epoch が記録値と異なる」。新しい枠は必ず新しい
# epochを持つため、リセット操作なしにラッチが構造的に起こり得ない。
# ═══════════════════════════════════════════════════════════════

# 全エージェントを通じた「最後に何かが動いた時刻」。B-4bの
# baton_watchdog_agent_progress_mtime を全エージェントで最大化するだけ。
baton_watchdog_max_progress_mtime() {
    local agent m max=0
    while IFS= read -r agent; do
        [ -n "$agent" ] || continue
        # 番犬自身の通知先は「進捗」と数えぬ。予告(usage_warn)が
        # karoのinboxを書き換えると、そのmtimeが「karoの進捗」として
        # 拾われ、再開条件(iv)（予告以降誰も動いていない）が永久に
        # 偽になる自己給餌を起こす（cmd_180 OBS-180-1と同型。OBS-181-6）。
        case "$agent" in karo|shogun) continue ;; esac
        m=$(baton_watchdog_agent_progress_mtime "$agent")
        [ -n "$m" ] && [ "$m" -gt "$max" ] && max=$m
    done < <(baton_watchdog_list_agents)
    echo "$max"
}

# check_once / check_d1_once / check_b4b_once / check_b4c_once と
# 完全に独立。それらを呼ばず、その内部状態にも触れない。
check_usage_once() {
    local now interval raw
    local util5h reset5h util7d reset7d flagged
    local warn_pct resume_pct

    [ "$(baton_watchdog_query enabled)" = "true" ] || return 0

    now=$(date +%s)
    interval=$(baton_watchdog_query usage_check_interval_sec)
    [ $((now - USAGE_LAST_CHECK_AT)) -ge "$interval" ] || return 0
    USAGE_LAST_CHECK_AT=$now

    raw="$(usage_limit_fetch_raw)" || raw=""
    # 取得不能なら何もしない。推測で予告も再開も出さぬ
    # （usage_limit_state が "ok" へ倒れぬのと同じ向き）。
    [ -n "$raw" ] || {
        echo "[$(date)] [baton_watchdog/usage] fetch failed; no action"
        return 0
    }

    util5h=$(printf '%s' "$raw" | grep '^5H_UTIL='        | cut -d= -f2)
    reset5h=$(printf '%s' "$raw" | grep '^5H_RESET_EPOCH=' | cut -d= -f2)
    util7d=$(printf '%s' "$raw" | grep '^7D_UTIL='        | cut -d= -f2)
    reset7d=$(printf '%s' "$raw" | grep '^7D_RESET_EPOCH=' | cut -d= -f2)
    flagged=$(printf '%s' "$raw" | grep '^LIMITS_FLAGGED=' | cut -d= -f2)

    warn_pct=$(baton_watchdog_query usage_warn_pct)
    resume_pct=$(baton_watchdog_query usage_resume_below_pct)

    # 5時間枠: 予告は家老へも送る（(b)の本体）。
    _usage_window_check 5h "$util5h" "$reset5h" "$warn_pct" \
                        "$resume_pct" "$now" true "$flagged"
    # 7日枠: 予告(a)は将軍inbox+ntfyのみで家老へは送らぬ
    #        （数日先の解除に「区切りをつけよ」は助言たり得ぬ）。
    # 【OBS-181-7】ただし notify_karo は予告(a)専用のフラグであり、
    # 再開(c)には適用されない——_usage_window_check の(c)節に見る
    # 通り、再開通知は枠を問わず常に家老へ届く。これは正しい挙動
    # である: 現状、7日枠の巻き直りで家老を起こす経路はこの再開(c)
    # 1本しか無いため、5時間枠に合わせて塞ぐとまさに要る時に効かなく
    # なる。
    _usage_window_check 7d "$util7d" "$reset7d" "$warn_pct" \
                        "$resume_pct" "$now" false "$flagged"

    echo "[$(date)] [baton_watchdog/usage] 5h_util=${util5h:-?} 7d_util=${util7d:-?}"
}

# label util reset_epoch warn_pct resume_pct now notify_karo(true|false) flagged
_usage_window_check() {
    local label="$1" util="$2" reset="$3" warn_pct="$4"
    local resume_pct="$5" now="$6" notify_karo="$7" flagged="${8:-}"
    local open_cmds max_mtime msg gate_open

    # epoch が取れなければこの枠は判定しない（推測しない）
    [[ "$reset" =~ ^[0-9]+$ ]] || return 0
    [[ "$util"  =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0

    # ── (a) 予告 ──────────────────────────────
    # 鍵は枠の同一性（reset epoch）。新しい枠は必ず新しい値を
    # 持つゆえ、明示リセットが要らぬ＝ラッチし得ぬ（OBS-180-1）。
    if awk -v u="$util" -v t="$warn_pct" 'BEGIN{exit !(u>=t)}' \
       && [ "${USAGE_WARNED_WINDOW[$label]:-0}" != "$reset" ]; then
        msg="usage_warn: window=${label} util=${util}% reset=$(date -d "@$reset" '+%m/%d %H:%M %Z')"
        baton_watchdog_notify_shogun "$msg"
        if [ "$notify_karo" = "true" ]; then
            bash "$ROOT/scripts/inbox_write.sh" karo \
              "${msg}。着手中タスクの task YAML と報告YAML を今のうちに書き切らせよ。新規の大きな発注は解除後に回せ。" \
              usage_warn baton_watchdog
        fi
        # 副経路。失敗許容——ログに残すのみで主経路に影響させぬ。
        branch_policy_notify "$msg" || \
          echo "[$(date)] [baton_watchdog/usage] ntfy failed; inbox notification unaffected" >&2
        USAGE_WARNED_WINDOW[$label]=$reset
        USAGE_WARNED_AT[$label]=$now
        USAGE_WARNED_FLAGGED[$label]="$flagged"
    fi

    # ── (c) 再開 ──────────────────────────────
    # 関門はORの二経路（finding_3）:
    #   (i)  予告を出した枠が巻き直った＝ reset epoch が変わったこと
    #        そのものが解除の直接証拠（閾値の当て推量を要さぬ）。
    #   (ii) LIMITS_FLAGGEDが予告時のtrueから今回falseへ落ちたこと。
    #        契約変更・上限緩和など、枠の巻き直りを伴わない解除
    #        （本日実データで reset epoch 不変のまま true→false 遷移
    #        を確認済み。(i)のみでは検知できない）。
    # ラッチ防止は従来どおり USAGE_RESUMED_WINDOW を鍵に保つ——(ii)
    # 経路でも reset epoch は変わらぬため、そのまま同じ鍵で機能する。
    [ -n "${USAGE_WARNED_AT[$label]:-}" ] || return 0
    [ "${USAGE_RESUMED_WINDOW[$label]:-0}" != "$reset" ] || return 0

    gate_open=false
    if [ "${USAGE_WARNED_WINDOW[$label]:-0}" != "$reset" ]; then
        gate_open=true
    elif [ "${USAGE_WARNED_FLAGGED[$label]:-false}" = "true" ] \
         && [ "$flagged" = "false" ]; then
        gate_open=true
    fi
    [ "$gate_open" = "true" ] || return 0

    # 裏取り: 新しい枠に余裕があること（(i)(ii)いずれの経路でも必須）
    awk -v u="$util" -v t="$resume_pct" 'BEGIN{exit !(u<t)}' || return 0
    # 仕事があること
    open_cmds=$(baton_watchdog_count_open_cmds)
    [ "${open_cmds:-0}" -gt 0 ] || return 0
    # 【空振り防止の核】予告以降、誰一人動いておらぬこと
    max_mtime=$(baton_watchdog_max_progress_mtime)
    [ "${max_mtime:-0}" -lt "${USAGE_WARNED_AT[$label]}" ] || {
        # 動いておる＝乗り切った。起こす必要は無い。
        USAGE_RESUMED_WINDOW[$label]=$reset
        return 0
    }

    msg="usage_resume: window=${label} 解除確認(util=${util}%) open_cmds=${open_cmds}。queue/ のYAMLから状態を再構築し作業を再開せよ。"
    bash "$ROOT/scripts/inbox_write.sh" karo "$msg" usage_resume baton_watchdog
    branch_policy_notify "$msg" || \
      echo "[$(date)] [baton_watchdog/usage] resume ntfy failed" >&2
    USAGE_RESUMED_WINDOW[$label]=$reset
}

if [ "${__BATON_WATCHDOG_TESTING__:-}" != "1" ]; then
    mkdir -p "$ROOT/logs"

    # enabled=false ならデーモンとして起動する意味自体が無いため即終了する。
    if [ "$(baton_watchdog_query enabled)" != "true" ]; then
        exit 0
    fi

    if [ "${1:-}" = "--once" ]; then
        baton_watchdog_refresh_watcher_snapshot
        check_once
        check_d1_once
        check_b4b_once
        check_b4c_once
        periodic_clear_check_once
        check_usage_once
        exit 0
    fi

    while true; do
        baton_watchdog_refresh_watcher_snapshot
        check_once
        check_d1_once
        check_b4b_once
        check_b4c_once
        periodic_clear_check_once
        check_usage_once
        sleep "$(baton_watchdog_query poll_interval_sec)"
    done
fi
