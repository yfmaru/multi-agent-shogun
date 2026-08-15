#!/usr/bin/env bats
# test_hook_armed_and_staleness.bats — cmd_217 是正3点の残り検査
#   (UPS_MARK_PROVENANCE単独筆者性 / D-1の special_deferred分岐 /
#    D-1の一度きりntfy・capture失敗時の縮退 / C-1の到達不能性)
#
# 設計原本: queue/reports/gunshi_report.yaml
#   (design_2_hook_armed_check / design_4_stale_busy_conflict / design_3_escalation_path)
#
# test_two_marker_busy_idle.bats がすでに扱う範囲（T-217-07/D1/08/08b等）
# とは重ならぬよう、このファイルは以下のみを扱う:
#
#   AC-I4: /tmp/shogun_ups_<agent> を touch する者が
#          user_prompt_submit_hook.sh ただ一つであることのリポジトリ全体grep
#   T-B2/AC-I7 (cmd_217 QC是正 F-A): /clear由来のsession_start_hook busy印
#          touchを何度繰り返してもups印が動かぬ限りHOOK-ARMEDを出さぬこと
#          （将軍が名指しで「これを外すな」と仰せの検査）
#   T-B5:  user_prompt_submit_hook.sh が busy印 と ups印 の両方を touch する
#   T-B6:  hook 成功時にログ行が1行増える
#   T-C1/T-C2 (cmd_217 QC是正 F-C): post_tool_use_hook.sh (D-2) が busy印を
#          touchすること・TMUX_PANE不在でもexit 0すること
#   T-D3:  force-idle の ntfy が複数サイクルにわたっても一度きりであること
#   T-D4:  pane capture が空を返す場合、force-idle を撃たない側へ倒れる
#   D-1(special_deferred枝): 延期中special型でも同じpane-hash-frozen AND
#          が効くこと（第二のforce-idle箇所、process_unreadのelif枝）
#   T-E1:  send_wakeup_with_escape() で cli=claude の早期returnが
#          agent_has_self_watch()等より前に位置し、それらへ構造上
#          到達しないこと（C-1: 記述是正の裏付け）

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
WATCHER_SCRIPT="$SCRIPT_DIR/scripts/inbox_watcher.sh"
UPS_HOOK="$SCRIPT_DIR/scripts/user_prompt_submit_hook.sh"
POSTTOOL_HOOK="$SCRIPT_DIR/scripts/post_tool_use_hook.sh"

setup_file() {
    export PROJECT_ROOT="$SCRIPT_DIR"
    export VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"
    [ -f "$WATCHER_SCRIPT" ] || return 1
    [ -f "$UPS_HOOK" ] || return 1
    "$VENV_PYTHON" -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export IDLE_FLAG_DIR="$(mktemp -d "$BATS_TMPDIR/hook_staleness_test.XXXXXX")"
}

teardown() {
    rm -rf "$IDLE_FLAG_DIR"
}

# ═══════════════════════════════════════════════════════════════
# AC-I4: sole-writer proof for /tmp/shogun_ups_<agent>
# ═══════════════════════════════════════════════════════════════

@test "AC-I4: only user_prompt_submit_hook.sh TOUCHES shogun_ups_ anywhere in the repo (others may only read it)" {
    # AC-I4 is about who WRITES the marker, not who references it —
    # inbox_watcher.sh legitimately READS it (stat -c %Y) in
    # check_hook_armed(). Grep specifically for `touch ... shogun_ups_`
    # lines, not any occurrence of the string.
    local hits
    hits=$(grep -rlF 'touch "${IDLE_FLAG_DIR:-/tmp}/shogun_ups_' "$SCRIPT_DIR/scripts" "$SCRIPT_DIR/lib" 2>/dev/null)
    local count total
    count=$(echo "$hits" | grep -cF 'user_prompt_submit_hook.sh' || true)
    total=$(echo "$hits" | grep -c . || true)
    [ "$total" -eq 1 ] && [ "$count" -eq 1 ] \
        || { echo "expected exactly one file (user_prompt_submit_hook.sh) to touch shogun_ups_; got: $hits"; false; }
    # post_tool_use_hook.sh (D-2) must NOT be among the writers — it is
    # scoped to busy印 only (comment in the script says so explicitly).
    ! grep -qF 'shogun_ups_' "$POSTTOOL_HOOK" \
        || { echo "regression: post_tool_use_hook.sh touches ups印, breaking AC-I4's single-writer guarantee"; false; }
}

# ═══════════════════════════════════════════════════════════════
# T-B5 / T-B6: hook touches both markers, success path logs
# ═══════════════════════════════════════════════════════════════

