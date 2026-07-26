#!/usr/bin/env bash
# Shared helpers for branch policy scripts.

BRANCH_POLICY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRANCH_POLICY_SETTINGS="${BRANCH_POLICY_SETTINGS:-$BRANCH_POLICY_ROOT/config/settings.yaml}"

branch_policy_python() {
    if [[ -x "$BRANCH_POLICY_ROOT/.venv/bin/python3" ]]; then
        printf '%s\n' "$BRANCH_POLICY_ROOT/.venv/bin/python3"
    else
        command -v python3
    fi
}

branch_policy_query() {
    local query="$1"
    local python_bin
    python_bin="$(branch_policy_python)"

    "$python_bin" - "$BRANCH_POLICY_SETTINGS" "$query" "$BRANCH_POLICY_ROOT" <<'PY'
import sys

try:
    import yaml
except Exception as exc:
    raise SystemExit(f"PyYAML is required to read branch_policy: {exc}")

settings_path, query, policy_root = sys.argv[1], sys.argv[2], sys.argv[3]

DEFAULT_POLICY = {
    "allowed_long_lived": ["main", "develop"],
    "short_lived_pattern": r"^codd/[^/]+-[0-9]{8}$",
    "max_age_seconds": 259200,
    "monitored_repos": [{"path": policy_root}],
    "auto_merge_enabled": False,
}

try:
    with open(settings_path, "r", encoding="utf-8") as fh:
        settings = yaml.safe_load(fh) or {}
except FileNotFoundError:
    settings = {}

policy = settings.get("branch_policy")
if not isinstance(policy, dict):
    policy = {}

def policy_get(key):
    value = policy.get(key)
    if value is None:
        return DEFAULT_POLICY[key]
    return value

allowed = policy_get("allowed_long_lived") or []
if not isinstance(allowed, list) or not allowed:
    allowed = DEFAULT_POLICY["allowed_long_lived"]
allowed = [str(item) for item in allowed]

def max_age_seconds() -> int:
    value = policy.get("max_age_seconds", policy.get("max_short_lived_age_seconds"))
    if value is None:
        value = DEFAULT_POLICY["max_age_seconds"]
    return int(value)

if query == "allowed":
    print("\n".join(allowed))
elif query == "primary":
    print(allowed[0])
elif query == "short_lived_pattern":
    pattern = policy.get("short_lived_pattern") or DEFAULT_POLICY["short_lived_pattern"]
    print(str(pattern))
elif query == "max_age_seconds":
    print(max_age_seconds())
elif query == "repos":
    repos = policy.get("monitored_repos") or []
    if not isinstance(repos, list) or not repos:
        repos = DEFAULT_POLICY["monitored_repos"]
    paths = []
    for item in repos:
        if isinstance(item, dict):
            path = item.get("path")
        else:
            path = item
        if path:
            paths.append(str(path))
    if not paths:
        paths = [str(DEFAULT_POLICY["monitored_repos"][0]["path"])]
    print("\n".join(paths))
elif query == "ntfy_topic":
    topic = settings.get("ntfy_topic")
    if topic:
        print(str(topic))
elif query == "auto_merge_enabled":
    print("true" if policy.get("auto_merge_enabled") is True else "false")
else:
    raise SystemExit(f"unknown branch_policy query: {query}")
PY
}

branch_policy_is_allowed_long_lived() {
    local branch="$1"
    local allowed
    while IFS= read -r allowed; do
        [[ "$branch" == "$allowed" ]] && return 0
    done < <(branch_policy_query allowed)
    return 1
}

branch_policy_is_git_repo() {
    local repo_path="$1"
    git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1
}

branch_policy_is_clean_repo() {
    local repo_path="$1"
    [[ -z "$(git -C "$repo_path" status --porcelain)" ]]
}

branch_policy_notify() {
    local message="$1"

    if [[ "${BRANCH_POLICY_DRY_RUN:-0}" == "1" ]]; then
        printf '[DRY-RUN] notify: %s\n' "$message"
        return 0
    fi

    if [[ -x "$BRANCH_POLICY_ROOT/scripts/ntfy_send.sh" ]]; then
        bash "$BRANCH_POLICY_ROOT/scripts/ntfy_send.sh" "$message"
        return $?
    fi

    if [[ -x "$BRANCH_POLICY_ROOT/scripts/ntfy.sh" ]]; then
        bash "$BRANCH_POLICY_ROOT/scripts/ntfy.sh" "$message"
        return $?
    fi

    local topic
    topic="$(branch_policy_query ntfy_topic)"
    if [[ -z "$topic" ]]; then
        printf 'ntfy_topic not configured; notification skipped: %s\n' "$message" >&2
        return 1
    fi

    curl -fsS -d "$message" "https://ntfy.sh/$topic" >/dev/null
}

branch_policy_remote_refs() {
    local repo_path="$1"
    git -C "$repo_path" for-each-ref \
        --format='%(refname)%09%(refname:short)%09%(committerdate:unix)' \
        refs/remotes
}
