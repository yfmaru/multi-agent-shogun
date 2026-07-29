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
#
# D-1（cmd_171/FU-1。既存B-1〜B-3とは独立したOR条件。配送機構死亡検知）:
# 条件はAND: (i) stale unread がある かつ (ii) 当該agentのinbox_watcher.shが
# 死んでいる。pgrep はデフォルトで「該当プロセス無し（死亡）」をモックする
# （TEST_HARNESS内）。TC-D1-001〜006 は (ii) が満たされる前提での検知テスト。
#   TC-D1-001: 未読1件・timestampが600秒超過・watcher死亡 → 通知される
#   TC-D1-002: 未読1件だがtimestampが600秒以内 → 通知されない
#   TC-D1-003: 未読0件 → 通知されない
#   TC-D1-005: D-1もtmuxに一切触れない
#   TC-D1-006: 同一の継続停止に対して二重通知しない
#   TC-D1-007: 未読1件・timestampが600秒超過だがwatcherが生きている → 通知されない
#              （軍師QC §SC-5：busyでの正常な滞留を誤検知しないためのAND条件）
#   TC-D1-008: 【回帰・QC-70】実際の scripts/inbox_write.sh が書く
#              naive・ローカル時刻のtimestampが正しく解釈されること
#   （TC-D1-004＝既存TC-BATON-001〜008の回帰は本ファイル全体の実行で担保）
#
# QC-70（PR #16 差し戻し）: naive timestamp を「UTC」と誤読していたため
# D-1が本番で約9時間発火しない欠陥があった。テストフィクスチャが
# `date -u` でUTCのnaive文字列を書いていたため本番との乖離が緑のまま
# 見逃されていた。以降フィクスチャは `-u` を使わず、本番と同一の
# ローカル時刻naive書式で timestamp を生成する。

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
WATCHDOG_SCRIPT="$PROJECT_ROOT/scripts/baton_watchdog.sh"

