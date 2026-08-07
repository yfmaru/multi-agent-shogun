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
#
# 【cmd_197: baton_watchdogへ「人待ち」の印を追加】check_once が数える
# open_cmds のうち、`queue/shogun_to_karo.yaml` の cmd に
# `awaiting: lord` が付いたものを通常閾値では除外し、24h(既定)の
# 安全網のみで発火させる。usage_resume（無引数呼び出し）には一切影響
# させない（TC-BATON-REG-001が守る）。
#   TC-BATON-AW-001: 印付きcmdが1件だけ開いている → 通常閾値では発報せぬ
#   TC-BATON-AW-002: 同上＋印なしcmdが1件ある → 発報する（除外は引き算であって停止ではない）
#   TC-BATON-AW-003: 印付き1件のみが安全網閾値を超えて滞留 → 発火し文面にhuman-held相当とcmd_idを含む
#                    （cmd_197/OBS-61-1是正: awaiting_sinceタイムスタンプから滞留時間を導く）
#   TC-BATON-AW-004: 印の値がlord以外（例: yes・空文字） → 除外せぬ（allowlist方向の確認）
#   TC-BATON-AW-005: awaitingフィールドが無い既存形 → 従来どおり数える
#   TC-BATON-AW-006: 毎サイクルのログ行にopen_cmds_machine/awaiting_lordが現れる
#   TC-BATON-AW-007（cmd_197/OBS-61-1是正の核心）: プロセスローカルの計時起点を
#                    明示的にリセットしても、awaiting_sinceが古ければ安全網が発火する
#                    （＝番犬プロセスの入れ替えをまたいでも滞留の記憶は失われない）
#   TC-BATON-AW-008: awaiting_sinceを持たぬ旧形式の印は、検知した瞬間から
#                    計時を開始する(その旨をログに残す)。黙って安全網が
#                    無効になるのを避けるための後方互換フォールバック
#   TC-BATON-AW-009（cmd_197/QC62-F1是正）: 引用符無しawaiting_since（YAMLが
#                    datetime型として解釈する値）でもparse_tsが解析でき、
#                    OBS-61-1と同じフォールバックへ黙って落ちない
#   TC-BATON-REG-001: usage_resumeが使う無引数呼び出しの戻り値が従来と一致する（将軍指定・最重要）
#
# 【cmd_208: baton_lost主経路の宛先二重化・人待ち安全網の閾値是正・再武装】
# (gunshi_design_208.yaml)
#   TC-208-V1: 通常経路がkaro・shogunの両方へ1件ずつ書く（措置A）
#   TC-208-V2a/V2b: repeat閾値未満では再通知せず、超えたら再通知する（措置C）
#   TC-208-V2c: 条件が偽になったら次回は新たな継続として計り直す（既存意味論の回帰固定）
#   TC-208-V3【必須・回帰固定】: 番犬自身がkaro宛に書いた警報はunreadに数えない
#   TC-208-V4: 印付きcmdが(新既定)3600秒超でhuman-held警報がkaroにも届く（措置B）
#   TC-208-V4b: 旧既定(86400s)を明示指定すれば4000s経過では発火しない（既定値是正の直接確認）
#
# 【cmd_208後続: awaiting:external・gunshi_design_208_awaiting_external.yaml】
# 除外(案A)ではなく「発報すると決めた後」の文面・間隔の差し替え(案B)。
# open_cmds_machineの条件判定には一切触れない。
#   W-1【最重要・回帰固定】: 外部印があってもopen_cmds_machineが減らずbaton_condition=trueになること
#   W-2: 外部印が揃えばexternal_wait:文面(target/checkを含む)、1件でも欠ければbaton_lost:のまま
#   W-3a/b: 外部待ちの再通知間隔(既定3600s)未満は再通知せず、超えたら再通知する
#   W-3c: awaiting_budget_sec超過で通常モードへ戻り、文面に予算超過が明記される
#   W-4: awaiting_target/awaiting_check/awaiting_sinceのいずれか欠落は印を無効にする(通常モードのまま)
#
# 【cmd_208後続 E-3: 静穏帯・gunshi_design_208_e3_quiet_hours.yaml】
# 主のご裁可「時間帯を限って鳴らす」。静穏帯は延期であって抑止ではない
# ——将軍inbox主経路は一切止めず、ntfy副経路のみ退避し明けに必ず一度出す。
#   Q-1: baton_ntfy_hm_in_window純関数の境界判定(0800/0900で8進罠を踏まぬこと含む)
#   Q-2: 静穏帯中はbranch_policy_notifyを呼ばず退避キューへ1行できる
#   Q-3: 連続呼び出しで行数が増えない(occurrencesが積算される)
#   Q-4: 明けたら将軍inboxへ1件・ntfyへ1回、両cmd_idと確認コマンドを含み、再送されない
#   Q-5: プロセス入替(シェル変数を引き継がぬ新プロセス)を跨いでも明けの1通が出る
#   Q-6: ntfyが死んでいても明けの1通(将軍inbox)は出る
#   Q-7【回帰固定・最重要】: 静穏帯の内外でcheck_onceの将軍inbox出力が完全一致する(主経路無影響)
#   Q-8: 静穏帯の幅が上限(既定720分)以上なら無効化され鳴る側へ倒れる

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

    # --- cmd_181: usage_limit フェイク（本物のAnthropic OAuth usage APIは
    # 一切叩かない。curl を PATH 先頭の偽物へ差し替える様式は
    # tests/unit/test_usage_limit.bats が確立した様式を踏襲する）。
    export USAGE_TEST_BIN="$TEST_TMPDIR/usage_bin"
    mkdir -p "$USAGE_TEST_BIN"
    export USAGE_TEST_CREDS="$TEST_TMPDIR/usage_credentials.json"
    cat > "$USAGE_TEST_CREDS" <<'EOF'
{"claudeAiOauth": {"accessToken": "dummy-token"}}
EOF
    export USAGE_RESPONSE_FILE="$TEST_TMPDIR/usage_response.json"
    # 既定: 両枠とも閾値未満・空のlimits[]（安全なベースライン）。
    cat > "$USAGE_RESPONSE_FILE" <<'EOF'
{"five_hour": {"utilization": 10, "resets_at": "2026-08-01T07:20:00+00:00"}, "seven_day": {"utilization": 10, "resets_at": "2026-08-05T07:00:00+00:00"}, "seven_day_sonnet": null, "seven_day_opus": null, "limits": []}
EOF
    cat > "$USAGE_TEST_BIN/curl" <<CURLSTUB
#!/usr/bin/env bash
cat "$USAGE_RESPONSE_FILE"
CURLSTUB
    chmod +x "$USAGE_TEST_BIN/curl"

    export TEST_HARNESS="$TEST_TMPDIR/test_harness.sh"
    cat > "$TEST_HARNESS" << HARNESS
#!/bin/bash
export BATON_WATCHDOG_ROOT="$FIXTURE_ROOT"
export STALL_POLICY_SETTINGS="$FIXTURE_ROOT/config/settings.yaml"
# cmd_187: allowlistの母集合を実リポジトリのconfig/settings.yamlから
# 独立させる（cli.agentsが未定義のフィクスチャなのでagent_registry_agents()
# は既定の10エージェント一覧 shogun/karo/ashigaru1-7/gunshi にフォール
# バックする。決定的・本番設定から隔離されたテストにするため）。
export AGENT_REGISTRY_SETTINGS="$FIXTURE_ROOT/config/settings.yaml"

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
# $9=baton_b4c_machine_exempt_agents（省略時はキー自体を書かず、コード側の既定["shogun"]に委ねる。
#    カンマ区切りで渡す。空文字列 "" を明示的に渡すと空リスト（除外なし）を書く——
#    「キー省略」と「意図的な空リスト」を区別するため、他の引数と違い
#    呼び出し側は明示的にこの区別を要求される。cmd_189）
# $10=baton_b4c_machine_stale_after_sec（省略時はキー自体を書かず、コード側の既定86400に委ねる。cmd_189）
# $11=baton_lost_human_held_after_sec（省略時はキー自体を書かず、コード側の既定86400に委ねる。cmd_197）
write_settings() {
    local ntfy_line="" d1_ntfy_line="" progress_stall_line="" b4b_ntfy_line="" b4c_stale_line=""
    local machine_exempt_block="" machine_stale_line="" human_held_line=""
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
    if [ "${9+set}" = "set" ]; then
        if [ -z "$9" ]; then
            machine_exempt_block="  baton_b4c_machine_exempt_agents: []"
        else
            machine_exempt_block="  baton_b4c_machine_exempt_agents:"
            local a
            IFS=',' read -ra __agents <<< "$9"
            for a in "${__agents[@]}"; do
                machine_exempt_block="$machine_exempt_block
    - $a"
            done
        fi
    fi
    if [ -n "${10:-}" ]; then
        machine_stale_line="  baton_b4c_machine_stale_after_sec: ${10}"
    fi
    if [ -n "${11:-}" ]; then
        human_held_line="  baton_lost_human_held_after_sec: ${11}"
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
$machine_exempt_block
$machine_stale_line
$human_held_line
YAML
}

# cmd_181: usage API のフェイク応答を書き直す。
# $1=5H_UTIL $2=5H_RESETS_AT(ISO8601) $3=7D_UTIL $4=7D_RESETS_AT(ISO8601)
write_usage_response() {
    cat > "$USAGE_RESPONSE_FILE" <<EOF
{"five_hour": {"utilization": $1, "resets_at": "$2"}, "seven_day": {"utilization": $3, "resets_at": "$4"}, "seven_day_sonnet": null, "seven_day_opus": null, "limits": []}
EOF
}

write_usage_response_broken() {
    cat > "$USAGE_RESPONSE_FILE" <<'EOF'
not json
EOF
}

