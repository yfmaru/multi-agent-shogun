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

# Installs a minimal `gh` stub at the front of PATH that answers
# `gh pr list --state all --head <branch> --json mergedAt --jq ...` with a
# fake merged timestamp iff <branch> is one of GH_STUB_MERGED_BRANCHES
# (space-separated), and prints nothing otherwise (i.e. "no merged PR
# found"). Real `gh` cannot be pointed at a fake local-path remote for
# this — it recognizes it isn't a GitHub host and errors out.
mk_gh_stub_path() {
    mkdir -p "$TEST_TMPDIR/gh_stub_bin"
    cat > "$TEST_TMPDIR/gh_stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "list" ]]; then
    branch="" prev=""
    for arg in "$@"; do
        [[ "$prev" == "--head" ]] && branch="$arg"
        prev="$arg"
    done
    for b in $GH_STUB_MERGED_BRANCHES; do
        [[ "$b" == "$branch" ]] && { echo "2026-01-01T00:00:00Z"; exit 0; }
    done
    exit 0
fi
exit 1
STUB
    chmod +x "$TEST_TMPDIR/gh_stub_bin/gh"
    printf '%s:%s' "$TEST_TMPDIR/gh_stub_bin" "$PATH"
}

@test "no unsafe override flags anywhere in the script" {
    run grep -n -- '--force' "$FOLD"
    [ "$status" -ne 0 ]
    run grep -nE -- '(^|[^A-Za-z0-9_-])-D([^A-Za-z0-9_-]|$)' "$FOLD"
    [ "$status" -ne 0 ]
    # Scoped to the two dangerous subcommands, not the whole file — a bare
    # script-wide "-f" ban would also flag `readlink -f` (portable
    # absolute-path resolution, unrelated to any git override flag).
    run grep -nE -- 'worktree remove.*(^|[^A-Za-z0-9_-])-f([^A-Za-z0-9_-]|$)' "$FOLD"
    [ "$status" -ne 0 ]
    run grep -nE -- 'worktree remove.*--force' "$FOLD"
    [ "$status" -ne 0 ]
    run grep -nE -- 'branch.*--delete[[:space:]]+--force' "$FOLD"
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

@test "C2 alone fails: upstream configured, but a follow-up commit was never pushed (original path, independent of C6's landing check)" {
    # Exercises C2's original (upstream-resolves) path in isolation. Uses a
    # merged-PR gh stub so C6 passes via the landing fallback even though
    # origin/develop..HEAD is non-zero here — proving C2's "ahead of
    # upstream" failure is a distinct signal from C6's "landed" check, not
    # just the same computation wearing two names.
    stub_path="$(mk_gh_stub_path)"
    path="$(mk_clean_worktree c2_unpushed)"
    git -C "$TEST_MAIN" merge -q --ff-only "feat/c2_unpushed"
    git -C "$TEST_MAIN" push -q origin develop

    echo more > "$path/more.txt"
    git -C "$path" add more.txt
    git -C "$path" commit -q -m "local-only follow-up commit, never pushed"

    run env PATH="$stub_path" GH_STUB_MERGED_BRANCHES="feat/c2_unpushed" bash "$FOLD" "$path"
    [ "$status" -ne 0 ]
    assert_only_one_condition_fails C2
    [ -d "$path" ]
}

@test "no-upstream + unlanded commit is refused (C2 and C6 both correctly fail — they share the landing check)" {
    # The floor QC-1's fix must not loosen: a branch that was never pushed
    # and carries unique content not present anywhere on base must still
    # be refused. Here C2's fallback and C6 both fail together — that
    # coupling is expected once @{u} is unresolvable, since they consult
    # the exact same branch_has_landed() result (see assert_only_one_*
    # tests above for where C2 and C6 are shown to be independently
    # triggerable).
    path="$TEST_TMPDIR/wt_c2_unlanded"
    git -C "$TEST_MAIN" worktree add -q -b feat/c2_unlanded "$path" develop
    git -C "$path" config user.email "test@example.com"
    git -C "$path" config user.name "Test User"
    echo unique > "$path/unique.txt"
    git -C "$path" add unique.txt
    git -C "$path" commit -q -m "never pushed, unique, unlanded commit"

    run bash "$FOLD" "$path"
    [ "$status" -ne 0 ]
    [[ "$output" == *"[FAIL] C2 "* ]] || { echo "$output"; false; }
    [[ "$output" == *"REFUSED"* ]] || { echo "$output"; false; }
    [ -d "$path" ]
}

@test "C2 alone passes: no upstream, but branch has zero commits unique vs base" {
    path="$TEST_TMPDIR/wt_c2_noop"
    git -C "$TEST_MAIN" worktree add -q -b feat/c2_noop "$path" develop
    run bash "$FOLD" "$path"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK]   C2"* ]] || { echo "$output"; false; }
}

