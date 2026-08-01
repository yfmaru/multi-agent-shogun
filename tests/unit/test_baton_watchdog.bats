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
#   TC-BATON-001: 未読0・active0・未完cmdあり が閾値継続 → 検知（将軍inbox通知1件）
#   TC-BATON-002: 未読が1件でもあれば検知しない
#   TC-BATON-003: assigned のタスクが1件でもあれば検知しない
#   TC-BATON-004: 未完了 cmd が無ければ検知しない
#   TC-BATON-005: 閾値未満の継続では検知しない
#   TC-BATON-006: 検知しても tmux を一切呼ばない
#   TC-BATON-007: baton_watchdog.enabled=false なら即座に何もしない
#   TC-BATON-008: shogun_to_karo.yaml が壊れている/無い場合も落ちない（open_cmds=0扱い）
#
# 【cmd_172・通知経路二重化】ntfy_topic 未設定で通知が誰にも届かなかった
# 事故（18:02〜21:00停止・9時間ログ0バイト）の是正。
#   TC-NOTIFY-001: ntfy_topic 未設定でも baton_lost_after_sec 到達で将軍inboxへ通知
#   TC-NOTIFY-002: ntfy(branch_policy_notify)はbaton_ntfy_after_sec到達で初めて発火
#   TC-NOTIFY-003: ntfy失敗は将軍inbox通知の成否・処理継続に影響しない
#   TC-NOTIFY-004: check_once は発火有無に関わらず毎回ステータス行を標準出力へ出す
# （TC-NOTIFY-005＝回帰: 上記TC-BATON-001〜008が全PASSし続けることをもって兼ねる）
#
# 【M-2是正・軍師発見】D-1（check_d1_once）も同じ二経路化パターンを適用する。
#   TC-NOTIFY-D1-001: D-1条件成立時、ntfy_topic 未設定でも将軍inboxへ通知される
#   TC-NOTIFY-D1-002: ntfy(branch_policy_notify)はD-1副経路閾値到達時のみ呼ばれる
#   TC-NOTIFY-D1-003: ntfy失敗はD-1の将軍inbox通知・処理継続に影響しない
#   TC-NOTIFY-D1-004（回帰）: 既存のD-1関連テスト・check_once関連テストが全PASS
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
    mkdir -p "$FIXTURE_ROOT/queue/inbox" "$FIXTURE_ROOT/queue/tasks" "$FIXTURE_ROOT/queue/reports" "$FIXTURE_ROOT/config" "$FIXTURE_ROOT/scripts"

    export MOCK_TMUX_LOG="$TEST_TMPDIR/tmux_calls.log"
    export NOTIFY_LOG="$TEST_TMPDIR/notify.log"
    export SHOGUN_NOTIFY_LOG="$TEST_TMPDIR/shogun_notify.log"
    export PGREP_LOG="$TEST_TMPDIR/pgrep_calls.log"
    > "$MOCK_TMUX_LOG"
    > "$NOTIFY_LOG"
    > "$SHOGUN_NOTIFY_LOG"
    > "$PGREP_LOG"

    # baton_watchdog_notify_shogun は "$ROOT/scripts/inbox_write.sh" を直接
    # 呼ぶため（ROOT=フィクスチャroot）、フィクスチャ内にモックを配置する。
    cat > "$FIXTURE_ROOT/scripts/inbox_write.sh" << STUB
#!/usr/bin/env bash
echo "INBOX_WRITE: \$*" >> "$SHOGUN_NOTIFY_LOG"
exit 0
STUB
    chmod +x "$FIXTURE_ROOT/scripts/inbox_write.sh"

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

