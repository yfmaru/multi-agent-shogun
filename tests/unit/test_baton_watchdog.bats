#!/usr/bin/env bats
# test_baton_watchdog.bats — baton_watchdog.sh unit tests (cmd_171/T3)
#
# Sources the REAL scripts/baton_watchdog.sh with __BATON_WATCHDOG_TESTING__=1
# (only function definitions are loaded — production code, not a reimplementation).
# queue/ is faked under a per-test tmp dir via BATON_WATCHDOG_ROOT.
# settings.yaml is faked via STALL_POLICY_SETTINGS (lib/stall_policy.sh honors
# the env override, so no real config/settings.yaml is required or touched).
#
# テスト構成:
#   TC-BATON-001: 未読0・active0・未完cmdあり が閾値継続 → 検知（通知1件）
#   TC-BATON-002: 未読が1件でもあれば検知しない
#   TC-BATON-003: assigned のタスクが1件でもあれば検知しない
#   TC-BATON-004: 未完了 cmd が無ければ検知しない
#   TC-BATON-005: 閾値未満の継続では検知しない
#   TC-BATON-006: 検知しても tmux を一切呼ばない
#   TC-BATON-007: baton_watchdog.enabled=false なら即座に何もしない
#   TC-BATON-008: shogun_to_karo.yaml が壊れている/無い場合も落ちない（open_cmds=0扱い）

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
WATCHDOG_SCRIPT="$PROJECT_ROOT/scripts/baton_watchdog.sh"

