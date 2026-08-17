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

# ─── AGENT_ID_RESOLVE_LADDER L3 対応表 (cmd_217 design_1) ───
# stdin JSON の session_id を読み、agent_id への対応表を書く。
# user_prompt_submit_hook.sh の L3 がこの対応表を引く（08-10実測: L1が
# SessionStartでは解決できたがUserPromptSubmitではできなかった回が
# あった——「解決できた者が、できぬ者のために書き置く」構図）。
# stdin は DATA として扱うのみで、中身を実行することは絶対にしない。
# stdin が空・不正JSONでも必ず exit 0 契約を守る（timeoutで包む）。
# 同じstdin JSONからsource（startup/resume/clear/compact）も併せて
# 読み取る（cmd_230 FAKE_BUSY_POST_RESTART_FIX 是正1）——stdinは1回しか
# 読めぬため、session_idとsourceを同時に取り出す。
HOOK_SESSION_ID=""
HOOK_SOURCE=""
if [ ! -t 0 ]; then
    _stdin_json=$(timeout 1 cat 2>/dev/null || true)
    if [ -n "$_stdin_json" ] && command -v python3 &>/dev/null; then
        _stdin_parsed=$(printf '%s' "$_stdin_json" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get("session_id", ""))
    print(d.get("source", ""))
except Exception:
    print("")
    print("")
' 2>/dev/null || true)
        HOOK_SESSION_ID=$(printf '%s\n' "$_stdin_parsed" | sed -n '1p')
        HOOK_SOURCE=$(printf '%s\n' "$_stdin_parsed" | sed -n '2p')
    fi
fi
if [ -n "$HOOK_SESSION_ID" ]; then
    echo "$AGENT_ID" > "${IDLE_FLAG_DIR:-/tmp}/shogun_session_${HOOK_SESSION_ID}" 2>/dev/null || true
fi

LOG_DIR="$(dirname "$0")/../logs"
mkdir -p "$LOG_DIR" || true
echo "[$(date -Iseconds)] $AGENT_ID session_start_hook fired (source=${HOOK_SOURCE:-unknown})" \
    >> "$LOG_DIR/session_start_hook.log" || true

# cmd_230 FAKE_BUSY_POST_RESTART_FIX 是正1（策B・根治）:
# busy印は source が clear/compact の時に限り打つ。この2つは「走って
# いるセッションへ /clear・compaction が撃ち込まれた」事象であり、直後に
# 必ずターンが続く——busy印は正しい。source=startup（CLI起動直後、welcome
# 画面でnudgeを待つ）や resume・未検出・JSON解析失敗では、ターンが続く
# 保証が無い（実測: 2026-08-17 20:52再起動直後、10体中6体がsource=startup
# でbusy印を押され、次のnudgeまで最大27分38秒idleのままbusy扱いされ続けた
# ——queue/reports/gunshi_report.yaml finding_1）。ここで押さずとも、真に
# 繁忙になった瞬間はUserPromptSubmit hookが必ずbusy印を打つため取りこぼしは
# 無い。
case "$HOOK_SOURCE" in
    clear|compact)
        touch "${IDLE_FLAG_DIR:-/tmp}/shogun_busy_${AGENT_ID}" 2>/dev/null || true
        ;;
esac

case "$AGENT_ID" in
    shogun|karo|gunshi)
        # command-layer agents: full Session Start (Step 1-5)
        cat <<EOF
**CRITICAL: Session Start 手順を最優先で実行せよ**

貴殿は **${AGENT_ID}** である。tmux pane から確定的に読み出した事実であり、推測不要。

以下を順番に実行せよ (省略禁止、ユーザ応答/inbox 処理はこの後):

1. \`tmux display-message -t "\$TMUX_PANE" -p '#{@agent_id}'\` で自己識別を再確認
2a. **個別メモリ**（過去の教訓・落とし穴を記した個別ファイル群） — persistent cross-session memory。このファイルを自動読み込みするCLIが、メモリも自動で注入するとは限らない。注入される環境では明示的なReadは不要だが、注入の有無はCLI・実行環境に依存し保証されない。個別メモリはClaude Code私有の領域（\`~/.claude/projects/<作業ディレクトリのslug>/memory/\`）に在り、注入されぬCLIからは実質的に読む術が無い。その環境では2bの台帳が唯一の記憶である
2b. **台帳**（\`memory/SHOGUN_LEDGER.md\`） — 主の契約・裁可・方針・TODOを記した文書。**将軍は毎セッション明示的にReadせよ（CLIを問わず必須）**。自動注入には依存しない
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
