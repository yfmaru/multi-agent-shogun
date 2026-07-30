#!/usr/bin/env bash
set -euo pipefail

# Keep inbox watchers alive in a persistent tmux-hosted shell.
# This script is designed to run forever.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

source "$SCRIPT_DIR/lib/agent_registry.sh"

mkdir -p logs queue/inbox

get_multiagent_pane_base() {
    if [ -n "${SHOGUN_PANE_BASE:-}" ]; then
        echo "$SHOGUN_PANE_BASE"
        return 0
    fi
    tmux show-options -gv pane-base-index 2>/dev/null || echo 0
}

ensure_inbox_file() {
    local agent="$1"
    if [ ! -f "queue/inbox/${agent}.yaml" ]; then
        printf 'messages: []\n' > "queue/inbox/${agent}.yaml"
    fi
}

pane_exists() {
    local pane="$1"
    tmux list-panes -a -F "#{session_name}:#{window_name}.#{pane_index}" 2>/dev/null | grep -qx "$pane"
}

start_watcher_if_missing() {
    local agent="$1"
    local pane="$2"
    local log_file="$3"
    local cli
    local lockfile="/tmp/shogun_watcher_start_${agent}.lock"

    ensure_inbox_file "$agent"
    if ! pane_exists "$pane"; then
        return 0
    fi

    (
        flock -n 9 || return 0
        if pgrep -Ef "scripts/inbox_watcher.sh ${agent} ${pane}( |$)" >/dev/null 2>&1; then
            return 0
        fi

        if pgrep -f "scripts/inbox_watcher.sh ${agent} " >/dev/null 2>&1; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] stale watcher detected for ${agent} (pane mismatch with expected ${pane}); not starting a new one to avoid duplicates. Resolve pane mismatch manually." >&2
            return 0
        fi

        cli=$(tmux show-options -p -t "$pane" -v @agent_cli 2>/dev/null || echo "codex")
        nohup bash scripts/inbox_watcher.sh "$agent" "$pane" "$cli" >> "$log_file" 2>&1 &
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [START] inbox_watcher started for ${agent} pane=${pane} PID=$!" >&2
    ) 9>"$lockfile"
}

# baton_watchdog は agent 単位ではない単一インスタンスの大域 watcher
# （cmd_171/T3）。全体整合性（バトン喪失）の判定を9本の inbox_watcher に
# 分散させると同一結論に9重で達し通知が9重に飛ぶため、専用プロセス1本に
# 起動を限定する。pgrep 判定は start_watcher_if_missing の重複起動防止と
# 同格の仕組みで既に足りる（1プロセスのみ許す）。
start_baton_watchdog_if_missing() {
    local log_file="$1"
    local lockfile="/tmp/shogun_watcher_start_baton_watchdog.lock"

    (
        flock -n 9 || return 0
        if pgrep -f "scripts/baton_watchdog.sh" >/dev/null 2>&1; then
            return 0
        fi

        nohup bash scripts/baton_watchdog.sh >> "$log_file" 2>&1 &
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [START] baton_watchdog started PID=$!" >&2
    ) 9>"$lockfile"
}

watcher_specs() {
    local pane_base
    local agent
    pane_base=$(get_multiagent_pane_base)

    while IFS= read -r agent; do
        [ -z "$agent" ] && continue
        local pane
        if ! pane=$(agent_registry_pane_for_agent "$agent" "$pane_base"); then
            continue
        fi
        printf '%s\t%s\tlogs/inbox_watcher_%s.log\n' "$agent" "$pane" "$agent"
    done < <(agent_registry_agents)

    # エージェント名ではない単一の大域 watcher。pane は存在しない（"-"）。
    printf 'baton_watchdog\t-\tlogs/baton_watchdog.log\n'
}

start_all_watchers() {
    local agent pane log_file
    while IFS=$'\t' read -r agent pane log_file; do
        if [ "$agent" = "baton_watchdog" ]; then
            start_baton_watchdog_if_missing "$log_file"
        else
            start_watcher_if_missing "$agent" "$pane" "$log_file"
        fi
    done < <(watcher_specs)
}

if [ "${1:-}" = "--print-watchers" ]; then
    watcher_specs
    exit 0
fi

while true; do
    start_all_watchers
    sleep 5
done
