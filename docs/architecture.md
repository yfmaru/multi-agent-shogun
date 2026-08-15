# Architecture

cmd_204にてCLAUDE.mdから移設。システムの配線・階層構造を記す常設ドキュメント。

## Delivery Mechanism

Two layers:
1. **Message persistence**: `inbox_write.sh` writes to `queue/inbox/{agent}.yaml` with flock. Guaranteed.
2. **Wake-up signal**: `inbox_watcher.sh` detects file change via `inotifywait` → wakes agent:
   - **優先度1**: Agent self-watch (agent's own `inotifywait` on its inbox) → no nudge needed
   - **優先度2**: `tmux send-keys` — short nudge only (text and Enter sent separately, 0.3s gap)

The nudge is minimal: `inboxN` (e.g. `inbox3` = 3 unread). That's it.
**Agent reads the inbox file itself.** Message content never travels through tmux — only a short wake-up signal.

Special cases (CLI commands sent via `tmux send-keys`):
- `type: clear_command` → sends context reset command via send-keys (Claude/Copilot/Kimi: `/clear`, Codex/OpenCode: `/new`)
- `type: model_switch` → sends the /model command via send-keys

**Escalation** (when nudge is not processed):

| Elapsed | Action | Trigger |
|---------|--------|---------|
| 0〜2 min | Standard pty nudge | Normal delivery |
| 2〜4 min | Escape×2 + recovery nudge | Copilot/Kimi use Escape×2 + Ctrl-C + nudge. Claude/Codex/OpenCode use a plain nudge instead |
| 4 min+ | context reset command 送出（Claude/Copilot/Kimi: `/clear`、Codex/OpenCode: `/new`）(max once per 5 min) | Force session reset + YAML re-read |

## Context Layers

```
Layer 1: 個別メモリ（Claude Codeのファイルメモリ。全Claudeエージェントへ自動注入される） + 台帳（memory/SHOGUN_LEDGER.md。将軍がCLIを問わず毎セッション明示的にRead）
Layer 2: Project files   — persistent per-project (config/, projects/, context/)
Layer 3: YAML Queue      — persistent task data (queue/ — authoritative source of truth)
Layer 4: Session context — volatile (CLAUDE.md auto-loaded, instructions/*.md, lost on context reset)
```

**履歴**: Layer 1はMemory MCPだったが、2026-08-06 cmd_204で不採用とした
（entities 0/relations 0の空の器であり、Claude Codeのファイルメモリと二重化していたため）。

## Liveness Signals (cmd_226)

番犬（`baton_watchdog.sh`）等が「agentが生きているか」を判定する際に使う痕跡は
複数あり、それぞれ書き手・読み手・測るものが異なる。一覧できねば混乱を生むため
（旧設計R-3）、ここへ1つにまとめる。

| 信号 | 書き手 | 読み手 | 何を測るか | 取れぬ時どちらへ倒すか |
|------|--------|--------|-----------|----------------------|
| busy印・idle印 | hook・inbox_watcher | inbox_watcher | ターン状態 | idle寄り |
| pane hash | inbox_watcher(自前) | inbox_watcher | 画面の動き | 判定不能扱い |
| ups印 | UserPromptSubmit hook | session_start | hook武装の有無 | 未武装扱い |
| transcript痕跡 | Claude Code(追記) | baton_watchdog | CLIの活動 | **発火側** |

transcript痕跡は`${IDLE_FLAG_DIR:-/tmp}/shogun_transcript_<agent>`に
transcript(JSONL)の絶対パスを1行のみ書いた印であり、`scripts/stop_hook_inbox.sh`
がAGENT_ID解決直後に毎ターン書き直す。transcript自体を追記するのはClaude Code
自身であって我らのコードではない——**我らが維持せぬ痕跡だけが、我らの不注意で
死なぬ**という設計判断による（cmd_217でbusy印が数時間黙って死んだ教訓）。
`baton_watchdog.sh`の`baton_watchdog_agent_liveness_mtime()`が印→指し先→mtimeを
辿り、取得できなければ「生存の証拠なし」として発火側へ倒す（劣化ガード）。

## Project Management

System manages ALL white-collar work, not just self-improvement. Project folders can be external (outside this repo). `projects/` is git-ignored (contains secrets).