setup() {
    TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/baton_watchdog_test.XXXXXX")"
    FIXTURE_ROOT="$TEST_TMPDIR/fixture"
    mkdir -p "$FIXTURE_ROOT/queue/inbox" "$FIXTURE_ROOT/queue/tasks" "$FIXTURE_ROOT/config"

    export MOCK_TMUX_LOG="$TEST_TMPDIR/tmux_calls.log"
    export NOTIFY_LOG="$TEST_TMPDIR/notify.log"
    export PGREP_LOG="$TEST_TMPDIR/pgrep_calls.log"
    > "$MOCK_TMUX_LOG"
    > "$NOTIFY_LOG"
    > "$PGREP_LOG"

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

# pgrep のデフォルトモック: 実マシン上で本物の inbox_watcher.sh が稼働中でも
# テスト結果がそれに引きずられないよう、常にこの関数で置き換える
# （real pgrep バイナリは呼ばない）。既定では該当プロセス無し＝watcher死亡
# とみなす（exit 1）。生存を模したいテストは呼び出し後にこの関数を
# 上書きしてよい。
pgrep() {
    echo "MOCKPGREP \$*" >> "$PGREP_LOG"
    return 1
}
export -f pgrep
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

# ═══════════════════════════════════════════════════════════════
# D-1: 配送機構死亡検知（既存B-1〜B-3とは独立したOR条件。cmd_171/FU-1）
# ═══════════════════════════════════════════════════════════════

# --- TC-D1-001: 未読1件・timestampが600秒超過 → 通知される ---

@test "TC-D1-001: delivery stall detected when an unread message's timestamp exceeds threshold" {
    local stale_ts
    # `-u` を付けぬこと。本番の書き手 scripts/inbox_write.sh:46 は
    # `date "+%Y-%m-%dT%H:%M:%S"` でローカル時刻・naiveの文字列を書く
    # （QC-70：フィクスチャがUTCを書くと本番と乖離し欠陥を見逃す）。
    stale_ts=$(date -d "@$(( $(date +%s) - 700 ))" +"%Y-%m-%dT%H:%M:%S")
    cat > "$FIXTURE_ROOT/queue/inbox/karo.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    timestamp: '${stale_ts}'
YAML

    run bash -c "
        source '$TEST_HARNESS'
        check_d1_once
    "
    [ "$status" -eq 0 ]
    grep -q "NOTIFY: delivery_stall" "$NOTIFY_LOG"
}

# --- TC-D1-002: 未読1件だがtimestampが600秒以内 → 通知されない ---

@test "TC-D1-002: no delivery-stall notification when the unread message is fresh" {
    local fresh_ts
    fresh_ts=$(date -d "@$(( $(date +%s) - 100 ))" +"%Y-%m-%dT%H:%M:%S")
    cat > "$FIXTURE_ROOT/queue/inbox/karo.yaml" << YAML
messages:
  - id: msg_fresh
    read: false
    timestamp: '${fresh_ts}'
YAML

    run bash -c "
        source '$TEST_HARNESS'
        check_d1_once
    "
    [ "$status" -eq 0 ]
    [ ! -s "$NOTIFY_LOG" ]
}

# --- TC-D1-003: 未読0件 → 通知されない ---

@test "TC-D1-003: no delivery-stall notification when there are no unread messages" {
    # デフォルトフィクスチャは既に read: true のみ

    run bash -c "
        source '$TEST_HARNESS'
        check_d1_once
    "
    [ "$status" -eq 0 ]
    [ ! -s "$NOTIFY_LOG" ]
}

# --- TC-D1-005: D-1もtmuxに一切触れない ---

@test "TC-D1-005: tmux is never called by check_d1_once even when a stall is detected" {
    local stale_ts
    # `-u` を付けぬこと。本番の書き手 scripts/inbox_write.sh:46 は
    # `date "+%Y-%m-%dT%H:%M:%S"` でローカル時刻・naiveの文字列を書く
    # （QC-70：フィクスチャがUTCを書くと本番と乖離し欠陥を見逃す）。
    stale_ts=$(date -d "@$(( $(date +%s) - 700 ))" +"%Y-%m-%dT%H:%M:%S")
    cat > "$FIXTURE_ROOT/queue/inbox/karo.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    timestamp: '${stale_ts}'
YAML

    run bash -c "
        source '$TEST_HARNESS'
        check_d1_once
    "
    [ "$status" -eq 0 ]
    grep -q "NOTIFY: delivery_stall" "$NOTIFY_LOG"
    [ ! -s "$MOCK_TMUX_LOG" ]
}

# --- TC-D1-006: 同一の継続停止に対して二重通知しない ---

@test "TC-D1-006: no duplicate notification for the same continued delivery stall" {
    local stale_ts
    # `-u` を付けぬこと。本番の書き手 scripts/inbox_write.sh:46 は
    # `date "+%Y-%m-%dT%H:%M:%S"` でローカル時刻・naiveの文字列を書く
    # （QC-70：フィクスチャがUTCを書くと本番と乖離し欠陥を見逃す）。
    stale_ts=$(date -d "@$(( $(date +%s) - 700 ))" +"%Y-%m-%dT%H:%M:%S")
    cat > "$FIXTURE_ROOT/queue/inbox/karo.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    timestamp: '${stale_ts}'
YAML

    run bash -c "
        source '$TEST_HARNESS'
        check_d1_once
        check_d1_once
        check_d1_once
    "
    [ "$status" -eq 0 ]
    [ "$(grep -c "NOTIFY: delivery_stall" "$NOTIFY_LOG")" -eq 1 ]
}

# --- TC-D1-007: 【軍師QC §SC-5】watcherが生きていれば、未読が滞留していても通知しない ---

@test "TC-D1-007: no notification when the message is stale but the agent's watcher is alive (busy, not dead)" {
    local stale_ts
    stale_ts=$(date -d "@$(( $(date +%s) - 700 ))" +"%Y-%m-%dT%H:%M:%S")
    cat > "$FIXTURE_ROOT/queue/inbox/karo.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    timestamp: '${stale_ts}'
YAML

    run bash -c "
        source '$TEST_HARNESS'
        # このテストに限り watcher が生きていることにする
        # （長いturnを回している間の正常な滞留を模す）。
        pgrep() { echo \"MOCKPGREP \$*\" >> '$PGREP_LOG'; return 0; }
        export -f pgrep
        check_d1_once
    "
    [ "$status" -eq 0 ]
    [ ! -s "$NOTIFY_LOG" ]
    grep -q "inbox_watcher.sh karo " "$PGREP_LOG"
}

# --- TC-D1-008: 【回帰・QC-70】inbox_write.shが実際に書くnaive・ローカル時刻timestampの解釈 ---

@test "TC-D1-008: naive local timestamp actually written by scripts/inbox_write.sh is correctly interpreted as local time" {
    # inbox_write.sh は自身の BASH_SOURCE から SCRIPT_DIR（= queue/ の親）を
    # 決めるため、fixture配下に実体をコピーして呼べば FIXTURE_ROOT/queue/inbox/
    # に書かせられる。同スクリプトが使う .venv も併せて用意する（本番と同じ
    # venv を再利用。フィクスチャ独自のvenvは持たない）。
    mkdir -p "$FIXTURE_ROOT/scripts"
    cp "$PROJECT_ROOT/scripts/inbox_write.sh" "$FIXTURE_ROOT/scripts/inbox_write.sh"
    ln -s "$PROJECT_ROOT/.venv" "$FIXTURE_ROOT/.venv"

    run bash "$FIXTURE_ROOT/scripts/inbox_write.sh" karo "regression message for QC-70" task_assigned ashigaru3
    [ "$status" -eq 0 ]
    [ -f "$FIXTURE_ROOT/queue/inbox/karo.yaml" ]
    grep -q "read: false" "$FIXTURE_ROOT/queue/inbox/karo.yaml"

    # 実際に書かれた timestamp の「書式」はそのまま（naive・ローカル時刻）に、
    # 「値」だけを600秒前に差し替える。書式そのものを検証するのが本テストの主旨。
    local stale_ts
    stale_ts=$(date -d "@$(( $(date +%s) - 700 ))" +"%Y-%m-%dT%H:%M:%S")
    sed "s/timestamp: .*/timestamp: '${stale_ts}'/" "$FIXTURE_ROOT/queue/inbox/karo.yaml" > "$FIXTURE_ROOT/queue/inbox/karo.yaml.tmp" \
      && mv "$FIXTURE_ROOT/queue/inbox/karo.yaml.tmp" "$FIXTURE_ROOT/queue/inbox/karo.yaml"

    run bash -c "
        source '$TEST_HARNESS'
        check_d1_once
    "
    [ "$status" -eq 0 ]
    grep -q "NOTIFY: delivery_stall" "$NOTIFY_LOG"
}
