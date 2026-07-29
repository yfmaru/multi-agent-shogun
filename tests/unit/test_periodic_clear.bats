#!/usr/bin/env bats
# test_periodic_clear.bats — periodic /clear extension to baton_watchdog.sh (cmd_172/P7)
#
# Sources the REAL scripts/baton_watchdog.sh with __BATON_WATCHDOG_TESTING__=1
# (only function definitions are loaded — production code, not a reimplementation).
# queue/ is faked under a per-test tmp dir via BATON_WATCHDOG_ROOT, and
# scripts/inbox_write.sh is faked under the SAME fixture root (periodic_clear
# invokes it as "$ROOT/scripts/inbox_write.sh", so pointing BATON_WATCHDOG_ROOT
# at the fixture transparently redirects the call — no PATH tricks needed).
#
# This file is intentionally separate from test_baton_watchdog.bats: it tests
# a distinct, independently-toggled feature (periodic_clear_*) that must be
# provably non-interfering with the existing B-1/B-2/B-3 judgment. Keeping it
# in its own file makes that separation legible; TC-PCLEAR-005 below plus a
# full `bats tests/unit/test_baton_watchdog.bats` regression run are the
# actual proof (see task report).
#
# テスト構成:
#   TC-PCLEAR-001: idle条件が periodic_clear_idle_sec を超えて継続 → karo/軍師
#                  それぞれについて inbox_write.sh(clear_command) が呼ばれる
#   TC-PCLEAR-002: 閾値未満、または未読/assignedタスクが1件でもあれば呼ばれない
#   TC-PCLEAR-003: 一度送信したら同一idle windowで再送されない。
#                  busy→idleを経れば再送される
#   TC-PCLEAR-004: periodic_clear_enabled=false（既定）なら一切呼ばれない
#   TC-PCLEAR-006: tmux は一切呼ばれない

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
WATCHDOG_SCRIPT="$PROJECT_ROOT/scripts/baton_watchdog.sh"

