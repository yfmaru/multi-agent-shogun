#!/usr/bin/env bats
# test_send_wakeup.bats — send_wakeup() unit tests
# Sources the REAL inbox_watcher.sh with __INBOX_WATCHER_TESTING__=1
# to test actual production functions with mocked externals (tmux, pgrep, etc).
#
# テスト構成:
#   T-SW-001: send_wakeup — active self-watch → skip nudge
#   T-SW-002: send_wakeup — no self-watch → tmux send-keys
#   T-SW-003: send_wakeup — send-keys content is "inboxN" + Enter (separated)
#   T-SW-004: send_wakeup — send-keys failure → return 1
#   T-SW-005: send_wakeup — no paste-buffer or set-buffer used
#   T-SW-006: agent_has_self_watch — detects inotifywait process
#   T-SW-007: agent_has_self_watch — no inotifywait → returns 1
#   T-SW-008: send_cli_command — /clear uses send-keys
#   T-SW-009: send_cli_command — /model uses send-keys
#   T-SW-010: nudge content format — inboxN (backward compatible)
#   T-SW-011: inbox_watcher.sh uses send-keys, functions exist
#   T-ESC-001: escalation — no unread → FIRST_UNREAD_SEEN stays 0
#   T-ESC-002: escalation — unread < 2min → standard nudge
#   T-ESC-003: escalation — unread 2-4min → Escape+nudge
#   T-ESC-004: escalation — unread > 4min → /clear sent
#   T-ESC-005: escalation — /clear cooldown → falls back to Escape+nudge
#   T-BUSY-001: agent_is_busy — detects "Working" in pane
#   T-BUSY-002: agent_is_busy — idle pane returns 1
#   T-BUSY-003: send_wakeup — skips when agent is busy
#   T-BUSY-004: send_wakeup_with_escape — skips when agent is busy
#   T-CODEX-001: send_cli_command — codex /clear → /new conversion
#   T-CODEX-002: send_cli_command — codex /model → skip
#   T-OPENCODE-001: send_cli_command — opencode /clear → /new conversion
#   T-OPENCODE-002: send_cli_command — opencode /model → skip
#   T-CODEX-003: C-u sent when unread=0 and agent is idle
#   T-CODEX-004: C-u NOT sent when agent is busy
#   T-CODEX-005: send_cli_command — claude /clear passes through as-is
#   T-CODEX-006: inbox_watcher.sh has agent_is_busy and Codex/Copilot handlers
#   T-CODEX-007: pane @agent_cli=codex overrides stale CLI_TYPE (Phase2 C-c抑止)
#   T-CODEX-008: pane @agent_cli=codex overrides stale CLI_TYPE (/clear→/new)
#   T-CODEX-009: normalize_special_command rejects invalid model_switch payload
#   T-CODEX-010: unresolved CLI type falls back to codex-safe path
#   T-CODEX-011: clear_command処理でauto-recovery task_assignedを自動投入
#   T-CODEX-012: auto-recovery task_assignedは重複投入しない
#   T-CODEX-016: Codex transcript echo is not treated as stuck input
#   T-SHOGUN-001: session_has_client — returns 0 when client attached
#   T-SHOGUN-002: session_has_client — returns 1 when no client
#   T-SHOGUN-003: send_wakeup — shogun + active + attached → send-keys (post PR#75)
#   T-SHOGUN-004: send_wakeup — shogun + active + detached → send-keys fallthrough
#   T-SHOGUN-005: shogun clear_command does not enqueue auto-recovery
#   T-SHOGUN-006: send_wakeup — shogun + client typed 5s ago → defer (display-message, no send-keys) (cmd_182)
#   T-SHOGUN-007: send_wakeup — deferral is not a drop; guard-window elapses → send-keys fires (cmd_182, MUST)
#   T-SHOGUN-008: send_wakeup — client attached but activity old → send-keys fires (ntfy reply path, PR#75 non-regression, cmd_182, MUST)
#   T-SHOGUN-009: send_wakeup — non-shogun agent unaffected by recent typing (cmd_182)
#   T-SHOGUN-010: send_wakeup — no client at all → human_typing_recently false → send-keys fires (cmd_182)
#   T-SHOGUN-011: deferral sets SHOGUN_DEFER_PENDING, reopens should_process_timeout_tick, resets on delivery/unread=0 (cmd_182 QC40-F1, MUST)
#   T-SHOGUN-012: deferred ntfy (branch_policy_notify) fires only once per defer episode (cmd_182 QC40-F2, MUST)
#   T-BUSY-005: agent_is_busy — returns busy during /clear cooldown (LAST_CLEAR_TS)
#   T-BUSY-006: agent_is_busy — returns idle after /clear cooldown expires
#   T-BUSY-007: agent_is_busy — /clear cooldown overrides idle pane
#   T-BUSY-008: agent_is_busy — idle prompt at bottom overrides old busy markers (false-busy fix)
#   T-BUSY-009: agent_is_busy — 'background terminal running' detected as busy
#   T-BUSY-010: agent_is_busy — 'Compacting conversation' detected as busy
#   T-BUSY-011: agent_is_busy — 'esc to interrupt' alone detected as busy
#   T-BUSY-012: agent_is_busy — OpenCode idle home screen detected as idle
#   T-BUSY-013: agent_is_busy — OpenCode sidebar busy state detected as busy
#   T-BUSY-014: agent_is_busy — OpenCode animation row detected as busy
#   T-BUSY-015: agent_is_busy — blank OpenCode pane falls back to idle
#   T-BUSY-016: agent_is_busy — OpenCode animation fallback works without python3
#   T-SHOOK-001: Claude Code throttle uses 60s cooldown (stop-hook-supplementary)
#   T-SHOOK-002: Claude Code count change bypasses throttle (stop-hook-supplementary)
#   T-SHOOK-003: Non-Claude CLIs still bypass throttle on count change
#   T-CRESET-001: send_context_reset — suppresses /clear for karo
#   T-CRESET-002: send_context_reset — suppresses /clear for gunshi
#   T-CRESET-003: send_context_reset — sends /clear for ashigaru
#   T-CRESET-004: send_context_reset — sends /new for opencode
#   T-COPILOT-001: send_cli_command — copilot /clear → Ctrl-C + restart
#   T-COPILOT-002: send_cli_command — copilot /model → skip

# --- セットアップ ---

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export WATCHER_SCRIPT="$PROJECT_ROOT/scripts/inbox_watcher.sh"
    export VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"
    [ -f "$WATCHER_SCRIPT" ] || return 1
    "$VENV_PYTHON" -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/send_wakeup_test.XXXXXX")"

    # Log file for tmux mock calls (all tmux invocations recorded here)
    export MOCK_LOG="$TEST_TMPDIR/tmux_calls.log"
    > "$MOCK_LOG"

    # Create mock pgrep (default: no self-watch found)
    export MOCK_PGREP="$TEST_TMPDIR/mock_pgrep"
    cat > "$MOCK_PGREP" << 'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$MOCK_PGREP"

    # Create test inbox directory
    export TEST_INBOX_DIR="$TEST_TMPDIR/queue/inbox"
    mkdir -p "$TEST_INBOX_DIR"

    # Default mock control variables
    export MOCK_CAPTURE_PANE=""
    export MOCK_SENDKEYS_RC=0
    export MOCK_PANE_CLI=""
    export MOCK_PANE_ACTIVE=""
    export MOCK_LIST_CLIENTS=""
    export MOCK_CLIENT_ACTIVITY=""

    # Test harness: sets up mocks, then sources the REAL inbox_watcher.sh
    # __INBOX_WATCHER_TESTING__=1 skips arg parsing, inotifywait check, and main loop.
    # Only function definitions are loaded — testing actual production code.
    export TEST_HARNESS="$TEST_TMPDIR/test_harness.sh"
    cat > "$TEST_HARNESS" << HARNESS
#!/bin/bash
# Variables required by inbox_watcher.sh functions
AGENT_ID="test_agent"
PANE_TARGET="test:0.0"
CLI_TYPE="claude"
INBOX="$TEST_INBOX_DIR/test_agent.yaml"
LOCKFILE="\${INBOX}.lock"
SCRIPT_DIR="$PROJECT_ROOT"
export IDLE_FLAG_DIR="$TEST_TMPDIR"

