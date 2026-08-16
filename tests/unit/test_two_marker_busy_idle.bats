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
#   T-217-07: 未読ありで300秒busy継続「かつ」画面停止 → idle印がtouchされ配送再開＋警告1回（D-1）
#   T-217-D1: 300秒busy継続だが画面が動き続けている → force-idleを撃たない（D-1の核心、N-3の再現防止）
#   T-217-08: nudge3回でups印が一度も出ない → [HOOK-UNARMED]が一度だけ
#   T-217-08b: ups印のmtimeがnudge間で前進すれば [HOOK-ARMED] が一度だけ（HOOK_ARMED_DEFERRED_EVAL）。
#              cmd_217 QC是正F-B: 3回目のnudge（ups印を再度前進）は一度きり旗
#              (HOOK_ARMED_LOGGED)そのものの検査である（2回目までではARMEDが
#              出る唯一の機会にしかならず、旗が壊れていても区別できない）
#   T-217-09: send_context_reset がbusy中に呼ばれる → 送出しない（かつ非0 return で defer とわかる）
#   T-217-11: UserPromptSubmit hookがtmux不在で走る → exit 0（プロンプトを壊さない）
#
# 変異試験（M1-M8, M7=D-1のpane hash門撤去）は本ファイルのテストで捕捉
# されることを個別に確認済み（queue/reports 側の実装報告に記載）。

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

    # cmd_229 AC-4: pane_input_safety() now gates every claude-type Enter
    # route; an empty capture classifies `unknown` (deny), not the old
    # "not modal" (allow). Default to a bare idle prompt — the baseline
    # "safe" screen — so tests that don't specifically exercise a
    # modal/working/unknown fixture keep exercising the send path.
    export MOCK_CAPTURE_PANE="❯"
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

# ─── T-217-07: 未読ありで300秒busy継続「かつ」画面停止 → idle印touch＋
#     警告1回（cmd_217 D-1: age単独では足りぬ。N-3参照）───

@test "T-217-07: stale-busy safety net force-touches idle印 after 300s of busy-age AND a frozen pane, notifies once" {
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

    local frozen_content='frozen busy pane content'
    run bash -c "
        MOCK_CAPTURE_PANE='$frozen_content'
        source '$WATCHER_HARNESS'
        now=\$(date +%s)
        FIRST_UNREAD_SEEN=\$((now - 301))
        STALE_BUSY_HASH=\$(printf '%s' '$frozen_content' | cksum | awk '{print \$1}')
        STALE_BUSY_HASH_SINCE=\$((now - 500))
        process_unread event
    "
    [ "$status" -eq 0 ]

    echo "$output" | grep -qi "hook不発の疑い" \
        || { echo "expected hook不発の疑い wording; output: $output"; false; }

    [ "$(grep -c 'NOTIFY:' "$NOTIFY_LOG")" -eq 1 ] \
        || { echo "expected exactly 1 branch_policy_notify call; log: $(cat "$NOTIFY_LOG")"; false; }

    teardown_watcher_harness
}

# ─── T-217-D1: 未読ありで300秒busy継続だが画面が動き続けている →
#     force-idleを撃たない（D-1の核心。今宵の病そのものの再現）───

@test "T-217-D1: stale-busy safety net does NOT force-idle when the pane hash is still fresh (screen just moved)" {
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

    # No STALE_BUSY_HASH seeded — the very first pane_hash_frozen_sec()
    # observation always reports 0s frozen (first sighting of this hash),
    # exactly like a screen that just changed. Busy-age alone (301s) must
    # NOT be enough on its own (this is the N-3 bug being guarded against).
    run bash -c "
        MOCK_CAPTURE_PANE='some pane content'
        source '$WATCHER_HARNESS'
        now=\$(date +%s)
        FIRST_UNREAD_SEEN=\$((now - 301))
        process_unread event
    "
    [ "$status" -eq 0 ]

    [ ! -f "$IDLE_FLAG_DIR/shogun_idle_t217agent" ] \
        || { echo "N-3 regression: force-idle fired on busy-age alone while the pane hash was fresh"; false; }
    echo "$output" | grep -q "Stop hook will deliver" \
        || { echo "expected the genuinely-busy claude branch to run instead; output: $output"; false; }

    teardown_watcher_harness
}

