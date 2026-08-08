#!/usr/bin/env bats
# test_liveness_tick.bats — cmd_218: stall detection reachability + notify
# escalation (queue/reports/gunshi_design_209_stall_unread_deadlock.yaml).
#
# Background: attempt_stall_recovery() used to be reachable only from inside
# process_unread()'s unread==0 else-branch, behind three stacked gates (G1
# fast-path early-return, G2 unread>0 if-branch, G3 busy return) — the oldest
# (2026-02-10) predates stall detection itself. The watcher's only periodic
# clock (30s timeout tick) never reached it during steady-state idle: 8 days,
# zero [STALL] log lines. Fix (案C): liveness_tick() runs on its own
# wall-clock timer from the main loop, independent of process_unread()
# entirely.
#
# Harness style mirrors tests/unit/test_stall_detect.bats: sources the REAL
# inbox_watcher.sh with __INBOX_WATCHER_TESTING__=1, mocks tmux/pgrep/
# stall_policy_query/usage_limit_state/branch_policy_notify. No real tmux
# pane or process is ever touched.
#
# テスト構成:
#   TC-REACH-001: periodic timeout tick, unread=0 (S1 regression) — process_
#                 unread() itself no longer reaches stall detection; liveness_
#                 tick() does, independent of it (AC-1)
#   TC-REACH-002: unread>0 + pane stalled (S4/S5 regression) — liveness_tick
#                 reaches stall detection regardless of unread count (G2)
#   TC-REACH-003: liveness_tick_and_defer's one-tick-defer contract (SE-2):
#                 rc=1 (continue) the tick the ladder acted, rc=0 otherwise
#   TC-REACH-004: liveness_tick itself is throttled by LIVENESS_MIN_INTERVAL
#                 (no double-fire within the same tick's re-entry)
#   TC-NTFY-001: stall_notify_after_attempts unresponsive-path escalation —
#                fires once at the threshold, resets when pane moves
#   TC-NTFY-002: usage_limited streak escalation, gated at the same
#                stall_retry_cooldown_sec cadence as the ladder path
#   TC-NTFY-003: notify never fires twice in one episode (STALL_NTFY_SENT)

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
WATCHER_SCRIPT="$SCRIPT_DIR/scripts/inbox_watcher.sh"

