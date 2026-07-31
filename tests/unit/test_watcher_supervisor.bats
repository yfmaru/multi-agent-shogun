#!/usr/bin/env bats
# test_watcher_supervisor.bats — start_watcher_if_missing unit tests
#
# Tests the flock-protected start_watcher_if_missing logic via mocking.
#
# Test cases:
#   T-WS-001: pane does not exist → returns 0, no watcher started
#   T-WS-002: watcher already running for correct pane → no duplicate started
#   T-WS-003: lockfile path follows pattern /tmp/shogun_watcher_start_{agent}.lock
#   T-WS-004: no existing watcher → watcher is started
#   T-WS-005: real (unmocked) pgrep correctly detects an already-running watcher
#   TC-DEDUP-001..003: agent/pane match combinations do not start duplicates
#   OBS22-A-001..003 (cmd_178): stale-watcher WARN escalates to a shogun inbox
#     notification, guarded by a per-agent dedup flag that clears on resolution

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SUPERVISOR_SCRIPT="$PROJECT_ROOT/scripts/watcher_supervisor.sh"

setup() {
    TEST_TMP="$(mktemp -d)"
    mkdir -p "$TEST_TMP/scripts"
    mkdir -p "$TEST_TMP/queue/inbox"
    mkdir -p "$TEST_TMP/logs"

    # Mock inbox_watcher.sh — records launch args
    cat > "$TEST_TMP/scripts/inbox_watcher.sh" << 'MOCK'
#!/bin/bash
echo "$@" >> "$(dirname "$0")/../watcher_launched.log"
sleep 60
MOCK
    chmod +x "$TEST_TMP/scripts/inbox_watcher.sh"

    # Default mock: pane does NOT exist
    MOCK_PANE_EXISTS=0

    # Default mock: no existing watcher pgrep hit
    MOCK_PGREP_CORRECT=1
    MOCK_PGREP_STALE=1
}

teardown() {
    rm -rf "$TEST_TMP"
    rm -f /tmp/shogun_watcher_start_ashigaru1_*_${$}_dedup*.lock
    rm -f /tmp/shogun_watcher_start_cmd176fake.lock
    rm -f /tmp/shogun_watcher_obs22_notified_ashigaru1_*_"${$}"_obs22a*
    # T-WS-005's decoy self-terminates via `sleep 5` (kept alive as a
    # detection safety margin; no kill needed, D006). Reap it only if it
    # has already exited (bounded, non-blocking check) — never block the
    # test suite for the decoy's remaining lifetime (QC29-9: this used to
    # cost ~5s/run via an unconditional `wait`).
    if [ -n "${decoy_pid:-}" ]; then
        for _ in $(seq 1 5); do
            kill -0 "$decoy_pid" 2>/dev/null || { wait "$decoy_pid" 2>/dev/null || true; break; }
            sleep 0.05
        done
    fi
}

# Source the function under test with mocked dependencies injected via env overrides.
# We source the function definitions only, then call start_watcher_if_missing directly.
source_supervisor_functions() {
    # Override pane_exists and pgrep with shell functions in the current subshell.
    pane_exists() {
        return $MOCK_PANE_EXISTS
    }

    pgrep() {
        # Distinguish correct-pane vs stale-pane pgrep call by argument pattern
        local args="$*"
        if echo "$args" | grep -q "( |\$)"; then
            # correct-pane pattern (has trailing space or end anchor)
            return $MOCK_PGREP_CORRECT
        else
            return $MOCK_PGREP_STALE
        fi
    }

    ensure_inbox_file() {
        local agent="$1"
        touch "$TEST_TMP/queue/inbox/${agent}.yaml"
    }

    # Load only the start_watcher_if_missing function definition from the script.
    # We extract and eval it to avoid running the infinite loop at the bottom.
    eval "$(
        awk '/^start_watcher_if_missing\(\)/{p=1} p{print} /^\}$/{if(p){p=0}}' \
            "$SUPERVISOR_SCRIPT"
    )"
}

