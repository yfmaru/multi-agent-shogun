#!/usr/bin/env bash
# Layer 3 (cmd_201): periodic stale-issue-comment audit.
# Flags comments on open GitHub issues that are >=24h old AND have at least
# one PR merged since the comment was posted. This script only enumerates
# candidates for a human (gunshi) to re-read -- it never judges whether a
# comment actually went stale. See queue/reports/gunshi_199_stale_issue_analysis.yaml.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/branch_policy.sh
source "$SCRIPT_DIR/lib/branch_policy.sh"

DRY_RUN=0
STALE_THRESHOLD_SECONDS=$((24 * 3600))

usage() {
    cat <<'EOF'
Usage: stale_issue_audit.sh [--dry-run] [--settings PATH]

Scans branch_policy.monitored_repos for open GitHub issues whose comments
are older than 24h AND have at least one PR merged since the comment was
posted. Candidates are not judged stale here -- a human (gunshi) must
re-read them. Sends one inbox message to karo if any candidates are found;
sends nothing if none are found (a quiet day should stay quiet).
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --settings) BRANCH_POLICY_SETTINGS="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

export BRANCH_POLICY_DRY_RUN="$DRY_RUN"

NOW_SECONDS="$(date -u +%s)"
mapfile -t REPO_PATHS < <(branch_policy_query repos)
echo "[INFO] monitoring ${#REPO_PATHS[@]} repositories"

CANDIDATES_FILE="$(mktemp)"
trap 'rm -f "$CANDIDATES_FILE"' EXIT

for repo_path in "${REPO_PATHS[@]}"; do
    if ! branch_policy_is_git_repo "$repo_path"; then
        echo "[SKIP] not a git repo: $repo_path" >&2
        continue
    fi

    remote_url="$(git -C "$repo_path" remote get-url origin 2>/dev/null || true)"
    if [[ -z "$remote_url" ]]; then
        echo "[SKIP] no origin remote: $repo_path" >&2
        continue
    fi

    owner_repo="$(printf '%s\n' "$remote_url" | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')"
    if [[ -z "$owner_repo" ]]; then
        echo "[SKIP] could not derive owner/repo from remote: $repo_path ($remote_url)" >&2
        continue
    fi

    echo "[INFO] checking $owner_repo ($repo_path)"

    issues_json="$(gh issue list --state open --json number,comments --repo "$owner_repo" --limit 200 2>&1)" || {
        echo "[SKIP] gh issue list failed: $owner_repo" >&2
        continue
    }

    while IFS=$'\t' read -r number url created_at; do
        [[ -z "${number:-}" ]] && continue

        created_epoch="$(date -u -d "$created_at" +%s 2>/dev/null || true)"
        if [[ -z "$created_epoch" ]]; then
            echo "[SKIP] unparseable comment timestamp: $owner_repo #$number ($created_at)" >&2
            continue
        fi

        age_seconds=$((NOW_SECONDS - created_epoch))
        if (( age_seconds < STALE_THRESHOLD_SECONDS )); then
            continue
        fi

        merged_json="$(gh pr list --state merged --repo "$owner_repo" \
            --search "merged:>$created_at" --json number --limit 200 2>/dev/null || echo '[]')"
        merged_count="$(printf '%s' "$merged_json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)"

        if (( merged_count > 0 )); then
            printf '%s\t%s\t%s\t%s\t%s\n' "$owner_repo" "$number" "$url" "$created_at" "$merged_count" >> "$CANDIDATES_FILE"
            echo "[CANDIDATE] $owner_repo #$number: $url (posted $created_at, ${merged_count} PR(s) merged since)"
        fi
    done < <(printf '%s' "$issues_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for issue in data:
    for c in issue.get("comments", []):
        print("{}\t{}\t{}".format(issue["number"], c["url"], c["createdAt"]))
')
done

if [[ -s "$CANDIDATES_FILE" ]]; then
    message_file="$(mktemp)"
    trap 'rm -f "$CANDIDATES_FILE" "$message_file"' EXIT
    {
        echo "陳腐化候補（要再確認・自動判定なし。判定は軍師が読んで行うこと）:"
        while IFS=$'\t' read -r owner_repo number url created_at merged_count; do
            echo "- ${owner_repo} #${number}: ${url} (投稿 ${created_at}, 以後マージされたPR ${merged_count}件)"
        done < "$CANDIDATES_FILE"
    } > "$message_file"

    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[DRY-RUN] would notify karo with:"
        cat "$message_file"
    else
        bash "$SCRIPT_DIR/scripts/inbox_write.sh" --to karo --content-file "$message_file" \
            --type stale_issue_alert --from stale_issue_audit
    fi
else
    echo "[OK] no stale issue comment candidates"
fi
