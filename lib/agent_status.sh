#!/usr/bin/env bash
# lib/agent_status.sh — エージェント稼働状態検出の共有ライブラリ
#
# 提供関数:
#   agent_is_busy_check <pane_target> [cli_type]              → 0=busy, 1=idle, 2=pane不在
#   get_pane_busy_rc <pane_target> [cli_type] [agent_id]       → 0=busy, 1=idle, 2=pane不在
#     (claude型はagent_turn_state優先・幅非依存。cmd_220 S-2)
#   get_pane_state_label <pane_target>                         → "稼働中" / "待機中" / "不在"
#
# 使用例:
#   source lib/agent_status.sh
#   agent_is_busy_check "multiagent:agents.0"
#   state=$(get_pane_state_label "multiagent:agents.3")

# ─── agent_status_bottom_block: shared bottom-block scanner (cmd_229 AC-1/2/3) ───
# agent_is_busy_check() / pane_has_open_modal() / pane_awaiting_input() used
# to each carry their own verbatim copy of
#   awk 'NF{b=b $0} !NF{b=""} END{print b}'
# — three independent copies of the same footer-scanning logic. When a
# queued input line (e.g. an accidentally-sent `❯ /clear`) landed BELOW a
# modal's footer, that copy's 5-line tail scan lost the footer text
# entirely and all three predicates went blind at once (cmd_229 RCA:
# 2026-08-16, 48-minute stall detector blackout). Consolidating into this
# single function makes "fix all three" structural — no call site defines
# its own scanning awk anymore; all three now call this one function.
#
# AGENT_STATUS_QUEUED_INPUT_RE matches a prompt glyph followed by queued
# TEXT (`❯ /clear`). It deliberately does NOT match a bare prompt (`❯`
# alone, or `❯ ` with only trailing whitespace) — lib/agent_status.sh:147's
# idle check already treats a bare prompt as the explicit idle marker, and
# peeling on a bare prompt would make T-MODAL-03 (footer residue above a
# bare bottom prompt) false-busy. This is not an arbitrary choice; it is
# this file's existing idle definition, extended rather than overridden.
AGENT_STATUS_QUEUED_INPUT_RE='^[[:space:]]*[❯>›][[:space:]]+[^[:space:]]'
AGENT_STATUS_DEEP_TAIL=${AGENT_STATUS_DEEP_TAIL:-10}

# agent_status_bottom_block <full_capture>
# Returns (stdout) the bottom contiguous non-empty block to run anchor
# checks against.
#
# Branch 1 (unpeeled): tail -5, same as every predicate did before this
# consolidation. Byte-for-byte identical to the pre-cmd_229 output on every
# existing fixture — this is an addition, not a behavior change, for the
# common case.
#
# Branch 2 (peeled): only taken when branch 1's block itself looks like a
# queued input line. Scans a deeper window (AGENT_STATUS_DEEP_TAIL, default
# 10 lines — a queued line taking 2 rows can push the real footer past
# tail -5) and returns the contiguous non-empty block ABOVE the queued
# line, i.e. the footer that was hidden underneath it.
#
# awk_note (this exact form is load-bearing, see gunshi_report.yaml
# defect1_design.awk_note): branch 2's awk is NOT the same shape as branch
# 1's. It stashes the last non-empty accumulated block into `prev` BEFORE
# resetting on a blank line (`!NF{if(b!="")prev=b; b=""}`), so a run of
# several blank lines between the footer and the queued line does not wipe
# `prev`. The END guard `if(b!="" && prev=="")prev=b` covers the case where
# the deep window contains no blank line at all (footer and queued line are
# adjacent). Dropping either piece loses the footer on a 2-line queued
# fixture (measured: G7 in gunshi_report.yaml).
agent_status_bottom_block() {
    local full="$1" b
    b=$(printf '%s\n' "$full" | tail -5 \
        | awk 'NF{b=b $0} !NF{b=""} END{print b}')

    if ! printf '%s\n' "$b" | grep -qE "$AGENT_STATUS_QUEUED_INPUT_RE"; then
        printf '%s\n' "$b"
        return
    fi

    printf '%s\n' "$full" | tail -"$AGENT_STATUS_DEEP_TAIL" \
        | awk 'NF{b=b $0} !NF{if(b!="")prev=b; b=""} END{if(b!="" && prev=="")prev=b; print prev}'
}