# ---------------------------------------------------------------------------
# T-WS-001: pane does not exist → function returns 0, no watcher started
# ---------------------------------------------------------------------------
@test "T-WS-001: pane does not exist returns 0 and does not start watcher" {
    (
        export MOCK_PANE_EXISTS=1   # non-zero = pane missing

        pane_exists() { return 1; }
        ensure_inbox_file() { :; }

        watcher_started=0
        nohup() { watcher_started=1; }

        eval "$(
            awk '/^start_watcher_if_missing\(\)/{p=1} p{print} /^\}$/{if(p){p=0}}' \
                "$SUPERVISOR_SCRIPT"
        )"

        start_watcher_if_missing "ashigaru1" "multiagent:agents.1" "/tmp/test_ws_001.log"
        result=$?

        [ "$result" -eq 0 ]
        [ "$watcher_started" -eq 0 ]
    )
}

# ---------------------------------------------------------------------------
# T-WS-002: watcher already running for correct pane → no duplicate started
# ---------------------------------------------------------------------------
@test "T-WS-002: watcher already running for correct pane does not start duplicate" {
    local launched_log="$TEST_TMP/watcher_launched.log"

    # Run a subprocess that:
    #   - pane exists
    #   - correct-pane pgrep returns 0 (watcher running)
    #   - records if inbox_watcher.sh gets executed
    (
        pane_exists() { return 0; }
        ensure_inbox_file() { touch "$TEST_TMP/queue/inbox/${1}.yaml"; }

        pgrep() {
            # Simulate: correct-pane watcher IS running
            return 0
        }

        nohup_called=0
        # Override nohup so we can detect if watcher would be launched
        nohup() { nohup_called=1; echo "$@" >> "$launched_log"; }

        eval "$(
            awk '/^start_watcher_if_missing\(\)/{p=1} p{print} /^\}$/{if(p){p=0}}' \
                "$SUPERVISOR_SCRIPT"
        )"

        start_watcher_if_missing "ashigaru1" "multiagent:agents.1" "/tmp/test_ws_002.log"

        # If launched_log was created, a duplicate was (incorrectly) started
        [ ! -f "$launched_log" ]
    )
}

# ---------------------------------------------------------------------------
# T-WS-003: lockfile path follows /tmp/shogun_watcher_start_{agent}.lock
# ---------------------------------------------------------------------------
@test "T-WS-003: lockfile path follows /tmp/shogun_watcher_start_{agent}.lock pattern" {
    local agent="ashigaru3"
    local expected_lockfile="/tmp/shogun_watcher_start_${agent}.lock"

    # Confirm the script contains the expected lockfile pattern for any agent name
    grep -q 'lockfile="/tmp/shogun_watcher_start_\${agent}.lock"' "$SUPERVISOR_SCRIPT"
}

# ---------------------------------------------------------------------------
# T-WS-004: no existing watcher → watcher is started (nohup bash ... invoked)
# ---------------------------------------------------------------------------
@test "T-WS-004: no existing watcher causes inbox_watcher to be launched" {
    local launched_log="$TEST_TMP/watcher_launched.log"
    local lockfile="/tmp/shogun_watcher_start_ashigaru4_$$_test.lock"

    # Clean up stray lockfile from a previous failed run
    rm -f "$lockfile"

    (
        pane_exists() { return 0; }
        ensure_inbox_file() { touch "$TEST_TMP/queue/inbox/${1}.yaml"; }

        pgrep() {
            # No watcher running
            return 1
        }

        tmux() {
            # Stub tmux show-options for @agent_cli
            echo "codex"
        }

        # macOS runners lack flock; stub it so the lock guard doesn't
        # short-circuit the test via the function's early `return 0`.
        flock() { return 0; }

        # Override nohup + bash to capture the launch without actually spawning
        nohup() {
            echo "launched: $*" >> "$launched_log"
        }

        eval "$(
            awk '/^start_watcher_if_missing\(\)/{p=1} p{print} /^\}$/{if(p){p=0}}' \
                "$SUPERVISOR_SCRIPT"
        )"

        # Use a test-specific lockfile to avoid collision with real supervisors
        # We re-define the lockfile variable inside the function scope by
        # calling with a modified env. Since lockfile is a local var built
        # from agent name, use a unique agent name for isolation.
        start_watcher_if_missing "ashigaru4_$$_test" "multiagent:agents.4" "$launched_log"
    )

    # A launched entry should exist in the log
    [ -f "$launched_log" ]
    grep -q "launched:" "$launched_log"
}

