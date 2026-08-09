#!/usr/bin/env bats
# cmd_222: scripts/workspace_fold.sh — C1-C7 safety conditions.
# Each condition test builds a fixture where exactly that condition fails
# and all others pass, per CLAUDE.md Test Rules and the design in
# queue/reports/gunshi_design_222_workspace_cleanup_convention.yaml.

setup() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export FOLD="$PROJECT_ROOT/scripts/workspace_fold.sh"
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/workspace_fold.XXXXXX")"

    git init -q --bare "$TEST_TMPDIR/origin.git"

    git init -q "$TEST_TMPDIR/seed"
    git -C "$TEST_TMPDIR/seed" config user.email "test@example.com"
    git -C "$TEST_TMPDIR/seed" config user.name "Test User"
    echo base > "$TEST_TMPDIR/seed/base.txt"
    git -C "$TEST_TMPDIR/seed" add base.txt
    git -C "$TEST_TMPDIR/seed" commit -q -m base
    git -C "$TEST_TMPDIR/seed" branch -M develop
    git -C "$TEST_TMPDIR/seed" remote add origin "$TEST_TMPDIR/origin.git"
    git -C "$TEST_TMPDIR/seed" push -q -u origin develop

    export TEST_MAIN="$TEST_TMPDIR/main_repo"
    git clone -q "$TEST_TMPDIR/origin.git" "$TEST_MAIN"
    git -C "$TEST_MAIN" config user.email "test@example.com"
    git -C "$TEST_MAIN" config user.name "Test User"
    git -C "$TEST_MAIN" checkout -q develop

    # Run all checks from outside any fixture worktree (self-target trap, RK-4).
    cd "$TEST_TMPDIR"
}

teardown() {
    cd "$PROJECT_ROOT"
    rm -rf "$TEST_TMPDIR"
}

# Creates a worktree off develop, on a fresh branch, pushed upstream
# (so C1/C2/C3/C4/C5/C6/C7 all pass by construction). Callers then break
# exactly one condition.
mk_clean_worktree() {
    local name="$1" path="$TEST_TMPDIR/wt_$1"
    git -C "$TEST_MAIN" worktree add -q -b "feat/$name" "$path" develop
    git -C "$path" push -q -u origin "feat/$name"
    echo "$path"
}

@test "no unsafe override flags anywhere in the script" {
    run grep -n -- '--force' "$FOLD"
    [ "$status" -ne 0 ]
    run grep -nE -- '(^|[^A-Za-z0-9_-])-D([^A-Za-z0-9_-]|$)' "$FOLD"
    [ "$status" -ne 0 ]
}

@test "C7 alone fails: raw directory not registered as a worktree" {
    mkdir -p "$TEST_TMPDIR/raw_dir"
    run bash "$FOLD" "$TEST_TMPDIR/raw_dir"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FAIL"*"C7"* ]]
    [[ "$output" == *"lord"* ]]
}

assert_only_one_condition_fails() {
    local id="$1" fail_count
    fail_count="$(grep -c '^\[FAIL\]' <<<"$output")"
    [[ "$output" == *"[FAIL] $id "* ]] || { echo "$output"; false; }
    [ "$fail_count" -eq 1 ] || { echo "expected exactly 1 failing condition, got $fail_count:"; echo "$output"; false; }
}

@test "C1 alone fails: uncommitted change present" {
    path="$(mk_clean_worktree c1)"
    echo dirty > "$path/dirty.txt"
    run bash "$FOLD" "$path"
    [ "$status" -ne 0 ]
    assert_only_one_condition_fails C1
    [ -d "$path" ]
}

@test "C2 alone fails: no upstream tracking branch configured" {
    path="$TEST_TMPDIR/wt_c2"
    git -C "$TEST_MAIN" worktree add -q -b feat/c2 "$path" develop
    run bash "$FOLD" "$path"
    [ "$status" -ne 0 ]
    assert_only_one_condition_fails C2
    [ -d "$path" ]
}