# settings.yaml を書き直すヘルパー。
# $1=enabled(true/false) $2=baton_lost_after_sec $3=poll_interval_sec
# $4=baton_ntfy_after_sec（省略時はキー自体を書かず、コード側の既定1800に委ねる）
# $5=baton_d1_ntfy_after_sec（省略時はキー自体を書かず、コード側の既定900に委ねる）
# $6=progress_stall_after_sec（省略時はキー自体を書かず、コード側の既定5400に委ねる）
# $7=baton_b4b_ntfy_after_sec（省略時はキー自体を書かず、コード側の既定900に委ねる）
# $8=baton_b4c_stale_after_sec（省略時はキー自体を書かず、コード側の既定5400に委ねる。cmd_180/T-3）
write_settings() {
    local ntfy_line="" d1_ntfy_line="" progress_stall_line="" b4b_ntfy_line="" b4c_stale_line=""
    if [ -n "${4:-}" ]; then
        ntfy_line="  baton_ntfy_after_sec: $4"
    fi
    if [ -n "${5:-}" ]; then
        d1_ntfy_line="  baton_d1_ntfy_after_sec: $5"
    fi
    if [ -n "${6:-}" ]; then
        progress_stall_line="  progress_stall_after_sec: $6"
    fi
    if [ -n "${7:-}" ]; then
        b4b_ntfy_line="  baton_b4b_ntfy_after_sec: $7"
    fi
    if [ -n "${8:-}" ]; then
        b4c_stale_line="  baton_b4c_stale_after_sec: $8"
    fi
    cat > "$FIXTURE_ROOT/config/settings.yaml" << YAML
baton_watchdog:
  enabled: $1
  baton_lost_after_sec: $2
  poll_interval_sec: $3
$ntfy_line
$d1_ntfy_line
$progress_stall_line
$b4b_ntfy_line
$b4c_stale_line
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
    # cmd_172是正後: 主経路は将軍inbox通知（baton_lost_after_sec到達で無条件発火）
    grep -q "INBOX_WRITE: shogun" "$SHOGUN_NOTIFY_LOG"
    grep -q "baton_lost" "$SHOGUN_NOTIFY_LOG"
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
    # 検知は確かに起きている（前提の健全性を確認。cmd_172是正後は将軍inbox経路）
    grep -q "INBOX_WRITE: shogun" "$SHOGUN_NOTIFY_LOG"
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
    [ ! -s "$SHOGUN_NOTIFY_LOG" ]
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


# --- TC-NOTIFY-001: ntfy_topic 未設定でも将軍inboxへは無条件に通知される ---

@test "TC-NOTIFY-001: shogun inbox is notified unconditionally when baton_lost_after_sec is reached, regardless of ntfy_topic" {
    # 既定フィクスチャの settings.yaml には ntfy_topic が一切登場しない
    # （2026-07-29事故の再現条件: ntfy_topic 未設定）。
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: in_progress
YAML

    run bash -c "
        source '$TEST_HARNESS'
        BATON_LOST_SINCE=\$(( \$(date +%s) - 10 ))  # shogun threshold=5s, 10s elapsed
        check_once
    "
    [ "$status" -eq 0 ]
    grep -q "INBOX_WRITE: shogun" "$SHOGUN_NOTIFY_LOG"
    grep -q "baton_alert" "$SHOGUN_NOTIFY_LOG"
    grep -q "baton_watchdog" "$SHOGUN_NOTIFY_LOG"
}

# --- TC-NOTIFY-002: ntfyはbaton_ntfy_after_sec到達で初めて発火する ---

@test "TC-NOTIFY-002: ntfy fires only once the longer baton_ntfy_after_sec threshold is reached" {
    write_settings true 5 60 8   # shogun threshold=5s, ntfy threshold=8s
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: in_progress
YAML

    # elapsed=6s: shogun閾値(5s)は超えるがntfy閾値(8s)はまだ
    run bash -c "
        source '$TEST_HARNESS'
        BATON_LOST_SINCE=\$(( \$(date +%s) - 6 ))
        check_once
    "
    [ "$status" -eq 0 ]
    grep -q "INBOX_WRITE: shogun" "$SHOGUN_NOTIFY_LOG"
    [ ! -s "$NOTIFY_LOG" ]

    # elapsed=10s: ntfy閾値(8s)も超える
    run bash -c "
        source '$TEST_HARNESS'
        BATON_LOST_SINCE=\$(( \$(date +%s) - 10 ))
        check_once
    "
    [ "$status" -eq 0 ]
    grep -q "NOTIFY: baton_lost" "$NOTIFY_LOG"
}

# --- TC-NOTIFY-003: ntfy失敗は将軍inbox通知の成否・処理継続に影響しない ---

@test "TC-NOTIFY-003: ntfy failure does not affect shogun inbox notification or check_once exit status" {
    write_settings true 5 60 5   # 両閾値とも5sにして同一check_once内で両方到達させる
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: in_progress
YAML

    run bash -c "
        source '$TEST_HARNESS'
        branch_policy_notify() { return 1; }  # ntfy_topic未設定時のexit 1相当を模擬
        BATON_LOST_SINCE=\$(( \$(date +%s) - 10 ))
        check_once
    "
    [ "$status" -eq 0 ]
    grep -q "INBOX_WRITE: shogun" "$SHOGUN_NOTIFY_LOG"
}

# --- TC-NOTIFY-004: check_once は発火有無に関わらず毎回ステータス行を出力する ---

@test "TC-NOTIFY-004: check_once always prints a status line regardless of whether it fires" {
    # 既定フィクスチャ: unread=0 active=0 open_cmds=0 → 条件不成立
    run bash -c "
        source '$TEST_HARNESS'
        check_once
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"unread="* ]]
    [[ "$output" == *"active="* ]]
    [[ "$output" == *"open_cmds="* ]]
    [[ "$output" == *"baton_condition=false"* ]]

    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: in_progress
YAML

    run bash -c "
        source '$TEST_HARNESS'
        BATON_LOST_SINCE=\$(( \$(date +%s) - 100 ))
        check_once
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"baton_condition=true"* ]]
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
    # M-2是正後: 主経路は将軍inbox通知（無条件・即座に発火）
    grep -q "INBOX_WRITE: shogun" "$SHOGUN_NOTIFY_LOG"
    grep -q "delivery_stall" "$SHOGUN_NOTIFY_LOG"
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
    # 検知は確かに起きている（前提の健全性を確認。M-2是正後は将軍inbox経路）
    grep -q "INBOX_WRITE: shogun" "$SHOGUN_NOTIFY_LOG"
    # にもかかわらず tmux は一度も呼ばれていない
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
    [ "$(grep -c "INBOX_WRITE: shogun" "$SHOGUN_NOTIFY_LOG")" -eq 1 ]
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
        # （長いturnを回している間の正常な滞留を模す）。cmd_180/T-2で
        # check_d1_once はWATCHER_ALIVE_SNAPSHOTを参照するようになった
        # ため、pgrepモック差し替え後に明示的にスナップショットを
        # 更新する（本番のメインループが毎サイクル行うのと同じ手順）。
        pgrep() { echo \"MOCKPGREP \$*\" >> '$PGREP_LOG'; return 0; }
        export -f pgrep
        baton_watchdog_refresh_watcher_snapshot
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
    # 注: この cp は setup() が置いたモック($FIXTURE_ROOT/scripts/inbox_write.sh)
    # を実物で上書きする。これにより check_d1_once → baton_watchdog_notify_shogun
    # の呼び出しも実物経由になり、$FIXTURE_ROOT/queue/inbox/shogun.yaml へ
    # 実際に書き込まれる（このテストに限りSHOGUN_NOTIFY_LOGは使われない）。
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
    [ -f "$FIXTURE_ROOT/queue/inbox/shogun.yaml" ]
    grep -q "delivery_stall" "$FIXTURE_ROOT/queue/inbox/shogun.yaml"
}

# --- TC-D1-LATCH-001【QC39-F2の固定】診断対象がshogun単独のとき、D-1はkaro宛に書き、将軍inboxの未読を増やさぬ ---

