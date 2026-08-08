#!/usr/bin/env bats
# test_two_marker_busy_idle.bats — cmd_217 二枚の印（busy印/idle印）方式
#
# 設計原本: queue/reports/gunshi_design_217_idle_flag_liveness.yaml
#
# テスト構成:
#   T-217-01: busy印のみ存在 → busy
#   T-217-02: idle印のみ存在 → idle
#   T-217-03: 両方存在・busyが新しい → busy
#   T-217-04: 両方存在・idleが新しい → idle
#   T-217-05: 両方同秒 → busy（安全側）
#   T-217-06: busy印が存在しない（hook未装填） → idle（今日と同一への縮退）
#   T-217-07: 未読ありで300秒busy継続 → idle印がtouchされ配送再開＋警告1回
#   T-217-08: nudge3回でbusy印が一度も出ない → [HOOK-UNARMED]が一度だけ
#   T-217-08b: busy印が現れれば [HOOK-ARMED] が一度だけ
#   T-217-09: send_context_reset がbusy中に呼ばれる → 送出しない（かつ非0 return で defer とわかる）
#   T-217-11: UserPromptSubmit hookがtmux不在で走る → exit 0（プロンプトを壊さない）
#
# 変異試験（M1-M8）は本ファイルのテストで捕捉されることを個別に確認済み
# （queue/reports 側の実装報告に記載）。

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
AGENT_STATUS_LIB="$SCRIPT_DIR/lib/agent_status.sh"
WATCHER_SCRIPT="$SCRIPT_DIR/scripts/inbox_watcher.sh"
UPS_HOOK="$SCRIPT_DIR/scripts/user_prompt_submit_hook.sh"

setup_file() {
    export PROJECT_ROOT="$SCRIPT_DIR"
    export VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"
    [ -f "$AGENT_STATUS_LIB" ] || return 1
    [ -f "$WATCHER_SCRIPT" ] || return 1
    [ -f "$UPS_HOOK" ] || return 1
    "$VENV_PYTHON" -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export IDLE_FLAG_DIR="$(mktemp -d "$BATS_TMPDIR/two_marker_test.XXXXXX")"
}

teardown() {
    rm -rf "$IDLE_FLAG_DIR"
}

# ─── T-217-01..06: agent_turn_state() 直接テスト ───

@test "T-217-01: busy印のみ存在 → busy" {
    touch "$IDLE_FLAG_DIR/shogun_busy_t217"
    run bash -c "source '$AGENT_STATUS_LIB'; agent_turn_state t217"
    [ "$status" -eq 0 ]
    [ "$output" = "busy" ]
}

@test "T-217-02: idle印のみ存在 → idle" {
    touch "$IDLE_FLAG_DIR/shogun_idle_t217"
    run bash -c "source '$AGENT_STATUS_LIB'; agent_turn_state t217"
    [ "$status" -eq 0 ]
    [ "$output" = "idle" ]
}

@test "T-217-03: 両方存在・busyが新しい → busy" {
    touch -d "@$(( $(date +%s) - 10 ))" "$IDLE_FLAG_DIR/shogun_idle_t217"
    touch -d "@$(date +%s)" "$IDLE_FLAG_DIR/shogun_busy_t217"
    run bash -c "source '$AGENT_STATUS_LIB'; agent_turn_state t217"
    [ "$status" -eq 0 ]
    [ "$output" = "busy" ]
}

@test "T-217-04: 両方存在・idleが新しい → idle" {
    touch -d "@$(( $(date +%s) - 10 ))" "$IDLE_FLAG_DIR/shogun_busy_t217"
    touch -d "@$(date +%s)" "$IDLE_FLAG_DIR/shogun_idle_t217"
    run bash -c "source '$AGENT_STATUS_LIB'; agent_turn_state t217"
    [ "$status" -eq 0 ]
    [ "$output" = "idle" ]
}

@test "T-217-05: 両方同秒 → busy（安全側）" {
    local now
    now=$(date +%s)
    touch -d "@$now" "$IDLE_FLAG_DIR/shogun_idle_t217"
    touch -d "@$now" "$IDLE_FLAG_DIR/shogun_busy_t217"
    run bash -c "source '$AGENT_STATUS_LIB'; agent_turn_state t217"
    [ "$status" -eq 0 ]
    [ "$output" = "busy" ]
}

