#!/usr/bin/env bats
# test_stall_detect.bats — type-A stall detection + escalation ladder (cmd_171/T1)
# Sources the REAL inbox_watcher.sh with __INBOX_WATCHER_TESTING__=1 to test
# actual production functions (is_stalled_pane, attempt_stall_recovery) with
# mocked externals (tmux, pgrep, stall_policy_query, usage_limit_state).
#
# This mirrors the tests/unit/test_send_wakeup.bats harness style: tmux is a
# shell function, no real tmux/pane is ever touched. This structurally avoids
# the cmd_168 self-referential FAIL (the runner's own live tmux busy state
# leaking into the assertions).
#
# cmd_209 P-2: is_stalled_pane()'s busy check now goes through stall_busy(),
# which for claude calls agent_is_busy_check() (real pane-text analysis) —
# not the idle flag file used by agent_is_busy(). Tests that need the busy
# branch use REAL_BUSY_TAIL, the literal last line captured from a genuinely
# stalled Claude Code permission-dialog pane (Step 0 実測, 2026-08-06,
# ashigaru3): `agent_is_busy_check <verify-pane> claude` returned rc=0 with
# this exact tail -5 output ending in "Esc to cancel · Tab to amend ·
# ctrl+e to explain" (the generic 'esc to' match, not the "esc to interrupt"
# spinner it was originally designed for).
#
# テスト構成:
#   TC-STALL-001: busy + pane hash unchanged for threshold → stalled
#   TC-STALL-002: pane content changes every sample → never stalled (誤爆防止)
#   TC-STALL-003: pane shows no busy marker (idle-looking) → not stalled
#   TC-STALL-004: pane active + client attached (Gate 0) → no action at all
#   TC-STALL-005: capture-pane empty → indeterminate, not stalled
#   TC-STALL-006: stall_policy.enabled=false → attempt_stall_recovery no-ops
#   TC-STALL-007: pane moves mid-ladder → later steps (nudge/clear) not sent
#   TC-STALL-008: retry cooldown → no repeat action
#   TC-STALL-009: agent_is_busy_check invokes capture-pane with -J (cmd_209
#                 P-2 livebug fix, argument-level check independent of the
#                 mock's blind spot — V-1)
#   TC-STALL-010: is_stalled_pane detects busy on a terminal-wrapped modal
#                 footer once -J re-joins it (cmd_209 P-2 livebug fix — V-2)
#   TC-STALL-011: is_stalled_pane stays idle when the -J-joined capture still
#                 lacks the 'esc to' marker (negative case recording the bug
#                 itself — V-2)
#   TC-USAGE-001: usage_state=limited → no send-keys at all
#   TC-USAGE-002: usage_state=unknown, unknown_policy=escape_only → Escape only
#   TC-USAGE-003: usage_state=unknown, unknown_policy=none → nothing sent
#   TC-USAGE-004: usage_state=ok → full ladder (Escape -> nudge -> /clear)
#   TC-USAGE-007: usage_limit_state returning "limited" (e.g. via pane-text
#                 fallback) is honored identically regardless of source
#   TC-CL-001: AGENT_ID=shogun/karo/gunshi → no keys sent at all (cmd_209
#              P-2 role guard, mitigation 3 — stricter than the old
#              "Escape ok, /clear forbidden" behavior)

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
WATCHER_SCRIPT="$SCRIPT_DIR/scripts/inbox_watcher.sh"