@test "TC-D1-LATCH-001: D-1 writes to karo (not shogun) when shogun alone is the dead-stale target, and shogun's unread count does not increase" {
    local stale_ts before_count after_count
    stale_ts=$(date -d "@$(( $(date +%s) - 700 ))" +"%Y-%m-%dT%H:%M:%S")
    cat > "$FIXTURE_ROOT/queue/inbox/shogun.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    timestamp: '${stale_ts}'
YAML
    before_count=$(grep -c 'read: false' "$FIXTURE_ROOT/queue/inbox/shogun.yaml")

    run bash -c "
        source '$TEST_HARNESS'
        check_d1_once
    "
    [ "$status" -eq 0 ]
    grep -q "INBOX_WRITE: karo" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    grep -q "delivery_stall" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }

    after_count=$(grep -c 'read: false' "$FIXTURE_ROOT/queue/inbox/shogun.yaml")
    [ "$before_count" -eq "$after_count" ] || { echo "shogun unread count changed: before=$before_count after=$after_count"; false; }
}

# --- TC-D1-LATCH-002【QC39-F1の直接固定・是正前に確実に落ちること確認済み】診断対象がshogun+ashigaru3の2名のとき、D-1はkaro宛に書き、将軍inboxの未読を増やさぬ ---

@test "TC-D1-LATCH-002: D-1 writes to karo (not shogun) when shogun is dead-stale together with another agent, and shogun's unread count does not increase" {
    local stale_ts before_count after_count
    stale_ts=$(date -d "@$(( $(date +%s) - 700 ))" +"%Y-%m-%dT%H:%M:%S")
    cat > "$FIXTURE_ROOT/queue/inbox/shogun.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    timestamp: '${stale_ts}'
YAML
    cat > "$FIXTURE_ROOT/queue/inbox/ashigaru3.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    timestamp: '${stale_ts}'
YAML
    before_count=$(grep -c 'read: false' "$FIXTURE_ROOT/queue/inbox/shogun.yaml")

    run bash -c "
        source '$TEST_HARNESS'
        check_d1_once
    "
    [ "$status" -eq 0 ]
    # dead_stale_agents = [ashigaru3, shogun]（要素数2）。QC39-F1是正前の
    # 「shogunが単独のときだけ」判定は当たらず、将軍inboxへ誤って書かれる
    # （＝本テストは是正前のコードに対して確実に落ちる）。
    grep -q "INBOX_WRITE: karo" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    grep -q "delivery_stall" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }

    after_count=$(grep -c 'read: false' "$FIXTURE_ROOT/queue/inbox/shogun.yaml")
    [ "$before_count" -eq "$after_count" ] || { echo "shogun unread count changed: before=$before_count after=$after_count"; false; }
}

# ═══════════════════════════════════════════════════════════════
# 【M-2是正・軍師発見】check_d1_once の通知経路二重化（cmd_172）
# ═══════════════════════════════════════════════════════════════

# --- TC-NOTIFY-D1-001: D-1条件成立時、ntfy_topic未設定でも将軍inboxへ無条件に通知される ---

@test "TC-NOTIFY-D1-001: shogun inbox is notified unconditionally when D-1 condition is met, regardless of ntfy_topic" {
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
        check_d1_once
    "
    [ "$status" -eq 0 ]
    grep -q "INBOX_WRITE: shogun" "$SHOGUN_NOTIFY_LOG"
    grep -q "baton_alert" "$SHOGUN_NOTIFY_LOG"
    grep -q "baton_watchdog" "$SHOGUN_NOTIFY_LOG"
}

# --- TC-NOTIFY-D1-002: ntfyはD-1専用のbaton_d1_ntfy_after_sec到達で初めて発火する ---

@test "TC-NOTIFY-D1-002: ntfy fires only once the D-1-specific baton_d1_ntfy_after_sec threshold is reached" {
    write_settings true 5 60 1800 8   # baton_d1_ntfy_after_sec=8s（D-1専用・短い閾値）
    local stale_ts
    stale_ts=$(date -d "@$(( $(date +%s) - 700 ))" +"%Y-%m-%dT%H:%M:%S")
    cat > "$FIXTURE_ROOT/queue/inbox/karo.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    timestamp: '${stale_ts}'
YAML

    # 検知直後（BATON_D1_CONDITION_SINCE計測開始直後）: 主経路は即発火するが副経路はまだ
    run bash -c "
        source '$TEST_HARNESS'
        check_d1_once
    "
    [ "$status" -eq 0 ]
    grep -q "INBOX_WRITE: shogun" "$SHOGUN_NOTIFY_LOG"
    [ ! -s "$NOTIFY_LOG" ]

    # BATON_D1_CONDITION_SINCEを直接過去化し、ntfy閾値(8s)到達後の状態を模す
    run bash -c "
        source '$TEST_HARNESS'
        BATON_D1_CONDITION_SINCE=\$(( \$(date +%s) - 10 ))
        check_d1_once
    "
    [ "$status" -eq 0 ]
    grep -q "NOTIFY: delivery_stall" "$NOTIFY_LOG"
}

# --- TC-NOTIFY-D1-003: ntfy失敗はD-1の将軍inbox通知・処理継続に影響しない ---

@test "TC-NOTIFY-D1-003: ntfy failure does not affect D-1 shogun inbox notification or check_d1_once exit status" {
    write_settings true 5 60 1800 5   # baton_d1_ntfy_after_sec=5s
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
        branch_policy_notify() { return 1; }  # ntfy_topic未設定時のexit 1相当を模擬
        BATON_D1_CONDITION_SINCE=\$(( \$(date +%s) - 10 ))
        check_d1_once
    "
    [ "$status" -eq 0 ]
    grep -q "INBOX_WRITE: shogun" "$SHOGUN_NOTIFY_LOG"
}

