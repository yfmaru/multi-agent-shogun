#!/usr/bin/env bats
# test_cmd229_detector_fixes.bats — cmd_229 detector-blindness fix
# (queue/reports/gunshi_report.yaml implementation_ac / test_cases §8-9).
#
# 欠陥1（agent_status_bottom_block の統合＋剥ぎ）と AC-4（三値ゲート
# pane_input_safety）と AC-7（init_turn_state_marks）と AC3 の合流点
# （TC-JOINT-01）をここに置く。既存の T-MODAL-01..04・TC-WAIT-*・
# TC-STALL-* は無改変のまま別ファイルに残す（AC-12）。
#
# fixture の由来: tests/fixtures/cmd_229_ac6a_live_capture.yaml に、
# 実際に本物のClaude Code CLIを起動して採取した経緯（welcome画面・
# AskUserQuestionモーダルは実採取、モーダル+積まれた行は3度の実験で
# 同一フレームに再現できず、既存の合成手法(cmd_209 T-MODAL-01..04)を
# 踏襲して footer部分は実採取バイト列のまま・積まれた行だけ合成した旨）
# を記す。G1/G7/G6 の行番号・awk突き合わせもそこに記載。
#
# テスト構成:
#   TC-PEEL-01: G1（モーダル+積まれた1行）→ 3述語すべてbusy/true
#   TC-PEEL-02: G1から積まれた行を除いたもの → 3述語すべて不変（保存）
#   TC-PEEL-03: G7（モーダル+積まれた複数行の貼り付け）→ 深い窓で3述語すべて拾う
#   TC-PEEL-04: G6（許可確認ダイアログ+積まれたnudge）→ pane_awaiting_input=true
#   TC-GATE-01: G9（空capture）→ unknown
#   TC-GATE-02: G8（'esc to interrupt'）→ working
#   TC-GATE-04: 実採取のwelcome画面 → safe
#   TC-TOCTOU-01: send_wakeupのリトライ内、Enter直前の再評価でmodalへ
#                 転じたら以後のEnterを撃たぬ（未読を消さず抜ける）
#   TC-RESTART-01: init_turn_state_marks — 保存側/初期化側/ps失敗時縮退
#   TC-JOINT-01: 印が反転（idle>busy）＋G1の画面 → stall_busy()が真
#                （AC3が求める「既に縮退した状態からの回復経路」の実体）

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
WATCHER_SCRIPT="$SCRIPT_DIR/scripts/inbox_watcher.sh"

# ═══════════════════════════════════════════════════════════════
# G1/G7/G6 fixture text — see tests/fixtures/cmd_229_ac6a_live_capture.yaml
# for the live-capture provenance and the byte-level awk walkthrough.
# ═══════════════════════════════════════════════════════════════

# G1: real AskUserQuestion modal (byte-identical to the live capture) with
# one queued input line appended below it (synthesized — 3 live attempts to
# reproduce this in a single real capture did not succeed; see fixture doc).
G1_CAPTURE=$'\xe2\x9d\xaf Call the AskUserQuestion tool right now to ask me\n  to pick a color, with options red, blue, and green.\n  Do not do anything else.\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n \xe2\x98\x90 Color\n\nPick a color:\n\n\xe2\x9d\xaf 1. Red\n    Red\n 2. Blue\n    Blue\n 3. Green\n    Green\n 4. Type something.\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n 5. Chat about this\n\nEnter to select \xc2\xb7 \xe2\x86\x91/\xe2\x86\x93 to navigate \xc2\xb7 Esc to cancel\n\n\xe2\x9d\xaf /clear'

# G2: same as G1 but without the queued line (footer is the true bottom).
G2_CAPTURE=$'\xe2\x9d\xaf Call the AskUserQuestion tool right now to ask me\n  to pick a color, with options red, blue, and green.\n  Do not do anything else.\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n \xe2\x98\x90 Color\n\nPick a color:\n\n\xe2\x9d\xaf 1. Red\n    Red\n 2. Blue\n    Blue\n 3. Green\n    Green\n 4. Type something.\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n 5. Chat about this\n\nEnter to select \xc2\xb7 \xe2\x86\x91/\xe2\x86\x93 to navigate \xc2\xb7 Esc to cancel'

