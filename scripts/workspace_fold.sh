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

Checks a git worktree against 7 safety conditions (C1-C7) before folding
it with `git worktree remove`. Default is dry-run: conditions are
reported but nothing is removed. Pass --yes to actually fold.

--sweep      Check every worktree registered under this repo (except the
             main worktree) instead of a single path.
--base       Base branch to check "landed" status against (default: develop).
             Assumes origin/<base> is up to date locally; this script does
             not fetch on your behalf.

Exit status: 0 if no removal was attempted or all attempted removals
succeeded; 1 if any target failed a safety condition or a removal failed.
EOF
}

MODE=""
TARGET_PATH=""
DO_YES=0
BASE_BRANCH="$DEFAULT_BASE_BRANCH"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sweep) MODE="sweep"; shift ;;
        --yes) DO_YES=1; shift ;;
        --base) BASE_BRANCH="$2"; shift 2 ;;
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
c2_no_unpushed_commits() {
    local path="$1" upstream ahead
    if ! upstream="$(git -C "$path" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>&1)"; then
        echo "no upstream tracking branch configured; cannot verify pushed state"
        return 1
    fi
    ahead="$(git -C "$path" log "${upstream}..HEAD" --oneline 2>&1)"
    if [[ -n "$ahead" ]]; then
        echo "unpushed commits ahead of $upstream: $(echo "$ahead" | wc -l) commit(s)"
        return 1
    fi
    return 0
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
    local path="$1" canon
    canon="$(resolve_path "$path")"

    if [[ -d /proc ]]; then
        local p cwd pid
        for p in /proc/[0-9]*; do
            [[ -e "$p/cwd" ]] || continue
            cwd="$(readlink -f "$p/cwd" 2>/dev/null)" || continue
            if [[ "$cwd" == "$canon" || "$cwd" == "$canon"/* ]]; then
                pid="${p#/proc/}"
                echo "process $pid has cwd under $canon"
                return 1
            fi
        done
        return 0
    fi

    if command -v lsof >/dev/null 2>&1; then
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

# C6: the branch has landed on the base branch (merged PR, or nothing
# unique left ahead of base). "Clean" and "done" are different things;
# this checks "done".
c6_branch_landed() {
    local path="$1" base="$2" branch ahead merged
    branch="$(git -C "$path" branch --show-current)"
    if [[ -z "$branch" ]]; then
        echo "detached HEAD; cannot determine branch identity"
        return 1
    fi
    if ! ahead="$(git -C "$path" rev-list --count "origin/${base}..HEAD" 2>&1)"; then
        echo "cannot resolve origin/$base locally to check landing status: $ahead"
        return 1
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
    echo "branch '$branch' has $ahead commit(s) ahead of origin/$base and no merged PR found"
    return 1
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

    for check in c1_status_clean:C1 c2_no_unpushed_commits:C2 c3_no_stash:C3 c4_no_data_files:C4 c5_no_live_process:C5; do
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

# Folds one worktree: assumes check_worktree already passed.
fold_worktree() {
    local path="$1" canon branch main_repo
    canon="$(resolve_path "$path")"
    branch="$(git -C "$canon" branch --show-current)"
    main_repo="$(git -C "$canon" worktree list --porcelain | awk '/^worktree /{print substr($0,10); exit}')"

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
    local main_repo
    main_repo="$(git worktree list --porcelain | awk '/^worktree /{print substr($0,10); exit}')"
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
    return 0
}

case "$MODE" in
    single) run_single "$TARGET_PATH" ;;
    sweep) run_sweep ;;
esac