# agent_is_busy_check <pane_target> [cli_type]
# tmux paneの末尾5行からCLI固有のidle/busyパターンを検出する。
# Returns: 0=busy, 1=idle, 2=pane不在
#
# Detection strategy:
#   1. OpenCode special-case: animated status row (`[■⬝]{8}`) = busy; if that
#      row is absent, fall back to the bottom status line's interrupt hint.
#   2. Status bar check (last non-empty line): 'esc to' only appears in
#      Claude Code's status bar during active processing. This is the most
#      reliable busy signal — immune to old spinner text in scroll-back.
#   3. Idle checks: CLI-specific idle prompts (❯, Codex ? prompt)
#   4. Text-based busy markers: spinner keywords in bottom 5 lines
#
# Why this order matters:
#   - Claude Code shows ❯ prompt even during thinking/working, so idle
#     checks alone cause false-idle (the bug that broke is_busy).
#   - Old spinner text (e.g. "Working on task • esc to interrupt") lingers
#     in scroll-back, so checking all 5 lines for 'esc to' causes false-busy
#     (the bug T-BUSY-008 fixed). Solution: check ONLY the last line for
#     'esc to' — the status bar is always at the bottom.
agent_is_busy_check() {
    local pane_target="$1"
    local cli_type="${2:-}"
    local pane_tail

    # Pane existence check — independent of capture-pane result.
    # capture-pane on a TUI app (e.g. Claude Code) often returns only trailing
    # blank lines when pane height > visible content, making pane_tail empty
    # even when the pane exists and is healthy. Use display-message instead.
    if ! tmux display-message -t "$pane_target" -p '#{pane_id}' &>/dev/null; then
        return 2  # pane truly absent
    fi

    # capture-pane -p outputs the full pane height including trailing blank lines.
    # Piping directly to `tail -5` captures those blank lines → empty result.
    # Fix: store in a variable first so command-substitution strips trailing newlines,
    # then pipe to tail.
    if [[ -z "$cli_type" ]]; then
        cli_type=$(timeout 2 tmux show-options -v -p -t "$pane_target" @agent_cli 2>/dev/null || true)
    fi

    local full_capture
    full_capture=$(timeout 2 tmux capture-pane -t "$pane_target" -p -J 2>/dev/null)
    # Only check the bottom 5 lines by default. Old busy markers linger in
    # scroll-back and cause false-busy if we scan too many lines.
    pane_tail=$(echo "$full_capture" | tail -5)

    # OpenCode uses a different layout from Codex/Claude. When the pane is
    # blank, treat it as idle so the watcher can recover instead of holding the
    # agent in permanent busy state after a crash or failed render. When the TUI
    # is visible, prefer the busy animation row and then the interrupt hint.
    if [[ "$cli_type" == "opencode" ]]; then
        local opencode_visible opencode_last_line
        opencode_visible=$(printf '%s\n' "$full_capture" | grep -v '^[[:space:]]*$' || true)
        if [[ -z "$opencode_visible" ]]; then
            return 1
        fi
        if opencode_has_busy_animation "$opencode_visible"; then
            return 0
        fi
        opencode_last_line=$(printf '%s\n' "$opencode_visible" | tail -1)
        if echo "$opencode_last_line" | grep -qiE '(^|[[:space:]])esc([[:space:]]+to)?[[:space:]]+interrupt([[:space:]]|$)'; then
            return 0
        fi
        return 1
    fi

    if [[ "$cli_type" == "cursor" ]]; then
        # Cursor: "ctrl+c to stop" appears in TUI only during active processing
        if echo "$pane_tail" | grep -qiF 'ctrl+c to stop'; then
            return 0  # busy
        fi
        # Idle markers: initial prompt or post-response prompt
        if echo "$pane_tail" | grep -qE '(Plan, search, build anything|Add a follow-up)'; then
            return 1  # idle
        fi
        return 1  # default idle
    fi

    # Pane exists but capture is empty → treat as idle, not absent
    if [[ -z "$pane_tail" ]]; then
        return 1
    fi

    # ── Status bar check (last non-empty line = most reliable) ──
    # Claude Code status bar appends 'esc to interrupt' (or truncated 'esc to…')
    # ONLY during active processing. When idle, this suffix disappears.
    # Checking only the last line avoids false-busy from old spinner text
    # that might still be visible in the bottom 5 lines (T-BUSY-008 scenario).
    # capture-pane -J (above) re-joins lines tmux wrapped at the terminal
    # width, so a status bar footer split by a narrow pane (e.g. "Esc to" /
    # "cancel" at 44 columns) lands back on one line before this check runs.
    # Without -J, the trailing fragment alone ("cancel") doesn't contain
    # 'esc to' and the busy signal is missed (cmd_209 P-2 live bug).
    local last_line
    last_line=$(echo "$pane_tail" | grep -v '^[[:space:]]*$' | tail -1)
    if echo "$last_line" | grep -qiF 'esc to'; then
        return 0  # busy — status bar confirms active processing
    fi

    # ── Modal footer check (cmd_209 AC2 / v5) ──
    # Claude Code paints its TUI with absolute cursor positioning, so a modal
    # footer wider than the pane is split by the APP itself, not by tmux.
    # -J only rejoins rows tmux itself wrapped, so the footer stays split and
    # the last non-empty row ("cancel") carries no 'esc to' — the check above
    # misses it. Measured blind band: pane widths 39-50 (footer is 51 cols);
    # production ashigaru3-7/gunshi panes are 44 (queue/reports/
    # gunshi_design_209_v5_redesign.yaml M-2/M-3).
    #
    # Live-verified 2026-08-08 by opening a real AskUserQuestion modal in an
    # isolated width-44 tmux pane (subtask_209_v5_modal_footer_fix Step 0):
    # the footer renders as its own bottom-most contiguous non-empty block —
    # separated from the option list above it by exactly one blank line —
    # and no other UI element (e.g. the idle-time permission hint row) is
    # present while the modal is open. Rejoin that bottom block with NO
    # separator (a terminal wrap inserts none; a space would split
    # "Esc t"+"o cancel" back apart at widths 39-43) and look for a
    # modal-footer anchor in it. These anchor strings never occur in spinner
    # text, so T-BUSY-008's false-busy scenario stays unreachable and the
    # last-line rule above is untouched.
    local bottom_block
    bottom_block=$(agent_status_bottom_block "$full_capture")
    if echo "$bottom_block" | grep -qiE 'enter to select|to navigate|↑/↓'; then
        return 0  # busy — an interactive modal is waiting for input
    fi

    # ── Idle checks ──
    # Codex idle prompt
    if echo "$pane_tail" | grep -qE '(\? for shortcuts|context left)'; then
        return 1
    fi
    # Claude Code bare prompt
    if echo "$pane_tail" | grep -qE '^(❯|›)\s*$'; then
        return 1
    fi

    # ── Text-based busy markers (bottom 5 lines) ──
    # These catch non-Claude-Code CLIs and edge cases where status bar
    # isn't present but spinner text indicates active work.
    if echo "$pane_tail" | grep -qiF 'background terminal running'; then
        return 0
    fi

    # cmd_220 S-3 SPINNER_VOCAB_FALLBACK_KEPT: このリポジトリの
    # .claude/settings.json はspinnerVerbsをmode:replaceでカスタム語彙
    # 1001件へ置き換えており、下記の英語/日本語スピナー語（Working/
    # Thinking/思考中…）はclaude型に対して一致0件で実測済み
    # （gunshi_design_220_pane_width_busy_scope §second_blind_spot）。
    # 軍師の設計は「S-1/S-2でclaude経路はagent_turn_stateを優先するため
    # 残る利用者は非claude型(本番不在)のみ」として撤去を推奨したが、
    # 実測するとこの前提は半分しか成り立たない——本ブロックには
    # 'Compacting conversation'等、Codex自身がハードコードで出す文言も
    # 混在しており、これは.claude/settings.jsonのspinnerVerbsとは無関係
    # （claudeの語彙置換の影響を受けない）。既存テスト
    # tests/unit/test_send_wakeup.bats T-BUSY-010（CLI_TYPE=codex,
    # 'Compacting conversation'をbusy検出）が現にこれへ依存しており、
    # 撤去すると非claude型フォールバックへ新たな誤idle面を開いてしまう
    # （AC4が禁じる面）。ゆえに(c)現状維持を選ぶ。claude型にとって死んで
    # いる事実は変わらないが、それはS-1/S-2がclaude型をagent_turn_state
    # 優先へ切り替え済みで実害が無いためであり、非claude型の実害を承知で
    # 撤去する理由には成り得ないと判断した。
    if echo "$pane_tail" | grep -qiE '(Working|Thinking|Planning|Sending|task is in progress|Compacting conversation|thought for|思考中|考え中|計画中|送信中|処理中|実行中)'; then
        return 0
    fi

    return 1  # idle (default)
}

