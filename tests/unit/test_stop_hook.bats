#!/usr/bin/env bats
# test_stop_hook.bats — stop_hook_inbox.sh unit tests
#
# Calls the REAL production script with env var overrides:
#   __STOP_HOOK_SCRIPT_DIR → points to test temp directory
#   __STOP_HOOK_AGENT_ID   → mocks tmux agent detection
#
# テスト構成:
#   T-HOOK-001: stop_hook_active=true → exit 0
#   T-HOOK-002: agent不明 → exit 0
#   T-HOOK-003: agent_id=shogun → exit 0
#   T-HOOK-004: 完了メッセージ → inbox_writeが呼ばれる (report_completed)
#   T-HOOK-005: エラーメッセージ → inbox_writeが呼ばれる (error_report)
#   T-HOOK-006: 中立メッセージ → inbox_write呼ばれない
#   T-HOOK-007: last_assistant_message空 → inbox_write呼ばれない
#   T-HOOK-008: inbox未読あり → block JSON出力
#   T-HOOK-009: inbox未読なし + 完了メッセージ → exit 0 + 通知あり
#   T-HOOK-010: inbox未読あり + 完了メッセージ → block + 通知あり
#   T-B1: 正常なJSONをstdinへ与えると、印にtranscript_pathが1行そのまま書かれる
#   T-B2: 空stdin／不正JSON／transcript_path欠落 → exit 0し印を作らず既存の印も壊さぬ
#   T-B3: hook生存の証拠——パスが前回と同一でも印のmtimeが更新される
#   T-B4: AGENT_ID解決不能 → 印を書かず exit 0（既存の早期exit経路を壊さぬ回帰）

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/scripts/stop_hook_inbox.sh"

