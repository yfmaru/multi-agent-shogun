#!/usr/bin/env bats
# test_task_complete.bats — scripts/task_complete.sh のユニットテスト（cmd_188前半）
#
# 実行方式: 実スクリプト scripts/task_complete.sh をフィクスチャ root へ
# コピーして実行する。task_complete.sh はトップレベルで即 exit する
# 単一エントリポイントであり（test_baton_watchdog.bats のように関数
# 分割されていない）、ソースして関数だけ読み込む方式は使えないため。
# コピー先で実行することで、スクリプト自身の
# `ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"` が
# フィクスチャを指すようになる（本物のqueue/へは一切触れない）。
#
# inbox_write.sh はフィクスチャ内のスタブへ差し替える（cmd_181 OBS-181-6の
# 教訓どおり、ログへの echo のみでなく、呼び出し引数の記録と失敗モード
# 再現の両方を持たせる）。
#
# TC-TCOMP-001〜011 は queue/reports/gunshi_report.yaml design_front_half
# 節 front_half_tests の記述どおり。
#
#   TC-TCOMP-001 正常系: status が done になり、宛先 inbox へ1件増える
#   TC-TCOMP-002 報告未着(P6) → exit 3・status不変・inbox不変
#   TC-TCOMP-003 task_id不一致 → exit 2・両者不変
#   TC-TCOMP-004 inbox_write失敗 → exit 4・statusが元の値へ巻き戻り
#   TC-TCOMP-005 自己宛(--to == agent) → exit 2・両者不変
#   TC-TCOMP-006 冪等: 既にdoneの状態で再実行 → exit 0・inbox +1
#   TC-TCOMP-007 messageに三重引用符 → exit 2・inbox不変
#   TC-TCOMP-008 --agent明示時はtmuxを一切呼ばない
#   TC-TCOMP-009 --dry-runでstatusもinboxも変わらない
#   TC-TCOMP-010 回帰: descriptionのblock scalar内の「status:」相当行は
#                書き換わらない。書き換わるのはtask:直下の1行のみ
#   TC-TCOMP-011 --status blockedでも同じ規律で動く

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
    TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/task_complete_test.XXXXXX")"
    FIXTURE_ROOT="$TEST_TMPDIR/fixture"
    mkdir -p "$FIXTURE_ROOT/queue/tasks" "$FIXTURE_ROOT/queue/reports" "$FIXTURE_ROOT/scripts"

    cp "$PROJECT_ROOT/scripts/task_complete.sh" "$FIXTURE_ROOT/scripts/task_complete.sh"
    chmod +x "$FIXTURE_ROOT/scripts/task_complete.sh"

    export INBOX_LOG="$TEST_TMPDIR/inbox_calls.log"
    > "$INBOX_LOG"
    export INBOX_WRITE_EXIT=0
    cat > "$FIXTURE_ROOT/scripts/inbox_write.sh" << 'STUB'
#!/usr/bin/env bash
echo "$*" >> "$INBOX_LOG"
exit "${INBOX_WRITE_EXIT:-0}"
STUB
    chmod +x "$FIXTURE_ROOT/scripts/inbox_write.sh"

    export TMUX_CALL_LOG="$TEST_TMPDIR/tmux_calls.log"
    > "$TMUX_CALL_LOG"
    TMUX_STUB_DIR="$TEST_TMPDIR/tmux_stub"
    mkdir -p "$TMUX_STUB_DIR"
    cat > "$TMUX_STUB_DIR/tmux" << STUB2
#!/usr/bin/env bash
echo "\$*" >> "$TMUX_CALL_LOG"
echo "SHOULD_NOT_BE_USED"
STUB2
    chmod +x "$TMUX_STUB_DIR/tmux"
    export PATH="$TMUX_STUB_DIR:$PATH"

    TASK_FILE="$FIXTURE_ROOT/queue/tasks/ashigaru1.yaml"
    REPORT_FILE="$FIXTURE_ROOT/queue/reports/ashigaru1_report.yaml"

    write_task done
    write_report done
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# task: 直下の status に加え、description のblock scalar内に紛らわしい
# 4スペース字下げの「status: assigned」相当行を常に含める（TC-TCOMP-010の
# 回帰観点を全テストで恒常的に踏ませるため）。実際のtask YAML
# （queue/tasks/ashigaru1.yaml等）では description が status より
# **前**に来る（task_id → ... → description → ... → status の順）ため、
# その順序を再現する。順序を逆にすると「最初に一致した行を置換する」
# awkの挙動により、アンカーの緩みがdescription側の決り文句より先に
# 本物のstatus行へ一致してしまい、回帰を検知できなくなる。
write_task() {
    local status="$1"
    cat > "$TASK_FILE" << YAML
task:
  task_id: subtask_test
  description: |
    紛らわしい字下げの決り文句:
    status: assigned
  status: $status
YAML
}

write_report() {
    local status="$1"
    local task_id="${2:-subtask_test}"
    cat > "$REPORT_FILE" << YAML
task_id: $task_id
status: $status
YAML
}

run_tc() {
    run bash "$FIXTURE_ROOT/scripts/task_complete.sh" "$@"
}

