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

## Project Management

System manages ALL white-collar work, not just self-improvement. Project folders can be external (outside this repo). `projects/` is git-ignored (contains secrets).

## Detector Blindness (cmd_229)

2026-08-16未明、足軽1号のpaneでモーダルが開いたまま48分間、復旧機構
（stall検知）が一度も気付かなかった。独立した2つの欠陥の同時発生が
原因——(1)モーダル脚注検知3関数の共通バグ (2)常駐inbox_watcher入替の
たびbusy状態がidleへ塗り潰される一般欠陥。以下は是正の配線。

### (a) 共有ヘルパ化 — `agent_status_bottom_block()`

`lib/agent_status.sh`の`agent_is_busy_check()`・`pane_has_open_modal()`・
`pane_awaiting_input()`は、末尾の連続非空ブロックを切り出す同一の
awkロジックを**逐語コピー**で3箇所に持っていた。モーダル脚注の下に
入力行（例: 誤って積まれた`❯ /clear`）が積まれると、`tail -5`基準の
走査窓から脚注そのものが押し出され、**3関数すべてが同時に盲目化**
した——1箇所直しても残り2つが盲目のままという構造的な罠であった。

`agent_status_bottom_block()`へ統合し、3関数は共通ヘルパを呼ぶのみと
した。ヘルパは2段構え:
1. 通常どおり`tail -5`から連続非空ブロックを返す（既存fixtureと
   バイト単位で同一の挙動）。
2. そのブロックが「積まれた入力行」（プロンプト記号+空白+文字、
   `AGENT_STATUS_QUEUED_INPUT_RE`）に一致する場合のみ、より深い窓
   （既定10行、`AGENT_STATUS_DEEP_TAIL`で上書き可）へ潜り、積まれた
   行の**直上**にある連続非空ブロック（＝隠れていた脚注）を返す。

**裸のプロンプト（`❯`のみ）は剥がぬ**——`agent_is_busy_check()`の
`^(❯|›)\s*$`という既存のidle判定と整合させるための意図的な線引きで
あり、これが崩れるとT-MODAL-03（脚注残骸の上に裸プロンプトが在る
検体）が誤ってbusyへ倒れる。

### (b) 三値ゲート — `pane_input_safety()`

検知（(a)）を直しても、送出側にもう一段の穴が残る。旧ゲート
（`pane_has_open_modal`/`pane_awaiting_input`の二値）は「モーダルで
なければ撃つ」というブラックリスト方式であり、**判定できぬ場合
（capture失敗・空画面・未知の画面形状）を『モーダルでない』へ畳んで
撃つ側へ倒していた**。

`pane_input_safety()`は同じ材料から4値を返す
（`safe`/`modal`/`working`/`unknown`）。**claude型paneに対する6つの
Enter注入経路すべて**（`send_cli_command`・`send_startup_prompt`・
`send_context_reset`・`send_wakeup`・`send_wakeup_with_escape`・
stall ladder）が、`claude_pane_may_enter()`（`scripts/inbox_watcher.sh`）
を経由してこのゲートを通る。`safe`/`working`でのみEnterが撃たれ、
`modal`はもちろん**`unknown`（判定不能）でも撃たれない**——ホワイト
リスト化により、未知の画面も判定不能な画面も自動的に「撃たぬ」側へ
落ちる。ゲートの無いキー送出2箇所（idle時のC-uクリーンアップ）にも
同じ判定を掛けてある。

TOCTOU（ゲート検査からEnter送出までの間にモーダルが開き得る隙間）は、
リトライループ内で**各Enter送出の直前に再評価**することで塞いだ。

`unknown`が連続N回（既定5、`stall_policy.unknown_gate_notify_after`で
上書き可）続いた場合は`branch_policy_notify`で主へ一度だけ報せる
（`unknown_gate_track_streak()`）——判定不能で撃てぬ状態が続くこと
自体を「鳴らぬ番犬」にしないための有界化。

非claude型（copilot/kimi等）paneは、本番不在で画面構えを実測できて
おらぬため、従来の二値ゲート（`pane_has_open_modal`/
`pane_awaiting_input`、修正済みヘルパ経由）のまま据え置いた。

### (c) 欠陥2の是正 — `init_turn_state_marks()`

