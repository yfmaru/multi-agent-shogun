#!/usr/bin/env bash
# Folds a git worktree once it is safe to do so (cmd_222).
# Safety is defined by 7 conditions (C1-C7); see
# queue/reports/gunshi_design_222_workspace_cleanup_convention.yaml §3-§5
# for the full rationale. Default is dry-run; nothing is ever removed
# without --yes. The unsafe override flags for worktree/branch removal
# are intentionally never used anywhere in this script (see
# test_workspace_fold.bats "no unsafe override flags").
set -euo pipefail

DEFAULT_BASE_BRANCH="develop"
DATA_FILE_MAXDEPTH=3

usage() {
    cat <<'EOF'
Usage:
  workspace_fold.sh <worktree_path> [--yes] [--base BRANCH]
  workspace_fold.sh --sweep [--yes] [--base BRANCH]
  workspace_fold.sh --strays

Checks a git worktree against 7 safety conditions (C1-C7) before folding
it with `git worktree remove`. Default is dry-run: conditions are
reported but nothing is removed. Pass --yes to actually fold.

--sweep      Check every worktree registered under this repo (except the
             main worktree) instead of a single path.
--strays     Read-only inventory of non-production tmux sessions (per
             CLAUDE.md Test Rules 5). Never removes anything and refuses
             --yes outright — folding a tmux session is not something an
             agent can do (D006 forbids `tmux kill-session`); this only
             reports what exists, so the lord can decide. Also printed
             automatically at the end of --sweep.
--base       Base branch to check "landed" status against (default: develop).
             Assumes origin/<base> is up to date locally; this script does
             not fetch on your behalf.

Exit status:
  Single target: 0 if no removal was attempted or the removal succeeded;
                 1 if a safety condition failed or the removal failed.
  --sweep:       always 0, regardless of how many targets were blocked —
                 a blocked in-progress workspace is the normal steady
                 state for a sweep. Read the SWEEP SUMMARY line for
                 foldable/folded/blocked counts.
  --strays:      0 on a normal report (including "nothing found" and "no
                 tmux on this host"); 2 if --yes was also passed.
EOF
}

MODE=""
TARGET_PATH=""
DO_YES=0
BASE_BRANCH="$DEFAULT_BASE_BRANCH"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sweep) MODE="sweep"; shift ;;
        --strays) MODE="strays"; shift ;;
        --yes) DO_YES=1; shift ;;
        --base)
            if [[ $# -lt 2 ]]; then
                echo "--base requires an argument" >&2; usage >&2; exit 2
            fi
            BASE_BRANCH="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)
            if [[ -n "$MODE" ]]; then
                echo "Unexpected extra argument: $1" >&2; usage >&2; exit 2
            fi
            TARGET_PATH="$1"; MODE="single"; shift ;;
    esac
done

if [[ -z "$MODE" ]]; then
    usage >&2
    exit 2
fi

# --strays is read-only by design (CLAUDE.md Test Rules 5): folding a tmux
# session means `tmux kill-session`, which D006 forbids an agent from ever
# running. Accepting --yes here would be an open door to that violation,
# so it is refused outright rather than silently ignored.
if [[ "$MODE" == "strays" && "$DO_YES" -eq 1 ]]; then
    echo "REFUSED: --strays is read-only and does not accept --yes (D006: an agent may never run tmux kill-session)." >&2
    exit 2
fi

# Portable absolute-path resolution. Deliberately avoids GNU-only
# `realpath -m` (BSD/macOS realpath lacks -m and requires the path to
# exist) — uses only cd+pwd -P, which both platforms' shells provide.
resolve_path() {
    local target="$1" dir base
    if [[ -d "$target" ]]; then
        (cd "$target" 2>/dev/null && pwd -P)
        return
    fi
    dir="$(dirname "$target")"
    base="$(basename "$target")"
    if [[ -d "$dir" ]]; then
        printf '%s/%s\n' "$(cd "$dir" 2>/dev/null && pwd -P)" "$base"
    else
        printf '%s\n' "$target"
    fi
}

# ---------------------------------------------------------------------------
# C7: is this a directory git itself tracks as a worktree of some repo?
# Anything else (a raw directory) is out of an agent's reach per D002.
# ---------------------------------------------------------------------------
c7_is_registered_worktree() {
    local path="$1" canon
    canon="$(resolve_path "$path")"
    if [[ -z "$canon" ]]; then
        echo "cannot resolve path: $path"
        return 1
    fi
    if [[ ! -d "$canon" ]]; then
        echo "path does not exist: $canon"
        return 1
    fi
    if ! git -C "$canon" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "not a git-managed directory; D002 applies, requires the lord's own hand"
        return 1
    fi
    local wt found=0
    while IFS= read -r wt; do
        if [[ "$(resolve_path "$wt")" == "$canon" ]]; then
            found=1
            break
        fi
    done < <(git -C "$canon" worktree list --porcelain | awk '/^worktree /{print substr($0,10)}')
    if [[ "$found" -ne 1 ]]; then
        echo "not registered in 'git worktree list'; raw directory, D002 applies, requires the lord's own hand"
        return 1
    fi
    return 0
}

# C1: no uncommitted changes.
c1_status_clean() {
    local path="$1" out
    out="$(git -C "$path" status --porcelain 2>&1)"
    if [[ -n "$out" ]]; then
        echo "uncommitted changes present: $(echo "$out" | head -1)"
        return 1
    fi
    return 0
}

# C2: no commits that exist only locally (unpushed).
#
# `@{u}` is unresolvable once the remote branch is deleted post-merge —
# the normal state right after `gh pr merge --delete-branch`, which is
# also the moment this script is most needed (design §3 C2 caveat).
# When that happens, judge by landing instead of refusing outright:
# see branch_has_landed().
c2_no_unpushed_commits() {
    local path="$1" base="$2" upstream ahead branch rc
    if upstream="$(git -C "$path" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>&1)"; then
        ahead="$(git -C "$path" log "${upstream}..HEAD" --oneline 2>&1)"
        if [[ -n "$ahead" ]]; then
            echo "unpushed commits ahead of $upstream: $(echo "$ahead" | wc -l) commit(s)"
            return 1
        fi
        return 0
    fi

    branch="$(git -C "$path" branch --show-current)"
    if [[ -z "$branch" ]]; then
        echo "no upstream tracking branch configured, and detached HEAD; cannot verify pushed state"
        return 1
    fi
    branch_has_landed "$path" "$base" "$branch" && rc=0 || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        return 0
    fi
    echo "no upstream tracking branch configured, and branch '$branch' has not landed on origin/$base"
    return 1
}

# C3: no stash entries. Stash is shared across all worktrees of a repo
# (one .git), so this is a repository-wide check, not a per-worktree one.
c3_no_stash() {
    local path="$1" out
    out="$(git -C "$path" stash list 2>&1)"
    if [[ -n "$out" ]]; then
        echo "stash is not empty (repo-wide): $(echo "$out" | head -1)"
        return 1
    fi
    return 0
}

# C4: no data/secret files. git status does not surface gitignored files,
# so this must be checked separately from C1.
c4_no_data_files() {
    local path="$1" hits
    hits="$(find "$path" -maxdepth "$DATA_FILE_MAXDEPTH" \
        \( -name '*.db' -o -name '*.sqlite*' -o -name '.env' -o -name '*.pem' -o -name '*.key' \) \
        -not -path '*/node_modules/*' 2>/dev/null)"
    if [[ -n "$hits" ]]; then
        echo "data/secret files present: $(echo "$hits" | head -3 | tr '\n' ' ')"
        return 1
    fi
    return 0
}

# C5: no live process holds this directory (or a subdirectory) as its cwd.
# Deleting a process's cwd out from under it succeeds silently on Linux;
# git does not detect this. /proc is Linux-only; on platforms without it
# (macOS/BSD) this falls back to lsof. If neither is available, this fails
# closed (refuses to fold) rather than silently reporting "clear".
c5_no_live_process() {
    local path="$1" canon proc_dir
    canon="$(resolve_path "$path")"
    # WORKSPACE_FOLD_PROC_DIR exists solely so tests can exercise the
    # "neither /proc nor lsof available" fail-closed branch below without
    # actually hiding /proc on the host. Unset/default is always /proc.
    proc_dir="${WORKSPACE_FOLD_PROC_DIR:-/proc}"

    if [[ -d "$proc_dir" ]]; then
        local p cwd pid
        for p in "$proc_dir"/[0-9]*; do
            [[ -e "$p/cwd" ]] || continue
            cwd="$(readlink -f "$p/cwd" 2>/dev/null)" || continue
            if [[ "$cwd" == "$canon" || "$cwd" == "$canon"/* ]]; then
                pid="${p##*/}"
                echo "process $pid has cwd under $canon"
                return 1
            fi
        done
        return 0
    fi

    # WORKSPACE_FOLD_LSOF_BIN exists solely so tests can exercise the
    # "neither /proc nor lsof available" fail-closed branch below without
    # stripping lsof's real directory from PATH (which, on this platform,
    # also holds git/bash and would break the test harness itself).
    # Unset/default is always the real "lsof".
    if command -v "${WORKSPACE_FOLD_LSOF_BIN:-lsof}" >/dev/null 2>&1; then
        local hit
        hit="$(lsof -a -d cwd +D "$canon" 2>/dev/null | awk 'NR>1')"
        if [[ -n "$hit" ]]; then
            echo "a process holds $canon as cwd (lsof): $(echo "$hit" | head -1)"
            return 1
        fi
        return 0
    fi

    echo "cannot verify: neither /proc nor lsof is available on this platform"
    return 1
}

# Shared by C2's no-upstream fallback and C6: has $branch (checked out at
# HEAD in $path) landed on origin/$base — either because it's an ancestor
# (nothing unique left ahead), or because a merged PR already carried its
# content in (squash-merge, so the commits themselves never become
# ancestors)? "Clean" and "done" are different things; this checks "done".
#
# Returns: 0 landed, 1 not landed, 2 cannot determine (origin/$base does
# not resolve locally — caller must fetch first).
branch_has_landed() {
    local path="$1" base="$2" branch="$3" ahead merged
    if ! ahead="$(git -C "$path" rev-list --count "origin/${base}..HEAD" 2>&1)"; then
        return 2
    fi
    if [[ "$ahead" =~ ^[0-9]+$ ]] && [[ "$ahead" -eq 0 ]]; then
        return 0
    fi
    if command -v gh >/dev/null 2>&1; then
        merged="$(cd "$path" && gh pr list --state all --head "$branch" \
            --json mergedAt --jq '.[] | select(.mergedAt != null) | .mergedAt' 2>/dev/null | head -1 || true)"
        if [[ -n "$merged" ]]; then
            return 0
        fi
    fi
    return 1
}

# C6: the branch has landed on the base branch. See branch_has_landed().
c6_branch_landed() {
    local path="$1" base="$2" branch rc
    branch="$(git -C "$path" branch --show-current)"
    if [[ -z "$branch" ]]; then
        echo "detached HEAD; cannot determine branch identity"
        return 1
    fi
    branch_has_landed "$path" "$base" "$branch" && rc=0 || rc=$?
    case "$rc" in
        0) return 0 ;;
        2) echo "cannot resolve origin/$base locally to check landing status"; return 1 ;;
        *) echo "branch '$branch' has commit(s) ahead of origin/$base and no merged PR found"; return 1 ;;
    esac
}

