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

# cmd_186/issue#27: 常駐daemonのログには自前のローテーションが一切無く、
# pane不一致WARN連発バグ（cmd_176是正前）で watcher_supervisor.log が
# 実測28MB・14.9万行まで無制限に膨張した実例がある。バグ自体は是正済みだが、
# 同種の再発（WARN/ERRを吐き続ける別バグ）に備え、サイズ上限を機械的に
# 掛ける。in-place truncate（`: > file`）を用いるのは、これらのログが
# 起動時に `>> file` (O_APPEND) でリダイレクトされたまま常駐daemonに
# 掴まれ続けているため——rename/mv方式だと旧inodeを書き続ける古いfdと
# 新ファイルが乖離し、以後の追記がどこにも見えなくなる（copytruncateが
# 必要な所以と同じ理由）。truncateはO_APPEND fdのオフセットを内部的に
# 巻き戻さないが、次回writeはカーネルがEOFへ再シークするため安全に追記が
# 続く。
rotate_log_if_large() {
    local log_file="$1"
    local max_bytes="${WATCHER_LOG_ROTATE_MAX_BYTES:-10485760}"
    local keep_lines="${WATCHER_LOG_ROTATE_KEEP_LINES:-5000}"
    local size

    [ -f "$log_file" ] || return 0
    size=$(stat -c%s "$log_file" 2>/dev/null || echo 0)
    [ "$size" -gt "$max_bytes" ] || return 0

    local tail_content
    tail_content=$(tail -n "$keep_lines" "$log_file")
    : > "$log_file"
    {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [watcher_supervisor/log_rotate] rotated ${log_file} in place: previous size ${size} bytes exceeded ${max_bytes} bytes cap; kept last ${keep_lines} lines"
        printf '%s\n' "$tail_content"
    } >> "$log_file"
}

rotate_all_managed_logs() {
    rotate_log_if_large "logs/watcher_supervisor.log"

    local agent pane log_file
    while IFS=$'\t' read -r agent pane log_file; do
        rotate_log_if_large "$log_file"
    done < <(watcher_specs)
}

start_watcher_if_missing() {
    local agent="$1"
    local pane="$2"
    local log_file="$3"
    local cli
    local lockfile="/tmp/shogun_watcher_start_${agent}.lock"
    local notified_flag="/tmp/shogun_watcher_obs22_notified_${agent}"

    ensure_inbox_file "$agent"
    if ! pane_exists "$pane"; then
        return 0
    fi

    (
        flock -n 9 || return 0
        if pgrep -f "scripts/inbox_watcher.sh ${agent} ${pane}( |$)" >/dev/null 2>&1; then
            # pane不一致が解消された（正しいpaneで稼働中）。次回また
            # 不一致が起きた際に再通知できるよう、重複防止フラグを消す。
            rm -f "$notified_flag"
            return 0
        fi

        if pgrep -f "scripts/inbox_watcher.sh ${agent} " >/dev/null 2>&1; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] stale watcher detected for ${agent} (pane mismatch with expected ${pane}); not starting a new one to avoid duplicates. Resolve pane mismatch manually." >&2
            if [ ! -f "$notified_flag" ]; then
                local actual_pane
                actual_pane=$(pgrep -af "scripts/inbox_watcher.sh ${agent} " 2>/dev/null | head -n1 | awk '{print $5}') || true
                if bash scripts/inbox_write.sh shogun "pane不一致検知: agent=${agent} expected_pane=${pane} actual_pane=${actual_pane:-不明}。inbox_watcherが期待と異なるpaneで稼働中の可能性。要確認。" watcher_alert watcher_supervisor; then
                    touch "$notified_flag"
                else
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] failed to notify shogun of pane mismatch for ${agent}" >&2
                fi
            fi
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
    rotate_all_managed_logs
    sleep 5
done
