#!/usr/bin/env bats
#
# cmd_178 PC-2 -- scripts/compute_daily_consumption.py,
# scripts/log_daily_consumption.sh
#
# QC33-F1: jsonl timestamps are UTC; the target date must be compared
# after converting to local time, not by raw string prefix match.
# QC33-F2: log_daily_consumption.sh's default date must be "yesterday"
# (a closed day), not "today" (still in progress).
#
# Both tests below force TZ=Asia/Tokyo so the UTC/JST boundary case is
# deterministic regardless of the host's configured timezone.

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/daily_consumption.XXXXXX")"
    export TZ="Asia/Tokyo"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# One line establishing role via the hook text, followed by a usage line
# whose timestamp is UTC 23:30 on the given UTC date -- i.e. JST 08:30 on
# the *next* calendar day.
make_fixture_jsonl() {
    local path="$1" utc_date="$2"
    cat > "$path" <<EOF
{"timestamp":"${utc_date}T00:00:00.000Z","message":{"content":"貴殿は **karo** である"}}
{"timestamp":"${utc_date}T23:30:00.453Z","message":{"usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":50}}}
EOF
}

@test "compute_daily_consumption.py buckets a UTC 23:30 line into the next JST day" {
    make_fixture_jsonl "$TEST_TMPDIR/session.jsonl" "2026-07-30"

    # Under the pre-fix bug (raw startswith(date) on the UTC string), this
    # line would be counted under 2026-07-30, never under 2026-07-31.
    run python3 "$PROJECT_ROOT/scripts/compute_daily_consumption.py" "2026-07-31" "$TEST_TMPDIR"
    [ "$status" -eq 0 ]
    [[ "$output" == "2026-07-31,karo,1,"* ]] || { echo "$output"; false; }

    run python3 "$PROJECT_ROOT/scripts/compute_daily_consumption.py" "2026-07-30" "$TEST_TMPDIR"
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "expected no rows for 2026-07-30, got: $output"; false; }
}

@test "log_daily_consumption.sh defaults to yesterday, not today" {
    export SHOGUN_CLAUDE_PROJECTS_DIR="$TEST_TMPDIR/claude_projects"
    mkdir -p "$SHOGUN_CLAUDE_PROJECTS_DIR"

    local_out_dir="$TEST_TMPDIR/logs/daily"
    # log_daily_consumption.sh writes to PROJECT_ROOT/logs/daily/consumption.csv
    # (not overridable), so run it from a copy of the repo tree rooted at
    # TEST_TMPDIR to avoid touching the real logs/ directory.
    mkdir -p "$TEST_TMPDIR/scripts"
    cp "$PROJECT_ROOT/scripts/log_daily_consumption.sh" "$TEST_TMPDIR/scripts/"
    cp "$PROJECT_ROOT/scripts/compute_daily_consumption.py" "$TEST_TMPDIR/scripts/"

    run bash "$TEST_TMPDIR/scripts/log_daily_consumption.sh"
    [ "$status" -eq 0 ]

    expected_date="$(TZ=Asia/Tokyo date -d yesterday +%Y-%m-%d)"
    [[ "$output" == *"Recorded ${expected_date} into"* ]] || { echo "$output"; false; }

    today="$(TZ=Asia/Tokyo date +%Y-%m-%d)"
    [[ "$output" != *"Recorded ${today} into"* ]] || { echo "unexpectedly recorded today: $output"; false; }
}
