#!/usr/bin/env bash
# Layer 3: merge stale short-lived remote branches into the configured primary branch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/branch_policy.sh
source "$SCRIPT_DIR/lib/branch_policy.sh"

DRY_RUN=0
NO_FETCH=0
REPO_OVERRIDE=""

usage() {
    cat <<'EOF'
Usage: auto_merge_short_lived.sh [--dry-run] [--no-fetch] [--repo PATH] [--settings PATH]

Finds remote branches matching branch_policy.short_lived_pattern that are older
than branch_policy.max_age_seconds, merges them into the configured primary
branch, pushes the primary branch, and deletes the merged remote branch.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --no-fetch) NO_FETCH=1; shift ;;
        --repo) REPO_OVERRIDE="$2"; shift 2 ;;
        --settings) BRANCH_POLICY_SETTINGS="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

export BRANCH_POLICY_DRY_RUN="$DRY_RUN"

AUTO_MERGE_ENABLED="$(branch_policy_query auto_merge_enabled 2>/dev/null || echo false)"
if [[ "$AUTO_MERGE_ENABLED" != "true" && "$DRY_RUN" != "1" ]]; then
    echo "[SKIP] auto_merge disabled by branch_policy.auto_merge_enabled" >&2
    exit 0
fi

PRIMARY_BRANCH="$(branch_policy_query primary)"
SHORT_LIVED_PATTERN="$(branch_policy_query short_lived_pattern)"
MAX_AGE_SECONDS="$(branch_policy_query max_age_seconds)"
NOW_SECONDS="$(date +%s)"

if [[ -n "$REPO_OVERRIDE" ]]; then
    REPO_PATHS=("$REPO_OVERRIDE")
else
    mapfile -t REPO_PATHS < <(branch_policy_query repos)
fi

merge_short_lived_branch() {
    local repo_path="$1"
    local remote_name="$2"
    local branch_name="$3"
    local full_ref="$4"
    local short_ref="$5"
    local original_branch="$6"

    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[DRY-RUN] would merge $short_ref into $PRIMARY_BRANCH in $repo_path"
        return 0
    fi

    if ! git -C "$repo_path" show-ref --verify --quiet "refs/remotes/$remote_name/$PRIMARY_BRANCH"; then
        branch_policy_notify "auto-merge skipped: $remote_name/$PRIMARY_BRANCH not found in $repo_path"
        return 0
    fi

    if git -C "$repo_path" show-ref --verify --quiet "refs/heads/$PRIMARY_BRANCH"; then
        git -C "$repo_path" checkout "$PRIMARY_BRANCH"
    else
        git -C "$repo_path" checkout -B "$PRIMARY_BRANCH" "$remote_name/$PRIMARY_BRANCH"
    fi

    git -C "$repo_path" pull --ff-only "$remote_name" "$PRIMARY_BRANCH"

    if git -C "$repo_path" merge --no-edit "$full_ref"; then
        git -C "$repo_path" push "$remote_name" "$PRIMARY_BRANCH"
        git -C "$repo_path" push "$remote_name" --delete "$branch_name"

        if git -C "$repo_path" show-ref --verify --quiet "refs/heads/$branch_name"; then
            git -C "$repo_path" branch -d "$branch_name" || true
        fi

        branch_policy_notify "auto-merged short-lived branch: $short_ref in $repo_path"
    else
        git -C "$repo_path" merge --abort >/dev/null 2>&1 || true
        branch_policy_notify "auto-merge conflict: $short_ref in $repo_path; skipped"
    fi

    if [[ -n "$original_branch" && "$original_branch" != "$PRIMARY_BRANCH" ]]; then
        git -C "$repo_path" checkout "$original_branch" >/dev/null 2>&1 || true
    fi
}

for repo_path in "${REPO_PATHS[@]}"; do
    if ! branch_policy_is_git_repo "$repo_path"; then
        echo "[SKIP] not a git repo: $repo_path" >&2
        continue
    fi

    if ! branch_policy_is_clean_repo "$repo_path"; then
        message="auto-merge skipped: dirty worktree in $repo_path"
        if [[ "$DRY_RUN" == "1" ]]; then
            echo "[DRY-RUN] $message"
        else
            echo "[SKIP] $message" >&2
            branch_policy_notify "$message"
            continue
        fi
    fi

    if [[ "$DRY_RUN" == "1" || "$NO_FETCH" == "1" ]]; then
        echo "[INFO] fetch skipped: $repo_path"
    else
        if ! git -C "$repo_path" fetch --all --prune; then
            branch_policy_notify "auto-merge fetch failed in $repo_path"
            continue
        fi
    fi

    original_branch="$(git -C "$repo_path" branch --show-current || true)"

    while IFS=$'\t' read -r full_ref short_ref commit_seconds; do
        [[ -z "${short_ref:-}" ]] && continue
        [[ "$full_ref" == refs/remotes/*/HEAD ]] && continue
        [[ "$short_ref" == */HEAD ]] && continue

        remote_name="${short_ref%%/*}"
        branch_name="${short_ref#*/}"

        if branch_policy_is_allowed_long_lived "$branch_name"; then
            continue
        fi

        if [[ ! "$branch_name" =~ $SHORT_LIVED_PATTERN ]]; then
            continue
        fi

        if [[ -z "${commit_seconds:-}" || "$commit_seconds" == "0" ]]; then
            echo "[SKIP] no commit timestamp: $repo_path $short_ref" >&2
            continue
        fi

        age_seconds=$((NOW_SECONDS - commit_seconds))
        if (( age_seconds <= MAX_AGE_SECONDS )); then
            echo "[OK] short-lived branch still fresh: $repo_path $short_ref age=${age_seconds}s"
            continue
        fi

        echo "[CANDIDATE] $repo_path $short_ref age=${age_seconds}s"
        merge_short_lived_branch "$repo_path" "$remote_name" "$branch_name" "$full_ref" "$short_ref" "$original_branch"
    done < <(branch_policy_remote_refs "$repo_path")
done