setup_file() {
    export PROJECT_ROOT="$SCRIPT_DIR"
    export VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"
    [ -f "$WATCHER_SCRIPT" ] || return 1
    "$VENV_PYTHON" -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/stall_detect_test.XXXXXX")"

    export MOCK_LOG="$TEST_TMPDIR/tmux_calls.log"
    > "$MOCK_LOG"

    export MOCK_PGREP="$TEST_TMPDIR/mock_pgrep"
    cat > "$MOCK_PGREP" << 'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$MOCK_PGREP"

    export TEST_INBOX_DIR="$TEST_TMPDIR/queue/inbox"
    mkdir -p "$TEST_INBOX_DIR"

    # Default mock control variables
    export MOCK_CAPTURE_PANE=""
    export MOCK_SENDKEYS_RC=0
    export MOCK_PANE_CLI=""
    export MOCK_PANE_ACTIVE="0"
    export MOCK_LIST_CLIENTS=""

    # Default stall_policy mocks (overridden per-test as needed)
    export MOCK_STALL_ENABLED="true"
    export MOCK_STALL_AFTER_SEC="480"
    export MOCK_STALL_COOLDOWN="600"
    export MOCK_RECOVERY_LEVEL="full"
    export MOCK_UNKNOWN_POLICY="escape_only"
    export MOCK_USAGE_STATE="ok"

    export TEST_HARNESS="$TEST_TMPDIR/test_harness.sh"
    cat > "$TEST_HARNESS" << HARNESS
#!/bin/bash
# Variables required by inbox_watcher.sh functions
# cmd_209 P-2: attempt_stall_recovery now returns immediately for any
# AGENT_ID not matching ^ashigaru[0-9]+\$ (role guard, mitigation 3).
# Ladder-mechanics tests need an ashigaru-shaped id to pass that guard;
# TC-CL-001 overrides this per-agent to exercise the guard itself.
AGENT_ID="ashigaru9"
PANE_TARGET="test:0.0"
CLI_TYPE="claude"
INBOX="$TEST_INBOX_DIR/test_agent.yaml"
LOCKFILE="\${INBOX}.lock"
SCRIPT_DIR="$PROJECT_ROOT"
export IDLE_FLAG_DIR="$TEST_TMPDIR"

# Mock tmux. capture-pane supports two modes:
#   - static: always returns \$MOCK_CAPTURE_PANE
#   - sequence: if MOCK_CAPTURE_SEQUENCE (array) is non-empty, each successive
#     capture-pane call consumes the next element (clamped to the last one).
#     Used by TC-STALL-007 to simulate the pane moving mid-ladder.
#     NOTE: is_stalled_pane() reads capture-pane output via \$(...), which
#     forks a subshell — a plain shell-variable counter would reset on every
#     call. The counter is a file so consumption persists across calls.
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
            # cmd_209 P-2 livebug fix (V-2): capture-pane -J re-joins
            # terminal-wrapped lines. Without this branch the mock would
            # ignore -J entirely and always return $MOCK_CAPTURE_PANE,
            # masking the exact linewrap bug this fix addresses.
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

# Mock stall_policy_query — pre-defining this function means the real
# lib/stall_policy.sh is never sourced (inbox_watcher.sh's
# "! type stall_policy_query" guard skips it), so tests never touch a real
# config/settings.yaml.
stall_policy_query() {
    case "\$1" in
        enabled) echo "\${MOCK_STALL_ENABLED:-true}" ;;
        stall_after_sec) echo "\${MOCK_STALL_AFTER_SEC:-480}" ;;
        stall_retry_cooldown_sec) echo "\${MOCK_STALL_COOLDOWN:-600}" ;;
        recovery_level) echo "\${MOCK_RECOVERY_LEVEL:-full}" ;;
        unknown_policy) echo "\${MOCK_UNKNOWN_POLICY:-escape_only}" ;;
        *) echo "" ;;
    esac
}
export -f stall_policy_query

# Mock usage_limit_state — pre-defining this means inbox_watcher.sh's own
# "declare -f usage_limit_state >/dev/null ||" fallback never kicks in, so
# tests control type-C state directly (lib/usage_limit.sh is T2's, not
# T1's concern here).
usage_limit_state() { echo "\${MOCK_USAGE_STATE:-ok}"; }
export -f usage_limit_state

