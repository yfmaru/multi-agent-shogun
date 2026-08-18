#!/usr/bin/env bats
# test_cmd230_fake_busy_fix.bats — FAKE_BUSY_POST_RESTART_FIX
#
# 設計原本: queue/reports/gunshi_report.yaml finding_1/2/3節。
# 2026-08-17 20:52の全CLI立て直し直後、10体中6体が「偽busy」に落ち、
# 家老10分41秒・軍師10分28秒、全軍で計約21分の停止が実測された事象の
# 是正3点をテストする。
#
# テスト構成:
#   T-SSH-SRC-01: session_start_hook.sh は source=clear で busy印を touch する
#   T-SSH-SRC-02: session_start_hook.sh は source=compact で busy印を touch する
#   T-SSH-SRC-03: session_start_hook.sh は source=startup で busy印を touch しない
#   T-SSH-SRC-04: session_start_hook.sh は source=resume で busy印を touch しない
#   T-SSH-SRC-05: source未検出（不正JSON）で busy印を touch しない
#   T-SSH-SRC-06: source未検出（空stdin）で busy印を touch しない
#   TC-TOL-01: init_turn_state_marks — cli_startとnewestが同値(tie)なら
#              idle印がtouchされる（TOL適用の直接効果、finding_1の再現防止）
#   TC-TOL-02: init_turn_state_marks — TOL(2秒)を超えて印がcli_startより
#              古い場合は従来どおりpreserveされる（TOLの限界確認）
#   T-STOP-SHOGUN-IDLE-01: stop_hook_inbox.sh のshogun早期return時に
#              idle印がtouchされる（finding_2(a)）

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SESSION_START_HOOK="$SCRIPT_DIR/scripts/session_start_hook.sh"
WATCHER_SCRIPT="$SCRIPT_DIR/scripts/inbox_watcher.sh"
STOP_HOOK="$SCRIPT_DIR/scripts/stop_hook_inbox.sh"

setup() {
    export IDLE_FLAG_DIR="$(mktemp -d "$BATS_TMPDIR/cmd230_test.XXXXXX")"
}

teardown() {
    rm -rf "$IDLE_FLAG_DIR"
}

# ─── T-SSH-SRC: session_start_hook.sh busy印 source-gating ───

@test "T-SSH-SRC-01: session_start_hook.sh touches busy印 when source=clear" {
    run bash -c "
        tmux() { echo 'srcagent1'; return 0; }
        export -f tmux
        export TMUX_PANE='test:0.0'
        echo '{\"session_id\":\"s1\",\"source\":\"clear\"}' | IDLE_FLAG_DIR='$IDLE_FLAG_DIR' bash '$SESSION_START_HOOK' > /dev/null
    "
    [ "$status" -eq 0 ]
    [ -f "$IDLE_FLAG_DIR/shogun_busy_srcagent1" ] \
        || { echo "expected busy印 to be touched for source=clear"; false; }
}

@test "T-SSH-SRC-02: session_start_hook.sh touches busy印 when source=compact" {
    run bash -c "
        tmux() { echo 'srcagent2'; return 0; }
        export -f tmux
        export TMUX_PANE='test:0.0'
        echo '{\"session_id\":\"s2\",\"source\":\"compact\"}' | IDLE_FLAG_DIR='$IDLE_FLAG_DIR' bash '$SESSION_START_HOOK' > /dev/null
    "
    [ "$status" -eq 0 ]
    [ -f "$IDLE_FLAG_DIR/shogun_busy_srcagent2" ] \
        || { echo "expected busy印 to be touched for source=compact"; false; }
}

