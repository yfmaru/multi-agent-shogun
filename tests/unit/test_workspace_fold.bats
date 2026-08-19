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

# Installs a minimal `tmux` stub at the front of PATH for the --strays
# tests. Real tmux sessions are never created for these tests (Test Rules
# 5 forbids creating anything that can't self-terminate, and a real tmux
# session inside a bats run would itself be exactly the kind of stray this
# feature exists to catch) — the stub answers `list-sessions`/`list-panes`
# from TMUX_STUB_SESSIONS/TMUX_STUB_PANES env vars instead of a live server.
mk_tmux_stub_path() {
    mkdir -p "$TEST_TMPDIR/tmux_stub_bin"
    cat > "$TEST_TMPDIR/tmux_stub_bin/tmux" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    list-sessions) printf '%s\n' "$TMUX_STUB_SESSIONS" ;;
    list-panes)    printf '%s\n' "$TMUX_STUB_PANES" ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$TEST_TMPDIR/tmux_stub_bin/tmux"
    printf '%s:%s' "$TEST_TMPDIR/tmux_stub_bin" "$PATH"
}

@test "--strays never lists multiagent/shogun even when tmux reports them (exclusion, not inclusion)" {
    stub_path="$(mk_tmux_stub_path)"
    run env PATH="$stub_path" \
        TMUX_STUB_SESSIONS=$'multiagent 1700000000\nshogun 1700000000\nscratch_g_225_a 1700000000' \
        TMUX_STUB_PANES=$'multiagent /some/prod/path\nshogun /some/prod/path\nscratch_g_225_a /some/scratch/path' \
        bash "$FOLD" --strays
    [ "$status" -eq 0 ]
    [[ "$output" != *"STRAY_SESSION: multiagent"* ]] || { echo "$output"; false; }
    [[ "$output" != *"STRAY_SESSION: shogun"* ]] || { echo "$output"; false; }
    [[ "$output" != *"kill-session -t multiagent"* ]] || { echo "$output"; false; }
    [[ "$output" != *"kill-session -t shogun"* ]] || { echo "$output"; false; }
    [[ "$output" == *"STRAY_SESSION: scratch_g_225_a"* ]] || { echo "$output"; false; }
}

@test "--strays refuses --yes outright (D006 guard: folding a tmux session is never an agent's to do)" {
    run bash "$FOLD" --strays --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSED"* ]] || { echo "$output"; false; }
    [[ "$output" == *"--strays"* ]] || { echo "$output"; false; }
}

@test "--strays flags a pane cwd inside a registered workspace as blocking its C5, and excludes a pane cwd in the main worktree" {
    path="$(mk_clean_worktree strays_c5)"
    stub_path="$(mk_tmux_stub_path)"

    cd "$TEST_MAIN"
    run env PATH="$stub_path" \
        TMUX_STUB_SESSIONS=$'scratch_a3_225_x 1700000000\nscratch_a3_225_y 1700000000' \
        TMUX_STUB_PANES="scratch_a3_225_x $path"$'\n'"scratch_a3_225_y $TEST_MAIN" \
        bash "$FOLD" --strays
    [ "$status" -eq 0 ]
    # Match loosely on the workspace path inside [BLOCKS ...], not exactly
    # $path: the script canonicalizes it (resolve_path), and on hosts where
    # the tmp root itself is a symlink (macOS /tmp -> /private/tmp) the
    # canonical form legitimately differs from bats' raw $TEST_TMPDIR-based
    # $path even though both name the same directory.
    [[ "$output" == *"PANE_CWD: $path"*"[BLOCKS C5 of workspace:"* ]] || { echo "$output"; false; }
    [[ "$output" == *"PANE_CWD: $TEST_MAIN"* ]] || { echo "$output"; false; }
    [[ "$output" != *"PANE_CWD: $TEST_MAIN [BLOCKS"* ]] || { echo "$output"; false; }
}

@test "--strays flags a non-scratch_* session name as a naming violation" {
    stub_path="$(mk_tmux_stub_path)"
    run env PATH="$stub_path" \
        TMUX_STUB_SESSIONS='diag_e2e2 1700000000' \
        TMUX_STUB_PANES='diag_e2e2 /tmp/somewhere' \
        bash "$FOLD" --strays
    [ "$status" -eq 0 ]
    [[ "$output" == *"STRAY_SESSION: diag_e2e2"*"NAMING-VIOLATION"* ]] || { echo "$output"; false; }
}