# ─── T-217-08: nudge3回でbusy印が一度も出ない → [HOOK-UNARMED]が一度だけ ───

@test "T-217-08: four nudges with busy印 never appearing logs HOOK-UNARMED exactly once" {
    _build_watcher_harness
    rm -f "$IDLE_FLAG_DIR/shogun_busy_t217agent"

    # should_throttle_nudge suppresses repeat sends of the same unread count
    # within its cooldown window — vary the count (1,2,3,4) so all four
    # send_wakeup calls actually reach the send-keys success path and
    # check_hook_armed, matching how count changes bypass throttling in
    # production (see T-SHOOK-002 in test_send_wakeup.bats).
    #
    # cmd_217 QC (gunshi_qc_217_pr100.yaml F-2): the threshold N=3 means
    # only the 3rd nudge ever reaches NUDGE_SEND_COUNT>=N, so a 3-nudge
    # test can't distinguish "logged once" from "one-shot flag removed" —
    # both look identical at exactly 1 line. A 4th nudge (N+1) is required
    # to prove the one-shot flag (HOOK_UNARMED_LOGGED) actually suppresses
    # the 2nd would-be log line, since production nudges indefinitely and a
    # broken one-shot flag means [HOOK-UNARMED] (and the ntfy it triggers)
    # fires on every nudge from the 3rd onward.
    run bash -c "
        source '$WATCHER_HARNESS'
        HOOK_ARMED_CHECK_N=3
        send_wakeup 1
        send_wakeup 2
        send_wakeup 3
        send_wakeup 4
    "
    [ "$status" -eq 0 ]

    [ "$(echo "$output" | grep -c 'HOOK-UNARMED')" -eq 1 ] \
        || { echo "expected exactly 1 [HOOK-UNARMED] log line; output: $output"; false; }
    [ "$(grep -c 'NOTIFY:' "$NOTIFY_LOG")" -eq 1 ] \
        || { echo "expected exactly 1 branch_policy_notify call for HOOK-UNARMED; log: $(cat "$NOTIFY_LOG")"; false; }

    teardown_watcher_harness
}