# ---------------------------------------------------------------------------
# T-WS-005 (cmd_176): real (unmocked) pgrep correctly detects an already-
# running watcher without falling through to the stale-WARN branch.
#
# T-WS-001..004 and TC-DEDUP-001..003 above all mock `pgrep` with a shell
# function, so none of them ever invoke the real pgrep binary — which is
# exactly why they stayed green through the cmd_176 regression: this host's
# procps-ng pgrep does not support `-E` and exits 2 on it, so the line-48
# exact-match check always failed and fell through to the stale-WARN branch
# at line 52 even when the correct-pane watcher was already running. Only a
# test that calls the real pgrep binary can catch that class of bug.
#
# The "already-running watcher" is simulated with a self-terminating decoy
# process rather than the real scripts/inbox_watcher.sh (which runs forever
# and cannot be self-cleaned without kill/pkill, forbidden by D006). The
# decoy uses `exec -a "<name>" sleep 5` so its /proc/PID/cmdline becomes
# exactly "<name> 5" via execve (no leftover shell wrapper text, and no
# bash tail-call surprises since sleep is the final and only exec'd image),
# giving pgrep -f a literal, stable match. Its 5s lifetime is kept only as
# a detection safety margin (QC29-9); the test itself does not wait for
# that full duration — see the bounded poll below and teardown()'s
# bounded, non-blocking reap. It exits on its own; never killed (D006).
# ---------------------------------------------------------------------------
@test "T-WS-005: real pgrep detects an already-running watcher via exact agent+pane match" {
    local agent="cmd176fake"
    local pane="faketest:0.0"
    local warn_log="$TEST_TMP/stderr_ws005.log"
    local launched_log="$TEST_TMP/watcher_launched_ws005.log"

    bash -c "exec -a \"scripts/inbox_watcher.sh ${agent} ${pane}\" sleep 5" &
    decoy_pid=$!

    # QC29-9: bounded polling instead of a fixed `sleep 0.3` guess — proceed
    # the instant the decoy's argv is actually visible to pgrep, rather than
    # waiting a fixed duration regardless of how fast (or slow) exec -a lands.
    local decoy_ready=false
    for _ in $(seq 1 20); do
        if pgrep -f "scripts/inbox_watcher.sh ${agent} ${pane}" >/dev/null 2>&1; then
            decoy_ready=true
            break
        fi
        sleep 0.05
    done
    [ "$decoy_ready" = true ]

    (
        pane_exists() { return 0; }
        nohup() { echo "launched: $*" >> "$launched_log"; }

        # macOS runners lack flock; stub it so the lock guard doesn't
        # short-circuit the test via the function's early `return 0`.
        flock() { return 0; }

        eval "$(
            awk '/^(start_watcher_if_missing|ensure_inbox_file)\(\)/{p=1} p{print} /^\}$/{if(p){p=0}}' \
                "$SUPERVISOR_SCRIPT"
        )"

        cd "$TEST_TMP"
        start_watcher_if_missing "$agent" "$pane" "/tmp/test_ws_005.log" 2>"$warn_log"
        result=$?

        [ "$result" -eq 0 ]
        [ ! -f "$launched_log" ]
        [ ! -s "$warn_log" ]
    )
}

# ---------------------------------------------------------------------------
# TC-DEDUP-001 (most important): agent matches but pane does not → no new
# watcher is started, only the existing WARN log is emitted (cmd_171 postmortem:
# previously this fell through to an unconditional nohup, causing duplicates).
# ---------------------------------------------------------------------------
@test "TC-DEDUP-001: agent match + pane mismatch does not start duplicate watcher" {
    local launched_log="$TEST_TMP/watcher_launched.log"
    local warn_log="$TEST_TMP/stderr.log"
    # Unique per-test agent name: avoids /tmp/shogun_watcher_start_<agent>.lock
    # colliding with the real, live watcher_supervisor.sh daemon on this host
    # (same isolation approach as T-WS-004).
    local agent="ashigaru1_${BATS_TEST_NUMBER}_$$_dedup001"
    local notified_flag="/tmp/shogun_watcher_obs22_notified_${agent}"
    rm -f "$notified_flag"

    (
        pane_exists() { return 0; }
        ensure_inbox_file() { touch "$TEST_TMP/queue/inbox/${1}.yaml"; }

        # correct-pane pgrep call (contains literal "( |$)") → not found (1)
        # agent-only/stale pgrep call (no "( |$)") → found (0)
        pgrep() {
            case "$*" in
                *'( |$)'*) return 1 ;;
                *) return 0 ;;
            esac
        }

        nohup_called=0
        nohup() { nohup_called=1; echo "$@" >> "$launched_log"; }

        # macOS runners lack flock; stub it so the lock guard doesn't
        # short-circuit the test via the function's early `return 0`.
        flock() { return 0; }

        # OBS22-A: this path now also fires a shogun inbox notification —
        # stub the real `bash scripts/inbox_write.sh ...` call the same way
        # OBS22-A-00x do, so this pre-existing test doesn't invoke the real
        # script (which needs a venv unavailable here and would otherwise
        # retry/sleep for seconds on failure).
        bash() {
            if [ "$1" = "scripts/inbox_write.sh" ]; then
                return 0
            fi
            command bash "$@"
        }

        eval "$(
            awk '/^start_watcher_if_missing\(\)/{p=1} p{print} /^\}$/{if(p){p=0}}' \
                "$SUPERVISOR_SCRIPT"
        )"

        start_watcher_if_missing "$agent" "multiagent:agents.1" "/tmp/test_dedup_001.log" 2>"$warn_log"
        result=$?

        [ "$result" -eq 0 ]
        [ ! -f "$launched_log" ]
        grep -q "stale watcher detected" "$warn_log"
    )

    rm -f "$notified_flag"
}