setup_file() {
    export PROJECT_ROOT="$SCRIPT_DIR"
    export VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"
    [ -f "$WATCHER_SCRIPT" ] || return 1
    "$VENV_PYTHON" -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/liveness_tick_test.XXXXXX")"

    export MOCK_LOG="$TEST_TMPDIR/tmux_calls.log"
    > "$MOCK_LOG"
    export NTFY_LOG="$TEST_TMPDIR/ntfy_calls.log"
    > "$NTFY_LOG"

    export MOCK_PGREP="$TEST_TMPDIR/mock_pgrep"
    cat > "$MOCK_PGREP" << 'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$MOCK_PGREP"

    export TEST_INBOX_DIR="$TEST_TMPDIR/queue/inbox"
    mkdir -p "$TEST_INBOX_DIR"

    export MOCK_CAPTURE_PANE=""
    export MOCK_SENDKEYS_RC=0
    export MOCK_PANE_CLI=""
    export MOCK_PANE_ACTIVE="0"
    export MOCK_LIST_CLIENTS=""

    export MOCK_STALL_ENABLED="true"
    export MOCK_STALL_AFTER_SEC="480"
    export MOCK_STALL_COOLDOWN="600"
    export MOCK_RECOVERY_LEVEL="full"
    export MOCK_UNKNOWN_POLICY="escape_only"
    export MOCK_USAGE_STATE="ok"
    export MOCK_STALL_NOTIFY_AFTER="3"

    export TEST_HARNESS="$TEST_TMPDIR/test_harness.sh"
    cat > "$TEST_HARNESS" << HARNESS
#!/bin/bash
AGENT_ID="ashigaru9"
PANE_TARGET="test:0.0"
CLI_TYPE="claude"
INBOX="$TEST_INBOX_DIR/test_agent.yaml"
LOCKFILE="\${INBOX}.lock"
SCRIPT_DIR="$PROJECT_ROOT"
export IDLE_FLAG_DIR="$TEST_TMPDIR"

MOCK_CAPTURE_SEQUENCE=()
MOCK_CAPTURE_INDEX_FILE="$TEST_TMPDIR/mock_capture_index"
echo 0 > "\$MOCK_CAPTURE_INDEX_FILE"
tmux() {
    echo "tmux \$*" >> "$MOCK_LOG"
    if echo "\$*" | grep -q "capture-pane"; then
        if [ "\${#MOCK_CAPTURE_SEQUENCE[@]}" -gt 0 ]; then
            local idx
            idx=\$(cat "\$MOCK_CAPTURE_INDEX_FILE" 2>/dev/null || echo 0)
            local last=\$((\${#MOCK_CAPTURE_SEQUENCE[@]} - 1))
            [ "\$idx" -gt "\$last" ] && idx=\$last
            echo "\${MOCK_CAPTURE_SEQUENCE[\$idx]}"
            echo \$((idx + 1)) > "\$MOCK_CAPTURE_INDEX_FILE"
        elif echo "\$*" | grep -q -- "-J" && [ "\${MOCK_CAPTURE_PANE_JOINED+x}" = "x" ]; then
            echo "\${MOCK_CAPTURE_PANE_JOINED}"
        else
            echo "\${MOCK_CAPTURE_PANE:-}"
        fi
        return 0
    fi
    if echo "\$*" | grep -q "send-keys"; then
        return \${MOCK_SENDKEYS_RC:-0}
    fi
    if echo "\$*" | grep -q "show-options"; then
        echo "\${MOCK_PANE_CLI:-}"
        return 0
    fi
    if echo "\$*" | grep -q "list-clients"; then
        [ -n "\${MOCK_LIST_CLIENTS:-}" ] && echo "\$MOCK_LIST_CLIENTS"
        return 0
    fi
    if echo "\$*" | grep -q "display-message"; then
        if echo "\$*" | grep -q "pane_active"; then
            echo "\${MOCK_PANE_ACTIVE:-0}"
        else
            echo "mock_session"
        fi
        return 0
    fi
    return 0
}
timeout() { shift; "\$@"; }
pgrep() { "$MOCK_PGREP" "\$@"; }
sleep() { :; }
export -f tmux timeout pgrep sleep

# Mock stall_policy_query — pre-defining this means lib/stall_policy.sh is
# never sourced, so tests never touch a real config/settings.yaml.
stall_policy_query() {
    case "\$1" in
        enabled) echo "\${MOCK_STALL_ENABLED:-true}" ;;
        stall_after_sec) echo "\${MOCK_STALL_AFTER_SEC:-480}" ;;
        stall_retry_cooldown_sec) echo "\${MOCK_STALL_COOLDOWN:-600}" ;;
        recovery_level) echo "\${MOCK_RECOVERY_LEVEL:-full}" ;;
        unknown_policy) echo "\${MOCK_UNKNOWN_POLICY:-escape_only}" ;;
        stall_notify_after_attempts) echo "\${MOCK_STALL_NOTIFY_AFTER:-3}" ;;
        *) echo "" ;;
    esac
}
export -f stall_policy_query

usage_limit_state() { echo "\${MOCK_USAGE_STATE:-ok}"; }
export -f usage_limit_state

# Mock branch_policy_notify — pre-defining this means lib/branch_policy.sh's
# real ntfy-sending body is never invoked; tests observe calls via NTFY_LOG.
branch_policy_notify() {
    echo "NOTIFY: \$1" >> "$NTFY_LOG"
    return 0
}
export -f branch_policy_notify

export __INBOX_WATCHER_TESTING__=1
source "$WATCHER_SCRIPT"
HARNESS
    chmod +x "$TEST_HARNESS"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# REAL_BUSY_TAIL: same fixture as test_stall_detect.bats (cmd_209 P-2 Step 0).
REAL_BUSY_TAIL=' Esc to cancel · Tab to amend · ctrl+e to explain'

seed_stalled_hash() {
    local content="$1"
    local age="${2:-500}"
    printf 'STALL_HASH=$(printf %%s %q | cksum | awk "{print \\$1}")\n' "$content"
    printf 'STALL_HASH_SINCE=$(( $(date +%%s) - %d ))\n' "$age"
}

# ─── TC-REACH-001: periodic timeout tick, unread=0 (S1 regression) ───

@test "TC-REACH-001: liveness_tick reaches stall recovery on a periodic timeout tick with unread=0, independent of process_unread" {
    run bash -c "
        MOCK_CAPTURE_PANE='$REAL_BUSY_TAIL'
        source '$TEST_HARNESS'
        $(seed_stalled_hash "$REAL_BUSY_TAIL" 500)
        FIRST_UNREAD_SEEN=0

        # S1 exactly: process_unread's own periodic timeout tick, unread=0.
        # AC-1: this must NOT be what reaches stall detection any more —
        # that responsibility moved to liveness_tick entirely.
        process_unread timeout
        grep -q 'send-keys.*Escape' '$MOCK_LOG' && { echo 'FAIL: process_unread must not itself trigger stall recovery'; cat '$MOCK_LOG'; exit 1; }

        LIVENESS_LAST_TS=0
        liveness_tick
        grep -q 'send-keys.*Escape.*Escape' '$MOCK_LOG' || { echo 'FAIL: liveness_tick did not reach stall recovery'; cat '$MOCK_LOG'; exit 1; }
        echo PASS
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "PASS"
}

