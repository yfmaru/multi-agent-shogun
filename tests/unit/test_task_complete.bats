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
#
# TC-TCOMP-012/013 は queue/reports/gunshi_report.yaml の QC49-F1/F2
# （PR#49差し戻し）の固定。是正前・是正後の双方で走らせ、是正前では
# 検知できないこと（＝真の回帰テストであること）を軍師が実測確認済み。
#
#   TC-TCOMP-012 ロック競合時、保持者側のロックを壊さない(QC49-F1)
#   TC-TCOMP-013 _release_lock定義前に落ちてもBACKUPが残らない(QC49-F2)
#
# TC-TCOMP-MF/EXP/REG は cmd_190（軍師設計 gunshi_190_design.yaml）に基づく。
# 主対策=--message-file（シェルを経路から外す）、副対策=展開検知の警告
# （die にはせぬ）。test_plan節どおり最低9件。
#
#   TC-TCOMP-MF-001  --message-fileの内容がバッククォート等を含め逐語で届く
#   TC-TCOMP-MF-002  --messageと--message-fileの同時指定 → exit 2
#   TC-TCOMP-MF-003  どちらも未指定 → exit 2
#   TC-TCOMP-MF-004  --message-fileが読めぬ → exit 2・task YAML不変
#   TC-TCOMP-EXP-001 --message経路・cmdlineに本文が逐語で在る → 警告なし
#   TC-TCOMP-EXP-002 --message経路・シェル展開で本文が消えた → 警告1行(exit 0)
#   TC-TCOMP-EXP-003 --message-file経路では常に警告なし（安全な経路の番人）
#   TC-TCOMP-EXP-004 /procが読めぬ環境を模す → 黙って飛ばしexit 0
#   TC-TCOMP-REG-001 既存の--message呼び出し形は非破壊
#
# TC-TCOMP-DUP-* は cmd_220 subtask（cmd_221 F-5是正、軍師QC
# gunshi_qc_220_pr103.yamlのF-5）に基づく。従来の書き換え後検算
# `grep -cE "^  status: ${STATUS}$"`は「新しい値に一致する行が1件か」
# しか見ておらず、末尾等に別の値を持つ重複`status:`キーが残っていても
# 素通りする（YAMLパーサは後勝ちで古い方＝重複を採用する）。値を問わず
# `status:`キーの出現数そのものが1件であることを検算するよう是正した。
#
#   TC-TCOMP-DUP-001 変異試験: 是正前の検算（新値一致件数のみ）は
#                     重複statusキーを検知できず「成功」と誤報告する
#                     ことを、是正前コードの再現で確認する
#   TC-TCOMP-DUP-002 回帰試験: 是正後の本スクリプトは重複statusキーを
#                     検知しexit 2で落ちる。原ファイルは巻き戻され
#                     重複がそのまま残る（＝真の巻き戻し）
#   TC-TCOMP-DUP-003 正常系の回帰無し: 重複の無い通常のtask YAMLは
#                     従来どおりexit 0でstatusが書き換わる

# TC-TCOMP-PF-* は cmd_203 案C（軍師設計 gunshi_self_return_dependency_design.yaml
# 案C）に基づく。queue/shogun_to_karo.yamlのpending_followups（status: pending分
# のみ）を、完了出力へ強制的に割り込ませて表示する。
#
#   TC-TCOMP-PF-001 status: doneのfollowupは表示されない
#   TC-TCOMP-PF-002 status: pendingのfollowupはid/when/thenの形で表示される
#   TC-TCOMP-PF-003 隣接する別cmdのpending_followupsが混入しない
#   TC-TCOMP-PF-004 parent_cmdはあるがshogun_to_karo.yaml自体が無い → 無破壊
#   TC-TCOMP-PF-005 該当cmdにpending_followups自体が無い（cmd未存在含む） → 無出力
#   TC-TCOMP-PF-006 回帰: parent_cmdフィールドが無いtaskはkaro_fileが在っても無出力

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
    KARO_FILE="$FIXTURE_ROOT/queue/shogun_to_karo.yaml"

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

# TC-TCOMP-DUP-* 用: task:マッピング直下（2スペース字下げ）の`status:`
# キーを先頭付近と末尾付近の2箇所に持つ検体（cmd_220 F-5の実例と同型）。
# 両方とも初期値はassignedとする（貴殿自身が踏んだ実例と同じ形）。
write_task_dup_status() {
    cat > "$TASK_FILE" << 'YAML'
task:
  task_id: subtask_test
  status: assigned
  description: |
    紛らわしい字下げの決り文句:
    status: assigned
  status: assigned
YAML
}