# Mock external commands (defined before sourcing so they override real commands)
tmux() {
    echo "tmux \$*" >> "$MOCK_LOG"
    if echo "\$*" | grep -q "capture-pane"; then
        echo "\${MOCK_CAPTURE_PANE:-}"
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
        if echo "\$*" | grep -q "client_activity"; then
            # cmd_182: client_last_activity_epoch() query — distinct control
            # variable from MOCK_LIST_CLIENTS (attach-count format) so tests
            # can set "recent"/"old"/absent independently of attach state.
            [ -n "\${MOCK_CLIENT_ACTIVITY:-}" ] && echo "\$MOCK_CLIENT_ACTIVITY"
            return 0
        fi
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

# Source the REAL inbox_watcher.sh (testing guard skips startup & main loop)
export __INBOX_WATCHER_TESTING__=1
source "$WATCHER_SCRIPT"
HARNESS
    chmod +x "$TEST_HARNESS"

    # Default: create idle flag so agent_is_busy() returns idle (1) for claude CLI
    # Tests requiring busy state must rm this file before their run bash -c block
    touch "$TEST_TMPDIR/shogun_idle_test_agent"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# --- T-SW-001: self-watch active → skip nudge ---

@test "T-SW-001: send_wakeup skips nudge when agent has active self-watch" {
    cat > "$MOCK_PGREP" << 'MOCK'
#!/bin/bash
echo "12345 inotifywait -q -t 120 -e modify inbox/test_agent.yaml"
exit 0
MOCK
    chmod +x "$MOCK_PGREP"

    run bash -c "source '$TEST_HARNESS' && send_wakeup 3"
    [ "$status" -eq 0 ]

    # No nudge send-keys should have occurred
    ! grep -q "send-keys.*inbox" "$MOCK_LOG"

    echo "$output" | grep -q "SKIP"
}

# --- T-SW-002: no self-watch → tmux send-keys ---

@test "T-SW-002: send_wakeup uses tmux send-keys when no self-watch" {
    run bash -c "source '$TEST_HARNESS' && send_wakeup 5"
    [ "$status" -eq 0 ]

    # Verify send-keys occurred with inbox5
    grep -q "send-keys.*inbox5" "$MOCK_LOG"
    # Verify Enter was sent (as separate call — Codex TUI compatibility)
    grep -q "send-keys.*Enter" "$MOCK_LOG"
}

# --- T-SW-003: send-keys content is "inboxN" + Enter (separated) ---

@test "T-SW-003: send-keys sends inboxN and Enter as separate calls" {
    run bash -c "source '$TEST_HARNESS' && send_wakeup 3"
    [ "$status" -eq 0 ]

    # Text and Enter are sent as separate send-keys calls (Codex TUI compatibility)
    grep -q "send-keys -t test:0.0 inbox3" "$MOCK_LOG"
    grep -q "send-keys -t test:0.0 Enter" "$MOCK_LOG"
}

# --- T-SW-004: send-keys failure → return 0 (daemon-safe) + WARNING log ---
# send_wakeup always returns 0 to avoid killing the watcher under set -euo pipefail.

@test "T-SW-004: send_wakeup returns 0 when send-keys fails (daemon-safe)" {
    run bash -c "MOCK_SENDKEYS_RC=1; source '$TEST_HARNESS' && send_wakeup 2"
    [ "$status" -eq 0 ]

    echo "$output" | grep -qi "WARNING\|failed"
}

# --- T-SW-005: no paste-buffer or set-buffer used ---

@test "T-SW-005: nudge delivery does NOT use paste-buffer or set-buffer" {
    run bash -c "source '$TEST_HARNESS' && send_wakeup 3"
    [ "$status" -eq 0 ]

    # These should never be used
    ! grep -q "paste-buffer" "$MOCK_LOG"
    ! grep -q "set-buffer" "$MOCK_LOG"

    # send-keys IS expected
    grep -q "send-keys" "$MOCK_LOG"
}

# --- T-SW-006: agent_has_self_watch — detects inotifywait ---

@test "T-SW-006: agent_has_self_watch returns 0 when inotifywait running" {
    cat > "$MOCK_PGREP" << 'MOCK'
#!/bin/bash
echo "99999 inotifywait -q -t 120 -e modify inbox/test_agent.yaml"
exit 0
MOCK
    chmod +x "$MOCK_PGREP"

    run bash -c "source '$TEST_HARNESS' && agent_has_self_watch"
    [ "$status" -eq 0 ]
}

# --- T-SW-007: agent_has_self_watch — no inotifywait ---

@test "T-SW-007: agent_has_self_watch returns 1 when no inotifywait" {
    run bash -c "source '$TEST_HARNESS' && agent_has_self_watch"
    [ "$status" -eq 1 ]
}

# --- T-SW-008: /clear uses send-keys ---

@test "T-SW-008: send_cli_command /clear uses tmux send-keys" {
    run bash -c "source '$TEST_HARNESS' && send_cli_command /clear"
    [ "$status" -eq 0 ]

    # Verify send-keys was used with /clear
    grep -q "send-keys.*/clear" "$MOCK_LOG"
    # C-c was sent first (stale input clearing)
    grep -q "send-keys.*C-c" "$MOCK_LOG"
    # Enter was sent after /clear
    grep -q "send-keys.*Enter" "$MOCK_LOG"
}

# --- T-SW-009: /model uses send-keys ---

@test "T-SW-009: send_cli_command /model uses tmux send-keys" {
    run bash -c "source '$TEST_HARNESS' && send_cli_command '/model opus'"
    [ "$status" -eq 0 ]

    grep -q "send-keys.*/model opus" "$MOCK_LOG"
    grep -q "send-keys.*Enter" "$MOCK_LOG"
}

# --- T-SW-010: nudge content format ---

@test "T-SW-010: nudge content format is inboxN (backward compatible)" {
    run bash -c "source '$TEST_HARNESS' && send_wakeup 7"
    [ "$status" -eq 0 ]

    grep -q "send-keys.*inbox7" "$MOCK_LOG"
}

# --- T-SW-011: functions exist in inbox_watcher.sh ---

@test "T-SW-011: inbox_watcher.sh uses send-keys with required functions" {
    grep -q "send_wakeup()" "$WATCHER_SCRIPT"
    grep -q "agent_has_self_watch" "$WATCHER_SCRIPT"
    grep -q "send_wakeup_with_escape()" "$WATCHER_SCRIPT"
    grep -q "send_cli_command()" "$WATCHER_SCRIPT"

    # send-keys IS used in executable code
    local executable_lines
    executable_lines=$(grep -v '^\s*#' "$WATCHER_SCRIPT")
    echo "$executable_lines" | grep -q "send-keys"

    # paste-buffer and set-buffer are NOT used
    ! echo "$executable_lines" | grep -q "paste-buffer"
    ! echo "$executable_lines" | grep -q "set-buffer"
}

# --- T-ESC-001: no unread → FIRST_UNREAD_SEEN stays 0 ---

@test "T-ESC-001: escalation state resets when no unread messages" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        FIRST_UNREAD_SEEN=12345
        # Simulate no unread
        normal_count=0
        if [ "$normal_count" -gt 0 ] 2>/dev/null; then
            echo "SHOULD_NOT_REACH"
        else
            FIRST_UNREAD_SEEN=0
        fi
        echo "FIRST_UNREAD_SEEN=$FIRST_UNREAD_SEEN"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "FIRST_UNREAD_SEEN=0"
}

# --- T-ESC-002: unread < 2min → standard nudge ---

@test "T-ESC-002: escalation Phase 1 — unread under 2min uses standard nudge" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        now=$(date +%s)
        FIRST_UNREAD_SEEN=$((now - 30))  # 30 seconds ago
        age=$((now - FIRST_UNREAD_SEEN))
        if [ "$age" -lt "$ESCALATE_PHASE1" ]; then
            send_wakeup 2
            echo "PHASE1_NUDGE"
        fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "PHASE1_NUDGE"
    grep -q "send-keys.*inbox2" "$MOCK_LOG"
    # No Escape-based nudge
    ! grep -q "send-keys.*Escape" "$MOCK_LOG"
}

