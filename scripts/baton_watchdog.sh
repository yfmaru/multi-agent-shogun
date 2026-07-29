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
BATON_LOST_SINCE=0   # 3条件が揃い始めた epoch（揃っていなければ0）
BATON_NOTIFIED=0     # 同一の継続停止に対して二重通知しないためのガード

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

# 1回だけ判定する。メインループ・--once どちらからも呼ばれる。
check_once() {
    local now unread active open_cmds threshold

    if [ "$(baton_watchdog_query enabled)" != "true" ]; then
        return 0
    fi

    now=$(date +%s)
    unread=$(baton_watchdog_count_unread)
    active=$(baton_watchdog_count_active_tasks)
    open_cmds=$(baton_watchdog_count_open_cmds)

    if [ "${unread:-0}" -eq 0 ] && [ "${active:-0}" -eq 0 ] && [ "${open_cmds:-0}" -gt 0 ]; then
        if [ "$BATON_LOST_SINCE" -eq 0 ]; then
            BATON_LOST_SINCE=$now
        fi

        threshold=$(baton_watchdog_query baton_lost_after_sec)
        if [ $((now - BATON_LOST_SINCE)) -ge "$threshold" ] && [ "$BATON_NOTIFIED" -eq 0 ]; then
            branch_policy_notify "baton_lost: unread=0 active=0 open_cmds=${open_cmds} (${threshold}s+継続)"
            BATON_NOTIFIED=1
        fi
    else
        # 条件が崩れた＝バトンは持たれている。状態をリセットし、
        # 次に条件が揃った際は新たな継続として計測し直す。
        BATON_LOST_SINCE=0
        BATON_NOTIFIED=0
    fi
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
# B-1〜B-3のような別途の継続時間計測（BATON_LOST_SINCE相当）は不要である。
#
# 既存の check_once()（B-1〜B-3判定）の内部は一切変更しない。
# ═══════════════════════════════════════════════════════════════
BATON_D1_STALE_AFTER_SEC=600   # 10分。既存baton_lost_after_secとは独立した固定値
BATON_D1_NOTIFIED=0            # 同一の継続停止に対して二重通知しないためのガード

# queue/inbox/*.yaml のうち、read: false かつ timestamp が
# BATON_D1_STALE_AFTER_SEC 秒以上前のメッセージを1件以上含む inbox の
# agent名（ファイル名から拡張子を除いたもの）を、1行1件で標準出力へ返す。
# naive（tzinfo無し）timestamp は「ローカル時刻」として解釈する
# （書き手 scripts/inbox_write.sh:46 は `date "+%Y-%m-%dT%H:%M:%S"` で
#   ローカル時刻・オフセット表記なしのnaive文字列を書くため）。
# 読むのは queue/inbox/*.yaml のみ。tmux には一切触れない（TC-D1-005）。
baton_watchdog_list_stale_inbox_agents() {
    local python_bin
    python_bin="$(stall_policy_python)"
    "$python_bin" - "$ROOT" "$BATON_D1_STALE_AFTER_SEC" <<'PY'
import glob
import os
import sys
from datetime import datetime, timezone

root, threshold = sys.argv[1], int(sys.argv[2])

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
    stale_here = False
    for msg in messages:
        if not isinstance(msg, dict):
            continue
        if msg.get("read") is not False:
            continue
        dt = parse_ts(msg.get("timestamp"))
        if dt is None:
            continue
        if (now - dt).total_seconds() >= threshold:
            stale_here = True
            break
    if stale_here:
        print(os.path.splitext(os.path.basename(path))[0])
PY
}

# agent の inbox_watcher.sh が生きていれば真を返す。
# watcher_supervisor.sh の重複起動防止判定と同一パターンを用いる
# （末尾スペースは ashigaru1 が ashigaru10 等に部分一致するのを防ぐ）。
baton_watchdog_watcher_alive() {
    local agent="$1"
    pgrep -f "scripts/inbox_watcher.sh ${agent} " >/dev/null 2>&1
}

# D-1を1回だけ判定する。check_once()（B-1〜B-3）とは完全に独立した関数であり、
# check_once() を呼ばない・その内部にも触れない。
#
# 条件はAND: (i) stale unread な inbox がある **かつ**
#            (ii) その agent の inbox_watcher.sh プロセスが生きていない
check_d1_once() {
    local agent dead_stale_count=0

    if [ "$(baton_watchdog_query enabled)" != "true" ]; then
        return 0
    fi

    while IFS= read -r agent; do
        [ -n "$agent" ] || continue
        if ! baton_watchdog_watcher_alive "$agent"; then
            dead_stale_count=$((dead_stale_count + 1))
        fi
    done < <(baton_watchdog_list_stale_inbox_agents)

    if [ "$dead_stale_count" -gt 0 ]; then
        if [ "$BATON_D1_NOTIFIED" -eq 0 ]; then
            branch_policy_notify "delivery_stall: dead_watcher_stale_inboxes=${dead_stale_count} (${BATON_D1_STALE_AFTER_SEC}s+未読放置 かつ watcherプロセス不在。配送機構死亡の疑い)"
            BATON_D1_NOTIFIED=1
        fi
    else
        BATON_D1_NOTIFIED=0
    fi
}

if [ "${__BATON_WATCHDOG_TESTING__:-}" != "1" ]; then
    mkdir -p "$ROOT/logs"

    # enabled=false ならデーモンとして起動する意味自体が無いため即終了する。
    if [ "$(baton_watchdog_query enabled)" != "true" ]; then
        exit 0
    fi

    if [ "${1:-}" = "--once" ]; then
        check_once
        check_d1_once
        exit 0
    fi

    while true; do
        check_once
        check_d1_once
        sleep "$(baton_watchdog_query poll_interval_sec)"
    done
fi