# ─── TC-REACH-002: unread>0 + pane stalled (S4/S5 regression) ───

@test "TC-REACH-002: liveness_tick reaches stall recovery even with unread>0 (G2 regression)" {
    run bash -c "
        MOCK_CAPTURE_PANE='$REAL_BUSY_TAIL'
        source '$TEST_HARNESS'
        cat > \"\$INBOX\" << 'YAML'
messages:
  - id: msg_1
    from: karo
    timestamp: \"2026-08-09T00:00:00+09:00\"
    type: task_assigned
    content: hi
    read: false
  - id: msg_2
    from: karo
    timestamp: \"2026-08-09T00:00:01+09:00\"
    type: task_assigned
    content: hi again
    read: false
YAML
        $(seed_stalled_hash "$REAL_BUSY_TAIL" 500)
        LIVENESS_LAST_TS=0
        liveness_tick
        grep -q 'send-keys.*Escape.*Escape' '$MOCK_LOG' || { echo 'FAIL: liveness_tick did not reach stall recovery with unread>0'; cat '$MOCK_LOG'; exit 1; }
        echo PASS
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "PASS"
}

# ─── TC-REACH-003: liveness_tick_and_defer one-tick-defer contract (SE-2) ───

@test "TC-REACH-003: liveness_tick_and_defer returns 1 (defer) the tick the ladder acted, 0 otherwise" {
    run bash -c "
        MOCK_CAPTURE_PANE='$REAL_BUSY_TAIL'
        source '$TEST_HARNESS'
        $(seed_stalled_hash "$REAL_BUSY_TAIL" 500)

        LIVENESS_LAST_TS=0
        if liveness_tick_and_defer; then
            echo 'FAIL: expected rc=1 (defer) on the tick the ladder acted'
            exit 1
        fi
        [ \"\${STALL_ACTION_TAKEN:-0}\" = \"0\" ] || { echo 'FAIL: STALL_ACTION_TAKEN must be consumed (reset to 0)'; exit 1; }

        # Next call: within cooldown/min-interval, no action taken -> rc=0.
        if ! liveness_tick_and_defer; then
            echo 'FAIL: expected rc=0 (proceed) when the ladder does not act'
            exit 1
        fi
        echo PASS
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "PASS"
}

# ─── TC-REACH-004: LIVENESS_MIN_INTERVAL throttles liveness_tick itself ───

@test "TC-REACH-004: liveness_tick no-ops when called again before LIVENESS_MIN_INTERVAL elapses" {
    run bash -c "
        MOCK_CAPTURE_PANE='$REAL_BUSY_TAIL'
        source '$TEST_HARNESS'
        $(seed_stalled_hash "$REAL_BUSY_TAIL" 500)
        type liveness_tick >/dev/null 2>&1 || { echo 'FAIL: liveness_tick is not defined'; exit 1; }

        LIVENESS_LAST_TS=\$(date +%s)
        liveness_tick
        grep -q 'send-keys' '$MOCK_LOG' && { echo 'FAIL: liveness_tick fired before LIVENESS_MIN_INTERVAL elapsed'; cat '$MOCK_LOG'; exit 1; }
        echo PASS
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "PASS"
}

# ─── TC-NTFY-001: unresponsive-path escalation fires once at threshold ───

@test "TC-NTFY-001: branch_policy_notify fires once after stall_notify_after_attempts unresponsive attempts, resets when pane moves" {
    run bash -c "
        MOCK_STALL_NOTIFY_AFTER=3
        MOCK_STALL_COOLDOWN=1
        MOCK_RECOVERY_LEVEL=escape_only
        source '$TEST_HARNESS'
        MOCK_CAPTURE_PANE='$REAL_BUSY_TAIL'
        $(seed_stalled_hash "$REAL_BUSY_TAIL" 500)

        # 3 separate stalled attempts, each past the (1s) cooldown.
        for i in 1 2 3; do
            STALL_ACTED_AT=0
            attempt_stall_recovery
        done
        [ \"\$(grep -c NOTIFY: '$NTFY_LOG')\" -eq 1 ] || { echo 'FAIL: expected exactly 1 notify after 3 attempts'; cat '$NTFY_LOG'; exit 1; }
        grep -q 'unresponsive' '$NTFY_LOG' || { echo 'FAIL: notify message missing unresponsive kind'; cat '$NTFY_LOG'; exit 1; }

        # A 4th attempt must NOT re-notify (STALL_NTFY_SENT one-shot).
        STALL_ACTED_AT=0
        attempt_stall_recovery
        [ \"\$(grep -c NOTIFY: '$NTFY_LOG')\" -eq 1 ] || { echo 'FAIL: notify fired again within the same episode'; cat '$NTFY_LOG'; exit 1; }

        # Pane moves (idle-looking, no busy marker) -> is_stalled_pane=false
        # -> counters and STALL_NTFY_SENT reset.
        MOCK_CAPTURE_PANE='idle screen, no busy marker'
        attempt_stall_recovery
        [ \"\$STALL_UNRESPONSIVE_ATTEMPTS\" -eq 0 ] || { echo 'FAIL: STALL_UNRESPONSIVE_ATTEMPTS not reset after pane moved'; exit 1; }
        [ \"\$STALL_NTFY_SENT\" -eq 0 ] || { echo 'FAIL: STALL_NTFY_SENT not reset after pane moved'; exit 1; }
        echo PASS
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "PASS"
}

# ─── TC-NTFY-002: usage_limited streak, gated at stall_retry_cooldown_sec cadence ───

@test "TC-NTFY-002: usage_limited streak advances once per cooldown window, not once per call" {
    run bash -c "
        MOCK_STALL_NOTIFY_AFTER=2
        MOCK_STALL_COOLDOWN=99999
        MOCK_USAGE_STATE=limited
        source '$TEST_HARNESS'
        MOCK_CAPTURE_PANE='$REAL_BUSY_TAIL'
        $(seed_stalled_hash "$REAL_BUSY_TAIL" 500)

        # First call seeds STALL_USAGE_LIMITED_LAST — counts as attempt #1.
        attempt_stall_recovery
        [ \"\$STALL_USAGE_LIMITED_STREAK\" -eq 1 ] || { echo 'FAIL: expected streak=1 after first usage_limited call'; exit 1; }

        # Immediate re-call within the (huge) cooldown window must NOT advance
        # the streak again — this is the guard against a 20s liveness_tick
        # cadence reaching the notify threshold in under two minutes.
        attempt_stall_recovery
        [ \"\$STALL_USAGE_LIMITED_STREAK\" -eq 1 ] || { echo 'FAIL: streak advanced again within the cooldown window'; exit 1; }
        [ \"\$(grep -c NOTIFY: '$NTFY_LOG')\" -eq 0 ] || { echo 'FAIL: notify should not have fired yet (threshold=2, streak=1)'; cat '$NTFY_LOG'; exit 1; }

        # Force the cooldown to have elapsed -> streak advances to 2 -> notify.
        STALL_USAGE_LIMITED_LAST=0
        attempt_stall_recovery
        [ \"\$STALL_USAGE_LIMITED_STREAK\" -eq 2 ] || { echo 'FAIL: expected streak=2 once cooldown elapsed'; exit 1; }
        [ \"\$(grep -c NOTIFY: '$NTFY_LOG')\" -eq 1 ] || { echo 'FAIL: expected exactly 1 notify at streak=threshold'; cat '$NTFY_LOG'; exit 1; }
        grep -q 'usage_limited' '$NTFY_LOG' || { echo 'FAIL: notify message missing usage_limited kind'; cat '$NTFY_LOG'; exit 1; }
        echo PASS
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "PASS"
}

# ─── TC-NTFY-003: notify never fires twice within one episode ───

@test "TC-NTFY-003: notify does not re-fire across mixed unresponsive/usage_limited calls in the same episode" {
    run bash -c "
        MOCK_STALL_NOTIFY_AFTER=1
        MOCK_STALL_COOLDOWN=1
        source '$TEST_HARNESS'
        MOCK_CAPTURE_PANE='$REAL_BUSY_TAIL'
        $(seed_stalled_hash "$REAL_BUSY_TAIL" 500)

        MOCK_RECOVERY_LEVEL=escape_only
        MOCK_USAGE_STATE=ok
        STALL_ACTED_AT=0
        attempt_stall_recovery
        [ \"\$(grep -c NOTIFY: '$NTFY_LOG')\" -eq 1 ] || { echo 'FAIL: expected first notify from unresponsive path'; cat '$NTFY_LOG'; exit 1; }

        MOCK_USAGE_STATE=limited
        STALL_USAGE_LIMITED_LAST=0
        attempt_stall_recovery
        [ \"\$(grep -c NOTIFY: '$NTFY_LOG')\" -eq 1 ] || { echo 'FAIL: notify re-fired via a different kind within the same episode'; cat '$NTFY_LOG'; exit 1; }
        echo PASS
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "PASS"
}