# ═══════════════════════════════════════════════════════════════
# B-4b: 無進捗検知（バトンを保持したまま停止）(cmd_179/T-B)
#
# 発端: 足軽7号が使用量制限中に報告執筆で中断し、status:assignedのまま
# 5時間41分誰にも検知されなかった。条件はAND: (i) queue/tasks/<agent>.yaml
# のstatusがassigned/in_progressであり、かつqueue/reports/<agent>_report.yaml
# が「同一task_id・status:done」という既に納品済みの反証を示していない
# (＝バトンを保持中)。(ii) task/report/inboxのmtime最大値
# (progress artifact) が progress_stall_after_sec 秒以上更新されていない。
# 当初案にあった「未読0」条件(iii)は誤りと判明し削除済み——escalation
# ladderには通知経路が一切無いため、未読が残ったまま止まっている
# ケースを永久に見逃す設計になってしまうため。
#
#   TC-B4B-001: 条件(i)(ii)がいずれも成立 → 通知される
#   TC-B4B-002: 条件(i)は成立するが(ii)（mtimeが新しい）が不成立 → 通知されない
#   TC-B4B-003: task.status=assignedだがreport.task_idが一致し
#               report.status=doneの場合 → 通知されない（本日実際に3体で
#               起きた誤発火パターンの回帰固定）
#   TC-B4B-004: 未読が1件以上ある状態でも(i)(ii)が成立すれば通知される
#               （削除した条件(iii)の回帰）
#   TC-B4B-005: tmuxを一切呼ばない
#   TC-B4B-006: 同一の継続停止に対して二重通知しない（NOTIFIEDフラグ）
#   TC-B4B-007: 停止が解消されればNOTIFIEDフラグがリセットされ、
#               再度停止すれば再通知される
#   TC-NOTIFY-B4B-001〜003: D-1のTC-NOTIFY-D1-001〜003と同型
#   TC-B4B-REAL-001: 2026-07-31 13:02頃の足軽7号の実データの形
#                     （task.status=assigned、5時間41分無更新、
#                     reportは別task_idで不一致）を固定する回帰
# ═══════════════════════════════════════════════════════════════

# --- TC-B4B-001: 条件(i)(ii)がいずれも成立 → 通知される ---

@test "TC-B4B-001: no-progress detected when (i) baton held and (ii) progress stalled past threshold" {
    write_settings true 5 60 "" "" 5 60   # progress_stall_after_sec=5, baton_b4b_ntfy_after_sec=60
    cat > "$FIXTURE_ROOT/queue/tasks/ashigaru3.yaml" << 'YAML'
task:
  task_id: subtask_test_b4b
  status: assigned
YAML
    touch -d "@$(( $(date +%s) - 10000 ))" "$FIXTURE_ROOT/queue/tasks/ashigaru3.yaml"

    run bash -c "
        source '$TEST_HARNESS'
        check_b4b_once
    "
    [ "$status" -eq 0 ]
    grep -q "INBOX_WRITE: shogun" "$SHOGUN_NOTIFY_LOG"
    grep -q "no_progress: agent=ashigaru3" "$SHOGUN_NOTIFY_LOG"
    grep -q "subtask_test_b4b" "$SHOGUN_NOTIFY_LOG"
}

# --- TC-B4B-002: 条件(i)は成立するが(ii)（mtimeが新しい）が不成立 → 通知されない ---

@test "TC-B4B-002: no notification when (i) holds but (ii) progress is fresh" {
    write_settings true 5 60 "" "" 5 60
    cat > "$FIXTURE_ROOT/queue/tasks/ashigaru3.yaml" << 'YAML'
task:
  task_id: subtask_test_b4b_fresh
  status: assigned
YAML
    # touchせず、作成直後の新しいmtimeのまま（条件(ii)不成立）

    run bash -c "
        source '$TEST_HARNESS'
        check_b4b_once
    "
    [ "$status" -eq 0 ]
    [ ! -s "$SHOGUN_NOTIFY_LOG" ]
}

# --- TC-B4B-003: 【回帰・誤発火防止】既に納品済み(report一致・done)なら通知されない ---

@test "TC-B4B-003: no notification when task.status=assigned but the matching report is already done" {
    write_settings true 5 60 "" "" 5 60
    cat > "$FIXTURE_ROOT/queue/tasks/ashigaru4.yaml" << 'YAML'
task:
  task_id: subtask_delivered
  status: assigned
YAML
    touch -d "@$(( $(date +%s) - 10000 ))" "$FIXTURE_ROOT/queue/tasks/ashigaru4.yaml"
    cat > "$FIXTURE_ROOT/queue/reports/ashigaru4_report.yaml" << 'YAML'
worker_id: ashigaru4
task_id: subtask_delivered
status: done
YAML

    run bash -c "
        source '$TEST_HARNESS'
        check_b4b_once
    "
    [ "$status" -eq 0 ]
    [ ! -s "$SHOGUN_NOTIFY_LOG" ]
}

# --- TC-B4B-004: 【回帰・削除した条件(iii)】未読が残っていても検知される ---

@test "TC-B4B-004: no-progress is still detected even when unread messages remain (removed condition iii regression)" {
    write_settings true 5 60 "" "" 5 60
    cat > "$FIXTURE_ROOT/queue/tasks/ashigaru5.yaml" << 'YAML'
task:
  task_id: subtask_test_b4b_unread
  status: assigned
YAML
    touch -d "@$(( $(date +%s) - 10000 ))" "$FIXTURE_ROOT/queue/tasks/ashigaru5.yaml"
    cat > "$FIXTURE_ROOT/queue/inbox/ashigaru5.yaml" << 'YAML'
messages:
  - id: msg_unread
    read: false
YAML
    touch -d "@$(( $(date +%s) - 10000 ))" "$FIXTURE_ROOT/queue/inbox/ashigaru5.yaml"

    # 前提の健全性: 未読が確かに残っている
    [ "$(grep -c 'read: false' "$FIXTURE_ROOT/queue/inbox/ashigaru5.yaml")" -eq 1 ]

    run bash -c "
        source '$TEST_HARNESS'
        check_b4b_once
    "
    [ "$status" -eq 0 ]
    grep -q "no_progress: agent=ashigaru5" "$SHOGUN_NOTIFY_LOG"
}

# --- TC-B4B-005: 【重要】検知しても tmux を一切呼ばない ---

@test "TC-B4B-005: tmux is never called by check_b4b_once even when no-progress is detected" {
    write_settings true 5 60 "" "" 5 60
    cat > "$FIXTURE_ROOT/queue/tasks/ashigaru3.yaml" << 'YAML'
task:
  task_id: subtask_test_b4b_tmux
  status: assigned
YAML
    touch -d "@$(( $(date +%s) - 10000 ))" "$FIXTURE_ROOT/queue/tasks/ashigaru3.yaml"

    run bash -c "
        source '$TEST_HARNESS'
        check_b4b_once
    "
    [ "$status" -eq 0 ]
    grep -q "INBOX_WRITE: shogun" "$SHOGUN_NOTIFY_LOG"
    [ ! -s "$MOCK_TMUX_LOG" ]
}

