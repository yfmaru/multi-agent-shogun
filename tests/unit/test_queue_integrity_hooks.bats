#!/usr/bin/env bats
# test_queue_integrity_hooks.bats — cmd_211 P-211-B unit tests
#
# Covers scripts/queue_integrity_snapshot.sh (PreToolUse),
# scripts/queue_integrity_post_check.sh (PostToolUse) and
# scripts/prune_snapshots.sh. Calls the REAL production scripts with
# env var overrides (__QUEUE_INTEGRITY_SCRIPT_DIR / QUEUE_INTEGRITY_*),
# following the same pattern as test_stop_hook.bats.
#
# テスト構成:
#   T-QIH-001: 対象パスへのEdit相当 → PreToolUseがスナップショットを作成
#   T-QIH-002: 対象外パス → PreToolUseは何もしない（スナップショット無し）
#   T-QIH-003: file_path欠落JSON → PreToolUseは何もしない（exit 0）
#   T-QIH-004: N世代超過 → 最古のスナップショットが削除される
#   T-QIH-005: 健全ファイル → PostToolUseはinbox_writeを呼ばない・exit 0
#   T-QIH-006: 破損ファイル（重複キー）→ PostToolUseがinbox_writeを呼ぶ
#   T-QIH-007: 破損ファイルでも対象外パス → PostToolUseは何もしない
#   T-QIH-008: prune_snapshots.sh単体 → keep未満なら削除しない
#   T-QIH-009: prune_snapshots.sh単体 → keep超過分を最古から削除する

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SNAPSHOT_HOOK="$SCRIPT_DIR/scripts/queue_integrity_snapshot.sh"
POST_HOOK="$SCRIPT_DIR/scripts/queue_integrity_post_check.sh"
PRUNE_SCRIPT="$SCRIPT_DIR/scripts/prune_snapshots.sh"

setup() {
    TEST_TMP="$(mktemp -d)"
    mkdir -p "$TEST_TMP/scripts" "$TEST_TMP/queue"

    # Copy the real collaborator scripts so __QUEUE_INTEGRITY_SCRIPT_DIR
    # resolves them, but mock inbox_write.sh to capture calls instead of
    # touching any real inbox.
    cp "$SCRIPT_DIR/scripts/prune_snapshots.sh" "$TEST_TMP/scripts/"
    cp "$SCRIPT_DIR/scripts/queue_integrity_check.sh" "$TEST_TMP/scripts/"
    cp "$SCRIPT_DIR/scripts/queue_integrity_check.py" "$TEST_TMP/scripts/"

    # Reuse the real repo's PyYAML-equipped venv (set up once in CI) instead
    # of falling back to the bare `python3` on PATH, whose PyYAML
    # availability varies by runner (present on ubuntu-latest, absent on
    # macos-latest). Same fix as test_queue_integrity_check.bats.
    if [ -d "$SCRIPT_DIR/.venv" ]; then
        ln -s "$SCRIPT_DIR/.venv" "$TEST_TMP/.venv"
    fi

    cat > "$TEST_TMP/scripts/inbox_write.sh" << 'MOCK'
#!/bin/bash
echo "$@" >> "$(dirname "$0")/../inbox_write_calls.log"
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    if [ "${args[$i]}" = "--content-file" ]; then
        cat "${args[$((i + 1))]}" >> "$(dirname "$0")/../inbox_write_body.log"
    fi
done
MOCK
    chmod +x "$TEST_TMP/scripts/inbox_write.sh"

    TARGET="$TEST_TMP/queue/shogun_to_karo.yaml"
    cat > "$TARGET" << 'YAML'
commands:
  - id: cmd_A
    status: pending
    timestamp: "2026-01-01T00:00:00+09:00"
  - id: cmd_B
    status: done
    timestamp: "2026-01-02T00:00:00+09:00"
YAML
}

teardown() {
    rm -rf "$TEST_TMP"
}

json_for_path() {
    python3 -c "import json,sys; print(json.dumps({'hook_event_name': sys.argv[1], 'tool_name': 'Edit', 'tool_input': {'file_path': sys.argv[2]}}))" "$1" "$2"
}

run_snapshot_hook() {
    local file_path="$1"
    local keep="${2:-20}"
    __QUEUE_INTEGRITY_SCRIPT_DIR="$TEST_TMP/scripts" \
    QUEUE_INTEGRITY_TARGET_PATH="$TARGET" \
    QUEUE_INTEGRITY_SNAPSHOT_KEEP="$keep" \
    run bash "$SNAPSHOT_HOOK" <<< "$(json_for_path PreToolUse "$file_path")"
}

run_post_hook() {
    local file_path="$1"
    __QUEUE_INTEGRITY_SCRIPT_DIR="$TEST_TMP/scripts" \
    QUEUE_INTEGRITY_TARGET_PATH="$TARGET" \
    run bash "$POST_HOOK" <<< "$(json_for_path PostToolUse "$file_path")"
}

@test "T-QIH-001: target path edit creates a snapshot" {
    run_snapshot_hook "$TARGET"
    [ "$status" -eq 0 ]
    [ -d "$TEST_TMP/queue/.snapshots" ]
    count=$(ls "$TEST_TMP/queue/.snapshots"/shogun_to_karo.*.yaml 2>/dev/null | wc -l)
    [ "$count" -eq 1 ]
    diff "$TARGET" "$TEST_TMP/queue/.snapshots"/shogun_to_karo.*.yaml
}