# Runs C1-C7 against one worktree path, printing one line per condition.
# Returns 0 iff all 7 conditions pass.
check_worktree() {
    local path="$1" base="$2" fail=0 msg

    if ! msg="$(c7_is_registered_worktree "$path")"; then
        echo "[FAIL] C7 ($path): $msg"
        return 1
    fi
    echo "[OK]   C7 ($path): registered worktree"

    if msg="$(c1_status_clean "$path")"; then
        echo "[OK]   C1 ($path)"
    else
        echo "[FAIL] C1 ($path): $msg"
        fail=1
    fi

    if msg="$(c2_no_unpushed_commits "$path" "$base")"; then
        echo "[OK]   C2 ($path)"
    else
        echo "[FAIL] C2 ($path): $msg"
        fail=1
    fi

    for check in c3_no_stash:C3 c4_no_data_files:C4 c5_no_live_process:C5; do
        local fn="${check%%:*}" id="${check##*:}"
        if msg="$($fn "$path")"; then
            echo "[OK]   $id ($path)"
        else
            echo "[FAIL] $id ($path): $msg"
            fail=1
        fi
    done

    if msg="$(c6_branch_landed "$path" "$base")"; then
        echo "[OK]   C6 ($path)"
    else
        echo "[FAIL] C6 ($path): $msg"
        fail=1
    fi

    return "$fail"
}