# cmd_208後続(E-3静穏帯)専用の設定追記ヘルパー。write_settingsの直後に
# 呼ぶこと（同一のbaton_watchdog:マッピングへキーを追記する。YAMLは
# 同一トップレベルキー配下ならブロック途中の追記を許す）。
# $1=quiet_enabled(true/false) $2=quiet_start(HH:MM) $3=quiet_end(HH:MM)
# $4=quiet_max_span_min(省略時はコード側の既定720に委ねる)
# $5=deferred_max_entries(省略時はコード側の既定20に委ねる)
write_quiet_settings() {
    {
        echo "  baton_ntfy_quiet_enabled: $1"
        echo "  baton_ntfy_quiet_start: \"$2\""
        echo "  baton_ntfy_quiet_end: \"$3\""
        if [ -n "${4:-}" ]; then
            echo "  baton_ntfy_quiet_max_span_min: $4"
        fi
        if [ -n "${5:-}" ]; then
            echo "  baton_ntfy_deferred_max_entries: $5"
        fi
    } >> "$FIXTURE_ROOT/config/settings.yaml"
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

# ═══════════════════════════════════════════════════════════════
# cmd_197: 「人待ち」の印（awaiting: lord）
# ═══════════════════════════════════════════════════════════════

# --- TC-BATON-AW-001: 印付きcmdが1件だけ開いている → 通常閾値では発報せぬ ---

@test "TC-BATON-AW-001: no normal-path notification when the only open cmd is marked awaiting:lord" {
    write_settings true 5 60
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_192
    status: in_progress
    awaiting: lord
YAML

    run bash -c "
        source '$TEST_HARNESS'
        BATON_LOST_SINCE=\$(( \$(date +%s) - 10 ))  # threshold=5s, already 10s elapsed
        check_once
    "
    [ "$status" -eq 0 ]
    ! grep -q "baton_lost:" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- TC-BATON-AW-002: 印付き＋印なしcmdが1件ずつ → 発報する（除外は引き算であって停止ではない）---

@test "TC-BATON-AW-002: normal-path notification still fires when an unmarked open cmd coexists, with exclusion breakdown in the message" {
    write_settings true 5 60
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_192
    status: in_progress
    awaiting: lord
  - id: cmd_200
    status: in_progress
YAML

    run bash -c "
        source '$TEST_HARNESS'
        BATON_LOST_SINCE=\$(( \$(date +%s) - 10 ))
        check_once
    "
    [ "$status" -eq 0 ]
    grep -q "INBOX_WRITE: shogun" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    grep -q "baton_lost: unread=0 active=0 open_cmds=1" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    grep -q "人待ち除外 1件: cmd_192" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- TC-BATON-AW-003: 印付き1件のみが安全網閾値を超えて滞留 → 発火しhuman-held相当の文言を含む ---

@test "TC-BATON-AW-003: the 24h safety net fires for a lone awaiting-marked cmd based on its own awaiting_since timestamp, not the watchdog process's uptime" {
    write_settings true 5 60
    local since
    since="$(date -d @$(( $(date +%s) - 90000 )) '+%Y-%m-%dT%H:%M:%S')"  # default threshold=86400s, 90000s elapsed
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << YAML
commands:
  - id: cmd_192
    status: in_progress
    awaiting: lord
    awaiting_since: "$since"
YAML

    run bash -c "
        source '$TEST_HARNESS'
        # cmd_197/OBS-61-1是正: プロセスがこの瞬間にソースされたばかりで
        # BATON_HELD_SINCEが既定値0のままでも(=プロセスローカルの計時には
        # 一切触れない)、awaiting_sinceが古ければ発火することを確かめる。
        check_once
    "
    [ "$status" -eq 0 ]
    grep -q "baton_lost(human-held)" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    grep -q "cmd_192" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    # 通常経路は依然として沈黙している（機械側の除外が効いたまま）
    ! grep -q "^INBOX_WRITE: shogun baton_lost: " "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- TC-BATON-AW-007: 是正の核心——プロセス再起動をまたいでも滞留時間が失われない ---

@test "TC-BATON-AW-007: the safety net survives a watchdog process restart (an explicitly reset process-local timer is ignored when awaiting_since is present)" {
    write_settings true 5 60
    local since
    since="$(date -d @$(( $(date +%s) - 90000 )) '+%Y-%m-%dT%H:%M:%S')"
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << YAML
commands:
  - id: cmd_192
    status: in_progress
    awaiting: lord
    awaiting_since: "$since"
YAML

    run bash -c "
        source '$TEST_HARNESS'
        # 番犬プロセスがこの直前に入れ替わったばかりであることを明示的に
        # 模す(プロセスローカルの滞留起点=1秒前)。是正前のコードはこの
        # 値で計時するため発火せぬはずだが、印付きcmdがある場合は
        # awaiting_sinceから導くためBATON_HELD_SINCEの値とは無関係に
        # 発火することを確かめる(OBS-61-1・cmd_197是正の核心)。
        BATON_HELD_SINCE=\$(( \$(date +%s) - 1 ))
        check_once
    "
    [ "$status" -eq 0 ]
    grep -q "baton_lost(human-held)" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    grep -q "cmd_192" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- TC-BATON-AW-008: awaiting_sinceを持たぬ旧形式の印は検知時点から計時開始する ---

@test "TC-BATON-AW-008: a legacy awaiting:lord marker without awaiting_since starts the safety-net timer at first detection, logs it, and later fires" {
    write_settings true 5 60 "" "" "" "" "" shogun 86400 2   # baton_lost_human_held_after_sec=2s
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_192
    status: in_progress
    awaiting: lord
YAML

    run bash -c "
        source '$TEST_HARNESS'
        check_once
        if [ \"\$BATON_HELD_NOTIFIED\" -ne 0 ]; then
            echo 'unexpectedly notified on first detection'
            exit 1
        fi
        sleep 3
        check_once
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "awaiting_since無し(旧形式の印)。安全網の計時をこの検知時点から開始する" || { echo "$output"; false; }
    grep -q "baton_lost(human-held)" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    grep -q "cmd_192" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- TC-BATON-AW-009: 引用符無しawaiting_since（YAMLがdatetime型として解釈する値）
#     でもparse_tsが正しく解析し、安全網が発火する（cmd_197/QC62-F1是正） ---

@test "TC-BATON-AW-009: an unquoted awaiting_since (parsed by YAML as a native datetime, not str) still fires the safety net based on its own timestamp" {
    write_settings true 5 60
    local since
    since="$(date -d @$(( $(date +%s) - 90000 )) '+%Y-%m-%dT%H:%M:%S')"  # default threshold=86400s, 90000s elapsed
    # 【QC62-F1の核心】ここではあえて引用符を付けない。PyYAMLはISO8601風の
    # 引用符無し値をstrではなくdatetime型として自動解釈する。是正前の
    # parse_tsはisinstance(value, str)を先頭で要求するためdatetime型は
    # Noneに落ち、OBS-61-1と同じ「awaiting_since無し」フォールバック扱い
    # になっていた（=このテストは是正前は最初のcheck_once一回では発火せず
    # 失敗した。是正後は文字列経由と同じくその場でawaiting_sinceから直接
    # 発火する）。
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << YAML
commands:
  - id: cmd_192
    status: in_progress
    awaiting: lord
    awaiting_since: $since
YAML

    run bash -c "
        source '$TEST_HARNESS'
        check_once
    "
    [ "$status" -eq 0 ]
    grep -q "baton_lost(human-held)" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    grep -q "cmd_192" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    # 旧形式フォールバック(=is-a-bug症状)のログ行が出ていないことも確かめる
    ! echo "$output" | grep -q "awaiting_since無し(旧形式の印)" || { echo "$output"; false; }
}

# --- TC-BATON-AW-004: 印の値がlord以外なら除外せぬ（allowlist方向の確認）---

@test "TC-BATON-AW-004: a non-'lord' awaiting value (or empty string) does not exclude the cmd" {
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: in_progress
    awaiting: "yes"
  - id: cmd_2
    status: in_progress
    awaiting: ""
YAML

    run bash -c "
        source '$TEST_HARNESS'
        baton_watchdog_count_open_cmds exclude_awaiting
    "
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

# --- TC-BATON-AW-005: awaitingフィールドが無い既存形は従来どおり数える ---

@test "TC-BATON-AW-005: cmds without an awaiting field are counted the same with or without exclusion" {
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: in_progress
  - id: cmd_2
    status: assigned
YAML

    run bash -c "
        source '$TEST_HARNESS'
        baton_watchdog_count_open_cmds
    "
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]

    run bash -c "
        source '$TEST_HARNESS'
        baton_watchdog_count_open_cmds exclude_awaiting
    "
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

# --- TC-BATON-AW-006: 毎サイクルのログ行にopen_cmds_machine/awaiting_lordが現れる ---

@test "TC-BATON-AW-006: the per-cycle status line exposes open_cmds_machine and awaiting_lord with the excluded cmd id" {
    write_settings true 5 60
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_192
    status: in_progress
    awaiting: lord
  - id: cmd_200
    status: in_progress
YAML

    run bash -c "
        source '$TEST_HARNESS'
        check_once
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "open_cmds=2 open_cmds_machine=1 awaiting_lord=1(cmd_192)" || { echo "$output"; false; }
}

# --- TC-BATON-REG-001: 将軍指定・最重要。usage_resumeが使う無引数呼び出しの戻り値が従来と一致する ---

@test "TC-BATON-REG-001: the no-arg call used by usage_resume still counts awaiting-marked cmds (regression guard)" {
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_192
    status: in_progress
    awaiting: lord
  - id: cmd_200
    status: in_progress
YAML

    run bash -c "
        source '$TEST_HARNESS'
        baton_watchdog_count_open_cmds
    "
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
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
    # from: baton_watchdog（本番同等・機械の書き手の例。QC45-F1是正:
    # list_stale_inbox_agentsの検知経路であるD-1はfromを問わず発火せねば
    # ならぬことを、本番と同型のfixtureで確かめる）。
    cat > "$FIXTURE_ROOT/queue/inbox/karo.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    from: baton_watchdog
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
    # from: watcher_supervisor（本番同等・機械の書き手の例）
    cat > "$FIXTURE_ROOT/queue/inbox/karo.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    from: watcher_supervisor
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
    # from: ashigaru2（本番同等・エージェントの書き手の例）
    cat > "$FIXTURE_ROOT/queue/inbox/karo.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    from: ashigaru2
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
    # from: baton_watchdog（本番同等・機械の書き手の例。将軍inboxへの
    # auto-recovery通知等はまさにこの経路で書かれる）。
    cat > "$FIXTURE_ROOT/queue/inbox/shogun.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    from: baton_watchdog
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
    # shogun側はfrom: watcher_supervisor（機械）、ashigaru3側はfrom: gunshi
    # （エージェント）——本番同等のfromを両様含める。
    cat > "$FIXTURE_ROOT/queue/inbox/shogun.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    from: watcher_supervisor
    timestamp: '${stale_ts}'
YAML
    cat > "$FIXTURE_ROOT/queue/inbox/ashigaru3.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    from: gunshi
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

# --- TC-SELF-005b/c: 副経路ntfyの成否がbaton_watchdog自身のログにも残る (cmd_171) ---

@test "TC-SELF-005b: a successful secondary ntfy notify leaves a one-line success log entry" {
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
    echo "$output" | grep -q "ntfy notify sent (branch_policy_notify succeeded)" || { echo "$output"; false; }
}

@test "TC-SELF-005c: a failed secondary ntfy notify still leaves only the failure log entry, not a success one" {
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
        branch_policy_notify() { return 1; }
        BATON_LOST_SINCE=\$(( \$(date +%s) - 10 ))
        check_once
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "ntfy notify failed" || { echo "$output"; false; }
    echo "$output" | grep -q "ntfy notify sent" && { echo "$output"; false; }
    true
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
    # from: baton_watchdog（本番同等・機械の書き手の例）
    cat > "$FIXTURE_ROOT/queue/inbox/karo.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    from: baton_watchdog
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
    # from: watcher_supervisor（本番同等・機械の書き手の例）
    cat > "$FIXTURE_ROOT/queue/inbox/karo.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    from: watcher_supervisor
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
    # from: ashigaru5（本番同等・エージェントの書き手の例）
    cat > "$FIXTURE_ROOT/queue/inbox/karo.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    from: ashigaru5
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
    # from: karo（cmd_189是正後・エージェント由来に差し替え）。
    # 既定 baton_b4c_machine_exempt_agents=["shogun"] により、shogun宛の
    # 機械由来(from: baton_watchdog等)の未読は通常閾値(5400s)では数えず
    # 24時間安全網のみで発火するようになった（TC-B4C-EXEMPT-001参照）。
    # 本テストの主張（自己給餌ラッチ防止）は送信者に依存しないため、
    # エージェント由来にしても主張は保たれる。
    cat > "$FIXTURE_ROOT/queue/inbox/shogun.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    from: karo
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
    # from: karo（cmd_189是正後・エージェント由来に差し替え）。理由は
    # TC-B4C-LATCH-001と同じ（既定の機械由来除外により、機械由来のままでは
    # 24時間安全網に達するまで本設計後は発火せず本テストが落ちるため）。
    cat > "$FIXTURE_ROOT/queue/inbox/shogun.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    from: karo
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
    # from: inbox_watcher（本番同等・機械の書き手の例）
    cat > "$FIXTURE_ROOT/queue/inbox/karo.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    from: inbox_watcher
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

# ═══════════════════════════════════════════════════════════════
# cmd_189: B-4c限定・対象名指しによる機械由来除外（軍師design_189・採用Option 2+3）
#
# list_stale_inbox_agents に省略可能な第2・第3引数を追加し、呼び出し側
# （check_b4c_once）のみが将軍(shogun)を名指しして、機械由来
# （agent_registry_agentsに非該当のfrom）の未読を通常閾値では数えず、
# 24時間(baton_b4c_machine_stale_after_sec)の安全網のみで発火させる。
# check_d1_once は無引数呼び出しのまま一文字も変えていない
# （非退行はTC-D1-EXEMPT-001・既存TC-D1-LATCH-001/002が担保）。
#
#   TC-B4C-EXEMPT-001: shogun・機械由来・6000s stale → 発火せぬ（本cmdの核）
#   TC-B4C-EXEMPT-002: shogun・エージェント由来(karo)・6000s stale
#                      → 従来どおり発火（丸ごと除外との違いを固定）
#   TC-B4C-EXEMPT-003: 非exempt(ashigaru3)・機械由来・stale → 従来どおり発火
#   TC-B4C-EXEMPT-004: shogun・from欠落・stale → 発火（安全側。countと同じ向き）
#   TC-B4C-EXEMPT-005: baton_b4c_machine_exempt_agents: [] → shogunでも
#                      機械由来で発火（巻き戻し弁）
#   TC-B4C-EXEMPT-006: 安全網の境界（86400s+で発火・86400s未満で発火せぬ）
#   TC-B4C-EXEMPT-007: 機械由来stale＋エージェント由来freshが同居 → 発火せぬ
#   TC-D1-EXEMPT-001【非退行の明示的な番人】: D-1はwatcher死亡時、shogunの
#                    機械由来staleでも従来どおり発火する（除外が漏れていない）
# ═══════════════════════════════════════════════════════════════

# --- TC-B4C-EXEMPT-001: shogunの機械由来staleは24h安全網に達するまで発火せぬ ---

@test "TC-B4C-EXEMPT-001: machine-origin stale shogun inbox stays silent under the 24h safety net" {
    write_settings true 5 60 "" "" "" "" 5400 shogun 86400
    local stale_ts
    stale_ts=$(date -d "@$(( $(date +%s) - 6000 ))" +"%Y-%m-%dT%H:%M:%S")
    cat > "$FIXTURE_ROOT/queue/inbox/shogun.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    from: baton_watchdog
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
    [ ! -s "$SHOGUN_NOTIFY_LOG" ] || { cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- TC-B4C-EXEMPT-002: shogunでもエージェント由来なら従来どおり通常閾値で発火 ---

@test "TC-B4C-EXEMPT-002: agent-origin stale shogun inbox still fires at the normal threshold" {
    write_settings true 5 60 "" "" "" "" 5400 shogun 86400
    local stale_ts
    stale_ts=$(date -d "@$(( $(date +%s) - 6000 ))" +"%Y-%m-%dT%H:%M:%S")
    cat > "$FIXTURE_ROOT/queue/inbox/shogun.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    from: karo
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
    grep -q "INBOX_WRITE: karo" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    grep -q "inbox_stall: agent=shogun" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- TC-B4C-EXEMPT-003: 対象を名指ししていないagentは機械由来でも従来どおり発火 ---

@test "TC-B4C-EXEMPT-003: machine-origin stale inbox for a non-exempt agent still fires normally" {
    write_settings true 5 60 "" "" "" "" 5400 shogun 86400
    local stale_ts
    stale_ts=$(date -d "@$(( $(date +%s) - 6000 ))" +"%Y-%m-%dT%H:%M:%S")
    cat > "$FIXTURE_ROOT/queue/inbox/ashigaru3.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    from: baton_watchdog
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
    grep -q "inbox_stall: agent=ashigaru3" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- TC-B4C-EXEMPT-004: fromが欠落したshogun宛staleは安全側(通常閾値)で発火 ---

@test "TC-B4C-EXEMPT-004: shogun inbox message with missing 'from' is treated as non-machine (safe side) and fires normally" {
    write_settings true 5 60 "" "" "" "" 5400 shogun 86400
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
    "
    [ "$status" -eq 0 ]
    grep -q "inbox_stall: agent=shogun" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- TC-B4C-EXEMPT-005【change_3で名指しした罠を直接押さえる】空リストは巻き戻し弁 ---

@test "TC-B4C-EXEMPT-005: empty machine_exempt_agents list restores pre-cmd_189 semantics (rollback valve works)" {
    write_settings true 5 60 "" "" "" "" 5400 "" 86400
    local stale_ts
    stale_ts=$(date -d "@$(( $(date +%s) - 6000 ))" +"%Y-%m-%dT%H:%M:%S")
    cat > "$FIXTURE_ROOT/queue/inbox/shogun.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    from: baton_watchdog
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
    grep -q "inbox_stall: agent=shogun" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- TC-B4C-EXEMPT-006: 安全網(24h)の境界 ---

@test "TC-B4C-EXEMPT-006: 24h safety net boundary — fires past 86400s, stays silent just under it" {
    write_settings true 5 60 "" "" "" "" 5400 shogun 86400

    local over_ts
    over_ts=$(date -d "@$(( $(date +%s) - 90000 ))" +"%Y-%m-%dT%H:%M:%S")
    cat > "$FIXTURE_ROOT/queue/inbox/shogun.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    from: baton_watchdog
    timestamp: '${over_ts}'
YAML
    run bash -c "
        source '$TEST_HARNESS'
        pgrep() { echo \"MOCKPGREP \$*\" >> '$PGREP_LOG'; return 0; }
        export -f pgrep
        baton_watchdog_refresh_watcher_snapshot
        check_b4c_once
    "
    [ "$status" -eq 0 ]
    grep -q "inbox_stall: agent=shogun" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }

    > "$SHOGUN_NOTIFY_LOG"
    local under_ts
    under_ts=$(date -d "@$(( $(date +%s) - 80000 ))" +"%Y-%m-%dT%H:%M:%S")
    cat > "$FIXTURE_ROOT/queue/inbox/shogun.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    from: baton_watchdog
    timestamp: '${under_ts}'
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

# --- TC-B4C-EXEMPT-007: 機械由来staleとエージェント由来freshの同居で境界混同しない ---

@test "TC-B4C-EXEMPT-007: a stale machine-origin message alongside a fresh agent-origin message in shogun's inbox does not fire" {
    write_settings true 5 60 "" "" "" "" 5400 shogun 86400
    local stale_ts fresh_ts
    stale_ts=$(date -d "@$(( $(date +%s) - 6000 ))" +"%Y-%m-%dT%H:%M:%S")
    fresh_ts=$(date -d "@$(( $(date +%s) - 10 ))" +"%Y-%m-%dT%H:%M:%S")
    cat > "$FIXTURE_ROOT/queue/inbox/shogun.yaml" << YAML
messages:
  - id: msg_machine_stale
    read: false
    from: baton_watchdog
    timestamp: '${stale_ts}'
  - id: msg_agent_fresh
    read: false
    from: karo
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

# --- TC-D1-EXEMPT-001【非退行の明示的な番人】D-1はwatcher死亡時、shogunの機械由来staleでも従来どおり発火する ---

@test "TC-D1-EXEMPT-001: D-1 still fires for machine-origin shogun stale messages when the watcher is dead (exemption must not leak into D-1)" {
    write_settings true 5 60 "" "" "" "" 5400 shogun 86400
    local stale_ts before_count after_count
    stale_ts=$(date -d "@$(( $(date +%s) - 700 ))" +"%Y-%m-%dT%H:%M:%S")
    cat > "$FIXTURE_ROOT/queue/inbox/shogun.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    from: baton_watchdog
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


# ═══════════════════════════════════════════════════════════════
# cmd_181: 使用量制限 事前予告(a)・猶予(b)・事後自動再開(c)
#
# check_once/check_d1_once/check_b4b_once/check_b4c_once とは完全に
# 独立した機能。前提誤り2件（実装前に是正済み）:
#   1. resets_at のUTC切り詰め: lib/usage_limit.sh が新たに出力する
#      5H_RESET_EPOCH/7D_RESET_EPOCH（既にepoch化済み）のみを用いる。
#   2. 再開の関門は usage_limit_state ではなく、reset epoch そのものの
#      巻き直り（「制限が近いか」ではなく「枠が実際に終わったか」）。
#
# TC-USAGE-WARN-001〜004: 三方への予告・重複防止・枠変化での再発火・
#                         7日枠は家老へ出ない
# TC-USAGE-TZ-001〜003:   UTC変換の固定・不正値での空文字フォールバック・
#                         offset無しnaive文字列での空文字フォールバック
#                         （TZ-003=OBS-181-9回帰）
# TC-USAGE-RESUME-001〜005: 正常再開・空振り防止各パターン・同一枠での重複防止
# TC-USAGE-FETCH-001:     API取得失敗時は何もしない
# TC-USAGE-TMUX-001:      tmux不使用
# TC-USAGE-FROM-001:      from=baton_watchdog固定（cmd_180結線）
# TC-USAGE-ISOLATION-001: 他4関数の状態に影響しない
#
# 【cmd_183・軍師QC(gunshi_qc_181_pr41.yaml)発見の追随修正4件】
#   TC-USAGE-RESUME-006:     OBS-181-6回帰。予告がkaro自身のinboxを実際に
#                            書き換えても（実物のscripts/inbox_write.sh経由）、
#                            それを「karoの進捗」と誤認して再開が空振りに
#                            消えないこと（自己給餌防止。cmd_180 OBS-180-1
#                            と同型の欠陥、本システムで3度目）
#   TC-USAGE-RESUME-FLAG-001: finding_3回帰。LIMITS_FLAGGEDがtrue→falseへ
#                            遷移すれば、reset epochが不変（契約変更等・
#                            枠の巻き直りを伴わない解除）でも再開が発火する
#   TC-USAGE-RESUME-7D-001:  OBS-181-7回帰。7日枠の巻き直りによる再開号令も
#                            5時間枠と同様に家老へ届く（従来コメントの
#                            「5時間枠のみ」という記述は誤りだった）
# ═══════════════════════════════════════════════════════════════

# --- TC-USAGE-WARN-001: 三方（将軍inbox・家老inbox・ntfy）への予告 ---

@test "TC-USAGE-WARN-001: usage_warn fires to shogun inbox, karo inbox, and ntfy when 5H_UTIL crosses usage_warn_pct" {
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: in_progress
YAML
    write_usage_response 85 "2026-08-01T07:20:00+00:00" 10 "2026-08-05T07:00:00+00:00"

    run env USAGE_LIMIT_CREDS="$USAGE_TEST_CREDS" PATH="$USAGE_TEST_BIN:$PATH" bash -c "
        source '$TEST_HARNESS'
        USAGE_LAST_CHECK_AT=0
        check_usage_once
    "
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -q "INBOX_WRITE: shogun.*usage_warn.*window=5h" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    grep -q "INBOX_WRITE: karo.*window=5h" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    grep -q "usage_warn.*window=5h" "$NOTIFY_LOG" || { cat "$NOTIFY_LOG"; false; }
}

# --- TC-USAGE-WARN-002: 同一枠では二度目以降は発火せぬ ---

@test "TC-USAGE-WARN-002: no duplicate usage_warn for the same reset window even across 3 cycles" {
    write_usage_response 85 "2026-08-01T07:20:00+00:00" 10 "2026-08-05T07:00:00+00:00"

    run env USAGE_LIMIT_CREDS="$USAGE_TEST_CREDS" PATH="$USAGE_TEST_BIN:$PATH" bash -c "
        source '$TEST_HARNESS'
        USAGE_LAST_CHECK_AT=0; check_usage_once
        USAGE_LAST_CHECK_AT=0; check_usage_once
        USAGE_LAST_CHECK_AT=0; check_usage_once
    "
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    count=$(grep -c "INBOX_WRITE: shogun.*window=5h" "$SHOGUN_NOTIFY_LOG")
    [ "$count" -eq 1 ] || { echo "expected 1 window=5h notification, got $count:"; cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- TC-USAGE-WARN-003: reset epochが変われば明示リセット無しで再発火する ---

@test "TC-USAGE-WARN-003: a changed reset epoch re-fires the warning without an explicit reset (OBS-180-1 regression)" {
    local json1 json2
    json1='{"five_hour": {"utilization": 85, "resets_at": "2026-08-01T07:20:00+00:00"}, "seven_day": {"utilization": 10, "resets_at": "2026-08-05T07:00:00+00:00"}, "seven_day_sonnet": null, "seven_day_opus": null, "limits": []}'
    json2='{"five_hour": {"utilization": 86, "resets_at": "2026-08-01T16:20:00+00:00"}, "seven_day": {"utilization": 10, "resets_at": "2026-08-05T07:00:00+00:00"}, "seven_day_sonnet": null, "seven_day_opus": null, "limits": []}'

    run env USAGE_LIMIT_CREDS="$USAGE_TEST_CREDS" PATH="$USAGE_TEST_BIN:$PATH" \
        USAGE_JSON_1="$json1" USAGE_JSON_2="$json2" bash -c "
        source '$TEST_HARNESS'
        printf '%s' \"\$USAGE_JSON_1\" > '$USAGE_RESPONSE_FILE'
        USAGE_LAST_CHECK_AT=0; check_usage_once
        printf '%s' \"\$USAGE_JSON_2\" > '$USAGE_RESPONSE_FILE'
        USAGE_LAST_CHECK_AT=0; check_usage_once
    "
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    count=$(grep -c "INBOX_WRITE: shogun.*window=5h" "$SHOGUN_NOTIFY_LOG")
    [ "$count" -eq 2 ] || { echo "expected 2 window=5h notifications (new epoch = new window), got $count:"; cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- TC-USAGE-WARN-004: 7日枠の予告は将軍inbox+ntfyのみ・家老inboxには出ぬ ---

@test "TC-USAGE-WARN-004: 7-day window warning reaches shogun inbox and ntfy but never karo inbox" {
    write_usage_response 10 "2026-08-01T07:20:00+00:00" 90 "2026-08-05T07:00:00+00:00"

    run env USAGE_LIMIT_CREDS="$USAGE_TEST_CREDS" PATH="$USAGE_TEST_BIN:$PATH" bash -c "
        source '$TEST_HARNESS'
        USAGE_LAST_CHECK_AT=0
        check_usage_once
    "
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -q "INBOX_WRITE: shogun.*window=7d" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    grep -q "window=7d" "$NOTIFY_LOG" || { cat "$NOTIFY_LOG"; false; }
    ! grep -q "INBOX_WRITE: karo.*window=7d" "$SHOGUN_NOTIFY_LOG" || { echo "karo must never receive the 7d warning:"; cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- TC-USAGE-TZ-001: '+00:00'付きUTC resets_atが正しいepochになる ---

@test "TC-USAGE-TZ-001: resets_at with an explicit +00:00 UTC offset produces the correct epoch (9h JST landmine fixed)" {
    write_usage_response 84 "2026-07-31T23:10:00.894023+00:00" 85 "2026-08-05T07:00:00.894046+00:00"
    local expected
    expected=$(date -u -d "2026-07-31T23:10:00" +%s)

    run env USAGE_LIMIT_CREDS="$USAGE_TEST_CREDS" PATH="$USAGE_TEST_BIN:$PATH" \
        bash -c "source '$PROJECT_ROOT/lib/usage_limit.sh'; usage_limit_fetch_raw"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *"5H_RESET_EPOCH=${expected}"* ]] || { echo "expected 5H_RESET_EPOCH=${expected} in:"; echo "$output"; false; }
}

# --- TC-USAGE-TZ-002: resets_atが不正・欠落ならEPOCHは空文字、check_usage_onceは何も出さぬ ---

@test "TC-USAGE-TZ-002: an invalid/missing resets_at yields an empty EPOCH and check_usage_once takes no action" {
    write_usage_response 90 "" 90 ""

    run env USAGE_LIMIT_CREDS="$USAGE_TEST_CREDS" PATH="$USAGE_TEST_BIN:$PATH" \
        bash -c "source '$PROJECT_ROOT/lib/usage_limit.sh'; usage_limit_fetch_raw"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *$'5H_RESET_EPOCH=\n'* ]] || { echo "expected empty 5H_RESET_EPOCH in:"; echo "$output"; false; }

    run env USAGE_LIMIT_CREDS="$USAGE_TEST_CREDS" PATH="$USAGE_TEST_BIN:$PATH" bash -c "
        source '$TEST_HARNESS'
        USAGE_LAST_CHECK_AT=0
        check_usage_once
    "
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ ! -s "$SHOGUN_NOTIFY_LOG" ] || { echo "must not notify when reset epoch is unavailable, despite util>=warn_pct:"; cat "$SHOGUN_NOTIFY_LOG"; false; }
    [ ! -s "$NOTIFY_LOG" ]
}

# --- TC-USAGE-RESUME-001: 正常再開（4条件AND成立） ---

@test "TC-USAGE-RESUME-001: karo inbox receives a resume order once the warned window rolls over with all 4 AND conditions met" {
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: in_progress
YAML
    sleep 1  # progress artifact mtimes (set up in setup()) must predate USAGE_WARNED_AT

    local json1 json2
    json1='{"five_hour": {"utilization": 90, "resets_at": "2026-08-01T07:20:00+00:00"}, "seven_day": {"utilization": 10, "resets_at": "2026-08-05T07:00:00+00:00"}, "seven_day_sonnet": null, "seven_day_opus": null, "limits": []}'
    json2='{"five_hour": {"utilization": 20, "resets_at": "2026-08-01T16:20:00+00:00"}, "seven_day": {"utilization": 10, "resets_at": "2026-08-05T07:00:00+00:00"}, "seven_day_sonnet": null, "seven_day_opus": null, "limits": []}'

    run env USAGE_LIMIT_CREDS="$USAGE_TEST_CREDS" PATH="$USAGE_TEST_BIN:$PATH" \
        USAGE_JSON_1="$json1" USAGE_JSON_2="$json2" bash -c "
        source '$TEST_HARNESS'
        printf '%s' \"\$USAGE_JSON_1\" > '$USAGE_RESPONSE_FILE'
        USAGE_LAST_CHECK_AT=0; check_usage_once
        printf '%s' \"\$USAGE_JSON_2\" > '$USAGE_RESPONSE_FILE'
        USAGE_LAST_CHECK_AT=0; check_usage_once
    "
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -q "INBOX_WRITE: karo.*usage_resume.*window=5h" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    grep -q "usage_resume.*window=5h" "$NOTIFY_LOG" || { cat "$NOTIFY_LOG"; false; }
}

# --- TC-USAGE-RESUME-002: 予告以降に誰かが動いていれば空振り防止で再開号令は出ぬ ---

@test "TC-USAGE-RESUME-002: no resume order when any agent's files were touched after the warning (false-alarm prevention)" {
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: in_progress
YAML
    sleep 1

    local json1 json2
    json1='{"five_hour": {"utilization": 90, "resets_at": "2026-08-01T07:20:00+00:00"}, "seven_day": {"utilization": 10, "resets_at": "2026-08-05T07:00:00+00:00"}, "seven_day_sonnet": null, "seven_day_opus": null, "limits": []}'
    json2='{"five_hour": {"utilization": 20, "resets_at": "2026-08-01T16:20:00+00:00"}, "seven_day": {"utilization": 10, "resets_at": "2026-08-05T07:00:00+00:00"}, "seven_day_sonnet": null, "seven_day_opus": null, "limits": []}'

    run env USAGE_LIMIT_CREDS="$USAGE_TEST_CREDS" PATH="$USAGE_TEST_BIN:$PATH" \
        USAGE_JSON_1="$json1" USAGE_JSON_2="$json2" bash -c "
        source '$TEST_HARNESS'
        printf '%s' \"\$USAGE_JSON_1\" > '$USAGE_RESPONSE_FILE'
        USAGE_LAST_CHECK_AT=0; check_usage_once
        sleep 1
        touch '$FIXTURE_ROOT/queue/tasks/ashigaru1.yaml'
        printf '%s' \"\$USAGE_JSON_2\" > '$USAGE_RESPONSE_FILE'
        USAGE_LAST_CHECK_AT=0; check_usage_once
    "
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    ! grep -q "usage_resume" "$SHOGUN_NOTIFY_LOG" || { echo "must not resume when someone kept working after the warning:"; cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- TC-USAGE-RESUME-003: 巻き直っても util が resume 閾値以上なら再開号令は出ぬ ---

@test "TC-USAGE-RESUME-003: no resume order when the new window's utilization is still at/above usage_resume_below_pct" {
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: in_progress
YAML
    sleep 1

    local json1 json2
    json1='{"five_hour": {"utilization": 90, "resets_at": "2026-08-01T07:20:00+00:00"}, "seven_day": {"utilization": 10, "resets_at": "2026-08-05T07:00:00+00:00"}, "seven_day_sonnet": null, "seven_day_opus": null, "limits": []}'
    json2='{"five_hour": {"utilization": 55, "resets_at": "2026-08-01T16:20:00+00:00"}, "seven_day": {"utilization": 10, "resets_at": "2026-08-05T07:00:00+00:00"}, "seven_day_sonnet": null, "seven_day_opus": null, "limits": []}'

    run env USAGE_LIMIT_CREDS="$USAGE_TEST_CREDS" PATH="$USAGE_TEST_BIN:$PATH" \
        USAGE_JSON_1="$json1" USAGE_JSON_2="$json2" bash -c "
        source '$TEST_HARNESS'
        printf '%s' \"\$USAGE_JSON_1\" > '$USAGE_RESPONSE_FILE'
        USAGE_LAST_CHECK_AT=0; check_usage_once
        printf '%s' \"\$USAGE_JSON_2\" > '$USAGE_RESPONSE_FILE'
        USAGE_LAST_CHECK_AT=0; check_usage_once
    "
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    ! grep -q "usage_resume" "$SHOGUN_NOTIFY_LOG" || { echo "must not resume while utilization (55%) is still >= usage_resume_below_pct (50%):"; cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- TC-USAGE-RESUME-004: open_cmds=0（仕事が無い）なら再開号令は出ぬ ---

@test "TC-USAGE-RESUME-004: no resume order when there is no open cmd to resume" {
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: done
YAML
    sleep 1

    local json1 json2
    json1='{"five_hour": {"utilization": 90, "resets_at": "2026-08-01T07:20:00+00:00"}, "seven_day": {"utilization": 10, "resets_at": "2026-08-05T07:00:00+00:00"}, "seven_day_sonnet": null, "seven_day_opus": null, "limits": []}'
    json2='{"five_hour": {"utilization": 20, "resets_at": "2026-08-01T16:20:00+00:00"}, "seven_day": {"utilization": 10, "resets_at": "2026-08-05T07:00:00+00:00"}, "seven_day_sonnet": null, "seven_day_opus": null, "limits": []}'

    run env USAGE_LIMIT_CREDS="$USAGE_TEST_CREDS" PATH="$USAGE_TEST_BIN:$PATH" \
        USAGE_JSON_1="$json1" USAGE_JSON_2="$json2" bash -c "
        source '$TEST_HARNESS'
        printf '%s' \"\$USAGE_JSON_1\" > '$USAGE_RESPONSE_FILE'
        USAGE_LAST_CHECK_AT=0; check_usage_once
        printf '%s' \"\$USAGE_JSON_2\" > '$USAGE_RESPONSE_FILE'
        USAGE_LAST_CHECK_AT=0; check_usage_once
    "
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    ! grep -q "usage_resume" "$SHOGUN_NOTIFY_LOG" || { echo "must not resume when open_cmds=0 (nothing to resume):"; cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- TC-USAGE-RESUME-005: 同一枠で再開号令は一度だけ ---

@test "TC-USAGE-RESUME-005: resume order fires at most once for the same rolled-over window across 3 cycles" {
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: in_progress
YAML
    sleep 1

    local json1 json2
    json1='{"five_hour": {"utilization": 90, "resets_at": "2026-08-01T07:20:00+00:00"}, "seven_day": {"utilization": 10, "resets_at": "2026-08-05T07:00:00+00:00"}, "seven_day_sonnet": null, "seven_day_opus": null, "limits": []}'
    json2='{"five_hour": {"utilization": 20, "resets_at": "2026-08-01T16:20:00+00:00"}, "seven_day": {"utilization": 10, "resets_at": "2026-08-05T07:00:00+00:00"}, "seven_day_sonnet": null, "seven_day_opus": null, "limits": []}'

    run env USAGE_LIMIT_CREDS="$USAGE_TEST_CREDS" PATH="$USAGE_TEST_BIN:$PATH" \
        USAGE_JSON_1="$json1" USAGE_JSON_2="$json2" bash -c "
        source '$TEST_HARNESS'
        printf '%s' \"\$USAGE_JSON_1\" > '$USAGE_RESPONSE_FILE'
        USAGE_LAST_CHECK_AT=0; check_usage_once
        printf '%s' \"\$USAGE_JSON_2\" > '$USAGE_RESPONSE_FILE'
        USAGE_LAST_CHECK_AT=0; check_usage_once
        USAGE_LAST_CHECK_AT=0; check_usage_once
        USAGE_LAST_CHECK_AT=0; check_usage_once
    "
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    count=$(grep -c "usage_resume.*window=5h" "$SHOGUN_NOTIFY_LOG")
    [ "$count" -eq 1 ] || { echo "expected exactly 1 resume order, got $count:"; cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- TC-USAGE-FETCH-001: API取得失敗時は何もしない ---

@test "TC-USAGE-FETCH-001: check_usage_once takes no action and does not fail when the usage API fetch fails" {
    write_usage_response_broken

    run env USAGE_LIMIT_CREDS="$USAGE_TEST_CREDS" PATH="$USAGE_TEST_BIN:$PATH" bash -c "
        source '$TEST_HARNESS'
        USAGE_LAST_CHECK_AT=0
        check_usage_once
    "
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ ! -s "$SHOGUN_NOTIFY_LOG" ] || { echo "must not notify on fetch failure:"; cat "$SHOGUN_NOTIFY_LOG"; false; }
    [ ! -s "$NOTIFY_LOG" ]
    [[ "$output" == *"fetch failed; no action"* ]] || { echo "expected a fetch-failed log line in:"; echo "$output"; false; }
}

# --- TC-USAGE-TMUX-001: tmuxを一切呼ばない（TC-BATON-006と同型） ---

@test "TC-USAGE-TMUX-001: check_usage_once never calls tmux even when a warning fires" {
    write_usage_response 85 "2026-08-01T07:20:00+00:00" 10 "2026-08-05T07:00:00+00:00"

    run env USAGE_LIMIT_CREDS="$USAGE_TEST_CREDS" PATH="$USAGE_TEST_BIN:$PATH" bash -c "
        source '$TEST_HARNESS'
        USAGE_LAST_CHECK_AT=0
        check_usage_once
    "
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -q "window=5h" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    [ ! -s "$MOCK_TMUX_LOG" ]
}

# --- TC-USAGE-FROM-001: 予告・再開いずれもfrom=baton_watchdog固定（cmd_180結線） ---

@test "TC-USAGE-FROM-001: both usage_warn and usage_resume are written with from=baton_watchdog (cmd_180 unread-exclusion wiring)" {
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: in_progress
YAML
    sleep 1

    local json1 json2
    json1='{"five_hour": {"utilization": 90, "resets_at": "2026-08-01T07:20:00+00:00"}, "seven_day": {"utilization": 10, "resets_at": "2026-08-05T07:00:00+00:00"}, "seven_day_sonnet": null, "seven_day_opus": null, "limits": []}'
    json2='{"five_hour": {"utilization": 20, "resets_at": "2026-08-01T16:20:00+00:00"}, "seven_day": {"utilization": 10, "resets_at": "2026-08-05T07:00:00+00:00"}, "seven_day_sonnet": null, "seven_day_opus": null, "limits": []}'

    run env USAGE_LIMIT_CREDS="$USAGE_TEST_CREDS" PATH="$USAGE_TEST_BIN:$PATH" \
        USAGE_JSON_1="$json1" USAGE_JSON_2="$json2" bash -c "
        source '$TEST_HARNESS'
        printf '%s' \"\$USAGE_JSON_1\" > '$USAGE_RESPONSE_FILE'
        USAGE_LAST_CHECK_AT=0; check_usage_once
        printf '%s' \"\$USAGE_JSON_2\" > '$USAGE_RESPONSE_FILE'
        USAGE_LAST_CHECK_AT=0; check_usage_once
    "
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    # baton_watchdog_notify_shogun (既存ヘルパ) は type=baton_alert 固定で
    # 呼ばれる。cmd_180結線が求めるのは「from」がbaton_watchdogであること
    # ——typeそのものではない。
    grep -q "INBOX_WRITE: shogun.*window=5h.*baton_watchdog$" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    grep -q "INBOX_WRITE: karo.*usage_warn baton_watchdog" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    grep -q "INBOX_WRITE: karo.*usage_resume baton_watchdog" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- TC-USAGE-ISOLATION-001: 他4関数の判定結果・状態変数に一切影響せぬ ---

@test "TC-USAGE-ISOLATION-001: check_usage_once does not affect check_once's state or determination" {
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: in_progress
YAML
    write_usage_response 10 "2026-08-01T07:20:00+00:00" 10 "2026-08-05T07:00:00+00:00"

    run env USAGE_LIMIT_CREDS="$USAGE_TEST_CREDS" PATH="$USAGE_TEST_BIN:$PATH" bash -c "
        source '$TEST_HARNESS'
        BATON_LOST_SINCE=\$(( \$(date +%s) - 10 ))
        check_once
        check_usage_once
        check_once
    "
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    # 【cmd_208/措置A是正】通常経路は今やkaro・shogunの二重通知のため、
    # 1回の発報につき2行(karo分・shogun分)書かれる。ここで確かめたい
    # 不変条件は行数そのものではなく「BATON_NOTIFIEDが interleaved
    # check_usage_once を挟んでも生き延び、2回目のcheck_onceで再発火
    # しないこと」——ゆえに2(=1回分の発報)を期待し、4(=2回分)にはならぬ
    # ことを確認する。
    count=$(grep -c "baton_lost" "$SHOGUN_NOTIFY_LOG")
    [ "$count" -eq 2 ] || { echo "expected exactly 2 baton_lost notification lines (karo+shogun, 1回分。BATON_NOTIFIED must survive an interleaved check_usage_once call), got $count:"; cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- TC-USAGE-RESUME-006【OBS-181-6回帰・実ファイル書き込み】予告がkaro自身の
#     inboxを実際に書き換えても、それを「karoの進捗」と誤認して再開が
#     空振りに消えないこと ---
#
# setup()が置く既定のinbox_write.shスタブはログへ1行echoするだけで
# queue/inbox/*.yamlを一切書かないため、予告がkaro自身のinbox mtimeを
# 押し上げる本番挙動（自己給餌の引き金）がそのままでは再現できない。
# このテストに限りTC-D1-008と同じ様式（実物cp + .venvシンボリック
# リンク）でスタブを実物へ差し替える。

@test "TC-USAGE-RESUME-006: karo's own advance-notice inbox write does not self-feed and silently swallow the resume order (OBS-181-6, real inbox_write.sh)" {
    cp "$PROJECT_ROOT/scripts/inbox_write.sh" "$FIXTURE_ROOT/scripts/inbox_write.sh"
    ln -s "$PROJECT_ROOT/.venv" "$FIXTURE_ROOT/.venv"

    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: in_progress
YAML
    # karoにtask YAMLが存在する状態を再現する（本番で偶然存在しない
    # ために発症していないだけ、という設計上の欠陥そのもの）。
    cat > "$FIXTURE_ROOT/queue/tasks/karo.yaml" << 'YAML'
task:
  task_id: subtask_karo_baseline
  status: assigned
YAML
    sleep 1  # setup()が置いた各progress artifactのmtimeがUSAGE_WARNED_ATより前になるよう猶予

    local json1 json2
    json1='{"five_hour": {"utilization": 90, "resets_at": "2026-08-01T07:20:00+00:00"}, "seven_day": {"utilization": 10, "resets_at": "2026-08-05T07:00:00+00:00"}, "seven_day_sonnet": null, "seven_day_opus": null, "limits": []}'
    json2='{"five_hour": {"utilization": 20, "resets_at": "2026-08-01T16:20:00+00:00"}, "seven_day": {"utilization": 10, "resets_at": "2026-08-05T07:00:00+00:00"}, "seven_day_sonnet": null, "seven_day_opus": null, "limits": []}'

    run env USAGE_LIMIT_CREDS="$USAGE_TEST_CREDS" PATH="$USAGE_TEST_BIN:$PATH" \
        USAGE_JSON_1="$json1" USAGE_JSON_2="$json2" bash -c "
        source '$TEST_HARNESS'
        printf '%s' \"\$USAGE_JSON_1\" > '$USAGE_RESPONSE_FILE'
        USAGE_LAST_CHECK_AT=0; check_usage_once
        printf '%s' \"\$USAGE_JSON_2\" > '$USAGE_RESPONSE_FILE'
        USAGE_LAST_CHECK_AT=0; check_usage_once
    "
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    # 予告がkaroのinboxへ実際に届いていること（自己給餌の引き金となる書き込み自体は発生する）
    grep -q "usage_warn" "$FIXTURE_ROOT/queue/inbox/karo.yaml" || { echo "expected the usage_warn advance notice to actually land in karo's real inbox:"; cat "$FIXTURE_ROOT/queue/inbox/karo.yaml"; false; }
    # 【本題】それでもなお再開号令が消えていないこと（是正前はここが0件に消えていた）
    grep -q "usage_resume" "$FIXTURE_ROOT/queue/inbox/karo.yaml" || { echo "usage_resume order missing from karo's real inbox -- OBS-181-6 self-feed regression:"; cat "$FIXTURE_ROOT/queue/inbox/karo.yaml"; false; }
}

# --- TC-USAGE-RESUME-FLAG-001【finding_3回帰】LIMITS_FLAGGEDのtrue→false遷移は、
#     reset epochが不変（契約変更等・枠の巻き直りを伴わない解除）でも再開を発火する ---
#
# 本日実データの形（gunshi_qc_181_pr41.yaml finding_3）: 17:05時点→21:10時点で
# 7D_RESETは不変(08-05→08-05)のままLIMITS_FLAGGEDがtrue→falseへ遷移した。
# cmd_181の再開関門「reset epochが変わること」単独ではこの解除を検知できない。

@test "TC-USAGE-RESUME-FLAG-001: a LIMITS_FLAGGED true->false transition fires resume even when the reset epoch is unchanged (finding_3, contract-change shape)" {
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: in_progress
YAML
    sleep 1

    local json1 json2
    # 5時間枠は無関係に保つ（util常に警告閾値未満・reset epoch不変）。
    # 7日枠のみ: reset epoch不変のままlimits[]がflagged→非flaggedへ遷移。
    json1='{"five_hour": {"utilization": 10, "resets_at": "2026-08-01T07:20:00+00:00"}, "seven_day": {"utilization": 90, "resets_at": "2026-08-05T07:00:00+00:00"}, "seven_day_sonnet": null, "seven_day_opus": null, "limits": [{"is_active": true, "severity": "critical"}]}'
    json2='{"five_hour": {"utilization": 10, "resets_at": "2026-08-01T07:20:00+00:00"}, "seven_day": {"utilization": 20, "resets_at": "2026-08-05T07:00:00+00:00"}, "seven_day_sonnet": null, "seven_day_opus": null, "limits": []}'

    run env USAGE_LIMIT_CREDS="$USAGE_TEST_CREDS" PATH="$USAGE_TEST_BIN:$PATH" \
        USAGE_JSON_1="$json1" USAGE_JSON_2="$json2" bash -c "
        source '$TEST_HARNESS'
        printf '%s' \"\$USAGE_JSON_1\" > '$USAGE_RESPONSE_FILE'
        USAGE_LAST_CHECK_AT=0; check_usage_once
        printf '%s' \"\$USAGE_JSON_2\" > '$USAGE_RESPONSE_FILE'
        USAGE_LAST_CHECK_AT=0; check_usage_once
    "
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -q "INBOX_WRITE: karo.*usage_resume.*window=7d" "$SHOGUN_NOTIFY_LOG" || { echo "expected a 7d resume order despite an unchanged reset epoch (contract-change path, finding_3):"; cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- TC-USAGE-RESUME-7D-001【OBS-181-7回帰】7日枠の巻き直りによる再開号令も家老へ届く ---
#
# 従来のコメントは「再開はこの(5時間)枠のみ」と書いていたが、実装
# （_usage_window_checkの(c)節）はnotify_karoで門を設けておらず、
# 7日枠の巻き直りでも家老へ再開号令が届く。これはコメントの誤りであり、
# 実装側が正しい（現状、7日枠の巻き直りで家老を起こす経路はこれ1本
# しか無いため）。本テストはその正しい挙動を固定する。

@test "TC-USAGE-RESUME-7D-001: a 7-day window resume order reaches karo inbox too, not just the 5-hour window (OBS-181-7)" {
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: in_progress
YAML
    sleep 1

    local json1 json2
    json1='{"five_hour": {"utilization": 10, "resets_at": "2026-08-01T07:20:00+00:00"}, "seven_day": {"utilization": 90, "resets_at": "2026-08-05T07:00:00+00:00"}, "seven_day_sonnet": null, "seven_day_opus": null, "limits": []}'
    json2='{"five_hour": {"utilization": 10, "resets_at": "2026-08-01T07:20:00+00:00"}, "seven_day": {"utilization": 20, "resets_at": "2026-08-12T07:00:00+00:00"}, "seven_day_sonnet": null, "seven_day_opus": null, "limits": []}'

    run env USAGE_LIMIT_CREDS="$USAGE_TEST_CREDS" PATH="$USAGE_TEST_BIN:$PATH" \
        USAGE_JSON_1="$json1" USAGE_JSON_2="$json2" bash -c "
        source '$TEST_HARNESS'
        printf '%s' \"\$USAGE_JSON_1\" > '$USAGE_RESPONSE_FILE'
        USAGE_LAST_CHECK_AT=0; check_usage_once
        printf '%s' \"\$USAGE_JSON_2\" > '$USAGE_RESPONSE_FILE'
        USAGE_LAST_CHECK_AT=0; check_usage_once
    "
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -q "INBOX_WRITE: karo.*usage_resume.*window=7d" "$SHOGUN_NOTIFY_LOG" || { echo "expected the 7d resume order to reach karo inbox (comment previously claimed 5h-only, but the implementation never actually gated this):"; cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- TC-USAGE-TZ-003【OBS-181-9回帰】offsetの無いnaive文字列は空文字にフォールバックする ---
#
# datetime.fromisoformatはoffsetの無い文字列をnaiveとして受理し、
# .timestamp()はそれをローカル時刻として解釈してしまう。APIがoffsetを
# 落とした値を返した場合、例外にならず9時間ずれたepochを返す
# （cmd_181が塞いだ罠が取得側の仕様変更ひとつで裏口から戻る形）。

@test "TC-USAGE-TZ-003: an offset-less (naive) resets_at yields an empty EPOCH instead of silently misinterpreting it as local time (OBS-181-9)" {
    write_usage_response 84 "2026-07-31T23:10:00" 85 "2026-08-05T07:00:00"

    run env USAGE_LIMIT_CREDS="$USAGE_TEST_CREDS" PATH="$USAGE_TEST_BIN:$PATH" \
        bash -c "source '$PROJECT_ROOT/lib/usage_limit.sh'; usage_limit_fetch_raw"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    printf '%s\n' "$output" | grep -qx '5H_RESET_EPOCH=' || { echo "expected empty 5H_RESET_EPOCH for an offset-less resets_at string, got:"; echo "$output"; false; }
    printf '%s\n' "$output" | grep -qx '7D_RESET_EPOCH=' || { echo "expected empty 7D_RESET_EPOCH for an offset-less resets_at string, got:"; echo "$output"; false; }
}

# ═══════════════════════════════════════════════════════════════
# 【cmd_187】「救出行為が検知を沈黙させる」構造の是正（SF-1/SF-2/SF-3）
# 軍師の横断調査（queue/reports/gunshi_183_self_feed_audit.yaml）が
# 発見した3件の同型欠陥の回帰固定。allowlist方式（agent_registry_agents()
# に含まれる送信者のみを「保持・応答しうる主体からの発信」として数える）
# への設計転換の効果を、denylist時代には検出できなかった形で固定する。
#
#   TC-SF1-001/002: SF-1（軍師のA/B実験と同型）。他者(karo)がinboxへ
#                   書き込んでもno_progress判定が変わらないことを固定
#   TC-SF2-001〜004: SF-2（軍師の4通り比較と同型）。from=inbox_watcherが
#                    本欠陥の直接固定である
#   TC-SF3-001: SF-3是正（QC45-F1）。count_unreadは機械を除外し、
#               list_stale_inbox_agentsは除外しない——これは意図であり、
#               問いが違うためであることを固定
#   TC-ALLOWLIST-001: allowlist方式の要。実在しない架空の機械名でも
#                      エージェント一覧に無い限り自動的に除外される
# ═══════════════════════════════════════════════════════════════

# --- TC-SF1-001/002: SF-1回帰（軍師のA/B実験と同型） ---
# 差は「karoが当該エージェントのinboxへ1件書くか否か」ただ1点。
# 当人(ashigaru6)は両caseで一切動いていない。

@test "TC-SF1-001 (CASE=no_inbound): no_progress fires when task is stale and no one wrote to the agent's inbox" {
    write_settings true 5 60 "" "" 5 60   # progress_stall_after_sec=5
    cat > "$FIXTURE_ROOT/queue/tasks/ashigaru6.yaml" << 'YAML'
task:
  task_id: subtask_sf1_no_inbound
  status: assigned
YAML
    touch -d "@$(( $(date +%s) - 10000 ))" "$FIXTURE_ROOT/queue/tasks/ashigaru6.yaml"

    run bash -c "
        source '$TEST_HARNESS'
        check_b4b_once
    "
    [ "$status" -eq 0 ]
    grep -q "no_progress: agent=ashigaru6" "$SHOGUN_NOTIFY_LOG"
}

@test "TC-SF1-002 (CASE=with_inbound) 【SF-1本欠陥の直接固定】: no_progress still fires even after karo writes a fresh message to the same agent's inbox" {
    write_settings true 5 60 "" "" 5 60
    cat > "$FIXTURE_ROOT/queue/tasks/ashigaru6.yaml" << 'YAML'
task:
  task_id: subtask_sf1_with_inbound
  status: assigned
YAML
    touch -d "@$(( $(date +%s) - 10000 ))" "$FIXTURE_ROOT/queue/tasks/ashigaru6.yaml"

    # karoが当該エージェント(ashigaru6)のinboxへ1件書く（mtimeは「今」になる）。
    # 是正前はこの1件がprogress_mtimeを巻き戻し、no_progressが0件になっていた
    # （gunshi_183_self_feed_audit.yaml SF-1実測と同型）。
    cat > "$FIXTURE_ROOT/queue/inbox/ashigaru6.yaml" << 'YAML'
messages:
  - id: msg_from_karo
    read: false
    from: karo
    timestamp: '2026-08-01T22:00:00'
YAML

    run bash -c "
        source '$TEST_HARNESS'
        check_b4b_once
    "
    [ "$status" -eq 0 ]
    grep -q "no_progress: agent=ashigaru6" "$SHOGUN_NOTIFY_LOG" || { echo "SF-1 regression: inbox write reset the progress timer"; cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- TC-SF2-001〜004: SF-2回帰（軍師の4通り比較と同型） ---
# 同一条件（active=0・open_cmds=1・BATON_LOST_SINCE=1000秒前）で、
# 足軽1号のinboxに置く未読1件のfromだけを変える。機械の書き手からの
# 発信はいずれも除外され、baton_lost判定は変わらない（常に発火する）。
# 特にfrom=inbox_watcherは本欠陥（SF-2）の直接固定である——是正前は
# denylistにinbox_watcherが含まれず、この1件だけが全軍規模の
# baton_lost検知を沈黙させていた。

@test "TC-SF2-001 (CASE=from=none): baseline control, no extra unread message → baton_lost fires" {
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
    grep -q "baton_lost" "$SHOGUN_NOTIFY_LOG"
}

@test "TC-SF2-002 (CASE=from=baton_watchdog): machine sender excluded → baton_lost still fires" {
    cat > "$FIXTURE_ROOT/queue/inbox/ashigaru1.yaml" << 'YAML'
messages:
  - id: msg_1
    read: false
    from: baton_watchdog
    timestamp: '2026-08-01T22:00:00'
YAML
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
    grep -q "baton_lost" "$SHOGUN_NOTIFY_LOG"
}

@test "TC-SF2-003 (CASE=from=watcher_supervisor): machine sender excluded → baton_lost still fires" {
    cat > "$FIXTURE_ROOT/queue/inbox/ashigaru1.yaml" << 'YAML'
messages:
  - id: msg_1
    read: false
    from: watcher_supervisor
    timestamp: '2026-08-01T22:00:00'
YAML
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
    grep -q "baton_lost" "$SHOGUN_NOTIFY_LOG"
}

@test "TC-SF2-004 (CASE=from=inbox_watcher) 【SF-2本欠陥の直接固定】: inbox_watcher's auto-recovery write no longer silences baton_lost across the whole formation" {
    cat > "$FIXTURE_ROOT/queue/inbox/ashigaru1.yaml" << 'YAML'
messages:
  - id: msg_1
    read: false
    from: inbox_watcher
    timestamp: '2026-08-01T22:00:00'
YAML
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
    grep -q "baton_lost" "$SHOGUN_NOTIFY_LOG" || { echo "SF-2 regression: inbox_watcher's write silenced whole-formation baton_lost detection"; cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- TC-SF3-001: SF-3是正（QC45-F1）。count_unreadは機械を除外し、list_stale_inbox_agentsは除外しない ---

@test "TC-SF3-001: count_unread excludes a machine sender but list_stale_inbox_agents does not (different questions, different rules by design)" {
    local stale_ts
    stale_ts=$(date -d "@$(( $(date +%s) - 700 ))" +"%Y-%m-%dT%H:%M:%S")
    cat > "$FIXTURE_ROOT/queue/inbox/karo.yaml" << YAML
messages:
  - id: msg_stale
    read: false
    from: inbox_watcher
    timestamp: '${stale_ts}'
YAML

    run bash -c "
        source '$TEST_HARNESS'
        echo \"stale_agents=[\$(baton_watchdog_list_stale_inbox_agents | tr '\n' ',')]\"
        echo \"unread=\$(baton_watchdog_count_unread)\"
    "
    [ "$status" -eq 0 ]
    # count_unreadが問うのは「誰かがバトンを保持しておるか」——機械の
    # 書き込みは保持の証拠ではないため除外が正しい（unread=0のまま）。
    # list_stale_inbox_agentsが問うのは「このinboxは読まれずに滞留して
    # おるか」——書き手が誰かは無関係。machine由来のauto-recovery通知も
    # 当人が読むべき未読ゆえ、karoがstaleとして挙がる（QC45-F1是正）。
    [[ "$output" == *"stale_agents=[karo,]"* ]] || { echo "QC45-F1 regression: list_stale_inbox_agents wrongly excluded a machine sender"; echo "$output"; false; }
    [[ "$output" == *"unread=0"* ]] || { echo "count_unread regression: machine sender should still be excluded here"; echo "$output"; false; }
}

# --- TC-ALLOWLIST-001: allowlist方式の要。架空の機械名でも自動的に除外される ---

@test "TC-ALLOWLIST-001: an unrecognized future machine sender (not in agent_registry_agents()) is excluded automatically, without any code change" {
    cat > "$FIXTURE_ROOT/queue/inbox/ashigaru1.yaml" << 'YAML'
messages:
  - id: msg_1
    read: false
    from: some_future_daemon
    timestamp: '2026-08-01T22:00:00'
YAML
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
    grep -q "baton_lost" "$SHOGUN_NOTIFY_LOG" || { echo "allowlist regression: an unrecognized machine sender was treated as a genuine unread"; cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# ═══════════════════════════════════════════════════════════════
# cmd_188後半: count_active_tasksをholds_baton基準へ統一
# （軍師設計 queue/reports/gunshi_188_design.yaml design_back_half節）
#
# 【方向A】吠えるべき時に吠える（2026-08-01の実データ形）
#   TC-ACTIVE-REAL-001/002: 成果物着地済み・report doneなのにtask
#     YAMLがassignedのままの実例2件（足軽3号・7号）が、それぞれ
#     count_active_tasksから正しく除外されること
#   TC-ACTIVE-REAL-003: 上記2件が同時に在る状態でcheck_onceを回すと、
#     7/31にactive固定でB-1が黙っていた状態が解消されること
#
# 【方向B】吠えてはならぬ時に吠えない（誤検知側・fail-high側）
#   TC-ACTIVE-FP-001〜006: 各種の「納品と誤認してはならぬ」形
#   TC-ACTIVE-FP-007: 差し戻し形でcheck_onceが早鳴きしないこと
#
# TC-B4B-008: 差し戻し形（FP-003と同じmtime順）で無進捗が閾値を
#   越えたとき、B-4bは②の条項の影響を受けず正しく吠えること
# ═══════════════════════════════════════════════════════════════

# --- TC-ACTIVE-REAL-001: 足軽3号の形（2026-08-01実例） ---

@test "TC-ACTIVE-REAL-001: count_active_tasks excludes an agent whose stale-assigned task has a fresher matching done report (ashigaru3, 2026-08-01 incident shape)" {
    cat > "$FIXTURE_ROOT/queue/tasks/ashigaru3.yaml" << 'YAML'
task:
  task_id: subtask_185_issue_58_qc_fix_v2
  status: assigned
YAML
    touch -d "@$(( $(date +%s) - 10000 ))" "$FIXTURE_ROOT/queue/tasks/ashigaru3.yaml"
    cat > "$FIXTURE_ROOT/queue/reports/ashigaru3_report.yaml" << 'YAML'
worker_id: ashigaru3
task_id: subtask_185_issue_58_qc_fix_v2
status: done
YAML

    run bash -c "
        source '$TEST_HARNESS'
        baton_watchdog_count_active_tasks
    "
    [ "$status" -eq 0 ]
    [ "$output" -eq 0 ] || { echo "expected active=0 but got: $output"; false; }
}

# --- TC-ACTIVE-REAL-002: 足軽7号の形（2026-08-01実例） ---

@test "TC-ACTIVE-REAL-002: count_active_tasks excludes an agent whose assigned task has a matching done report (ashigaru7, cmd_183 incident shape)" {
    cat > "$FIXTURE_ROOT/queue/tasks/ashigaru7.yaml" << 'YAML'
task:
  task_id: subtask_183_usage_limit_selffeed_fix
  status: assigned
YAML
    touch -d "@$(( $(date +%s) - 10000 ))" "$FIXTURE_ROOT/queue/tasks/ashigaru7.yaml"
    cat > "$FIXTURE_ROOT/queue/reports/ashigaru7_report.yaml" << 'YAML'
worker_id: ashigaru7
task_id: subtask_183_usage_limit_selffeed_fix
status: done
YAML

    run bash -c "
        source '$TEST_HARNESS'
        baton_watchdog_count_active_tasks
    "
    [ "$status" -eq 0 ]
    [ "$output" -eq 0 ] || { echo "expected active=0 but got: $output"; false; }
}

# --- TC-ACTIVE-REAL-003: 上記2件同時+閾値越しのcheck_once → 検知が復活すること ---

@test "TC-ACTIVE-REAL-003: check_once detects baton_lost once both real-incident agents are correctly excluded from active" {
    cat > "$FIXTURE_ROOT/queue/tasks/ashigaru3.yaml" << 'YAML'
task:
  task_id: subtask_185_issue_58_qc_fix_v2
  status: assigned
YAML
    touch -d "@$(( $(date +%s) - 10000 ))" "$FIXTURE_ROOT/queue/tasks/ashigaru3.yaml"
    cat > "$FIXTURE_ROOT/queue/reports/ashigaru3_report.yaml" << 'YAML'
worker_id: ashigaru3
task_id: subtask_185_issue_58_qc_fix_v2
status: done
YAML
    cat > "$FIXTURE_ROOT/queue/tasks/ashigaru7.yaml" << 'YAML'
task:
  task_id: subtask_183_usage_limit_selffeed_fix
  status: assigned
YAML
    touch -d "@$(( $(date +%s) - 10000 ))" "$FIXTURE_ROOT/queue/tasks/ashigaru7.yaml"
    cat > "$FIXTURE_ROOT/queue/reports/ashigaru7_report.yaml" << 'YAML'
worker_id: ashigaru7
task_id: subtask_183_usage_limit_selffeed_fix
status: done
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
    [[ "$output" == *"baton_condition=true"* ]] || { echo "expected baton_condition=true; got: $output"; false; }
    [ "$(grep -c 'INBOX_WRITE: shogun' "$SHOGUN_NOTIFY_LOG")" -eq 1 ] || { echo "expected exactly 1 shogun inbox notification"; cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- TC-ACTIVE-FP-001: 報告ファイル無し → active=1（納品と誤認しない） ---

@test "TC-ACTIVE-FP-001: an assigned task with no matching report file still counts as active" {
    cat > "$FIXTURE_ROOT/queue/tasks/ashigaru2.yaml" << 'YAML'
task:
  task_id: subtask_fp1
  status: assigned
YAML

    run bash -c "
        source '$TEST_HARNESS'
        baton_watchdog_count_active_tasks
    "
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ] || { echo "expected active=1 but got: $output"; false; }
}

# --- TC-ACTIVE-FP-002: 報告のtask_idが別物 → active=1 ---

@test "TC-ACTIVE-FP-002: a report whose task_id does not match the current task is not treated as delivery, still counts as active" {
    cat > "$FIXTURE_ROOT/queue/tasks/ashigaru2.yaml" << 'YAML'
task:
  task_id: subtask_fp2_v2
  status: assigned
YAML
    cat > "$FIXTURE_ROOT/queue/reports/ashigaru2_report.yaml" << 'YAML'
worker_id: ashigaru2
task_id: subtask_fp2
status: done
YAML

    run bash -c "
        source '$TEST_HARNESS'
        baton_watchdog_count_active_tasks
    "
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ] || { echo "expected active=1 but got: $output"; false; }
}

# --- TC-ACTIVE-FP-003【要】: 同一task_idの差し戻し → 古い報告を証拠に採らない ---

@test "TC-ACTIVE-FP-003: a same-task_id redo makes the report stale evidence — task YAML touched after the report keeps the agent active" {
    cat > "$FIXTURE_ROOT/queue/reports/ashigaru2_report.yaml" << 'YAML'
worker_id: ashigaru2
task_id: subtask_fp3
status: done
YAML
    touch -d "@$(( $(date +%s) - 1000 ))" "$FIXTURE_ROOT/queue/reports/ashigaru2_report.yaml"
    cat > "$FIXTURE_ROOT/queue/tasks/ashigaru2.yaml" << 'YAML'
task:
  task_id: subtask_fp3
  status: assigned
YAML
    # task YAMLは報告より後(=差し戻し)。デフォルトのmtime(=今)で十分新しい。

    run bash -c "
        source '$TEST_HARNESS'
        baton_watchdog_count_active_tasks
    "
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ] || { echo "expected active=1 (redo report must not be accepted as delivery evidence) but got: $output"; false; }
}

# --- TC-ACTIVE-FP-004: 報告のstatusがdone以外(blocked) → active=1 ---

@test "TC-ACTIVE-FP-004: a report with status other than done (blocked) is not treated as delivery, still counts as active" {
    cat > "$FIXTURE_ROOT/queue/tasks/ashigaru2.yaml" << 'YAML'
task:
  task_id: subtask_fp4
  status: assigned
YAML
    cat > "$FIXTURE_ROOT/queue/reports/ashigaru2_report.yaml" << 'YAML'
worker_id: ashigaru2
task_id: subtask_fp4
status: blocked
YAML

    run bash -c "
        source '$TEST_HARNESS'
        baton_watchdog_count_active_tasks
    "
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ] || { echo "expected active=1 but got: $output"; false; }
}

# --- TC-ACTIVE-FP-005: 報告YAMLが壊れている/読めない → active=1（fail-high） ---

@test "TC-ACTIVE-FP-005: a malformed/unparsable report is not treated as delivery, still counts as active (fail-high)" {
    cat > "$FIXTURE_ROOT/queue/tasks/ashigaru2.yaml" << 'YAML'
task:
  task_id: subtask_fp5
  status: assigned
YAML
    printf 'this is not a valid report\nno task_id line at all\n\x00\x01binary garbage' > "$FIXTURE_ROOT/queue/reports/ashigaru2_report.yaml"

    run bash -c "
        source '$TEST_HARNESS'
        baton_watchdog_count_active_tasks
    "
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ] || { echo "expected active=1 (fail-high on unparsable report) but got: $output"; false; }
}

# --- TC-ACTIVE-FP-006: task status:in_progress + 報告一致done(mtime古) → active=0 ---

@test "TC-ACTIVE-FP-006: an in_progress task with a matching done report (older task mtime) is excluded from active, same discipline as assigned" {
    cat > "$FIXTURE_ROOT/queue/reports/ashigaru2_report.yaml" << 'YAML'
worker_id: ashigaru2
task_id: subtask_fp6
status: done
YAML
    cat > "$FIXTURE_ROOT/queue/tasks/ashigaru2.yaml" << 'YAML'
task:
  task_id: subtask_fp6
  status: in_progress
YAML
    touch -d "@$(( $(date +%s) - 10000 ))" "$FIXTURE_ROOT/queue/tasks/ashigaru2.yaml"

    run bash -c "
        source '$TEST_HARNESS'
        baton_watchdog_count_active_tasks
    "
    [ "$status" -eq 0 ]
    [ "$output" -eq 0 ] || { echo "expected active=0 but got: $output"; false; }
}

# --- TC-ACTIVE-FP-007: 差し戻し形でcheck_onceを閾値越しに回す → 早鳴きしないこと ---

@test "TC-ACTIVE-FP-007: check_once does not fire (baton_condition=false) when a redo keeps an agent counted as active (no early-crow)" {
    cat > "$FIXTURE_ROOT/queue/reports/ashigaru2_report.yaml" << 'YAML'
worker_id: ashigaru2
task_id: subtask_fp7
status: done
YAML
    touch -d "@$(( $(date +%s) - 1000 ))" "$FIXTURE_ROOT/queue/reports/ashigaru2_report.yaml"
    cat > "$FIXTURE_ROOT/queue/tasks/ashigaru2.yaml" << 'YAML'
task:
  task_id: subtask_fp7
  status: assigned
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
    [[ "$output" == *"baton_condition=false"* ]] || { echo "expected baton_condition=false; got: $output"; false; }
    [ ! -s "$SHOGUN_NOTIFY_LOG" ] || { echo "expected zero shogun notifications; got:"; cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- TC-B4B-008: 差し戻し形(FP-003と同型)+無進捗閾値越え → B-4bは吠える ---

@test "TC-B4B-008: B-4b still fires no_progress for a same-task_id redo whose stale-relative report would otherwise look like delivery" {
    write_settings true 5 60 "" "" 5 60   # progress_stall_after_sec=5
    cat > "$FIXTURE_ROOT/queue/reports/ashigaru3_report.yaml" << 'YAML'
worker_id: ashigaru3
task_id: subtask_b4b008
status: done
YAML
    touch -d "@$(( $(date +%s) - 10000 ))" "$FIXTURE_ROOT/queue/reports/ashigaru3_report.yaml"
    cat > "$FIXTURE_ROOT/queue/tasks/ashigaru3.yaml" << 'YAML'
task:
  task_id: subtask_b4b008
  status: assigned
YAML
    # task YAMLは報告より後(=差し戻し)だが、なお進捗停滞閾値は越えている
    touch -d "@$(( $(date +%s) - 9000 ))" "$FIXTURE_ROOT/queue/tasks/ashigaru3.yaml"

    run bash -c "
        source '$TEST_HARNESS'
        check_b4b_once
    "
    [ "$status" -eq 0 ]
    grep -q "no_progress: agent=ashigaru3" "$SHOGUN_NOTIFY_LOG" || { echo "expected B-4b to fire for the redo shape (report_delivered's mtime条項 must not suppress B-4b's own detection)"; cat "$SHOGUN_NOTIFY_LOG"; false; }
    grep -q "subtask_b4b008" "$SHOGUN_NOTIFY_LOG"
}

# ═══════════════════════════════════════════════════════════════
# cmd_208: baton_lost主経路の宛先二重化・人待ち安全網の閾値是正・再武装
# (gunshi_design_208.yaml)
#   V-1: 通常経路がkaro・shogunの両方へ1件ずつ書く
#   V-2: repeat閾値未満では再通知せず、超えたら再通知する。条件が偽に
#        なった場合は新たな継続として計り直す（既存else節の意味論維持）
#   V-3【回帰固定・必須】番犬自身がkaro宛に書いた警報はunreadに数えない
#        （措置Aの安全性が全面的に依存する性質）
#   V-4: 印付きcmdが(新既定)3600秒超でhuman-held警報がkaroにも届く
# ═══════════════════════════════════════════════════════════════

# --- V-1: 通常経路の宛先二重化 ---

@test "TC-208-V1: baton_lost normal path writes one baton_alert each to karo and shogun" {
    write_settings true 5 60
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: in_progress
YAML

    run bash -c "
        source '$TEST_HARNESS'
        BATON_LOST_SINCE=\$(( \$(date +%s) - 10 ))  # threshold=5s, 10s elapsed
        check_once
    "
    [ "$status" -eq 0 ]
    [ "$(grep -c 'INBOX_WRITE: karo ' "$SHOGUN_NOTIFY_LOG")" -eq 1 ] || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    [ "$(grep -c 'INBOX_WRITE: shogun ' "$SHOGUN_NOTIFY_LOG")" -eq 1 ] || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    grep -q "baton_alert" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    # 将軍への通知は削らず維持されていること（措置Aは追加のみ）
    grep -q "baton_lost: unread=0 active=0 open_cmds=1" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- V-2a: repeat閾値未満では再通知しない ---

@test "TC-208-V2a: no repeat notification while under baton_lost_repeat_after_sec" {
    write_settings true 5 60
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: in_progress
YAML

    # BATON_NOTIFIEDは100秒前(既定repeat閾値900秒未満) → 再通知させない
    run bash -c "
        source '$TEST_HARNESS'
        now=\$(date +%s)
        BATON_LOST_SINCE=\$((now - 10))
        BATON_NOTIFIED=\$((now - 100))
        check_once
    "
    [ "$status" -eq 0 ]
    [ ! -s "$SHOGUN_NOTIFY_LOG" ] || { echo "expected no repeat notification yet"; cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- V-2b: repeat閾値を超えたら再通知する ---

@test "TC-208-V2b: repeat notification fires once baton_lost_repeat_after_sec is exceeded" {
    write_settings true 5 60
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: in_progress
YAML

    # BATON_NOTIFIEDは1000秒前(既定repeat閾値900秒超) → 再通知させる
    run bash -c "
        source '$TEST_HARNESS'
        now=\$(date +%s)
        BATON_LOST_SINCE=\$((now - 10))
        BATON_NOTIFIED=\$((now - 1000))
        check_once
    "
    [ "$status" -eq 0 ]
    [ "$(grep -c 'INBOX_WRITE: karo ' "$SHOGUN_NOTIFY_LOG")" -eq 1 ] || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    [ "$(grep -c 'INBOX_WRITE: shogun ' "$SHOGUN_NOTIFY_LOG")" -eq 1 ] || { cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- V-2c: 条件が偽になったら次回は新たな継続として計り直す（既存意味論の回帰固定） ---

@test "TC-208-V2c: when the condition goes false, BATON_LOST_SINCE and the epoch-based BATON_NOTIFIED both reset to 0" {
    write_settings true 5 60
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: in_progress
YAML
    # unreadを1件立てて条件を偽にする
    cat > "$FIXTURE_ROOT/queue/inbox/ashigaru1.yaml" << 'YAML'
messages:
  - id: msg_unread
    read: false
YAML

    run bash -c "
        source '$TEST_HARNESS'
        now=\$(date +%s)
        BATON_LOST_SINCE=\$((now - 10))
        BATON_NOTIFIED=\$((now - 10))
        check_once
        echo \"RESET_STATE:\${BATON_LOST_SINCE}:\${BATON_NOTIFIED}\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"RESET_STATE:0:0"* ]] || { echo "$output"; false; }
}

# --- V-3【必須・回帰固定】自己給餌しないこと ---

@test "TC-208-V3: baton_watchdog_count_unread returns 0 for its own karo alert (self-feeding safety, regression-pinned)" {
    cat > "$FIXTURE_ROOT/queue/inbox/karo.yaml" << 'YAML'
messages:
  - id: msg_self_written_by_watchdog
    from: baton_watchdog
    read: false
    timestamp: "2026-08-07T00:00:00"
    type: baton_alert
YAML

    run bash -c "
        source '$TEST_HARNESS'
        baton_watchdog_count_unread
    "
    [ "$status" -eq 0 ]
    [ "$output" = "0" ] || { echo "expected 0 (self-written baton_alert must not be counted); got: $output"; false; }
}

# --- V-4: 印付きcmdが(新既定)3600秒超でhuman-held警報がkaroにも届く ---

@test "TC-208-V4: the human-held safety net (now defaulting to 3600s) reaches karo in addition to shogun" {
    write_settings true 5 60
    local since
    since="$(date -d @$(( $(date +%s) - 4000 )) '+%Y-%m-%dT%H:%M:%S')"  # 新既定3600sを超過
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << YAML
commands:
  - id: cmd_192
    status: in_progress
    awaiting: lord
    awaiting_since: "$since"
YAML

    run bash -c "
        source '$TEST_HARNESS'
        check_once
    "
    [ "$status" -eq 0 ]
    grep -q "INBOX_WRITE: karo " "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    grep -q "INBOX_WRITE: shogun " "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    grep -q "baton_lost(human-held)" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    grep -q "cmd_192" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- V-4b: 24時間の旧既定ではもはや発火しないこと（既定値是正の直接確認）---

@test "TC-208-V4b: the safety net does NOT fire yet at 4000s elapsed if the old 86400s default were still in effect (sanity: confirms the default actually changed)" {
    write_settings true 5 60 "" "" "" "" "" shogun 86400 86400   # 明示的に旧既定(86400s)へ戻す
    local since
    since="$(date -d @$(( $(date +%s) - 4000 )) '+%Y-%m-%dT%H:%M:%S')"
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << YAML
commands:
  - id: cmd_192
    status: in_progress
    awaiting: lord
    awaiting_since: "$since"
YAML

    run bash -c "
        source '$TEST_HARNESS'
        check_once
    "
    [ "$status" -eq 0 ]
    ! grep -q "baton_lost(human-held)" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# ═══════════════════════════════════════════════════════════════
# cmd_208後続: awaiting:external (gunshi_design_208_awaiting_external.yaml)
# ═══════════════════════════════════════════════════════════════

# --- W-1【最重要・回帰固定】: 外部印はopen_cmds_machineを減らさない ---

@test "W-1: an awaiting:external marker does not shrink open_cmds_machine and baton_condition stays true" {
    write_settings true 5 60
    local since
    since="$(date -d @$(( $(date +%s) - 60 )) '+%Y-%m-%dT%H:%M:%S')"
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << YAML
commands:
  - id: cmd_208
    status: in_progress
    awaiting: external
    awaiting_since: "$since"
    awaiting_target: "PR#84 run 123"
    awaiting_check: "gh pr checks 84"
YAML

    run bash -c "
        source '$TEST_HARNESS'
        BATON_LOST_SINCE=\$(( \$(date +%s) - 10 ))
        check_once
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "open_cmds_machine=1" || { echo "$output"; false; }
    echo "$output" | grep -q "baton_condition=true" || { echo "$output"; false; }
}

# --- W-2: 印が揃えばexternal_wait:文面(target/checkを含む) ---

@test "W-2: a complete external marker produces external_wait: text containing the target and check command" {
    write_settings true 5 60
    local since
    since="$(date -d @$(( $(date +%s) - 60 )) '+%Y-%m-%dT%H:%M:%S')"
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << YAML
commands:
  - id: cmd_208
    status: in_progress
    awaiting: external
    awaiting_since: "$since"
    awaiting_target: "PR#84 run 123"
    awaiting_check: "gh pr checks 84"
YAML

    run bash -c "
        source '$TEST_HARNESS'
        BATON_LOST_SINCE=\$(( \$(date +%s) - 10 ))
        check_once
    "
    [ "$status" -eq 0 ]
    grep -q "external_wait:" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    grep -q "PR#84 run 123" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    grep -q "gh pr checks 84" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    [ "$(grep -c 'INBOX_WRITE: karo ' "$SHOGUN_NOTIFY_LOG")" -eq 1 ] || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    [ "$(grep -c 'INBOX_WRITE: shogun ' "$SHOGUN_NOTIFY_LOG")" -eq 1 ] || { cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- W-3a/b: 再通知間隔(既定3600s)の差し替え ---

@test "W-3a: no repeat notification for external_wait while under baton_external_repeat_after_sec" {
    write_settings true 5 60
    local since
    since="$(date -d @$(( $(date +%s) - 60 )) '+%Y-%m-%dT%H:%M:%S')"
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << YAML
commands:
  - id: cmd_208
    status: in_progress
    awaiting: external
    awaiting_since: "$since"
    awaiting_target: "PR#84 run 123"
    awaiting_check: "gh pr checks 84"
YAML

    # BATON_NOTIFIEDは100秒前(既定3600s未満) → 再通知させない
    run bash -c "
        source '$TEST_HARNESS'
        now=\$(date +%s)
        BATON_LOST_SINCE=\$((now - 10))
        BATON_NOTIFIED=\$((now - 100))
        check_once
    "
    [ "$status" -eq 0 ]
    [ ! -s "$SHOGUN_NOTIFY_LOG" ] || { echo "expected no repeat notification yet"; cat "$SHOGUN_NOTIFY_LOG"; false; }
}

@test "W-3b: repeat notification fires once baton_external_repeat_after_sec is exceeded" {
    write_settings true 5 60
    local since
    since="$(date -d @$(( $(date +%s) - 60 )) '+%Y-%m-%dT%H:%M:%S')"
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << YAML
commands:
  - id: cmd_208
    status: in_progress
    awaiting: external
    awaiting_since: "$since"
    awaiting_target: "PR#84 run 123"
    awaiting_check: "gh pr checks 84"
YAML

    # BATON_NOTIFIEDは4000秒前(既定3600s超) → 再通知させる
    run bash -c "
        source '$TEST_HARNESS'
        now=\$(date +%s)
        BATON_LOST_SINCE=\$((now - 10))
        BATON_NOTIFIED=\$((now - 4000))
        check_once
    "
    [ "$status" -eq 0 ]
    grep -q "external_wait:" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- W-3c: awaiting_budget_sec超過は通常モードへ戻り、超過を明記する ---

@test "W-3c: awaiting_budget_sec exceeded falls back to normal mode with an explicit overrun note" {
    write_settings true 5 60
    local since
    since="$(date -d @$(( $(date +%s) - 900 )) '+%Y-%m-%dT%H:%M:%S')"  # 900s経過
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << YAML
commands:
  - id: cmd_208
    status: in_progress
    awaiting: external
    awaiting_since: "$since"
    awaiting_target: "PR#84 run 123"
    awaiting_check: "gh pr checks 84"
    awaiting_budget_sec: 180
YAML

    run bash -c "
        source '$TEST_HARNESS'
        BATON_LOST_SINCE=\$(( \$(date +%s) - 10 ))
        check_once
    "
    [ "$status" -eq 0 ]
    grep -q "^INBOX_WRITE: shogun baton_lost: " "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    grep -q "外部待ち予算超過: cmd_208 が3mを超えた" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    ! grep -q "external_wait:" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- W-4: 必須欄(target/check/since)いずれかの欠落は印を無効にする ---

@test "W-4: a marker missing awaiting_target, awaiting_check, or awaiting_since is treated as no marker (normal mode)" {
    write_settings true 5 60
    local since
    since="$(date -d @$(( $(date +%s) - 60 )) '+%Y-%m-%dT%H:%M:%S')"

    # (a) awaiting_target 欠落
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << YAML
commands:
  - id: cmd_208
    status: in_progress
    awaiting: external
    awaiting_since: "$since"
    awaiting_check: "gh pr checks 84"
YAML
    run bash -c "
        source '$TEST_HARNESS'
        BATON_LOST_SINCE=\$(( \$(date +%s) - 10 ))
        check_once
    "
    [ "$status" -eq 0 ]
    grep -q "^INBOX_WRITE: shogun baton_lost: " "$SHOGUN_NOTIFY_LOG" || { echo "(a) awaiting_target欠落で発火せず"; cat "$SHOGUN_NOTIFY_LOG"; false; }
    ! grep -q "external_wait:" "$SHOGUN_NOTIFY_LOG" || { echo "(a) 欠落した印がexternal_waitとして扱われた"; cat "$SHOGUN_NOTIFY_LOG"; false; }

    # (b) awaiting_check 欠落
    > "$SHOGUN_NOTIFY_LOG"
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << YAML
commands:
  - id: cmd_208
    status: in_progress
    awaiting: external
    awaiting_since: "$since"
    awaiting_target: "PR#84 run 123"
YAML
    run bash -c "
        source '$TEST_HARNESS'
        BATON_LOST_SINCE=\$(( \$(date +%s) - 10 ))
        check_once
    "
    [ "$status" -eq 0 ]
    grep -q "^INBOX_WRITE: shogun baton_lost: " "$SHOGUN_NOTIFY_LOG" || { echo "(b) awaiting_check欠落で発火せず"; cat "$SHOGUN_NOTIFY_LOG"; false; }
    ! grep -q "external_wait:" "$SHOGUN_NOTIFY_LOG" || { echo "(b) 欠落した印がexternal_waitとして扱われた"; cat "$SHOGUN_NOTIFY_LOG"; false; }

    # (c) awaiting_since 欠落
    > "$SHOGUN_NOTIFY_LOG"
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_208
    status: in_progress
    awaiting: external
    awaiting_target: "PR#84 run 123"
    awaiting_check: "gh pr checks 84"
YAML
    run bash -c "
        source '$TEST_HARNESS'
        BATON_LOST_SINCE=\$(( \$(date +%s) - 10 ))
        check_once
    "
    [ "$status" -eq 0 ]
    grep -q "^INBOX_WRITE: shogun baton_lost: " "$SHOGUN_NOTIFY_LOG" || { echo "(c) awaiting_since欠落で発火せず"; cat "$SHOGUN_NOTIFY_LOG"; false; }
    ! grep -q "external_wait:" "$SHOGUN_NOTIFY_LOG" || { echo "(c) 欠落した印がexternal_waitとして扱われた"; cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# ═══════════════════════════════════════════════════════════════
# cmd_208後続 E-3: 静穏帯付きntfy (gunshi_design_208_e3_quiet_hours.yaml)
# ═══════════════════════════════════════════════════════════════

# --- Q-1: baton_ntfy_hm_in_window純関数の境界判定(8進罠を含む) ---

@test "Q-1: baton_ntfy_hm_in_window boundary judgement including the 0800/0900 octal-literal trap" {
    write_settings true 5 60
    run bash -c "
        source '$TEST_HARNESS'
        baton_ntfy_hm_in_window 2259 2300 0700; echo \"2259:\$?\"
        baton_ntfy_hm_in_window 2300 2300 0700; echo \"2300:\$?\"
        baton_ntfy_hm_in_window 0300 2300 0700; echo \"0300:\$?\"
        baton_ntfy_hm_in_window 0659 2300 0700; echo \"0659:\$?\"
        baton_ntfy_hm_in_window 0700 2300 0700; echo \"0700:\$?\"
        baton_ntfy_hm_in_window 0701 2300 0700; echo \"0701:\$?\"
        baton_ntfy_hm_in_window 0800 0000 0900; echo \"0800:\$?\"
        baton_ntfy_hm_in_window 0900 0000 0900; echo \"0900:\$?\"
        baton_ntfy_hm_in_window 1200 0000 0000; echo \"eq:\$?\"
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "^2259:1$" || { echo "$output"; false; }
    echo "$output" | grep -q "^2300:0$" || { echo "$output"; false; }
    echo "$output" | grep -q "^0300:0$" || { echo "$output"; false; }
    echo "$output" | grep -q "^0659:0$" || { echo "$output"; false; }
    echo "$output" | grep -q "^0700:1$" || { echo "$output"; false; }
    echo "$output" | grep -q "^0701:1$" || { echo "$output"; false; }
    echo "$output" | grep -q "^0800:0$" || { echo "$output"; false; }
    echo "$output" | grep -q "^0900:1$" || { echo "$output"; false; }
    echo "$output" | grep -q "^eq:1$" || { echo "$output"; false; }
}

# --- Q-2: 静穏帯中はbranch_policy_notifyを呼ばず退避キューへ1行できる ---

@test "Q-2: during quiet hours, branch_policy_notify is not called and one deferred row is written" {
    write_settings true 5 60
    write_quiet_settings true 23:00 07:00
    run bash -c "
        source '$TEST_HARNESS'
        baton_ntfy_now_hm() { echo 0300; }
        baton_ntfy_emit_or_defer external_budget_exceeded cmd_208 'message text'
    "
    [ "$status" -eq 0 ]
    [ ! -s "$NOTIFY_LOG" ] || { cat "$NOTIFY_LOG"; false; }
    [ -f "$FIXTURE_ROOT/queue/ntfy_deferred.tsv" ] || { echo "deferred TSV not created"; false; }
    [ "$(grep -c '^external_budget_exceeded' "$FIXTURE_ROOT/queue/ntfy_deferred.tsv")" -eq 1 ] || { cat "$FIXTURE_ROOT/queue/ntfy_deferred.tsv"; false; }
}

# --- Q-3: 連続呼び出しで行数が増えず、occurrencesが積算される ---

@test "Q-3: repeated calls in the same window keep the row count at 1, incrementing occurrences" {
    write_settings true 5 60
    write_quiet_settings true 23:00 07:00
    run bash -c "
        source '$TEST_HARNESS'
        baton_ntfy_now_hm() { echo 0300; }
        for i in \$(seq 1 10); do
            baton_ntfy_emit_or_defer external_budget_exceeded cmd_208 'msg'
        done
    "
    [ "$status" -eq 0 ]
    [ "$(grep -c '^external_budget_exceeded' "$FIXTURE_ROOT/queue/ntfy_deferred.tsv")" -eq 1 ] || { cat "$FIXTURE_ROOT/queue/ntfy_deferred.tsv"; false; }
    occ=$(awk -F'\t' '$1=="external_budget_exceeded"{print $5}' "$FIXTURE_ROOT/queue/ntfy_deferred.tsv")
    [ "$occ" = "10" ] || { echo "occurrences=$occ"; cat "$FIXTURE_ROOT/queue/ntfy_deferred.tsv"; false; }
}

# --- Q-4: 明けたら将軍inbox1件・ntfy1回、両cmd_idと確認コマンドを含み、再送されない ---

@test "Q-4: after quiet hours end, a digest reaches shogun inbox and ntfy once, contains both cmd_ids and confirm commands, and is not resent" {
    write_settings true 5 60
    write_quiet_settings true 23:00 07:00
    local now
    now=$(date +%s)
    printf 'external_budget_exceeded\tcmd_208\t%s\t%s\t3\t0\tcmd_208 対象:PR#84。確認: gh pr checks 84\n' "$now" "$now" > "$FIXTURE_ROOT/queue/ntfy_deferred.tsv"
    printf 'external_budget_exceeded\tcmd_210\t%s\t%s\t1\t0\tcmd_210 対象:PR#85。確認: gh pr checks 85\n' "$now" "$now" >> "$FIXTURE_ROOT/queue/ntfy_deferred.tsv"

    run bash -c "
        source '$TEST_HARNESS'
        baton_ntfy_now_hm() { echo 0700; }
        ntfy_flush_deferred_once
        ntfy_flush_deferred_once
    "
    [ "$status" -eq 0 ]
    [ "$(grep -c 'INBOX_WRITE: shogun external_wait 予算超過' "$SHOGUN_NOTIFY_LOG")" -eq 1 ] || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    [ "$(grep -c 'external_wait 予算超過' "$NOTIFY_LOG")" -eq 1 ] || { cat "$NOTIFY_LOG"; false; }
    grep -q "cmd_208" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    grep -q "cmd_210" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    grep -q "確認:" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- Q-5【本設計の要】: プロセス入替(シェル変数を引き継がぬ新プロセス)を跨いでも明けの1通が出る ---

@test "Q-5: the flush survives a fresh process with no inherited shell state (file-based deferral, not process-local)" {
    write_settings true 5 60
    write_quiet_settings true 23:00 07:00
    local now
    now=$(date +%s)
    printf 'external_budget_exceeded\tcmd_208\t%s\t%s\t5\t0\tcmd_208 対象:PR#84。確認: gh pr checks 84\n' "$now" "$now" > "$FIXTURE_ROOT/queue/ntfy_deferred.tsv"

    # 退避を書いた側のプロセスとは無関係な、シェル変数を一切引き継がぬ
    # 新プロセスでflushする(番犬プロセスがwatcher_supervisorにより
    # 入れ替わる実運用を模す。cmd_197/OBS-61-1と同じ轍を踏まぬための
    # 要件そのもの)。
    run bash -c "
        source '$TEST_HARNESS'
        baton_ntfy_now_hm() { echo 0700; }
        ntfy_flush_deferred_once
    "
    [ "$status" -eq 0 ]
    grep -q "INBOX_WRITE: shogun external_wait 予算超過" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    grep -q "cmd_208" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
}

# --- Q-6: ntfyが死んでいても明けの1通(将軍inbox)は出る ---

@test "Q-6: the digest still reaches shogun inbox even when ntfy itself fails, and flushed_epoch is set (no infinite retry)" {
    write_settings true 5 60
    write_quiet_settings true 23:00 07:00
    local now
    now=$(date +%s)
    printf 'external_budget_exceeded\tcmd_208\t%s\t%s\t1\t0\tcmd_208 対象:PR#84。確認: gh pr checks 84\n' "$now" "$now" > "$FIXTURE_ROOT/queue/ntfy_deferred.tsv"

    run bash -c "
        source '$TEST_HARNESS'
        branch_policy_notify() { return 1; }
        baton_ntfy_now_hm() { echo 0700; }
        ntfy_flush_deferred_once
    "
    [ "$status" -eq 0 ]
    grep -q "INBOX_WRITE: shogun external_wait 予算超過" "$SHOGUN_NOTIFY_LOG" || { cat "$SHOGUN_NOTIFY_LOG"; false; }
    flushed=$(awk -F'\t' '$1=="external_budget_exceeded"{print $6}' "$FIXTURE_ROOT/queue/ntfy_deferred.tsv")
    [ "$flushed" != "0" ] || { echo "flushed_epoch not set; would retry forever"; cat "$FIXTURE_ROOT/queue/ntfy_deferred.tsv"; false; }
}

# --- Q-7【回帰固定・最重要】: 静穏帯は将軍inbox主経路に一切影響しない ---

@test "Q-7: shogun inbox output from check_once is byte-identical whether quiet hours are in effect or not" {
    write_settings true 5 60
    write_quiet_settings true 23:00 07:00
    cat > "$FIXTURE_ROOT/queue/shogun_to_karo.yaml" << 'YAML'
commands:
  - id: cmd_1
    status: in_progress
YAML

    run bash -c "
        source '$TEST_HARNESS'
        baton_ntfy_now_hm() { echo 0300; }
        BATON_LOST_SINCE=\$(( \$(date +%s) - 10 ))
        check_once
    "
    [ "$status" -eq 0 ]
    cp "$SHOGUN_NOTIFY_LOG" "$TEST_TMPDIR/quiet_on.log"
    > "$SHOGUN_NOTIFY_LOG"

    run bash -c "
        source '$TEST_HARNESS'
        baton_ntfy_now_hm() { echo 1200; }
        BATON_LOST_SINCE=\$(( \$(date +%s) - 10 ))
        check_once
    "
    [ "$status" -eq 0 ]
    diff "$TEST_TMPDIR/quiet_on.log" "$SHOGUN_NOTIFY_LOG" || { echo "quiet hours leaked into the shogun-inbox primary path"; false; }
}

# --- Q-8: 静穏帯の幅が上限を超えると無効化され鳴る側へ倒れる ---

@test "Q-8: a quiet window wider than the span cap is disabled (falls to the noisy side) and logs a warning" {
    write_settings true 5 60
    write_quiet_settings true 00:00 13:00   # 780min >= 既定720min
    run bash -c "
        source '$TEST_HARNESS'
        baton_ntfy_in_quiet_hours
        echo \"RESULT:\$?\"
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "RESULT:1" || { echo "$output"; false; }
    echo "$output" | grep -q "quiet window too wide" || { echo "$output"; false; }
}