# G7: G2 (footer, no queued content) + a DOUBLE blank line + a 4-row
# continuation block (no prompt glyph — a wrapped multi-line paste).
# Two things had to be true for this specimen to earn its keep as a
# mutation-battery guard (both verified by actually reverting the
# corresponding code and confirming red — see git history of this file):
#   - The footer must be pushed to position 7-from-bottom. A single
#     extra queued row (position 4) is NOT enough — tail -5's own
#     window already reaches that. AGENT_STATUS_DEEP_TAIL=10 only
#     matters once the gap is this large (M4).
#   - The blank line immediately below the footer must be DOUBLED, not
#     single. A single blank does not distinguish the deep-scan awk's
#     `if(b!="")prev=b` guard from an unconditional `prev=b` — only a
#     second, immediately-following blank line (which resets b to ""
#     before the unconditional assignment would fire) exposes it (M6,
#     gunshi_report.yaml awk_note).
G7_CAPTURE="${G2_CAPTURE}"$'\n\n\n\xe2\x9d\xaf /clear\n  --force\n  --dry-run\n  --verbose'

# G6: REAL_BUSY_TAIL (same permission-dialog footer captured live for
# cmd_209/cmd_219 — tests/unit/test_liveness_tick.bats) with a queued nudge
# line below it.
G6_CAPTURE=$' Esc to cancel \xc2\xb7 Tab to amend \xc2\xb7 ctrl+e to explain\n\n\xe2\x9d\xaf inbox3'

# G8: busy screen ('esc to interrupt') — TC-GATE-02.
G8_CAPTURE=$'some output line\nmore output\n\xe2\x97\xa6 Working on task (12s \xe2\x80\xa2 esc to interrupt)'

# Welcome screen — real, unmodified live capture (width 54, 2026-08-16).
WELCOME_CAPTURE=$' \xe2\x96\x90\xe2\x96\x9b\xe2\x96\x88\xe2\x96\x88\xe2\x96\x88\xe2\x96\x9c\xe2\x96\x8c   Claude Code v2.1.233\n\xe2\x96\x9d\xe2\x96\x9c\xe2\x96\x88\xe2\x96\x88\xe2\x96\x88\xe2\x96\x88\xe2\x96\x88\xe2\x96\x9b\xe2\x96\x98\xe2\x80\x82 Sonnet 5 \xc2\xb7 Claude Pro\n  \xe2\x96\x98\xe2\x96\x98 \xe2\x96\x9d\xe2\x96\x9d    /mnt/c/tools/multi-agent-shogun\n\n\n\n\n\n\n                                     \xe2\x97\x8f high \xc2\xb7 /effort\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n  \xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on (shift+tab to cycle) \xc2\xb7 \xe2\x86\x90 \xe2\x80\xa6'

# G9: empty capture (indeterminate).
G9_CAPTURE=""

# ═══════════════════════════════════════════════════════════════
# Group A — lib/agent_status.sh direct (agent_status_bottom_block /
# pane_input_safety), mocked tmux, no inbox_watcher.sh harness needed.
# ═══════════════════════════════════════════════════════════════

setup_lib_only() {
    export MOCK_CAPTURE_PANE=""
    # shellcheck disable=SC2317
    tmux() {
        if [[ "$*" == *"capture-pane"* ]]; then
            printf '%s' "$MOCK_CAPTURE_PANE"
            return 0
        fi
        if [[ "$*" == *"display-message"* ]]; then
            return 0  # pane exists
        fi
        return 0
    }
    # shellcheck disable=SC2317
    timeout() { shift; "$@"; }
    export -f tmux timeout
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/lib/agent_status.sh"
}