# --- T-ESC-003: unread 2-4min → Escape+nudge ---

@test "T-ESC-003: escalation Phase 2 — unread 2-4min uses Escape+nudge (copilot)" {
    # Escape escalation is suppressed for claude/codex (Stop hook / safety).
    # Test with copilot CLI which still uses Escape escalation.
    export MOCK_PANE_CLI="copilot"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        now=$(date +%s)
        FIRST_UNREAD_SEEN=$((now - 180))  # 3 minutes ago
        age=$((now - FIRST_UNREAD_SEEN))
        if [ "$age" -ge "$ESCALATE_PHASE1" ] && [ "$age" -lt "$ESCALATE_PHASE2" ]; then
            send_wakeup_with_escape 3
            echo "PHASE2_ESCAPE_NUDGE"
        fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "PHASE2_ESCAPE_NUDGE"
    grep -q "send-keys.*C-c" "$MOCK_LOG"
    # Escape was sent
    grep -q "send-keys.*Escape" "$MOCK_LOG"
    # Nudge was also sent
    grep -q "send-keys.*inbox3" "$MOCK_LOG"
}

# --- T-ESC-004: unread > 4min → /clear sent ---

@test "T-ESC-004: escalation Phase 3 — unread over 4min sends /clear" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        now=$(date +%s)
        FIRST_UNREAD_SEEN=$((now - 300))  # 5 minutes ago
        LAST_CLEAR_TS=0  # no recent /clear
        age=$((now - FIRST_UNREAD_SEEN))
        if [ "$age" -ge "$ESCALATE_PHASE2" ] && [ "$LAST_CLEAR_TS" -lt "$((now - ESCALATE_COOLDOWN))" ]; then
            send_cli_command "/clear"
            echo "PHASE3_CLEAR"
        fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "PHASE3_CLEAR"
    grep -q "send-keys.*/clear" "$MOCK_LOG"
}

# --- T-ESC-005: /clear cooldown → falls back to Escape+nudge ---

@test "T-ESC-005: escalation /clear cooldown — falls back to Escape+nudge (copilot)" {
    # Escape escalation is suppressed for claude/codex. Test with copilot.
    export MOCK_PANE_CLI="copilot"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        now=$(date +%s)
        FIRST_UNREAD_SEEN=$((now - 300))  # 5 minutes ago
        LAST_CLEAR_TS=$((now - 60))  # /clear sent 1 min ago (within 5min cooldown)
        age=$((now - FIRST_UNREAD_SEEN))
        if [ "$age" -ge "$ESCALATE_PHASE2" ] && [ "$LAST_CLEAR_TS" -ge "$((now - ESCALATE_COOLDOWN))" ]; then
            send_wakeup_with_escape 4
            echo "COOLDOWN_FALLBACK"
        fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "COOLDOWN_FALLBACK"
    grep -q "send-keys.*C-c" "$MOCK_LOG"
    grep -q "send-keys.*Escape" "$MOCK_LOG"
    grep -q "send-keys.*inbox4" "$MOCK_LOG"
    ! grep -q "send-keys.*/clear" "$MOCK_LOG"
}

# --- T-BUSY-001: agent_is_busy detects "Working" ---

@test "T-BUSY-001: agent_is_busy returns 0 (busy) when no idle flag — claude CLI" {
    rm -f "$TEST_TMPDIR/shogun_idle_test_agent"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        LAST_CLEAR_TS=0
        agent_is_busy
    '
    [ "$status" -eq 0 ]
}

# --- T-BUSY-002: agent_is_busy returns 1 when idle ---

@test "T-BUSY-002: agent_is_busy returns 1 when pane is idle" {
    run bash -c '
        MOCK_CAPTURE_PANE="› Summarize recent commits
  ? for shortcuts                100% context left"
        source "'"$TEST_HARNESS"'"
        agent_is_busy
    '
    [ "$status" -eq 1 ]
}

# --- T-BUSY-003: send_wakeup skips when agent is busy ---

@test "T-BUSY-003: send_wakeup skips nudge when agent is busy" {
    rm -f "$TEST_TMPDIR/shogun_idle_test_agent"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        send_wakeup 3
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi "SKIP.*busy"

    # No nudge should have been sent
    ! grep -q "send-keys.*inbox" "$MOCK_LOG"
}

# --- T-BUSY-004: send_wakeup_with_escape skips when agent is busy ---

@test "T-BUSY-004: send_wakeup_with_escape skips when agent is busy" {
    rm -f "$TEST_TMPDIR/shogun_idle_test_agent"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        send_wakeup_with_escape 2
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi "SKIP.*busy"

    # No nudge should have been sent
    ! grep -q "send-keys.*inbox" "$MOCK_LOG"
}

# --- T-CODEX-001: codex /clear → /new conversion ---

@test "T-CODEX-001: send_cli_command converts /clear to /new for codex" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="codex"
        send_cli_command "/clear"
    '
    [ "$status" -eq 0 ]

    # Should send /new, NOT /clear
    grep -q "send-keys.*/new" "$MOCK_LOG"
    ! grep -q "send-keys.*/clear" "$MOCK_LOG"
}

# --- T-CODEX-002: codex /model → skip ---

@test "T-CODEX-002: send_cli_command skips /model for codex" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="codex"
        send_cli_command "/model opus"
    '
    [ "$status" -eq 0 ]

    # No tmux send-keys for /model
    ! grep -q "send-keys.*/model" "$MOCK_LOG"

    # Stderr indicates skip
    echo "$output" | grep -q "not supported on codex"
}

# --- T-OPENCODE-001: opencode /clear → /new conversion ---

@test "T-OPENCODE-001: send_cli_command converts /clear to /new for opencode" {
    run bash -c '
        MOCK_CAPTURE_PANE="first line\nsecond line\nthird line\n"
        MOCK_PANE_CLI="opencode"
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="opencode"
        send_cli_command "/clear"
    '
    [ "$status" -eq 0 ]

    # /clear is converted to /new after clearing stale input — no Escape or C-c sent.
    grep -q "send-keys.*C-u" "$MOCK_LOG"
    grep -q "send-keys.*/new" "$MOCK_LOG"
    ! grep -q "send-keys.*/clear" "$MOCK_LOG"
    ! grep -q "send-keys.*Escape" "$MOCK_LOG"
    ! grep -q "send-keys.*C-c" "$MOCK_LOG"
}

# --- T-OPENCODE-002: opencode /model → skip with restart-only note ---

@test "T-OPENCODE-002: send_cli_command skips /model for opencode" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="opencode"
        send_cli_command "/model opus"
    '
    [ "$status" -eq 0 ]

    ! grep -q "send-keys.*/model" "$MOCK_LOG"
    echo "$output" | grep -q "restart-only"
}

@test "T-ANTIGRAVITY-001: send_cli_command passes /clear through for antigravity" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="antigravity"
        send_cli_command "/clear"
    '
    [ "$status" -eq 0 ]

    grep -q "send-keys.*/clear" "$MOCK_LOG"
    ! grep -q "send-keys.*/new" "$MOCK_LOG"
}

@test "T-ANTIGRAVITY-002: send_cli_command skips /model for antigravity" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="antigravity"
        send_cli_command "/model gemini-latest"
    '
    [ "$status" -eq 0 ]

    ! grep -q "send-keys.*/model" "$MOCK_LOG"
    echo "$output" | grep -q "Antigravity model changes are restart-only"
}

# --- T-CODEX-003: C-u sent when unread=0 and agent is idle ---

@test "T-CODEX-003: C-u cleanup sent when no unread and agent is idle" {
    run bash -c '
        MOCK_CAPTURE_PANE="› Summarize recent commits
  ? for shortcuts                100% context left"
        source "'"$TEST_HARNESS"'"
        # Simulate process_unread no-unread path
        FIRST_UNREAD_SEEN=12345
        normal_count=0
        if [ "$normal_count" -gt 0 ] 2>/dev/null; then
            echo "SHOULD_NOT_REACH"
        else
            FIRST_UNREAD_SEEN=0
            if ! agent_is_busy; then
                timeout 2 tmux send-keys -t "$PANE_TARGET" C-u 2>/dev/null
                echo "C_U_SENT"
            fi
        fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "C_U_SENT"
    grep -q "send-keys.*C-u" "$MOCK_LOG"
}

