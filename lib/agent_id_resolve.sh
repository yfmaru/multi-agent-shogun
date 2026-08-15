#!/usr/bin/env bash
# lib/agent_id_resolve.sh — AGENT_ID_RESOLVE_LADDER (cmd_217 design_1)
#
# Resolves the caller's own agent_id without depending solely on
# TMUX_PANE, which was observed to go missing for the UserPromptSubmit
# hook event specifically on some sessions (cause unresolved — see
# queue/reports/gunshi_report.yaml N-1/N-2). Sourced by
# scripts/user_prompt_submit_hook.sh; kept in a library (rather than
# inlined) so each rung can be unit-tested in isolation without tripping
# the hook script's unconditional `exit 0` at end-of-file.
#
# Usage:
#   source lib/agent_id_resolve.sh
#   resolve_agent_id_ladder "$HOOK_SESSION_ID"   # HOOK_SESSION_ID may be ""
#   # on success (rc=0): $RESOLVED_AGENT_ID is set, $RESOLVED_VIA is
#   #   "l1"/"l2"/"l3"
#   # on failure (rc=1): both are left empty
#
# 不変の契約: このライブラリ自身は決して exit しない（呼び出し元の
# hookが exit 0 契約を守れるようにするため）。

RESOLVED_AGENT_ID=""
RESOLVED_VIA=""

# L1: TMUX_PANE → tmux display-message（現行・最も安い・最初に試す）
resolve_agent_id_l1() {
    [ -n "${TMUX_PANE:-}" ] || return 1
    local id
    id=$(tmux display-message -t "$TMUX_PANE" -p '#{@agent_id}' 2>/dev/null || true)
    [ -n "$id" ] || return 1
    printf '%s' "$id"
}

# L2: プロセス系譜 → 各tmux paneのpane_pidと照合。TMUX_PANE不要。
# AC-I3: /proc/<pid>/stat の第4フィールドを awk で取ってはならぬ
# （comm欄が空白・括弧を含み得てフィールド番号がずれる——軍師が設計
# レビュー中に実際に踏んだ罠）。正しくは /proc/<pid>/status の PPid。
resolve_agent_id_l2() {
    local panes
    panes=$(timeout 2 tmux list-panes -a -F '#{pane_pid} #{@agent_id}' 2>/dev/null) || return 1
    [ -n "$panes" ] || return 1

    local pid="${AGENT_ID_RESOLVE_L2_START_PID:-$$}"
    local hop=0
    local -A seen=()
    while [ "$hop" -lt 10 ]; do
        hop=$((hop + 1))
        [ -n "$pid" ] && [ "$pid" != "1" ] || break
        # ループ防止: 同一pid再訪は打ち切り
        [ -z "${seen[$pid]:-}" ] || break
        seen[$pid]=1

        local match_id
        match_id=$(printf '%s\n' "$panes" | awk -v p="$pid" '$1 == p && $2 != "" {print $2; exit}')
        if [ -n "$match_id" ]; then
            printf '%s' "$match_id"
            return 0
        fi

        local ppid
        ppid=$(awk '/^PPid:/{print $2}' "/proc/${pid}/status" 2>/dev/null)
        [ -n "$ppid" ] || break
        pid="$ppid"
    done
    return 1
}

# L3: session_id → session_start_hook.sh が書いた対応表
resolve_agent_id_l3() {
    local session_id="${1:-}"
    [ -n "$session_id" ] || return 1
    local map_file="${IDLE_FLAG_DIR:-/tmp}/shogun_session_${session_id}"
    [ -f "$map_file" ] || return 1
    local id
    id=$(cat "$map_file" 2>/dev/null || true)
    [ -n "$id" ] || return 1
    printf '%s' "$id"
}

# 三段の梯子を順に試す。$1 = session_id（L3用、空でよい）。
# 成功時: RESOLVED_AGENT_ID / RESOLVED_VIA をセットし rc=0。
# 全段失敗時: 両方とも空のまま rc=1。
resolve_agent_id_ladder() {
    local session_id="${1:-}"
    RESOLVED_AGENT_ID=""
    RESOLVED_VIA=""

    local id
    id=$(resolve_agent_id_l1 2>/dev/null || true)
    if [ -n "$id" ]; then
        RESOLVED_AGENT_ID="$id"
        RESOLVED_VIA="l1"
        return 0
    fi

    id=$(resolve_agent_id_l2 2>/dev/null || true)
    if [ -n "$id" ]; then
        RESOLVED_AGENT_ID="$id"
        RESOLVED_VIA="l2"
        return 0
    fi

    id=$(resolve_agent_id_l3 "$session_id" 2>/dev/null || true)
    if [ -n "$id" ]; then
        RESOLVED_AGENT_ID="$id"
        RESOLVED_VIA="l3"
        return 0
    fi

    return 1
}