@test "T-SSH-SRC-03: session_start_hook.sh does NOT touch busy印 when source=startup (finding_1 root cause)" {
    run bash -c "
        tmux() { echo 'srcagent3'; return 0; }
        export -f tmux
        export TMUX_PANE='test:0.0'
        echo '{\"session_id\":\"s3\",\"source\":\"startup\"}' | IDLE_FLAG_DIR='$IDLE_FLAG_DIR' bash '$SESSION_START_HOOK' > /dev/null
    "
    [ "$status" -eq 0 ]
    [ ! -f "$IDLE_FLAG_DIR/shogun_busy_srcagent3" ] \
        || { echo "busy印 must NOT be touched for source=startup — this was finding_1's root cause (false-busy for up to 27m38s)"; false; }
}

@test "T-SSH-SRC-04: session_start_hook.sh does NOT touch busy印 when source=resume" {
    run bash -c "
        tmux() { echo 'srcagent4'; return 0; }
        export -f tmux
        export TMUX_PANE='test:0.0'
        echo '{\"session_id\":\"s4\",\"source\":\"resume\"}' | IDLE_FLAG_DIR='$IDLE_FLAG_DIR' bash '$SESSION_START_HOOK' > /dev/null
    "
    [ "$status" -eq 0 ]
    [ ! -f "$IDLE_FLAG_DIR/shogun_busy_srcagent4" ] \
        || { echo "busy印 must NOT be touched for source=resume"; false; }
}

@test "T-SSH-SRC-05: session_start_hook.sh does NOT touch busy印 on malformed JSON (source undetected)" {
    run bash -c "
        tmux() { echo 'srcagent5'; return 0; }
        export -f tmux
        export TMUX_PANE='test:0.0'
        echo 'not valid json {{{' | IDLE_FLAG_DIR='$IDLE_FLAG_DIR' bash '$SESSION_START_HOOK' > /dev/null
    "
    [ "$status" -eq 0 ]
    [ ! -f "$IDLE_FLAG_DIR/shogun_busy_srcagent5" ] \
        || { echo "busy印 must NOT be touched when source cannot be determined"; false; }
}

@test "T-SSH-SRC-06: session_start_hook.sh does NOT touch busy印 on empty stdin (source undetected)" {
    run bash -c "
        tmux() { echo 'srcagent6'; return 0; }
        export -f tmux
        export TMUX_PANE='test:0.0'
        IDLE_FLAG_DIR='$IDLE_FLAG_DIR' bash '$SESSION_START_HOOK' < /dev/null > /dev/null
    "
    [ "$status" -eq 0 ]
    [ ! -f "$IDLE_FLAG_DIR/shogun_busy_srcagent6" ] \
        || { echo "busy印 must NOT be touched when stdin is empty"; false; }
}

# ─── TC-TOL: init_turn_state_marks TOL (defense-in-depth) ───
#
# `date` is overridden inside the harness so "now" as seen by
# init_turn_state_marks is a fixed epoch (FIXED_NOW) chosen by the test,
# eliminating second-boundary flakiness when testing single-digit-second
# offsets around TOL=2. The busy印 mtime is likewise pinned to FIXED_NOW
# via `touch -d "@FIXED_NOW"`, so cli_start and newest_mark are both
# exactly controlled.

@test "TC-TOL-01: init_turn_state_marks touches idle印 when cli_start == newest_mark (tie, TOL direct effect)" {
    local FIXED_NOW=2000000000
    local harness="$IDLE_FLAG_DIR/harness_tol01.sh"
    cat > "$harness" << HARNESS
#!/bin/bash
AGENT_ID="tolagent1"
PANE_TARGET="test:0.0"
CLI_TYPE="claude"
SCRIPT_DIR="$SCRIPT_DIR"
export IDLE_FLAG_DIR="$IDLE_FLAG_DIR"
tmux() {
    if echo "\$*" | grep -q "display-message"; then
        echo "99999"
        return 0
    fi
    return 0
}
# etimes=0 → cli_start = FIXED_NOW - 0 = FIXED_NOW = newest_mark (tie)
ps() { echo "0 claude"; }
date() { if [ "\$1" = "+%s" ]; then echo "$FIXED_NOW"; else command date "\$@"; fi; }
timeout() { shift; "\$@"; }
export -f tmux ps date timeout
export __INBOX_WATCHER_TESTING__=1
source "$WATCHER_SCRIPT"
HARNESS
    chmod +x "$harness"

    touch -d "@$FIXED_NOW" "$IDLE_FLAG_DIR/shogun_busy_tolagent1"

    run bash -c "source '$harness' && init_turn_state_marks"
    [ "$status" -eq 0 ] || { echo "init_turn_state_marks should not fail; output: $output"; false; }
    echo "$output" | grep -qF "CLI newer than marks" \
        || { echo "expected the fresh-CLI (idle) log line for a tied mark; output: $output"; false; }
    [ -f "$IDLE_FLAG_DIR/shogun_idle_tolagent1" ] \
        || { echo "idle印 should be created on a tie — this is finding_1's exact false-busy shape (session_start_hook's busy印 mistaken for a live turn)"; false; }
}