setup() {
    TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/baton_watchdog_test.XXXXXX")"
    FIXTURE_ROOT="$TEST_TMPDIR/fixture"
    mkdir -p "$FIXTURE_ROOT/queue/inbox" "$FIXTURE_ROOT/queue/tasks" "$FIXTURE_ROOT/config"

    export MOCK_TMUX_LOG="$TEST_TMPDIR/tmux_calls.log"
    export NOTIFY_LOG="$TEST_TMPDIR/notify.log"
    > "$MOCK_TMUX_LOG"
    > "$NOTIFY_LOG"

    # --- 既定フィクスチャ: 未読0・稼働中タスク0・未完了cmd0（安全なベースライン） ---
    cat > "$FIXTURE_ROOT/queue/inbox/karo.yaml" << 'YAML'
messages:
  - id: msg_1
    read: true
YAML
    cat > "$FIXTURE_ROOT/queue/tasks/ashigaru1.yaml" << 'YAML'
task:
  task_id: subtask_done
  status: done
YAML
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: done
YAML
    write_settings true 5 60

    export BATON_WATCHDOG_ROOT="$FIXTURE_ROOT"
    export STALL_POLICY_SETTINGS="$FIXTURE_ROOT/config/settings.yaml"

    export TEST_HARNESS="$TEST_TMPDIR/test_harness.sh"
    cat > "$TEST_HARNESS" << HARNESS
#!/bin/bash
export BATON_WATCHDOG_ROOT="$FIXTURE_ROOT"
export STALL_POLICY_SETTINGS="$FIXTURE_ROOT/config/settings.yaml"

# tmux は絶対に呼ばれてはならない。呼ばれたら記録するだけの「失敗モック」。
tmux() {
    echo "tmux \$*" >> "$MOCK_TMUX_LOG"
    return 1
}
export -f tmux

export __BATON_WATCHDOG_TESTING__=1
source "$WATCHDOG_SCRIPT"

# 実ネットワーク（ntfy）を叩かぬよう、branch_policy_notify をソース後に上書きする。
branch_policy_notify() {
    echo "NOTIFY: \$1" >> "$NOTIFY_LOG"
    return 0
}
HARNESS
    chmod +x "$TEST_HARNESS"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# settings.yaml を書き直すヘルパー。 $1=enabled(true/false) $2=baton_lost_after_sec $3=poll_interval_sec
write_settings() {
    cat > "$FIXTURE_ROOT/config/settings.yaml" << YAML
baton_watchdog:
  enabled: $1
  baton_lost_after_sec: $2
  poll_interval_sec: $3
YAML
}

# --- TC-BATON-001: 未読0・active0・未完cmdあり が閾値継続 → 検知 ---

@test "TC-BATON-001: baton lost detected when unread=0, active=0, open_cmds>0 past threshold" {
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: in_progress
YAML

    run bash -c "
        source '$TEST_HARNESS'
        BATON_LOST_SINCE=\$(( \$(date +%s) - 10 ))  # threshold=5s, already 10s elapsed
        check_once
    "
    [ "$status" -eq 0 ]
    grep -q "NOTIFY: baton_lost" "$NOTIFY_LOG"
}

# --- TC-BATON-002: 未読が1件でもあれば検知しない ---

@test "TC-BATON-002: no detection when any unread message exists" {
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: in_progress
YAML
    cat > "$FIXTURE_ROOT/queue/inbox/ashigaru1.yaml" << 'YAML'
messages:
  - id: msg_unread
    read: false
YAML

    run bash -c "
        source '$TEST_HARNESS'
        BATON_LOST_SINCE=\$(( \$(date +%s) - 100 ))
        check_once
    "
    [ "$status" -eq 0 ]
    [ ! -s "$NOTIFY_LOG" ]
}

# --- TC-BATON-003: assigned のタスクが1件でもあれば検知しない ---

@test "TC-BATON-003: no detection when an assigned/in_progress task exists" {
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: in_progress
YAML
    cat > "$FIXTURE_ROOT/queue/tasks/ashigaru2.yaml" << 'YAML'
task:
  task_id: subtask_active
  status: assigned
YAML

    run bash -c "
        source '$TEST_HARNESS'
        BATON_LOST_SINCE=\$(( \$(date +%s) - 100 ))
        check_once
    "
    [ "$status" -eq 0 ]
    [ ! -s "$NOTIFY_LOG" ]
}

# --- TC-BATON-004: 未完了 cmd が無ければ検知しない（全部done＝正常な静止） ---

@test "TC-BATON-004: no detection when no open cmd exists (all done)" {
    # デフォルトフィクスチャは既に commands: status: done のみ

    run bash -c "
        source '$TEST_HARNESS'
        BATON_LOST_SINCE=\$(( \$(date +%s) - 100 ))
        check_once
    "
    [ "$status" -eq 0 ]
    [ ! -s "$NOTIFY_LOG" ]
}

# --- TC-BATON-005: 閾値未満の継続では検知しない ---

@test "TC-BATON-005: no detection when stall duration is under threshold" {
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: in_progress
YAML

    run bash -c "
        source '$TEST_HARNESS'
        BATON_LOST_SINCE=\$(( \$(date +%s) - 2 ))  # threshold=5s, only 2s elapsed
        check_once
    "
    [ "$status" -eq 0 ]
    [ ! -s "$NOTIFY_LOG" ]
}

# --- TC-BATON-006: 【重要】検知しても tmux を一切呼ばない ---

@test "TC-BATON-006: tmux is never called even when baton loss is detected" {
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: in_progress
YAML

    run bash -c "
        source '$TEST_HARNESS'
        BATON_LOST_SINCE=\$(( \$(date +%s) - 10 ))
        check_once
    "
    [ "$status" -eq 0 ]
    # 検知は確かに起きている（前提の健全性を確認）
    grep -q "NOTIFY: baton_lost" "$NOTIFY_LOG"
    # にもかかわらず tmux は一度も呼ばれていない
    [ ! -s "$MOCK_TMUX_LOG" ]
}

# --- TC-BATON-007: baton_watchdog.enabled=false なら即座に何もしない ---

@test "TC-BATON-007: disabled policy causes check_once to no-op immediately" {
    write_settings false 5 60
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: in_progress
YAML

    run bash -c "
        source '$TEST_HARNESS'
        BATON_LOST_SINCE=\$(( \$(date +%s) - 1000 ))
        check_once
    "
    [ "$status" -eq 0 ]
    [ ! -s "$NOTIFY_LOG" ]
    [ ! -s "$MOCK_TMUX_LOG" ]

    # スクリプトをプロセスとして直接起動しても即 exit 0 する
    run env BATON_WATCHDOG_ROOT="$FIXTURE_ROOT" STALL_POLICY_SETTINGS="$FIXTURE_ROOT/config/settings.yaml" \
        bash "$WATCHDOG_SCRIPT" --once
    [ "$status" -eq 0 ]
}

# --- TC-BATON-008: shogun_to_karo.yaml が壊れている/無い場合も落ちない ---

@test "TC-BATON-008: missing or corrupt shogun_to_karo.yaml is treated as open_cmds=0" {
    rm -f "$FIXTURE_ROOT/queue/shogun_to_karo.yaml"

    run bash -c "
        source '$TEST_HARNESS'
        baton_watchdog_count_open_cmds
    "
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]

    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands: [this is: not: valid: yaml: [[[
YAML

    run bash -c "
        source '$TEST_HARNESS'
        baton_watchdog_count_open_cmds
    "
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]

    # check_once 自体も落ちず、未完了cmd0扱いなので検知しない
    run bash -c "
        source '$TEST_HARNESS'
        BATON_LOST_SINCE=\$(( \$(date +%s) - 100 ))
        check_once
    "
    [ "$status" -eq 0 ]
    [ ! -s "$NOTIFY_LOG" ]
}