@test "TC-PEEL-01: G1 (modal footer + 1 queued line) — all 3 predicates detect busy/true" {
    setup_lib_only
    MOCK_CAPTURE_PANE="$G1_CAPTURE"
    run agent_is_busy_check "fake:0.0" claude
    [ "$status" -eq 0 ] || { echo "agent_is_busy_check should be busy (0), got $status"; false; }
    run pane_has_open_modal "fake:0.0"
    [ "$status" -eq 0 ] || { echo "pane_has_open_modal should be true (0), got $status"; false; }
    run pane_awaiting_input "fake:0.0"
    [ "$status" -eq 0 ] || { echo "pane_awaiting_input should be true (0), got $status"; false; }
}

@test "TC-PEEL-02: G2 (same modal, no queued line) — all 3 predicates unchanged (existing detection preserved)" {
    setup_lib_only
    MOCK_CAPTURE_PANE="$G2_CAPTURE"
    run agent_is_busy_check "fake:0.0" claude
    [ "$status" -eq 0 ] || { echo "expected busy without peeling, got $status"; false; }
    run pane_has_open_modal "fake:0.0"
    [ "$status" -eq 0 ] || { echo "expected modal without peeling, got $status"; false; }
    run pane_awaiting_input "fake:0.0"
    [ "$status" -eq 0 ] || { echo "expected awaiting_input without peeling, got $status"; false; }
}

@test "TC-PEEL-03: G7 (modal footer + a multi-row queued paste) — deep window (10) still recovers the footer" {
    setup_lib_only
    MOCK_CAPTURE_PANE="$G7_CAPTURE"
    run agent_is_busy_check "fake:0.0" claude
    [ "$status" -eq 0 ] || { echo "2-line queued input should still be peeled through (AC-3), got $status"; false; }
    run pane_has_open_modal "fake:0.0"
    [ "$status" -eq 0 ] || { echo "expected modal after deep peel, got $status"; false; }
    run pane_awaiting_input "fake:0.0"
    [ "$status" -eq 0 ] || { echo "expected awaiting_input after deep peel, got $status"; false; }
}

@test "TC-PEEL-04: G6 (permission-confirm footer + queued nudge) — pane_awaiting_input recovers it (cmd_219 coverage)" {
    setup_lib_only
    MOCK_CAPTURE_PANE="$G6_CAPTURE"
    run pane_awaiting_input "fake:0.0"
    [ "$status" -eq 0 ] || { echo "REAL_BUSY_TAIL under a queued nudge line should still be awaiting_input, got $status"; false; }
}

@test "TC-GATE-01: G9 (empty capture) — pane_input_safety=unknown (deny), not the old 'not modal' allow" {
    setup_lib_only
    MOCK_CAPTURE_PANE="$G9_CAPTURE"
    run pane_input_safety "fake:0.0"
    [ "$output" = "unknown" ] || { echo "expected unknown for empty capture, got: $output"; false; }
}

@test "TC-GATE-02: G8 ('esc to interrupt') — pane_input_safety=working (Enter allowed, queued not lost)" {
    setup_lib_only
    MOCK_CAPTURE_PANE="$G8_CAPTURE"
    run pane_input_safety "fake:0.0"
    [ "$output" = "working" ] || { echo "expected working for a busy screen, got: $output"; false; }
}

@test "TC-GATE-02b: G1 (modal) — pane_input_safety=modal (Enter denied)" {
    setup_lib_only
    MOCK_CAPTURE_PANE="$G1_CAPTURE"
    run pane_input_safety "fake:0.0"
    [ "$output" = "modal" ] || { echo "expected modal for G1, got: $output"; false; }
}

@test "TC-GATE-04: live-captured welcome screen (width 54) — pane_input_safety=safe (decision_rule_if_welcome_is_unknown satisfied)" {
    setup_lib_only
    MOCK_CAPTURE_PANE="$WELCOME_CAPTURE"
    run pane_input_safety "fake:0.0"
    [ "$output" = "safe" ] || { echo "welcome screen must classify safe or R2 (send_startup_prompt) can never fire; got: $output"; false; }
}