# --- T-CODEX-004: C-u NOT sent when agent is busy ---

@test "T-CODEX-004: C-u cleanup NOT sent when agent is busy" {
    rm -f "$TEST_TMPDIR/shogun_idle_test_agent"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        FIRST_UNREAD_SEEN=12345
        normal_count=0
        if [ "$normal_count" -gt 0 ] 2>/dev/null; then
            echo "SHOULD_NOT_REACH"
        else
            FIRST_UNREAD_SEEN=0
            if ! agent_is_busy; then
                timeout 2 tmux send-keys -t "$PANE_TARGET" C-u 2>/dev/null
                echo "C_U_SENT"
            else
                echo "C_U_SKIPPED"
            fi
        fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "C_U_SKIPPED"
    ! grep -q "C-u" "$MOCK_LOG"
}

# --- T-CODEX-005: claude /clear passes through as-is ---

@test "T-CODEX-005: send_cli_command sends /clear as-is for claude" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="claude"
        send_cli_command "/clear"
    '
    [ "$status" -eq 0 ]

    # Should send /clear directly (not /new)
    grep -q "send-keys.*/clear" "$MOCK_LOG"
    ! grep -q "/new" "$MOCK_LOG"
}

# --- T-CODEX-006: inbox_watcher.sh has agent_is_busy and Codex/Copilot handlers ---

@test "T-CODEX-006: inbox_watcher.sh contains agent_is_busy and Codex/Copilot handlers" {
    grep -q "agent_is_busy()" "$WATCHER_SCRIPT"
    # Busy detection patterns live in lib/agent_status.sh (shared library)
    grep -q 'Working|Thinking|Planning|Sending' "$PROJECT_ROOT/lib/agent_status.sh"

    # Codex /clear → /new conversion exists
    grep -q '/new' "$WATCHER_SCRIPT"

    # Codex /model skip exists
    grep -q 'not supported on codex' "$WATCHER_SCRIPT"

    # C-u cleanup exists
    grep -q 'C-u' "$WATCHER_SCRIPT"

    # Copilot handler exists
    grep -q 'copilot --yolo' "$WATCHER_SCRIPT"
    grep -q 'not supported on copilot' "$WATCHER_SCRIPT"
}

# --- T-CODEX-007: pane cli overrides stale CLI_TYPE in Phase2 ---

@test "T-CODEX-007: pane @agent_cli=codex overrides stale CLI_TYPE for Phase2 (no C-c)" {
    run bash -c '
        MOCK_PANE_CLI="codex"
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="claude"
        send_wakeup_with_escape 2
    '
    [ "$status" -eq 0 ]

    grep -q "send-keys.*inbox2" "$MOCK_LOG"
    # Codex: Escape escalation is suppressed (avoid interrupting work / human typing)
    ! grep -q "send-keys.*Escape" "$MOCK_LOG"
    ! grep -q "send-keys.*C-c" "$MOCK_LOG"
}

# --- T-CODEX-008: pane cli overrides stale CLI_TYPE in /clear path ---

@test "T-CODEX-008: pane @agent_cli=codex overrides stale CLI_TYPE for /clear (uses /new)" {
    run bash -c '
        MOCK_PANE_CLI="codex"
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="claude"
        send_cli_command "/clear"
    '
    [ "$status" -eq 0 ]

    grep -q "send-keys.*/new" "$MOCK_LOG"
    ! grep -q "send-keys.*/clear" "$MOCK_LOG"
    ! grep -q "send-keys.*C-c" "$MOCK_LOG"
}

# --- T-CODEX-009: invalid model_switch payload is rejected ---

@test "T-CODEX-009: normalize_special_command rejects invalid model_switch payload" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        cmd=$(normalize_special_command "model_switch" "please change model" 2>/dev/null)
        [ -z "$cmd" ]
    '
    [ "$status" -eq 0 ]
}

# --- T-CODEX-010: unresolved cli falls back to codex-safe ---

@test "T-CODEX-010: unresolved CLI type falls back to codex-safe (/clear->/new, no C-c)" {
    run bash -c '
        MOCK_PANE_CLI=""
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="unknown_cli"
        send_cli_command "/clear"
    '
    [ "$status" -eq 0 ]

    grep -q "send-keys.*/new" "$MOCK_LOG"
    ! grep -q "send-keys.*/clear" "$MOCK_LOG"
    ! grep -q "send-keys.*C-c" "$MOCK_LOG"
}

# --- T-CODEX-011: clear_command auto-recovery injection ---

@test "T-CODEX-011: process_unread injects auto-recovery task and sends inbox nudge after clear_command" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="codex"
        cat > "$INBOX" << "YAML"
messages:
  - id: msg_clear
    from: karo
    timestamp: "2026-02-10T14:00:00+09:00"
    type: clear_command
    content: redo
    read: false
YAML
        process_unread event
        "$VENV_PYTHON" - << "PY" "$INBOX"
import sys
import yaml

inbox_path = sys.argv[1]
with open(inbox_path, "r", encoding="utf-8") as f:
    data = yaml.safe_load(f) or {}

messages = data.get("messages", []) or []
msg_clear = [m for m in messages if m.get("id") == "msg_clear"]
assert len(msg_clear) == 1 and msg_clear[0].get("read") is True

auto = [
    m for m in messages
    if m.get("from") == "inbox_watcher"
    and m.get("type") == "task_assigned"
    and "[auto-recovery]" in (m.get("content") or "")
]
assert len(auto) == 1
assert auto[0].get("read") is False
print("OK")
PY
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK"

    # codex clear path uses /new
    grep -q "send-keys.*/new" "$MOCK_LOG"
    # After /new, startup prompt is sent (replaces inbox1 nudge for wake-up)
    grep -q "send-keys.*Session Start" "$MOCK_LOG"
}

@test "T-SHOGUN-005: process_unread does not auto-recover skipped shogun clear_command" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="shogun"
        PANE_TARGET="shogun:main"
        CLI_TYPE="codex"
        INBOX="'"$TEST_INBOX_DIR"'/shogun.yaml"
        LOCKFILE="${INBOX}.lock"
        cat > "$INBOX" << "YAML"
messages:
  - id: msg_clear
    from: karo
    timestamp: "2026-05-22T03:22:46+09:00"
    type: clear_command
    content: refresh
    read: false
YAML
        process_unread event
        "$VENV_PYTHON" - << "PY" "$INBOX"
import sys
import yaml

inbox_path = sys.argv[1]
with open(inbox_path, "r", encoding="utf-8") as f:
    data = yaml.safe_load(f) or {}

messages = data.get("messages", []) or []
msg_clear = [m for m in messages if m.get("id") == "msg_clear"]
assert len(msg_clear) == 1 and msg_clear[0].get("read") is True

auto = [
    m for m in messages
    if m.get("from") == "inbox_watcher"
    and m.get("type") == "task_assigned"
    and "[auto-recovery]" in (m.get("content") or "")
]
assert auto == []
print("OK")
PY
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK"

    ! grep -q "send-keys.*/new" "$MOCK_LOG"
    ! grep -q "send-keys.*/clear" "$MOCK_LOG"
}

# --- T-OPENCODE-003: OpenCode Phase 2 falls back to plain nudge ---

@test "T-OPENCODE-003: send_wakeup_with_escape falls back to plain nudge for OpenCode" {
    run bash -c '
        MOCK_CAPTURE_PANE="first line\nsecond line\nthird line\n"
        MOCK_PANE_CLI="opencode"
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="opencode"
        send_wakeup_with_escape 3
    '
    [ "$status" -eq 0 ]

    ! grep -q "send-keys.*Escape" "$MOCK_LOG"
    ! grep -q "send-keys.*C-c" "$MOCK_LOG"
    grep -q "send-keys.*C-u" "$MOCK_LOG"
    grep -q "send-keys.*inbox3" "$MOCK_LOG"
}