# ---------------------------------------------------------------------------
# TC-DEDUP-002 (regression): agent + pane exact match → nothing started
# (existing early return path, unchanged by the fix).
# ---------------------------------------------------------------------------
@test "TC-DEDUP-002: exact agent+pane match still starts nothing" {
    local launched_log="$TEST_TMP/watcher_launched.log"
    local agent="ashigaru1_${BATS_TEST_NUMBER}_$$_dedup002"

    (
        pane_exists() { return 0; }
        ensure_inbox_file() { touch "$TEST_TMP/queue/inbox/${1}.yaml"; }

        # correct-pane pgrep call → found (0): exact match already running
        pgrep() {
            case "$*" in
                *'( |$)'*) return 0 ;;
                *) return 0 ;;
            esac
        }

        nohup() { echo "$@" >> "$launched_log"; }

        eval "$(
            awk '/^start_watcher_if_missing\(\)/{p=1} p{print} /^\}$/{if(p){p=0}}' \
                "$SUPERVISOR_SCRIPT"
        )"

        start_watcher_if_missing "$agent" "multiagent:agents.1" "/tmp/test_dedup_002.log"
        result=$?

        [ "$result" -eq 0 ]
        [ ! -f "$launched_log" ]
    )
}

# ---------------------------------------------------------------------------
# TC-DEDUP-003 (regression): no existing watcher at all (neither exact nor
# stale pgrep match) → a new watcher is started.
# ---------------------------------------------------------------------------
@test "TC-DEDUP-003: no existing watcher causes new watcher to be started" {
    local launched_log="$TEST_TMP/watcher_launched.log"
    local agent="ashigaru1_${BATS_TEST_NUMBER}_$$_dedup003"

    (
        pane_exists() { return 0; }
        ensure_inbox_file() { touch "$TEST_TMP/queue/inbox/${1}.yaml"; }

        # Neither correct-pane nor stale pgrep call finds anything.
        pgrep() { return 1; }

        tmux() { echo "codex"; }

        # macOS runners lack flock; stub it so the lock guard doesn't
        # short-circuit the test via the function's early `return 0`.
        flock() { return 0; }

        nohup() { echo "launched: $*" >> "$launched_log"; }

        eval "$(
            awk '/^start_watcher_if_missing\(\)/{p=1} p{print} /^\}$/{if(p){p=0}}' \
                "$SUPERVISOR_SCRIPT"
        )"

        start_watcher_if_missing "$agent" "multiagent:agents.1" "/tmp/test_dedup_003.log"
    )

    [ -f "$launched_log" ]
    grep -q "launched:" "$launched_log"
}