# --- TC-B4B-006: 同一の継続停止に対して二重通知しない ---

@test "TC-B4B-006: no duplicate notification for the same continued no-progress stop" {
    write_settings true 5 60 "" "" 5 60
    cat > "$FIXTURE_ROOT/queue/tasks/ashigaru3.yaml" << 'YAML'
task:
  task_id: subtask_test_b4b_dup
  status: assigned
YAML
    touch -d "@$(( $(date +%s) - 10000 ))" "$FIXTURE_ROOT/queue/tasks/ashigaru3.yaml"

    run bash -c "
        source '$TEST_HARNESS'
        check_b4b_once
        check_b4b_once
        check_b4b_once
    "
    [ "$status" -eq 0 ]
    [ "$(grep -c "no_progress: agent=ashigaru3" "$SHOGUN_NOTIFY_LOG")" -eq 1 ]
}

# --- TC-B4B-007: 停止解消でNOTIFIEDがリセットされ、再停止で再通知される ---

@test "TC-B4B-007: NOTIFIED flag resets once the stall resolves, then re-fires on a renewed stall" {
    write_settings true 5 60 "" "" 5 60
    cat > "$FIXTURE_ROOT/queue/tasks/ashigaru6.yaml" << 'YAML'
task:
  task_id: subtask_test_b4b_recur
  status: assigned
YAML
    touch -d "@$(( $(date +%s) - 10000 ))" "$FIXTURE_ROOT/queue/tasks/ashigaru6.yaml"

    run bash -c "
        source '$TEST_HARNESS'
        check_b4b_once
        # 進捗が観測された体でmtimeを新しくする(=条件(ii)崩れ)
        touch '$FIXTURE_ROOT/queue/tasks/ashigaru6.yaml'
        check_b4b_once
        # 再び古いmtimeに戻す(=条件(ii)再成立。新たな継続として扱われるはず)
        touch -d '@$(( $(date +%s) - 10000 ))' '$FIXTURE_ROOT/queue/tasks/ashigaru6.yaml'
        check_b4b_once
    "
    [ "$status" -eq 0 ]
    [ "$(grep -c "no_progress: agent=ashigaru6" "$SHOGUN_NOTIFY_LOG")" -eq 2 ]
}

# --- TC-NOTIFY-B4B-001: ntfy_topic未設定でも将軍inboxへ無条件に通知される ---

@test "TC-NOTIFY-B4B-001: shogun inbox is notified unconditionally when B-4b condition is met, regardless of ntfy_topic" {
    write_settings true 5 60 "" "" 5 60
    cat > "$FIXTURE_ROOT/queue/tasks/ashigaru3.yaml" << 'YAML'
task:
  task_id: subtask_test_b4b_notify1
  status: assigned
YAML
    touch -d "@$(( $(date +%s) - 10000 ))" "$FIXTURE_ROOT/queue/tasks/ashigaru3.yaml"

    run bash -c "
        source '$TEST_HARNESS'
        check_b4b_once
    "
    [ "$status" -eq 0 ]
    grep -q "INBOX_WRITE: shogun" "$SHOGUN_NOTIFY_LOG"
    grep -q "baton_alert" "$SHOGUN_NOTIFY_LOG"
    grep -q "baton_watchdog" "$SHOGUN_NOTIFY_LOG"
}

# --- TC-NOTIFY-B4B-002: ntfyはB-4b専用のbaton_b4b_ntfy_after_sec到達で初めて発火する ---

@test "TC-NOTIFY-B4B-002: ntfy fires only once the B-4b-specific baton_b4b_ntfy_after_sec threshold is reached" {
    write_settings true 5 60 "" "" 5 8   # progress_stall_after_sec=5, baton_b4b_ntfy_after_sec=8
    cat > "$FIXTURE_ROOT/queue/tasks/ashigaru7.yaml" << 'YAML'
task:
  task_id: subtask_test_b4b_ntfy
  status: assigned
YAML
    touch -d "@$(( $(date +%s) - 10000 ))" "$FIXTURE_ROOT/queue/tasks/ashigaru7.yaml"

    # 検知直後（B4B_CONDITION_SINCE計測開始直後）: 主経路は即発火するが副経路はまだ
    run bash -c "
        source '$TEST_HARNESS'
        check_b4b_once
    "
    [ "$status" -eq 0 ]
    grep -q "no_progress: agent=ashigaru7" "$SHOGUN_NOTIFY_LOG"
    [ ! -s "$NOTIFY_LOG" ]

    # B4B_CONDITION_SINCEを直接過去化し、ntfy閾値(8s)到達後の状態を模す
    run bash -c "
        source '$TEST_HARNESS'
        B4B_CONDITION_SINCE[ashigaru7]=\$(( \$(date +%s) - 10 ))
        check_b4b_once
    "
    [ "$status" -eq 0 ]
    grep -q "NOTIFY: no_progress: agent=ashigaru7" "$NOTIFY_LOG"
}

# --- TC-NOTIFY-B4B-003: ntfy失敗はB-4bの将軍inbox通知・処理継続に影響しない ---

@test "TC-NOTIFY-B4B-003: ntfy failure does not affect B-4b shogun inbox notification or check_b4b_once exit status" {
    write_settings true 5 60 "" "" 5 5   # baton_b4b_ntfy_after_sec=5
    cat > "$FIXTURE_ROOT/queue/tasks/ashigaru7.yaml" << 'YAML'
task:
  task_id: subtask_test_b4b_ntfy_fail
  status: assigned
YAML
    touch -d "@$(( $(date +%s) - 10000 ))" "$FIXTURE_ROOT/queue/tasks/ashigaru7.yaml"

    run bash -c "
        source '$TEST_HARNESS'
        branch_policy_notify() { return 1; }  # ntfy_topic未設定時のexit 1相当を模擬
        B4B_CONDITION_SINCE[ashigaru7]=\$(( \$(date +%s) - 10 ))
        check_b4b_once
    "
    [ "$status" -eq 0 ]
    grep -q "no_progress: agent=ashigaru7" "$SHOGUN_NOTIFY_LOG"
}