@test "T-217-08b: ups印 mtime advancing between nudges logs HOOK-ARMED exactly once, no HOOK-UNARMED (3rd nudge tests the one-shot flag itself)" {
    _build_watcher_harness
    # cmd_217 design_2 UPS_MARK_PROVENANCE: check_hook_armed() now looks at
    # ups印 (not busy印) and evaluates it one nudge late (HOOK_ARMED_
    # DEFERRED_EVAL — the hook fires ~1s after send-keys, so a same-call
    # synchronous check would always miss it). Seed an already-old ups印
    # so nudge #1's snapshot (UPS_MTIME_PRE) is a real, distinguishable
    # timestamp, then advance it between nudge #1 and #2 to simulate the
    # hook firing in between — nudge #2's check should then see the
    # advance and log ARMED exactly once.
    # Keep the agent's CURRENT state idle (idle印 newer) so send_wakeup's
    # own busy gate doesn't itself suppress the nudge before
    # check_hook_armed runs.
    #
    # cmd_217 QC是正 F-B (gunshi_report.yaml required_fixes): a 2-nudge
    # test can't distinguish "logged once" from "one-shot flag removed" —
    # nudge #2 is the FIRST occasion ARMED can log at all, so there is no
    # 3rd occasion for a broken HOOK_ARMED_LOGGED flag to double-fire.
    # A 3rd nudge, with ups印 advanced again in between, is required to
    # prove the one-shot flag itself suppresses a second [HOOK-ARMED]
    # line — mirroring how T-217-08 (17 lines above) needed a 4th nudge
    # for the same reason on the UNARMED side. Plain back-to-back `touch`
    # calls would not do: within the same second mtime does not move, so
    # `touch -d` is used to advance it explicitly (confirmed by gunshi).
    touch -d "@$(( $(date +%s) - 100 ))" "$IDLE_FLAG_DIR/shogun_ups_t217agent"
    touch "$IDLE_FLAG_DIR/shogun_idle_t217agent"

    run bash -c "
        source '$WATCHER_HARNESS'
        HOOK_ARMED_CHECK_N=3
        send_wakeup 1
        touch -d \"@\$(( \$(date +%s) + 5 ))\" '$IDLE_FLAG_DIR/shogun_ups_t217agent'
        send_wakeup 2
        touch -d \"@\$(( \$(date +%s) + 10 ))\" '$IDLE_FLAG_DIR/shogun_ups_t217agent'
        send_wakeup 3
    "
    [ "$status" -eq 0 ]

    [ "$(echo "$output" | grep -c 'HOOK-ARMED')" -eq 1 ] \
        || { echo "expected exactly 1 [HOOK-ARMED] log line across 3 nudges (one-shot flag); output: $output"; false; }
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

# ─── F-1 (subtask_217_qc_fixes, gunshi_qc_217_pr100.yaml): M3/M4を捕まえる ───
# 軍師の変異試験で M3（session_start_hook.sh の busy印touch削除）と
# M4（stop_hook_inbox.sh block経路の busy印touch削除）が生存した
# （どちらも捕まえるテストが無かった）。T-217-10b と同じ流儀
# （対象スクリプトの現物をgrepして busy印touch 行の存在を検査する）で塞ぐ。
#
# NOTE: パターンに $AGENT_ID のような "$" を含む文字列を渡す際は必ず
# grep -F（固定文字列）を用いること。素の -n/-q だと、この実行環境の
# grep 実体（ugrep）が BRE 途中の "$" を行末アンカーとして誤解釈し、
# 実在する行にも決してヒットしなくなる
# （gunshi_qc_217_pr100.yaml F-3で実証済みの罠。printf 'a$b\n' | grep -c
# 'a$b' が GNU grep=1 / ugrep=0 で再現する）。

@test "T-217-12 (F-1/M3): session_start_hook.sh touches shogun_busy_<agent> on Session Start" {
    local hook_script="$SCRIPT_DIR/scripts/session_start_hook.sh"
    [ -f "$hook_script" ]
    grep -qF 'touch "${IDLE_FLAG_DIR:-/tmp}/shogun_busy_${AGENT_ID}"' "$hook_script"
}

@test "T-217-13 (F-1/M4): stop_hook_inbox.sh block path touches shogun_busy_<agent> after any idle印touch and before the block decision" {
    local hook_script="$SCRIPT_DIR/scripts/stop_hook_inbox.sh"
    [ -f "$hook_script" ]

    local busy_line
    busy_line=$(grep -nF 'touch "${IDLE_FLAG_DIR:-/tmp}/shogun_busy_${AGENT_ID}"' "$hook_script" | head -1 | cut -d: -f1)
    [ -n "$busy_line" ] || { echo "shogun_busy_ touch line not found in $hook_script"; false; }

    local last_idle_line
    last_idle_line=$(grep -nF 'touch "$FLAG"' "$hook_script" | tail -1 | cut -d: -f1)
    [ -n "$last_idle_line" ] || { echo "idle印 touch line not found in $hook_script"; false; }

    local block_line
    block_line=$(grep -nF "'decision': 'block'" "$hook_script" | head -1 | cut -d: -f1)
    [ -n "$block_line" ] || { echo "block decision line not found in $hook_script"; false; }

    # busy印touch must be positioned AFTER every idle印touch on this
    # invocation (newer mtime wins under §2 design) and BEFORE the block
    # decision is emitted — matching the ordering comment at the touch
    # site (stop_hook_inbox.sh: "immediately before the block decision").
    [ "$busy_line" -gt "$last_idle_line" ] \
        || { echo "busy印touch(L$busy_line) must come AFTER last idle印touch(L$last_idle_line)"; false; }
    [ "$busy_line" -lt "$block_line" ] \
        || { echo "busy印touch(L$busy_line) must come BEFORE block decision(L$block_line)"; false; }
}