# pane_has_open_modal <pane_target>
# agent_is_busy_check() 内のモーダル脚注アンカー検査部分のみを切り出した
# 狭い専用述語。Enter送出直前の最終ゲートとして使うことを目的とする
# （cmd_209 subtask_209_modal_gate_fix）。
# Returns: 0=モーダル表示中, 1=それ以外（pane不在を含む）
#
# なぜagent_is_busy_check()全体を使わぬか: busy全体をゲートに使うと、
# spinner残骸や描画揺れで一瞬busyに転んだだけでEnter送出が恒久停止し、
# フラグ方式が元々恐れていたデッドロックを配送経路へ持ち込む。モーダル
# 脚注アンカーはspinner文には出現しないため、この述語に絞ることで
# T-BUSY-008の誤busy面を再び開かない。
#
# cmd_216 F-4: claude初回起動時のフォルダ信頼ダイアログ（脚注 "Enter to
# confirm · Esc to cancel"）は上記アンカーのいずれにも一致せず、この述語
# だけが当該ダイアログを見落としていた（agent_is_busy_check()側は末尾行の
# 'esc to'規則で別途busyと拾えている）。'enter to confirm'を追加して塞ぐ。
# 両関数の脚注検査は「同等ロジックの二重定義」のままであり、片方だけ
# 広げた本コミットにより乖離が残る——統合は別cmdの範囲（cmd_216スコープ外）。
pane_has_open_modal() {
    local pane_target="$1"

    if ! tmux display-message -t "$pane_target" -p '#{pane_id}' &>/dev/null; then
        return 1  # pane不在はモーダル表示中ではない
    fi

    local full_capture pane_tail
    full_capture=$(timeout 2 tmux capture-pane -t "$pane_target" -p -J 2>/dev/null)
    pane_tail=$(echo "$full_capture" | tail -5)

    if [[ -z "$pane_tail" ]]; then
        return 1
    fi

    local bottom_block
    bottom_block=$(agent_status_bottom_block "$full_capture")
    if echo "$bottom_block" | grep -qiE 'enter to select|to navigate|↑/↓|enter to confirm'; then
        return 0  # モーダル表示中
    fi

    return 1
}

