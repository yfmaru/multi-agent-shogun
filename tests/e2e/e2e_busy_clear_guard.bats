#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# E2E-009: busy中/clear抑制テスト
# ═══════════════════════════════════════════════════════════════
# Verifies inbox_watcher behavior when clear_command arrives while
# an agent is working:
#   - busy state: clear_command is deferred (no /clear sent)
#   - idle state: clear_command is sent to the agent
# ═══════════════════════════════════════════════════════════════

# bats file_tags=e2e

load "../test_helper/bats-support/load"
load "../test_helper/bats-assert/load"

E2E_HELPERS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/helpers" && pwd)"
source "$E2E_HELPERS_DIR/setup.bash"
source "$E2E_HELPERS_DIR/assertions.bash"
source "$E2E_HELPERS_DIR/tmux_helpers.bash"

setup_file() {
    command -v tmux &>/dev/null || skip "tmux not available"
    command -v python3 &>/dev/null || skip "python3 not available"
    python3 -c "import yaml" 2>/dev/null || skip "python3-yaml not available"

    setup_e2e_session 2
    mkdir -p "$E2E_QUEUE/.venv/bin"
    ln -sf "$(command -v python3)" "$E2E_QUEUE/.venv/bin/python3"
}

teardown_file() {
    teardown_e2e_session
}

setup() {
    reset_queues
    mkdir -p "$E2E_QUEUE/.venv/bin"
    ln -sf "$(command -v python3)" "$E2E_QUEUE/.venv/bin/python3"
    sleep 2
}

wait_for_log() {
    local log_file="$1" pattern="$2" timeout="${3:-20}"
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        if grep -qF "$pattern" "$log_file" 2>/dev/null; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    echo "TIMEOUT: '$pattern' not found in $log_file after ${timeout}s" >&2
    return 1
}

# inbox_message_is_read / wait_for_inbox_read (cmd_220 F-A/F-E) are defined
# in helpers/assertions.bash (loaded above) — shared with e2e_idle_flag_recovery.bats.

# ═══ E2E-009-A: clear_command is deferred while busy ═══