# TC-TCOMP-DUP-001用: 是正前（F-5是正前）のtask_complete.shを、
# フィクスチャの現物コードから機械的に再構成する。「新しい値に一致する
# 行が1件か」しか見ない旧検算のみが残る形。行番号ではなく本文中の
# 是正コミットで追加した目印コメント・die文言で範囲指定するため、
# 本体側の周辺コードが動いても対象を見失わない。
build_pre_fix_script() {
    local dst="$1"
    awk '
      /^# 書き換え前点検:/ { skipA=1 }
      skipA { if ($0 ~ /（書き換え前点検・巻き戻し不要）/) skipA=0; next }
      /^# 書き換え後検算:/ { skipB=1 }
      skipB { if ($0 == "}") skipB=0; next }
      { print }
    ' "$FIXTURE_ROOT/scripts/task_complete.sh" > "$dst"
    chmod +x "$dst"
}

# TC-TCOMP-PF-* 用: parent_cmdフィールドを持つtask YAML。
write_task_with_parent() {
    local status="$1"
    local parent="$2"
    cat > "$TASK_FILE" << YAML
task:
  task_id: subtask_test
  parent_cmd: $parent
  description: |
    紛らわしい字下げの決り文句:
    status: assigned
  status: $status
YAML
}

# TC-TCOMP-PF-* 用: cmd_100（隣・前）/ cmd_203（本題。実物のcmd_203
# サンプルどおりt3_dispatch=done, cmd204_unblock=pending）/ cmd_300
# （隣・後）の3ブロックを持つ、実物のshogun_to_karo.yaml形式のfixture。
# 前後どちらの隣接cmdからも混入しないことを1ファイルで検証できる。
write_karo_file() {
    cat > "$KARO_FILE" << 'YAML'
  - id: cmd_100
    timestamp: "2026-01-01T00:00:00"
    pending_followups:
      - id: neighbor_pending
        when: "隣cmd(前)の条件"
        then: "隣cmd(前)のアクション"
        declared_at: "2026-01-01T00:00:00"
        declared_by: karo
        status: pending
  - id: cmd_203
    timestamp: "2026-01-01T00:00:00"
    pending_followups:
      - id: t3_dispatch
        when: "T2a〜T2dの4本すべてがdevelopへ着地"
        then: "T3を足軽へ発注する"
        declared_at: "2026-01-01T00:00:00"
        declared_by: karo
        status: done
      - id: cmd204_unblock
        when: "T3がdevelopへ着地"
        then: "cmd_204の着手条件が整う"
        declared_at: "2026-01-01T00:00:00"
        declared_by: karo
        status: pending
  - id: cmd_300
    timestamp: "2026-01-01T00:00:00"
    pending_followups:
      - id: another_neighbor
        when: "隣cmd(後)の条件"
        then: "隣cmd(後)のアクション"
        declared_at: "2026-01-01T00:00:00"
        declared_by: karo
        status: pending
YAML
}

# TC-TCOMP-PF-007/008(F1)用: 実物のcmd204_unblock同様、thenが二重引用符の
# 折り返し（複数行）で書かれたfixture。従来はwhen: /then: の1行しか
# 拾わず、途中で切れていた。
write_karo_file_multiline_then() {
    cat > "$KARO_FILE" << 'YAML'
  - id: cmd_203
    timestamp: "2026-01-01T00:00:00"
    pending_followups:
      - id: cmd204_unblock
        when: "T3がdevelopへ着地"
        then: "cmd_204の着手条件が
          整う。移設先を将軍が引き直し済み。
          軍師へ実装分割の相談をした上で足軽へ発注する"
        declared_at: "2026-01-01T00:00:00"
        declared_by: karo
        status: pending
YAML
}