@test "T-217-06: busy印が存在しない（hook未装填）→ idle" {
    rm -f "$IDLE_FLAG_DIR/shogun_busy_t217" "$IDLE_FLAG_DIR/shogun_idle_t217"
    run bash -c "source '$AGENT_STATUS_LIB'; agent_turn_state t217"
    [ "$status" -eq 0 ]
    [ "$output" = "idle" ]
}

# ─── watcher harness (T-217-07/08/09) ───

_build_watcher_harness() {
    export TEST_HOOK_TMP="$(mktemp -d "$BATS_TMPDIR/hook_tmp.XXXXXX")"
    mkdir -p "$TEST_HOOK_TMP/queue/inbox" "$TEST_HOOK_TMP/scripts"
    cat > "$TEST_HOOK_TMP/scripts/inbox_write.sh" << 'MOCK'
#!/bin/bash
echo "$@" >> "$(dirname "$0")/../inbox_write_calls.log"
MOCK
    chmod +x "$TEST_HOOK_TMP/scripts/inbox_write.sh"

    export MOCK_LOG="$IDLE_FLAG_DIR/tmux_calls.log"
    > "$MOCK_LOG"
    export NOTIFY_LOG="$IDLE_FLAG_DIR/notify.log"
    > "$NOTIFY_LOG"

    export MOCK_PGREP="$IDLE_FLAG_DIR/mock_pgrep"
    cat > "$MOCK_PGREP" << 'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$MOCK_PGREP"

    export MOCK_CAPTURE_PANE=""
    export MOCK_PANE_CLI=""
    export MOCK_SENDKEYS_RC=0

    export WATCHER_HARNESS="$IDLE_FLAG_DIR/watcher_harness.sh"
    cat > "$WATCHER_HARNESS" << HARNESS
#!/bin/bash
AGENT_ID="t217agent"
PANE_TARGET="test:0.0"
CLI_TYPE="claude"
INBOX="$TEST_HOOK_TMP/queue/inbox/t217agent.yaml"
LOCKFILE="\${INBOX}.lock"
SCRIPT_DIR="$PROJECT_ROOT"
export IDLE_FLAG_DIR="$IDLE_FLAG_DIR"

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
        return 0
    fi
    if echo "\$*" | grep -q "display-message"; then
        echo "mock_session"
        return 0
    fi
    return 0
}
timeout() { shift; "\$@"; }
pgrep() { "$MOCK_PGREP" "\$@"; }
sleep() { :; }
branch_policy_notify() { echo "NOTIFY: \$1" >> "$NOTIFY_LOG"; return 0; }
export -f tmux timeout pgrep sleep branch_policy_notify

export __INBOX_WATCHER_TESTING__=1
source "$WATCHER_SCRIPT"
HARNESS
    chmod +x "$WATCHER_HARNESS"
}

teardown_watcher_harness() {
    rm -rf "$TEST_HOOK_TMP"
}

# ─── T-217-07: 未読ありで300秒busy継続 → idle印touch＋警告1回 ───

@test "T-217-07: stale-busy safety net force-touches idle印 after 300s and notifies once" {
    _build_watcher_harness
    touch "$IDLE_FLAG_DIR/shogun_busy_t217agent"

    cat > "$TEST_HOOK_TMP/queue/inbox/t217agent.yaml" << 'YAML'
messages:
- content: task
  from: karo
  id: msg_001
  read: false
  timestamp: '2026-01-01T00:00:00'
  type: task_assigned
YAML

    run bash -c "
        source '$WATCHER_HARNESS'
        now=\$(date +%s)
        FIRST_UNREAD_SEEN=\$((now - 301))
        process_unread event
    "
    [ "$status" -eq 0 ]

    echo "$output" | grep -qi "hook不発の疑い" \
        || { echo "expected hook不発の疑い wording; output: $output"; false; }

    [ "$(grep -c 'NOTIFY:' "$NOTIFY_LOG")" -eq 1 ] \
        || { echo "expected exactly 1 branch_policy_notify call; log: $(cat "$NOTIFY_LOG")"; false; }

    teardown_watcher_harness
}

