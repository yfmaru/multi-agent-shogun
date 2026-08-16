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

# stdin JSON から session_id と transcript_path を取り出す（L3・
# cmd_226生存痕跡用）。stdin は DATA として扱うのみで、中身を実行する
# ことは絶対にしない。timeoutで包み、stdinが来ない/閉じない環境でも
# exit 0 契約を守る。python3の起動は1回に留める（全軍の全ターンの
# 先頭で同期実行されるため。stop_hook_inbox.sh:56-59と同じ作法）。
HOOK_SESSION_ID=""
HOOK_TRANSCRIPT_PATH=""
if [ ! -t 0 ]; then
    _stdin_json=$(timeout 1 cat 2>/dev/null || true)
    if [ -n "$_stdin_json" ] && command -v python3 &>/dev/null; then
        _hook_fields=$(printf '%s' "$_stdin_json" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get("session_id", ""))
    print(d.get("transcript_path", ""))
except Exception:
    print("")
    print("")
' 2>/dev/null || true)
        HOOK_SESSION_ID=$(printf '%s' "$_hook_fields" | sed -n 1p)
        HOOK_TRANSCRIPT_PATH=$(printf '%s' "$_hook_fields" | sed -n 2p)
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

# ─── LIVENESS_TRACE_AT_TURN_START (cmd_226) ───
# 生存痕跡を「ターンが始まる時」にも書く。
# 従来は stop_hook_inbox.sh（ターンが終わる時）だけが書いていたため、
# **ターンを終えぬほど長く働いている者＝守るべき相手のところにだけ
# 証拠が無い**という逆相関になっていた（cmd_226 実戦初回の誤検知）。
# 加えて /clear のたび session_id とともに transcript のパスが変わる
# ため、ターンを終えるまで痕跡は前セッションの凍ったファイルを
# 指し続けていた（軍師実測 F-4）。この一手で両方塞がる。
#
# 書くのはパスだけでよい。番犬が見るのは指し先の mtime であり、
# そのファイルは Claude Code 自身がターンの最中も追記し続ける
# （実測: ターン内の追記間隔は最大503秒・p99 55秒に対し、
#  閾値 liveness_stall_after_sec は既定1800秒）。
#
# shogun は B-4b の評価対象外（queue/tasks/shogun.yaml が無い）ゆえ
# 書かぬ。stop_hook_inbox.sh の扱いと揃える。
#
# 失敗しても黙って諦める。本hookは exit 0 が絶対契約であり、
# 痕跡が書けぬ場合は読み手側の劣化ガードが「証拠なし＝発火側」へ
# 倒すため、沈黙が沈黙を生むことはない。
if [ -n "$HOOK_TRANSCRIPT_PATH" ] && [ "$AGENT_ID" != "shogun" ]; then
    case "$HOOK_TRANSCRIPT_PATH" in
        /*)
            __TRACE_DIR="${IDLE_FLAG_DIR:-/tmp}"
            __TRACE_TMP="$__TRACE_DIR/.shogun_transcript_${AGENT_ID}.$$"
            if printf '%s\n' "$HOOK_TRANSCRIPT_PATH" > "$__TRACE_TMP" 2>/dev/null; then
                mv -f "$__TRACE_TMP" "$__TRACE_DIR/shogun_transcript_${AGENT_ID}" \
                    2>/dev/null || rm -f "$__TRACE_TMP" 2>/dev/null || true
            fi
            ;;
        *) : ;;   # 相対パスは受理せぬ（読み手も絶対パスのみ受理する）
    esac
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