@test "E2E-009-A: clear_command is deferred when agent is busy (no /clear sent)" {
    local ashigaru1_pane
    ashigaru1_pane=$(pane_target 1)
    local log_file watcher_pid

    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_ashigaru1_basic.yaml" \
        "$E2E_QUEUE/queue/tasks/ashigaru1.yaml"

    # Keep mock in busy state before clear_command arrives.
    send_to_pane "$ashigaru1_pane" "busy_hold 2"
    sleep 2

    tmux set-option -p -t "$ashigaru1_pane" @agent_cli "copilot"
    log_file="/tmp/e2e_inbox_watcher_ashigaru1_busy_${BASHPID}.log"
    watcher_pid=$(
        bash "$E2E_QUEUE/scripts/inbox_watcher.sh" "ashigaru1" "$ashigaru1_pane" "copilot" \
            > "$log_file" 2>&1 &
        echo $!
    )
    sleep 2

    bash "$E2E_QUEUE/scripts/inbox_write.sh" "ashigaru1" \
        "/clear" "clear_command" "karo"

    local clear_msg_id
    clear_msg_id=$(python3 -c "
import yaml
with open('$E2E_QUEUE/queue/inbox/ashigaru1.yaml') as f:
    data = yaml.safe_load(f) or {}
for m in data.get('messages', []) or []:
    if m.get('type') == 'clear_command':
        print(m.get('id', ''))
" 2>/dev/null)
    [ -n "$clear_msg_id" ]

    run wait_for_log "$log_file" "[SKIP] Agent ashigaru1 is busy — /clear (clear_command) deferred to next cycle"
    assert_success

    # Busy suppression keeps task unprocessed by /clear path.
    run wait_for_yaml_value "$E2E_QUEUE/queue/tasks/ashigaru1.yaml" "task.status" "assigned" 30
    assert_success

    run grep -qF "[SEND-KEYS] Copilot /clear: sending Ctrl-C + restart for ashigaru1" "$log_file"
    [ "$status" -ne 0 ]

    # cmd_220 F-A: deferral must not be consumption. get_unread_info()
    # peeked this message (that's how the [SKIP] log above knows about it)
    # but must NOT have marked it read on that peek — otherwise "deferred to
    # next cycle" is a lie and there is no next cycle (gunshi RCA
    # gunshi_rca_ashigaru1_baton_drop_fix2, L2).
    [ "$(inbox_message_is_read "$E2E_QUEUE/queue/inbox/ashigaru1.yaml" "$clear_msg_id")" = "false" ]

    stop_inbox_watcher "$watcher_pid"
}

# ═══ E2E-009-C: deferred clear_command is actually delivered once busy clears ═══
# cmd_220 F-E: E2E-009-A only proved the deferral log line and that the
# message survives one peek. It never proved delivery actually completes
# once the agent stops being busy — the exact gap the gunshi RCA
# (gunshi_rca_ashigaru1_baton_drop_fix2) found: "deferred to next cycle" was
# logged while the message was silently consumed, so there never was a next
# cycle. This test drives busy/idle via the busy印/idle印 files directly
# (same technique as E2E-010-B) instead of the copilot mock's free-running
# busy_hold text timer — the copilot fallback busy-text matcher in
# lib/agent_status.sh scans the whole bottom-5-lines window (not just the
# last line) and keeps matching stale "Working..." text long after the mock
# returns to idle, which makes natural busy-clear timing for that path
# unrelated to this fix and unsuitable for a deterministic assertion here
# (separate pre-existing issue, out of scope for cmd_220). claude's busy
# verdict instead comes from agent_turn_state()'s busy印/idle印 mtime
# comparison (cmd_217), which this test controls directly and deterministically.

@test "E2E-009-C: deferred clear_command is delivered once busy clears" {
    local ashigaru1_pane
    ashigaru1_pane=$(pane_target 1)
    local flag_dir log_file watcher_pid
    local ashigaru_idle_flag ashigaru_busy_flag

    flag_dir="$(mktemp -d "/tmp/e2e_idle_flags_deferred_XXXXXX")"
    ashigaru_idle_flag="$flag_dir/shogun_idle_ashigaru1"
    ashigaru_busy_flag="$flag_dir/shogun_busy_ashigaru1"

    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_ashigaru1_basic.yaml" \
        "$E2E_QUEUE/queue/tasks/ashigaru1.yaml"

    # Seed busy (busy印 newer than idle印) before the watcher ever starts, so
    # agent_turn_state() reads busy from cycle 1 — same technique E2E-010-B
    # uses to make claude's two-marker busy verdict deterministic.
    touch "$ashigaru_idle_flag"
    sleep 1
    touch "$ashigaru_busy_flag"

    tmux set-option -p -t "$ashigaru1_pane" @agent_cli "claude"
    log_file="/tmp/e2e_inbox_watcher_ashigaru1_deferred_delivery_${BASHPID}.log"
    watcher_pid=$(
        IDLE_FLAG_DIR="$flag_dir" \
        bash "$E2E_QUEUE/scripts/inbox_watcher.sh" "ashigaru1" "$ashigaru1_pane" "claude" \
            > "$log_file" 2>&1 &
        echo $!
    )
    sleep 2

    bash "$E2E_QUEUE/scripts/inbox_write.sh" "ashigaru1" \
        "/clear" "clear_command" "karo"

    local clear_msg_id
    clear_msg_id=$(python3 -c "
import yaml
with open('$E2E_QUEUE/queue/inbox/ashigaru1.yaml') as f:
    data = yaml.safe_load(f) or {}
for m in data.get('messages', []) or []:
    if m.get('type') == 'clear_command':
        print(m.get('id', ''))
" 2>/dev/null)
    [ -n "$clear_msg_id" ]

    run wait_for_log "$log_file" "[SKIP] Agent ashigaru1 is busy — /clear (clear_command) deferred to next cycle"
    assert_success

    [ "$(inbox_message_is_read "$E2E_QUEUE/queue/inbox/ashigaru1.yaml" "$clear_msg_id")" = "false" ]

    # Simulate the Stop hook firing (turn ends): idle印 becomes newer than
    # busy印, so agent_turn_state() flips to idle on the watcher's next check.
    touch "$ashigaru_idle_flag"

    # No new inbox write happens here, so delivery can only come from the
    # periodic INOTIFY_TIMEOUT fallback tick (default 30s) re-evaluating the
    # still-unread clear_command — 40s comfortably covers one tick.
    run wait_for_log "$log_file" "[SEND-KEYS] Sending CLI command to ashigaru1 (claude): /clear" 40
    assert_success

    # send_cli_command() blocks in send_startup_prompt() (up to 3×5s retries
    # + the actual prompt send) before returning and mark_special_read()
    # runs, so the read-commit lands well after the SEND-KEYS log line above
    # — 30s covers that.
    run wait_for_inbox_read "$E2E_QUEUE/queue/inbox/ashigaru1.yaml" "$clear_msg_id" 30
    assert_success

    stop_inbox_watcher "$watcher_pid"
    rm -rf "$flag_dir"
}

# ═══ E2E-009-B: clear_command is sent when idle ═══

@test "E2E-009-B: clear_command is sent when agent is idle" {
    local ashigaru1_pane
    ashigaru1_pane=$(pane_target 1)
    local log_file watcher_pid
    local idle_flag="/tmp/shogun_idle_ashigaru1"

    touch "$idle_flag"

    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_ashigaru1_basic.yaml" \
        "$E2E_QUEUE/queue/tasks/ashigaru1.yaml"

    tmux set-option -p -t "$ashigaru1_pane" @agent_cli "claude"
    log_file="/tmp/e2e_inbox_watcher_ashigaru1_idle_${BASHPID}.log"
    watcher_pid=$(
        bash "$E2E_QUEUE/scripts/inbox_watcher.sh" "ashigaru1" "$ashigaru1_pane" "claude" \
            > "$log_file" 2>&1 &
        echo $!
    )
    sleep 2

    bash "$E2E_QUEUE/scripts/inbox_write.sh" "ashigaru1" \
        "/clear" "clear_command" "karo"

    run wait_for_log "$log_file" "[SEND-KEYS] Sending CLI command to ashigaru1 (claude): /clear"
    assert_success

    run wait_for_yaml_value "$E2E_QUEUE/queue/tasks/ashigaru1.yaml" "task.status" "done" 45
    assert_success

    stop_inbox_watcher "$watcher_pid"
}