# --- T-CODEX-012: auto-recovery dedupe ---

@test "T-CODEX-012: enqueue_recovery_task_assigned deduplicates unread auto-recovery message" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        cat > "$INBOX" << "YAML"
messages:
  - id: msg_auto_existing
    from: inbox_watcher
    timestamp: "2026-02-10T14:00:00+09:00"
    type: task_assigned
    content: "[auto-recovery] existing hint"
    read: false
YAML
        r1=$(enqueue_recovery_task_assigned)
        r2=$(enqueue_recovery_task_assigned)
        "$VENV_PYTHON" - << "PY" "$INBOX" "$r1" "$r2"
import sys
import yaml

inbox_path, r1, r2 = sys.argv[1], sys.argv[2], sys.argv[3]
with open(inbox_path, "r", encoding="utf-8") as f:
    data = yaml.safe_load(f) or {}
messages = data.get("messages", []) or []
auto = [
    m for m in messages
    if m.get("from") == "inbox_watcher"
    and m.get("type") == "task_assigned"
    and "[auto-recovery]" in (m.get("content") or "")
    and m.get("read") is False
]
assert len(auto) == 1
assert r1 == "SKIP_DUPLICATE"
assert r2 == "SKIP_DUPLICATE"
print("OK")
PY
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK"
}

# --- T-CODEX-013: auto-recovery skipped when task is cancelled ---

@test "T-CODEX-013: enqueue_recovery_task_assigned skips if task YAML status is cancelled" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        # Initialize inbox (required by enqueue_recovery_task_assigned)
        echo "messages: []" > "$INBOX"
        # Place task YAML with status: cancelled
        mkdir -p "$(dirname "$INBOX")/../tasks"
        cat > "$(dirname "$INBOX")/../tasks/test_agent.yaml" << "YAML"
worker_id: test_agent
task_id: subtask_test_cancelled
status: cancelled
YAML
        r=$(enqueue_recovery_task_assigned)
        # Should return SKIP_CANCELLED:cancelled
        if [ "$r" = "SKIP_CANCELLED:cancelled" ]; then echo "OK"; else echo "FAIL:$r"; fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK"
}

# --- T-CODEX-014: auto-recovery skipped when task is idle ---

@test "T-CODEX-014: enqueue_recovery_task_assigned skips if task YAML status is idle" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        echo "messages: []" > "$INBOX"
        mkdir -p "$(dirname "$INBOX")/../tasks"
        cat > "$(dirname "$INBOX")/../tasks/test_agent.yaml" << "YAML"
worker_id: test_agent
task_id: subtask_test_idle
status: idle
YAML
        r=$(enqueue_recovery_task_assigned)
        if [ "$r" = "SKIP_CANCELLED:idle" ]; then echo "OK"; else echo "FAIL:$r"; fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK"
}

# --- T-CODEX-015: auto-recovery proceeds when task is assigned ---

@test "T-CODEX-015: enqueue_recovery_task_assigned proceeds when task YAML status is assigned" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        echo "messages: []" > "$INBOX"
        mkdir -p "$(dirname "$INBOX")/../tasks"
        cat > "$(dirname "$INBOX")/../tasks/test_agent.yaml" << "YAML"
worker_id: test_agent
task_id: subtask_test_assigned
status: assigned
YAML
        r=$(enqueue_recovery_task_assigned)
        # Should return a message ID (not SKIP_*)
        if [[ "$r" != SKIP_* ]] && [[ "$r" != "ERROR" ]] && [[ -n "$r" ]]; then echo "OK"; else echo "FAIL:$r"; fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK"
}

# --- T-COPILOT-001: copilot /clear → Ctrl-C + restart ---

@test "T-COPILOT-001: send_cli_command sends Ctrl-C + copilot restart for copilot /clear" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="copilot"
        send_cli_command "/clear"
    '
    [ "$status" -eq 0 ]

    # Should trigger copilot restart
    grep -q "send-keys.*C-c" "$MOCK_LOG"
    grep -q "send-keys.*copilot --yolo" "$MOCK_LOG"
    # NOT /clear or /new
    ! grep -q "send-keys.*/clear" "$MOCK_LOG"
    ! grep -q "send-keys.*/new" "$MOCK_LOG"
}

# --- T-COPILOT-002: copilot /model → skip ---

@test "T-COPILOT-002: send_cli_command skips /model for copilot" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="copilot"
        send_cli_command "/model opus"
    '
    [ "$status" -eq 0 ]

    ! grep -q "send-keys.*/model" "$MOCK_LOG"
    echo "$output" | grep -q "not supported on copilot"
}

# --- T-SHOGUN-001: session_has_client — client attached ---

@test "T-SHOGUN-001: session_has_client returns 0 when client attached" {
    run bash -c '
        MOCK_LIST_CLIENTS="/dev/pts/1: mock_session [200x50 xterm-256color]"
        source "'"$TEST_HARNESS"'"
        session_has_client
    '
    [ "$status" -eq 0 ]
}

# --- T-SHOGUN-002: session_has_client — no client ---

@test "T-SHOGUN-002: session_has_client returns 1 when no client" {
    run bash -c '
        MOCK_LIST_CLIENTS=""
        source "'"$TEST_HARNESS"'"
        session_has_client
    '
    [ "$status" -ne 0 ]
}

# --- T-SHOGUN-003: shogun + active pane + client attached → send-keys (post PR#75) ---

@test "T-SHOGUN-003: send_wakeup shogun + active + attached uses send-keys" {
    run bash -c '
        MOCK_PANE_ACTIVE="1"
        MOCK_LIST_CLIENTS="/dev/pts/1: mock_session [200x50 xterm-256color]"
        MOCK_CLIENT_ACTIVITY="100"  # cmd_182: client_activity is sufficiently old (1970) — not typing recently
        source "'"$TEST_HARNESS"'"
        AGENT_ID="shogun"
        send_wakeup 2
    '
    [ "$status" -eq 0 ]

    # Post PR#75: shogun uses send-keys like other agents (display-message path removed)
    grep -q "send-keys.*inbox2" "$MOCK_LOG"
}

# --- T-SHOGUN-004: shogun + active pane + no client → send-keys fallthrough ---

@test "T-SHOGUN-004: send_wakeup shogun + active + detached falls through to send-keys" {
    run bash -c '
        MOCK_PANE_ACTIVE="1"
        MOCK_LIST_CLIENTS=""
        MOCK_CLIENT_ACTIVITY="100"  # cmd_182: client_activity is sufficiently old (1970) — not typing recently
        source "'"$TEST_HARNESS"'"
        AGENT_ID="shogun"
        send_wakeup 2
    '
    [ "$status" -eq 0 ]

    # Should NOT show display-message path
    ! echo "$output" | grep -q "DISPLAY"

    # Should have used send-keys
    grep -q "send-keys.*inbox2" "$MOCK_LOG"
}

# --- T-SHOGUN-006: shogun typed recently → defer (display-message, no send-keys) ---

@test "T-SHOGUN-006: send_wakeup defers to display-message when shogun typed 5s ago" {
    run bash -c '
        MOCK_CLIENT_ACTIVITY="$(( $(date +%s) - 5 ))"
        source "'"$TEST_HARNESS"'"
        AGENT_ID="shogun"
        send_wakeup 2
    '
    [ "$status" -eq 0 ]

    # Direction A stays closed: no send-keys with the nudge text
    ! grep -q "send-keys.*inbox2" "$MOCK_LOG"
    # Notification still surfaces via display-message (no keystrokes, status line only)
    grep -q "display-message.*inbox2" "$MOCK_LOG"
    echo "$output" | grep -q "DEFER"
}

# --- T-SHOGUN-007 (MUST): deferral is not a drop — guard window elapses → send-keys fires ---
# Fixes the specific regression risk: "defer" silently degrading into "drop".