# pane_awaiting_input <pane_target>
# cmd_219 STALL_AWAITING_INPUT_GATE: 「この画面はキー入力を待っている」と
# 積極的に名指しできるかを判定する。attempt_stall_recovery() の鍵注入
# 直前ゲートとして使うことを目的とする
# （queue/reports/gunshi_design_219_stall_wait_budget_conflict.yaml §2(b)）。
# Returns: 0=入力待ちと名指しできる, 1=それ以外（pane不在を含む）
#
# pane_has_open_modal の流用では足りぬ——許可確認ダイアログの実採取フッタ
# ' Esc to cancel · Tab to amend · ctrl+e to explain'
# （tests/unit/test_liveness_tick.bats:171 REAL_BUSY_TAIL）を
# pane_has_open_modal のどのアンカーも拾えない。stall検知は「待って良い
# 時間」を一切見ず「その画面が何であるか」だけを見るため、この述語は
# pane_has_open_modal より広い（許可ダイアログ含む）が、繁忙中の画面
# （'esc to interrupt' が末尾にある）は明示的に除外する。
#
# 判定順（設計§2(b)を厳守。除外規則が最優先）:
#   1. 末尾ブロックに 'esc to interrupt' が在れば無条件 false
#      （「働いている」印。他のアンカーと同時に現れても false を優先する）
#   2. 次に以下いずれかが在れば true:
#      enter to select | to navigate | ↑/↓ | enter to confirm
#      | esc to cancel | tab to amend
#   3. どちらも無ければ false
pane_awaiting_input() {
    local pane_target="$1"

    if ! tmux display-message -t "$pane_target" -p '#{pane_id}' &>/dev/null; then
        return 1  # pane不在は入力待ちではない
    fi

    local full_capture pane_tail
    full_capture=$(timeout 2 tmux capture-pane -t "$pane_target" -p -J 2>/dev/null)
    pane_tail=$(echo "$full_capture" | tail -5)

    if [[ -z "$pane_tail" ]]; then
        return 1
    fi

    local bottom_block
    bottom_block=$(agent_status_bottom_block "$full_capture")

    if echo "$bottom_block" | grep -qiE 'esc to interrupt'; then
        return 1  # 働いている印。入力待ちではない（除外規則、最優先）
    fi

    if echo "$bottom_block" | grep -qiE 'enter to select|to navigate|↑/↓|enter to confirm|esc to cancel|tab to amend'; then
        return 0  # 入力待ちと名指しできる
    fi

    return 1
}

