#!/usr/bin/env bats

setup() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/stall_policy.XXXXXX")"
    export TEST_SETTINGS="$TEST_TMPDIR/settings.yaml"
    export TEST_SETTINGS_NO_SECTION="$TEST_TMPDIR/settings_no_section.yaml"

    # Bundled settings.yaml carrying the full cmd_171 §2.2 schema.
    cat > "$TEST_SETTINGS" <<EOF
language: ja

stall_policy:
  enabled: false
  stall_after_sec: 480
  hash_sample_interval_sec: 30
  stall_retry_cooldown_sec: 600
  recovery_level: escape_only
  unknown_policy: escape_only
  usage_limit_threshold_pct: 95
  usage_cache_ttl_sec: 120
  usage_limit_pane_patterns:
    - "usage limit"
    - "rate limit"
    - "limit reached"
    - "resets at"

baton_watchdog:
  enabled: true
  baton_lost_after_sec: 900
  poll_interval_sec: 60
EOF

    # settings.yaml that exists but has neither section (pre-cmd_171 file).
    cat > "$TEST_SETTINGS_NO_SECTION" <<EOF
language: ja
shell: bash
EOF
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

@test "TC-CFG-001: stall_policy_query falls back to safe defaults when section is absent" {
    run env STALL_POLICY_SETTINGS="$TEST_SETTINGS_NO_SECTION" \
        bash -c 'source "'"$PROJECT_ROOT"'/lib/stall_policy.sh"; stall_policy_query enabled; stall_policy_query stall_after_sec; stall_policy_query recovery_level; stall_policy_query unknown_policy'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "false" ]
    [ "${lines[1]}" = "480" ]
    [ "${lines[2]}" = "escape_only" ]
    [ "${lines[3]}" = "escape_only" ]
}

@test "TC-CFG-001b: baton_watchdog_query falls back to safe defaults when section is absent" {
    run env STALL_POLICY_SETTINGS="$TEST_SETTINGS_NO_SECTION" \
        bash -c 'source "'"$PROJECT_ROOT"'/lib/stall_policy.sh"; baton_watchdog_query enabled; baton_watchdog_query baton_lost_after_sec; baton_watchdog_query poll_interval_sec'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "true" ]
    [ "${lines[1]}" = "900" ]
    [ "${lines[2]}" = "60" ]
}

@test "TC-CFG-001c: both queries fall back to safe defaults and exit 0 when settings.yaml itself is missing" {
    run env STALL_POLICY_SETTINGS="$TEST_TMPDIR/nonexistent_settings.yaml" \
        bash -c 'source "'"$PROJECT_ROOT"'/lib/stall_policy.sh"; stall_policy_query enabled && baton_watchdog_query enabled'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "false" ]
    [ "${lines[1]}" = "true" ]
}

@test "TC-CFG-002: stall_policy_query reads enabled=false from bundled settings.yaml" {
    run env STALL_POLICY_SETTINGS="$TEST_SETTINGS" \
        bash -c 'source "'"$PROJECT_ROOT"'/lib/stall_policy.sh"; stall_policy_query enabled'
    [ "$status" -eq 0 ]
    [ "$output" = "false" ]
}

@test "TC-CFG-003: baton_watchdog_query reads enabled=true from bundled settings.yaml" {
    run env STALL_POLICY_SETTINGS="$TEST_SETTINGS" \
        bash -c 'source "'"$PROJECT_ROOT"'/lib/stall_policy.sh"; baton_watchdog_query enabled'
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "stall_policy_query usage_limit_pane_patterns returns the bundled multi-line list" {
    run env STALL_POLICY_SETTINGS="$TEST_SETTINGS" \
        bash -c 'source "'"$PROJECT_ROOT"'/lib/stall_policy.sh"; stall_policy_query usage_limit_pane_patterns'
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 4 ]
    [[ "$output" == *"usage limit"* ]]
    [[ "$output" == *"resets at"* ]]
}

@test "stall_policy_query usage_limit_pane_patterns falls back to defaults when patterns list is empty" {
    cat > "$TEST_TMPDIR/settings_empty_patterns.yaml" <<EOF
stall_policy:
  usage_limit_pane_patterns: []
EOF
    run env STALL_POLICY_SETTINGS="$TEST_TMPDIR/settings_empty_patterns.yaml" \
        bash -c 'source "'"$PROJECT_ROOT"'/lib/stall_policy.sh"; stall_policy_query usage_limit_pane_patterns'
    [ "$status" -eq 0 ]
    [[ "$output" == *"usage limit"* ]]
}

@test "stall_policy_query rejects an unknown query key" {
    run env STALL_POLICY_SETTINGS="$TEST_SETTINGS" \
        bash -c 'source "'"$PROJECT_ROOT"'/lib/stall_policy.sh"; stall_policy_query not_a_real_key'
    [ "$status" -ne 0 ]
}

@test "baton_watchdog_query rejects an unknown query key" {
    run env STALL_POLICY_SETTINGS="$TEST_SETTINGS" \
        bash -c 'source "'"$PROJECT_ROOT"'/lib/stall_policy.sh"; baton_watchdog_query not_a_real_key'
    [ "$status" -ne 0 ]
}

# cmd_208/措置B・C: 既定値が実際に変わったこと自体の回帰固定。
@test "TC-CFG-208: baton_watchdog_query default for baton_lost_human_held_after_sec is 3600 (was 86400), and baton_lost_repeat_after_sec defaults to 900" {
    run env STALL_POLICY_SETTINGS="$TEST_SETTINGS_NO_SECTION" \
        bash -c 'source "'"$PROJECT_ROOT"'/lib/stall_policy.sh"; baton_watchdog_query baton_lost_human_held_after_sec; baton_watchdog_query baton_lost_repeat_after_sec'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "3600" ]
    [ "${lines[1]}" = "900" ]
}