@test "TC-TOL-02: init_turn_state_marks preserves marks when cli_start predates newest_mark by more than TOL" {
    local FIXED_NOW=2000000000
    local harness="$IDLE_FLAG_DIR/harness_tol02.sh"
    cat > "$harness" << HARNESS
#!/bin/bash
AGENT_ID="tolagent2"
PANE_TARGET="test:0.0"
CLI_TYPE="claude"
SCRIPT_DIR="$SCRIPT_DIR"
export IDLE_FLAG_DIR="$IDLE_FLAG_DIR"
tmux() {
    if echo "\$*" | grep -q "display-message"; then
        echo "99999"
        return 0
    fi
    return 0
}
# etimes=3 → cli_start = FIXED_NOW - 3, which is 3s older than newest_mark
# (FIXED_NOW) — 1s beyond TOL=2, so preserve side must still win.
ps() { echo "3 claude"; }
date() { if [ "\$1" = "+%s" ]; then echo "$FIXED_NOW"; else command date "\$@"; fi; }
timeout() { shift; "\$@"; }
export -f tmux ps date timeout
export __INBOX_WATCHER_TESTING__=1
source "$WATCHER_SCRIPT"
HARNESS
    chmod +x "$harness"

    touch -d "@$FIXED_NOW" "$IDLE_FLAG_DIR/shogun_busy_tolagent2"

    run bash -c "source '$harness' && init_turn_state_marks"
    [ "$status" -eq 0 ] || { echo "init_turn_state_marks should not fail; output: $output"; false; }
    echo "$output" | grep -qF "Preserving turn-state marks" \
        || { echo "expected the preserve-side log line when the CLI predates the mark by more than TOL; output: $output"; false; }
    [ ! -f "$IDLE_FLAG_DIR/shogun_idle_tolagent2" ] \
        || { echo "idle印 must NOT be created when the gap exceeds TOL — a real running CLI's busy印 would be erased (defect2 replay)"; false; }
}

# ─── T-STOP-SHOGUN-IDLE: stop_hook_inbox.sh shogun early-return idle印 ───

@test "T-STOP-SHOGUN-IDLE-01: stop_hook_inbox.sh touches shogun's idle印 on the early-return path without running block/normal-exit logic" {
    __STOP_HOOK_SCRIPT_DIR="$SCRIPT_DIR" \
    __STOP_HOOK_AGENT_ID="shogun" \
    IDLE_FLAG_DIR="$IDLE_FLAG_DIR" \
    run bash "$STOP_HOOK" <<< '{"stop_hook_active": false, "last_assistant_message": "任務完了"}'

    [ "$status" -eq 0 ]
    [ -z "$output" ] \
        || { echo "shogun early-return must produce no stdout (block/normal-exit JSON logic must not run); output: $output"; false; }
    [ -f "$IDLE_FLAG_DIR/shogun_idle_shogun" ] \
        || { echo "expected idle印 to be touched on shogun's early-return path (finding_2(a)) — otherwise agent_turn_state(\"shogun\") never returns idle after the first busy印"; false; }
}