`scripts/inbox_watcher.sh`は起動のたびbusy印/idle印のうちidle印を
**無条件でtouch**していた。CLIの初回起動（welcome画面）では正しいが、
**主のお手による正規の常駐入替**でも同じ関数が走るため、ターン進行
中のagentの真のbusy状態が入替のたび塗り潰され、番犬が盲目化していた
（2026-08-16の事故そのもの）。

`init_turn_state_marks()`は「CLIプロセス自身の起動時刻」と「既存の
busy印/idle印のうち新しい方」を比較し、**CLIが真に新しい時（marksが
1つも無い、またはCLIの起動がmarksより新しい）にのみ**idle印を作る。
それ以外は何もしない（ログのみ）。CLI本体の起動時刻は`ps --ppid
<pane_pid> -o etimes=,comm=`で特定する——**`pane_pid`はpaneの
シェル(bash)であり、CLI本体はその子プロセスである**ことを実測済み
（`switch_cli.sh`によるCLI入替がpane_pidを変えないため、pane_pid
自身のetimesを使う旧案は誤り）。`pgrep`は使わぬ（CLAUDE.md「pgrep
Self-Match Pitfall」——本環境のBashツールのラッパcmdlineへの
自己マッチ）。

CLIプロセスを特定できぬ場合（`ps`失敗等）は**保存側へ縮退**する。
理由は両側の失敗の有界性が非対称なため——保存側の誤りは300秒
stale-busy網が解く（有界）、touch側の誤りは欠陥2の再演で解く者が
居らぬ（無界）。

この修正は**状態を保存するだけで生成せぬ**——busyもidleも新たに
作らず、既にある真実をそのまま残す。既に反転してしまった印
（idle印>busy印）はこの修正だけでは直らない。それでも(a)の修正が
回復経路になる: `stall_busy()`は`agent_turn_state==busy ||
agent_is_busy_check`のORであり、印が反転していても画面側の項が
生きていれば検知は成立する。

### (d) FINDING-B（文書化のみ・未実装）

`scripts/session_start_hook.sh`のコメントは「既存のwatcher起動時
idle印touchと競合しても、本hookのほうが後段（起動→watcher起動より
後にsessionが立ち上がる順）なのでbusy側が勝つのが自然」と述べる。
**この推論は出陣時にのみ真である。** watcherだけを入れ替える時には
SessionStartが起こらず、idle印のtouchが無抵抗で勝つ——(a)/(c)と
同じ型の「観測時にたまたま真だった前提」である。300秒stale-busy網
（unread>0の時）と900秒stall通知が実害の上限を与えるため、本cmdの
射程外・文書化のみとした。

### FINDING-A（未着手・既知の残債）

軍師の設計検討で新たに見つかった、(c)と同型の第4の穴: watcher再起動
は idle印だけでなく、**stall検知の画面凍結時計（900秒）とstale-busy
網の時計（300秒）も、in-memory変数ゆえプロセス入替でゼロへ巻き戻す**。
主が入替をなさるたび、番犬は「今さっき見始めたばかり」になる——
900秒より短い間隔で入替が続けば、stall検知は原理的に一度も成立しない。

推奨修正（`shogun_panehash_<agent>`へ`<hash> <since_epoch>`を永続化し、
hashが一致する時だけsinceを引き継ぐ）は**本cmdでは未実装**である。
本cmdの主目的（欠陥1・欠陥2・AC4のEnter誤射）を最優先し、時間の制約
により見送った。**「時計は直っているはず」という前提を次の検死で
使わぬこと**——AC3（縮退の非可逆性）の「300秒/900秒の上限が在る」
という主張は、この時計が入替のたびゼロへ戻るという事実に照らせば
「入替が300秒/900秒より稀であることに暗黙に依存している」に過ぎない。

### (e) `last_line`規則の死亡（触るな・記録のみ）

`agent_is_busy_check()`冒頭の`last_line`規則（末尾非空行に'esc to'が
在ればbusy）は、**本番のclaude paneに対して既に実質死んでいる**。
実測した9面すべてで末尾非空行は`⏵⏵ bypass permissions on …`であり、
'esc to'を含まない。cmd_220 S-1/S-2がclaude経路を`agent_turn_state`
優先へ切り替え済みで実害は無いが、非claude型フォールバックが依存
している可能性があるため撤去はしていない。「生きているつもりの
死んだ規則」として記録のみ残す。
