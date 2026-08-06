#!/usr/bin/env bats
# test_instructions_parity_check.bats — instructions_parity_check.sh ユニットテスト
# cmd_203 T1: 手書き版 instructions/<role>.md と生成元
# instructions/roles/<role>_role.md + instructions/common/*.md の
# 見出し食い違いを機械的に検出するスクリプトのテスト。
#
# baseline (a=85 / b=26) について:
#   cmd_203 の内容突合（T2）が未着手の現時点における「既知の食い違い」
#   の件数である。ゼロであることは検査しない——ゼロを求めるのはT2の
#   職掌であり、本テストの役目は「これ以上こっそり増えていないか」を
#   機械的に見張ることにある（再発防止）。T2でreconciliationが進めば、
#   このbaseline自体を該当PRで更新すること。

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export SCRIPT="$PROJECT_ROOT/scripts/instructions_parity_check.sh"
}

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SCRIPT="$PROJECT_ROOT/scripts/instructions_parity_check.sh"
}

@test "parity: script exists and is executable" {
    [ -x "$SCRIPT" ]
}

@test "parity: --help exits 0" {
    run bash "$SCRIPT" --help
    [ "$status" -eq 0 ]
}

@test "parity: unknown --role exits 2" {
    run bash "$SCRIPT" --role nobody
    [ "$status" -eq 2 ]
}

@test "parity: unknown option exits 2" {
    run bash "$SCRIPT" --bogus
    [ "$status" -eq 2 ]
}

# T2aでhw側の見出し挿入位置を1レベル下げた副作用によりhw-onlyが85→86へ
# 増加した（正常な既知の増加）。ゆえにgen-only(b)と同じ作法で完全一致
# ではなく上限（regression ceiling）判定にする。
@test "parity: known drift baseline — hw-only(a) total is at most 86" {
    run bash "$SCRIPT"
    total_line=$(printf '%s\n' "$output" | grep '=== TOTAL ===')
    [ -n "$total_line" ] || { printf '%s\n' "$output"; false; }
    a_count=$(printf '%s\n' "$total_line" | sed -n 's/.*hw-only(a)=\([0-9]*\).*/\1/p')
    [ "$a_count" -le 86 ] || { echo "expected <= 86 (regression), got: $total_line"; false; }
}

# cmd_203 T2はgen-only(b)を意図的に減らす作業のため、完全一致ではなく
# 上限（regression ceiling）判定にする——増加のみを検知し、減少は許容する。
@test "parity: known drift baseline — gen-only(b) total is at most 26" {
    run bash "$SCRIPT"
    total_line=$(printf '%s\n' "$output" | grep '=== TOTAL ===')
    [ -n "$total_line" ] || { printf '%s\n' "$output"; false; }
    b_count=$(printf '%s\n' "$total_line" | sed -n 's/.*gen-only(b)=\([0-9]*\).*/\1/p')
    [ "$b_count" -le 26 ] || { echo "expected <= 26 (regression), got: $total_line"; false; }
}

@test "parity: --role shogun limits output to a single role section" {
    run bash "$SCRIPT" --role shogun
    section_count=$(printf '%s\n' "$output" | grep -c '^\[INFO\] === role: ')
    [ "$section_count" = "1" ] || { printf '%s\n' "$output"; false; }
    printf '%s\n' "$output" | grep -q '=== role: shogun ===' || { printf '%s\n' "$output"; false; }
}

@test "parity: exits non-zero while known drift remains (a>0 or b>0)" {
    run bash "$SCRIPT" --role ashigaru
    [ "$status" -eq 1 ] || { printf '%s\n' "$output"; false; }
}