# --- TC-B4B-REAL-001: 【acceptance_criteria 2】実データの形の回帰固定 ---
#
# 2026-07-31 13:02頃、足軽7号がsubtask_178_pc2_daily_consumption_log_v2の
# 報告執筆中に使用量制限へ達して中断し、task.status=assignedのまま5時間
# 41分（20460秒）誰にも検知されなかった。当時のreportは前タスク
# （subtask_177_prior_task。実際の前タスクIDは異なるが「新task_idとは
# 不一致」という形が本質）のまま更新されておらず、(i)の判定基準である
# 「report.task_idが一致しstatus:doneという反証」が成立しなかった。
# progress_stall_after_secは本番既定値（5400秒）のまま検証する。

@test "TC-B4B-REAL-001: regression fixed to the real 2026-07-31 13:02 ashigaru7 incident shape (5h41m stall, mismatched report task_id)" {
    write_settings true 5 60 "" "" 5400 900   # 本番既定値のまま
    cat > "$FIXTURE_ROOT/queue/tasks/ashigaru7.yaml" << 'YAML'
task:
  task_id: subtask_178_pc2_daily_consumption_log_v2
  parent_cmd: cmd_178
  status: assigned
YAML
    touch -d "@$(( $(date +%s) - 20460 ))" "$FIXTURE_ROOT/queue/tasks/ashigaru7.yaml"

    cat > "$FIXTURE_ROOT/queue/reports/ashigaru7_report.yaml" << 'YAML'
worker_id: ashigaru7
task_id: subtask_177_prior_task
status: done
YAML
    touch -d "@$(( $(date +%s) - 20460 ))" "$FIXTURE_ROOT/queue/reports/ashigaru7_report.yaml"

    run bash -c "
        source '$TEST_HARNESS'
        check_b4b_once
    "
    [ "$status" -eq 0 ]
    grep -q "INBOX_WRITE: shogun" "$SHOGUN_NOTIFY_LOG"
    grep -q "no_progress: agent=ashigaru7" "$SHOGUN_NOTIFY_LOG"
    grep -q "subtask_178_pc2_daily_consumption_log_v2" "$SHOGUN_NOTIFY_LOG"
}

# ═══════════════════════════════════════════════════════════════
# 【cmd_180・自己沈黙の解消】T-1: baton_watchdog_count_unread の
# 自己給餌排除（2026-07-31 20:52:25、6時間23分の自己沈黙インシデント）
#
#   TC-SELF-001: baton_watchdog自身の警報は除外される（昨夜の形そのもの）
#   TC-SELF-002: watcher_supervisorの警報も同様に除外される
#   TC-SELF-003【最重要・対照実験】fromがkaro等の真の未読は引き続き数える
#   TC-SELF-004: fromフィールド欠落の未読は数える（除外せぬ）
#   TC-SELF-005: 副経路ntfyが実際に到達する（昨夜到達し得なかった経路）
#   TC-SELF-006: python/yaml失敗時のフォールバックは除外なしのgrep方式へ
# ═══════════════════════════════════════════════════════════════

# --- TC-SELF-001: baton_watchdog自身の警報は自己沈黙を起こさず除外される ---

@test "TC-SELF-001: baton_watchdog's own alert in shogun inbox is excluded from unread count (2026-07-31 20:52 incident shape)" {
    cat > "$FIXTURE_ROOT/queue/inbox/shogun.yaml" << 'YAML'
messages:
  - id: msg_alert
    read: false
    from: baton_watchdog
    type: baton_alert
    timestamp: '2026-07-31T20:52:25'
YAML
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: in_progress
YAML

    run bash -c "
        source '$TEST_HARNESS'
        check_once
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"unread=0"* ]]
    [[ "$output" == *"baton_condition=true"* ]]
}

# --- TC-SELF-002: watcher_supervisorの警報も同様に除外される ---

@test "TC-SELF-002: watcher_supervisor's own alert in shogun inbox is also excluded from unread count" {
    cat > "$FIXTURE_ROOT/queue/inbox/shogun.yaml" << 'YAML'
messages:
  - id: msg_watcher_alert
    read: false
    from: watcher_supervisor
    type: watcher_alert
    timestamp: '2026-07-31T20:52:25'
YAML
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: in_progress
YAML

    run bash -c "
        source '$TEST_HARNESS'
        check_once
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"unread=0"* ]]
    [[ "$output" == *"baton_condition=true"* ]]
}

# --- TC-SELF-003【最重要の対照実験】真の未読(from: karo)は引き続き数えられる ---

@test "TC-SELF-003: a genuine unread from karo is still counted (intent-preserving control against over-exclusion)" {
    cat > "$FIXTURE_ROOT/queue/inbox/shogun.yaml" << 'YAML'
messages:
  - id: msg_real
    read: false
    from: karo
    type: task_assigned
    timestamp: '2026-07-31T20:52:25'
YAML
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: in_progress
YAML

    run bash -c "
        source '$TEST_HARNESS'
        check_once
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"unread=1"* ]]
    [[ "$output" == *"baton_condition=false"* ]]
}

# --- TC-SELF-004: fromフィールド欠落の未読は数える（除外せぬ） ---

@test "TC-SELF-004: a message with no 'from' field is still counted (safe-side; not treated as excluded)" {
    cat > "$FIXTURE_ROOT/queue/inbox/shogun.yaml" << 'YAML'
messages:
  - id: msg_no_from
    read: false
YAML
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: in_progress
YAML

    run bash -c "
        source '$TEST_HARNESS'
        check_once
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"unread=1"* ]]
    [[ "$output" == *"baton_condition=false"* ]]
}

# --- TC-SELF-005: 副経路ntfyが実際に到達する（AC2） ---

