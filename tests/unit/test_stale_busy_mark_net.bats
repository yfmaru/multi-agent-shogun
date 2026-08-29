#!/usr/bin/env bats
# test_stale_busy_mark_net.bats — cmd_243: unread-independent stale-busy-mark
# net (3rd safety net, in liveness_tick) + AC2 display-layer fallback narrowing.
#
# Background: queue/reports/gunshi_design_243_busy_idle_stale_gap.yaml.
# The legacy safety nets (inbox_watcher.sh:2214/2371) gate on
# FIRST_UNREAD_SEEN, a proxy for busy印's age that is reset to 0 by both
# process_unread() branches whenever unread==0 (§0-D) — so a busy印 frozen
# by a Stop-hook-not-firing death can never trip them while no unread
# message ever arrives. stale_busy_mark_net() reads the busy印's own mtime
# directly instead, and is wired into liveness_tick() — the unread-
# independent wall-clock (cmd_218) — so it fires regardless.
#
# Harness style mirrors tests/unit/test_liveness_tick.bats: sources the REAL
# inbox_watcher.sh with __INBOX_WATCHER_TESTING__=1 (never source it raw —
# that runs the real main loop against real queue/, memory:
# feedback_never_source_resident_daemon_raw). No real tmux pane or process
# is ever touched.
#
# テスト構成 (§E3):
#   T-243-01: 是正前は process_unread 単体では救われぬ（構造的分離。
#             是正後も green のままであるべき回帰）
#   T-243-02: liveness_tick 経由なら救われる（busy印齢>=300s AND 画面停止
#             >=300s AND 未読0）
#   T-243-03: 画面が動いていれば発火せぬ（cmd_217 D-1 の維持）
#   T-243-04: capture 不能なら発火せぬ（T-D4）
#   T-243-05: busy印が無ければ何もせぬ（hook未装填への縮退）
#   T-243-06: 入力待ち画面（modal）では印を触らず通知だけ出す
#   T-243-07: 非claudeでは発火せぬ
#   T-243-08: get_pane_busy_rc: hook装填済み(ups印あり)かつturn_state==idle
#             かつ画面に'esc to interrupt'が残る → 待機中(rc=1)（§B-2の直列性）
#   T-243-09: get_pane_busy_rc: ups印もbusy印も無い(未装填) → 従来どおり
#             pane解析へ落ちる（cmd_220 F-1 の維持）
#   T-243-10: liveness_tick の呼び出し順（attempt_stall_recovery が
#             stale_busy_mark_net より先）を固定する（§A1 call_order /
#             §A-4 R2(a)。gunshi_report.yaml F-1 recommendation (1)）
#   T-243-11: AGENT_ID=shogun でも T-243-02 と同じ発火を要求する
#             （§A3-2。shogun除外変異を検出する。F-1 recommendation (2)）
#   T-243-12: 強制idle化時、NTFY_LOG に1件、文言に「強制idle化」を含む
#             通知が出ることを検める（§A-4 R2(b)。F-1 recommendation (3)）

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
WATCHER_SCRIPT="$SCRIPT_DIR/scripts/inbox_watcher.sh"
AGENT_STATUS_LIB="$SCRIPT_DIR/lib/agent_status.sh"

setup_file() {
    export PROJECT_ROOT="$SCRIPT_DIR"
    export VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"
    [ -f "$WATCHER_SCRIPT" ] || return 1
    [ -f "$AGENT_STATUS_LIB" ] || return 1
    "$VENV_PYTHON" -c "import yaml" 2>/dev/null || return 1
}

# G8_CAPTURE: real "esc to interrupt" working-status tail (same fixture
# family as test_cmd229_detector_fixes.bats G8_CAPTURE) — a screen that
# LOOKS busy (last line carries the interrupt hint) but is frozen because
# the turn actually died. This is exactly the scenario the net targets.
WORKING_CAPTURE=$'some output line\nmore output\n\xe2\x97\xa6 Working on task (12s \xe2\x80\xa2 esc to interrupt)'

