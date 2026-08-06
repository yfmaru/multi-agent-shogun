#!/usr/bin/env bash
# SessionStart hook — 起動/resume//clear/compact 全経路で Session Start 手順を確定的に注入
#
# 公式仕様 (hooks-guide.md):
#   - matcher: startup / resume / clear / compact (全 matcher で発火させる)
#   - stdout の plain text は additionalContext として Claude の context に注入される
#   - exit 0 で正常終了。失敗しても black hole にならぬよう set -e は使わず graceful degrade
#
# 本 hook の目的:
#   shutsujin_departure.sh の STEP 6.7 (起動時 inbox broadcast) 廃止 (commit 485ab9f, 2026-02-08)
#   以降、起動時に Session Start が発火せず、persona 未確立で「自己紹介して」に対し
#   全エージェントが「我は将軍」と誤認する事故が発生 (2026-04-19)。
#   SessionStart hook で確定的に Session Start 手順を注入し、/clear・compaction も同時カバーする。
#
# Note: ashigaru5(Codex CLI), ashigaru6(Codex CLI) は Claude Code hook 対象外。
# この hook は Claude Code セッションのみで発火する。
# Codex CLI 環境では TMUX_PANE が設定されても @agent_id が未設定のため
# silent exit となり、ログも残らない（正常動作）。

set -uo pipefail

AGENT_ID=""
if [ -n "${TMUX_PANE:-}" ]; then
    AGENT_ID=$(tmux display-message -t "$TMUX_PANE" -p '#{@agent_id}' 2>/dev/null || true)
fi

# @agent_id 未設定 (= multi-agent 環境外の個人 Claude Code) → silent exit で干渉せぬ
if [ -z "$AGENT_ID" ]; then
    exit 0
fi

LOG_DIR="$(dirname "$0")/../logs"
mkdir -p "$LOG_DIR" || true
echo "[$(date -Iseconds)] $AGENT_ID session_start_hook fired" \
    >> "$LOG_DIR/session_start_hook.log" || true

case "$AGENT_ID" in
    shogun|karo|gunshi)
        # command-layer agents: full Session Start (Step 1-5)
        cat <<EOF
**CRITICAL: Session Start 手順を最優先で実行せよ**

貴殿は **${AGENT_ID}** である。tmux pane から確定的に読み出した事実であり、推測不要。

以下を順番に実行せよ (省略禁止、ユーザ応答/inbox 処理はこの後):

1. \`tmux display-message -t "\$TMUX_PANE" -p '#{@agent_id}'\` で自己識別を再確認
2. \`memory/MEMORY.md\` — Claude Code 使用時は全エージェントのセッションへ自動注入されるため明示的な Read は不要。他CLI（Codex/OpenCode/Kimi 等）では自動注入されぬため、将軍のみ明示的に Read せよ
3. \`instructions/${AGENT_ID}.md\` を最後まで必読 — persona・戦国口調・forbidden_actions 再確立 **(絶対省略禁止)**
4. \`queue/\` 配下 (tasks/, inbox/, reports/) から state 再構築

**Step 1-3 完了まで inbox 処理・ユーザ応答は禁止**。inbox{N} nudge が先に届いても無視し、persona 確立を優先せよ。

Rationale: 2026-04-18 に家老が「我は将軍」と役職誤認する persona 崩壊事例あり。
command-layer agent は persona + 戦国口調 + forbidden_actions の再確立が必須。

なお、本メッセージは SessionStart hook (scripts/session_start_hook.sh) が
tmux pane の @agent_id を読み出して生成したものであり、推測や混同の余地はない。
EOF
        ;;
    ashigaru*)
        # worker agents: /clear Recovery (ashigaru only) 準拠の軽量手順
        cat <<EOF
**CRITICAL: Session Start 手順を最優先で実行せよ**

貴殿は **${AGENT_ID}** である。tmux pane から確定的に読み出した事実。

足軽用軽量手順 (CLAUDE.md「/clear Recovery (ashigaru only)」準拠):

1. \`queue/tasks/${AGENT_ID}.yaml\` を Read
   - status=assigned かつ work → タスク実行
   - idle → 待機
   - done → 待機 (再報告禁止)
2. タスクに \`project:\` があれば \`context/{project}.md\` を Read
3. タスクに \`target_path:\` があれば対象ファイルを Read
4. Step 1-3 完了後にタスク着手

**Step 1-2 完了まで inbox 処理・ユーザ応答は禁止**。
初回起動時は CLAUDE.md 自動ロード済み、instructions/ashigaru.md の再読は不要 (コスト節約)。

本メッセージは SessionStart hook (scripts/session_start_hook.sh) が
tmux pane の @agent_id を読み出して生成したものであり、推測や混同の余地はない。
EOF
        ;;
    *)
        cat <<EOF
**Session Start**: agent_id=${AGENT_ID}。CLAUDE.md の Session Start 手順に従い自己の instructions/*.md を読み込め。
EOF
        ;;
esac

exit 0