@test "T-SHOGUN-007: send_wakeup deferral is not a drop — send-keys fires once guard window elapses" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="shogun"

        MOCK_CLIENT_ACTIVITY="$(( $(date +%s) - 5 ))"   # typed 5s ago → defer
        send_wakeup 2

        echo "=== SPLIT_MARKER ===" >> "'"$MOCK_LOG"'"

        MOCK_CLIENT_ACTIVITY="$(( $(date +%s) - 120 ))"  # guard (60s) has elapsed → deliver
        send_wakeup 2
    '
    [ "$status" -eq 0 ]

    local before after
    before="$(sed -n "1,/SPLIT_MARKER/p" "$MOCK_LOG")"
    after="$(sed -n "/SPLIT_MARKER/,\$p" "$MOCK_LOG")"

    # Before the guard window elapsed: deferred, no send-keys yet
    ! echo "$before" | grep -q "send-keys.*inbox2"
    echo "$before" | grep -q "display-message.*inbox2"

    # After the guard window elapsed: the SAME still-unread nudge is now delivered —
    # this is the one assertion that pins "deferred" apart from "dropped"
    echo "$after" | grep -q "send-keys.*inbox2"
}

# --- T-SHOGUN-008 (MUST): client attached but activity old → send-keys fires (ntfy reply path) ---
# Fixes the PR#75 regression the original (rejected) design would have reintroduced:
# an attached-but-idle terminal (lord replying via ntfy from his phone) must still be
# reachable via send-keys — attach state alone must never suppress delivery.

@test "T-SHOGUN-008: send_wakeup delivers via send-keys when client attached but idle (ntfy reply path)" {
    run bash -c '
        MOCK_LIST_CLIENTS="/dev/pts/1: mock_session [200x50 xterm-256color]"
        MOCK_CLIENT_ACTIVITY="$(( $(date +%s) - 1200 ))"  # attached, but no keystroke in 20 minutes
        source "'"$TEST_HARNESS"'"
        AGENT_ID="shogun"
        send_wakeup 2
    '
    [ "$status" -eq 0 ]

    grep -q "send-keys.*inbox2" "$MOCK_LOG"
    ! echo "$output" | grep -q "DEFER"
}

# --- T-SHOGUN-009: non-shogun agent unaffected by recent client activity ---

@test "T-SHOGUN-009: send_wakeup for non-shogun agent ignores recent client activity" {
    run bash -c '
        MOCK_CLIENT_ACTIVITY="$(( $(date +%s) - 5 ))"
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru3"
        touch "${IDLE_FLAG_DIR:-/tmp}/shogun_idle_ashigaru3"  # match agent_is_busy() idle-flag lookup for the overridden AGENT_ID
        send_wakeup 2
    '
    [ "$status" -eq 0 ]

    grep -q "send-keys.*inbox2" "$MOCK_LOG"
    ! echo "$output" | grep -q "DEFER"
}

# --- T-SHOGUN-010: no client at all → human_typing_recently is false → send-keys fires ---

@test "T-SHOGUN-010: send_wakeup delivers via send-keys when no client is attached at all" {
    run bash -c '
        MOCK_LIST_CLIENTS=""
        MOCK_CLIENT_ACTIVITY=""
        source "'"$TEST_HARNESS"'"
        AGENT_ID="shogun"
        send_wakeup 2
    '
    [ "$status" -eq 0 ]

    grep -q "send-keys.*inbox2" "$MOCK_LOG"
    ! echo "$output" | grep -q "DEFER"
}

# --- T-SHOGUN-011 (MUST, cmd_182 QC40-F1): deferral re-arms re-evaluation ---
# shogun's watcher runs with ASW_PROCESS_TIMEOUT=0 (event-driven only), so
# without SHOGUN_DEFER_PENDING there is no "next cycle" to re-check a
# deferred nudge. Pins: (a) should_process_timeout_tick() — the extracted
# main-loop gate — stays closed by default and opens only while a defer is
# pending; (b) SHOGUN_DEFER_PENDING flips 1 on defer and back to 0 once the
# nudge actually reaches the pane.

@test "T-SHOGUN-011: deferral sets SHOGUN_DEFER_PENDING and re-opens the timeout gate until delivered" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="shogun"

        ASW_PROCESS_TIMEOUT=0
        SHOGUN_DEFER_PENDING=0
        should_process_timeout_tick; echo "TICK_BEFORE_DEFER=$?"

        MOCK_CLIENT_ACTIVITY="$(( $(date +%s) - 5 ))"    # typed 5s ago -> defer
        send_wakeup 2
        echo "DEFER_PENDING_AFTER_DEFER=$SHOGUN_DEFER_PENDING"
        should_process_timeout_tick; echo "TICK_AFTER_DEFER=$?"

        MOCK_CLIENT_ACTIVITY="$(( $(date +%s) - 120 ))"  # guard (60s) elapsed -> delivered
        send_wakeup 2
        echo "DEFER_PENDING_AFTER_SEND=$SHOGUN_DEFER_PENDING"
        should_process_timeout_tick; echo "TICK_AFTER_SEND=$?"

        # reset_shogun_defer_state is also the unread=0 reset path (process_unread
        # calls it once the inbox drains); pin it directly since driving the full
        # process_unread flow through this harness is not practical.
        SHOGUN_DEFER_PENDING=1
        SHOGUN_DEFER_NTFY_SENT=1
        reset_shogun_defer_state
        echo "UNREAD_ZERO_RESET=${SHOGUN_DEFER_PENDING}${SHOGUN_DEFER_NTFY_SENT}"
    '
    [ "$status" -eq 0 ]

    echo "$output" | grep -q "TICK_BEFORE_DEFER=1" \
        || { echo "expected timeout gate closed before any defer (event-driven default); output: $output"; false; }
    echo "$output" | grep -q "DEFER_PENDING_AFTER_DEFER=1" \
        || { echo "expected SHOGUN_DEFER_PENDING=1 immediately after the defer branch; output: $output"; false; }
    echo "$output" | grep -q "TICK_AFTER_DEFER=0" \
        || { echo "expected timeout gate reopened (rc=0) while a defer is pending; output: $output"; false; }
    echo "$output" | grep -q "DEFER_PENDING_AFTER_SEND=0" \
        || { echo "expected SHOGUN_DEFER_PENDING reset to 0 once send-keys actually delivered; output: $output"; false; }
    echo "$output" | grep -q "TICK_AFTER_SEND=1" \
        || { echo "expected timeout gate closed again after defer resolved; output: $output"; false; }
    echo "$output" | grep -q "UNREAD_ZERO_RESET=00" \
        || { echo "expected reset_shogun_defer_state (unread=0 reset path) to clear both flags; output: $output"; false; }
}

# --- T-SHOGUN-012 (MUST, cmd_182 QC40-F2): deferred ntfy fires once per episode ---
# Without a one-shot guard, once QC40-F1 reopens the timeout gate the ntfy
# insurance path would fire every ~30s for as long as the defer continues
# (a dead path turning into a flood). Pins that 3 send_wakeup calls while
# still deferred and past the ntfy threshold produce exactly 1 notify call.

@test "T-SHOGUN-012: deferred ntfy notification fires only once per defer episode" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        NOTIFY_LOG="'"$TEST_TMPDIR"'/notify.log"
        > "$NOTIFY_LOG"
        # Real network (ntfy) must not be hit in tests — override after sourcing,
        # same style as test_baton_watchdog.bats.
        branch_policy_notify() { echo "NOTIFY: $1" >> "$NOTIFY_LOG"; return 0; }

        AGENT_ID="shogun"
        MOCK_CLIENT_ACTIVITY="$(( $(date +%s) - 5 ))"     # always typed recently -> always defer
        FIRST_UNREAD_SEEN=$(( $(date +%s) - 400 ))         # past default 300s ntfy threshold

        send_wakeup 2
        send_wakeup 2
        send_wakeup 2

        calls=$(grep -c "NOTIFY:" "$NOTIFY_LOG")
        echo "NOTIFY_CALLS=$calls"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "NOTIFY_CALLS=1" \
        || { echo "expected exactly 1 branch_policy_notify call across 3 deferred send_wakeup calls; output: $output"; false; }
}

# --- T-BUSY-005: agent_is_busy during /clear cooldown ---