# TC-TCOMP-PF-008(F1)用: thenがYAMLブロックスカラ（|）で書かれたfixture。
# 従来は「|」の一文字しか出ず情報量が零になっていた。
write_karo_file_block_scalar_then() {
    cat > "$KARO_FILE" << 'YAML'
  - id: cmd_203
    timestamp: "2026-01-01T00:00:00"
    pending_followups:
      - id: block_scalar_case
        when: "単一行の条件"
        then: |
          ブロックスカラの本文行
        declared_at: "2026-01-01T00:00:00"
        declared_by: karo
        status: pending
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

@test "TC-TCOMP-012: lock contention does not destroy the holder's lock (QC49-F1 fix)" {
    write_task assigned
    write_report done
    # 別プロセスがロックを保持中であることを模す（mkdirの原子性を先取り）
    mkdir "${TASK_FILE}.lock.d"
    run_tc --task-id subtask_test --to gunshi --message "hello" --agent ashigaru1
    [ "$status" -eq 2 ] || { echo "output: $output"; false; }
    [ -d "${TASK_FILE}.lock.d" ] || { echo "REGRESSION: 保持者のlock.dが消えた（QC49-F1）"; false; }
    grep -qE '^  status: assigned$' "$TASK_FILE" || { cat "$TASK_FILE"; false; }
}

@test "TC-TCOMP-013: crash before _release_lock is defined still cleans up BACKUP (QC49-F2 fix)" {
    write_task assigned
    write_report done
    # LOCK_DIR代入の直前でfalseを挟み、_release_lock定義前の異常終了を再現する
    local crash_script="$FIXTURE_ROOT/scripts/task_complete_crash.sh"
    awk '{ if ($0 == "LOCK_DIR=\"${TASK_FILE}.lock.d\"") print "false"; print }' \
        "$FIXTURE_ROOT/scripts/task_complete.sh" > "$crash_script"
    chmod +x "$crash_script"
    run bash "$crash_script" --task-id subtask_test --to gunshi --message "hello" --agent ashigaru1
    [ "$status" -ne 127 ] || { echo "output: $output (exit 127 = _release_lockがcommand not foundでtrap中断)"; false; }
    shopt -s nullglob
    local leftovers=("$FIXTURE_ROOT"/queue/tasks/*.bak.*)
    shopt -u nullglob
    [ "${#leftovers[@]}" -eq 0 ] || { echo "REGRESSION: BACKUPが残存: ${leftovers[*]}"; false; }
}

@test "TC-TCOMP-DUP-001: mutation check - the pre-fix status verification wrongly reports success on a duplicate status key" {
    write_task_dup_status
    write_report done
    local pre_fix_script="$FIXTURE_ROOT/scripts/task_complete_pre_fix.sh"
    build_pre_fix_script "$pre_fix_script"
    run bash "$pre_fix_script" --task-id subtask_test --to gunshi --message "hello" --agent ashigaru1
    [ "$status" -eq 0 ] || { echo "REGRESSION: 変異試験の前提が崩れている（是正前コードなのにexit 0でない）: output=$output"; false; }
    [ "$(grep -cE '^  status:' "$TASK_FILE")" -eq 2 ] || { echo "変異試験の前提が崩れている: 重複が再現できていない"; cat "$TASK_FILE"; false; }
    grep -qE '^  status: done$' "$TASK_FILE" || { cat "$TASK_FILE"; false; }
    grep -qE '^  status: assigned$' "$TASK_FILE" || { cat "$TASK_FILE"; false; }
}

@test "TC-TCOMP-DUP-002: regression - a duplicate status key is detected and exits 2, original file rolled back" {
    write_task_dup_status
    write_report done
    local before_content
    before_content="$(cat "$TASK_FILE")"
    run_tc --task-id subtask_test --to gunshi --message "hello" --agent ashigaru1
    [ "$status" -eq 2 ] || { echo "output: $output"; false; }
    [ "$(cat "$TASK_FILE")" = "$before_content" ] || { echo "REGRESSION: 巻き戻しが不完全"; cat "$TASK_FILE"; false; }
    [ "$(grep -cE '^  status: assigned$' "$TASK_FILE")" -eq 2 ] || { cat "$TASK_FILE"; false; }
    [ ! -s "$INBOX_LOG" ] || { cat "$INBOX_LOG"; false; }
}

@test "TC-TCOMP-DUP-003: no regression on a normal (non-duplicate) task YAML" {
    write_task assigned
    write_report done
    run_tc --task-id subtask_test --to gunshi --message "hello" --agent ashigaru1
    [ "$status" -eq 0 ] || { echo "output: $output"; false; }
    [ "$(grep -cE '^  status:' "$TASK_FILE")" -eq 1 ] || { cat "$TASK_FILE"; false; }
    grep -qE '^  status: done$' "$TASK_FILE" || { cat "$TASK_FILE"; false; }
    [ "$(wc -l < "$INBOX_LOG")" -eq 1 ] || { cat "$INBOX_LOG"; false; }
}

@test "TC-TCOMP-MF-001: --message-file passes the file's raw content through unchanged (backticks, \$(), \$VAR survive verbatim)" {
    write_task assigned
    write_report done
    local msg_file="$TEST_TMPDIR/msg.txt"
    printf '%s' 'raw: `date` and $(whoami) and $HOME must survive literally' > "$msg_file"
    run_tc --task-id subtask_test --to gunshi --message-file "$msg_file" --agent ashigaru1
    [ "$status" -eq 0 ] || { echo "output: $output"; false; }
    grep -qF 'raw: `date` and $(whoami) and $HOME must survive literally' "$INBOX_LOG" || { cat "$INBOX_LOG"; false; }
}

@test "TC-TCOMP-MF-002: --message and --message-file together exits 2, inbox untouched" {
    write_task assigned
    write_report done
    local msg_file="$TEST_TMPDIR/msg.txt"
    printf '%s' 'irrelevant' > "$msg_file"
    run_tc --task-id subtask_test --to gunshi --message "hello" --message-file "$msg_file" --agent ashigaru1
    [ "$status" -eq 2 ] || { echo "output: $output"; false; }
    [ ! -s "$INBOX_LOG" ] || { cat "$INBOX_LOG"; false; }
}

@test "TC-TCOMP-MF-003: neither --message nor --message-file exits 2" {
    write_task assigned
    write_report done
    run_tc --task-id subtask_test --to gunshi --agent ashigaru1
    [ "$status" -eq 2 ] || { echo "output: $output"; false; }
    [ ! -s "$INBOX_LOG" ] || { cat "$INBOX_LOG"; false; }
}

@test "TC-TCOMP-MF-004: unreadable --message-file path exits 2, task YAML unmutated" {
    write_task assigned
    write_report done
    run_tc --task-id subtask_test --to gunshi --message-file "$TEST_TMPDIR/does_not_exist.txt" --agent ashigaru1
    [ "$status" -eq 2 ] || { echo "output: $output"; false; }
    grep -qE '^  status: assigned$' "$TASK_FILE" || { cat "$TASK_FILE"; false; }
    [ ! -s "$INBOX_LOG" ] || { cat "$INBOX_LOG"; false; }
}

@test "TC-TCOMP-EXP-001: --message path emits no warning when the caller's raw cmdline contains the message verbatim" {
    write_task assigned
    write_report done
    # 末尾の`; :`は必須: bashはサブシェル内の末尾コマンドをexecで
    # 自身に置き換える最適化を行うため、これが無いとtask_complete.shの
    # 実プロセスが1階層祖父母側($PPID)へ繰り上がり、本テストの前提
    # （task_complete.shの$PPIDがこの-cプロセス自身になること）が崩れる
    local placeholder='MESSAGE="hello world literal"; bash "__ROOT__/scripts/task_complete.sh" --task-id subtask_test --to gunshi --message "$MESSAGE" --agent ashigaru1; :'
    local inner="${placeholder//__ROOT__/$FIXTURE_ROOT}"
    run bash -c "$inner"
    [ "$status" -eq 0 ] || { echo "output: $output"; false; }
    [[ "$output" != *"警告"* ]] || { echo "output: $output"; false; }
    [ "$(wc -l < "$INBOX_LOG")" -eq 1 ] || { cat "$INBOX_LOG"; false; }
}

@test "TC-TCOMP-EXP-002: --message path warns (but still exits 0) when the caller's shell expanded the text away from the raw cmdline" {
    write_task assigned
    write_report done
    # 末尾の`; :`はEXP-001と同じ理由で必須（bashのexec置き換え最適化対策）
    local placeholder='bash "__ROOT__/scripts/task_complete.sh" --task-id subtask_test --to gunshi --message "A `echo MANGLED` B" --agent ashigaru1; :'
    local inner="${placeholder//__ROOT__/$FIXTURE_ROOT}"
    run bash -c "$inner"
    [ "$status" -eq 0 ] || { echo "output: $output"; false; }
    if [ "$(uname -s)" = "Darwin" ]; then
        # macOSにはそもそも/procが無く、展開検知の仕組み自体がEXP-004と
        # 同じ理由で原理的に働かない。ゆえに警告は出ない（この非対称性
        # 自体がmacOSでの正しい挙動であり、失敗ではない）
        [[ "$output" != *"警告"* ]] || { echo "output: $output"; false; }
    else
        [[ "$output" == *"警告"* ]] || { echo "output: $output"; false; }
    fi
    [ "$(wc -l < "$INBOX_LOG")" -eq 1 ] || { cat "$INBOX_LOG"; false; }
}

@test "TC-TCOMP-EXP-003: --message-file path never emits the expansion warning, even with a cmdline mismatch" {
    write_task assigned
    write_report done
    local msg_file="$TEST_TMPDIR/msg.txt"
    printf '%s' 'content that will never appear on any cmdline verbatim xyz789' > "$msg_file"
    run_tc --task-id subtask_test --to gunshi --message-file "$msg_file" --agent ashigaru1
    [ "$status" -eq 0 ] || { echo "output: $output"; false; }
    [[ "$output" != *"警告"* ]] || { echo "output: $output"; false; }
}

@test "TC-TCOMP-EXP-004: no readable /proc entry for the parent silently skips the check (exit 0, no warning)" {
    write_task assigned
    write_report done
    if [ "$(uname -s)" = "Darwin" ]; then
        # macOSにはそもそも/procが無く、本テストが検証したい状態が
        # 最初から自然に成立している
        run_tc --task-id subtask_test --to gunshi --message "hello" --agent ashigaru1
    elif command -v unshare >/dev/null 2>&1 && unshare -rm -- true >/dev/null 2>&1; then
        # Linux: 非特権 user+mount namespace で /proc を空tmpfsへ置き換え、
        # 「/procが読めぬ」状態を人為的に再現する
        local placeholder='mount -t tmpfs none /proc; bash "__ROOT__/scripts/task_complete.sh" --task-id subtask_test --to gunshi --message "hello" --agent ashigaru1; :'
        local inner="${placeholder//__ROOT__/$FIXTURE_ROOT}"
        run unshare -rm -- bash -c "$inner"
    else
        # ubuntu-latest実測(cmd_190 PR#56): AppArmorの
        # unprivileged_userns restrictionによりunshare -rm自体が拒否される
        # 環境が実在する。--message-fileが原理的に安全という主張はここに
        # 依存しないため、CIのSKIP=FAILゲート対象外として明示的に許容する
        skip "user namespaceで/procを隠せず、/procが無い状況を再現できぬ (CI environment: AppArmor unprivileged userns restriction)"
    fi
    [ "$status" -eq 0 ] || { echo "output: $output"; false; }
    [[ "$output" != *"警告"* ]] || { echo "output: $output"; false; }
}

@test "TC-TCOMP-REG-001: existing --message call form is unaffected by the new --message-file path" {
    write_task assigned
    write_report done
    run_tc --task-id subtask_test --to gunshi --message "plain handoff text" --agent ashigaru1
    [ "$status" -eq 0 ] || { echo "output: $output"; false; }
    grep -qE '^  status: done$' "$TASK_FILE" || { cat "$TASK_FILE"; false; }
    grep -q "gunshi plain handoff text report_received ashigaru1" "$INBOX_LOG" || { cat "$INBOX_LOG"; false; }
}

@test "TC-TCOMP-PF-001: a pending_followups item with status done is not surfaced" {
    write_task_with_parent assigned cmd_203
    write_report done
    write_karo_file
    run_tc --task-id subtask_test --to karo --message "hello" --agent ashigaru1
    [ "$status" -eq 0 ] || { echo "output: $output"; false; }
    [[ "$output" != *"t3_dispatch"* ]] || { echo "output: $output"; false; }
}

@test "TC-TCOMP-PF-002: a pending_followups item with status pending is surfaced as id/when/then" {
    write_task_with_parent assigned cmd_203
    write_report done
    write_karo_file
    run_tc --task-id subtask_test --to karo --message "hello" --agent ashigaru1
    [ "$status" -eq 0 ] || { echo "output: $output"; false; }
    [[ "$output" == *"pending_followups"* ]] || { echo "output: $output"; false; }
    [[ "$output" == *"cmd204_unblock: T3がdevelopへ着地 → cmd_204の着手条件が整う"* ]] || { echo "output: $output"; false; }
}

@test "TC-TCOMP-PF-003: pending_followups belonging to neighboring cmd blocks (before and after) are not leaked" {
    write_task_with_parent assigned cmd_203
    write_report done
    write_karo_file
    run_tc --task-id subtask_test --to karo --message "hello" --agent ashigaru1
    [ "$status" -eq 0 ] || { echo "output: $output"; false; }
    [[ "$output" != *"neighbor_pending"* ]] || { echo "output: $output"; false; }
    [[ "$output" != *"another_neighbor"* ]] || { echo "output: $output"; false; }
}

@test "TC-TCOMP-PF-004: parent_cmd is set but shogun_to_karo.yaml itself is absent - completion is unaffected" {
    write_task_with_parent assigned cmd_203
    write_report done
    rm -f "$KARO_FILE"
    run_tc --task-id subtask_test --to karo --message "hello" --agent ashigaru1
    [ "$status" -eq 0 ] || { echo "output: $output"; false; }
    [[ "$output" != *"pending_followups"* ]] || { echo "output: $output"; false; }
    grep -qE '^  status: done$' "$TASK_FILE" || { cat "$TASK_FILE"; false; }
}

@test "TC-TCOMP-PF-005: target cmd has no pending_followups (cmd not present in karo_file at all) - no output" {
    write_task_with_parent assigned cmd_999
    write_report done
    write_karo_file
    run_tc --task-id subtask_test --to karo --message "hello" --agent ashigaru1
    [ "$status" -eq 0 ] || { echo "output: $output"; false; }
    [[ "$output" != *"pending_followups"* ]] || { echo "output: $output"; false; }
}

@test "TC-TCOMP-PF-006: regression - a task with no parent_cmd field emits no pending_followups output even if karo_file exists" {
    write_task done
    write_report done
    write_karo_file
    run_tc --task-id subtask_test --to gunshi --message "hello" --agent ashigaru1
    [ "$status" -eq 0 ] || { echo "output: $output"; false; }
    [[ "$output" != *"pending_followups"* ]] || { echo "output: $output"; false; }
}

@test "TC-TCOMP-PF-007: fix(F1) - a multi-line double-quoted 'then' is folded whole, not truncated at the first line" {
    write_task_with_parent assigned cmd_203
    write_report done
    write_karo_file_multiline_then
    run_tc --task-id subtask_test --to karo --message "hello" --agent ashigaru1
    [ "$status" -eq 0 ] || { echo "output: $output"; false; }
    [[ "$output" == *"cmd204_unblock: T3がdevelopへ着地 → cmd_204の着手条件が 整う。移設先を将軍が引き直し済み。 軍師へ実装分割の相談をした上で足軽へ発注する"* ]] \
        || { echo "output: $output"; false; }
    [[ "$output" != *'"'* ]] || { echo "REGRESSION: 閉じ二重引用符が漏れている: $output"; false; }
}

@test "TC-TCOMP-PF-008: fix(F1) - a block-scalar 'then' (|) surfaces its content, not a bare pipe character" {
    write_task_with_parent assigned cmd_203
    write_report done
    write_karo_file_block_scalar_then
    run_tc --task-id subtask_test --to karo --message "hello" --agent ashigaru1
    [ "$status" -eq 0 ] || { echo "output: $output"; false; }
    [[ "$output" == *"block_scalar_case: 単一行の条件 → ブロックスカラの本文行"* ]] || { echo "output: $output"; false; }
    [[ "$output" != *"→ |"* ]] || { echo "REGRESSION: ブロックスカラの中身が「|」一文字に潰れている: $output"; false; }
}

@test "TC-TCOMP-PF-009: fix(F2) - an existing but unreadable karo_file does not abort completion (still exit 0, status done, inbox sent)" {
    write_task_with_parent assigned cmd_203
    write_report done
    write_karo_file
    chmod 000 "$KARO_FILE"
    run_tc --task-id subtask_test --to karo --message "hello" --agent ashigaru1
    chmod 644 "$KARO_FILE"
    [ "$status" -eq 0 ] || { echo "REGRESSION: 読めないkaro_fileで異常終了した: output=$output"; false; }
    grep -qE '^  status: done$' "$TASK_FILE" || { cat "$TASK_FILE"; false; }
    [ "$(wc -l < "$INBOX_LOG")" -eq 1 ] || { cat "$INBOX_LOG"; false; }
    [[ "$output" == *"完了: status=done"* ]] || { echo "output: $output"; false; }
}