@test "TC-TCOMP-001: normal path - status becomes done and target inbox gains one message" {
    write_task assigned
    write_report done
    run_tc --task-id subtask_test --to gunshi --message "hello" --agent ashigaru1
    [ "$status" -eq 0 ] || { echo "output: $output"; false; }
    grep -qE '^  status: done$' "$TASK_FILE" || { cat "$TASK_FILE"; false; }
    grep -qE '^  completed_at: ' "$TASK_FILE" || { cat "$TASK_FILE"; false; }
    [ "$(wc -l < "$INBOX_LOG")" -eq 1 ] || { cat "$INBOX_LOG"; false; }
    grep -q "gunshi hello report_received ashigaru1" "$INBOX_LOG" || { cat "$INBOX_LOG"; false; }
}

@test "TC-TCOMP-002: missing report blocks with exit 3, status and inbox untouched" {
    write_task assigned
    rm -f "$REPORT_FILE"
    run_tc --task-id subtask_test --to gunshi --message "hello" --agent ashigaru1
    [ "$status" -eq 3 ] || { echo "output: $output"; false; }
    grep -qE '^  status: assigned$' "$TASK_FILE" || { cat "$TASK_FILE"; false; }
    [ ! -s "$INBOX_LOG" ] || { cat "$INBOX_LOG"; false; }
}

@test "TC-TCOMP-003: task_id mismatch exits 2, neither file mutated" {
    write_task assigned
    write_report done
    run_tc --task-id subtask_wrong --to gunshi --message "hello" --agent ashigaru1
    [ "$status" -eq 2 ] || { echo "output: $output"; false; }
    grep -qE '^  status: assigned$' "$TASK_FILE" || { cat "$TASK_FILE"; false; }
    [ ! -s "$INBOX_LOG" ] || { cat "$INBOX_LOG"; false; }
}

@test "TC-TCOMP-004: inbox_write failure rolls status back and exits 4" {
    write_task assigned
    write_report done
    export INBOX_WRITE_EXIT=1
    run_tc --task-id subtask_test --to gunshi --message "hello" --agent ashigaru1
    [ "$status" -eq 4 ] || { echo "output: $output"; false; }
    grep -qE '^  status: assigned$' "$TASK_FILE" || { cat "$TASK_FILE"; false; }
}

@test "TC-TCOMP-005: self-addressed handoff exits 2, neither file mutated" {
    write_task assigned
    write_report done
    run_tc --task-id subtask_test --to ashigaru1 --message "hello" --agent ashigaru1
    [ "$status" -eq 2 ] || { echo "output: $output"; false; }
    grep -qE '^  status: assigned$' "$TASK_FILE" || { cat "$TASK_FILE"; false; }
    [ ! -s "$INBOX_LOG" ] || { cat "$INBOX_LOG"; false; }
}

@test "TC-TCOMP-006: idempotent rerun on already-done task still sends handoff" {
    write_task done
    write_report done
    run_tc --task-id subtask_test --to gunshi --message "hello" --agent ashigaru1
    [ "$status" -eq 0 ] || { echo "output: $output"; false; }
    [ "$(grep -cE '^  status: done$' "$TASK_FILE")" -eq 1 ] || { cat "$TASK_FILE"; false; }
    [ "$(wc -l < "$INBOX_LOG")" -eq 1 ] || { cat "$INBOX_LOG"; false; }
}

@test "TC-TCOMP-007: triple-quote in message exits 2, inbox untouched" {
    write_task assigned
    write_report done
    run_tc --task-id subtask_test --to gunshi --message "bad '''quote" --agent ashigaru1
    [ "$status" -eq 2 ] || { echo "output: $output"; false; }
    [ ! -s "$INBOX_LOG" ] || { cat "$INBOX_LOG"; false; }
}

@test "TC-TCOMP-008: explicit --agent never invokes tmux" {
    write_task assigned
    write_report done
    run_tc --task-id subtask_test --to gunshi --message "hello" --agent ashigaru1
    [ "$status" -eq 0 ] || { echo "output: $output"; false; }
    [ ! -s "$TMUX_CALL_LOG" ] || { cat "$TMUX_CALL_LOG"; false; }
}

@test "TC-TCOMP-009: --dry-run mutates neither status nor inbox" {
    write_task assigned
    write_report done
    run_tc --task-id subtask_test --to gunshi --message "hello" --agent ashigaru1 --dry-run
    [ "$status" -eq 0 ] || { echo "output: $output"; false; }
    grep -qE '^  status: assigned$' "$TASK_FILE" || { cat "$TASK_FILE"; false; }
    [ ! -s "$INBOX_LOG" ] || { cat "$INBOX_LOG"; false; }
}

@test "TC-TCOMP-010: regression - only the task-level status line is rewritten, not the description decoy" {
    write_task assigned
    write_report done
    run_tc --task-id subtask_test --to gunshi --message "hello" --agent ashigaru1
    [ "$status" -eq 0 ] || { echo "output: $output"; false; }
    [ "$(grep -cE '^  status: done$' "$TASK_FILE")" -eq 1 ] || { cat "$TASK_FILE"; false; }
    grep -qxF '    status: assigned' "$TASK_FILE" || { cat "$TASK_FILE"; false; }
}

@test "TC-TCOMP-011: --status blocked follows the same discipline as done" {
    write_task assigned
    write_report blocked
    run_tc --task-id subtask_test --to karo --message "blocked, need decision" --agent ashigaru1 --status blocked
    [ "$status" -eq 0 ] || { echo "output: $output"; false; }
    grep -qE '^  status: blocked$' "$TASK_FILE" || { cat "$TASK_FILE"; false; }
    [ "$(wc -l < "$INBOX_LOG")" -eq 1 ] || { cat "$INBOX_LOG"; false; }
}
