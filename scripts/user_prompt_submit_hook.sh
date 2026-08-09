#!/usr/bin/env bash
# UserPromptSubmit hook — busy印 touch (cmd_217 二枚の印方式)
#
# 目的:
#   busy/idle をpaneの見た目から推し量るのをやめ、CLI自身が知っている
#   出来事（ターンの開始）を busy印 の mtime として記録する。ターンの
#   開始とは「nudge・主の入力が実際に読み込まれてターンが始まった瞬間」
#   であり、UserPromptSubmit がその一次情報である。
#   詳細設計: queue/reports/gunshi_design_217_idle_flag_liveness.yaml
#
# 契約: 必ず exit 0。tmux不在・@agent_id取得失敗・touch失敗、いずれの
# 場合も非0で終了してはならない。hookの非0終了はプロンプト投入自体を
# 壊す（全軍が同時に壊れる型の事故。T-217-11）。
#
# Usage: 登録は .claude/settings.json の hooks.UserPromptSubmit から。
#   Claude Code が発火時に stdin へJSONを渡すが、本hookは中身を読まぬ
#   （busy印のtouchに入力は不要）。

set -uo pipefail

LOG_DIR="$(dirname "$0")/../logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true

AGENT_ID=""
if [ -n "${TMUX_PANE:-}" ]; then
    AGENT_ID=$(tmux display-message -t "$TMUX_PANE" -p '#{@agent_id}' 2>/dev/null || true)
fi

if [ -z "$AGENT_ID" ]; then
    # tmux不在 or @agent_id未設定（multi-agent環境外の個人利用等）。
    # §7-2緩和: 黙って exit 0 するが、原因追跡用に1行だけログへ残す。
    echo "[$(date -Iseconds)] user_prompt_submit_hook: AGENT_ID unresolved (TMUX_PANE=${TMUX_PANE:-<unset>}) — skipping busy touch" \
        >> "$LOG_DIR/hook_user_prompt_submit.log" 2>/dev/null || true
    exit 0
fi

touch "${IDLE_FLAG_DIR:-/tmp}/shogun_busy_${AGENT_ID}" 2>/dev/null || true

exit 0