@test "T-QIH-002: non-target path is a no-op, no snapshot dir created" {
    OTHER="$TEST_TMP/queue/some_other_file.yaml"
    echo "unrelated: true" > "$OTHER"
    run_snapshot_hook "$OTHER"
    [ "$status" -eq 0 ]
    [ ! -d "$TEST_TMP/queue/.snapshots" ]
}

@test "T-QIH-003: missing file_path in hook JSON is a no-op" {
    __QUEUE_INTEGRITY_SCRIPT_DIR="$TEST_TMP/scripts" \
    QUEUE_INTEGRITY_TARGET_PATH="$TARGET" \
    run bash "$SNAPSHOT_HOOK" <<< '{"hook_event_name": "PreToolUse", "tool_name": "Edit", "tool_input": {}}'
    [ "$status" -eq 0 ]
    [ ! -d "$TEST_TMP/queue/.snapshots" ]
}

@test "T-QIH-004: snapshots beyond N generations get pruned, oldest first" {
    mkdir -p "$TEST_TMP/queue/.snapshots"
    for i in 1 2 3 4 5; do
        printf 'gen %s\n' "$i" > "$TEST_TMP/queue/.snapshots/shogun_to_karo.2026010${i}T000000Z.yaml"
    done
    run_snapshot_hook "$TARGET" 3
    [ "$status" -eq 0 ]
    remaining=$(ls "$TEST_TMP/queue/.snapshots"/shogun_to_karo.*.yaml | sort)
    count=$(echo "$remaining" | wc -l)
    [ "$count" -eq 3 ]
    # The two oldest pre-existing generations (1, 2) must be gone.
    ! echo "$remaining" | grep -q "20260101T000000Z"
    ! echo "$remaining" | grep -q "20260102T000000Z"
    # The newest pre-existing ones plus the just-created snapshot survive.
    echo "$remaining" | grep -q "20260104T000000Z"
    echo "$remaining" | grep -q "20260105T000000Z"
}

@test "T-QIH-005: healthy target file triggers no inbox_write call" {
    run_post_hook "$TARGET"
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_TMP/inbox_write_calls.log" ]
}

@test "T-QIH-006: corrupted target file (M-1 duplicate key) delivers via inbox_write" {
    # Simulate M-1: drop the "- id: cmd_B" heading line so cmd_B's body
    # merges into cmd_A's mapping (duplicate keys, valid YAML).
    cat > "$TARGET" << 'YAML'
commands:
  - id: cmd_A
    status: pending
    timestamp: "2026-01-01T00:00:00+09:00"
    status: done
    timestamp: "2026-01-02T00:00:00+09:00"
YAML
    run_post_hook "$TARGET"
    [ "$status" -eq 0 ]
    [ -f "$TEST_TMP/inbox_write_calls.log" ] || { echo "no inbox_write call recorded"; false; }
    grep -q -- "--to karo" "$TEST_TMP/inbox_write_calls.log" || { cat "$TEST_TMP/inbox_write_calls.log"; false; }
    grep -q -- "--from queue_integrity_check" "$TEST_TMP/inbox_write_calls.log" || { cat "$TEST_TMP/inbox_write_calls.log"; false; }
    [ -f "$TEST_TMP/inbox_write_body.log" ] || { echo "no inbox_write body captured"; false; }
    grep -q "QUEUE INTEGRITY CHECK FAILED" "$TEST_TMP/inbox_write_body.log" || { cat "$TEST_TMP/inbox_write_body.log"; false; }
    grep -q "C-1 duplicate key" "$TEST_TMP/inbox_write_body.log" || { cat "$TEST_TMP/inbox_write_body.log"; false; }
}

@test "T-QIH-007: corrupted file at a non-target path triggers nothing" {
    OTHER="$TEST_TMP/queue/some_other_file.yaml"
    cat > "$OTHER" << 'YAML'
commands:
  - id: cmd_A
    status: pending
    status: done
YAML
    run_post_hook "$OTHER"
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_TMP/inbox_write_calls.log" ]
}

@test "T-QIH-008: prune_snapshots.sh leaves files alone when under the keep limit" {
    mkdir -p "$TEST_TMP/queue/.snapshots"
    for i in 1 2; do
        printf 'gen %s\n' "$i" > "$TEST_TMP/queue/.snapshots/shogun_to_karo.2026010${i}T000000Z.yaml"
    done
    run bash "$PRUNE_SCRIPT" "$TEST_TMP/queue/.snapshots" "shogun_to_karo" 20
    [ "$status" -eq 0 ]
    count=$(ls "$TEST_TMP/queue/.snapshots"/shogun_to_karo.*.yaml | wc -l)
    [ "$count" -eq 2 ]
}

@test "T-QIH-009: prune_snapshots.sh deletes the oldest excess generations" {
    mkdir -p "$TEST_TMP/queue/.snapshots"
    for i in 1 2 3 4 5; do
        printf 'gen %s\n' "$i" > "$TEST_TMP/queue/.snapshots/shogun_to_karo.2026010${i}T000000Z.yaml"
    done
    run bash "$PRUNE_SCRIPT" "$TEST_TMP/queue/.snapshots" "shogun_to_karo" 2
    [ "$status" -eq 0 ]
    remaining=$(ls "$TEST_TMP/queue/.snapshots"/shogun_to_karo.*.yaml | sort)
    count=$(echo "$remaining" | wc -l)
    [ "$count" -eq 2 ]
    echo "$remaining" | grep -q "20260104T000000Z"
    echo "$remaining" | grep -q "20260105T000000Z"
}