@test "C2+C6 pass via merged-PR landing fallback: push, squash-merge, delete remote branch, prune (gh pr merge --squash --delete-branch equivalent, QC-1 required test)" {
    stub_path="$(mk_gh_stub_path)"
    path="$(mk_clean_worktree squash_landed)"
    echo feature > "$path/feature.txt"
    git -C "$path" add feature.txt
    git -C "$path" commit -q -m "feature work"
    git -C "$path" push -q origin "feat/squash_landed"

    # Squash-merge into develop: content lands, but the branch's own
    # commit never becomes an ancestor of develop.
    git -C "$TEST_MAIN" checkout -q develop
    git -C "$TEST_MAIN" merge -q --squash "feat/squash_landed"
    git -C "$TEST_MAIN" commit -q -m "squash merge feat/squash_landed"
    git -C "$TEST_MAIN" push -q origin develop

    # gh pr merge --delete-branch equivalent: remote branch deleted, then
    # pruned locally — this is what makes @{u} unresolvable (QC-1).
    git -C "$path" push -q origin --delete "feat/squash_landed"
    git -C "$path" fetch -q --prune

    run env PATH="$stub_path" GH_STUB_MERGED_BRANCHES="feat/squash_landed" bash "$FOLD" "$path"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK]   C2"* ]] || { echo "$output"; false; }
    [[ "$output" == *"[OK]   C6"* ]] || { echo "$output"; false; }
    [[ "$output" == *"DRY-RUN"* ]] || { echo "$output"; false; }

    run env PATH="$stub_path" GH_STUB_MERGED_BRANCHES="feat/squash_landed" bash "$FOLD" "$path" --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"FOLDED"* ]] || { echo "$output"; false; }
    [ ! -d "$path" ]
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

@test "C5 alone fails: a live process holds a subdirectory (not the root) as cwd" {
    path="$(mk_clean_worktree c5_sub)"
    mkdir -p "$path/sub/dir"
    ( cd "$path/sub/dir" && exec timeout 8 sleep 20 ) &
    sleep 1

    run bash "$FOLD" "$path"
    [ "$status" -ne 0 ]
    assert_only_one_condition_fails C5

    wait || true
    run bash "$FOLD" "$path"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN"* ]] || { echo "$output"; false; }
}

@test "C5 alone fails (fails closed): neither /proc nor lsof is available" {
    path="$(mk_clean_worktree c5_noverify)"
    run env WORKSPACE_FOLD_PROC_DIR="$TEST_TMPDIR/no_such_proc" \
        WORKSPACE_FOLD_LSOF_BIN="no_such_lsof_binary_xyz" \
        bash "$FOLD" "$path"
    [ "$status" -ne 0 ]
    assert_only_one_condition_fails C5
    [[ "$output" == *"cannot verify"* ]] || { echo "$output"; false; }
    [ -d "$path" ]
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

    # Simulate "gh not installed" by excluding only gh's own directory from
    # PATH, not by blunt-stripping PATH (which would also hide lsof/coreutils
    # needed by other checks on non-Linux platforms).
    local gh_bin gh_dir filtered_path
    gh_bin="$(command -v gh || true)"
    if [[ -n "$gh_bin" ]]; then
        gh_dir="$(dirname "$gh_bin")"
        filtered_path="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vF "$gh_dir" | tr '\n' ':')"
    else
        filtered_path="$PATH"
    fi

    run env PATH="$filtered_path" bash "$FOLD" "$path"
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

# Installs a `git` stub at the front of PATH that behaves exactly like real
# git EXCEPT for `worktree list --porcelain` (with or without a leading
# `-C <path>`), where it re-emits the real output one line at a time with a
# small sleep between lines instead of writing it all at once. This forces
# the SIGPIPE race deterministically: if a caller pipes this output directly
# into an early-exiting `awk '...; exit}'`, awk closes its read end after
# the very first "worktree " line, and the stub's next write attempt (after
# its sleep) hits a broken pipe and dies with SIGPIPE (exit 141) — exactly
# what real git does on a busy host with dozens of worktrees, just made
# reproducible on demand instead of depending on OS scheduling luck.
mk_slow_worktree_list_git_stub_path() {
    local real_git
    real_git="$(command -v git)"
    mkdir -p "$TEST_TMPDIR/slow_git_bin"
    cat > "$TEST_TMPDIR/slow_git_bin/git" <<STUB
#!/usr/bin/env bash
REAL_GIT="$real_git"
is_wt_list=0
args=("\$@")
for ((i=0; i<\${#args[@]}; i++)); do
    if [[ "\${args[\$i]}" == "worktree" && "\${args[\$((i+1))]}" == "list" && "\${args[\$((i+2))]}" == "--porcelain" ]]; then
        is_wt_list=1
        break
    fi
done
if [[ "\$is_wt_list" -eq 1 ]]; then
    while IFS= read -r line; do
        printf '%s\n' "\$line"
        sleep 0.05
    done < <("\$REAL_GIT" "\$@")
    exit 0
fi
exec "\$REAL_GIT" "\$@"
STUB
    chmod +x "$TEST_TMPDIR/slow_git_bin/git"
    printf '%s:%s' "$TEST_TMPDIR/slow_git_bin" "$PATH"
}

@test "--sweep dry-run survives a slow-writing 'git worktree list --porcelain' without SIGPIPE-aborting (cmd_222 follow-up regression: main_repo lookup must not pipe a live writer into an early-exiting awk)" {
    mk_clean_worktree sigpipe_a >/dev/null
    mk_clean_worktree sigpipe_b >/dev/null

    cd "$TEST_MAIN"
    PATH="$(mk_slow_worktree_list_git_stub_path)" run bash "$FOLD" --sweep
    [ "$status" -eq 0 ] || { echo "status=$status (141 == SIGPIPE-killed); output:"; echo "$output"; false; }
    [[ "$output" == *"SWEEP SUMMARY"* ]] || { echo "$output"; false; }
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