# G1_CAPTURE-style modal: an AskUserQuestion footer (enter to select / to
# navigate / esc to cancel all present in the bottom block).
MODAL_CAPTURE=$'\xe2\x9d\xaf Pick a color:\n\n\xe2\x9d\xaf 1. Red\n 2. Blue\n\nEnter to select \xc2\xb7 \xe2\x86\x91/\xe2\x86\x93 to navigate \xc2\xb7 Esc to cancel'

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/stale_busy_mark_test.XXXXXX")"
    export IDLE_FLAG_DIR="$TEST_TMPDIR"
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
    echo "messages: []" > "$TEST_INBOX_DIR/test_agent.yaml"

    # Defaults: no capture-pane-non-J mock sequence, capture succeeds,
    # attempt_stall_recovery disabled (opt-in default) so it never
    # interferes with stale_busy_mark_net's own state.
    export MOCK_CAPTURE_PANE=""
    export MOCK_CAPTURE_RC="0"
    export MOCK_CAPTURE_MOVING="0"
    export MOCK_CAPTURE_COUNTER_FILE="$TEST_TMPDIR/capture_counter"
    echo 0 > "$MOCK_CAPTURE_COUNTER_FILE"
    export MOCK_SENDKEYS_RC=0
    export MOCK_PANE_CLI=""
    export MOCK_STALL_ENABLED="false"

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

tmux() {
    echo "tmux \$*" >> "$MOCK_LOG"
    if echo "\$*" | grep -q "capture-pane"; then
        if [ "\${MOCK_CAPTURE_RC:-0}" -ne 0 ]; then
            return "\${MOCK_CAPTURE_RC}"
        fi
        if [ "\${MOCK_CAPTURE_MOVING:-0}" = "1" ]; then
            local n
            n=\$(cat "$TEST_TMPDIR/capture_counter" 2>/dev/null || echo 0)
            echo "moving screen tick \$n"
            echo \$((n + 1)) > "$TEST_TMPDIR/capture_counter"
            return 0
        fi
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
        if echo "\$*" | grep -q "pane_active"; then
            echo "0"
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

stall_policy_query() {
    case "\$1" in
        enabled) echo "\${MOCK_STALL_ENABLED:-false}" ;;
        *) echo "" ;;
    esac
}
export -f stall_policy_query

usage_limit_state() { echo "ok"; }
export -f usage_limit_state

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

seed_stale_busy_mark_hash() {
    # Seeds STALE_BUSY_MARK_HASH/_SINCE so pane_hash_frozen_sec reports the
    # requested frozen duration on the FIRST call (no need to actually wait).
    local content="$1"
    local age="${2:-500}"
    printf 'STALE_BUSY_MARK_HASH=$(printf %%s %q | cksum | awk "{print \\$1}")\n' "$content"
    printf 'STALE_BUSY_MARK_HASH_SINCE=$(( $(date +%%s) - %d ))\n' "$age"
}

# ─── T-243-01: 是正前は process_unread 単体では救われぬ ───

@test "T-243-01: process_unread alone (timeout and event ticks) never touches idle印 for a stale busy印 — structurally isolated from stale_busy_mark_net" {
    touch "$TEST_TMPDIR/shogun_busy_ashigaru9"
    touch -d "@$(( $(date +%s) - 600 ))" "$TEST_TMPDIR/shogun_busy_ashigaru9"
    rm -f "$TEST_TMPDIR/shogun_idle_ashigaru9"

    MOCK_CAPTURE_PANE="$WORKING_CAPTURE" run bash -c "
        source '$TEST_HARNESS'
        FIRST_UNREAD_SEEN=0
        process_unread timeout
        process_unread event
    "
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_TMPDIR/shogun_idle_ashigaru9" ] \
        || { echo 'FAIL: process_unread alone must never reach stale_busy_mark_net (liveness_tick-only wiring)'; false; }
}

# ─── T-243-02: liveness_tick 経由なら救われる ───

@test "T-243-02: liveness_tick fires stale_busy_mark_net when busy印 age>=300s AND pane frozen>=300s AND unread=0" {
    touch "$TEST_TMPDIR/shogun_busy_ashigaru9"
    touch -d "@$(( $(date +%s) - 600 ))" "$TEST_TMPDIR/shogun_busy_ashigaru9"
    rm -f "$TEST_TMPDIR/shogun_idle_ashigaru9"

    MOCK_CAPTURE_PANE="$WORKING_CAPTURE" run bash -c "
        source '$TEST_HARNESS'
        $(seed_stale_busy_mark_hash "$WORKING_CAPTURE" 500)
        LIVENESS_LAST_TS=0
        liveness_tick
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '\[STALE-BUSY-MARK\]' \
        || { echo "FAIL: expected [STALE-BUSY-MARK] log line; output: $output"; false; }
    [ -f "$TEST_TMPDIR/shogun_idle_ashigaru9" ] \
        || { echo 'FAIL: idle印 was not touched'; false; }
    [ "$(stat -c %Y "$TEST_TMPDIR/shogun_idle_ashigaru9")" -ge "$(stat -c %Y "$TEST_TMPDIR/shogun_busy_ashigaru9")" ] \
        || { echo 'FAIL: idle印 mtime is not newer than busy印 (turn_state would stay busy)'; false; }
}