@test "TC-GATE-05: bare idle prompt — pane_input_safety=safe" {
    setup_lib_only
    MOCK_CAPTURE_PANE=$'\xe2\x9d\xaf'
    run pane_input_safety "fake:0.0"
    [ "$output" = "safe" ] || { echo "bare prompt should be safe, got: $output"; false; }
}

@test "TC-GATE-06: queued line with no modal beneath — pane_input_safety=unknown, not safe (rule 4)" {
    setup_lib_only
    MOCK_CAPTURE_PANE=$'\xe2\x9d\xaf /some-command'
    run pane_input_safety "fake:0.0"
    [ "$output" = "unknown" ] || { echo "a queued line by itself (no modal recovered) must stay unknown, got: $output"; false; }
}

# ═══════════════════════════════════════════════════════════════
# Group B — inbox_watcher.sh harness (TC-TOCTOU-01, TC-RESTART-01,
# TC-JOINT-01). Mirrors tests/unit/test_send_wakeup.bats's harness style.
# ═══════════════════════════════════════════════════════════════

setup_file() {
    export PROJECT_ROOT="$SCRIPT_DIR"
    export VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"
    [ -f "$WATCHER_SCRIPT" ] || return 1
    "$VENV_PYTHON" -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/cmd229_test.XXXXXX")"
    export MOCK_LOG="$TEST_TMPDIR/tmux_calls.log"
    > "$MOCK_LOG"
    export TEST_INBOX_DIR="$TEST_TMPDIR/queue/inbox"
    mkdir -p "$TEST_INBOX_DIR"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

@test "TC-GATE-01b: send_wakeup sends no Enter at all when pane_input_safety=unknown (G9, empty capture) — full gate integration, not just the unit-level verdict" {
    local harness="$TEST_TMPDIR/test_harness.sh"
    cat > "$harness" << HARNESS
#!/bin/bash
AGENT_ID="gate01b_agent"
PANE_TARGET="test:0.0"
CLI_TYPE="claude"
INBOX="$TEST_INBOX_DIR/gate01b_agent.yaml"
LOCKFILE="\${INBOX}.lock"
SCRIPT_DIR="$PROJECT_ROOT"
export IDLE_FLAG_DIR="$TEST_TMPDIR"
touch "$TEST_TMPDIR/shogun_idle_gate01b_agent"

tmux() {
    echo "tmux \$*" >> "$MOCK_LOG"
    if echo "\$*" | grep -q "capture-pane"; then
        printf '%s' ""
        return 0
    fi
    if echo "\$*" | grep -q "send-keys"; then
        return 0
    fi
    if echo "\$*" | grep -q "show-options"; then
        echo ""
        return 0
    fi
    if echo "\$*" | grep -q "list-clients"; then
        return 0
    fi
    if echo "\$*" | grep -q "display-message"; then
        echo "mock_session"
        return 0
    fi
    return 0
}
timeout() { shift; "\$@"; }
pgrep() { return 1; }
sleep() { :; }
export -f tmux timeout pgrep sleep

export __INBOX_WATCHER_TESTING__=1
source "$WATCHER_SCRIPT"
HARNESS
    chmod +x "$harness"

    run bash -c "source '$harness' && send_wakeup 1"
    [ "$status" -eq 0 ] || { echo "send_wakeup should still return 0 (daemon-safe); output: $output"; false; }
    echo "$output" | grep -qF "pane_input_safety=unknown" || { echo "expected the gate to log unknown; output: $output"; false; }
    ! grep -qE "send-keys -t test:0\.0 Enter$" "$MOCK_LOG" || { echo "unknown must never be treated as safe — this is the exact hole M7 (the AC-4 mutation battery's core mutation) reopens; log: $(cat "$MOCK_LOG")"; false; }
}

@test "TC-TOCTOU-01: send_wakeup aborts before Enter when the gate flips to modal mid-retry (untouched unread)" {
    local harness="$TEST_TMPDIR/test_harness.sh"
    cat > "$harness" << HARNESS
#!/bin/bash
AGENT_ID="toctou_agent"
PANE_TARGET="test:0.0"
CLI_TYPE="claude"
INBOX="$TEST_INBOX_DIR/toctou_agent.yaml"
LOCKFILE="\${INBOX}.lock"
SCRIPT_DIR="$PROJECT_ROOT"
export IDLE_FLAG_DIR="$TEST_TMPDIR"
touch "$TEST_TMPDIR/shogun_idle_toctou_agent"

MOCK_CAPTURE_INDEX_FILE="$TEST_TMPDIR/capture_index"
echo 0 > "\$MOCK_CAPTURE_INDEX_FILE"
# Sequence: call 1 = outer gate (safe bare prompt), call 2 = TOCTOU
# recheck right before Enter (modal opened in the gap) — clamps at the
# last entry for any further calls.
MOCK_CAPTURE_SEQUENCE=("❯" "$G1_CAPTURE")
tmux() {
    echo "tmux \$*" >> "$MOCK_LOG"
    if echo "\$*" | grep -q "capture-pane"; then
        local idx last
        idx=\$(cat "\$MOCK_CAPTURE_INDEX_FILE")
        last=\$((\${#MOCK_CAPTURE_SEQUENCE[@]} - 1))
        [ "\$idx" -gt "\$last" ] && idx=\$last
        printf '%s' "\${MOCK_CAPTURE_SEQUENCE[\$idx]}"
        echo \$((idx + 1)) > "\$MOCK_CAPTURE_INDEX_FILE"
        return 0
    fi
    if echo "\$*" | grep -q "send-keys"; then
        return 0
    fi
    if echo "\$*" | grep -q "show-options"; then
        echo ""
        return 0
    fi
    if echo "\$*" | grep -q "list-clients"; then
        return 0
    fi
    if echo "\$*" | grep -q "display-message"; then
        echo "mock_session"
        return 0
    fi
    return 0
}
timeout() { shift; "\$@"; }
pgrep() { return 1; }
sleep() { :; }
export -f tmux timeout pgrep sleep

export __INBOX_WATCHER_TESTING__=1
source "$WATCHER_SCRIPT"
HARNESS
    chmod +x "$harness"

    run bash -c "source '$harness' && send_wakeup 1"
    [ "$status" -eq 0 ] || { echo "send_wakeup should still return 0 (daemon-safe); output: $output"; false; }
    echo "$output" | grep -qF "TOCTOU guard" || { echo "expected the TOCTOU abort log line; output: $output"; false; }
    ! grep -qE "send-keys -t test:0\.0 Enter$" "$MOCK_LOG" || { echo "Enter must NOT have been sent once the gate flipped to modal; log: $(cat "$MOCK_LOG")"; false; }
}

@test "AC-6-STREAK: unknown_gate_track_streak notifies exactly once at the threshold, not before, and resets on a non-unknown verdict" {
    local harness="$TEST_TMPDIR/test_harness.sh"
    local ntfy_log="$TEST_TMPDIR/ntfy.log"
    > "$ntfy_log"
    cat > "$harness" << HARNESS
#!/bin/bash
AGENT_ID="streak_agent"
PANE_TARGET="test:0.0"
CLI_TYPE="claude"
SCRIPT_DIR="$PROJECT_ROOT"
export IDLE_FLAG_DIR="$TEST_TMPDIR"
stall_policy_query() { echo "5"; }
branch_policy_notify() { echo "NOTIFY: \$1" >> "$ntfy_log"; return 0; }
export -f stall_policy_query branch_policy_notify
export __INBOX_WATCHER_TESTING__=1
source "$WATCHER_SCRIPT"
HARNESS
    chmod +x "$harness"

    run bash -c "source '$harness'
        for i in 1 2 3 4; do unknown_gate_track_streak unknown; done
        [ -s '$ntfy_log' ] && echo 'NOTIFIED_TOO_EARLY'
        unknown_gate_track_streak unknown
        [ -s '$ntfy_log' ] || echo 'NOT_NOTIFIED_AT_THRESHOLD'
        unknown_gate_track_streak safe
        unknown_gate_track_streak unknown
        unknown_gate_track_streak unknown
        unknown_gate_track_streak unknown
        unknown_gate_track_streak unknown
        unknown_gate_track_streak unknown
        n=\$(grep -c NOTIFY '$ntfy_log')
        echo \"NOTIFY_COUNT=\$n\"
    "
    [ "$status" -eq 0 ] || false
    ! echo "$output" | grep -qF "NOTIFIED_TOO_EARLY" || { echo "must not notify before the 5th consecutive unknown; output: $output"; false; }
    ! echo "$output" | grep -qF "NOT_NOTIFIED_AT_THRESHOLD" || { echo "must notify exactly at the 5th consecutive unknown; output: $output"; false; }
    echo "$output" | grep -qF "NOTIFY_COUNT=2" || { echo "expected exactly 2 notifications total (5th of the first streak + 5th of the second, after a safe verdict reset the counter); output: $output"; false; }
}

@test "TC-RESTART-01a: init_turn_state_marks preserves marks when the CLI predates them (保存側)" {
    local harness="$TEST_TMPDIR/test_harness.sh"
    cat > "$harness" << HARNESS
#!/bin/bash
AGENT_ID="restart_agent"
PANE_TARGET="test:0.0"
CLI_TYPE="claude"
SCRIPT_DIR="$PROJECT_ROOT"
export IDLE_FLAG_DIR="$TEST_TMPDIR"
tmux() {
    if echo "\$*" | grep -q "display-message"; then
        echo "99999"  # fake pane_pid
        return 0
    fi
    return 0
}
ps() {
    # CLI started 500s ago (etimes=500) — OLDER than the marks below (busy印 touched "now").
    echo "500 claude"
}
timeout() { shift; "\$@"; }
export -f tmux ps timeout
export __INBOX_WATCHER_TESTING__=1
source "$WATCHER_SCRIPT"
HARNESS
    chmod +x "$harness"

    touch "$TEST_TMPDIR/shogun_busy_restart_agent"
    local busy_mtime
    busy_mtime=$(stat -c %Y "$TEST_TMPDIR/shogun_busy_restart_agent")

    run bash -c "source '$harness' && init_turn_state_marks"
    [ "$status" -eq 0 ] || { echo "init_turn_state_marks should not fail; output: $output"; false; }
    echo "$output" | grep -qF "Preserving turn-state marks" || { echo "expected the preserve-side log line; output: $output"; false; }
    [ ! -f "$TEST_TMPDIR/shogun_idle_restart_agent" ] || { echo "idle印 must NOT be created — a real running CLI's busy印 would be erased (defect2 replay)"; false; }
    local busy_mtime_after
    busy_mtime_after=$(stat -c %Y "$TEST_TMPDIR/shogun_busy_restart_agent")
    [ "$busy_mtime" = "$busy_mtime_after" ] || { echo "busy印 mtime must not change"; false; }
}

@test "TC-RESTART-01b: init_turn_state_marks creates idle印 when no marks exist at all (初期化側)" {
    local harness="$TEST_TMPDIR/test_harness.sh"
    cat > "$harness" << HARNESS
#!/bin/bash
AGENT_ID="restart_agent2"
PANE_TARGET="test:0.0"
CLI_TYPE="claude"
SCRIPT_DIR="$PROJECT_ROOT"
export IDLE_FLAG_DIR="$TEST_TMPDIR"
tmux() {
    if echo "\$*" | grep -q "display-message"; then
        echo "99999"
        return 0
    fi
    return 0
}
ps() { echo "5 claude"; }
timeout() { shift; "\$@"; }
export -f tmux ps timeout
export __INBOX_WATCHER_TESTING__=1
source "$WATCHER_SCRIPT"
HARNESS
    chmod +x "$harness"

    [ ! -f "$TEST_TMPDIR/shogun_idle_restart_agent2" ]
    [ ! -f "$TEST_TMPDIR/shogun_busy_restart_agent2" ]

    run bash -c "source '$harness' && init_turn_state_marks"
    [ "$status" -eq 0 ] || false
    echo "$output" | grep -qF "no prior marks" || { echo "expected the init-side log line; output: $output"; false; }
    [ -f "$TEST_TMPDIR/shogun_idle_restart_agent2" ] || { echo "idle印 should be created when a pane has never had marks (fresh CLI at welcome screen)"; false; }
}

@test "TC-RESTART-01c: init_turn_state_marks degrades to the preserve side when ps cannot identify the CLI (縮退の向き)" {
    local harness="$TEST_TMPDIR/test_harness.sh"
    cat > "$harness" << HARNESS
#!/bin/bash
AGENT_ID="restart_agent3"
PANE_TARGET="test:0.0"
CLI_TYPE="claude"
SCRIPT_DIR="$PROJECT_ROOT"
export IDLE_FLAG_DIR="$TEST_TMPDIR"
tmux() {
    if echo "\$*" | grep -q "display-message"; then
        echo "99999"
        return 0
    fi
    return 0
}
ps() { return 1; }  # ps failure — CLI cannot be identified
timeout() { shift; "\$@"; }
export -f tmux ps timeout
export __INBOX_WATCHER_TESTING__=1
source "$WATCHER_SCRIPT"
HARNESS
    chmod +x "$harness"

    touch "$TEST_TMPDIR/shogun_busy_restart_agent3"

    run bash -c "source '$harness' && init_turn_state_marks"
    [ "$status" -eq 0 ] || false
    echo "$output" | grep -qF "Preserving turn-state marks" || { echo "ps failure must degrade to the preserve side (bounded failure), not touch-side (unbounded); output: $output"; false; }
    [ ! -f "$TEST_TMPDIR/shogun_idle_restart_agent3" ] || { echo "idle印 must not be created when the CLI cannot be identified"; false; }
}

@test "TC-JOINT-01: stall_busy() is true when marks are inverted (idle>busy) AND the screen shows G1 (AC3 recovery path)" {
    local harness="$TEST_TMPDIR/test_harness.sh"
    cat > "$harness" << HARNESS
#!/bin/bash
AGENT_ID="joint_agent"
PANE_TARGET="test:0.0"
CLI_TYPE="claude"
SCRIPT_DIR="$PROJECT_ROOT"
export IDLE_FLAG_DIR="$TEST_TMPDIR"
tmux() {
    if echo "\$*" | grep -q "capture-pane"; then
        printf '%s' "$G1_CAPTURE"
        return 0
    fi
    if echo "\$*" | grep -q "show-options"; then
        echo "claude"
        return 0
    fi
    if echo "\$*" | grep -q "display-message"; then
        echo "mock_session"
        return 0
    fi
    return 0
}
timeout() { shift; "\$@"; }
export -f tmux timeout
export __INBOX_WATCHER_TESTING__=1
source "$WATCHER_SCRIPT"
HARNESS
    chmod +x "$harness"

    # Inverted marks: idle印 newer than busy印 — agent_turn_state() reports idle.
    touch -d "10 seconds ago" "$TEST_TMPDIR/shogun_busy_joint_agent"
    touch "$TEST_TMPDIR/shogun_idle_joint_agent"

    run bash -c "source '$harness' && stall_busy"
    [ "$status" -eq 0 ] || { echo "stall_busy must still report busy via the screen-side OR term even though marks are inverted; output: $output"; false; }
}
