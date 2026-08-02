#!/usr/bin/env bats
# test_watcher_supervisor_log_rotate.bats — rotate_log_if_large unit tests
#
# Background (cmd_186/issue#27): watcher_supervisor.log balooned to a
# real measured 28MB / 149,190 lines with no automatic cap (root cause:
# the pane-mismatch WARN spam bug, fixed separately by cmd_176; this test
# covers the still-missing generic size cap, so a *different* future
# WARN/ERR spam source cannot repeat the same unbounded growth).
#
# Test cases:
#   T-ROT-001: log under the size cap is left untouched
#   T-ROT-002: log over the size cap is truncated in place, keeping only
#              the last N lines plus a rotation marker line
#   T-ROT-003: missing log file is a no-op. Note: this test's setup() only
#              extracts the rotate_log_if_large() function body via awk+eval
#              (see below) — the script's own top-of-file `set -euo pipefail`
#              line is outside the extracted range, so this test shell does
#              NOT have errexit active. It exercises the early-return path
#              only, not errexit resilience.
#   T-ROT-004: rotation truncates the file IN PLACE (same inode before/after)
#              rather than replacing it — this is the property that keeps
#              an already-open append-mode fd (held by the daemon whose
#              stdout was redirected with `>>` at launch) still landing in
#              the visible file after rotation, instead of silently
#              writing into an unlinked, invisible inode.
#   TC-ROT-005: with `set -euo pipefail` explicitly enabled in-test (QC52-F1,
#               cmd_186 PR#52 redo), a failing `tail` inside
#               rotate_log_if_large() must not kill the caller — the function
#               must return 0 and the caller's subsequent line must still run.

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SUPERVISOR_SCRIPT="$PROJECT_ROOT/scripts/watcher_supervisor.sh"

setup() {
    TEST_TMP="$(mktemp -d)"

    # Load only the rotate_log_if_large function definition, to avoid
    # running the infinite loop at the bottom of the script (same
    # extraction technique as test_watcher_supervisor.bats).
    eval "$(
        awk '/^rotate_log_if_large\(\)/{p=1} p{print} /^\}$/{if(p){p=0}}' \
            "$SUPERVISOR_SCRIPT"
    )"
}

teardown() {
    rm -rf "$TEST_TMP"
}

@test "T-ROT-001: log under the size cap is left untouched" {
    local log="$TEST_TMP/small.log"
    printf 'line1\nline2\nline3\n' > "$log"
    local before
    before=$(cat "$log")

    WATCHER_LOG_ROTATE_MAX_BYTES=10485760 rotate_log_if_large "$log"

    [ "$(cat "$log")" = "$before" ]
}

@test "T-ROT-002: log over the size cap is truncated in place, keeping last N lines + marker" {
    local log="$TEST_TMP/big.log"
    for i in $(seq 1 100); do
        echo "old-line-${i}" >> "$log"
    done
    local size_before
    size_before=$(stat -c%s "$log")

    WATCHER_LOG_ROTATE_MAX_BYTES=100 WATCHER_LOG_ROTATE_KEEP_LINES=10 rotate_log_if_large "$log"

    # Rotation marker present, mentions the pre-rotation size.
    run grep -c "log_rotate.*rotated ${log} in place" "$log"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
    grep -q "previous size ${size_before} bytes" "$log"

    # Only the last 10 old lines survived (old-line-91..old-line-100),
    # nothing earlier.
    ! grep -q "old-line-90$" "$log"
    grep -q "old-line-100$" "$log"

    # Total line count is small now (marker + 10 kept lines), not 100+.
    local line_count
    line_count=$(wc -l < "$log")
    [ "$line_count" -le 12 ]
}

@test "T-ROT-003: missing log file is a no-op" {
    local log="$TEST_TMP/does_not_exist.log"
    run rotate_log_if_large "$log"
    [ "$status" -eq 0 ]
    [ ! -e "$log" ]
}

@test "T-ROT-004: rotation truncates in place (same inode), so a live append-mode writer keeps landing in the visible file" {
    local log="$TEST_TMP/live.log"
    for i in $(seq 1 50); do
        echo "pre-rotate-${i}" >> "$log"
    done

    local inode_before
    inode_before=$(stat -c%i "$log")

    # Simulate the daemon's own `>> "$log_file" 2>&1 &` redirection: open
    # an append-mode fd on fd 9 BEFORE rotation (avoiding bats' own use of
    # low fds), exactly like a running inbox_watcher/baton_watchdog
    # process would already hold one.
    exec 9>>"$log"

    WATCHER_LOG_ROTATE_MAX_BYTES=50 WATCHER_LOG_ROTATE_KEEP_LINES=5 rotate_log_if_large "$log"

    local inode_after
    inode_after=$(stat -c%i "$log")
    [ "$inode_before" = "$inode_after" ] || { echo "inode changed: rotation replaced the file instead of truncating in place, which would strand any already-open append fd"; false; }

    # Write through the pre-rotation fd — must land in the (now much
    # smaller) visible file, proving the fd is still valid post-truncate.
    echo "post-rotate-via-old-fd" >&9
    exec 9>&-

    grep -q "post-rotate-via-old-fd" "$log" || { cat "$log"; false; }
}

@test "TC-ROT-005: under set -euo pipefail, tail failure returns 0 and caller continues" {
    local log="$TEST_TMP/tail_fail.log"
    for i in $(seq 1 100); do
        echo "line-${i}" >> "$log"
    done
    local before
    before=$(cat "$log")

    # Stub tail to always fail, simulating an I/O failure inside the
    # command substitution that feeds tail_content.
    tail() { return 1; }

    local marker_file="$TEST_TMP/reached_after_call"
    rm -f "$marker_file"

    (
        set -euo pipefail
        WATCHER_LOG_ROTATE_MAX_BYTES=100 WATCHER_LOG_ROTATE_KEEP_LINES=10 rotate_log_if_large "$log"
        touch "$marker_file"
    )
    local subshell_status=$?

    [ "$subshell_status" -eq 0 ] || { echo "subshell aborted under set -euo pipefail (status=$subshell_status) — errexit killed the caller instead of the function returning 0"; false; }
    [ -f "$marker_file" ] || { echo "caller's line after rotate_log_if_large never ran — errexit killed the shell before returning"; false; }
    [ "$(cat "$log")" = "$before" ] || { echo "log file was modified despite tail failure"; cat "$log"; false; }
}