# pane_input_safety <pane_target>
# cmd_229 AC-4 (単独不合格条件, ENTER_REQUIRES_POSITIVE_SAFE_SCREEN):
# 「モーダルでなければ撃つ」（ブラックリスト）から「安全な入力欄だと
# 名指しできる時だけ撃つ」（ホワイトリスト）への反転。
# claude型paneに対するEnter送出経路6つ（R1〜R6、scripts/inbox_watcher.sh）
# は全てこの関数の判定を通す。呼び手は safe/working のときだけEnterを
# 送出すること。非claude型paneは対象外（本番不在で画面構えを実測でき
# ておらぬため — queue/reports/gunshi_report.yaml ac4_analysis
# scope_of_strict_gate）。
#
# なぜ二値ではなく四値か: 二値（modal/not-modal）は「判定できぬ」を
# 「モーダルでない」へ畳んで撃つ側へ倒す。それが3つの残存経路を生んだ
# （P1: capture失敗・空画面の畳み込み、P2: TOCTOU、P3: 未知の画面形状は
# ブラックリストで尽くせぬ）。四値化しホワイトリストへ反転すれば、
# 「判定できぬ」も「未知の画面」も自動的に撃たぬ側へ落ちる。
#
# 標準出力へ4値のいずれかを書く（返り値ではない — 三値以上を返り値の
# 数値では素直に表せぬため、agent_turn_state と同じ様式に合わせる）:
#   safe     … 通常の入力欄が見えている。Enter可
#   modal    … 入力待ちと名指しできる。Enter不可
#   working  … 'esc to interrupt' が在る＝働いている。Enter可（テキストは
#              queueされEnterは失われる。既存の意図どおりの挙動）
#   unknown  … いずれとも名指しできぬ。Enter不可
#
# 判定順（queue/reports/gunshi_report.yaml ac4_analysis.recommended_design.
# classification_rules を厳守。除外規則が最優先——pane_awaiting_input と
# 同じ規律）:
#   1. tail5 が空白のみ → unknown（capture失敗・再描画中。pane不在も
#      ここに含む）
#   2. 剥ぎ済み末尾ブロック（agent_status_bottom_block）に 'esc to
#      interrupt' が在れば working（アンカーと同時に現れても working
#      優先）
#   3. 次に剥ぎ済み末尾ブロックに await系アンカーが在れば modal
#   4. tail5（未剥ぎ・生の5行）に「文字を伴う入力行」（積まれた入力）が
#      在れば unknown — 剥いだ結果その下にモーダルが無くとも、何かが
#      積まれていること自体が「素の入力欄ではない」印である
#   5. tail5 に裸の入力行、または安全ヒントが在れば safe
#   6. それ以外は unknown
#
# anchor_note: 安全ヒントのアンカーは `bypass permissions on` とせよ。
# `(shift+tab to cycle)` を含めてはならぬ——幅49の足軽6号・7号では実測で
# `(shift+tab to      ·` と切り詰められ `cycle` が消える
# （gunshi_report.yaml §7 実測表）。
pane_input_safety() {
    local pane_target="$1"

    if ! tmux display-message -t "$pane_target" -p '#{pane_id}' &>/dev/null; then
        echo "unknown"  # pane不在。撃たぬ側へ倒す
        return
    fi

    local full_capture pane_tail
    full_capture=$(timeout 2 tmux capture-pane -t "$pane_target" -p -J 2>/dev/null)
    pane_tail=$(echo "$full_capture" | tail -5)

    if [[ -z "$pane_tail" ]]; then
        echo "unknown"  # capture失敗・再描画中（P1）
        return
    fi

    local bottom_block
    bottom_block=$(agent_status_bottom_block "$full_capture")

    if echo "$bottom_block" | grep -qiE 'esc to interrupt'; then
        echo "working"
        return
    fi

    if echo "$bottom_block" | grep -qiE 'enter to select|to navigate|↑/↓|enter to confirm|esc to cancel|tab to amend'; then
        echo "modal"
        return
    fi

    if echo "$pane_tail" | grep -qE "$AGENT_STATUS_QUEUED_INPUT_RE"; then
        echo "unknown"  # 何かが積まれている＝素の入力欄ではない
        return
    fi

    if echo "$pane_tail" | grep -qE '^[[:space:]]*[❯›][[:space:]]*$' \
        || echo "$pane_tail" | grep -qiF 'bypass permissions on' \
        || echo "$pane_tail" | grep -qE '(\? for shortcuts|context left)'; then
        echo "safe"
        return
    fi

    echo "unknown"  # 未知の画面形状（P3）。撃たぬ側へ倒す
}