@test "T-BUSY-005: agent_is_busy returns 0 (busy) during /clear cooldown period" {
    run bash -c '
        MOCK_CAPTURE_PANE="› prompt
  ? for shortcuts                100% context left"
        source "'"$TEST_HARNESS"'"
        now=$(date +%s)
        LAST_CLEAR_TS=$((now - 10))  # /clear sent 10 seconds ago (within 30s cooldown)
        agent_is_busy
    '
    [ "$status" -eq 0 ]
}

# --- T-BUSY-006: agent_is_busy idle after /clear cooldown expires ---

@test "T-BUSY-006: agent_is_busy returns 1 (idle) after /clear cooldown expires" {
    run bash -c '
        MOCK_CAPTURE_PANE="› prompt
  ? for shortcuts                100% context left"
        source "'"$TEST_HARNESS"'"
        now=$(date +%s)
        LAST_CLEAR_TS=$((now - 40))  # /clear sent 40 seconds ago (past 30s cooldown)
        agent_is_busy
    '
    [ "$status" -eq 1 ]
}

# --- T-BUSY-007: /clear cooldown overrides idle pane ---

@test "T-BUSY-007: agent_is_busy /clear cooldown overrides idle pane state" {
    run bash -c '
        MOCK_CAPTURE_PANE="› Summarize recent commits
  ? for shortcuts                100% context left"
        source "'"$TEST_HARNESS"'"
        now=$(date +%s)
        LAST_CLEAR_TS=$((now - 5))  # /clear sent 5 seconds ago
        # Pane looks idle, but cooldown should make it busy
        if agent_is_busy; then
            echo "BUSY_DURING_COOLDOWN"
        else
            echo "WRONGLY_IDLE"
        fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "BUSY_DURING_COOLDOWN"
}

# --- T-BUSY-008: idle prompt at bottom overrides old busy markers (false-busy fix) ---
# Bug: 59ec12f / 69c1ecb — old "Working" or "esc to interrupt" lingered in scroll-back
# above the idle prompt, causing false-busy. Fix: only check bottom 5 lines, idle first.

@test "T-BUSY-008: agent_is_busy returns idle when idle prompt is below old busy markers" {
    run bash -c '
        MOCK_CAPTURE_PANE="$(printf "◦ Working on task (12s • esc to interrupt)\nsome output line\nmore output\n\n❯ ")"
        source "'"$TEST_HARNESS"'"
        LAST_CLEAR_TS=0
        if agent_is_busy; then
            echo "WRONGLY_BUSY"
        else
            echo "CORRECTLY_IDLE"
        fi
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "CORRECTLY_IDLE"
}

# --- T-BUSY-009: 'background terminal running' detected as busy ---
# Bug: 91ebf61 — Codex shows this when a tool is running in background.

@test "T-BUSY-009: agent_is_busy detects 'background terminal running' as busy" {
    run bash -c '
        MOCK_CAPTURE_PANE="$(printf "Some output\nbackground terminal running\n")"
        source "'"$TEST_HARNESS"'"
        LAST_CLEAR_TS=0
        CLI_TYPE="codex"  # pane-based detection (non-claude fallback)
        agent_is_busy
    '
    [ "$status" -eq 0 ]
}

# --- T-BUSY-010: 'Compacting conversation' detected as busy ---

@test "T-BUSY-010: agent_is_busy detects 'Compacting conversation' as busy" {
    run bash -c '
        MOCK_CAPTURE_PANE="$(printf "Compacting conversation...\n")"
        source "'"$TEST_HARNESS"'"
        LAST_CLEAR_TS=0
        CLI_TYPE="codex"  # pane-based detection (non-claude fallback)
        agent_is_busy
    '
    [ "$status" -eq 0 ]
}

# --- T-BUSY-011: 'esc to interrupt' detected as busy ---

@test "T-BUSY-011: agent_is_busy detects 'esc to interrupt' as busy" {
    run bash -c '
        MOCK_CAPTURE_PANE="$(printf "◦ Thinking (5s • esc to interrupt)\n")"
        source "'"$TEST_HARNESS"'"
        LAST_CLEAR_TS=0
        CLI_TYPE="codex"  # pane-based detection (non-claude fallback)
        agent_is_busy
    '
    [ "$status" -eq 0 ]
}

# --- T-BUSY-012: OpenCode idle home screen detected as idle ---

@test "T-BUSY-012: agent_is_busy detects OpenCode home screen as idle" {
    run bash -c '
        MOCK_CAPTURE_PANE="$(printf "  ┃\n  ┃  Ask anything...\n  ┃\n\n                                                   ctrl+p commands\n")"
        MOCK_PANE_CLI="opencode"
        source "'"$TEST_HARNESS"'"
        LAST_CLEAR_TS=0
        CLI_TYPE="opencode"
        agent_is_busy
    '
    [ "$status" -eq 1 ]
}

# --- T-BUSY-013: OpenCode busy sidebar detected as busy ---

@test "T-BUSY-013: agent_is_busy detects OpenCode busy sidebar as busy" {
    run bash -c '
        MOCK_CAPTURE_PANE="$(printf "  ┃  think something deeper\n     → Skill \"requirements-clarification\"\n\n   ■⬝⬝⬝⬝⬝⬝⬝  esc interrupt\n")"
        MOCK_PANE_CLI="opencode"
        source "'"$TEST_HARNESS"'"
        LAST_CLEAR_TS=0
        CLI_TYPE="opencode"
        agent_is_busy
    '
    [ "$status" -eq 0 ]
}

# --- T-BUSY-014: OpenCode busy animation row detected as busy ---

@test "T-BUSY-014: agent_is_busy detects OpenCode busy animation row as busy" {
    run bash -c '
        MOCK_CAPTURE_PANE="$(printf "   ■⬝⬝⬝⬝⬝⬝⬝\n")"
        MOCK_PANE_CLI="opencode"
        source "'"$TEST_HARNESS"'"
        LAST_CLEAR_TS=0
        CLI_TYPE="opencode"
        agent_is_busy
    '
    [ "$status" -eq 0 ]
}

# --- T-BUSY-015: blank OpenCode pane falls back to idle ---

@test "T-BUSY-015: agent_is_busy treats blank OpenCode pane as idle fallback" {
    run bash -c '
        MOCK_CAPTURE_PANE=""
        MOCK_PANE_CLI="opencode"
        source "'"$TEST_HARNESS"'"
        LAST_CLEAR_TS=0
        CLI_TYPE="opencode"
        agent_is_busy
    '
    [ "$status" -eq 1 ]
}

@test "T-BUSY-016: OpenCode busy animation fallback works without python3" {
    run bash -c '
        PATH="/nonexistent"
        source "'"$PROJECT_ROOT"'/lib/agent_status.sh"
        opencode_has_busy_animation "$(printf "   ⬝⬝■⬝⬝⬝⬝⬝  esc interrupt\n")"
    '
    [ "$status" -eq 0 ]
}

# --- T-SHOOK-001: Claude Code throttle uses 60s cooldown (post PR#75: stop-hook supplementary) ---

@test "T-SHOOK-001: Claude Code throttle uses 60s cooldown (stop-hook-supplementary)" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="claude"
        LAST_NUDGE_TS=0
        LAST_NUDGE_COUNT=""

        # First call: should pass through (no throttle)
        should_throttle_nudge 1
        rc1=$?

        # Simulate 60s elapsed — cooldown expired for claude (60s, same as default)
        LAST_NUDGE_TS=$(($(date +%s) - 60))
        LAST_NUDGE_COUNT=1

        # Second call with same count after 60s: should NOT throttle (cooldown expired)
        should_throttle_nudge 1
        rc2=$?

        echo "rc1=$rc1 rc2=$rc2"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "rc1=1 rc2=1"  # 1=not-throttled, 1=not-throttled (60s cooldown expired)
}

# --- T-SHOOK-002: Claude Code count change bypasses throttle (post PR#75: standard behavior) ---