# Source the REAL inbox_watcher.sh (testing guard skips startup & main loop)
export __INBOX_WATCHER_TESTING__=1
source "$WATCHER_SCRIPT"
HARNESS
    chmod +x "$TEST_HARNESS"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# REAL_BUSY_TAIL: literal fixture captured in cmd_209 P-2 Step 0 (2026-08-06).
# A single line is enough — agent_is_busy_check() only inspects the last
# non-empty line of the bottom 5 for the 'esc to' marker.
# Capture width: presumed 154 columns (the verify209 window, since removed —
# cannot be re-measured directly). At that width the 48-char line fits
# without wrapping, which is why this fixture alone never exposed the
# cmd_209 P-2 livebug linewrap bug fixed below (see REAL_BUSY_TAIL_WRAPPED).
REAL_BUSY_TAIL=' Esc to cancel · Tab to amend · ctrl+e to explain'

# REAL_BUSY_TAIL_WRAPPED / REAL_BUSY_TAIL_WRAPPED_JOINED: cmd_209 P-2 livebug
# fixture pair (gunshi live-tmux measurement, 2026-08-07). Capture width: 44
# columns (production ashigaru pane width). At this width tmux wraps the
# AskUserQuestion modal footer across two physical lines, splitting "Esc to"
# from "cancel" — the unjoined tail alone lacks the 'esc to' marker, which is
# exactly the bug (agent_is_busy_check reported idle while the pane was
# stuck on a modal). REAL_BUSY_TAIL_WRAPPED_JOINED is what `capture-pane -J`
# returns for the same pane — the fix under test.
REAL_BUSY_TAIL_WRAPPED='  Enter to select · ↑/↓ to navigate · Esc to
 cancel'
REAL_BUSY_TAIL_WRAPPED_JOINED='  Enter to select · ↑/↓ to navigate · Esc to cancel'

# Helper: seed STALL_HASH/STALL_HASH_SINCE so a subsequent is_stalled_pane()
# call with the same MOCK_CAPTURE_PANE content sees "already stale for N sec".
# Mirrors real usage: the first call always just seeds the hash (returns
# false); tests that need "already stalled" pre-seed it directly rather than
# manipulating wall-clock time.
seed_stalled_hash() {
    local content="$1"
    local age="${2:-500}"
    printf 'STALL_HASH=$(printf %%s %q | cksum | awk "{print \\$1}")\n' "$content"
    printf 'STALL_HASH_SINCE=$(( $(date +%%s) - %d ))\n' "$age"
}

# ─── TC-STALL-001: busy + pane hash unchanged for threshold → stalled ───

@test "TC-STALL-001: is_stalled_pane detects stall when busy and hash unchanged past threshold" {
    run bash -c "
        MOCK_CAPTURE_PANE='$REAL_BUSY_TAIL'
        source '$TEST_HARNESS'
        $(seed_stalled_hash "$REAL_BUSY_TAIL" 500)
        is_stalled_pane
    "
    [ "$status" -eq 0 ]
}

# ─── TC-STALL-002: pane content changes every sample → never stalled ───

@test "TC-STALL-002: is_stalled_pane never fires while pane content keeps changing (false-positive guard)" {
    # Each frame carries a real busy marker (last line) so stall_busy()
    # reports busy every time — the invariant under test is that a
    # genuinely-busy, ever-CHANGING pane never crosses stall_after_sec.
    run bash -c '
        source "'"$TEST_HARNESS"'"
        rc_all=0
        for i in 1 2 3 4 5 6; do
            MOCK_CAPTURE_PANE="frame $i $(date +%N)-$RANDOM
 Esc to cancel . Tab to amend . ctrl+e to explain"
            is_stalled_pane
            rc=$?
            if [ "$rc" -eq 0 ]; then rc_all=1; fi
        done
        echo "rc_all=$rc_all"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "rc_all=0"
}