# opencode_has_busy_animation <capture_text>
# OpenCode paneの busy animation (`[■⬝]{8}`) を検出する。
opencode_has_busy_animation() {
    local capture_text="$1"

    if command -v python3 &>/dev/null; then
        OPENCODE_CAPTURE_TEXT="$capture_text" python3 - <<'PY'
import os
import sys

text = os.environ.get("OPENCODE_CAPTURE_TEXT", "")
for line in text.splitlines():
    glyphs = "".join(ch for ch in line if ch in "■⬝")
    if len(glyphs) >= 8:
        sys.exit(0)
sys.exit(1)
PY
        return $?
    fi

    local line
    while IFS= read -r line; do
        # Python is preferred for Unicode handling.  This shell fallback keeps
        # the same contract: any OpenCode spinner line with at least eight
        # busy-animation glyphs is busy, regardless of the current frame.
        if [[ "$line" =~ ([■⬝].*){8} ]]; then
            return 0
        fi
    done <<< "$capture_text"
    return 1
}

# agent_turn_state <agent_id>
# cmd_217: busy/idle を画面から推し量るのをやめ、CLI自身が知っている
# 出来事（ターンの開始・終了）を2つのタイムスタンプファイル（busy印・
# idle印）の新旧mtime比較で読む。
#   busy := mtime(busy印) >= mtime(idle印)      （busy印が在る時）
#   idle := busy印が存在せぬ、または mtime(idle印) > mtime(busy印)
# 同秒同着は busy 側に倒す（安全側 — 送出を控える方が安全）。
# busy印が一度も生まれておらぬ（＝ UserPromptSubmit hook 未装填）場合は
# idle へ静かに縮退する（フラグ方式で「flagが常在＝実質常にidle」だった
# 現状と同一の姿であり、退行しない。装填検査は呼び手 (inbox_watcher.sh)
# の責務）。
#
# 標準出力に "busy" または "idle" を書く（返り値ではない）。既存の
# agent_is_busy_check の 0/1/2 三値と紛らわしくならぬよう、意図的に
# 別名・別インターフェースとする。
#
# 幅依存の実測（§1-3, gunshi_design_217_idle_flag_liveness.yaml）:
# pane解析による busy 判定（agent_is_busy_check 上記）は pane 幅44
# （本リポでは軍師・足軽3〜7号）で繁忙時にも idle と誤判定する
# （末尾行の 'esc to' 判定の土台となるヒント行がアプリ側の切り詰めで
# 現れない）。本関数は pane テキストを一切参照しないため、この幅依存
# 欠陥の影響を受けない。
agent_turn_state() {
    local agent_id="$1"
    local flag_dir="${IDLE_FLAG_DIR:-/tmp}"
    local busy_flag="${flag_dir}/shogun_busy_${agent_id}"
    local idle_flag="${flag_dir}/shogun_idle_${agent_id}"

    if [ ! -f "$busy_flag" ]; then
        echo "idle"
        return
    fi

    local mtime_busy mtime_idle
    mtime_busy=$(stat -c %Y "$busy_flag" 2>/dev/null || echo 0)
    if [ -f "$idle_flag" ]; then
        mtime_idle=$(stat -c %Y "$idle_flag" 2>/dev/null || echo 0)
    else
        mtime_idle=-1
    fi

    if [ "$mtime_busy" -ge "$mtime_idle" ]; then
        echo "busy"
    else
        echo "idle"
    fi
}

