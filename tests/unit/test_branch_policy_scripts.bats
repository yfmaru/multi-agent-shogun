#!/usr/bin/env bats

setup() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/branch_policy.XXXXXX")"
    export TEST_REPO="$TEST_TMPDIR/repo"
    export TEST_SETTINGS="$TEST_TMPDIR/settings.yaml"

    mkdir -p "$TEST_REPO"
    git -C "$TEST_REPO" init -q
    git -C "$TEST_REPO" config user.email "test@example.com"
    git -C "$TEST_REPO" config user.name "Test User"

    echo "base" > "$TEST_REPO/file.txt"
    git -C "$TEST_REPO" add file.txt
    GIT_AUTHOR_DATE="2000-01-01T00:00:00+0000" \
    GIT_COMMITTER_DATE="2000-01-01T00:00:00+0000" \
        git -C "$TEST_REPO" commit -q -m "base"
    git -C "$TEST_REPO" branch -M main
    git -C "$TEST_REPO" update-ref refs/remotes/origin/main HEAD
    git -C "$TEST_REPO" update-ref refs/remotes/origin/codd/demo-20000101 HEAD
    git -C "$TEST_REPO" update-ref refs/remotes/origin/develop HEAD
    git -C "$TEST_REPO" update-ref refs/remotes/origin/feat/cmd_163-branch-policy HEAD

    cat > "$TEST_SETTINGS" <<EOF
ntfy_topic: "test-topic-12345"
branch_policy:
  allowed_long_lived:
    - main
    - develop
  short_lived_pattern: "^codd/[^/]+-[0-9]{8}$"
  max_age_seconds: 1
  monitored_repos:
    - path: $TEST_REPO
EOF
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

@test "pre_deploy_verify passes on configured primary branch" {
    run env BRANCH_POLICY_SETTINGS="$TEST_SETTINGS" \
        bash "$PROJECT_ROOT/scripts/pre_deploy_verify.sh" --repo "$TEST_REPO" --dry-run

    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK] deploy branch confirmed: main"* ]]
}

@test "branch_drift_check reports stale non-primary remote branch in dry-run" {
    run env BRANCH_POLICY_SETTINGS="$TEST_SETTINGS" \
        bash "$PROJECT_ROOT/scripts/branch_drift_check.sh" --dry-run --no-fetch

    [ "$status" -eq 0 ]
    [[ "$output" == *"[DRIFT] branch drift: origin/codd/demo-20000101"* ]]
    [[ "$output" == *"[DRY-RUN] notify:"* ]]
}

@test "auto_merge_short_lived previews stale matching branch without mutation" {
    run env BRANCH_POLICY_SETTINGS="$TEST_SETTINGS" \
        bash "$PROJECT_ROOT/scripts/auto_merge_short_lived.sh" --dry-run --no-fetch

    [ "$status" -eq 0 ]
    [[ "$output" == *"[CANDIDATE]"* ]]
    [[ "$output" == *"[DRY-RUN] would merge origin/codd/demo-20000101 into main"* ]]
    git -C "$TEST_REPO" show-ref --verify --quiet refs/remotes/origin/codd/demo-20000101
}

@test "branch_policy_query falls back to safe defaults when settings.yaml is absent" {
    run env BRANCH_POLICY_SETTINGS="$TEST_REPO/nonexistent_settings.yaml" \
        bash -c 'source "'"$PROJECT_ROOT"'/lib/branch_policy.sh"; branch_policy_query primary'
    [ "$status" -eq 0 ]
    [ "$output" = "main" ]
}

@test "branch_drift_check does not flag develop as drift" {
    run env BRANCH_POLICY_SETTINGS="$TEST_SETTINGS" \
        bash "$PROJECT_ROOT/scripts/branch_drift_check.sh" --dry-run --no-fetch
    [ "$status" -eq 0 ]
    [[ "$output" != *"[DRIFT] branch drift: origin/develop"* ]]
}

@test "pre_deploy_verify aborts when repo is on develop" {
    git -C "$TEST_REPO" checkout -q -B develop
    run env BRANCH_POLICY_SETTINGS="$TEST_SETTINGS" \
        bash "$PROJECT_ROOT/scripts/pre_deploy_verify.sh" --repo "$TEST_REPO" --dry-run
    [ "$status" -eq 1 ]
    [[ "$output" == *"expected: main"* ]]
}

@test "auto_merge_short_lived ignores policy work branches" {
    run env BRANCH_POLICY_SETTINGS="$TEST_SETTINGS" \
        bash "$PROJECT_ROOT/scripts/auto_merge_short_lived.sh" --dry-run --no-fetch
    [ "$status" -eq 0 ]
    [[ "$output" != *"feat/cmd_163-branch-policy"* ]]
}

@test "auto_merge_short_lived skips non-dry-run execution when auto_merge_enabled is false" {
    run env BRANCH_POLICY_SETTINGS="$TEST_SETTINGS" \
        bash "$PROJECT_ROOT/scripts/auto_merge_short_lived.sh" --no-fetch
    [ "$status" -eq 0 ]
    [[ "$output" == *"[SKIP] auto_merge disabled by branch_policy.auto_merge_enabled"* ]]
}