@test "TC-SELF-005: secondary ntfy route actually reaches once baton_ntfy_after_sec elapses (the route that never fired all of last night)" {
    write_settings true 5 60 8   # shogun threshold=5s, ntfy threshold=8s
    cat > "$FIXTURE_ROOT/queue/inbox/shogun.yaml" << 'YAML'
messages:
  - id: msg_alert
    read: false
    from: baton_watchdog
    type: baton_alert
    timestamp: '2026-07-31T20:52:25'
YAML
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
    grep -q "NOTIFY: baton_lost" "$NOTIFY_LOG"
}

# --- TC-SELF-006: python/yaml失敗時のフォールバック方向（除外なしgrep方式） ---

@test "TC-SELF-006: count_unread falls back to the conservative grep count (no exclusion) when python/yaml is unavailable" {
    cat > "$FIXTURE_ROOT/queue/inbox/shogun.yaml" << 'YAML'
messages:
  - id: msg_alert
    read: false
    from: baton_watchdog
    type: baton_alert
    timestamp: '2026-07-31T20:52:25'
YAML

    run bash -c "
        source '$TEST_HARNESS'
        stall_policy_python() { echo '/nonexistent/python3'; }
        baton_watchdog_count_unread
    "
    [ "$status" -eq 0 ]
    # フォールバックは除外なしのgrep方式へ戻るため、baton_watchdog由来の
    # 警報も数えられる（unread=0へは倒れない。フォールバック方向を誤ると
    # ここが0になり、誤って baton_condition が真になる）。
    [ "$output" = "1" ]
}

# ═══════════════════════════════════════════════════════════════
# 【cmd_180】T-2: watcher生死スナップショットの共有（D-1・B-4cの排他性）
# T-3: B-4c（stale未読 かつ watcher生存）本体
# T-4: D-1の通知先決定規則（診断した当人へは書かぬ）
#
#   TC-B4C-EXCL-001: D-1発火時にB-4cが発火せぬ（dead watcher）
#   TC-B4C-EXCL-002: B-4c発火時にD-1が発火せぬ（alive watcher）
#   TC-B4C-EXCL-003【最重要】D-1・B-4c間でpgrep応答が反転しても通知は1件のみ
#   TC-B4C-LATCH-001: B-4cは診断対象自身(shogun)のinboxへは書かぬ（自己給餌ラッチ防止）
#   TC-B4C-LATCH-002: 停止解消でガードがリセットされ、再度staleで再通知される
#   TC-B4C-001: karo（task YAMLを持たぬエージェント）が対象で発火（AC3）
#   TC-B4C-002: 閾値未満では発火しない
#   TC-B4C-003: tmuxを一切呼ばない
# ═══════════════════════════════════════════════════════════════

# --- TC-B4C-EXCL-001: D-1発火時にB-4cが発火せぬ（同一のdead-watcher-stale-inbox） ---

@test "TC-B4C-EXCL-001: D-1 fires and B-4c stays silent for the same dead-watcher stale inbox" {
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
        baton_watchdog_refresh_watcher_snapshot
        check_d1_once
        check_b4c_once
    "
    [ "$status" -eq 0 ]
    [ "$(grep -c "delivery_stall" "$SHOGUN_NOTIFY_LOG")" -eq 1 ]
    [ "$(grep -c "inbox_stall" "$SHOGUN_NOTIFY_LOG")" -eq 0 ]
}

# --- TC-B4C-EXCL-002: B-4c発火時にD-1が発火せぬ（同一のalive-watcher-stale-inbox） ---