setup() {
    TEST_TMP="$(mktemp -d)"
    mkdir -p "$TEST_TMP/scripts"
    mkdir -p "$TEST_TMP/queue/inbox"

    # Mock inbox_write.sh — logs arguments to file
    cat > "$TEST_TMP/scripts/inbox_write.sh" << 'MOCK'
#!/bin/bash
echo "$@" >> "$(dirname "$0")/../inbox_write_calls.log"
MOCK
    chmod +x "$TEST_TMP/scripts/inbox_write.sh"

    # cmd_226: 生存痕跡の置き場をフィクスチャ内へ隔離する。
    # 本番の/tmp/shogun_transcript_*を読み書きさせない。
    export IDLE_FLAG_DIR="$TEST_TMP/idle_flags"
    mkdir -p "$IDLE_FLAG_DIR"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# Helper: run the REAL hook script with test overrides
run_hook() {
    local json="$1"
    local agent_id="${2:-ashigaru1}"
    __STOP_HOOK_SCRIPT_DIR="$TEST_TMP" \
    __STOP_HOOK_AGENT_ID="$agent_id" \
    IDLE_FLAG_DIR="$IDLE_FLAG_DIR" \
    run bash "$HOOK_SCRIPT" <<< "$json"
}

# Helper: run with no agent ID set
run_hook_no_agent() {
    local json="$1"
    __STOP_HOOK_SCRIPT_DIR="$TEST_TMP" \
    __STOP_HOOK_AGENT_ID="" \
    IDLE_FLAG_DIR="$IDLE_FLAG_DIR" \
    run bash "$HOOK_SCRIPT" <<< "$json"
}

@test "T-HOOK-001: stop_hook_active=true skips all processing" {
    run_hook '{"stop_hook_active": true, "last_assistant_message": "任務完了"}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "T-HOOK-002: unknown agent (empty agent_id) exits 0" {
    run_hook_no_agent '{"stop_hook_active": false}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "T-HOOK-003: shogun agent always exits 0" {
    run_hook '{"stop_hook_active": false, "last_assistant_message": "任務完了"}' "shogun"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "T-HOOK-004: completion message triggers inbox_write to karo" {
    run_hook '{"stop_hook_active": false, "last_assistant_message": "任務完了でござる。report YAML更新済み。"}'
    [ "$status" -eq 0 ]
    [ -f "$TEST_TMP/inbox_write_calls.log" ]
    grep -q "karo" "$TEST_TMP/inbox_write_calls.log"
    grep -q "report_completed" "$TEST_TMP/inbox_write_calls.log"
    grep -q "ashigaru1" "$TEST_TMP/inbox_write_calls.log"
}

@test "T-HOOK-005: error message triggers inbox_write to karo" {
    run_hook '{"stop_hook_active": false, "last_assistant_message": "ファイルが見つからない。エラーで中断する。"}'
    [ "$status" -eq 0 ]
    [ -f "$TEST_TMP/inbox_write_calls.log" ]
    grep -q "karo" "$TEST_TMP/inbox_write_calls.log"
    grep -q "error_report" "$TEST_TMP/inbox_write_calls.log"
}

@test "T-HOOK-006: neutral message does not trigger inbox_write" {
    run_hook '{"stop_hook_active": false, "last_assistant_message": "待機する。次の指示を待つ。"}'
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_TMP/inbox_write_calls.log" ]
}

@test "T-HOOK-007: empty last_assistant_message does not trigger inbox_write" {
    run_hook '{"stop_hook_active": false, "last_assistant_message": ""}'
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_TMP/inbox_write_calls.log" ]
}

@test "T-HOOK-008: unread inbox messages produce block JSON" {
    cat > "$TEST_TMP/queue/inbox/ashigaru1.yaml" << 'YAML'
messages:
  - id: msg_001
    from: karo
    type: task_assigned
    content: "新タスクだ"
    read: false
YAML
    run_hook '{"stop_hook_active": false, "last_assistant_message": ""}'
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"decision"'
    echo "$output" | grep -q '"block"'
}

@test "T-HOOK-009: no unread + completion message exits 0 with notification" {
    cat > "$TEST_TMP/queue/inbox/ashigaru1.yaml" << 'YAML'
messages:
  - id: msg_001
    from: karo
    type: task_assigned
    content: "古いメッセージ"
    read: true
YAML
    run_hook '{"stop_hook_active": false, "last_assistant_message": "タスク完了した。report YAML updated。"}'
    [ "$status" -eq 0 ]
    [ -z "$output" ] || ! echo "$output" | grep -q '"block"'
    [ -f "$TEST_TMP/inbox_write_calls.log" ]
    grep -q "report_completed" "$TEST_TMP/inbox_write_calls.log"
}

@test "T-HOOK-010: unread inbox + completion message blocks AND notifies" {
    cat > "$TEST_TMP/queue/inbox/ashigaru1.yaml" << 'YAML'
messages:
  - id: msg_001
    from: karo
    type: task_assigned
    content: "次のタスク"
    read: false
YAML
    run_hook '{"stop_hook_active": false, "last_assistant_message": "任務完了でござる。"}'
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"block"'
    [ -f "$TEST_TMP/inbox_write_calls.log" ]
    grep -q "report_completed" "$TEST_TMP/inbox_write_calls.log"
}

# ═══════════════════════════════════════════════════════════════
# 【cmd_226 / LIVENESS_TRACE_GATE_B】書き手（stop_hook_inbox.shのみ）
# ═══════════════════════════════════════════════════════════════

@test "T-B1: valid transcript_path is written verbatim as a single line to the liveness marker" {
    run_hook '{"stop_hook_active": false, "last_assistant_message": "", "transcript_path": "/fake/session123.jsonl"}'
    [ "$status" -eq 0 ]
    [ -f "$IDLE_FLAG_DIR/shogun_transcript_ashigaru1" ]
    [ "$(cat "$IDLE_FLAG_DIR/shogun_transcript_ashigaru1")" = "/fake/session123.jsonl" ]
}

@test "T-B2: empty stdin / invalid JSON / missing transcript_path exit 0 without creating or clobbering the marker" {
    printf '/pre/existing.jsonl\n' > "$IDLE_FLAG_DIR/shogun_transcript_ashigaru1"

    # transcript_path欠落
    run_hook '{"stop_hook_active": false, "last_assistant_message": ""}'
    [ "$status" -eq 0 ]
    [ "$(cat "$IDLE_FLAG_DIR/shogun_transcript_ashigaru1")" = "/pre/existing.jsonl" ]

    # 不正JSON
    __STOP_HOOK_SCRIPT_DIR="$TEST_TMP" __STOP_HOOK_AGENT_ID="ashigaru1" IDLE_FLAG_DIR="$IDLE_FLAG_DIR" \
    run bash "$HOOK_SCRIPT" <<< "not valid json"
    [ "$status" -eq 0 ]
    [ "$(cat "$IDLE_FLAG_DIR/shogun_transcript_ashigaru1")" = "/pre/existing.jsonl" ]

    # 空stdin
    __STOP_HOOK_SCRIPT_DIR="$TEST_TMP" __STOP_HOOK_AGENT_ID="ashigaru1" IDLE_FLAG_DIR="$IDLE_FLAG_DIR" \
    run bash "$HOOK_SCRIPT" < /dev/null
    [ "$status" -eq 0 ]
    [ "$(cat "$IDLE_FLAG_DIR/shogun_transcript_ashigaru1")" = "/pre/existing.jsonl" ]
}

@test "T-B3: marker mtime advances on each hook run even when transcript_path is unchanged (liveness proof)" {
    run_hook '{"stop_hook_active": false, "last_assistant_message": "", "transcript_path": "/fake/session123.jsonl"}'
    [ "$status" -eq 0 ]
    local marker="$IDLE_FLAG_DIR/shogun_transcript_ashigaru1"
    [ -f "$marker" ]
    touch -d "@$(( $(date +%s) - 100 ))" "$marker"
    local before after
    before=$(stat -c %Y "$marker")

    run_hook '{"stop_hook_active": false, "last_assistant_message": "", "transcript_path": "/fake/session123.jsonl"}'
    [ "$status" -eq 0 ]
    after=$(stat -c %Y "$marker")
    [ "$after" -gt "$before" ] || { echo "before=$before after=$after"; false; }
}

@test "T-B4: unresolved AGENT_ID writes no marker and still exits 0 (existing early-exit path preserved)" {
    run_hook_no_agent '{"stop_hook_active": false, "last_assistant_message": "", "transcript_path": "/fake/session123.jsonl"}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$(find "$IDLE_FLAG_DIR" -name 'shogun_transcript_*' 2>/dev/null)" ]
}