@test "--strays returns quietly (no error) when tmux is not installed" {
    # Shadows tmux's directory with a copy that symlinks everything EXCEPT
    # tmux, rather than dropping the directory from PATH outright: on this
    # host /bin is a symlink to /usr/bin (merged-usr) and also holds bash,
    # git, awk, date, etc., so a blunt removal of that PATH entry breaks
    # the very tools the script (and `env`'s own re-exec of `bash`) needs,
    # and a plain string exclusion of "/usr/bin" would leave tmux reachable
    # via the "/bin" entry regardless. Replacing both entries with the same
    # tmux-free shadow directory removes only tmux, everywhere it would
    # otherwise be found.
    local tmux_bin real_dir shadow_dir f dir filtered_path
    tmux_bin="$(command -v tmux || true)"
    if [[ -n "$tmux_bin" ]]; then
        real_dir="$(cd "$(dirname "$tmux_bin")" && pwd -P)"
        shadow_dir="$TEST_TMPDIR/no_tmux_bin"
        mkdir -p "$shadow_dir"
        for f in "$real_dir"/*; do
            [[ "$(basename "$f")" == "tmux" ]] && continue
            ln -sf "$f" "$shadow_dir/$(basename "$f")"
        done
        filtered_path=""
        while IFS= read -r dir; do
            [[ -z "$dir" ]] && continue
            if [[ -d "$dir" ]] && [[ "$(cd "$dir" 2>/dev/null && pwd -P)" == "$real_dir" ]]; then
                filtered_path="$filtered_path:$shadow_dir"
            else
                filtered_path="$filtered_path:$dir"
            fi
        done < <(printf '%s' "$PATH" | tr ':' '\n')
        filtered_path="${filtered_path#:}"
    else
        filtered_path="$PATH"
    fi
    run env PATH="$filtered_path" bash "$FOLD" --strays
    [ "$status" -eq 0 ]
    [[ "$output" != *"STRAY_SESSION"* ]] || { echo "$output"; false; }
}

@test "--sweep prints the strays section at the end even with nothing to fold" {
    stub_path="$(mk_tmux_stub_path)"
    cd "$TEST_MAIN"
    run env PATH="$stub_path" \
        TMUX_STUB_SESSIONS='scratch_a3_225_z 1700000000' \
        TMUX_STUB_PANES="scratch_a3_225_z $TEST_MAIN" \
        bash "$FOLD" --sweep
    [ "$status" -eq 0 ]
    [[ "$output" == *"SWEEP SUMMARY"* ]] || { echo "$output"; false; }
    [[ "$output" == *"STRAY_SESSION: scratch_a3_225_z"* ]] || { echo "$output"; false; }
}

@test "a worktree that initialized a submodule folds successfully with --yes (cmd_222 follow-up: 'working trees containing submodules cannot be moved or removed')" {
    # Self-contained local submodule remote — no network access, and no
    # $TEST_MAIN entanglement: this exercises exactly the git-internal
    # state (a worktree-private git-dir/modules directory) that blocks
    # `git worktree remove`, independent of the actual submodule content.
    git init -q --bare "$TEST_TMPDIR/subrepo.git"
    git -C "$TEST_TMPDIR/subrepo.git" symbolic-ref HEAD refs/heads/main
    git init -q "$TEST_TMPDIR/subseed"
    git -C "$TEST_TMPDIR/subseed" config user.email "test@example.com"
    git -C "$TEST_TMPDIR/subseed" config user.name "Test User"
    git -C "$TEST_TMPDIR/subseed" checkout -q -b main
    echo sub > "$TEST_TMPDIR/subseed/sub.txt"
    git -C "$TEST_TMPDIR/subseed" add sub.txt
    git -C "$TEST_TMPDIR/subseed" commit -q -m sub
    git -C "$TEST_TMPDIR/subseed" remote add origin "$TEST_TMPDIR/subrepo.git"
    git -C "$TEST_TMPDIR/subseed" push -q -u origin main

    path="$(mk_clean_worktree submodule_fold)"
    git -C "$path" -c protocol.file.allow=always submodule add -q "$TEST_TMPDIR/subrepo.git" sub
    git -C "$path" commit -q -m "add submodule"
    git -C "$path" push -q origin "feat/submodule_fold"

    # Sanity: this fixture really did trip the actual git precondition this
    # test protects against — the worktree-private submodule metadata
    # directory exists (deinit alone does not remove it; see fold_worktree()).
    wt_gitdir="$(git -C "$path" rev-parse --git-dir)"
    [ -d "$wt_gitdir/modules" ] || { echo "fixture did not initialize a submodule in this worktree"; false; }

    git -C "$TEST_MAIN" merge -q --ff-only "feat/submodule_fold"
    git -C "$TEST_MAIN" push -q origin develop

    run bash "$FOLD" "$path" --yes
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *"FOLDED"* ]] || { echo "$output"; false; }
    [ ! -d "$path" ]
}

@test "F-1 regression: single-target on another repo's main worktree must not delete the caller's own .git/modules (gunshi QC on PR#118: 'rev-parse --git-dir' is relative for a main worktree, so \$wt_gitdir/modules resolves against the invoking shell's cwd, not \$canon)" {
    # "caller" = the repo whose cwd the script is invoked from. It has a
    # real submodule initialized in its OWN main worktree, so its
    # .git/modules is populated with real metadata that
    # deinit_worktree_submodules() must never touch, no matter what path
    # is passed as the fold target.
    git init -q --bare "$TEST_TMPDIR/sub2.git"
    git -C "$TEST_TMPDIR/sub2.git" symbolic-ref HEAD refs/heads/main
    git init -q "$TEST_TMPDIR/sub2seed"
    git -C "$TEST_TMPDIR/sub2seed" config user.email "test@example.com"
    git -C "$TEST_TMPDIR/sub2seed" config user.name "Test User"
    git -C "$TEST_TMPDIR/sub2seed" checkout -q -b main
    echo sub2 > "$TEST_TMPDIR/sub2seed/sub2.txt"
    git -C "$TEST_TMPDIR/sub2seed" add sub2.txt
    git -C "$TEST_TMPDIR/sub2seed" commit -q -m sub2
    git -C "$TEST_TMPDIR/sub2seed" remote add origin "$TEST_TMPDIR/sub2.git"
    git -C "$TEST_TMPDIR/sub2seed" push -q -u origin main

    caller="$TEST_TMPDIR/caller_repo"
    git init -q --bare "$TEST_TMPDIR/caller_origin.git"
    git clone -q "$TEST_TMPDIR/caller_origin.git" "$caller"
    git -C "$caller" config user.email "test@example.com"
    git -C "$caller" config user.name "Test User"
    git -C "$caller" checkout -q -b develop
    echo base > "$caller/base.txt"
    git -C "$caller" add base.txt
    git -C "$caller" commit -q -m base
    git -C "$caller" push -q -u origin develop
    git -C "$caller" -c protocol.file.allow=always submodule add -q "$TEST_TMPDIR/sub2.git" sub2
    git -C "$caller" commit -q -m "add submodule to caller"
    git -C "$caller" push -q origin develop

    # Sanity: caller really has its own populated .git/modules — the
    # resource F-1 must not delete.
    [ -d "$caller/.git/modules/sub2" ] || { echo "fixture did not initialize caller's submodule metadata"; false; }

    # "victim" = a separate, unrelated repo's MAIN worktree, with no
    # submodules of its own, targeted with --yes via the single-path form.
    # It cannot itself be folded (git refuses to remove a main working
    # tree) but the bug fires BEFORE that refusal.
    victim="$TEST_TMPDIR/victim_main"
    git init -q --bare "$TEST_TMPDIR/victim_origin.git"
    git clone -q "$TEST_TMPDIR/victim_origin.git" "$victim"
    git -C "$victim" config user.email "test@example.com"
    git -C "$victim" config user.name "Test User"
    git -C "$victim" checkout -q -b develop
    echo v > "$victim/v.txt"
    git -C "$victim" add v.txt
    git -C "$victim" commit -q -m v
    git -C "$victim" push -q -u origin develop

    cd "$caller"
    run bash "$FOLD" "$victim" --yes
    cd "$TEST_TMPDIR"

    [ -d "$caller/.git/modules" ] || { echo "F-1 regressed: caller's .git/modules was deleted entirely. output: $output"; false; }
    [ -d "$caller/.git/modules/sub2" ] || { echo "F-1 regressed: caller's submodule metadata subdir is gone. output: $output"; false; }
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