# ─── TC-STALL-003: pane shows no busy marker (idle-looking) → not stalled ───

@test "TC-STALL-003: is_stalled_pane returns false when the pane has no busy marker (idle-looking screen)" {
    # cmd_209 P-2: stall_busy() for claude reads pane text (agent_is_busy_check),
    # not the idle flag file — so a plain, marker-less capture reads as idle
    # regardless of any flag on disk. This fixture intentionally has no
    # 'esc to' / Working-Thinking-etc marker.
    run bash -c "
        MOCK_CAPTURE_PANE='frozen screen content'
        source '$TEST_HARNESS'
        $(seed_stalled_hash 'frozen screen content' 500)
        is_stalled_pane
    "
    [ "$status" -eq 1 ]
}

# ─── TC-STALL-004: pane active + client attached (Gate 0) → no action ───

@test "TC-STALL-004: attempt_stall_recovery takes no action when pane is active and human is attached" {
    export MOCK_PANE_ACTIVE="1"
    export MOCK_LIST_CLIENTS="client_a"
    run bash -c "
        MOCK_CAPTURE_PANE='frozen screen content'
        MOCK_PANE_ACTIVE=1
        MOCK_LIST_CLIENTS=client_a
        source '$TEST_HARNESS'
        $(seed_stalled_hash 'frozen screen content' 500)
        attempt_stall_recovery
    "
    [ "$status" -eq 0 ]
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ─── TC-STALL-005: capture-pane empty → indeterminate, not stalled ───

@test "TC-STALL-005: is_stalled_pane returns false when capture-pane is empty (indeterminate)" {
    # First capture (consumed by stall_busy()'s own agent_is_busy_check call)
    # is busy; second capture (is_stalled_pane's own, for the hash) is empty
    # — this exercises is_stalled_pane's dedicated empty-capture branch
    # rather than short-circuiting earlier via stall_busy()=idle.
    run bash -c "
        MOCK_CAPTURE_SEQUENCE=('$REAL_BUSY_TAIL' '')
        source '$TEST_HARNESS'
        is_stalled_pane
    "
    [ "$status" -eq 1 ]
}

# ─── TC-STALL-006: stall_policy.enabled=false → attempt_stall_recovery no-ops ───

@test "TC-STALL-006: attempt_stall_recovery does nothing when stall_policy.enabled=false" {
    export MOCK_STALL_ENABLED="false"
    run bash -c "
        MOCK_CAPTURE_PANE='frozen screen content'
        MOCK_STALL_ENABLED=false
        source '$TEST_HARNESS'
        $(seed_stalled_hash 'frozen screen content' 500)
        attempt_stall_recovery
    "
    [ "$status" -eq 0 ]
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ─── TC-STALL-007: pane moves mid-ladder → later steps not sent ───

@test "TC-STALL-007: attempt_stall_recovery aborts the ladder once the pane starts moving again" {
    # Sequence has 3 slots because is_stalled_pane() now does TWO
    # capture-pane calls per invocation (stall_busy()'s own, then its own
    # hash capture): [0]=busy marker for call#1's stall_busy(),
    # [1]="frozen screen content" for call#1's hash check (matches the
    # pre-seeded hash below), [2]="screen moved now" for call#2's
    # stall_busy() — a plain line with no busy marker, so stall_busy()
    # itself reports idle and the ladder aborts (still verifies the
    # "pane moved -> ladder aborts" externally-observable contract).
    run bash -c '
        MOCK_RECOVERY_LEVEL=full
        MOCK_USAGE_STATE=ok
        source "'"$TEST_HARNESS"'"
        '"$(seed_stalled_hash 'frozen screen content' 500)"'
        MOCK_CAPTURE_SEQUENCE=("'"$REAL_BUSY_TAIL"'" "frozen screen content" "screen moved now")
        attempt_stall_recovery
    '
    [ "$status" -eq 0 ]
    grep -q "send-keys.*Escape.*Escape" "$MOCK_LOG"
    ! grep -q "send-keys.*inbox" "$MOCK_LOG"
    ! grep -q "send-keys.*/clear" "$MOCK_LOG"
}

# ─── TC-STALL-008: retry cooldown → no repeat action ───

@test "TC-STALL-008: attempt_stall_recovery skips while a prior recovery is within cooldown" {
    # Must actually reach Gate2=stalled first, or the cooldown gate below it
    # is never exercised.
    run bash -c "
        MOCK_CAPTURE_PANE='$REAL_BUSY_TAIL'
        MOCK_STALL_COOLDOWN=600
        source '$TEST_HARNESS'
        $(seed_stalled_hash "$REAL_BUSY_TAIL" 500)
        STALL_ACTED_AT=\$(( \$(date +%s) - 30 ))
        attempt_stall_recovery
    "
    [ "$status" -eq 0 ]
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ─── TC-STALL-009: agent_is_busy_check calls capture-pane with -J (V-1) ───

@test "TC-STALL-009: agent_is_busy_check invokes tmux capture-pane with -J" {
    # Checks the call arguments directly via MOCK_LOG, independent of
    # whether the mock's return value reflects -J (V-0: it doesn't unless
    # MOCK_CAPTURE_PANE_JOINED is set). This is the one check that would
    # catch a silent revert of the -J flag even if every fixture-based
    # test above happened to still pass.
    run bash -c "
        MOCK_CAPTURE_PANE='$REAL_BUSY_TAIL'
        source '$TEST_HARNESS'
        agent_is_busy_check \"\$PANE_TARGET\" claude || true
        grep -q 'capture-pane.*-J' '$MOCK_LOG' || { cat '$MOCK_LOG'; false; }
    "
    [ "$status" -eq 0 ]
}

# ─── TC-STALL-010/011: linewrap fixture pair (V-2) ───

@test "TC-STALL-010: is_stalled_pane detects busy once -J re-joins a wrapped modal footer" {
    # cmd_209 P-2 livebug: without -J, MOCK_CAPTURE_PANE alone (unwrapped
    # tail " cancel") lacks 'esc to' and is_stalled_pane would misread the
    # pane as idle. MOCK_CAPTURE_PANE_JOINED simulates what -J actually
    # returns for the same pane once the fix (lib/agent_status.sh:55) is in
    # place — the mock only serves this value when the tmux call includes -J.
    # is_stalled_pane()'s OWN hash capture (line ~975, R-2: intentionally
    # left without -J) still reads MOCK_CAPTURE_PANE — the raw, unjoined
    # two-line content — so the seeded hash must match that, not the
    # joined value.
    run bash -c "
        MOCK_CAPTURE_PANE='$REAL_BUSY_TAIL_WRAPPED'
        MOCK_CAPTURE_PANE_JOINED='$REAL_BUSY_TAIL_WRAPPED_JOINED'
        source '$TEST_HARNESS'
        $(seed_stalled_hash "$REAL_BUSY_TAIL_WRAPPED" 500)
        is_stalled_pane
    "
    [ "$status" -eq 0 ]
}

@test "TC-STALL-011: is_stalled_pane stays idle when the -J capture still lacks 'esc to' (bug record)" {
    # Negative case: even with -J requested, an empty/marker-less joined
    # capture must not be treated as busy. stall_busy() reports idle here,
    # so is_stalled_pane() returns 1 at its first gate without ever reaching
    # the hash capture — this is the exact behavior the original bug
    # produced for every pane, joined or not, before the -J fix existed.
    run bash -c "
        MOCK_CAPTURE_PANE='$REAL_BUSY_TAIL_WRAPPED'
        MOCK_CAPTURE_PANE_JOINED=''
        source '$TEST_HARNESS'
        is_stalled_pane
    "
    [ "$status" -eq 1 ]
}

# ─── TC-USAGE-001: usage_state=limited → no send-keys at all ───

@test "TC-USAGE-001: attempt_stall_recovery sends nothing when usage_limit_state is limited" {
    # Must reach Gate2=stalled first (F1: Gate2 now evaluated before Gate1),
    # or this test would trivially pass on a Gate2 short-circuit instead of
    # actually verifying the usage=limited path.
    export MOCK_USAGE_STATE="limited"
    run bash -c "
        MOCK_CAPTURE_PANE='$REAL_BUSY_TAIL'
        MOCK_USAGE_STATE=limited
        MOCK_RECOVERY_LEVEL=full
        source '$TEST_HARNESS'
        $(seed_stalled_hash "$REAL_BUSY_TAIL" 500)
        attempt_stall_recovery
    "
    [ "$status" -eq 0 ]
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ─── TC-USAGE-002: unknown + escape_only → Escape only, no nudge/clear ───

@test "TC-USAGE-002: attempt_stall_recovery sends only Escape when usage state is unknown (unknown_policy=escape_only)" {
    run bash -c "
        MOCK_CAPTURE_PANE='$REAL_BUSY_TAIL'
        MOCK_USAGE_STATE=unknown
        MOCK_UNKNOWN_POLICY=escape_only
        source '$TEST_HARNESS'
        $(seed_stalled_hash "$REAL_BUSY_TAIL" 500)
        attempt_stall_recovery
    "
    [ "$status" -eq 0 ]
    grep -q "send-keys.*Escape.*Escape" "$MOCK_LOG"
    ! grep -q "send-keys.*inbox" "$MOCK_LOG"
    ! grep -q "send-keys.*/clear" "$MOCK_LOG"
}

# ─── TC-USAGE-003: unknown + none → nothing sent ───

@test "TC-USAGE-003: attempt_stall_recovery sends nothing when usage state is unknown and unknown_policy=none" {
    run bash -c "
        MOCK_CAPTURE_PANE='$REAL_BUSY_TAIL'
        MOCK_USAGE_STATE=unknown
        MOCK_UNKNOWN_POLICY=none
        source '$TEST_HARNESS'
        $(seed_stalled_hash "$REAL_BUSY_TAIL" 500)
        attempt_stall_recovery
    "
    [ "$status" -eq 0 ]
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ─── TC-USAGE-004: ok → full ladder (Escape -> nudge -> /clear) ───

@test "TC-USAGE-004: attempt_stall_recovery runs the full ladder when usage state is ok" {
    run bash -c "
        MOCK_CAPTURE_PANE='$REAL_BUSY_TAIL'
        MOCK_USAGE_STATE=ok
        MOCK_RECOVERY_LEVEL=full
        source '$TEST_HARNESS'
        $(seed_stalled_hash "$REAL_BUSY_TAIL" 500)
        attempt_stall_recovery
    "
    [ "$status" -eq 0 ]
    grep -q "send-keys.*Escape.*Escape" "$MOCK_LOG"
    grep -q "send-keys.*inbox" "$MOCK_LOG"
    grep -q "send-keys.*/clear" "$MOCK_LOG"

    # Order: Escape before nudge before /clear
    esc_line=$(grep -n "send-keys.*Escape.*Escape" "$MOCK_LOG" | head -1 | cut -d: -f1)
    nudge_line=$(grep -n "send-keys.*inbox" "$MOCK_LOG" | head -1 | cut -d: -f1)
    clear_line=$(grep -n "send-keys.*/clear" "$MOCK_LOG" | head -1 | cut -d: -f1)
    [ "$esc_line" -lt "$nudge_line" ]
    [ "$nudge_line" -lt "$clear_line" ]
}

# ─── TC-STALL-012 (cmd_216 F-3 ii): raw nudge Enter gated by open modal ───

@test "TC-STALL-012: attempt_stall_recovery suppresses the raw nudge Enter while a modal is open" {
    # This route (the "inbox?" + Enter mid-ladder step) sends via raw tmux
    # send-keys, bypassing send_wakeup entirely — PR#97's 5-route gate table
    # never covered it (gunshi QC's 6th-route finding). REAL_BUSY_TAIL_WRAPPED_JOINED
    # carries both an 'esc to' busy marker (keeps is_stalled_pane true across
    # the ladder) and a modal anchor ('enter to select'/'to navigate'/'↑/↓'),
    # so this exercises the same live footer that made TC-STALL-010 necessary.
    # Escape is unaffected (it is the intended way to dismiss a modal and is
    # never gated); only the nudge's Enter must be suppressed.
    run bash -c "
        MOCK_CAPTURE_PANE='$REAL_BUSY_TAIL_WRAPPED_JOINED'
        MOCK_USAGE_STATE=ok
        MOCK_RECOVERY_LEVEL=full
        source '$TEST_HARNESS'
        $(seed_stalled_hash "$REAL_BUSY_TAIL_WRAPPED_JOINED" 500)
        attempt_stall_recovery
    "
    [ "$status" -eq 0 ]
    grep -q "send-keys.*Escape.*Escape" "$MOCK_LOG" \
        || { echo "expected Escape x2 to still fire (never modal-gated)"; cat "$MOCK_LOG"; false; }
    ! grep -q "send-keys.*inbox" "$MOCK_LOG" \
        || { echo "nudge text must not reach the pane while a modal is open"; cat "$MOCK_LOG"; false; }
    ! grep -q "send-keys.*Enter" "$MOCK_LOG" \
        || { echo "nudge Enter must not reach the pane while a modal is open (would confirm the modal's first option)"; cat "$MOCK_LOG"; false; }
    ! grep -q "send-keys.*/clear" "$MOCK_LOG" \
        || { echo "/clear must not fire when the ladder never reached it"; cat "$MOCK_LOG"; false; }
}

# ─── TC-USAGE-007: usage_limit_state=limited (regardless of source) is honored ───

@test "TC-USAGE-007: attempt_stall_recovery treats any 'limited' usage_limit_state as limited (source-agnostic)" {
    # usage_limit_state's own pane-text fallback (owned by T2, lib/usage_limit.sh)
    # can also produce "limited" even when the OAuth API says ok. T1 only
    # consumes the return value — this asserts that value is trusted as-is.
    export MOCK_USAGE_STATE="limited"
    run bash -c "
        MOCK_CAPTURE_PANE='$REAL_BUSY_TAIL'
        MOCK_USAGE_STATE=limited
        MOCK_RECOVERY_LEVEL=full
        source '$TEST_HARNESS'
        $(seed_stalled_hash "$REAL_BUSY_TAIL" 500)
        attempt_stall_recovery
    "
    [ "$status" -eq 0 ]
    ! grep -q "send-keys" "$MOCK_LOG"
}

# ─── TC-CL-001: command-layer agents never get /clear from the stall ladder ───

@test "TC-CL-001: attempt_stall_recovery injects no keys at all for shogun/karo/gunshi (cmd_209 P-2 mitigation 3)" {
    # cmd_209 主裁可: 対象は足軽paneのみ。旧仕様（Escapeは送るが/clearは
    # 送らぬ）よりも厳しく、command-layer paneには一切キーを注入しない。
    for agent in shogun karo gunshi; do
        > "$MOCK_LOG"
        run bash -c "
            MOCK_CAPTURE_PANE='frozen screen content'
            MOCK_USAGE_STATE=ok
            MOCK_RECOVERY_LEVEL=full
            source '$TEST_HARNESS'
            AGENT_ID='$agent'
            $(seed_stalled_hash 'frozen screen content' 500)
            attempt_stall_recovery
        "
        [ "$status" -eq 0 ]
        ! grep -q "send-keys" "$MOCK_LOG"
    done
}
