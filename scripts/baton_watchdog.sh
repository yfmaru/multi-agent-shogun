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
# 【periodic /clear (cmd_172/P7) — 同プロセスへの並存拡張】
# 上記B-1/B-2/B-3判定（check_once）とは完全に独立した別機能を同居させる。
# karo/軍師それぞれが「手隙」を periodic_clear_idle_sec 以上継続した場合に
# 限り、既存の clear_command 配送経路（inbox_write.sh → inbox_watcher.sh）
# へ1回だけ書き込み、文脈をリセットさせる。opt-in（既定 disabled）。
# 詳細は periodic_clear_* 関数群（check_once 定義の直前）を参照。
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

# ─── プロセスローカル状態 ───
BATON_LOST_SINCE=0     # 3条件が揃い始めた epoch（揃っていなければ0）
BATON_NOTIFIED=0       # 将軍inbox通知を同一継続停止で二重送信しないためのガード
BATON_NTFY_NOTIFIED=0  # ntfy通知（cmd_172/急報）を同一継続停止で二重送信しないためのガード

# ─── periodic /clear (cmd_172/P7) プロセスローカル状態 ───
# エージェントごとに独立（B-1/B-2/B-3の全体判定とは完全に並存する別機能）。
declare -A PERIODIC_CLEAR_IDLE_SINCE=()  # agent -> idle条件が揃い始めた epoch（0なら未計測）
declare -A PERIODIC_CLEAR_SENT=()        # agent -> 同一idle windowで送信済みか(1/0)

baton_watchdog_count_unread() {
    local unread=0 f n
    for f in "$ROOT"/queue/inbox/*.yaml; do
        [ -f "$f" ] || continue
        n=$(grep -c 'read: false' "$f" 2>/dev/null || true)
        unread=$((unread + ${n:-0}))
    done
    echo "$unread"
}

baton_watchdog_count_active_tasks() {
    local active=0 f
    for f in "$ROOT"/queue/tasks/*.yaml; do
        [ -f "$f" ] || continue
        if grep -qE '^  status: (assigned|in_progress)' "$f" 2>/dev/null; then
            active=$((active + 1))
        fi
    done
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
    bash "$ROOT/scripts/inbox_write.sh" shogun "$message" baton_alert baton_watchdog
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

if [ "${__BATON_WATCHDOG_TESTING__:-}" != "1" ]; then
    mkdir -p "$ROOT/logs"

    # enabled=false ならデーモンとして起動する意味自体が無いため即終了する。
    if [ "$(baton_watchdog_query enabled)" != "true" ]; then
        exit 0
    fi

    if [ "${1:-}" = "--once" ]; then
        check_once
        periodic_clear_check_once
        exit 0
    fi

    while true; do
        check_once
        periodic_clear_check_once
        sleep "$(baton_watchdog_query poll_interval_sec)"
    done
fi