# Clears whatever blocks `git worktree remove` when $canon initialized
# submodules at some point (cmd_222 follow-up: 40/42 real worktrees hit
# `fatal: working trees containing submodules cannot be moved or
# removed`). Empirically, `git submodule deinit --all -f` ALONE does not
# clear the block — git still refuses afterward. The actual gate is
# $canon's own git-dir/modules directory (created the first time
# `git submodule update --init` runs in THIS worktree; separate from the
# shared $main_repo/.git/modules object store), and it survives deinit.
# Both steps are required, in this order: deinit first (clears the
# submodule's working-tree checkout and gitlink so the directory doesn't
# end up as a dangling `.git` pointer), then remove that leftover
# metadata directory. A worktree that never initialized any submodule
# has no such directory and is left untouched (no-op).
deinit_worktree_submodules() {
    local canon="$1" wt_gitdir
    wt_gitdir="$(git -C "$canon" rev-parse --absolute-git-dir)"
    [[ "$wt_gitdir" == */worktrees/* ]] || return 0
    [[ -d "$wt_gitdir/modules" ]] || return 0
    git -C "$canon" submodule deinit --all -f
    rm -rf "$wt_gitdir/modules"
}

# Folds one worktree: assumes check_worktree already passed.
fold_worktree() {
    local path="$1" canon branch main_repo wt_list
    canon="$(resolve_path "$path")"
    branch="$(git -C "$canon" branch --show-current)"
    # SIGPIPE-safe main_repo lookup (see run_sweep() for rationale):
    # capture the full `git worktree list --porcelain` output via command
    # substitution first (which waits for git to finish), THEN feed the
    # already-complete string to awk's early-exit. Piping git directly into
    # an early-exiting awk risks SIGPIPE if git is still writing when awk
    # closes the pipe — this becomes a near-certain crash once the repo has
    # dozens of worktrees (cmd_222 follow-up, discovered post-merge of PR#107).
    wt_list="$(git -C "$canon" worktree list --porcelain)"
    main_repo="$(printf '%s\n' "$wt_list" | awk '/^worktree /{print substr($0,10); exit}')"

    # A main worktree is never an agent's to fold (git refuses it anyway), and
    # reaching deinit_worktree_submodules() with one would delete that repo's
    # SHARED submodule store before git's refusal ever lands. run_sweep() skips
    # the main worktree, but the single-path form has no such exclusion.
    if [[ "$canon" == "$(resolve_path "$main_repo")" ]]; then
        echo "ABORT: $canon is the main worktree of its repository; not an agent's to fold"
        return 1
    fi

    deinit_worktree_submodules "$canon"

    if ! git -C "$main_repo" worktree remove "$canon"; then
        echo "ABORT: git worktree remove refused for $canon (git's own safety check declined; not overridden)"
        return 1
    fi
    echo "FOLDED: $canon"

    if [[ -n "$branch" ]]; then
        if git -C "$main_repo" branch -d "$branch" >/dev/null 2>&1; then
            echo "BRANCH REMOVED: $branch"
        else
            echo "BRANCH KEPT: $branch (git declined a plain delete; worktree is already gone, this is harmless)"
        fi
    fi

    git -C "$main_repo" worktree prune
    return 0
}

run_single() {
    local path="$1"
    if check_worktree "$path" "$BASE_BRANCH"; then
        if [[ "$DO_YES" -eq 1 ]]; then
            fold_worktree "$path"
            return $?
        fi
        echo "DRY-RUN: all 7 conditions satisfied for $path. Re-run with --yes to fold."
        return 0
    fi
    echo "REFUSED: $path did not satisfy all safety conditions; not folded."
    return 1
}

run_sweep() {
    local main_repo wt_list
    # SIGPIPE-safe main_repo lookup: capture the full porcelain output via
    # command substitution first (command substitution waits for the
    # producer to finish, so this cannot race), THEN let awk early-exit on
    # the already-complete string. Piping `git worktree list --porcelain`
    # directly into an early-exiting `awk '...; exit}'` risks SIGPIPE when
    # git is still writing remaining worktrees at the moment awk closes the
    # pipe — under `set -euo pipefail` this kills the whole script (exit
    # 141), reproducibly once the repo has dozens of worktrees.
    wt_list="$(git worktree list --porcelain)"
    main_repo="$(printf '%s\n' "$wt_list" | awk '/^worktree /{print substr($0,10); exit}')"
    if [[ -z "$main_repo" ]]; then
        echo "not inside a git repository; --sweep requires running from within one" >&2
        return 1
    fi

    local wt folded=0 blocked=0
    while IFS= read -r wt; do
        [[ "$(resolve_path "$wt")" == "$(resolve_path "$main_repo")" ]] && continue
        if check_worktree "$wt" "$BASE_BRANCH"; then
            if [[ "$DO_YES" -eq 1 ]]; then
                fold_worktree "$wt" && folded=$((folded + 1)) || blocked=$((blocked + 1))
            else
                echo "DRY-RUN: all 7 conditions satisfied for $wt. Re-run with --yes to fold."
                folded=$((folded + 1))
            fi
        else
            echo "REFUSED: $wt did not satisfy all safety conditions; not folded."
            blocked=$((blocked + 1))
        fi
    done < <(git -C "$main_repo" worktree list --porcelain | awk '/^worktree /{print substr($0,10)}')

    git -C "$main_repo" worktree prune
    echo "SWEEP SUMMARY: foldable/folded=$folded blocked=$blocked"
    print_strays_report
    return 0
}

# ---------------------------------------------------------------------------
# --strays (cmd_225): read-only tmux-session inventory. Never folds anything.
#
# The naming convention `scratch_<agent>_<cmd>_<label>` (CLAUDE.md Test
# Rules 5) exists so this can tell production sessions apart from ones an
# agent spun up for verification. But per the design's pre_mortem, listing
# is done by EXCLUSION (everything except the two production names), never
# by INCLUSION (only names matching scratch_*) — an inclusion list would
# let a misnamed stray slip through the exact same way the underlying bug
# class does: something not on the list goes unnoticed. Misnamed sessions
# are instead surfaced as their own [NAMING-VIOLATION] category below.
# ---------------------------------------------------------------------------
STRAY_SESSION_PREFIX="scratch_"
STRAY_PRODUCTION_SESSIONS=(multiagent shogun)
STRAY_STALE_AGE_SECONDS=1800

is_production_session() {
    local name="$1" prod
    for prod in "${STRAY_PRODUCTION_SESSIONS[@]}"; do
        [[ "$name" == "$prod" ]] && return 0
    done
    return 1
}

# Lists "<name> <created_epoch>", one per line, for every tmux session
# except the production ones. A host with no tmux (or no server running)
# is a normal environment for this repo (CI, a fresh checkout) — never an
# error, so this returns an empty list rather than failing.
list_stray_sessions() {
    command -v tmux >/dev/null 2>&1 || return 0
    local line name created
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        name="${line%% *}"
        created="${line#* }"
        is_production_session "$name" && continue
        printf '%s %s\n' "$name" "$created"
    done < <(tmux list-sessions -F '#{session_name} #{session_created}' 2>/dev/null)
    return 0
}

# Lists "<session_name> <pane_current_path>" for every pane of every
# non-production session (a session can have several windows/panes, each
# with its own cwd — this is why cmd220_probe's 4 windows all had to be
# checked individually, not just the session's first pane).
list_stray_panes() {
    command -v tmux >/dev/null 2>&1 || return 0
    local line name path
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        name="${line%% *}"
        path="${line#* }"
        is_production_session "$name" && continue
        printf '%s %s\n' "$name" "$path"
    done < <(tmux list-panes -a -F '#{session_name} #{pane_current_path}' 2>/dev/null)
    return 0
}

# Is $1 inside a registered *feature* worktree (i.e. would this pane's cwd
# make C5 refuse that workspace's fold)? The main working tree is
# deliberately excluded — it is never folded by this script, so a pane
# sitting there (as the 2026-08-09 `livefire999` specimen did) blocks
# nothing (design_6: "作業場を掴んではおらぬゆえ今は誰も阻んでいない").
# Uses the same capture-then-awk pattern as fold_worktree()/run_sweep()
# to avoid the SIGPIPE race documented there.
stray_blocks_worktree() {
    local cwd="$1" wt_list first=1 wt canon_cwd
    command -v git >/dev/null 2>&1 || return 1
    # Canonicalize both sides before comparing. A real tmux pane_current_path
    # is already symlink-resolved, so this is normally a no-op — but on
    # hosts where the tmp/worktree root itself is a symlink (e.g. macOS's
    # /tmp -> /private/tmp), comparing a raw path against `resolve_path`'s
    # canonical worktree form would false-negative.
    canon_cwd="$(resolve_path "$cwd")"
    [[ -z "$canon_cwd" ]] && canon_cwd="$cwd"
    wt_list="$(git worktree list --porcelain 2>/dev/null)" || return 1
    [[ -z "$wt_list" ]] && return 1
    while IFS= read -r wt; do
        [[ -z "$wt" ]] && continue
        if [[ "$first" -eq 1 ]]; then
            first=0
            continue
        fi
        wt="$(resolve_path "$wt")"
        if [[ "$canon_cwd" == "$wt" || "$canon_cwd" == "$wt"/* ]]; then
            printf '%s\n' "$wt"
            return 0
        fi
    done < <(printf '%s\n' "$wt_list" | awk '/^worktree /{print substr($0,10)}')
    return 1
}

print_strays_report() {
    command -v tmux >/dev/null 2>&1 || return 0

    local sessions
    sessions="$(list_stray_sessions)"
    if [[ -z "$sessions" ]]; then
        echo "STRAYS: no non-production tmux sessions found."
        return 0
    fi

    echo "STRAYS: non-production tmux sessions (multiagent/shogun always excluded):"
    local now line name created age note wt
    now="$(date +%s)"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        name="${line%% *}"
        created="${line#* }"
        age=$(( now - created ))
        note=""
        if [[ "$name" != ${STRAY_SESSION_PREFIX}* ]]; then
            note=" [NAMING-VIOLATION: does not follow scratch_<agent>_<cmd>_<label>]"
        elif [[ "$age" -gt "$STRAY_STALE_AGE_SECONDS" ]]; then
            note=" [STALE: age ${age}s exceeds the ${STRAY_STALE_AGE_SECONDS}s Test Rules 5 default despite scratch_* naming]"
        fi
        echo "STRAY_SESSION: $name age=${age}s${note}"

        while IFS= read -r pane_line; do
            [[ -z "$pane_line" ]] && continue
            [[ "${pane_line%% *}" == "$name" ]] || continue
            local pane_cwd="${pane_line#* }" blocked=""
            if wt="$(stray_blocks_worktree "$pane_cwd")"; then
                blocked=" [BLOCKS C5 of workspace: $wt]"
            fi
            echo "  PANE_CWD: $pane_cwd$blocked"
        done < <(list_stray_panes)
    done <<< "$sessions"

    echo "STRAYS: to remove, the lord's own hand only — D006 forbids an agent from running these:"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        echo "  tmux kill-session -t ${line%% *}"
    done <<< "$sessions"
    return 0
}

run_strays() {
    print_strays_report
    return 0
}

case "$MODE" in
    single) run_single "$TARGET_PATH" ;;
    sweep) run_sweep ;;
    strays) run_strays ;;
esac