# ─── T-243-03: 画面が動いていれば発火せぬ ───

@test "T-243-03: a moving screen (hash changes every tick) never lets frozen_sec reach the limit — no fire" {
    touch "$TEST_TMPDIR/shogun_busy_ashigaru9"
    touch -d "@$(( $(date +%s) - 600 ))" "$TEST_TMPDIR/shogun_busy_ashigaru9"
    rm -f "$TEST_TMPDIR/shogun_idle_ashigaru9"

    MOCK_CAPTURE_MOVING=1 run bash -c "
        source '$TEST_HARNESS'
        for i in 1 2 3; do
            LIVENESS_LAST_TS=0
            liveness_tick
        done
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '\[STALE-BUSY-MARK\]' \
        && { echo "FAIL: fired despite a screen that keeps moving; output: $output"; false; }
    [ ! -f "$TEST_TMPDIR/shogun_idle_ashigaru9" ] \
        || { echo 'FAIL: idle印 touched despite a moving screen (D-1 regression, N-3 scenario)'; false; }
}

# ─── T-243-04: capture 不能なら発火せぬ (T-D4) ───

@test "T-243-04: capture-pane failure (rc!=0) is treated as indeterminate, not frozen — no fire" {
    touch "$TEST_TMPDIR/shogun_busy_ashigaru9"
    touch -d "@$(( $(date +%s) - 600 ))" "$TEST_TMPDIR/shogun_busy_ashigaru9"
    rm -f "$TEST_TMPDIR/shogun_idle_ashigaru9"

    MOCK_CAPTURE_RC=1 run bash -c "
        source '$TEST_HARNESS'
        LIVENESS_LAST_TS=0
        liveness_tick
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '\[STALE-BUSY-MARK\]' \
        && { echo "FAIL: fired despite capture-pane failing; output: $output"; false; }
    [ ! -f "$TEST_TMPDIR/shogun_idle_ashigaru9" ] \
        || { echo 'FAIL: idle印 touched despite capture-pane failure (T-D4 regression)'; false; }
}

# ─── T-243-05: busy印が無ければ何もせぬ ───

@test "T-243-05: no busy印 at all (hook not yet armed) — stale_busy_mark_net no-ops" {
    rm -f "$TEST_TMPDIR/shogun_busy_ashigaru9" "$TEST_TMPDIR/shogun_idle_ashigaru9"

    MOCK_CAPTURE_PANE="$WORKING_CAPTURE" run bash -c "
        source '$TEST_HARNESS'
        LIVENESS_LAST_TS=0
        liveness_tick
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '\[STALE-BUSY-MARK\]' \
        && { echo "FAIL: fired without a busy印 present; output: $output"; false; }
    [ ! -f "$TEST_TMPDIR/shogun_idle_ashigaru9" ] \
        || { echo 'FAIL: idle印 created without a busy印 ever existing'; false; }
}

# ─── T-243-06: 入力待ち画面（modal）では印を触らず通知だけ出す ───

@test "T-243-06: a modal screen (awaiting input) is never forced idle — notify only, busy印 untouched" {
    touch "$TEST_TMPDIR/shogun_busy_ashigaru9"
    touch -d "@$(( $(date +%s) - 600 ))" "$TEST_TMPDIR/shogun_busy_ashigaru9"
    rm -f "$TEST_TMPDIR/shogun_idle_ashigaru9"

    MOCK_CAPTURE_PANE="$MODAL_CAPTURE" run bash -c "
        source '$TEST_HARNESS'
        $(seed_stale_busy_mark_hash "$MODAL_CAPTURE" 500)
        LIVENESS_LAST_TS=0
        liveness_tick
    "
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_TMPDIR/shogun_idle_ashigaru9" ] \
        || { echo 'FAIL: idle印 was forced despite the screen being a modal (would cut a real in-progress question)'; false; }
    [ "$(grep -c 'NOTIFY:' "$NTFY_LOG")" -eq 1 ] \
        || { echo "FAIL: expected exactly 1 notify for the modal case; log: $(cat "$NTFY_LOG")"; false; }
    grep -q '要人手' "$NTFY_LOG" \
        || { echo "FAIL: notify wording missing the modal-specific 要人手 phrasing; log: $(cat "$NTFY_LOG")"; false; }
}

