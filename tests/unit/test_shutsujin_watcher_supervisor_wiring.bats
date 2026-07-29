#!/usr/bin/env bats
# test_shutsujin_watcher_supervisor_wiring.bats — cmd_172
#
# 2026-07-29 07:33〜11:49 の4時間15分全軍停止インシデントの根本原因は
# scripts/watcher_supervisor.sh（baton_watchdog.shの起動元）が
# shutsujin_departure.sh から一度も呼ばれていなかったことだった。
# 本テストは静的チェックのみ（実行はしない）。shutsujin_departure.sh実行は
# 稼働中の本番tmuxセッション全体に影響する破壊的操作であり、本テストからは
# 絶対に実行しない。

SCRIPT_PATH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/shutsujin_departure.sh"

@test "T-SDW-001: shutsujin_departure.sh references scripts/watcher_supervisor.sh" {
    grep -q "scripts/watcher_supervisor.sh" "$SCRIPT_PATH"
}

@test "T-SDW-002: watcher_supervisor startup is guarded by a pgrep check (no duplicate launch)" {
    grep -A3 'scripts/watcher_supervisor.sh"' "$SCRIPT_PATH" | grep -q 'pgrep' \
        || grep -B3 'scripts/watcher_supervisor.sh"' "$SCRIPT_PATH" | grep -q 'pgrep -f "scripts/watcher_supervisor.sh"'
}

@test "T-SDW-003: existing per-agent inbox_watcher startup block (STEP 6.6) is untouched" {
    grep -q "STEP 6.6: inbox_watcher起動（全エージェント）" "$SCRIPT_PATH"
    grep -q 'scripts/inbox_watcher.sh" shogun "shogun:main"' "$SCRIPT_PATH"
}

@test "T-SDW-004: shutsujin_departure.sh has no syntax errors" {
    run bash -n "$SCRIPT_PATH"
    [ "$status" -eq 0 ]
}