@test "T-B5: user_prompt_submit_hook.sh touches both busy印 and ups印 on a resolved agent" {
    run bash -c "
        tmux() { echo 't217b5agent'; return 0; }
        export -f tmux
        export TMUX_PANE='test:0.0'
        IDLE_FLAG_DIR='$IDLE_FLAG_DIR' bash '$UPS_HOOK' < /dev/null
    "
    [ "$status" -eq 0 ]
    [ -f "$IDLE_FLAG_DIR/shogun_busy_t217b5agent" ] \
        || { echo "expected busy印 to be touched"; false; }
    [ -f "$IDLE_FLAG_DIR/shogun_ups_t217b5agent" ] \
        || { echo "expected ups印 to be touched"; false; }
}

@test "T-B6: user_prompt_submit_hook.sh success path adds exactly one new log line" {
    local log="$SCRIPT_DIR/logs/hook_user_prompt_submit.log"
    mkdir -p "$(dirname "$log")"
    local before after
    before=$(wc -l < "$log" 2>/dev/null || echo 0)

    run bash -c "
        tmux() { echo 't217b6agent'; return 0; }
        export -f tmux
        export TMUX_PANE='test:0.0'
        IDLE_FLAG_DIR='$IDLE_FLAG_DIR' bash '$UPS_HOOK' < /dev/null
    "
    [ "$status" -eq 0 ]

    after=$(wc -l < "$log" 2>/dev/null || echo 0)
    [ "$after" -eq "$((before + 1))" ] \
        || { echo "expected exactly one new log line on the success path (before=$before after=$after)"; false; }
    tail -1 "$log" | grep -qF "agent=t217b6agent busy印/ups印 touch OK" \
        || { echo "expected the new line to record the success-path message"; false; }
}

# ═══════════════════════════════════════════════════════════════
# Shared watcher harness (mirrors test_two_marker_busy_idle.bats's
# _build_watcher_harness, duplicated per this repo's existing per-file
# convention — no cross-file bats helper exists yet)
# ═══════════════════════════════════════════════════════════════

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

# ═══════════════════════════════════════════════════════════════
# T-B2/AC-I7 (cmd_217 QC是正 F-A, gunshi_report.yaml required_fixes):
# session_start_hook busy印 touchが何度繰り返されようと、ups印が動かぬ
# 限りHOOK-ARMEDを出してはならぬ。将軍が名指しで「これを外すな」と
# 仰せの検査。M4（check_hook_armedがups印でなくbusy印を見る変異）を
# 将軍のご懸念そのものの形で赤にする。
# ═══════════════════════════════════════════════════════════════

@test "T-B2/AC-I7: repeated session_start_hook busy印 touches never yield HOOK-ARMED while ups印 stays put" {
    _build_watcher_harness
    rm -f "$IDLE_FLAG_DIR/shogun_ups_t217agent"

    # session_start_hook.sh を実際に走らせて busy印 を進める。
    # 走らせるたび idle印 を後追いで touch し、send_wakeup 自身の
    # busy ゲートで nudge が抑止されるのを防ぐ（抑止されると
    # check_hook_armed が一度も走らず、変異を入れても ARMED が
    # 出ないため、テストが無意味に緑になる）。
    _fire_session_start() {
        TMUX_PANE='test:0.0' IDLE_FLAG_DIR="$IDLE_FLAG_DIR" \
            bash -c "
                tmux() { echo 't217agent'; return 0; }
                export -f tmux
                bash '$PROJECT_ROOT/scripts/session_start_hook.sh' < /dev/null
            " >/dev/null 2>&1 || true
        sleep 1
        touch "$IDLE_FLAG_DIR/shogun_idle_t217agent"
    }

    _fire_session_start
    run bash -c "
        source '$WATCHER_HARNESS'
        HOOK_ARMED_CHECK_N=99
        send_wakeup 1
    "
    [ "$status" -eq 0 ]

    _fire_session_start
    run bash -c "
        source '$WATCHER_HARNESS'
        HOOK_ARMED_CHECK_N=99
        UPS_MTIME_PRE=0
        HOOK_CHECK_PENDING=1
        send_wakeup 2
    "
    [ "$status" -eq 0 ]
    ! echo "$output" | grep -q 'HOOK-ARMED' \
        || { echo "AC-I7 violation: busy印 movement alone produced [HOOK-ARMED]; output: $output"; false; }

    [ ! -f "$IDLE_FLAG_DIR/shogun_ups_t217agent" ] \
        || { echo "ups印 must not exist — session_start_hook must never touch it"; false; }

    teardown_watcher_harness
}

