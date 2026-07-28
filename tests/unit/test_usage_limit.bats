#!/usr/bin/env bats
#
# cmd_171/T2 — lib/usage_limit.sh (usage_limit_state)
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

# Fake curl that prints a fixed OAuth usage API response body to stdout,
# with five_hour.utilization set to $1.
write_fake_curl_with_utilization() {
    local util="$1"
    cat > "$TEST_BIN/curl" <<EOF
#!/usr/bin/env bash
cat <<JSON
{"five_hour": {"utilization": ${util}, "resets_at": "2026-07-29T00:00"}, "seven_day": {"utilization": 10, "resets_at": "2026-08-04"}}
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

    run env CLI_ADAPTER_SETTINGS="$TEST_SETTINGS_CLAUDE" \
        STALL_POLICY_SETTINGS="$TEST_SETTINGS_CLAUDE" \
        USAGE_LIMIT_CREDS="$TEST_CREDS" \
        PATH="$TEST_BIN:$PATH" \
        bash -c 'source "'"$PROJECT_ROOT"'/lib/usage_limit.sh"; usage_limit_state ashigaru1'
    [ "$status" -eq 0 ]
    [ "$output" = "unknown" ]
}

@test "TC-USAGE-006: non-claude CLI -> unknown even with valid credentials present" {
    write_fake_curl_with_utilization 99

    run env CLI_ADAPTER_SETTINGS="$TEST_SETTINGS_CODEX_AGENT" \
        STALL_POLICY_SETTINGS="$TEST_SETTINGS_CODEX_AGENT" \
        USAGE_LIMIT_CREDS="$TEST_CREDS" \
        PATH="$TEST_BIN:$PATH" \
        bash -c 'source "'"$PROJECT_ROOT"'/lib/usage_limit.sh"; usage_limit_state ashigaru9'
    [ "$status" -eq 0 ]
    [ "$output" = "unknown" ]
}

@test "usage_limit_state returns limited when five_hour.utilization is at/above threshold" {
    write_fake_curl_with_utilization 97

    run env CLI_ADAPTER_SETTINGS="$TEST_SETTINGS_CLAUDE" \
        STALL_POLICY_SETTINGS="$TEST_SETTINGS_CLAUDE" \
        USAGE_LIMIT_CREDS="$TEST_CREDS" \
        PATH="$TEST_BIN:$PATH" \
        bash -c 'source "'"$PROJECT_ROOT"'/lib/usage_limit.sh"; usage_limit_state ashigaru1'
    [ "$status" -eq 0 ]
    [ "$output" = "limited" ]
}

@test "usage_limit_state returns ok when five_hour.utilization is below threshold" {
    write_fake_curl_with_utilization 10

    run env CLI_ADAPTER_SETTINGS="$TEST_SETTINGS_CLAUDE" \
        STALL_POLICY_SETTINGS="$TEST_SETTINGS_CLAUDE" \
        USAGE_LIMIT_CREDS="$TEST_CREDS" \
        PATH="$TEST_BIN:$PATH" \
        bash -c 'source "'"$PROJECT_ROOT"'/lib/usage_limit.sh"; usage_limit_state ashigaru1'
    [ "$status" -eq 0 ]
    [ "$output" = "ok" ]
}

@test "usage_limit_fetch_raw prints nothing and fails when credentials are missing" {
    run env USAGE_LIMIT_CREDS="$TEST_MISSING_CREDS" \
        bash -c 'source "'"$PROJECT_ROOT"'/lib/usage_limit.sh"; usage_limit_fetch_raw'
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}