# ─── T-217-08: nudge3回でbusy印が一度も出ない → [HOOK-UNARMED]が一度だけ ───

@test "T-217-08: three nudges with busy印 never appearing logs HOOK-UNARMED exactly once" {
    _build_watcher_harness
    rm -f "$IDLE_FLAG_DIR/shogun_busy_t217agent"

    # should_throttle_nudge suppresses repeat sends of the same unread count
    # within its cooldown window — vary the count (1,2,3) so all three
    # send_wakeup calls actually reach the send-keys success path and
    # check_hook_armed, matching how count changes bypass throttling in
    # production (see T-SHOOK-002 in test_send_wakeup.bats).
    run bash -c "
        source '$WATCHER_HARNESS'
        HOOK_ARMED_CHECK_N=3
        send_wakeup 1
        send_wakeup 2
        send_wakeup 3
    "
    [ "$status" -eq 0 ]

    [ "$(echo "$output" | grep -c 'HOOK-UNARMED')" -eq 1 ] \
        || { echo "expected exactly 1 [HOOK-UNARMED] log line; output: $output"; false; }
    [ "$(grep -c 'NOTIFY:' "$NOTIFY_LOG")" -eq 1 ] \
        || { echo "expected exactly 1 branch_policy_notify call for HOOK-UNARMED; log: $(cat "$NOTIFY_LOG")"; false; }

    teardown_watcher_harness
}

@test "T-217-08b: busy印 appearing before N nudges logs HOOK-ARMED exactly once, no HOOK-UNARMED" {
    _build_watcher_harness
    # A busy印 that exists but is STALE (older than a fresh idle印) still
    # proves the hook has fired at least once this session — check_hook_armed
    # only checks existence, not freshness (§2-3: "一度でも現れたか"). Keep
    # the agent's CURRENT state idle (idle印 newer) so send_wakeup's own busy
    # gate doesn't itself suppress the nudge before check_hook_armed runs.
    touch -d "@$(( $(date +%s) - 100 ))" "$IDLE_FLAG_DIR/shogun_busy_t217agent"
    touch "$IDLE_FLAG_DIR/shogun_idle_t217agent"

    run bash -c "
        source '$WATCHER_HARNESS'
        HOOK_ARMED_CHECK_N=3
        send_wakeup 1
        send_wakeup 2
    "
    [ "$status" -eq 0 ]

    [ "$(echo "$output" | grep -c 'HOOK-ARMED')" -eq 1 ] \
        || { echo "expected exactly 1 [HOOK-ARMED] log line; output: $output"; false; }
    ! echo "$output" | grep -q "HOOK-UNARMED"

    teardown_watcher_harness
}

# ─── T-217-09: send_context_reset がbusy中に呼ばれる → 送出しない ───

@test "T-217-09: send_context_reset defers (no send, non-zero return) while agent is busy" {
    _build_watcher_harness
    touch "$IDLE_FLAG_DIR/shogun_busy_t217agent"

    run bash -c "
        source '$WATCHER_HARNESS'
        LAST_CLEAR_TS=0
        if send_context_reset; then
            echo RESET_SENT
        else
            echo RESET_DEFERRED
        fi
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "RESET_DEFERRED"
    ! grep -q "send-keys" "$MOCK_LOG"

    teardown_watcher_harness
}

@test "T-217-09b: send_context_reset sends /clear when agent is idle" {
    _build_watcher_harness
    # no busy flag -> idle

    run bash -c "
        source '$WATCHER_HARNESS'
        LAST_CLEAR_TS=0
        if send_context_reset; then
            echo RESET_SENT
        else
            echo RESET_DEFERRED
        fi
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "RESET_SENT"
    grep -q "send-keys.*/clear" "$MOCK_LOG"

    teardown_watcher_harness
}

# ─── T-217-11: UserPromptSubmit hookがtmux不在で走る → exit 0 ───

@test "T-217-11: user_prompt_submit_hook.sh exits 0 with no TMUX_PANE (does not break prompt submission)" {
    run bash -c "unset TMUX_PANE; IDLE_FLAG_DIR='$IDLE_FLAG_DIR' bash '$UPS_HOOK'"
    [ "$status" -eq 0 ]
}

