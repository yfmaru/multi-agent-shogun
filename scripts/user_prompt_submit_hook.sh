#!/usr/bin/env bash
# UserPromptSubmit hook — busy印/ups印 touch (cmd_217 二枚の印方式 + 是正3点)
#
# 目的:
#   busy/idle をpaneの見た目から推し量るのをやめ、CLI自身が知っている
#   出来事（ターンの開始）を busy印 の mtime として記録する。ターンの
#   開始とは「nudge・主の入力が実際に読み込まれてターンが始まった瞬間」
#   であり、UserPromptSubmit がその一次情報である。
#   詳細設計: queue/reports/gunshi_design_217_idle_flag_liveness.yaml
#            queue/reports/gunshi_report.yaml (design_1/design_2, 是正3点)
#
# 契約: 必ず exit 0。agent_id解決失敗・touch失敗、いずれの場合も非0で
# 終了してはならない。hookの非0終了はプロンプト投入自体を壊す
# （全軍が同時に壊れる型の事故。T-217-11）。
#
# Usage: 登録は .claude/settings.json の hooks.UserPromptSubmit から。
#   Claude Code が発火時に stdin へJSONを渡す。L3（lib/agent_id_
#   resolve.sh）はその session_id を読むために stdin を消費する。

set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$SELF_DIR/../logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true

# ─── AGENT_ID_RESOLVE_LADDER (cmd_217 design_1) ───
# 実体は lib/agent_id_resolve.sh — 各段を単体テストできるよう、
# このhook自身が持つ無条件 exit 0 の外側にライブラリとして置く。
_agent_id_resolve_lib="$SELF_DIR/../lib/agent_id_resolve.sh"
if [ -f "$_agent_id_resolve_lib" ]; then
    # shellcheck source=/dev/null
    source "$_agent_id_resolve_lib"
fi

# stdin JSON から session_id を取り出す（L3用）。stdin は DATA として
# 扱うのみで、中身を実行することは絶対にしない。timeoutで包み、stdin
# が来ない/閉じない環境でも exit 0 契約を守る。
HOOK_SESSION_ID=""
if [ ! -t 0 ]; then
    _stdin_json=$(timeout 1 cat 2>/dev/null || true)
    if [ -n "$_stdin_json" ] && command -v python3 &>/dev/null; then
        HOOK_SESSION_ID=$(printf '%s' "$_stdin_json" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get("session_id", ""))
except Exception:
    print("")
' 2>/dev/null || true)
    fi
fi

AGENT_ID=""
RESOLVED_VIA=""
if declare -f resolve_agent_id_ladder &>/dev/null; then
    if resolve_agent_id_ladder "$HOOK_SESSION_ID"; then
        AGENT_ID="$RESOLVED_AGENT_ID"
        RESOLVED_VIA="$RESOLVED_VIA"
    fi
fi

if [ -z "$AGENT_ID" ]; then
    # 三段すべて空振り（またはライブラリ不在）。§7-2緩和: 黙って exit 0
    # するが、原因追跡用に1行だけログへ残す。
    echo "[$(date -Iseconds)] user_prompt_submit_hook: AGENT_ID unresolved (TMUX_PANE=${TMUX_PANE:-<unset>}, L1/L2/L3 all failed) — skipping busy/ups touch" \
        >> "$LOG_DIR/hook_user_prompt_submit.log" 2>/dev/null || true
    exit 0
fi

# ─── UPS_MARK_PROVENANCE (cmd_217 design_2) ───
# busy印（3者共有・意味論不変）に加え、本hook「だけ」が touch する
# ups印を新設する。check_hook_armed() は ups印 のみを見ることで、
# 「何が印を動かしたか」を出所で分離する（/clear由来のbusy印touchと
# 区別できる）。
touch "${IDLE_FLAG_DIR:-/tmp}/shogun_busy_${AGENT_ID}" 2>/dev/null || true
touch "${IDLE_FLAG_DIR:-/tmp}/shogun_ups_${AGENT_ID}" 2>/dev/null || true

# 成功経路にも痕跡を残す（N-2再発防止）。従来は失敗経路にしかログが
# 無く、「ログが増えぬ」が健全とも障害とも読めてしまい、実際に前者へ
# 誤読された（gunshi_report.yaml N-2）。沈黙を健全の証にしてはならぬ。
echo "[$(date -Iseconds)] user_prompt_submit_hook: agent=${AGENT_ID} busy印/ups印 touch OK (resolved via ${RESOLVED_VIA})" \
    >> "$LOG_DIR/hook_user_prompt_submit.log" 2>/dev/null || true

exit 0