# ─── T-243-07: 非claudeでは発火せぬ ───

@test "T-243-07: non-claude CLI type never fires (two-marker scheme is claude-only)" {
    touch "$TEST_TMPDIR/shogun_busy_ashigaru9"
    touch -d "@$(( $(date +%s) - 600 ))" "$TEST_TMPDIR/shogun_busy_ashigaru9"
    rm -f "$TEST_TMPDIR/shogun_idle_ashigaru9"

    MOCK_CAPTURE_PANE="$WORKING_CAPTURE" MOCK_PANE_CLI="codex" run bash -c "
        source '$TEST_HARNESS'
        $(seed_stale_busy_mark_hash "$WORKING_CAPTURE" 500)
        LIVENESS_LAST_TS=0
        liveness_tick
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '\[STALE-BUSY-MARK\]' \
        && { echo "FAIL: fired for a non-claude CLI type; output: $output"; false; }
    [ ! -f "$TEST_TMPDIR/shogun_idle_ashigaru9" ] \
        || { echo 'FAIL: idle印 touched for a non-claude CLI type'; false; }
}

# ─── T-243-08 / T-243-09: get_pane_busy_rc AC2 fallback narrowing ───
# Direct lib/agent_status.sh tests (no inbox_watcher.sh harness needed) —
# same style as test_cmd229_detector_fixes.bats Group A.

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
    source "$AGENT_STATUS_LIB"
}

@test "T-243-08: get_pane_busy_rc returns idle(rc=1) when hook is armed (ups印) even though turn_state=idle and the screen shows 'esc to interrupt'" {
    export TEST_LIB_TMPDIR="$(mktemp -d "$BATS_TMPDIR/lib_only_test.XXXXXX")"
    export IDLE_FLAG_DIR="$TEST_LIB_TMPDIR"
    touch "$TEST_LIB_TMPDIR/shogun_ups_t243agent"
    # turn_state must be idle: no busy印 at all (armed only via ups印).
    rm -f "$TEST_LIB_TMPDIR/shogun_busy_t243agent" "$TEST_LIB_TMPDIR/shogun_idle_t243agent"

    setup_lib_only
    MOCK_CAPTURE_PANE="$WORKING_CAPTURE"
    run get_pane_busy_rc "fake:0.0" "claude" "t243agent"
    [ "$status" -eq 1 ] \
        || { echo "FAIL: expected rc=1 (待機中) — hook-armed idle turn_state must not fall through to pane analysis; got rc=$status"; false; }
    rm -rf "$TEST_LIB_TMPDIR"
}

@test "T-243-09: get_pane_busy_rc still falls through to pane analysis when hook is unarmed (no ups印, no busy印) — cmd_220 F-1 preserved" {
    export TEST_LIB_TMPDIR="$(mktemp -d "$BATS_TMPDIR/lib_only_test.XXXXXX")"
    export IDLE_FLAG_DIR="$TEST_LIB_TMPDIR"
    rm -f "$TEST_LIB_TMPDIR/shogun_ups_t243agent" "$TEST_LIB_TMPDIR/shogun_busy_t243agent" "$TEST_LIB_TMPDIR/shogun_idle_t243agent"

    setup_lib_only
    MOCK_CAPTURE_PANE="$WORKING_CAPTURE"
    run get_pane_busy_rc "fake:0.0" "claude" "t243agent"
    [ "$status" -eq 0 ] \
        || { echo "FAIL: expected rc=0 (busy via pane-analysis fallback, 'esc to interrupt' last line) when hook unarmed; got rc=$status"; false; }
    rm -rf "$TEST_LIB_TMPDIR"
}

# ─── T-243-10: liveness_tick の呼び出し順を固定する ───
# gunshi_report.yaml F-1: 設計 §A1 call_order・§A-4 R2(a) は「stall層に
# 先番を譲る」順序そのものを退行防止の手当てと位置づける。順序を入れ
# 替える変異（liveness_tick 内で stale_busy_mark_net を
# attempt_stall_recovery より先に呼ぶ）が62ケース全green だった穴を塞ぐ。