@test "T-217-11b: user_prompt_submit_hook.sh touches busy印 when TMUX_PANE resolves an agent" {
    export MOCK_LOG="$IDLE_FLAG_DIR/tmux_calls.log"
    > "$MOCK_LOG"
    run bash -c "
        tmux() {
            echo \"tmux \$*\" >> '$MOCK_LOG'
            if echo \"\$*\" | grep -q display-message; then
                echo 't217hookagent'
                return 0
            fi
            return 0
        }
        export -f tmux
        export TMUX_PANE='test:0.0'
        IDLE_FLAG_DIR='$IDLE_FLAG_DIR' bash '$UPS_HOOK'
    "
    [ "$status" -eq 0 ]
    [ -f "$IDLE_FLAG_DIR/shogun_busy_t217hookagent" ]
}

# ─── M8 guard: process_unread must never touch idle印 for claude ───
# This is the mutation the design calls out as most important (§6 M8):
# reverting the removal of the gated idle印 touch in inbox_watcher.sh would
# reintroduce today's actual bug — a genuinely busy claude agent flips back
# to idle the moment process_unread ticks, because the old code touched
# shogun_idle_<agent> whenever the pane merely *looked* idle (broken at
# width 44) or unconditionally in the fast path. Under the two-marker
# design, claude's idle印 must come ONLY from hooks (or the 300s stale-busy
# net) — never from inbox_watcher.sh's regular per-tick paths.

@test "T-217-M8a: process_unread fast-path (unread=0) does not touch idle印 for claude while busy" {
    _build_watcher_harness
    touch "$IDLE_FLAG_DIR/shogun_busy_t217agent"
    rm -f "$IDLE_FLAG_DIR/shogun_idle_t217agent"

    cat > "$TEST_HOOK_TMP/queue/inbox/t217agent.yaml" << 'YAML'
messages: []
YAML

    run bash -c "
        source '$WATCHER_HARNESS'
        FIRST_UNREAD_SEEN=0
        process_unread timeout
    "
    [ "$status" -eq 0 ]

    [ ! -f "$IDLE_FLAG_DIR/shogun_idle_t217agent" ] \
        || { echo 'M8 regression: fast-path touched idle印 for claude while genuinely busy'; false; }

    run bash -c "source '$AGENT_STATUS_LIB'; agent_turn_state t217agent"
    [ "$output" = "busy" ] \
        || { echo "expected agent_turn_state to remain busy after fast-path tick; got: $output"; false; }

    teardown_watcher_harness
}

@test "T-217-M8b: process_unread no-unread slow path does not touch idle印 for claude while busy" {
    _build_watcher_harness
    touch "$IDLE_FLAG_DIR/shogun_busy_t217agent"
    rm -f "$IDLE_FLAG_DIR/shogun_idle_t217agent"

    cat > "$TEST_HOOK_TMP/queue/inbox/t217agent.yaml" << 'YAML'
messages:
- content: old message
  from: karo
  id: msg_001
  read: true
  timestamp: '2026-01-01T00:00:00'
  type: task_assigned
YAML

    run bash -c "
        source '$WATCHER_HARNESS'
        FIRST_UNREAD_SEEN=0
        process_unread event
    "
    [ "$status" -eq 0 ]

    [ ! -f "$IDLE_FLAG_DIR/shogun_idle_t217agent" ] \
        || { echo 'M8 regression: no-unread slow path touched idle印 for claude while genuinely busy'; false; }

    run bash -c "source '$AGENT_STATUS_LIB'; agent_turn_state t217agent"
    [ "$output" = "busy" ] \
        || { echo "expected agent_turn_state to remain busy after no-unread tick; got: $output"; false; }

    teardown_watcher_harness
}

@test "T-217-11c: user_prompt_submit_hook.sh exits 0 even if touch target dir is unwritable" {
    run bash -c "
        tmux() { echo 't217hookagent'; return 0; }
        export -f tmux
        export TMUX_PANE='test:0.0'
        IDLE_FLAG_DIR='/nonexistent/no/such/dir' bash '$UPS_HOOK'
    "
    [ "$status" -eq 0 ]
}