@test "C3 alone fails: repo-wide stash entry" {
    path="$(mk_clean_worktree c3)"
    echo stashme > "$TEST_MAIN/stashfile.txt"
    git -C "$TEST_MAIN" add stashfile.txt
    git -C "$TEST_MAIN" stash -q
    run bash "$FOLD" "$path"
    [ "$status" -ne 0 ]
    assert_only_one_condition_fails C3
    git -C "$TEST_MAIN" stash drop -q
    [ -d "$path" ]
}

@test "C4 alone fails: gitignored data file not visible to git status" {
    git -C "$TEST_MAIN" checkout -q develop
    echo '*.db' > "$TEST_MAIN/.gitignore"
    git -C "$TEST_MAIN" add .gitignore
    git -C "$TEST_MAIN" commit -q -m "ignore db files"
    git -C "$TEST_MAIN" push -q origin develop

    path="$(mk_clean_worktree c4)"
    touch "$path/data.db"
    run bash "$FOLD" "$path"
    [ "$status" -ne 0 ]
    assert_only_one_condition_fails C4
    [[ "$output" == *"[OK]   C1"* ]] || { echo "$output"; false; }
    [ -d "$path" ]
}

@test "C5 alone fails: a live process holds the directory as cwd" {
    path="$(mk_clean_worktree c5)"
    ( cd "$path" && exec timeout 8 sleep 20 ) &
    sleep 1

    run bash "$FOLD" "$path"
    [ "$status" -ne 0 ]
    assert_only_one_condition_fails C5

    wait || true
    run bash "$FOLD" "$path"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN"* ]] || { echo "$output"; false; }
}

@test "C6 alone fails: branch pushed but not landed on base, no PR" {
    path="$TEST_TMPDIR/wt_c6"
    git -C "$TEST_MAIN" worktree add -q -b feat/c6 "$path" develop
    git -C "$path" config user.email "test@example.com"
    git -C "$path" config user.name "Test User"
    echo extra > "$path/extra.txt"
    git -C "$path" add extra.txt
    git -C "$path" commit -q -m "unmerged commit"
    git -C "$path" push -q -u origin feat/c6

    run env PATH="/usr/bin:/bin" bash "$FOLD" "$path"
    [ "$status" -ne 0 ]
    assert_only_one_condition_fails C6
    [ -d "$path" ]
}

@test "all conditions pass but --yes is absent: nothing is removed (dry-run default)" {
    path="$(mk_clean_worktree allpass_dryrun)"
    git -C "$TEST_MAIN" merge -q --ff-only "feat/allpass_dryrun"
    git -C "$TEST_MAIN" push -q origin develop

    run bash "$FOLD" "$path"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN"* ]] || { echo "$output"; false; }
    [ -d "$path" ]
    run git -C "$TEST_MAIN" worktree list
    [[ "$output" == *"wt_allpass_dryrun"* ]] || { echo "$output"; false; }
}

@test "all conditions pass with --yes: worktree and branch are folded" {
    path="$(mk_clean_worktree allpass_yes)"
    git -C "$TEST_MAIN" merge -q --ff-only "feat/allpass_yes"
    git -C "$TEST_MAIN" push -q origin develop

    run bash "$FOLD" "$path" --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"FOLDED"* ]] || { echo "$output"; false; }
    [ ! -d "$path" ]
    run git -C "$TEST_MAIN" worktree list
    [[ "$output" != *"wt_allpass_yes"* ]] || { echo "$output"; false; }
    run git -C "$TEST_MAIN" branch --list "feat/allpass_yes"
    [ -z "$output" ]
}

@test "--sweep folds every eligible worktree and blocks the rest, main worktree untouched" {
    ok_path="$(mk_clean_worktree sweep_ok)"
    git -C "$TEST_MAIN" merge -q --ff-only "feat/sweep_ok"
    git -C "$TEST_MAIN" push -q origin develop

    bad_path="$(mk_clean_worktree sweep_bad)"
    echo dirty > "$bad_path/dirty.txt"

    cd "$TEST_MAIN"
    run bash "$FOLD" --sweep --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"FOLDED"* ]] || { echo "$output"; false; }
    [[ "$output" == *"REFUSED"* ]] || { echo "$output"; false; }
    [ ! -d "$ok_path" ]
    [ -d "$bad_path" ]
    [ -d "$TEST_MAIN" ]
}