@test "T-SHOOK-002: Claude Code count change bypasses throttle (stop-hook-supplementary)" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="claude"
        LAST_NUDGE_TS=0
        LAST_NUDGE_COUNT=""

        # First call: should pass through
        should_throttle_nudge 1
        rc1=$?

        # Simulate 30s elapsed, count changed from 1 to 2
        LAST_NUDGE_TS=$(($(date +%s) - 30))

        # Post PR#75: Claude uses standard throttle logic.
        # Count change (1→2) bypasses throttle for ALL CLIs including claude.
        should_throttle_nudge 2
        rc2=$?

        echo "rc1=$rc1 rc2=$rc2"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "rc1=1 rc2=1"  # Both: 1=not-throttled (count change bypasses)
}

# --- T-SHOOK-003: Non-Claude CLIs bypass throttle on count change ---

@test "T-SHOOK-003: Non-Claude CLIs still bypass throttle on count change" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="copilot"
        LAST_NUDGE_TS=0
        LAST_NUDGE_COUNT=""

        # First call
        should_throttle_nudge 1
        rc1=$?

        # Simulate 30s elapsed, count changed from 1 to 2
        LAST_NUDGE_TS=$(($(date +%s) - 30))

        # For copilot, count change (1→2) SHOULD bypass throttle
        should_throttle_nudge 2
        rc2=$?

        echo "rc1=$rc1 rc2=$rc2"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "rc1=1 rc2=1"  # Both pass through (count changed)
}

# --- T-SHOOK-004: all-read reset clears nudge throttle for next inbox1 batch ---

@test "T-SHOOK-004: all-read reset clears nudge throttle for same-count next batch" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="codex"
        cat > "$INBOX" <<YAML
messages: []
YAML
        LAST_NUDGE_TS=$(date +%s)
        LAST_NUDGE_COUNT=1
        FIRST_UNREAD_SEEN=123

        process_unread event

        should_throttle_nudge 1
        rc=$?
        echo "last_ts=$LAST_NUDGE_TS last_count=${LAST_NUDGE_COUNT:-empty} rc=$rc"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "rc=1"  # 1 = not throttled
}

# --- T-CODEX-016: Codex transcript echo is not treated as stuck input ---

@test "T-CODEX-016: send_wakeup codex treats transcript echo as delivered" {
    run bash -c '
        MOCK_CAPTURE_PANE="$(printf "› inbox1\n  gpt-5.5 xhigh · ~/repo\n")"
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="codex"
        send_wakeup 1
    '
    [ "$status" -eq 0 ]

    echo "$output" | grep -q "cli=codex"
    ! echo "$output" | grep -q "nudge text still visible"
    [ "$(grep -c "send-keys -t test:0.0 inbox1" "$MOCK_LOG")" -eq 1 ]
}

# --- T-CRESET-001: send_context_reset suppresses /clear for karo ---

@test "T-CRESET-001: send_context_reset suppresses /clear for karo" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="karo"
        send_context_reset
    '
    [ "$status" -eq 0 ]

    # No send-keys should have occurred
    ! grep -q "send-keys" "$MOCK_LOG"

    # SKIP message in stderr
    echo "$output" | grep -q "SKIP.*karo"
}

# --- T-CRESET-002: send_context_reset suppresses /clear for gunshi ---

@test "T-CRESET-002: send_context_reset suppresses /clear for gunshi" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="gunshi"
        send_context_reset
    '
    [ "$status" -eq 0 ]

    # No send-keys should have occurred
    ! grep -q "send-keys" "$MOCK_LOG"

    # SKIP message in stderr
    echo "$output" | grep -q "SKIP.*gunshi"
}

# --- T-CRESET-003: send_context_reset sends /clear for ashigaru ---

@test "T-CRESET-003: send_context_reset sends /clear for ashigaru" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru3"
        CLI_TYPE="claude"
        send_context_reset
    '
    [ "$status" -eq 0 ]

    # /clear should have been sent via send-keys
    grep -q "send-keys.*/clear" "$MOCK_LOG"
}

# --- T-CRESET-004: send_context_reset sends /new for opencode ---

@test "T-CRESET-004: send_context_reset sends /new for opencode" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru3"
        CLI_TYPE="opencode"
        send_context_reset
    '
    [ "$status" -eq 0 ]

    # C-u for input clear, then /new — no Escape (function removed)
    grep -q "send-keys.*C-u" "$MOCK_LOG"
    grep -q "send-keys.*/new" "$MOCK_LOG"
    ! grep -q "send-keys.*/clear" "$MOCK_LOG"
    ! grep -q "send-keys.*Escape" "$MOCK_LOG"
    ! grep -q "send-keys.*C-c" "$MOCK_LOG"
}

# --- T-MODAL-GATE-01 (cmd_209 subtask_209_modal_gate_fix) ---
#
# Reproduces the live bug from gunshi_rca_209_modal_autoclose.yaml: for
# claude, agent_is_busy() consults ONLY the idle flag file, never pane
# content (L2). The flag is never deleted during normal operation (L3), so
# it reads "idle" even while an AskUserQuestion modal is open in the pane —
# and send_wakeup's nudge Enter confirms the modal's first option (L1).
#
# setup() already touches the idle flag for test_agent (line ~176), so
# agent_is_busy() reports idle here exactly as it wrongly did in production.
# MOCK_CAPTURE_PANE carries a modal footer split across two lines the way
# T-MODAL-01 (tests/integration/test_stall_detect_livepane.bats) reproduces
# the real footer — this is what pane_has_open_modal() must catch where the
# idle flag cannot.
#
# Before this fix: send_wakeup has no modal-aware gate at all, so it falls
# straight to the send-keys nudge (Enter included). After this fix: the
# pane_has_open_modal() gate added ahead of the send-keys block intercepts
# it and no keys are sent (verified: reverting the send_wakeup gate hunk
# alone reproduces a failing run of this test against otherwise-current
# code).
@test "T-MODAL-GATE-01: send_wakeup suppresses Enter into an open modal even though the idle flag says idle" {
    export MOCK_CAPTURE_PANE="Enter to select · ↑/↓ to navigate · Esc to
cancel"
    run bash -c "source '$TEST_HARNESS' && send_wakeup 1"
    [ "$status" -eq 0 ]

    echo "$output" | grep -q "SKIP-MODAL" \
        || { echo "expected a [SKIP-MODAL] log line; output: $output"; false; }
    ! grep -q "send-keys.*inbox1" "$MOCK_LOG" \
        || { echo "nudge text must not reach the pane while a modal is open"; cat "$MOCK_LOG"; false; }
    ! grep -q "send-keys.*Enter" "$MOCK_LOG" \
        || { echo "Enter must not reach the pane while a modal is open (would confirm the modal's first option)"; cat "$MOCK_LOG"; false; }
}

# --- T-MODAL-GATE-02 (cmd_216 F-4) ---
#
# Live-measured (gunshi QC, cmd_209 PR#97 F-4): claude's first-run folder
# trust dialog footer reads "Enter to confirm · Esc to cancel" — none of
# pane_has_open_modal()'s pre-existing anchors ('enter to select' / 'to
# navigate' / '↑/↓') match it, so the dialog passed through this predicate
# undetected even though agent_is_busy_check() already caught it separately
# via its own 'esc to' last-line rule. This adds the missing 'enter to
# confirm' anchor.
@test "T-MODAL-GATE-02: send_wakeup suppresses Enter into an open folder-trust dialog (enter to confirm)" {
    export MOCK_CAPTURE_PANE="Do you trust the files in this folder?

❯ 1. Yes, proceed
  2. No, exit

Enter to confirm · Esc to cancel"
    run bash -c "source '$TEST_HARNESS' && send_wakeup 1"
    [ "$status" -eq 0 ]

    echo "$output" | grep -q "SKIP-MODAL" \
        || { echo "expected a [SKIP-MODAL] log line; output: $output"; false; }
    ! grep -q "send-keys.*inbox1" "$MOCK_LOG" \
        || { echo "nudge text must not reach the pane while the trust dialog is open"; cat "$MOCK_LOG"; false; }
    ! grep -q "send-keys.*Enter" "$MOCK_LOG" \
        || { echo "Enter must not reach the pane while the trust dialog is open (would confirm it)"; cat "$MOCK_LOG"; false; }
}
