#!/usr/bin/env bash
# lib/usage_limit.sh — Type-C (usage limit) stall detection for cmd_171.
#
# Extracted from scripts/ratelimit_check.sh (:209-250), which called the
# Anthropic OAuth usage API inline. scripts/ratelimit_check.sh now sources
# this file so the API-calling code exists in exactly one place.
#
# Public API:
#   usage_limit_fetch_raw          → stdout: KEY=VALUE lines (5H_UTIL=.., ...)
#                                     on success; nothing (non-zero exit) on
#                                     any failure (no creds / no python / API
#                                     unreachable / malformed response).
#   usage_limit_state [agent_id]   → stdout: "limited" | "ok" | "unknown"
#
# usage_limit_state never returns "ok" when the underlying signal could not
# be determined — it returns "unknown" instead (cmd_171 §1.3). The 5-hour
# utilization is a single account-wide figure (one OAuth credential covers
# the whole machine), so the result does not vary by agent_id except for
# the CLI-type gate below.

USAGE_LIMIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=./cli_adapter.sh
source "$USAGE_LIMIT_ROOT/lib/cli_adapter.sh"
# shellcheck source=./stall_policy.sh
source "$USAGE_LIMIT_ROOT/lib/stall_policy.sh"

USAGE_LIMIT_CREDS="${USAGE_LIMIT_CREDS:-$HOME/.claude/.credentials.json}"

usage_limit_python() {
    if [[ -x "$USAGE_LIMIT_ROOT/.venv/bin/python3" ]]; then
        printf '%s\n' "$USAGE_LIMIT_ROOT/.venv/bin/python3"
    else
        command -v python3
    fi
}

# usage_limit_fetch_raw — hits the Anthropic OAuth usage API and prints
# KEY=VALUE lines (same shape scripts/ratelimit_check.sh parses today).
# Returns non-zero and prints nothing if credentials are missing/unreadable,
# python is unavailable, or the API call fails / returns malformed JSON.
usage_limit_fetch_raw() {
    local python_bin
    python_bin="$(usage_limit_python)"

    [[ -f "$USAGE_LIMIT_CREDS" ]] || return 1
    [[ -n "$python_bin" ]] || return 1

    "$python_bin" -c "
import json, subprocess, sys

try:
    with open('${USAGE_LIMIT_CREDS}') as f:
        creds = json.load(f)
except Exception:
    sys.exit(1)

token = creds.get('claudeAiOauth', {}).get('accessToken', '')
if not token:
    sys.exit(1)

try:
    result = subprocess.run([
        'curl', '-s', '-m', '10',
        '-H', f'Authorization: Bearer {token}',
        '-H', 'Accept: application/json',
        '-H', 'anthropic-beta: oauth-2025-04-20',
        'https://api.anthropic.com/api/oauth/usage'
    ], capture_output=True, text=True)
except Exception:
    sys.exit(1)

try:
    data = json.loads(result.stdout)
except Exception:
    sys.exit(1)

fh = data.get('five_hour') or {}
sd = data.get('seven_day') or {}
ss = data.get('seven_day_sonnet') or {}
so = data.get('seven_day_opus') or {}
ex = data.get('extra_usage') or {}

print(f'5H_UTIL={fh.get(\"utilization\", \"?\")}')
print(f'5H_RESET={fh.get(\"resets_at\", \"?\")[:16]}')
print(f'7D_UTIL={sd.get(\"utilization\", \"?\")}')
print(f'7D_RESET={sd.get(\"resets_at\", \"?\")[:10]}')
print(f'7D_SONNET={ss.get(\"utilization\", \"-\")}')
print(f'7D_OPUS={so.get(\"utilization\", \"-\")}')
print(f'EXTRA={ex.get(\"is_enabled\", False)}')
" 2>/dev/null
}

# usage_limit_state [agent_id] → "limited" | "ok" | "unknown"
usage_limit_state() {
    local agent_id="${1:-}"
    local cli

    # OAuth usage API is claude-CLI-only; other CLIs have no equivalent signal.
    cli="$(get_cli_type "$agent_id" 2>/dev/null || echo claude)"
    if [[ "$cli" != "claude" ]]; then
        printf 'unknown\n'
        return 0
    fi

    local ttl now
    ttl="$(stall_policy_query usage_cache_ttl_sec 2>/dev/null || echo 120)"
    now=$(date +%s)

    if [[ -n "${USAGE_LIMIT_CACHE_STATE:-}" ]] \
        && [[ -n "${USAGE_LIMIT_CACHE_TS:-}" ]] \
        && (( now - USAGE_LIMIT_CACHE_TS < ttl )); then
        printf '%s\n' "$USAGE_LIMIT_CACHE_STATE"
        return 0
    fi

    local raw util threshold state
    raw="$(usage_limit_fetch_raw)" || raw=""
    util=$(printf '%s' "$raw" | grep '^5H_UTIL=' | cut -d= -f2)

    if [[ -z "$util" ]] || ! [[ "$util" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        state="unknown"
    else
        threshold="$(stall_policy_query usage_limit_threshold_pct 2>/dev/null || echo 95)"
        if awk -v u="$util" -v t="$threshold" 'BEGIN { exit !(u >= t) }'; then
            state="limited"
        else
            state="ok"
        fi
    fi

    export USAGE_LIMIT_CACHE_STATE="$state"
    export USAGE_LIMIT_CACHE_TS="$now"
    printf '%s\n' "$state"
}