# ═══════════════════════════════════════════════════════════════
# T-C1/T-C2 (cmd_217 QC是正 F-C, gunshi_report.yaml recommended_fixes):
# post_tool_use_hook.sh (D-2) はmatcher無しで全ツール呼び出しごとに
# 走るゆえ、契約(busy印touch/exit 0)の検査が要る。ups印を触らぬことは
# AC-I4が既に担保している。
# ═══════════════════════════════════════════════════════════════

@test "T-C1: post_tool_use_hook.sh touches busy印 when TMUX_PANE resolves an agent" {
    run bash -c "
        tmux() { echo 't217c1agent'; return 0; }
        export -f tmux
        export TMUX_PANE='test:0.0'
        IDLE_FLAG_DIR='$IDLE_FLAG_DIR' bash '$POSTTOOL_HOOK' < /dev/null
    "
    [ "$status" -eq 0 ]
    [ -f "$IDLE_FLAG_DIR/shogun_busy_t217c1agent" ] \
        || { echo "expected busy印 to be touched"; false; }
}

@test "T-C2: post_tool_use_hook.sh exits 0 with no TMUX_PANE (does not break tool execution)" {
    run bash -c "
        unset TMUX_PANE
        IDLE_FLAG_DIR='$IDLE_FLAG_DIR' bash '$POSTTOOL_HOOK' < /dev/null
    "
    [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════
# T-D3: force-idle ntfy is one-shot across MULTIPLE qualifying cycles
# ═══════════════════════════════════════════════════════════════

@test "T-D3: stale-busy force-idle ntfy fires once even across repeated qualifying cycles" {
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

    local frozen_content='frozen busy pane content for T-D3'
    run bash -c "
        MOCK_CAPTURE_PANE='$frozen_content'
        source '$WATCHER_HARNESS'
        now=\$(date +%s)
        FIRST_UNREAD_SEEN=\$((now - 301))
        STALE_BUSY_HASH=\$(printf '%s' '$frozen_content' | cksum | awk '{print \$1}')
        STALE_BUSY_HASH_SINCE=\$((now - 500))
        # Two consecutive cycles that both qualify for force-idle (age AND
        # frozen pane) — the one-shot flag (STALE_BUSY_NTFY_SENT) must
        # suppress the second ntfy.
        process_unread event
        FIRST_UNREAD_SEEN=\$((now - 301))
        process_unread event
    "
    [ "$status" -eq 0 ]

    [ "$(grep -c 'NOTIFY:' "$NOTIFY_LOG")" -eq 1 ] \
        || { echo "expected exactly 1 branch_policy_notify call across 2 qualifying cycles; log: $(cat "$NOTIFY_LOG")"; false; }

    teardown_watcher_harness
}

# ═══════════════════════════════════════════════════════════════
# T-D4: capture-pane returns empty → indeterminate, no force-idle
# ═══════════════════════════════════════════════════════════════

@test "T-D4: stale-busy safety net does not force-idle when pane capture is empty (indeterminate)" {
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

    # MOCK_CAPTURE_PANE left unset/empty — capture-pane returns "" (rc=0,
    # empty output), the indeterminate case pane_hash_frozen_sec() must
    # treat as "not frozen" rather than "frozen".
    run bash -c "
        source '$WATCHER_HARNESS'
        now=\$(date +%s)
        FIRST_UNREAD_SEEN=\$((now - 301))
        process_unread event
    "
    [ "$status" -eq 0 ]

    [ ! -f "$IDLE_FLAG_DIR/shogun_idle_t217agent" ] \
        || { echo "M9 regression: force-idle fired despite indeterminate (empty) pane capture"; false; }
    [ "$(grep -c 'NOTIFY:' "$NOTIFY_LOG")" -eq 0 ] \
        || { echo "expected no ntfy when force-idle did not fire"; false; }

    teardown_watcher_harness
}

# ═══════════════════════════════════════════════════════════════
# D-1 special_deferred branch: same pane-hash-frozen AND applies to the
# second force-idle site (a deferred clear_command while busy)
# ═══════════════════════════════════════════════════════════════

@test "D-1-special: special_deferred branch does NOT force-idle while the pane is still moving" {
    _build_watcher_harness
    touch "$IDLE_FLAG_DIR/shogun_busy_t217agent"

    cat > "$TEST_HOOK_TMP/queue/inbox/t217agent.yaml" << 'YAML'
messages:
- content: /clear
  from: karo
  id: msg_001
  read: false
  timestamp: '2026-01-01T00:00:00'
  type: clear_command
YAML

    run bash -c "
        MOCK_CAPTURE_PANE='some moving pane content'
        source '$WATCHER_HARNESS'
        now=\$(date +%s)
        FIRST_UNREAD_SEEN=\$((now - 301))
        process_unread event
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "clear_command) deferred to next cycle" \
        || { echo "expected the clear_command to be deferred (busy); output: $output"; false; }

    [ ! -f "$IDLE_FLAG_DIR/shogun_idle_t217agent" ] \
        || { echo "N-3-shaped regression: special_deferred branch force-idled on age alone while pane was moving"; false; }

    teardown_watcher_harness
}

@test "D-1-special: special_deferred branch DOES force-idle once busy-age AND pane-frozen both hold" {
    _build_watcher_harness
    touch "$IDLE_FLAG_DIR/shogun_busy_t217agent"

    cat > "$TEST_HOOK_TMP/queue/inbox/t217agent.yaml" << 'YAML'
messages:
- content: /clear
  from: karo
  id: msg_001
  read: false
  timestamp: '2026-01-01T00:00:00'
  type: clear_command
YAML

    local frozen_content='frozen busy pane content for D-1-special'
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

    [ -f "$IDLE_FLAG_DIR/shogun_idle_t217agent" ] \
        || { echo "expected force-idle once both busy-age and pane-frozen conditions hold"; false; }
    [ "$(grep -c 'NOTIFY:' "$NOTIFY_LOG")" -eq 1 ] \
        || { echo "expected exactly 1 branch_policy_notify call; log: $(cat "$NOTIFY_LOG")"; false; }

    teardown_watcher_harness
}

# ═══════════════════════════════════════════════════════════════
# T-E1 (structural, C-1): claude's early-return in
# send_wakeup_with_escape() sits before agent_has_self_watch() /
# agent_is_busy() / pane_has_open_modal() — those are structurally
# unreachable for cli=claude, not merely mis-ordered.
# ═══════════════════════════════════════════════════════════════

@test "T-E1: send_wakeup_with_escape()'s claude early-return precedes agent_has_self_watch/agent_is_busy/pane_has_open_modal" {
    local start_line end_line
    start_line=$(grep -n '^send_wakeup_with_escape()' "$WATCHER_SCRIPT" | head -1 | cut -d: -f1)
    [ -n "$start_line" ] || { echo "send_wakeup_with_escape() not found"; false; }

    # Next top-level function definition after start_line marks the end
    # of this function's body.
    end_line=$(tail -n "+$((start_line + 1))" "$WATCHER_SCRIPT" | grep -n '^[a-zA-Z_][a-zA-Z0-9_]*() *{' | head -1 | cut -d: -f1)
    [ -n "$end_line" ] || { echo "could not find the end of send_wakeup_with_escape()"; false; }
    end_line=$((start_line + end_line))

    local claude_line selfwatch_line busy_line
    claude_line=$(sed -n "${start_line},${end_line}p" "$WATCHER_SCRIPT" | grep -n 'effective_cli" == "claude" \]\]; then' | head -1 | cut -d: -f1)
    selfwatch_line=$(sed -n "${start_line},${end_line}p" "$WATCHER_SCRIPT" | grep -n 'if agent_has_self_watch; then' | head -1 | cut -d: -f1)
    busy_line=$(sed -n "${start_line},${end_line}p" "$WATCHER_SCRIPT" | grep -n 'if agent_is_busy; then' | head -1 | cut -d: -f1)

    [ -n "$claude_line" ] || { echo "claude branch not found inside send_wakeup_with_escape()"; false; }
    [ -n "$selfwatch_line" ] || { echo "agent_has_self_watch call not found inside send_wakeup_with_escape()"; false; }
    [ -n "$busy_line" ] || { echo "agent_is_busy call not found inside send_wakeup_with_escape()"; false; }

    [ "$claude_line" -lt "$selfwatch_line" ] \
        || { echo "claude branch (L$claude_line) must precede agent_has_self_watch (L$selfwatch_line)"; false; }
    [ "$claude_line" -lt "$busy_line" ] \
        || { echo "claude branch (L$claude_line) must precede agent_is_busy (L$busy_line)"; false; }

    # And the claude branch itself must fall back to send_wakeup + return
    # (i.e. it is a genuine early-return, not merely a comment).
    sed -n "${start_line},${end_line}p" "$WATCHER_SCRIPT" | grep -qF 'send_wakeup "$unread_count"' \
        || { echo "expected the claude branch to fall back to send_wakeup()"; false; }
}
