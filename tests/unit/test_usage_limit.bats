#!/usr/bin/env bats
#
# cmd_171/T2 -- lib/usage_limit.sh (usage_limit_state)
#
# NOTE: no test here ever calls the real Anthropic OAuth usage API. curl is
# replaced with a fake executable placed first on PATH, per task
# instructions (network-dependent tests would consume the lord's quota).

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/usage_limit.XXXXXX")"

    TEST_SETTINGS_CLAUDE="$TEST_TMPDIR/settings_claude.yaml"
    cat > "$TEST_SETTINGS_CLAUDE" <<EOF
cli:
  default: claude
stall_policy:
  usage_cache_ttl_sec: 120
  usage_limit_threshold_pct: 95
EOF

    TEST_SETTINGS_CODEX_AGENT="$TEST_TMPDIR/settings_codex_agent.yaml"
    cat > "$TEST_SETTINGS_CODEX_AGENT" <<EOF
cli:
  default: claude
  agents:
    ashigaru9:
      type: codex
stall_policy:
  usage_cache_ttl_sec: 120
  usage_limit_threshold_pct: 95
EOF

    TEST_MISSING_CREDS="$TEST_TMPDIR/no_such_credentials.json"

    TEST_CREDS="$TEST_TMPDIR/credentials.json"
    cat > "$TEST_CREDS" <<EOF
{"claudeAiOauth": {"accessToken": "dummy-token"}}
EOF

    TEST_BIN="$TEST_TMPDIR/bin"
    mkdir -p "$TEST_BIN"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# Fake curl that prints a fixed OAuth usage API response body to stdout.
# five_hour/seven_day utilization and the limits[] array are all
# parameterized so each test can reproduce a specific real-world shape.
write_fake_curl() {
    local five_hour_util="$1"
    local seven_day_util="$2"
    local limits_json="${3:-[]}"
    cat > "$TEST_BIN/curl" <<EOF
#!/usr/bin/env bash
cat <<JSON
{"five_hour": {"utilization": ${five_hour_util}, "resets_at": "2026-07-29T00:00"}, "seven_day": {"utilization": ${seven_day_util}, "resets_at": "2026-08-04"}, "seven_day_sonnet": null, "seven_day_opus": null, "limits": ${limits_json}}
JSON
EOF
    chmod +x "$TEST_BIN/curl"
}

write_fake_curl_broken() {
    cat > "$TEST_BIN/curl" <<'EOF'
#!/usr/bin/env bash
echo "not json"
EOF
    chmod +x "$TEST_BIN/curl"
}

run_usage_limit_state() {
    local settings="$1" creds="$2" agent="$3"
    run env CLI_ADAPTER_SETTINGS="$settings" \
        STALL_POLICY_SETTINGS="$settings" \
        USAGE_LIMIT_CREDS="$creds" \
        PATH="$TEST_BIN:$PATH" \
        bash -c 'source "'"$PROJECT_ROOT"'/lib/usage_limit.sh"; usage_limit_state '"$agent"
}

@test "TC-USAGE-005: missing credentials file -> unknown (never falls to ok)" {
    run env CLI_ADAPTER_SETTINGS="$TEST_SETTINGS_CLAUDE" \
        STALL_POLICY_SETTINGS="$TEST_SETTINGS_CLAUDE" \
        USAGE_LIMIT_CREDS="$TEST_MISSING_CREDS" \
        bash -c 'source "'"$PROJECT_ROOT"'/lib/usage_limit.sh"; usage_limit_state ashigaru1'
    [ "$status" -eq 0 ]
    [ "$output" = "unknown" ]
}

@test "TC-USAGE-005b: API call fails / malformed response -> unknown (never falls to ok)" {
    write_fake_curl_broken

    run_usage_limit_state "$TEST_SETTINGS_CLAUDE" "$TEST_CREDS" ashigaru1
    [ "$status" -eq 0 ]
    [ "$output" = "unknown" ]
}

@test "TC-USAGE-006: non-claude CLI -> unknown even with valid credentials present" {
    write_fake_curl 99 10 "[]"

    run_usage_limit_state "$TEST_SETTINGS_CODEX_AGENT" "$TEST_CREDS" ashigaru9
    [ "$status" -eq 0 ]
    [ "$output" = "unknown" ]
}

@test "TC-USAGE-008: limits[] active+non-normal entry -> limited even when five_hour has margin (EV-C2 real-world case)" {
    # Reproduces the 2026-07-29 measurement: five_hour=43 (comfortable),
    # seven_day=78 (below the 95 threshold too), but limits[] carries an
    # active weekly_all warning -- the actual constraint that stalled 3
    # agents for ~10h. Neither raw percentage alone would have caught it.
    write_fake_curl 43 78 '[{"kind": "session", "group": "weekly", "percent": 42, "severity": "normal", "is_active": false}, {"kind": "weekly_all", "group": "weekly", "percent": 78, "severity": "warning", "is_active": true}]'

    run_usage_limit_state "$TEST_SETTINGS_CLAUDE" "$TEST_CREDS" ashigaru1
    [ "$status" -eq 0 ]
    [ "$output" = "limited" ]
}

@test "TC-USAGE-009: empty limits[] falls back to five_hour/seven_day thresholds correctly" {
    write_fake_curl 10 10 "[]"
    run_usage_limit_state "$TEST_SETTINGS_CLAUDE" "$TEST_CREDS" ashigaru1
    [ "$status" -eq 0 ]
    [ "$output" = "ok" ]

    write_fake_curl 97 10 "[]"
    run_usage_limit_state "$TEST_SETTINGS_CLAUDE" "$TEST_CREDS" ashigaru1
    [ "$status" -eq 0 ]
    [ "$output" = "limited" ]

    write_fake_curl 10 97 "[]"
    run_usage_limit_state "$TEST_SETTINGS_CLAUDE" "$TEST_CREDS" ashigaru1
    [ "$status" -eq 0 ]
    [ "$output" = "limited" ]
}

@test "TC-USAGE-009b: limits[] present but with no active/non-normal entry does not force limited" {
    write_fake_curl 10 10 '[{"kind": "session", "group": "five_hour", "percent": 5, "severity": "normal", "is_active": false}]'
    run_usage_limit_state "$TEST_SETTINGS_CLAUDE" "$TEST_CREDS" ashigaru1
    [ "$status" -eq 0 ]
    [ "$output" = "ok" ]
}

@test "usage_limit_fetch_raw prints nothing and fails when credentials are missing" {
    run env USAGE_LIMIT_CREDS="$TEST_MISSING_CREDS" \
        bash -c 'source "'"$PROJECT_ROOT"'/lib/usage_limit.sh"; usage_limit_fetch_raw'
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "usage_limit_fetch_raw exposes LIMITS_FLAGGED=true when an active non-normal limit exists" {
    write_fake_curl 43 78 '[{"kind": "weekly_all", "group": "weekly", "percent": 78, "severity": "warning", "is_active": true}]'
    run env USAGE_LIMIT_CREDS="$TEST_CREDS" PATH="$TEST_BIN:$PATH" \
        bash -c 'source "'"$PROJECT_ROOT"'/lib/usage_limit.sh"; usage_limit_fetch_raw'
    [ "$status" -eq 0 ]
    [[ "$output" == *"LIMITS_FLAGGED=true"* ]]
}