# get_pane_busy_rc <pane_target> [cli_type] [agent_id]
# cli_type/agent_idは呼び手が既に持っていれば渡してtmux呼び出しを省ける
# （省略時はここで解決する）。
#
# cmd_220 S-2 GET_PANE_BUSY_RC_TURN_STATE: 従来はagent_is_busy_check()の
# pane解析（幅44で末尾行'esc to'規則が壊れる）だけに拠っており、幅44の
# 6体は繁忙中でも常に「待機中」と表示されていた
# （gunshi_design_220_pane_width_busy_scope §scope_findings Q3(a)）。
# claude型かつagent_idが解決できた場合はagent_turn_state（幅非依存）を
# 優先し、取れなければ従来経路（agent_is_busy_check）へ落とす。
# 「不在」(rc=2)の判定は引き続きtmux display-messageに拠る——
# busy印/idle印のmtimeはpaneの不在を表現できない。
# Returns: 0=busy, 1=idle, 2=pane不在
get_pane_busy_rc() {
    local pane_target="$1"
    local cli_type="${2:-}"
    local agent_id="${3:-}"

    if [[ -z "$cli_type" ]]; then
        cli_type=$(timeout 2 tmux show-options -v -p -t "$pane_target" @agent_cli 2>/dev/null || true)
    fi

    if [[ "$cli_type" == "claude" ]]; then
        if [[ -z "$agent_id" ]]; then
            agent_id=$(timeout 2 tmux display-message -t "$pane_target" -p '#{@agent_id}' 2>/dev/null || true)
        fi
        if [[ -n "$agent_id" ]]; then
            if ! tmux display-message -t "$pane_target" -p '#{pane_id}' &>/dev/null; then
                return 2
            fi
            if [[ "$(agent_turn_state "$agent_id")" == "busy" ]]; then
                return 0
            fi
            # cmd_243 AC2: hook装填済みなら turn_state の idle は信用してよい。
            # pane解析へ落ちるのは装填の証拠が1つも無い時だけとする
            # （cmd_220 F-1 が残した理由＝縮退時の沈黙回避、をそのまま
            #  条件に写したもの）。装填済みで落ちると、ターンが死んで
            #  凍った画面の 'esc to interrupt' を読んで表示層だけが
            #  「稼働中」と言い続ける（cmd_243 §B-2）。
            local _fd="${IDLE_FLAG_DIR:-/tmp}"
            if [ -f "${_fd}/shogun_ups_${agent_id}" ] || [ -f "${_fd}/shogun_busy_${agent_id}" ]; then
                return 1
            fi
            # else は置かない（装填の証拠が無い場合）。hook未装填で
            # turn_stateが常にidleへ縮退しても表示層が沈黙せぬよう、
            # agent_is_busy_check へ落とす（S-1と同形。gunshi_qc_220_pr103 F-1 是正）。
        fi
    fi

    agent_is_busy_check "$pane_target" "$cli_type"
}

# get_pane_state_label <pane_target>
# 人間が読めるラベルを返す。get_pane_busy_rc()の薄いラッパ。
get_pane_state_label() {
    local pane_target="$1"
    get_pane_busy_rc "$pane_target"
    local rc=$?
    case $rc in
        0) echo "稼働中" ;;
        1) echo "待機中" ;;
        2) echo "不在" ;;
    esac
}