# ---------------------------------------------------------------------------
# OBS22-A-001 (cmd_178): first stale-watcher detection escalates the WARN to
# a shogun inbox notification (via inbox_write.sh) and creates a dedup flag.
# ---------------------------------------------------------------------------
@test "OBS22-A-001: first stale-watcher detection sends shogun inbox notification and creates dedup flag" {
    local agent="ashigaru1_${BATS_TEST_NUMBER}_$$_obs22a001"
    local notified_flag="/tmp/shogun_watcher_obs22_notified_${agent}"
    rm -f "$notified_flag"

    (
        pane_exists() { return 0; }
        ensure_inbox_file() { touch "$TEST_TMP/queue/inbox/${1}.yaml"; }

        # correct-pane pgrep call → not found (1); agent-only/stale pgrep → found (0)
        pgrep() {
            case "$*" in
                *'( |$)'*) return 1 ;;
                *) return 0 ;;
            esac
        }

        flock() { return 0; }
        nohup() { :; }

        # Intercept the `bash scripts/inbox_write.sh ...` call the same way
        # other tests intercept `nohup`/`tmux`/`pgrep`.
        bash() {
            if [ "$1" = "scripts/inbox_write.sh" ]; then
                echo "$*" >> "$TEST_TMP/inbox_write_calls.log"
                return 0
            fi
            command bash "$@"
        }

        eval "$(
            awk '/^start_watcher_if_missing\(\)/{p=1} p{print} /^\}$/{if(p){p=0}}' \
                "$SUPERVISOR_SCRIPT"
        )"

        start_watcher_if_missing "$agent" "multiagent:agents.1" "/tmp/test_obs22a001.log"

        [ -f "$TEST_TMP/inbox_write_calls.log" ]
        grep -q "shogun" "$TEST_TMP/inbox_write_calls.log"
        grep -q "$agent" "$TEST_TMP/inbox_write_calls.log"
        [ -f "$notified_flag" ]
    )

    rm -f "$notified_flag"
}

# ---------------------------------------------------------------------------
# OBS22-A-002 (cmd_178): repeated detection of the SAME unresolved mismatch
# must NOT re-notify (dedup guard) — this is the core of OBS22-A's purpose:
# without it, every 5s supervisor cycle would re-flood shogun's inbox.
# ---------------------------------------------------------------------------
@test "OBS22-A-002: repeated stale-watcher detection with existing flag does not re-notify" {
    local agent="ashigaru1_${BATS_TEST_NUMBER}_$$_obs22a002"
    local notified_flag="/tmp/shogun_watcher_obs22_notified_${agent}"
    touch "$notified_flag"

    (
        pane_exists() { return 0; }
        ensure_inbox_file() { touch "$TEST_TMP/queue/inbox/${1}.yaml"; }

        pgrep() {
            case "$*" in
                *'( |$)'*) return 1 ;;
                *) return 0 ;;
            esac
        }

        flock() { return 0; }
        nohup() { :; }

        bash() {
            if [ "$1" = "scripts/inbox_write.sh" ]; then
                echo "$*" >> "$TEST_TMP/inbox_write_calls.log"
                return 0
            fi
            command bash "$@"
        }

        eval "$(
            awk '/^start_watcher_if_missing\(\)/{p=1} p{print} /^\}$/{if(p){p=0}}' \
                "$SUPERVISOR_SCRIPT"
        )"

        start_watcher_if_missing "$agent" "multiagent:agents.1" "/tmp/test_obs22a002.log"

        [ ! -f "$TEST_TMP/inbox_write_calls.log" ]
        [ -f "$notified_flag" ]
    )

    rm -f "$notified_flag"
}

# ---------------------------------------------------------------------------
# OBS22-A-003 (cmd_178): once the mismatch resolves (exact agent+pane match
# reached), the dedup flag is cleared so a FUTURE mismatch can notify again.
# ---------------------------------------------------------------------------
@test "OBS22-A-003: resolved pane match clears the dedup notification flag" {
    local agent="ashigaru1_${BATS_TEST_NUMBER}_$$_obs22a003"
    local notified_flag="/tmp/shogun_watcher_obs22_notified_${agent}"
    touch "$notified_flag"

    (
        pane_exists() { return 0; }
        ensure_inbox_file() { touch "$TEST_TMP/queue/inbox/${1}.yaml"; }

        # correct-pane pgrep call → found (0): exact match already running
        pgrep() { return 0; }

        flock() { return 0; }
        nohup() { :; }

        bash() {
            if [ "$1" = "scripts/inbox_write.sh" ]; then
                echo "$*" >> "$TEST_TMP/inbox_write_calls.log"
                return 0
            fi
            command bash "$@"
        }

        eval "$(
            awk '/^start_watcher_if_missing\(\)/{p=1} p{print} /^\}$/{if(p){p=0}}' \
                "$SUPERVISOR_SCRIPT"
        )"

        start_watcher_if_missing "$agent" "multiagent:agents.1" "/tmp/test_obs22a003.log"

        [ ! -f "$notified_flag" ]
        [ ! -f "$TEST_TMP/inbox_write_calls.log" ]
    )

    rm -f "$notified_flag"
}