@test "T-243-10: liveness_tick calls attempt_stall_recovery before stale_busy_mark_net (call-order invariant, §A1/§A-4 R2(a))" {
    run bash -c "
        source '$TEST_HARNESS'
        ORDER_LOG='$TEST_TMPDIR/call_order.log'
        attempt_stall_recovery() { echo stall >> \"\$ORDER_LOG\"; }
        stale_busy_mark_net() { echo stale >> \"\$ORDER_LOG\"; }
        LIVENESS_LAST_TS=0
        liveness_tick
        cat \"\$ORDER_LOG\"
    "
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'stall\nstale')" ] \
        || { echo "FAIL: expected call order [attempt_stall_recovery, stale_busy_mark_net] (stall層先番); got: $output"; false; }
}

# ─── T-243-11: AGENT_ID=shogun でも同じ発火を要求する ───
# gunshi_report.yaml F-1: 設計 §A3-2 は shogun を意図して含めた
# （legacy 2枚は逆に shogun を除外している）。shogun を除外する変異
# （`[[ "$AGENT_ID" != "shogun" ]] || return 0` を足す）が
# 検出されなかった穴を塞ぐ。

@test "T-243-11: liveness_tick fires stale_busy_mark_net for AGENT_ID=shogun exactly as for any other agent (§A3-2 — shogun is intentionally included)" {
    touch "$TEST_TMPDIR/shogun_busy_shogun"
    touch -d "@$(( $(date +%s) - 600 ))" "$TEST_TMPDIR/shogun_busy_shogun"
    rm -f "$TEST_TMPDIR/shogun_idle_shogun"

    MOCK_CAPTURE_PANE="$WORKING_CAPTURE" run bash -c "
        source '$TEST_HARNESS'
        AGENT_ID='shogun'
        $(seed_stale_busy_mark_hash "$WORKING_CAPTURE" 500)
        LIVENESS_LAST_TS=0
        liveness_tick
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '\[STALE-BUSY-MARK\]' \
        || { echo "FAIL: expected [STALE-BUSY-MARK] log line for AGENT_ID=shogun; output: $output"; false; }
    [ -f "$TEST_TMPDIR/shogun_idle_shogun" ] \
        || { echo 'FAIL: idle印 was not touched for AGENT_ID=shogun (shogun must not be excluded)'; false; }
}

# ─── T-243-12: 強制idle化時、通知に「強制idle化」を含む ───
# gunshi_report.yaml F-1: 設計 §A-4 R2(b) は、この通知を「stall層の
# エスカレーションを先回りして潰すこと」への代償と位置づける。T-243-06は
# modal経路の通知だけを固定しており、強制idle経路（非modal）の
# stale_busy_mark_notify 呼び出しを削る変異は検出されなかった。

@test "T-243-12: forced-idle path (non-modal) notifies once with wording containing 強制idle化 (§A-4 R2(b))" {
    touch "$TEST_TMPDIR/shogun_busy_ashigaru9"
    touch -d "@$(( $(date +%s) - 600 ))" "$TEST_TMPDIR/shogun_busy_ashigaru9"
    rm -f "$TEST_TMPDIR/shogun_idle_ashigaru9"

    MOCK_CAPTURE_PANE="$WORKING_CAPTURE" run bash -c "
        source '$TEST_HARNESS'
        $(seed_stale_busy_mark_hash "$WORKING_CAPTURE" 500)
        LIVENESS_LAST_TS=0
        liveness_tick
    "
    [ "$status" -eq 0 ]
    [ -f "$TEST_TMPDIR/shogun_idle_ashigaru9" ] \
        || { echo 'FAIL: precondition broken — idle印 was not touched (forced-idle path did not run)'; false; }
    [ "$(grep -c 'NOTIFY:' "$NTFY_LOG")" -eq 1 ] \
        || { echo "FAIL: expected exactly 1 notify for the forced-idle case; log: $(cat "$NTFY_LOG")"; false; }
    grep -q '強制idle化' "$NTFY_LOG" \
        || { echo "FAIL: notify wording missing 強制idle化 phrasing (R2(b) 代償が欠落); log: $(cat "$NTFY_LOG")"; false; }
}