setup() {
    TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/periodic_clear_test.XXXXXX")"
    FIXTURE_ROOT="$TEST_TMPDIR/fixture"
    mkdir -p "$FIXTURE_ROOT/queue/inbox" "$FIXTURE_ROOT/queue/tasks" "$FIXTURE_ROOT/config" "$FIXTURE_ROOT/scripts"

    export MOCK_TMUX_LOG="$TEST_TMPDIR/tmux_calls.log"
    export NOTIFY_LOG="$TEST_TMPDIR/notify.log"
    export INBOX_WRITE_LOG="$TEST_TMPDIR/inbox_write_calls.log"
    > "$MOCK_TMUX_LOG"
    > "$NOTIFY_LOG"
    > "$INBOX_WRITE_LOG"

    # --- 既定フィクスチャ: karo・軍師とも「手隙」（安全なベースライン） ---
    cat > "$FIXTURE_ROOT/queue/inbox/karo.yaml" << 'YAML'
messages:
  - id: msg_1
    read: true
YAML
    cat > "$FIXTURE_ROOT/queue/inbox/gunshi.yaml" << 'YAML'
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

    # 実際にどこにも書き込まれない「失敗しないモック」。
    # $ROOT/scripts/inbox_write.sh として呼ばれる — periodic_clear_check_once
    # は $ROOT からの相対パスでこれを呼ぶため、BATON_WATCHDOG_ROOT を
    # フィクスチャに向けるだけで実スクリプトへの到達を防げる。
    cat > "$FIXTURE_ROOT/scripts/inbox_write.sh" << 'SH'
#!/usr/bin/env bash
echo "inbox_write $*" >> "$INBOX_WRITE_LOG"
SH
    chmod +x "$FIXTURE_ROOT/scripts/inbox_write.sh"

    write_settings false 5 "karo gunshi"

    export BATON_WATCHDOG_ROOT="$FIXTURE_ROOT"
    export STALL_POLICY_SETTINGS="$FIXTURE_ROOT/config/settings.yaml"

    export TEST_HARNESS="$TEST_TMPDIR/test_harness.sh"
    cat > "$TEST_HARNESS" << HARNESS
#!/bin/bash
export BATON_WATCHDOG_ROOT="$FIXTURE_ROOT"
export STALL_POLICY_SETTINGS="$FIXTURE_ROOT/config/settings.yaml"
export INBOX_WRITE_LOG="$INBOX_WRITE_LOG"

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

# settings.yaml を書き直すヘルパー。
# $1=periodic_clear_enabled(true/false) $2=periodic_clear_idle_sec $3=agents(スペース区切り)
write_settings() {
    local agents_yaml=""
    local a
    for a in $3; do
        agents_yaml="$agents_yaml
  - $a"
    done
    cat > "$FIXTURE_ROOT/config/settings.yaml" << YAML
baton_watchdog:
  enabled: true
  baton_lost_after_sec: 900
  poll_interval_sec: 60
  periodic_clear_enabled: $1
  periodic_clear_idle_sec: $2
  periodic_clear_agents:$agents_yaml
YAML
}

# --- TC-PCLEAR-001: 閾値継続 → karo/軍師それぞれについてinbox_write呼び出し ---

@test "TC-PCLEAR-001: clear_command sent for karo when idle exceeds threshold" {
    write_settings true 5 "karo gunshi"

    run bash -c "
        source '$TEST_HARNESS'
        PERIODIC_CLEAR_IDLE_SINCE[karo]=\$(( \$(date +%s) - 10 ))  # threshold=5s, already 10s elapsed
        periodic_clear_check_once
    "
    [ "$status" -eq 0 ]
    grep -q "inbox_write karo .* clear_command baton_watchdog" "$INBOX_WRITE_LOG"
}

@test "TC-PCLEAR-001b: clear_command sent for gunshi when idle exceeds threshold" {
    write_settings true 5 "karo gunshi"

    run bash -c "
        source '$TEST_HARNESS'
        PERIODIC_CLEAR_IDLE_SINCE[gunshi]=\$(( \$(date +%s) - 10 ))
        periodic_clear_check_once
    "
    [ "$status" -eq 0 ]
    grep -q "inbox_write gunshi .* clear_command baton_watchdog" "$INBOX_WRITE_LOG"
}

# --- TC-PCLEAR-002: 閾値未満、または未読/assignedタスクが1件でもあれば呼ばれない ---

@test "TC-PCLEAR-002a: not sent when idle duration is under threshold" {
    write_settings true 100 "karo gunshi"

    run bash -c "
        source '$TEST_HARNESS'
        PERIODIC_CLEAR_IDLE_SINCE[karo]=\$(( \$(date +%s) - 2 ))  # threshold=100s, only 2s elapsed
        periodic_clear_check_once
    "
    [ "$status" -eq 0 ]
    [ ! -s "$INBOX_WRITE_LOG" ]
}

@test "TC-PCLEAR-002b: not sent when karo has an unread inbox message" {
    write_settings true 5 "karo gunshi"
    cat > "$FIXTURE_ROOT/queue/inbox/karo.yaml" << 'YAML'
messages:
  - id: msg_unread
    read: false
YAML

    run bash -c "
        source '$TEST_HARNESS'
        PERIODIC_CLEAR_IDLE_SINCE[karo]=\$(( \$(date +%s) - 100 ))
        periodic_clear_check_once
    "
    [ "$status" -eq 0 ]
    [ ! -s "$INBOX_WRITE_LOG" ]
}

@test "TC-PCLEAR-002c: not sent for karo when an ashigaru task is assigned" {
    write_settings true 5 "karo gunshi"
    cat > "$FIXTURE_ROOT/queue/tasks/ashigaru2.yaml" << 'YAML'
task:
  task_id: subtask_active
  status: assigned
YAML

    run bash -c "
        source '$TEST_HARNESS'
        PERIODIC_CLEAR_IDLE_SINCE[karo]=\$(( \$(date +%s) - 100 ))
        periodic_clear_check_once
    "
    [ "$status" -eq 0 ]
    [ ! -s "$INBOX_WRITE_LOG" ]
}

@test "TC-PCLEAR-002d: not sent for karo when a shogun_to_karo cmd is in_progress" {
    write_settings true 5 "karo gunshi"
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: in_progress
YAML

    run bash -c "
        source '$TEST_HARNESS'
        PERIODIC_CLEAR_IDLE_SINCE[karo]=\$(( \$(date +%s) - 100 ))
        periodic_clear_check_once
    "
    [ "$status" -eq 0 ]
    [ ! -s "$INBOX_WRITE_LOG" ]
}

@test "TC-PCLEAR-002e: not sent for gunshi when gunshi task is in_progress" {
    write_settings true 5 "karo gunshi"
    cat > "$FIXTURE_ROOT/queue/tasks/gunshi.yaml" << 'YAML'
task:
  task_id: subtask_active
  status: in_progress
YAML

    run bash -c "
        source '$TEST_HARNESS'
        PERIODIC_CLEAR_IDLE_SINCE[gunshi]=\$(( \$(date +%s) - 100 ))
        periodic_clear_check_once
    "
    [ "$status" -eq 0 ]
    [ ! -s "$INBOX_WRITE_LOG" ]
}

# --- TC-PCLEAR-003: 一度送信したら同一idle windowで再送されない。busy→idleで再送 ---

@test "TC-PCLEAR-003: no duplicate send within same idle window; resends after busy->idle" {
    write_settings true 5 "karo gunshi"

    run bash -c "
        source '$TEST_HARNESS'
        PERIODIC_CLEAR_IDLE_SINCE[karo]=\$(( \$(date +%s) - 10 ))

        # 1回目: 送信されるはず
        periodic_clear_check_once
        first_count=\$(grep -c 'inbox_write karo' \"$INBOX_WRITE_LOG\" || true)

        # 2回目: 同一idle windowのまま呼んでも再送されないはず
        periodic_clear_check_once
        second_count=\$(grep -c 'inbox_write karo' \"$INBOX_WRITE_LOG\" || true)

        echo \"first=\$first_count second=\$second_count\"
        [ \"\$first_count\" -eq 1 ]
        [ \"\$second_count\" -eq 1 ]

        # busyにする（未読発生）→ 状態リセット
        cat > '$FIXTURE_ROOT/queue/inbox/karo.yaml' << 'YAML'
messages:
  - id: msg_unread
    read: false
YAML
        periodic_clear_check_once

        # 再びidleに戻し、閾値超過を再度作る → 再送されるはず
        cat > '$FIXTURE_ROOT/queue/inbox/karo.yaml' << 'YAML'
messages:
  - id: msg_1
    read: true
YAML
        PERIODIC_CLEAR_IDLE_SINCE[karo]=\$(( \$(date +%s) - 10 ))
        periodic_clear_check_once
        third_count=\$(grep -c 'inbox_write karo' \"$INBOX_WRITE_LOG\" || true)
        echo \"third=\$third_count\"
        [ \"\$third_count\" -eq 2 ]
    "
    [ "$status" -eq 0 ]
}

# --- TC-PCLEAR-004: periodic_clear_enabled=false（既定）なら一切呼ばれない ---

@test "TC-PCLEAR-004: disabled (default) policy causes periodic_clear_check_once to no-op" {
    # setup() の既定フィクスチャは periodic_clear_enabled=false のまま

    run bash -c "
        source '$TEST_HARNESS'
        PERIODIC_CLEAR_IDLE_SINCE[karo]=\$(( \$(date +%s) - 1000 ))
        PERIODIC_CLEAR_IDLE_SINCE[gunshi]=\$(( \$(date +%s) - 1000 ))
        periodic_clear_check_once
    "
    [ "$status" -eq 0 ]
    [ ! -s "$INBOX_WRITE_LOG" ]
    [ ! -s "$MOCK_TMUX_LOG" ]
}

# --- TC-PCLEAR-006: 【重要】検知しても tmux を一切呼ばない ---

@test "TC-PCLEAR-006: tmux is never called even when a clear_command is sent" {
    write_settings true 5 "karo gunshi"

    run bash -c "
        source '$TEST_HARNESS'
        PERIODIC_CLEAR_IDLE_SINCE[karo]=\$(( \$(date +%s) - 10 ))
        periodic_clear_check_once
    "
    [ "$status" -eq 0 ]
    # 送信は確かに起きている（前提の健全性を確認）
    [ -s "$INBOX_WRITE_LOG" ]
    # にもかかわらず tmux は一度も呼ばれていない
    [ ! -s "$MOCK_TMUX_LOG" ]
}
