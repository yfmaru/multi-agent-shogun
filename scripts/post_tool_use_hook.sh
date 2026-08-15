#!/usr/bin/env bash
# TURN_LIVENESS_POSTTOOLUSE — PostToolUse hook — busy印 touch (cmd_217 D-2)
#
# 目的:
#   busy印を進める者が「ターン開始」(UserPromptSubmit hook) と
#   「ターン境界」(Stop hook) のみで、ターンの最中を進める者が
#   一人も居らぬことが N-3 の根だった（gunshi_report.yaml design_4）。
#   道具を呼ぶたびにbusy印を進めることで、300秒を超える長いターンでも
#   stale-busy安全網が偽idleへ落とさぬようにする。
#
# 条件(a): これは D-1（inbox_watcher.sh のpane hash不変性AND）の補強で
# あり代替ではない。本hookが未装填でも D-1 単独で強制idle化の誤発火を
# 防ぐ（hook依存の手当てをhook不発の安全網に据えるのは循環になる）。
#
# 条件(b): .claude/settings.json の変更は稼働中セッションへは届かない
# （既知の事実。CLI再起動が要る）。入替をお願いする際はこの旨を明記
# すること。
#
# ups印には触れぬこと。ups印は UserPromptSubmit hook 専用の証跡
# （AC-I4: 触る者がただ一つであることを grep で証明する）。
#
# 契約: 必ず exit 0（他hookと同じ、T-217-11と同型の契約）。全ツール
# 呼び出しのたびに走るため、L2/L3のような重い解決策（tmux list-panes
# 全体走査等）はここでは使わず、TMUX_PANE（L1）のみに留める——
# ホットパスで毎回コストを払わせぬため。

set -uo pipefail

AGENT_ID=""
if [ -n "${TMUX_PANE:-}" ]; then
    AGENT_ID=$(tmux display-message -t "$TMUX_PANE" -p '#{@agent_id}' 2>/dev/null || true)
fi

if [ -z "$AGENT_ID" ]; then
    exit 0
fi

touch "${IDLE_FLAG_DIR:-/tmp}/shogun_busy_${AGENT_ID}" 2>/dev/null || true

exit 0