@test "TC-B4C-EXCL-002: B-4c fires and D-1 stays silent for the same live-watcher stale inbox" {
    local stale_ts
    stale_ts=$(date -d "@$(( $(date +%s) - 6000 ))" +"%Y-%m-%dT%H:%M:%S")
    cat > "$FIXTURE_ROOT/queue/inbox/karo.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    timestamp: '${stale_ts}'
YAML

    run bash -c "
        source '$TEST_HARNESS'
        pgrep() { echo \"MOCKPGREP \$*\" >> '$PGREP_LOG'; return 0; }
        export -f pgrep
        baton_watchdog_refresh_watcher_snapshot
        check_d1_once
        check_b4c_once
    "
    [ "$status" -eq 0 ]
    [ "$(grep -c "delivery_stall" "$SHOGUN_NOTIFY_LOG")" -eq 0 ]
    [ "$(grep -c "inbox_stall" "$SHOGUN_NOTIFY_LOG")" -eq 1 ]
}

# --- TC-B4C-EXCL-003【最重要・是正1の固定】D-1・B-4c間でpgrep応答が反転しても通知は1件のみ ---

@test "TC-B4C-EXCL-003: flipping pgrep from dead to alive between the D-1 and B-4c calls still yields exactly one notification (frozen snapshot)" {
    local stale_ts
    stale_ts=$(date -d "@$(( $(date +%s) - 6000 ))" +"%Y-%m-%dT%H:%M:%S")
    cat > "$FIXTURE_ROOT/queue/inbox/karo.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    timestamp: '${stale_ts}'
YAML

    run bash -c "
        source '$TEST_HARNESS'
        baton_watchdog_refresh_watcher_snapshot
        check_d1_once
        pgrep() { echo \"MOCKPGREP \$*\" >> '$PGREP_LOG'; return 0; }
        export -f pgrep
        check_b4c_once
    "
    [ "$status" -eq 0 ]
    local delivery_count inbox_count
    delivery_count=$(grep -c "delivery_stall" "$SHOGUN_NOTIFY_LOG" || true)
    inbox_count=$(grep -c "inbox_stall" "$SHOGUN_NOTIFY_LOG" || true)
    [ "$((delivery_count + inbox_count))" -eq 1 ]
}

# --- TC-B4C-LATCH-001【是正2の固定】診断対象自身(shogun)のinboxへは書かぬ ---

@test "TC-B4C-LATCH-001: B-4c never writes to shogun's own inbox when shogun is the diagnosed target (self-feeding latch prevention)" {
    local stale_ts before_count after_count
    stale_ts=$(date -d "@$(( $(date +%s) - 6000 ))" +"%Y-%m-%dT%H:%M:%S")
    cat > "$FIXTURE_ROOT/queue/inbox/shogun.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    timestamp: '${stale_ts}'
YAML
    before_count=$(grep -c 'read: false' "$FIXTURE_ROOT/queue/inbox/shogun.yaml")

    run bash -c "
        source '$TEST_HARNESS'
        pgrep() { echo \"MOCKPGREP \$*\" >> '$PGREP_LOG'; return 0; }
        export -f pgrep
        baton_watchdog_refresh_watcher_snapshot
        check_b4c_once
    "
    [ "$status" -eq 0 ]
    grep -q "INBOX_WRITE: karo" "$SHOGUN_NOTIFY_LOG"
    grep -q "inbox_stall: agent=shogun" "$SHOGUN_NOTIFY_LOG"

    after_count=$(grep -c 'read: false' "$FIXTURE_ROOT/queue/inbox/shogun.yaml")
    [ "$before_count" -eq "$after_count" ]
}

# --- TC-B4C-LATCH-002: 停止解消でガードがリセットされ、再度staleで再通知される ---

@test "TC-B4C-LATCH-002: guard resets once shogun's stale message is read, then re-fires on a renewed stall" {
    local stale_ts
    stale_ts=$(date -d "@$(( $(date +%s) - 6000 ))" +"%Y-%m-%dT%H:%M:%S")
    cat > "$FIXTURE_ROOT/queue/inbox/shogun.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    timestamp: '${stale_ts}'
YAML

    run bash -c "
        source '$TEST_HARNESS'
        pgrep() { echo \"MOCKPGREP \$*\" >> '$PGREP_LOG'; return 0; }
        export -f pgrep
        baton_watchdog_refresh_watcher_snapshot
        check_b4c_once

        sed 's/read: false/read: true/' '$FIXTURE_ROOT/queue/inbox/shogun.yaml' > '$FIXTURE_ROOT/queue/inbox/shogun.yaml.tmp' \
          && mv '$FIXTURE_ROOT/queue/inbox/shogun.yaml.tmp' '$FIXTURE_ROOT/queue/inbox/shogun.yaml'
        baton_watchdog_refresh_watcher_snapshot
        check_b4c_once

        sed 's/read: true/read: false/' '$FIXTURE_ROOT/queue/inbox/shogun.yaml' > '$FIXTURE_ROOT/queue/inbox/shogun.yaml.tmp' \
          && mv '$FIXTURE_ROOT/queue/inbox/shogun.yaml.tmp' '$FIXTURE_ROOT/queue/inbox/shogun.yaml'
        baton_watchdog_refresh_watcher_snapshot
        check_b4c_once
    "
    [ "$status" -eq 0 ]
    [ "$(grep -c "inbox_stall: agent=shogun" "$SHOGUN_NOTIFY_LOG")" -eq 2 ]
}

# --- TC-B4C-001【AC3】karo（queue/tasks/*.yamlを持たぬエージェント）が対象で発火 ---

@test "TC-B4C-001: inbox-stall detected for karo (an agent with no queue/tasks/*.yaml, per AC3) when watcher is alive" {
    write_settings true 5 60 "" "" "" "" 5   # baton_b4c_stale_after_sec=5
    local stale_ts
    stale_ts=$(date -d "@$(( $(date +%s) - 10 ))" +"%Y-%m-%dT%H:%M:%S")
    cat > "$FIXTURE_ROOT/queue/inbox/karo.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    timestamp: '${stale_ts}'
YAML

    run bash -c "
        source '$TEST_HARNESS'
        pgrep() { echo \"MOCKPGREP \$*\" >> '$PGREP_LOG'; return 0; }
        export -f pgrep
        baton_watchdog_refresh_watcher_snapshot
        check_b4c_once
    "
    [ "$status" -eq 0 ]
    grep -q "INBOX_WRITE: shogun" "$SHOGUN_NOTIFY_LOG"
    grep -q "inbox_stall: agent=karo" "$SHOGUN_NOTIFY_LOG"
}

# --- TC-B4C-002: 閾値未満では発火しない ---

@test "TC-B4C-002: no notification when stale duration is under the baton_b4c_stale_after_sec threshold" {
    write_settings true 5 60 "" "" "" "" 6000   # baton_b4c_stale_after_sec=6000
    local fresh_ts
    fresh_ts=$(date -d "@$(( $(date +%s) - 10 ))" +"%Y-%m-%dT%H:%M:%S")
    cat > "$FIXTURE_ROOT/queue/inbox/karo.yaml" << YAML
messages:
  - id: msg_fresh
    read: false
    timestamp: '${fresh_ts}'
YAML

    run bash -c "
        source '$TEST_HARNESS'
        pgrep() { echo \"MOCKPGREP \$*\" >> '$PGREP_LOG'; return 0; }
        export -f pgrep
        baton_watchdog_refresh_watcher_snapshot
        check_b4c_once
    "
    [ "$status" -eq 0 ]
    [ ! -s "$SHOGUN_NOTIFY_LOG" ]
}

# --- TC-B4C-003: tmuxを一切呼ばない ---

@test "TC-B4C-003: tmux is never called by check_b4c_once even when inbox-stall is detected" {
    write_settings true 5 60 "" "" "" "" 5
    local stale_ts
    stale_ts=$(date -d "@$(( $(date +%s) - 10 ))" +"%Y-%m-%dT%H:%M:%S")
    cat > "$FIXTURE_ROOT/queue/inbox/karo.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    timestamp: '${stale_ts}'
YAML

    run bash -c "
        source '$TEST_HARNESS'
        pgrep() { echo \"MOCKPGREP \$*\" >> '$PGREP_LOG'; return 0; }
        export -f pgrep
        baton_watchdog_refresh_watcher_snapshot
        check_b4c_once
    "
    [ "$status" -eq 0 ]
    grep -q "INBOX_WRITE: shogun" "$SHOGUN_NOTIFY_LOG"
    [ ! -s "$MOCK_TMUX_LOG" ]
}
