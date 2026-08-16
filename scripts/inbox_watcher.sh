#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# inbox_watcher.sh — メールボックス監視＆起動シグナル配信
# Usage: bash scripts/inbox_watcher.sh <agent_id> <pane_target> [cli_type]
# Example: bash scripts/inbox_watcher.sh karo multiagent:0.0 claude
#
# 設計思想:
#   メッセージ本体はファイル（inbox YAML）に書く = 確実
#   起動シグナルは tmux send-keys（テキストとEnterを分離送信）
#   エージェントが自分でinboxをReadして処理する
#   冪等: 2回届いてもunreadがなければ何もしない
#
# inotifywait でファイル変更を検知（イベント駆動、ポーリングではない）
# Fallback 1: 30秒タイムアウト（WSL2 inotify不発時の安全網）
# Fallback 2: rc=1処理（Claude Code atomic write = tmp+rename でinode変更時）
#
# エスカレーション（未読メッセージが放置されている場合）:
#   0〜2分: 通常nudge（send-keys）。ただしWorking中はスキップ
#   2〜4分: Copilot/Kimi は Escape×2 + Ctrl-C + nudge。
#            Claude/Codex/OpenCode は通常nudgeへフォールバック
#   4分〜 : /clear送信（5分に1回まで。強制リセット+YAML再読）
#
# 停止検知（cmd_171。上記エスカレーションとは別系統。未読の有無を問わず、
# pane が静止したまま busy に見える状態を対象とする。stall_policy.enabled
# が true のときのみ動く opt-in 機構）:
#   判定順序は必ず以下を守る（順序を誤ると使用量制限中のエージェントへ
#   Escape/nudge/clearを送ってしまう）:
#     Gate 0: pane_is_active（人間操作中は何もしない）
#     Gate 1: 類型C（使用量制限）を最優先で排除 — limitedなら何もしない
#     Gate 2: 類型Aの検知（is_stalled_pane） — unknownならEscapeのみ、okなら全段
# ═══════════════════════════════════════════════════════════════

# ─── Testing guard ───
# When __INBOX_WATCHER_TESTING__=1, only function definitions are loaded.
# Argument parsing, inotifywait check, and main loop are skipped.
# Test code sets variables (AGENT_ID, PANE_TARGET, CLI_TYPE, INBOX) externally.
if [ "${__INBOX_WATCHER_TESTING__:-}" != "1" ]; then
    set -euo pipefail

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    AGENT_ID="$1"
    PANE_TARGET="$2"
    CLI_TYPE="${3:-claude}"  # CLI種別（claude/codex/copilot/kimi/opencode/antigravity）。未指定→claude（後方互換）
    case "$CLI_TYPE" in
        gemini|agy) CLI_TYPE="antigravity" ;;
    esac

    INBOX="$SCRIPT_DIR/queue/inbox/${AGENT_ID}.yaml"
    LOCKFILE="${INBOX}.lock"

    if [ -z "$AGENT_ID" ] || [ -z "$PANE_TARGET" ]; then
        echo "Usage: inbox_watcher.sh <agent_id> <pane_target> [cli_type]" >&2
        exit 1
    fi

    # Initialize inbox if not exists
    if [ ! -f "$INBOX" ]; then
        mkdir -p "$(dirname "$INBOX")"
        echo "messages: []" > "$INBOX"
    fi

    echo "[$(date)] inbox_watcher started — agent: $AGENT_ID, pane: $PANE_TARGET, cli: $CLI_TYPE" >&2

    # cmd_229 AC-7/S-3 (defect2_design PRESERVE_TURN_STATE_ACROSS_WATCHER_RESTART):
    # this used to be an unconditional `touch idle印` — correct the first time
    # this script ever starts for a pane (CLI starts at welcome screen = idle),
    # but wrong every time the watcher itself is merely restarted (e.g. the
    # Lord replacing it per CLAUDE.md's daemon-swap procedure) while the CLI
    # underneath keeps running mid-turn: the fresh watcher process would blow
    # away a live busy印 and go permanently blind to that turn (2026-08-16
    # RCA: exactly this, for 48 minutes). init_turn_state_marks() (defined
    # below, outside this testing guard, so bats can call it directly)
    # distinguishes the two cases by comparing the CLI process's own start
    # time against the marks already on disk.
    if [[ "$CLI_TYPE" == "claude" ]]; then
        init_turn_state_marks
    fi

    # Source cli_adapter for get_startup_prompt() (Codex needs startup prompt after /new)
    _cli_adapter="${SCRIPT_DIR}/lib/cli_adapter.sh"
    if [ -f "$_cli_adapter" ]; then
        source "$_cli_adapter"
        echo "[$(date)] cli_adapter.sh loaded (get_startup_prompt available)" >&2
    fi

    # Source shared agent status library (busy/idle detection)
    _agent_status_lib="${SCRIPT_DIR}/lib/agent_status.sh"
    if [ -f "$_agent_status_lib" ]; then
        source "$_agent_status_lib"
    fi

    # Source stall_policy query lib (cmd_171). Provides stall_policy_query /
    # baton_watchdog_query / shogun_input_guard_query with safe defaults
    # even when the config section (or config/settings.yaml itself) is absent.
    _stall_policy_lib="${SCRIPT_DIR}/lib/stall_policy.sh"
    if [ -f "$_stall_policy_lib" ]; then
        source "$_stall_policy_lib"
    fi

    # Source branch_policy lib (cmd_182). Provides branch_policy_notify(),
    # used as a failure-tolerant insurance ntfy when a shogun nudge stays
    # deferred (human_typing_recently) past shogun_defer_ntfy_after_sec.
    _branch_policy_lib="${SCRIPT_DIR}/lib/branch_policy.sh"
    if [ -f "$_branch_policy_lib" ]; then
        source "$_branch_policy_lib"
    fi

    # Source usage_limit lib (cmd_171 P-1). Provides usage_limit_state(),
    # used by Gate 1 (type-C exclusion) to avoid firing Escape at agents
    # that are merely rate-limited rather than stuck on a modal.
    _usage_limit_lib="${SCRIPT_DIR}/lib/usage_limit.sh"
    if [ -f "$_usage_limit_lib" ]; then
        source "$_usage_limit_lib"
    fi

    # Detect OS and select file-watching backend
    INBOX_WATCHER_OS="$(uname -s)"
    if [ "$INBOX_WATCHER_OS" = "Darwin" ]; then
        # macOS: use fswatch instead of inotifywait
        if ! command -v fswatch &>/dev/null; then
            echo "[inbox_watcher] ERROR: fswatch not found. Install: brew install fswatch" >&2
            exit 1
        fi
        WATCH_BACKEND="fswatch"
        if ! command -v gtimeout &>/dev/null; then
            echo "[inbox_watcher] WARN: gtimeout not found. Using sleep-based fallback (higher CPU). Recommended: brew install coreutils" >&2
        fi
    else
        # Linux: use inotifywait
        if ! command -v inotifywait &>/dev/null; then
            echo "[inbox_watcher] ERROR: inotifywait not found. Install: sudo apt install inotify-tools" >&2
            exit 1
        fi
        WATCH_BACKEND="inotifywait"
    fi
    echo "[$(date)] File watch backend: $WATCH_BACKEND" >&2
fi

# ─── timeout command compatibility wrapper (macOS support) ───
if ! command -v timeout &>/dev/null; then
  if command -v gtimeout &>/dev/null; then
    timeout() { gtimeout "$@"; }
  else
    # Pure bash fallback: timeout DURATION COMMAND [ARGS...]
    timeout() {
      local duration="$1"; shift
      "$@" &
      local pid=$!
      ( sleep "$duration" && kill "$pid" 2>/dev/null ) &
      local watcher=$!
      wait "$pid" 2>/dev/null
      local rc=$?
      kill "$watcher" 2>/dev/null
      wait "$watcher" 2>/dev/null
      return $rc
    }
  fi
fi

# ─── init_turn_state_marks (cmd_229 AC-7/S-3) ───
# Defined outside the testing guard above (unlike the old inline touch it
# replaces) so bats can call it directly with mocked tmux/ps/stat — see
# defect2_design.reference_implementation in queue/reports/gunshi_report.yaml
# for the design this implements almost verbatim.
#
# final_rule:
#   cli_start   := now - etimes(CLIプロセス)
#   newest_mark := max(mtime(busy印), mtime(idle印))   （どちらも無ければ -∞）
#   if 印が1つも無い OR cli_start > newest_mark:
#       touch idle印        # 真に新しいCLI。welcome画面＝idleで正しい
#   else:
#       何もせぬ（ログのみ）  # 印は走っているCLIのものである。触るな
#
# なぜこれで十分か（AC3 非可逆性との整合）: この規則は状態を保存する
# だけで生成せぬ。busyを作りもせず、idleを作りもせず、既にある真実を
# そのまま残す。既に反転してしまった印（idle印>busy印）は直しはせぬ
# ——欠陥1の是正（stall_busy()のOR右項、画面側）が回復経路になる。
init_turn_state_marks() {
    local flag_dir="${IDLE_FLAG_DIR:-/tmp}"
    local busy_flag="${flag_dir}/shogun_busy_${AGENT_ID}"
    local idle_flag="${flag_dir}/shogun_idle_${AGENT_ID}"

    local newest=-1 m t
    for m in "$busy_flag" "$idle_flag"; do
        [ -f "$m" ] || continue
        t=$(stat -c %Y "$m" 2>/dev/null || echo -1)
        if [ "$t" -gt "$newest" ] 2>/dev/null; then
            newest="$t"
        fi
    done

    if [ "$newest" -lt 0 ]; then
        touch "$idle_flag"
        echo "[$(date)] Created initial idle flag for $AGENT_ID (no prior marks)" >&2
        return 0
    fi

    # CLI本体の起動時刻を求める。pane_pid は pane のシェルであり CLI ではない
    # （実測: cmd_229 §5, gunshi_report.yaml correction_to_rca_draft ——
    # RCA試作案の pane_pid=etimes 直用は switch_cli.sh によるCLI入替を
    # 検知できず誤り）。ps --ppid でその子から CLI を探す。pgrep は使わぬ
    # （CLAUDE.md「pgrep Self-Match Pitfall」— ラッパのcmdlineに自己マッチ）。
    local pane_pid cli_etimes cli_start=-1
    pane_pid=$(timeout 2 tmux display-message -t "$PANE_TARGET" -p '#{pane_pid}' 2>/dev/null || true)
    if [ -n "$pane_pid" ]; then
        cli_etimes=$(ps --ppid "$pane_pid" -o etimes=,comm= 2>/dev/null \
            | awk -v c="$CLI_TYPE" '$2==c {print $1; exit}')
        if [ -n "$cli_etimes" ]; then
            cli_start=$(( $(date +%s) - cli_etimes ))
        fi
    fi

    # degradation_direction (gunshi_report.yaml): CLIプロセスを特定できぬ
    # 場合（ps失敗・CLIが直接の子でない・comm名が違う）はcli_start=-1の
    # ままとなり、保存側へ倒れる。理由は両側の失敗の有界性が非対称だから
    # ——保存側の誤り(真に新しいCLIが古いbusy印を引き継ぐ)は300秒
    # stale-busy網が解く(有界)。touch側の誤り(欠陥2の再演)は解く者が
    # 居らぬ(無界)。cli_start=-1のとき `$cli_start -gt $newest` は常に
    # 偽ゆえ、下のif文はこの縮退方向を自然に満たす（追加分岐は不要）。
    if [ "$cli_start" -ge 0 ] && [ "$cli_start" -gt "$newest" ]; then
        touch "$idle_flag"
        echo "[$(date)] Created initial idle flag for $AGENT_ID (CLI newer than marks — fresh CLI)" >&2
    else
        echo "[$(date)] Preserving turn-state marks for $AGENT_ID (marks belong to the running CLI; cli_start=$cli_start newest_mark=$newest)" >&2
    fi
    return 0
}

# ─── Escalation state ───
# Time-based escalation: track how long unread messages have been waiting
FIRST_UNREAD_SEEN=${FIRST_UNREAD_SEEN:-0}
LAST_CLEAR_TS=${LAST_CLEAR_TS:-0}
ESCALATE_PHASE1=${ESCALATE_PHASE1:-120}
ESCALATE_PHASE2=${ESCALATE_PHASE2:-240}
ESCALATE_COOLDOWN=${ESCALATE_COOLDOWN:-300}

# ─── Shogun defer state (cmd_182 QC40-F1/F2) ───
# shogun's watcher runs with ASW_PROCESS_TIMEOUT=0 (event-driven only, see
# shutsujin_departure.sh:910-912). When human_typing_recently() defers a
# send-keys nudge, there is no "next cycle" to re-evaluate unless the main
# loop's timeout branch is explicitly reopened while a defer is pending.
SHOGUN_DEFER_PENDING=${SHOGUN_DEFER_PENDING:-0}
# One-shot guard so the deferred-notify ntfy fires once per defer episode,
# not every 30s once QC40-F1 reopens the timeout branch.
SHOGUN_DEFER_NTFY_SENT=${SHOGUN_DEFER_NTFY_SENT:-0}

# cmd_217: one-shot guard for the 300s stale-busy safety net's ntfy
# (§3/AC3'). Reset alongside the other unread-episode one-shots so the
# next stale-busy episode can notify again.
STALE_BUSY_NTFY_SENT=${STALE_BUSY_NTFY_SENT:-0}

# Clears shogun-defer state. Call when a nudge actually reaches the pane
# (send-keys success) or when the inbox goes back to zero unread.
reset_shogun_defer_state() {
    SHOGUN_DEFER_PENDING=0
    SHOGUN_DEFER_NTFY_SENT=0
    STALE_BUSY_NTFY_SENT=0
}

# QC40-F1: whether the main loop's 30s timeout tick should call
# process_unread. Normally gated by ASW_PROCESS_TIMEOUT (0 for shogun,
# event-driven only). While a shogun defer is pending, force it open so
# the deferred nudge gets re-evaluated instead of waiting forever for the
# next inbox write event.
should_process_timeout_tick() {
    [ "${ASW_PROCESS_TIMEOUT:-1}" = "1" ] || [ "${SHOGUN_DEFER_PENDING:-0}" = "1" ]
}

# ─── Nudge throttle ───
# Avoid spamming the same "inboxN" into the pane every timeout tick.
LAST_NUDGE_TS=${LAST_NUDGE_TS:-0}
LAST_NUDGE_COUNT=${LAST_NUDGE_COUNT:-""}
NUDGE_COOLDOWN_SEC=${NUDGE_COOLDOWN_SEC:-60}
# Codex は「思考中に入力が入ると即拾う」挙動があり、思考がループすることがあるため長めにする。
NUDGE_COOLDOWN_SEC_CODEX=${NUDGE_COOLDOWN_SEC_CODEX:-300}

reset_nudge_throttle() {
    LAST_NUDGE_TS=0
    LAST_NUDGE_COUNT=""
}

acquire_inbox_lock() {
    local lock_dir="${LOCKFILE}.d"
    local i=0

    while ! mkdir "$lock_dir" 2>/dev/null; do
        sleep 0.1
        i=$((i + 1))
        [ "$i" -ge 300 ] && return 1
    done

    if command -v flock &>/dev/null; then
        flock -x 200 || {
            rmdir "$lock_dir" 2>/dev/null
            return 1
        }
    fi
}

release_inbox_lock() {
    rmdir "${LOCKFILE}.d" 2>/dev/null || true
}

# ─── Context reset tracking ───
# Tracks whether we've sent /new or /clear for the current task_assigned batch.
# Resets to 0 when all messages are read (FIRST_UNREAD_SEEN → 0).
NEW_CONTEXT_SENT=${NEW_CONTEXT_SENT:-0}
# Tracks whether we sent a startup prompt (Codex) that includes full recovery.
# When set, skip follow-up nudge for this cycle (agent already knows what to do).
STARTUP_PROMPT_SENT=${STARTUP_PROMPT_SENT:-0}

# ─── Phase feature flags (cmd_107 Phase 1/2/3) ───
# ASW_PHASE:
#   1 = self-watch base (compatible)
#   2 = disable normal nudge by default
#   3 = FINAL_ESCALATION_ONLY (send-keys is fallback only)
ASW_PHASE=${ASW_PHASE:-2}
ASW_DISABLE_NORMAL_NUDGE=${ASW_DISABLE_NORMAL_NUDGE:-$([ "${ASW_PHASE}" -ge 2 ] && echo 1 || echo 0)}
ASW_FINAL_ESCALATION_ONLY=${ASW_FINAL_ESCALATION_ONLY:-$([ "${ASW_PHASE}" -ge 3 ] && echo 1 || echo 0)}
FINAL_ESCALATION_ONLY=${FINAL_ESCALATION_ONLY:-$ASW_FINAL_ESCALATION_ONLY}
ASW_NO_IDLE_FULL_READ=${ASW_NO_IDLE_FULL_READ:-1}
# Optional safety toggles:
# - ASW_DISABLE_ESCALATION=1: disable phase2/phase3 escalation actions
# - ASW_PROCESS_TIMEOUT=0: do not process unread on timeout ticks (event-only)
ASW_DISABLE_ESCALATION=${ASW_DISABLE_ESCALATION:-0}
ASW_PROCESS_TIMEOUT=${ASW_PROCESS_TIMEOUT:-1}

# ─── Stall detection state (cmd_171 / T1) ───
# Process-local; tracks the last observed pane hash for is_stalled_pane().
STALL_HASH=${STALL_HASH:-}
STALL_HASH_SINCE=${STALL_HASH_SINCE:-0}
STALL_ACTED_AT=${STALL_ACTED_AT:-0}

# ─── Stale-busy pane-hash state (cmd_217 D-1) ───
# Separate state from STALL_HASH/STALL_HASH_SINCE above — the stale-busy
# safety net (§ force-idle sites below) and is_stalled_pane() share only
# the pane_hash_frozen_sec() mechanism, never the state itself, so their
# thresholds (stale_busy_limit=300s vs stall_after_sec=480s default) never
# mix (gunshi_report.yaml design_4: "閾値は混ぜるな").
STALE_BUSY_HASH=${STALE_BUSY_HASH:-}
STALE_BUSY_HASH_SINCE=${STALE_BUSY_HASH_SINCE:-0}

# ─── Liveness/notify state (cmd_218) ───
# STALL_ACTION_TAKEN: set by attempt_stall_recovery() the instant it actually
# sends keys; consumed by the main loop to defer delivery one tick (SE-2).
# STALL_UNRESPONSIVE_ATTEMPTS / STALL_USAGE_LIMITED_STREAK: per-episode
# counters feeding stall_maybe_notify()'s stall_notify_after_attempts gate.
# STALL_USAGE_LIMITED_LAST: cooldown timestamp so the usage_limited streak
# advances at the same ~stall_retry_cooldown_sec cadence as the ladder path,
# not once per liveness_tick. All reset to 0 the instant is_stalled_pane()
# reports the pane moved (one episode = one continuous stall).
STALL_ACTION_TAKEN=${STALL_ACTION_TAKEN:-0}
STALL_UNRESPONSIVE_ATTEMPTS=${STALL_UNRESPONSIVE_ATTEMPTS:-0}
STALL_USAGE_LIMITED_STREAK=${STALL_USAGE_LIMITED_STREAK:-0}
STALL_USAGE_LIMITED_LAST=${STALL_USAGE_LIMITED_LAST:-0}
STALL_NTFY_SENT=${STALL_NTFY_SENT:-0}

# ─── Metrics hooks (FR-006 / NFR-003) ───
# unread_latency_sec / read_count / estimated_tokens are intentionally explicit
READ_COUNT=${READ_COUNT:-0}
READ_BYTES_TOTAL=${READ_BYTES_TOTAL:-0}
ESTIMATED_TOKENS_TOTAL=${ESTIMATED_TOKENS_TOTAL:-0}
METRICS_FILE=${METRICS_FILE:-${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/queue/metrics/${AGENT_ID:-unknown}_selfwatch.yaml}

update_metrics() {
    local bytes_read="${1:-0}"
    local now
    now=$(date +%s)

    READ_COUNT=$((READ_COUNT + 1))
    READ_BYTES_TOTAL=$((READ_BYTES_TOTAL + bytes_read))
    ESTIMATED_TOKENS_TOTAL=$((ESTIMATED_TOKENS_TOTAL + ((bytes_read + 3) / 4)))

    local unread_latency_sec=0
    if [ "$FIRST_UNREAD_SEEN" -gt 0 ] 2>/dev/null; then
        unread_latency_sec=$((now - FIRST_UNREAD_SEEN))
    fi

    mkdir -p "$(dirname "$METRICS_FILE")" 2>/dev/null || true
    cat > "$METRICS_FILE" <<EOF
agent_id: "${AGENT_ID:-unknown}"
timestamp: "$(date '+%Y-%m-%dT%H:%M:%S%z')"
unread_latency_sec: $unread_latency_sec
read_count: $READ_COUNT
bytes_read: $READ_BYTES_TOTAL
estimated_tokens: $ESTIMATED_TOKENS_TOTAL
EOF
}

# cmd_217 §2-3 + design_2是正: 装填検査（自己申告する機構）。
# UPS_MARK_PROVENANCE: check_hook_armed() は ups印
# (/tmp/shogun_ups_<agent>, user_prompt_submit_hook.sh だけが touch する
# 専用の証跡) のみを見る。busy印は3者共有の集約物であり、mtimeがどれだけ
# 進んでも「何が動かしたか」を復元できない（session_start_hookが/clear
# のたびに同じ印を touch するため）。ups印なら出所は一つしかなく、
# 「mtime前進 = UserPromptSubmit hookが発火した」を意味論そのものに
# できる。
#
# HOOK_ARMED_DEFERRED_EVAL: 判定は遅延評価でなければならぬ。hookが
# 発火するのは send-keys のおよそ1秒後であり、check_hook_armed() は
# 送出成功の直後に同期で呼ばれる——その場でups印のmtimeを見ても
# 間に合わない。ゆえに「今回のnudge」の判定は「次回のcheck_hook_armed()
# 呼び出し」まで遅延させる（HOOK_CHECK_PENDING）。判定は1回分の
# nudgeだけ遅れるが、UNARMEDは元よりN回後の判定ゆえ実害無し。
HOOK_ARMED_CHECK_N=${HOOK_ARMED_CHECK_N:-3}
NUDGE_SEND_COUNT=${NUDGE_SEND_COUNT:-0}
HOOK_ARMED_LOGGED=${HOOK_ARMED_LOGGED:-0}
HOOK_UNARMED_LOGGED=${HOOK_UNARMED_LOGGED:-0}
HOOK_CHECK_PENDING=${HOOK_CHECK_PENDING:-0}
UPS_MTIME_PRE=${UPS_MTIME_PRE:-0}
MISS_COUNT=${MISS_COUNT:-0}

check_hook_armed() {
    local cli
    cli=$(get_effective_cli_type)
    [[ "$cli" == "claude" ]] || return 0

    local ups_file="${IDLE_FLAG_DIR:-/tmp}/shogun_ups_${AGENT_ID}"
    local now_mtime
    now_mtime=$(stat -c %Y "$ups_file" 2>/dev/null || echo 0)

    # 前回のnudgeに対する保留中の判定を、まず先に片付ける。
    if [ "$HOOK_CHECK_PENDING" -eq 1 ]; then
        if [ "$now_mtime" -gt "$UPS_MTIME_PRE" ] 2>/dev/null; then
            if [ "$HOOK_ARMED_LOGGED" -eq 0 ]; then
                echo "[$(date)] [HOOK-ARMED] $AGENT_ID: UserPromptSubmit hook ups印を確認 (nudge x${NUDGE_SEND_COUNT})" >&2
                HOOK_ARMED_LOGGED=1
            fi
            HOOK_CHECK_PENDING=0
        else
            MISS_COUNT=$((MISS_COUNT + 1))
        fi
    fi

    NUDGE_SEND_COUNT=$((NUDGE_SEND_COUNT + 1))

    # ARMED確定後は新たな保留を立てない（以後の呼び出しは完全に無害化）。
    if [ "$HOOK_ARMED_LOGGED" -eq 0 ]; then
        UPS_MTIME_PRE="$now_mtime"
        HOOK_CHECK_PENDING=1
    fi

    if [ "$MISS_COUNT" -ge "$HOOK_ARMED_CHECK_N" ] && [ "$HOOK_UNARMED_LOGGED" -eq 0 ] && [ "$HOOK_ARMED_LOGGED" -eq 0 ]; then
        echo "[$(date)] [HOOK-UNARMED] $AGENT_ID: UserPromptSubmit hook が未装填の可能性 (nudge x${NUDGE_SEND_COUNT}, ups印一度もmtime前進せず)" >&2
        type branch_policy_notify &>/dev/null && branch_policy_notify "[HOOK-UNARMED] ${AGENT_ID}: UserPromptSubmit hook 未装填の疑い(nudge x${NUDGE_SEND_COUNT})" 2>/dev/null || true
        HOOK_UNARMED_LOGGED=1
    fi
}

disable_normal_nudge() {
    # Phase 2+: suppress nudge ONLY when agent is busy.
    # If agent is idle, nudge is needed (stop hook won't fire for idle agents).
    if [ "${ASW_DISABLE_NORMAL_NUDGE:-0}" != "1" ]; then
        return 1  # Phase 1: never suppress
    fi
    # Phase 2+: check if agent is idle.
    # cmd_217: route claude through the shared two-marker judgment
    # (agent_turn_state) instead of re-deriving "idle" from flag presence
    # here — a second presence-only definition would silently reproduce
    # the same lie agent_is_busy() used to tell if this path is ever
    # switched on (currently dead: ASW_DISABLE_NORMAL_NUDGE=0).
    local cli
    cli=$(get_effective_cli_type)
    if [[ "$cli" == "claude" ]]; then
        if [[ "$(agent_turn_state "$AGENT_ID")" == "idle" ]]; then
            return 1  # Agent is IDLE → don't suppress, send nudge
        fi
        return 0  # Agent is BUSY → suppress, stop hook will deliver
    fi
    if [ -f "${IDLE_FLAG_DIR:-/tmp}/shogun_idle_${AGENT_ID}" ]; then
        return 1  # Agent is IDLE → don't suppress, send nudge
    fi
    return 0  # Agent is BUSY → suppress, stop hook will deliver
}

should_throttle_nudge() {
    local unread_count="${1:-0}"
    local now
    now=$(date +%s)

    local effective_cli
    effective_cli=$(get_effective_cli_type)

    local cooldown_sec="${NUDGE_COOLDOWN_SEC:-60}"
    if [[ "$effective_cli" == "codex" ]]; then
        cooldown_sec="${NUDGE_COOLDOWN_SEC_CODEX:-300}"
    elif [[ "$effective_cli" == "claude" ]]; then
        # Claude Code: same cooldown as default (60s).
        # Stop hook is supplementary, not primary — nudge immediately.
        cooldown_sec="${NUDGE_COOLDOWN_SEC_CLAUDE:-60}"
    fi

    # Standard throttle: skip if same count within cooldown window.
    if [ "${LAST_NUDGE_COUNT:-}" = "$unread_count" ] && [ "${LAST_NUDGE_TS:-0}" -gt 0 ]; then
        local age=$((now - LAST_NUDGE_TS))
        if [ "$age" -lt "${cooldown_sec}" ]; then
            echo "[$(date)] [SKIP] Throttling nudge for $AGENT_ID: inbox${unread_count} (${age}s < ${cooldown_sec}s, cli=$effective_cli)" >&2
            return 0
        fi
    fi

    LAST_NUDGE_COUNT="$unread_count"
    LAST_NUDGE_TS="$now"
    return 1
}

is_valid_cli_type() {
    case "${1:-}" in
        claude|codex|copilot|kimi|opencode|antigravity|gemini|agy) return 0 ;;
        *) return 1 ;;
    esac
}

normalize_watcher_cli_type() {
    case "${1:-}" in
        gemini|agy) echo "antigravity" ;;
        *) echo "${1:-}" ;;
    esac
}

get_effective_cli_type() {
    local pane_cli_raw=""
    local pane_cli=""

    pane_cli_raw=$(timeout 2 tmux show-options -p -t "$PANE_TARGET" -v @agent_cli 2>/dev/null || true)
    pane_cli=$(echo "$pane_cli_raw" | tr -d '\r' | head -n1 | tr -d '[:space:]')

    if is_valid_cli_type "$pane_cli"; then
        pane_cli=$(normalize_watcher_cli_type "$pane_cli")
        local arg_cli
        arg_cli=$(normalize_watcher_cli_type "${CLI_TYPE:-}")
        if is_valid_cli_type "${CLI_TYPE:-}" && [ "$pane_cli" != "$arg_cli" ]; then
            echo "[$(date)] [WARN] CLI drift detected for $AGENT_ID: arg=${CLI_TYPE}, pane=${pane_cli}. Using pane value." >&2
        fi
        echo "$pane_cli"
        return 0
    fi

    if is_valid_cli_type "${CLI_TYPE:-}"; then
        if [ -n "$pane_cli" ]; then
            echo "[$(date)] [WARN] Invalid pane @agent_cli for $AGENT_ID: '${pane_cli}'. Falling back to arg=${CLI_TYPE}." >&2
        fi
        normalize_watcher_cli_type "${CLI_TYPE}"
        return 0
    fi

    # Fail-closed: when CLI is unknown, take codex-safe path (no C-c, /clear->/new)
    echo "[$(date)] [WARN] CLI unresolved for $AGENT_ID (pane='${pane_cli:-<empty>}', arg='${CLI_TYPE:-<empty>}'). Fallback=codex-safe." >&2
    echo "codex"
}

normalize_special_command() {
    local msg_type="${1:-}"
    local raw_content="${2:-}"

    case "$msg_type" in
        clear_command)
            echo "/clear"
            ;;
        model_switch)
            if [[ "$raw_content" =~ ^/model[[:space:]]+[^[:space:]].* ]]; then
                echo "$raw_content"
            else
                echo "[$(date)] [SKIP] Invalid model_switch payload for $AGENT_ID: ${raw_content:-<empty>}" >&2
            fi
            ;;
        cli_restart)
            # cli_restart is handled externally by switch_cli.sh, not via send_cli_command.
            # Emit a marker so the main loop can call switch_cli.sh.
            echo "__CLI_RESTART__:${raw_content}"
            ;;
    esac
}

enqueue_recovery_task_assigned() {
    (
        # acquire_inbox_lock also takes flock when available.
        if ! acquire_inbox_lock; then
            echo "ERROR"
            exit 0
        fi
        trap release_inbox_lock EXIT
        INBOX_PATH="$INBOX" AGENT_ID="$AGENT_ID" "$SCRIPT_DIR/.venv/bin/python3" - << 'PY'
import datetime
import os
import uuid
import yaml

inbox = os.environ.get("INBOX_PATH", "")
agent_id = os.environ.get("AGENT_ID", "agent")

try:
    with open(inbox, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}

    messages = data.get("messages", []) or []

    # Dedup guard: keep only one pending auto-recovery hint at a time.
    for m in reversed(messages):
        if (
            m.get("from") == "inbox_watcher"
            and m.get("type") == "task_assigned"
            and m.get("read", False) is False
            and "[auto-recovery]" in (m.get("content") or "")
        ):
            print("SKIP_DUPLICATE")
            raise SystemExit(0)

    # Task YAML status guard: skip auto-recovery if task is cancelled or idle.
    # This prevents restarting a task that Karo intentionally cancelled via clear_command.
    task_yaml_path = os.path.join(
        os.path.dirname(os.path.dirname(inbox)), "tasks", f"{agent_id}.yaml"
    )
    if os.path.exists(task_yaml_path):
        try:
            with open(task_yaml_path, "r", encoding="utf-8") as tf:
                task_data = yaml.safe_load(tf) or {}
            task_status = str(task_data.get("status") or "").strip().strip("'\"")
            if task_status in ("cancelled", "idle"):
                print(f"SKIP_CANCELLED:{task_status}")
                raise SystemExit(0)
        except SystemExit:
            raise
        except Exception:
            pass  # If task YAML is unreadable, proceed with auto-recovery as safety net

    now = datetime.datetime.now(datetime.timezone.utc).astimezone()
    # Persona re-establishment on /clear is handled by SessionStart hook
    # (scripts/session_start_hook.sh, matcher=clear). Auto-recovery message only
    # ensures task resumption after the /clear inbox nudge is consumed.
    msg = {
        "content": (
            f"[auto-recovery] /clear 後の再着手通知。"
            f"queue/tasks/{agent_id}.yaml を再読し、assigned タスクを即時再開せよ。"
        ),
        "from": "inbox_watcher",
        "id": f"msg_auto_recovery_{now.strftime('%Y%m%d_%H%M%S')}_{uuid.uuid4().hex[:8]}",
        "read": False,
        "timestamp": now.replace(microsecond=0).isoformat(),
        "type": "task_assigned",
    }
    messages.append(msg)
    data["messages"] = messages

    tmp_path = f"{inbox}.tmp.{os.getpid()}"
    with open(tmp_path, "w", encoding="utf-8") as f:
        yaml.safe_dump(
            data,
            f,
            default_flow_style=False,
            allow_unicode=True,
            sort_keys=False,
        )
    os.replace(tmp_path, inbox)
    print(msg["id"])
except Exception:
    # Best-effort safety net only. Primary /clear delivery must not fail here.
    print("ERROR")
PY
    ) 200>"$LOCKFILE" 2>/dev/null
}

no_idle_full_read() {
    local trigger="${1:-timeout}"
    [ "${ASW_NO_IDLE_FULL_READ:-1}" = "1" ] || return 1
    [ "$trigger" = "timeout" ] || return 1
    [ "${FIRST_UNREAD_SEEN:-0}" -eq 0 ] || return 1
    return 0
}

# summary-first: unread_count fast-path before full read
get_unread_count_fast() {
    INBOX_PATH="$INBOX" "$SCRIPT_DIR/.venv/bin/python3" - << 'PY'
import json
import os
import yaml

inbox = os.environ.get("INBOX_PATH", "")
try:
    with open(inbox, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    messages = data.get("messages", []) or []
    unread_count = sum(1 for m in messages if not m.get("read", False))
    print(json.dumps({"count": unread_count}))
except Exception:
    print(json.dumps({"count": 0}))
PY
}

# ─── Extract unread message info ───
# Returns JSON lines: {"count": N, "has_special": true/false, "specials": [...]}
# Test anchor for bats awk pattern: get_unread_info\\(\\)
#
# cmd_220 F-A: this is a pure PEEK — it no longer marks specials as read.
# Peek and commit used to be fused here (read the message → immediately
# write read:true), which meant a clear_command/model_switch/cli_restart
# was consumed the instant it was *seen*, regardless of whether the busy
# guard downstream actually acted on it. When the busy guard deferred
# (agent busy → `continue`), the message was already gone: "deferred to
# next cycle" was a lie, there was no next cycle (gunshi RCA
# gunshi_rca_ashigaru1_baton_drop_fix2, L2). Committing read:true is now
# the caller's job via mark_special_read(), called only after the special
# is actually handed to send_cli_command and it reports success.
get_unread_info() {
    (
        # acquire_inbox_lock also takes flock when available.
        if ! acquire_inbox_lock; then
            echo '{"count": 0, "specials": []}'
            exit 0
        fi
        trap release_inbox_lock EXIT
        INBOX_PATH="$INBOX" "$SCRIPT_DIR/.venv/bin/python3" - << 'PY'
import json
import os
import yaml

inbox = os.environ.get("INBOX_PATH", "")
try:
    with open(inbox, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}

    messages = data.get("messages", []) or []
    unread = [m for m in messages if not m.get("read", False)]
    special_types = ("clear_command", "model_switch", "cli_restart")
    specials = [m for m in unread if m.get("type") in special_types]

    normal_count = len(unread) - len(specials)
    normal_msgs = [m for m in unread if m.get("type") not in special_types]
    has_task_assigned = any(m.get("type") == "task_assigned" for m in normal_msgs)
    payload = {
        "count": normal_count,
        "has_task_assigned": has_task_assigned,
        "specials": [
            {"type": m.get("type", ""), "content": m.get("content", ""), "id": m.get("id", "")}
            for m in specials
        ],
    }
    print(json.dumps(payload))
except Exception:
    print(json.dumps({"count": 0, "specials": []}))
PY
    ) 200>"$LOCKFILE" 2>/dev/null
}

# ─── Commit a special message as read (cmd_220 F-A) ───
# Call ONLY after the special identified by msg_id was actually handed to
# send_cli_command and it reported success. Never call this from the busy
# guard's defer/continue path — that is precisely the case that must leave
# the message unread so the next cycle sees it again.
mark_special_read() {
    local msg_id="$1"
    [ -n "$msg_id" ] || return 0
    (
        if ! acquire_inbox_lock; then
            exit 0
        fi
        trap release_inbox_lock EXIT
        INBOX_PATH="$INBOX" MSG_ID="$msg_id" "$SCRIPT_DIR/.venv/bin/python3" - << 'PY'
import os
import yaml

inbox = os.environ.get("INBOX_PATH", "")
target_id = os.environ.get("MSG_ID", "")
try:
    with open(inbox, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}

    messages = data.get("messages", []) or []
    changed = False
    for m in messages:
        if m.get("id") == target_id and not m.get("read", False):
            m["read"] = True
            changed = True

    if changed:
        tmp_path = f"{inbox}.tmp.{os.getpid()}"
        with open(tmp_path, "w", encoding="utf-8") as f:
            yaml.safe_dump(
                data,
                f,
                default_flow_style=False,
                allow_unicode=True,
                sort_keys=False,
            )
        os.replace(tmp_path, inbox)
except Exception:
    pass
PY
    ) 200>"$LOCKFILE" 2>/dev/null
}

# ─── Enter-injection gate (cmd_229 AC-4, single unconditional-fail acceptance
# criterion) ───
# All 6 routes that can send Enter into a claude-type pane (R1 send_cli_command,
# R2 send_startup_prompt, R3 send_context_reset, R4 send_wakeup, R5
# send_wakeup_with_escape, R6 attempt_stall_recovery's stall ladder) call this
# instead of the old binary pane_has_open_modal()/pane_awaiting_input() gates.
# Non-claude panes keep whichever legacy binary predicate the route already
# used (scope_of_strict_gate — gunshi_report.yaml §2: non-claude画面構えは
# 本番不在で実測できておらぬ)。
#
# claude_pane_may_enter <pane_target> <cli_type> <legacy_predicate_name>
# Returns 0 (allow) / 1 (deny). Logs the pane_input_safety() verdict and
# feeds unknown_gate_track_streak() (AC-6) — every call site, claude and
# non-claude, funnels through here so the streak counter sees the true
# per-attempt rate regardless of which route triggered it.
claude_pane_may_enter() {
    local pane_target="$1" cli_type="$2" legacy_predicate="$3"

    if [[ "$cli_type" == "claude" ]]; then
        local verdict
        verdict=$(pane_input_safety "$pane_target")
        echo "[$(date)] [ENTER-GATE] $AGENT_ID: pane_input_safety=$verdict" >&2
        unknown_gate_track_streak "$verdict"
        [[ "$verdict" == "safe" || "$verdict" == "working" ]]
        return
    fi

    # Non-claude: legacy two-value gate, unchanged (allow unless the legacy
    # predicate reports true — i.e. modal/awaiting-input open).
    ! "$legacy_predicate" "$pane_target"
}

# unknown_gate_track_streak <verdict> (cmd_229 AC-6)
# A silently-suppressed Enter is the exact shape cmd_218 "鳴らぬ番犬" fixed
# for stall detection — this closes the same hole for the AC-4 gate. Any
# non-unknown verdict resets the streak and the one-shot notify flag (same
# episode-reset pattern as STALL_NTFY_SENT / STALE_BUSY_NTFY_SENT).
UNKNOWN_GATE_STREAK=${UNKNOWN_GATE_STREAK:-0}
UNKNOWN_GATE_NTFY_SENT=${UNKNOWN_GATE_NTFY_SENT:-0}
unknown_gate_track_streak() {
    local verdict="$1"
    if [[ "$verdict" != "unknown" ]]; then
        UNKNOWN_GATE_STREAK=0
        UNKNOWN_GATE_NTFY_SENT=0
        return 0
    fi
    UNKNOWN_GATE_STREAK=$((UNKNOWN_GATE_STREAK + 1))
    local threshold
    threshold=$(stall_policy_query unknown_gate_notify_after 2>/dev/null) || threshold=5
    if [ "$UNKNOWN_GATE_STREAK" -ge "$threshold" ] && [ "${UNKNOWN_GATE_NTFY_SENT:-0}" -eq 0 ]; then
        UNKNOWN_GATE_NTFY_SENT=1
        echo "[$(date)] [ENTER-GATE] $AGENT_ID: pane_input_safety=unknown が ${UNKNOWN_GATE_STREAK}回連続 — Enter送出を見送り中" >&2
        type branch_policy_notify &>/dev/null && branch_policy_notify "${AGENT_ID}: pane_input_safety=unknownが${UNKNOWN_GATE_STREAK}回連続 — Enter送出を見送り中(未読が届かぬ可能性)" 2>/dev/null || true
    fi
    return 0
}

# ─── Send CLI command via pty direct write ───
# For /clear and /model only. These are CLI commands, not conversation messages.
# CLI_TYPE別分岐: claude→そのまま, codex→/clear対応・/modelスキップ,
#                  copilot→Ctrl-C+再起動・/modelスキップ, opencode→/clear→/new・/modelスキップ,
#                  antigravity→/clearそのまま・/modelスキップ
# 実行時にtmux paneの @agent_cli を再確認し、ドリフト時はpane値を優先する。
send_cli_command() {
    local cmd="$1"
    # cmd_220 subtask2 (QC-1/QC-2): global flag, not the return value, tells
    # the caller "this was deferred, not a final disposition". Two callers
    # (line ~1599 stall recovery, ~1925 context reset) invoke this function
    # bare, outside any `if`; a non-zero return there would be killed by
    # set -euo pipefail (see the "Never return 1" comment below). So every
    # transient-suppress path below sets SEND_DEFERRED=1 and still returns 0.
    SEND_DEFERRED=0
    # cmd_171/C1-3: attempt_stall_recovery() passes force_busy=1. A stall is
    # BY DEFINITION busy (is_stalled_pane requires agent_is_busy() true), so
    # the ordinary busy-guard below would silently swallow /clear every time
    # a stall is detected — defeating the ladder's final step entirely.
    local force_busy="${2:-0}"
    local effective_cli
    effective_cli=$(get_effective_cli_type)

    # Modal gate (cmd_209 subtask_209_modal_gate_fix; cmd_229 AC-4 R1): this
    # function sends C-c (line ~716) in addition to Enter. C-c during an open
    # modal is a different kind of destruction (turn interruption) than
    # Enter, so the entire route is gated here rather than gating Enter
    # alone. NOT agent_is_busy_check() — gating on busy-in-general would
    # reintroduce the nudge-deadlock the idle-flag design already fears
    # (spinner flicker → permanent stall). claude type uses the strict
    # three-value gate (pane_input_safety via claude_pane_may_enter);
    # non-claude keeps the legacy pane_has_open_modal() binary gate.
    if ! claude_pane_may_enter "$PANE_TARGET" "$effective_cli" pane_has_open_modal; then
        echo "[$(date)] [SKIP-MODAL] $AGENT_ID: modal open — suppressing CLI command ($cmd)" >&2
        # cmd_220 subtask2 QC-1: this is a transient state, not a final
        # disposition — the modal will eventually close on its own. Tell the
        # caller via SEND_DEFERRED so it does NOT mark the message read.
        SEND_DEFERRED=1
        return 0  # Never return 1 — set -euo pipefail would kill the watcher daemon
    fi

    # cli_restart: delegate to switch_cli.sh (full /exit → relaunch cycle)
    if [[ "$cmd" == __CLI_RESTART__:* ]]; then
        local restart_args="${cmd#__CLI_RESTART__:}"
        echo "[$(date)] [CLI-RESTART] Delegating to switch_cli.sh for $AGENT_ID: ${restart_args}" >&2
        bash "${SCRIPT_DIR}/scripts/switch_cli.sh" "$AGENT_ID" $restart_args 2>&1 | while IFS= read -r line; do  # SCRIPT_DIR=project_root
            echo "[$(date)] [switch_cli] $line" >&2
        done
        # Update effective CLI type after restart
        CLI_TYPE=$(tmux show-options -p -t "$PANE_TARGET" -v @agent_cli 2>/dev/null || echo "$CLI_TYPE")
        return 0
    fi

    # Safety: never inject CLI commands into the shogun pane.
    # Shogun is controlled by the Lord; keystroke injection can clobber human input.
    # cmd_220 F-A: returns 0 (not 1) — this is a final, intentional decision to
    # never send, same status as an actual send from the caller's point of
    # view. The busy-guard loop calls mark_special_read() only when this
    # function returns truthy; returning 1 here would leave a shogun-directed
    # special permanently unread (retried and re-suppressed every cycle
    # forever) instead of the pre-cmd_220 behavior of being handled once.
    if [ "$AGENT_ID" = "shogun" ]; then
        echo "[$(date)] [SKIP] shogun: suppressing CLI command injection ($cmd)" >&2
        return 0
    fi

    # Busy guard: never send /clear when agent is actively processing.
    # clear_command inbox processor also checks busy, but this is a defense-in-depth guard.
    # Sending /clear during Working destroys in-progress context and causes data loss.
    # OpenCode startup can leave capture-pane blank before the first frame renders,
    # so only apply this guard after we can actually observe pane text.
    local pane_snapshot=""
    if [[ "$cmd" == "/clear" ]]; then
        pane_snapshot=$(timeout 2 tmux capture-pane -t "$PANE_TARGET" -p 2>/dev/null || true)
    fi
    if [[ "$cmd" == "/clear" ]] && [ "$force_busy" -ne 1 ] && ! [[ "$effective_cli" == "opencode" && -z "${pane_snapshot//[[:space:]]/}" ]] && agent_is_busy; then
        echo "[$(date)] [SKIP] Agent is busy — /clear deferred to next cycle (agent=$AGENT_ID)" >&2
        # cmd_220 subtask2 QC-2: same as the modal gate above — transient,
        # not final. Normally the outer busy guard (~line 1738) catches this
        # first, but a race window (agent_is_busy flips between the two
        # checks) can reach here directly.
        SEND_DEFERRED=1
        return 0
    fi

    # CLI別コマンド変換
    local actual_cmd="$cmd"
    case "$effective_cli" in
        codex)
            # Codex: /clear不存在→/newで新規会話開始, /model非対応→スキップ
            # /clearはCodexでは未定義コマンドでCLI終了してしまうため、/newに変換
            if [[ "$cmd" == "/clear" ]]; then
                # Guard: skip duplicate /new if already sent for this batch
                if [ "${NEW_CONTEXT_SENT:-0}" -eq 1 ]; then
                    echo "[$(date)] [SKIP] Codex /new already sent for $AGENT_ID — skipping duplicate clear_command" >&2
                    return 0
                fi
                echo "[$(date)] [SEND-KEYS] Codex /clear→/new: starting new conversation for $AGENT_ID" >&2
                # Dismiss suggestion UI first (typing "x" clears autocomplete prompt)
                timeout 5 tmux send-keys -t "$PANE_TARGET" "x" 2>/dev/null || true
                sleep 0.3
                timeout 5 tmux send-keys -t "$PANE_TARGET" C-u 2>/dev/null || true
                sleep 0.3
                timeout 5 tmux send-keys -t "$PANE_TARGET" "/new" 2>/dev/null || true
                sleep 0.3
                timeout 5 tmux send-keys -t "$PANE_TARGET" Enter 2>/dev/null || true
                sleep 3
                # Send startup prompt immediately (don't defer to context-reset cycle)
                send_startup_prompt
                NEW_CONTEXT_SENT=1
                return 0
            fi
            if [[ "$cmd" == /model* ]]; then
                echo "[$(date)] Skipping $cmd (not supported on codex)" >&2
                return 0
            fi
            ;;
        opencode)
            # OpenCode: /clear is normalized to /new, /model changes are restart-only.
            if [[ "$cmd" == "/clear" ]]; then
                if [ "${NEW_CONTEXT_SENT:-0}" -eq 1 ]; then
                    echo "[$(date)] [SKIP] OpenCode /new already sent for $AGENT_ID — skipping duplicate clear_command" >&2
                    return 0
                fi
                echo "[$(date)] [SEND-KEYS] OpenCode /new for clear_command: starting new conversation for $AGENT_ID" >&2
                timeout 5 tmux send-keys -t "$PANE_TARGET" C-u 2>/dev/null || true
                sleep 0.3
                timeout 5 tmux send-keys -t "$PANE_TARGET" "/new" 2>/dev/null || true
                sleep 0.3
                timeout 5 tmux send-keys -t "$PANE_TARGET" Enter 2>/dev/null || true
                sleep 3
                NEW_CONTEXT_SENT=1
                return 0
             fi
            if [[ "$cmd" == /model* ]]; then
                echo "[$(date)] Skipping $cmd (OpenCode model changes are restart-only)" >&2
                return 0
            fi
            ;;
        copilot)
            # Copilot: /clearはCtrl-C+再起動, /model非対応→スキップ
            if [[ "$cmd" == "/clear" ]]; then
                echo "[$(date)] [SEND-KEYS] Copilot /clear: sending Ctrl-C + restart for $AGENT_ID" >&2
                timeout 5 tmux send-keys -t "$PANE_TARGET" C-c 2>/dev/null || true
                sleep 2
                timeout 5 tmux send-keys -t "$PANE_TARGET" "copilot --yolo" 2>/dev/null || true
                sleep 0.3
                timeout 5 tmux send-keys -t "$PANE_TARGET" Enter 2>/dev/null || true
                sleep 3
                return 0
            fi
            if [[ "$cmd" == /model* ]]; then
                echo "[$(date)] Skipping $cmd (not supported on copilot)" >&2
                return 0
            fi
            ;;
        cursor)
            # Cursor: /clear不存在→/new-chatで新規会話開始, /modelは対応
            if [[ "$cmd" == "/clear" ]]; then
                if [ "${NEW_CONTEXT_SENT:-0}" -eq 1 ]; then
                    echo "[$(date)] [SKIP] Cursor /new-chat already sent for $AGENT_ID — skipping duplicate clear_command" >&2
                    return 0
                fi
                echo "[$(date)] [SEND-KEYS] Cursor /clear→/new-chat: starting new conversation for $AGENT_ID" >&2
                timeout 5 tmux send-keys -t "$PANE_TARGET" "/new-chat" 2>/dev/null || true
                sleep 0.3
                timeout 5 tmux send-keys -t "$PANE_TARGET" Enter 2>/dev/null || true
                sleep 3
                NEW_CONTEXT_SENT=1
                return 0
            fi
            ;;
        antigravity)
            if [[ "$cmd" == /model* ]]; then
                echo "[$(date)] Skipping $cmd (Antigravity model changes are restart-only)" >&2
                return 0
            fi
            ;;
        # claude: commands pass through as-is
    esac

    echo "[$(date)] [SEND-KEYS] Sending CLI command to $AGENT_ID ($effective_cli): $actual_cmd" >&2
    # Clear stale input first, then send command (text and Enter separated for Codex TUI)
    # Codex CLI: C-c when idle causes CLI to exit — skip it
    if [[ "$effective_cli" != "codex" ]]; then
        timeout 5 tmux send-keys -t "$PANE_TARGET" C-c 2>/dev/null || true
        sleep 0.5
    fi
    timeout 5 tmux send-keys -t "$PANE_TARGET" "$actual_cmd" 2>/dev/null || true
    # /clear needs longer gap before Enter — CLI prompt may not be ready at 0.3s
    if [[ "$actual_cmd" == "/clear" || "$actual_cmd" == "/new" ]]; then
        sleep 1.0
    else
        sleep 0.3
    fi
    timeout 5 tmux send-keys -t "$PANE_TARGET" Enter 2>/dev/null || true

    # /clear needs extra wait time before follow-up
    if [[ "$actual_cmd" == "/clear" ]]; then
        LAST_CLEAR_TS=$(date +%s)
        sleep 3
        # Claude: send startup prompt so agent re-runs Session Start after /clear
        if [[ "$effective_cli" == "claude" ]]; then
            send_startup_prompt
        fi
    else
        sleep 1
    fi
}

# ─── Send startup prompt after context reset ───
# Waits for agent to become idle, then sends a startup prompt that includes
# full recovery steps (identify, read task YAML, read inbox, start work).
# Codex uses a typed `x` to dismiss its suggestion UI.
# Called from both send_cli_command (clear_command) and send_context_reset.
send_startup_prompt() {
    # Poll until agent becomes idle (prompt ready) instead of fixed sleep.
    # Max 15s (3 attempts × 5s). If still busy after 15s, proceed anyway.
    local attempt
    for attempt in 1 2 3; do
        sleep 5
        if ! agent_is_busy; then
            echo "[$(date)] [STARTUP] $AGENT_ID idle after ${attempt}×5s — sending startup prompt" >&2
            break
        fi
        echo "[$(date)] [STARTUP] $AGENT_ID still busy after ${attempt}×5s — retrying" >&2
    done
    if agent_is_busy; then
        echo "[$(date)] [STARTUP] $AGENT_ID still busy after 15s — proceeding with startup prompt anyway" >&2
    fi

    # Modal gate (cmd_209 subtask_209_modal_gate_fix; cmd_229 AC-4 R2): the
    # busy-poll above proceeds anyway after 15s even if still busy, so it
    # cannot be relied on to stop an Enter into an open modal. Check right
    # before sending — NOT agent_is_busy_check() (that would reintroduce the
    # nudge-deadlock the idle-flag design already fears). claude type uses
    # the strict three-value gate; non-claude keeps the legacy binary gate.
    # decision_rule_if_welcome_is_unknown (gunshi_report.yaml §2-4): this is
    # the one route where an unmeasured `unknown` verdict on the welcome
    # screen could stop出陣 itself — see docs/architecture.md for the
    # live-captured welcome-screen verdict this cmd measured (AC6a).
    local startup_gate_cli
    startup_gate_cli=$(get_effective_cli_type)
    if ! claude_pane_may_enter "$PANE_TARGET" "$startup_gate_cli" pane_has_open_modal; then
        echo "[$(date)] [SKIP-MODAL] $AGENT_ID: modal open — suppressing startup prompt" >&2
        return 0  # Never return 1 — set -euo pipefail would kill the watcher daemon
    fi

    local startup_prompt=""
    if type get_startup_prompt &>/dev/null; then
        startup_prompt=$(get_startup_prompt "$AGENT_ID" 2>/dev/null || true)
    fi
    if [[ -z "$startup_prompt" ]]; then
        startup_prompt="Session Start — do ALL of this in one turn, do NOT stop early: 1) tmux display-message to identify yourself. 2) Read queue/tasks/${AGENT_ID}.yaml. 3) Read queue/inbox/${AGENT_ID}.yaml, mark read:true. 4) Read context_files. 5) Execute the assigned task to completion — edit files, run commands, write reports. Keep working until done."
    fi
    local effective_cli
    effective_cli=$(get_effective_cli_type)
    echo "[$(date)] [STARTUP] Sending startup prompt to $AGENT_ID (${effective_cli}): ${startup_prompt:0:80}..." >&2
    # Dismiss suggestion UI, then send startup prompt
    if [[ "$effective_cli" != "opencode" ]]; then
        timeout 5 tmux send-keys -t "$PANE_TARGET" "x" 2>/dev/null || true
        sleep 0.3
        timeout 5 tmux send-keys -t "$PANE_TARGET" C-u 2>/dev/null || true
        sleep 0.3
    fi
    timeout 5 tmux send-keys -l -t "$PANE_TARGET" "$startup_prompt" 2>/dev/null || true
    sleep 0.3
    timeout 5 tmux send-keys -t "$PANE_TARGET" Enter 2>/dev/null || true
    STARTUP_PROMPT_SENT=1
}

# ─── Send context reset before new task ───
# Called when task_assigned is detected in unread messages.
# Sends the appropriate "new conversation" command per CLI type to clear
# stale context from the previous task.
# CLI mapping: claude→/clear, codex→/new, opencode→/new, cursor→/new-chat, copilot→/clear, kimi→/clear
# CLI mapping: claude→/clear, codex→/new, opencode→/new, copilot→/clear, kimi→/clear, antigravity→/clear

send_context_reset() {
    local effective_cli
    effective_cli=$(get_effective_cli_type)

    # Safety: never auto-reset context for command-layer agents.
    # Only ashigaru should receive automatic context resets (clear stale task context).
    # Shogun (human-controlled), Karo (coordinator state), Gunshi (strategic state)
    # all maintain complex running context that should not be wiped automatically.
    if [ "$AGENT_ID" = "shogun" ] || [ "$AGENT_ID" = "karo" ] || [ "$AGENT_ID" = "gunshi" ]; then
        echo "[$(date)] [SKIP] $AGENT_ID: suppressing context reset (command-layer agent)" >&2
        return 0
    fi

    # Modal gate (cmd_209 subtask_209_modal_gate_fix; cmd_229 AC-4 R3): this
    # function had no busy guard at all before this fix. Not
    # agent_is_busy_check() (see send_cli_command for why). cmd_217:
    # modal-skip now returns 1 (defer) instead of 0 — the sole caller wraps
    # this call in `if send_context_reset; then ...` so a non-zero return
    # here means "retry next cycle", not "watcher dies". claude type uses
    # the strict three-value gate; non-claude keeps the legacy binary gate.
    if ! claude_pane_may_enter "$PANE_TARGET" "$effective_cli" pane_has_open_modal; then
        echo "[$(date)] [SKIP-MODAL] $AGENT_ID: modal open — suppressing context reset" >&2
        return 1
    fi

    # cmd_217: busy guard. Previously omitted deliberately — agent_is_busy()
    # for claude was a presence-only lie (§1-2, gunshi_design_217), so
    # gating on it here would have reintroduced the nudge/reset deadlock the
    # idle-flag design feared. Now that agent_is_busy() reflects the real
    # two-marker judgment, this guard finally means something: sending
    # /clear into a mid-turn agent destroys in-progress context.
    if agent_is_busy; then
        echo "[$(date)] [SKIP] $AGENT_ID: busy — deferring context reset to next cycle" >&2
        return 1
    fi

    local reset_cmd
    case "$effective_cli" in
        codex)    reset_cmd="/new" ;;
        opencode) reset_cmd="/new" ;;
        cursor)   reset_cmd="/new-chat" ;;
        claude)   reset_cmd="/clear" ;;
        copilot)  reset_cmd="/clear" ;;
        kimi)     reset_cmd="/clear" ;;
        antigravity) reset_cmd="/clear" ;;
        *)        reset_cmd="/new" ;;  # safe default (codex-safe)
    esac

    echo "[$(date)] [CONTEXT-RESET] Sending $reset_cmd before task_assigned for $AGENT_ID ($effective_cli)" >&2

    # Codex/OpenCode/Cursor: send new-context command as a single atomic operation.
    # When called from clear_command path, NEW_CONTEXT_SENT=1 prevents reaching here.
    # When called for standalone task_assigned, this is the only send.
    if [[ "$effective_cli" == "codex" || "$effective_cli" == "opencode" || "$effective_cli" == "cursor" ]]; then
        # Dismiss suggestion UI (Codex only) + send reset command
        if [[ "$effective_cli" == "codex" ]]; then
            timeout 5 tmux send-keys -t "$PANE_TARGET" "x" 2>/dev/null || true
            sleep 0.3
        fi
        if [[ "$effective_cli" != "cursor" ]]; then
            timeout 5 tmux send-keys -t "$PANE_TARGET" C-u 2>/dev/null || true
            sleep 0.3
        fi
        timeout 5 tmux send-keys -t "$PANE_TARGET" "$reset_cmd" 2>/dev/null || true
        sleep 0.3
        timeout 5 tmux send-keys -t "$PANE_TARGET" Enter 2>/dev/null || true
        sleep 3
        # Codex: send startup prompt (agent has no auto-loaded instructions).
        # OpenCode: skip — agent definition is auto-loaded via --agent flag.
        if [[ "$effective_cli" == "codex" ]]; then
            send_startup_prompt
        fi
        return 0
    fi

    # Non-Codex CLIs: send /clear and wait for idle
    # Send the command (text and Enter separated for TUI compatibility)
    timeout 5 tmux send-keys -t "$PANE_TARGET" "$reset_cmd" 2>/dev/null || true
    # Longer gap for /clear — CLI prompt rendering needs time
    sleep 1.0
    timeout 5 tmux send-keys -t "$PANE_TARGET" Enter 2>/dev/null || true
    # Mark /clear timestamp so agent_is_busy() treats it as busy during processing
    if [[ "$reset_cmd" == "/clear" ]]; then
        LAST_CLEAR_TS=$(date +%s)
    fi

    # Poll until agent becomes idle (prompt ready) instead of fixed sleep.
    # Max 15s (3 attempts × 5s). If still busy after 15s, proceed anyway.
    local attempt
    for attempt in 1 2 3; do
        sleep 5
        if ! agent_is_busy; then
            echo "[$(date)] [CONTEXT-RESET] $AGENT_ID idle after ${attempt}×5s — ready for nudge" >&2
            break
        fi
        echo "[$(date)] [CONTEXT-RESET] $AGENT_ID still busy after ${attempt}×5s — retrying" >&2
    done
    if agent_is_busy; then
        echo "[$(date)] [CONTEXT-RESET] $AGENT_ID still busy after 15s — proceeding anyway" >&2
    fi
}

# ─── Agent self-watch detection ───
# Check if the agent has an active inotifywait on its inbox.
# If yes, the agent will self-wake — no nudge needed.
agent_has_self_watch() {
    # Codex/Copilot/Kimi/OpenCode CLIs cannot run self-watch. Only Claude Code agents can.
    local effective_cli
    effective_cli=$(get_effective_cli_type)
    if [[ "$effective_cli" != "claude" ]]; then
        return 1  # non-Claude CLIs never have self-watch
    fi
    # For Claude Code agents: check if an inotifywait exists that is NOT
    # a child of this inbox_watcher process (exclude our own watcher).
    local my_pgid
    my_pgid=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
    local found=1  # default: not found
    while IFS= read -r pid; do
        local pid_pgid
        pid_pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
        if [[ "$pid_pgid" != "$my_pgid" ]]; then
            found=0  # found an inotifywait NOT from our process group
            break
        fi
    done < <(pgrep -f "inotifywait.*inbox/${AGENT_ID}.yaml" 2>/dev/null)
    return $found
}

# ─── Agent busy detection ───
# Check if the agent's CLI is currently processing (Working/thinking/etc).
# Sending nudge during Working causes text to queue but Enter to be lost.
# Returns 0 (true) if agent is busy, 1 if idle.
# Implementation: delegates to lib/agent_status.sh (shared library).
agent_is_busy() {
    # /clear cooldown: treat agent as busy for 30s after /clear was sent.
    # Claude Code's /clear takes 10-30s (CLAUDE.md reload + context init).
    # Without this, nudges sent during /clear processing queue up at the prompt
    # and cause race conditions (inbox1 arrives before /clear completes).
    local now_busy
    now_busy=$(date +%s)
    if [ "${LAST_CLEAR_TS:-0}" -gt 0 ] && [ "$((now_busy - LAST_CLEAR_TS))" -lt 30 ]; then
        return 0  # busy — /clear still processing
    fi

    local effective_cli
    effective_cli=$(get_effective_cli_type)
    if [[ "$effective_cli" == "claude" ]]; then
        # cmd_217: 二枚の印（busy印/idle印）の新旧mtime比較方式へ移行。
        # 存在のみを見る旧方式（フラグなし=busy）は、touchに門を付けても
        # 判定を1ミリも変えぬ死に体だった（§1-2, gunshi_design_217参照）。
        [[ "$(agent_turn_state "$AGENT_ID")" == "busy" ]]
    else
        # 従来のpane解析（Codex等フォールバック）
        agent_is_busy_check "$PANE_TARGET" "$effective_cli"
    fi
}

# ─── Stall detection (cmd_171 / T1) ───
# Same double-source guard for usage_limit_state() (cmd_171 P-1), so it is
# available in test mode too (in normal mode it was already sourced above
# by the first testing-guarded block; double-sourcing is harmless). Placed
# here — immediately before the fallback stub below — rather than at the
# bottom of the file with the stall_policy/branch_policy guards, because
# the stub definition below runs unconditionally in both modes: if the
# guard ran after it, `type usage_limit_state` would already see the stub
# and skip loading the real implementation in test mode.
_usage_limit_lib="${SCRIPT_DIR}/lib/usage_limit.sh"
if [ -f "$_usage_limit_lib" ] && ! type usage_limit_state &>/dev/null; then
    source "$_usage_limit_lib"
fi

# usage_limit_state() lives in lib/usage_limit.sh and is now sourced above
# (cmd_171 P-1), so the real implementation is used from here on. The
# fallback stub below remains only as a safety net for the unlikely case
# that lib/usage_limit.sh fails to load.
declare -f usage_limit_state >/dev/null || usage_limit_state() { echo unknown; }

# stall検知専用。フラグファイルではなくpane解析を直接見る。
# agent_is_busy()（配送経路が依存する）とは意図的に分離する（cmd_209 P-2）:
# agent_is_busy() を claude 向けに直せば、nudge抑止・/clearガード・
# エスカレーションという配送経路が同時に挙動を変えてしまうため、
# stall検知の前提だけをここで差し替える。
#
# cmd_220 S-1 STALL_BUSY_OR_TURN_STATE: pane幅44ではagent_is_busy_check()の
# 末尾行'esc to'規則がヒント行の切り詰めにより現れず、stall検知が誤idleへ
# 落ちる（gunshi_design_220_pane_width_busy_scope §width_mechanism）。
# 単純にagent_turn_stateへ差し替えるのは退行——UserPromptSubmit hookが
# 未装填の日、agent_turn_stateは静かに「常にidle」へ縮退し（cmd_217の
# 設計どおり）、stall検知がそれだけに依存すると緑のまま丸ごと沈黙する。
# ゆえに二つの幅非依存な入力の論理和にする。
#
# 【軍師設計からの変更点】軍師の設計案は第二項に`pane_has_open_modal`
# （選択肢一覧型モーダルの脚注アンカーのみ）を挙げていたが、実装時に
# tests/unit/test_stall_detect.bats TC-STALL-001等（REAL_BUSY_TAIL=
# ' Esc to cancel · Tab to amend · ctrl+e to explain'——選択肢一覧では
# ない許可確認ダイアログの実測フィクスチャ、cmd_209 P-2 Step0で採取）
# で実測すると、この文言は`pane_has_open_modal`のどのアンカー
# （enter to select|to navigate|↑/↓|enter to confirm）にも一致せず、
# 旧来`agent_is_busy_check`の末尾行'esc to'規則で拾えていたものを
# 新たに取り逃す（AC4が禁じる誤idle面の新設）。ゆえに第二項は
# `pane_has_open_modal`ではなく`agent_is_busy_check`（旧来のstall_busy
# 全量、末尾行'esc to'・モーダル脚注・spinner語彙を全て含む）を採る。
# こちらは旧stall_busy()の検知力を包含する厳密な上位集合であり、
# agent_turn_stateを追加するだけで何も失わない。is_stalled_paneは
# busyかつ画面hash無変化の二重ゲートゆえ、busy側を広げても誤検知には
# 直結しない。
stall_busy() {
    local cli
    cli=$(get_effective_cli_type)
    if [[ "$cli" == "claude" ]]; then
        [[ "$(agent_turn_state "$AGENT_ID")" == "busy" ]] || agent_is_busy_check "$PANE_TARGET" "$cli"
    else
        agent_is_busy
    fi
}

# ─── STALE_BUSY_REQUIRES_FROZEN_PANE: shared pane-hash-freeze core (cmd_217 D-1) ───
# Computes how long PANE_TARGET's content hash has been unchanged. Shared by
# is_stalled_pane() below (stall_after_sec threshold) and the 300s stale-busy
# safety net (stale_busy_limit threshold, further down this file) — same
# mechanism (screen movement = alive), separate state per caller
# (gunshi_report.yaml design_4: "hash不変判定部分のみを共有し、閾値は
# 混ぜるな").
#
# NOTE: must be called directly (pane_hash_frozen_sec VAR1 VAR2), never via
# command substitution ($(pane_hash_frozen_sec ...)) — command substitution
# forks a subshell, and the nameref writes to the caller's hash/since state
# would be silently lost the instant that subshell exits. The result is
# returned via the global PANE_HASH_FROZEN_SEC instead of stdout.
#
# Args: $1 = name of caller's hash-value variable (nameref)
#       $2 = name of caller's hash-since variable (nameref)
# On success: sets PANE_HASH_FROZEN_SEC to the number of seconds the hash
# has been unchanged (0 on first observation / on a hash change), returns 0.
# On pane capture failure or empty capture (indeterminate — pane gone, tmux
# hiccup): clears the caller's hash var, clears PANE_HASH_FROZEN_SEC,
# returns 1. Never treat capture failure as "frozen" (T-D4/M9: 判定不能を
# 固着と断ずるな).
PANE_HASH_FROZEN_SEC=""
pane_hash_frozen_sec() {
    local -n _phf_hash="$1"
    local -n _phf_since="$2"
    local now capture_output capture_rc
    now=$(date +%s)
    capture_output=$(timeout 2 tmux capture-pane -t "$PANE_TARGET" -p 2>/dev/null)
    capture_rc=$?
    # Capture failure or empty pane (e.g. pane gone) → indeterminate, do nothing.
    # NOTE: we check capture_output directly rather than the post-cksum hash —
    # cksum of zero bytes still yields a non-empty checksum ("4294967295"), so
    # testing the hash for emptiness would never catch this case.
    if [ "$capture_rc" -ne 0 ] || [ -z "$capture_output" ]; then
        _phf_hash=""
        PANE_HASH_FROZEN_SEC=""
        return 1
    fi

    local h
    h=$(printf '%s' "$capture_output" | cksum | awk '{print $1}')

    if [ "$h" != "$_phf_hash" ]; then
        _phf_hash="$h"
        _phf_since="$now"
        PANE_HASH_FROZEN_SEC=0
        return 0  # screen moved — alive
    fi

    PANE_HASH_FROZEN_SEC=$((now - _phf_since))
    return 0
}

# is_stalled_pane: type-A (interactive-modal-style) stall detection.
# True only when busy AND the pane content hash has been unchanged for
# stall_after_sec. This is the false-positive guard — genuine long-running
# turns keep printing tokens/spinner, so the hash keeps changing.
is_stalled_pane() {
    # Not busy → not stalled. Reset tracking state.
    if ! stall_busy; then
        STALL_HASH=""
        STALL_HASH_SINCE=0
        return 1
    fi

    pane_hash_frozen_sec STALL_HASH STALL_HASH_SINCE || return 1

    # Same hash persisting — check duration against threshold
    local stall_after_sec
    stall_after_sec=$(stall_policy_query stall_after_sec 2>/dev/null) || stall_after_sec=480
    [ "$PANE_HASH_FROZEN_SEC" -ge "$stall_after_sec" ]
}

# ─── Pane focus detection (human safety) ───
# If the target pane is currently active, avoid injecting keystrokes.
pane_is_active() {
    local active=""
    active=$(timeout 2 tmux display-message -p -t "$PANE_TARGET" '#{pane_active}' 2>/dev/null || true)
    [ "$active" = "1" ]
}

# ─── Session attach detection ───
# Function: session_has_client
# Description: Checks if the tmux session containing PANE_TARGET has at least
#   one client attached. Used to avoid suppressing send-keys when no human is
#   watching (e.g. single-pane shogun session where pane_is_active is always true).
# Arguments: none (uses global PANE_TARGET)
# Returns: 0 if at least one client is attached, 1 otherwise
session_has_client() {
    local session_name
    session_name=$(timeout 2 tmux display-message -p -t "$PANE_TARGET" '#{session_name}' 2>/dev/null || true)
    [ -n "$session_name" ] && [ "$(tmux list-clients -t "$session_name" 2>/dev/null | wc -l)" -gt 0 ]
}

# ─── Human input-guard detection (cmd_182) ───
# Function: client_last_activity_epoch
# Description: Returns the newest #{client_activity} (epoch seconds) among all
#   tmux clients attached to the session containing PANE_TARGET. This measures
#   "how recently a human touched the keyboard", not "is a terminal open"
#   (session_has_client / pane_is_active answer the latter and are always true
#   for a single-pane session like shogun — see gunshi cmd_182 verification).
#   If no client is attached, prints nothing (empty string).
# Arguments: none (uses global PANE_TARGET)
# Returns: always 0. Newest client_activity epoch on stdout, or empty.
client_last_activity_epoch() {
    local session_name
    session_name=$(timeout 2 tmux display-message -p -t "$PANE_TARGET" '#{session_name}' 2>/dev/null || true)
    [ -n "$session_name" ] || return 0
    timeout 2 tmux list-clients -t "$session_name" -F '#{client_activity}' 2>/dev/null | sort -n | tail -1
}

# Function: human_typing_recently
# Description: True if a client attached to PANE_TARGET's session has been
#   active within the last shogun_input_guard_sec seconds. Used to defer
#   (not drop) shogun nudges so they never interrupt an in-progress keystroke
#   (cmd_182 — "issue 37" corrupted into "inbox137" by a mid-line nudge).
# Returns: 0 if a client was active within the guard window, 1 otherwise
#   (including when no client is attached at all).
human_typing_recently() {
    local guard newest now
    guard=$(shogun_input_guard_query shogun_input_guard_sec 2>/dev/null) || guard=60
    newest=$(client_last_activity_epoch)
    [ -n "$newest" ] || return 1
    now=$(date +%s)
    [ "$((now - newest))" -lt "$guard" ]
}

# ─── Send wake-up nudge ───
# Layered approach:
#   1. If agent has active inotifywait self-watch → skip (agent wakes itself)
#   2. If agent is busy (Working) → skip (nudge during Working loses Enter)
#   3. tmux send-keys (短いnudgeのみ、timeout 5s)
send_wakeup() {
    local unread_count="$1"
    local nudge="inbox${unread_count}"

    if [ "${FINAL_ESCALATION_ONLY:-0}" = "1" ]; then
        echo "[$(date)] [SKIP] FINAL_ESCALATION_ONLY=1, suppressing normal nudge for $AGENT_ID" >&2
        return 0
    fi

    # 優先度1: Agent self-watch — nudge不要（エージェントが自分で気づく）
    if agent_has_self_watch; then
        echo "[$(date)] [SKIP] Agent $AGENT_ID has active self-watch, no nudge needed" >&2
        return 0
    fi

    # 優先度2 (cmd_182): shogun + 主が直近打鍵中 — send-keysで割り込むと
    # 入力行が壊れる（"issue 37"→"inbox137"の実例）。破棄ではなく延期。
    # agent_is_busy判定より前に置くこと（shogunのbusy例外を温存しつつ、
    # それより先に人間打鍵を検知するため）。
    # QC40-F1: 将軍のwatcherは ASW_PROCESS_TIMEOUT=0 で走る（event-driven
    # のみ。shutsujin_departure.sh:910-912）。ゆえに「次サイクル」は
    # inboxへの書き込みイベント時にしか来ない。延期しただけでは再評価が
    # 永久に起こらぬため、SHOGUN_DEFER_PENDINGを立てて主ループのtimeout
    # 分岐を延期中だけ開かせる（should_process_timeout_tick参照）。
    if [ "$AGENT_ID" = "shogun" ] && human_typing_recently; then
        echo "[$(date)] [DEFER] shogun: 主の打鍵を検知。send-keysを延期しdisplay-messageで通知" >&2
        timeout 2 tmux display-message -t "$PANE_TARGET" "$nudge" 2>/dev/null || true
        SHOGUN_DEFER_PENDING=1
        local defer_ntfy_after
        defer_ntfy_after=$(shogun_input_guard_query shogun_defer_ntfy_after_sec 2>/dev/null) || defer_ntfy_after=300
        if [ "${FIRST_UNREAD_SEEN:-0}" -gt 0 ] 2>/dev/null; then
            local defer_elapsed
            defer_elapsed=$(( $(date +%s) - FIRST_UNREAD_SEEN ))
            # QC40-F2: 一度きり旗。無いとF1で再評価が回るようになった途端、
            # 30秒ごとに主のスマホが鳴り続ける（死んだ経路が洪水に化ける）。
            if [ "$defer_elapsed" -ge "$defer_ntfy_after" ] && [ "${SHOGUN_DEFER_NTFY_SENT:-0}" -eq 0 ]; then
                type branch_policy_notify &>/dev/null && branch_policy_notify "shogun宛の通知が${defer_elapsed}秒延期中(打鍵検知)" 2>/dev/null || true
                SHOGUN_DEFER_NTFY_SENT=1
            fi
        fi
        return 0     # 破棄ではない。未読は残り、SHOGUN_DEFER_PENDING経由で再評価される
    fi

    # 優先度3: Agent busy — nudge送信するとEnterが消失するためスキップ
    # Claude Code: Stop hook catches unread at turn end. Skip nudge to avoid Enter loss.
    # Exception: shogun — ntfy must be delivered immediately regardless of busy state.
    if agent_is_busy && [[ "$AGENT_ID" != "shogun" ]]; then
        local busy_cli_wakeup
        busy_cli_wakeup=$(get_effective_cli_type)
        if [[ "$busy_cli_wakeup" == "claude" ]]; then
            echo "[$(date)] [SKIP] Agent $AGENT_ID is busy (claude) — Stop hook will deliver, no nudge" >&2
        else
            echo "[$(date)] [SKIP] Agent $AGENT_ID is busy ($busy_cli_wakeup), deferring nudge" >&2
        fi
        return 0
    fi

    if should_throttle_nudge "$unread_count"; then
        return 0
    fi

    # Modal gate (cmd_209 subtask_209_modal_gate_fix; cmd_229 AC-4 R4): the
    # busy-check at 優先度3 above (agent_is_busy) is a no-op for claude
    # agents — see RCA gunshi_rca_209_modal_autoclose.yaml. Add a narrow,
    # separate gate here, NOT agent_is_busy_check() (gating on busy-in-general
    # would reintroduce the nudge-deadlock the idle-flag design already
    # fears). Do NOT clear unread here — this only skips delivery, it does
    # not mean delivery completed. claude type uses the strict three-value
    # gate; non-claude keeps the legacy binary gate.
    local effective_cli_for_nudge
    effective_cli_for_nudge=$(get_effective_cli_type)
    if ! claude_pane_may_enter "$PANE_TARGET" "$effective_cli_for_nudge" pane_has_open_modal; then
        echo "[$(date)] [SKIP-MODAL] $AGENT_ID: modal open — suppressing nudge" >&2
        return 0
    fi

    # Shogun: deliver nudge via send-keys like other agents.
    # ntfy messages must reach Claude Code directly.

    # 優先度3: tmux send-keys（テキストとEnterを分離 — Codex TUI対策）
    echo "[$(date)] [SEND-KEYS] Sending nudge to $PANE_TARGET for $AGENT_ID" >&2

    # Codex suggestion UI dismissal: typing any character dismisses the autocomplete
    # suggestion prompt (› Implement {feature} etc.) that traps idle agents.
    # Sequence: "x" (dismiss suggestion) → C-u (clear input) → nudge → Enter
    if [[ "$effective_cli_for_nudge" == "codex" ]]; then
        timeout 5 tmux send-keys -t "$PANE_TARGET" "x" 2>/dev/null || true
        sleep 0.3
        timeout 5 tmux send-keys -t "$PANE_TARGET" C-u 2>/dev/null || true
        sleep 0.3
    fi

    # 行クリア（残存テキスト除去）→ nudge送信 → Enter → 確認 → 最大2回リトライ
    local max_retries=2
    local attempt=0
    while [ $attempt -le $max_retries ]; do
        # C-u で行をクリア
        timeout 5 tmux send-keys -t "$PANE_TARGET" C-u 2>/dev/null || true
        sleep 0.3
        # nudge 送信
        if ! timeout 5 tmux send-keys -t "$PANE_TARGET" "$nudge" 2>/dev/null; then
            echo "[$(date)] WARNING: send-keys nudge failed for $AGENT_ID (attempt $((attempt+1)))" >&2
            attempt=$((attempt+1))
            continue
        fi
        sleep 0.3
        # cmd_229 AC-5 TOCTOU: the gate above ran once, before the retry loop
        # began. Up to 3 iterations of C-u+text+Enter (~1.1s each, 3s+ total)
        # pass before this Enter fires — long enough for a modal to open in
        # between (agent自身がAskUserQuestionをいつでも開き得る). Re-evaluate
        # immediately before EACH Enter, not just once at entry.
        if ! claude_pane_may_enter "$PANE_TARGET" "$effective_cli_for_nudge" pane_has_open_modal; then
            echo "[$(date)] [SKIP-MODAL] $AGENT_ID: modal opened mid-retry — aborting nudge before Enter (TOCTOU guard, attempt $((attempt+1)))" >&2
            return 0
        fi
        timeout 5 tmux send-keys -t "$PANE_TARGET" Enter 2>/dev/null || true
        sleep 0.5
        if [[ "$effective_cli_for_nudge" == "codex" ]]; then
            # Codex echoes submitted text in the transcript; seeing inboxN after
            # Enter does not mean it is still stuck in the input field.
            echo "[$(date)] Wake-up sent to $AGENT_ID (${unread_count} unread, attempt $((attempt+1)), cli=codex)" >&2
            return 0
        fi
        # 送信確認: capture-pane でプロンプトにnudgeテキストが残っていないか確認
        local pane_content
        pane_content=$(timeout 3 tmux capture-pane -t "$PANE_TARGET" -p 2>/dev/null | tail -5 || echo "")
        if echo "$pane_content" | grep -qF "$nudge"; then
            # nudgeテキストが残存 → 送信失敗 → C-u クリアしてリトライ
            echo "[$(date)] WARNING: nudge text still visible in pane, retrying (attempt $((attempt+1)))" >&2
            timeout 5 tmux send-keys -t "$PANE_TARGET" C-u 2>/dev/null || true
            sleep 0.3
            attempt=$((attempt+1))
            continue
        fi
        # 送信成功
        # NOTE: アイドルフラグは削除しない。nudge送信≠エージェント起動確認。
        # フラグを消すと agent_is_busy()=true → 以降のnudge全スキップ → デッドロック。
        # フラグはエージェントが実際に作業開始した時に自然消滅する（stop_hook設計と整合）。
        reset_shogun_defer_state  # QC40-F1/F2: 実際に届いたので延期状態を解除
        check_hook_armed  # cmd_217 §2-3: 装填検査カウント
        echo "[$(date)] Wake-up sent to $AGENT_ID (${unread_count} unread, attempt $((attempt+1)))" >&2
        return 0
    done
    echo "[$(date)] WARNING: send-keys failed after $max_retries retries for $AGENT_ID" >&2
    return 0  # Never return 1 — set -euo pipefail would kill the watcher daemon
}

# ─── Send wake-up nudge with Escape prefix ───
# Phase 2 escalation: Copilot/Kimi get Escape×2 + single Ctrl-C + nudge.
# Claude/Codex/OpenCode fall back to a plain nudge.
#
# cmd_217 design_3 C-1 (記述是正のみ、コード変更ではない): AC4第3経路
# （エスカレーション）は claude 型エージェントに対しては「順序を直せば
# 到達する」ものではなく、そもそも段が無い。この関数を上から読むと、
# cli=claude の場合は下記の早期return（"claude: suppressing Escape
# escalation" ログ行）で plain nudge へ落ちて即 return するため、そこから下にある
# agent_has_self_watch()・agent_is_busy() のガード順序や pane_has_open_
# modal() は claude に対しては構造上到達不能である（gunshi_report.yaml
# design_3参照。以前の記述「self-watch早期returnとbusyガードの順序
# 見直し」は、claudeの実際の配送経路を指したものではなかった）。
# claude 向けの実際の配送は Stop hook + plain nudge の二段のみであり、
# 三段目は無い。第3段の新設（C-2）はN-3の病を悪化させ得るため本PRの
# 範囲外——別cmdとして将軍へ上申済み（着地後の再評価は家老が📌へ記録）。
send_wakeup_with_escape() {
    local unread_count="$1"
    local nudge="inbox${unread_count}"
    local effective_cli
    effective_cli=$(get_effective_cli_type)

    # Safety: never send Escape escalation to shogun. It can wipe the Lord's input.
    if [ "$AGENT_ID" = "shogun" ]; then
        echo "[$(date)] [SKIP] shogun: suppressing Escape escalation; sending plain nudge" >&2
        send_wakeup "$unread_count"
        return 0
    fi

    # Codex CLI: ESC は「中断」になりやすく、人間操作中の事故も多い。
    # Phase 2 の Escape エスカレーションは無効化し、通常 nudge のみに落とす。
    if [[ "$effective_cli" == "codex" ]]; then
        echo "[$(date)] [SKIP] codex: suppressing Escape escalation for $AGENT_ID; sending plain nudge" >&2
        send_wakeup "$unread_count"
        return 0
    fi

    # Claude Code: Stop hookがturn終了時にinbox未読を検出→自動処理する。
    # Escape送信は処理中のturnを中断させるため有害。Phase 2は通常nudgeに落とす。
    if [[ "$effective_cli" == "claude" ]]; then
        echo "[$(date)] [SKIP] claude: suppressing Escape escalation for $AGENT_ID (Stop hook handles delivery); sending plain nudge" >&2
        send_wakeup "$unread_count"
        return 0
    fi

    # OpenCode: Escape is bound to session_interrupt in the pinned TUI config.
    # Phase 2 must not interrupt the session; fall back to a plain nudge.
    if [[ "$effective_cli" == "opencode" || "$effective_cli" == "antigravity" ]]; then
        echo "[$(date)] [SKIP] opencode: suppressing Escape escalation for $AGENT_ID (Escape interrupts the session); sending plain nudge" >&2
        send_wakeup "$unread_count"
        return 0
    fi

    if [ "${FINAL_ESCALATION_ONLY:-0}" = "1" ]; then
        echo "[$(date)] [SKIP] FINAL_ESCALATION_ONLY=1, suppressing phase2 nudge for $AGENT_ID" >&2
        return 0
    fi

    if agent_has_self_watch; then
        return 0
    fi

    # Phase 2 still skips if agent is busy — Escape during Working would interrupt
    if agent_is_busy; then
        echo "[$(date)] [SKIP] Agent $AGENT_ID is busy (Working), deferring Phase 2 nudge" >&2
        return 0
    fi

    # Modal gate (cmd_209 subtask_209_modal_gate_fix; cmd_229 AC-4 R5):
    # claude/codex/opencode/antigravity already fall back to send_wakeup()
    # above (gated there — claude's own gate is unreachable here by
    # construction). This is the remaining raw path (copilot/kimi/etc.) —
    # claude_pane_may_enter() with the same legacy fallback as before, kept
    # for symmetry with the other 5 routes should this function's early
    # returns ever change.
    if ! claude_pane_may_enter "$PANE_TARGET" "$effective_cli" pane_has_open_modal; then
        echo "[$(date)] [SKIP-MODAL] $AGENT_ID: modal open — suppressing Escape+nudge" >&2
        return 0
    fi

    echo "[$(date)] [SEND-KEYS] ESCALATION Phase 2: Escape×2 + nudge for $AGENT_ID (cli=$effective_cli)" >&2
    # Escape×2 to exit any mode
    timeout 5 tmux send-keys -t "$PANE_TARGET" Escape Escape 2>/dev/null || true
    sleep 0.5
    if [[ "$effective_cli" == "copilot" || "$effective_cli" == "kimi" ]]; then
        timeout 5 tmux send-keys -t "$PANE_TARGET" C-c 2>/dev/null || true
        sleep 0.5
    fi
    if timeout 5 tmux send-keys -t "$PANE_TARGET" "$nudge" 2>/dev/null; then
        sleep 0.3
        timeout 5 tmux send-keys -t "$PANE_TARGET" Enter 2>/dev/null || true
        echo "[$(date)] Escape+nudge sent to $AGENT_ID (${unread_count} unread, cli=$effective_cli)" >&2
        return 0
    fi

    echo "[$(date)] WARNING: send-keys failed for Escape+nudge ($AGENT_ID)" >&2
    return 0  # Never return 1 — set -euo pipefail would kill the watcher daemon
}

# ─── Stall notify (cmd_218 residual_hole) ───
# An Escape-proof stall (or a persistent usage_limited verdict) never gets
# reported to anyone otherwise — the ladder just keeps firing into the void.
# Fires branch_policy_notify() exactly once per episode (STALL_NTFY_SENT),
# reset by attempt_stall_recovery() the instant is_stalled_pane() reports the
# pane moved. Never returns non-zero — set -euo pipefail would kill the
# watcher daemon.
stall_maybe_notify() {
    local agent="$1" kind="$2" count="$3"
    [ "${STALL_NTFY_SENT:-0}" = "1" ] && return 0

    local threshold
    threshold=$(stall_policy_query stall_notify_after_attempts 2>/dev/null) || threshold=3
    if [ "$count" -ge "$threshold" ] 2>/dev/null; then
        STALL_NTFY_SENT=1
        echo "[$(date)] [STALL-NTFY] $agent: $kind unresolved after $count attempts — notifying" >&2
        branch_policy_notify "${agent} が固着（${kind}）。自動復帰不能——${count}回試行後も未解消" 2>/dev/null || true
    fi
    return 0
}

# ─── Stall recovery (cmd_171 / T1) ───
# Escalation ladder for a detected type-A stall: Escape×2 -> (30s) nudge ->
# (30s) /clear. Re-checks is_stalled_pane() before each step and aborts the
# remaining steps the instant the screen starts moving again (TC-STALL-007).
# opt-in via stall_policy.enabled (default false — lord's authorization).
attempt_stall_recovery() {
    if [ "$(stall_policy_query enabled 2>/dev/null)" != "true" ]; then
        return 0
    fi

    # cmd_209 主裁可: 当面は足軽paneのみを対象とする。
    # 家老・軍師・将軍のpaneへはキーを注入せぬ（将軍paneは主の卓）。
    if [[ ! "$AGENT_ID" =~ ^ashigaru[0-9]+$ ]]; then
        return 0
    fi

    # Gate 0: human may be operating this pane right now — never inject keys.
    if pane_is_active && session_has_client; then
        return 0
    fi

    # Gate 2 (evaluated first — cmd_209 P-2 F1): type-A detection. Cheap
    # (tmux capture + cksum, no external API), so check it before Gate 1's
    # usage_limit_state call. §1.0's principle that type-C takes priority
    # over type-A is unchanged — evaluation ORDER moved, but the priority
    # of the VERDICT below did not: a stalled+limited pane still falls
    # through to the Gate 1 check and returns without action.
    if ! is_stalled_pane; then
        # cmd_218: pane moved (or was never stalled) — episode over, reset
        # the notify counters so the next stall starts a fresh episode.
        STALL_UNRESPONSIVE_ATTEMPTS=0
        STALL_USAGE_LIMITED_STREAK=0
        STALL_USAGE_LIMITED_LAST=0
        STALL_NTFY_SENT=0
        return 0
    fi

    # Gate 1: type-C (usage limit) takes priority over type-A. An agent
    # stalled by a usage limit has a frozen pane that looks identical to a
    # type-A stall — evaluating this first (relative to the ladder below)
    # is the whole point of §1.0.
    local usage_state
    usage_state=$(usage_limit_state "$AGENT_ID" 2>/dev/null) || usage_state="unknown"
    if [ "$usage_state" = "limited" ]; then
        echo "[$(date)] [STALL] $AGENT_ID: type_C usage_limited — no action taken" >&2
        # cmd_218: count at the same ~stall_retry_cooldown_sec cadence as the
        # ladder path below, not once per liveness_tick (would reach the
        # notify threshold in under two minutes otherwise).
        local ul_now ul_cooldown
        ul_now=$(date +%s)
        ul_cooldown=$(stall_policy_query stall_retry_cooldown_sec 2>/dev/null) || ul_cooldown=600
        if [ "${STALL_USAGE_LIMITED_LAST:-0}" -eq 0 ] || [ "$((ul_now - STALL_USAGE_LIMITED_LAST))" -ge "$ul_cooldown" ]; then
            STALL_USAGE_LIMITED_LAST=$ul_now
            STALL_USAGE_LIMITED_STREAK=$((${STALL_USAGE_LIMITED_STREAK:-0} + 1))
            stall_maybe_notify "$AGENT_ID" "usage_limited" "$STALL_USAGE_LIMITED_STREAK"
        fi
        return 0
    fi

    # Retry cooldown — don't re-trigger the ladder repeatedly on one stall.
    local now cooldown
    now=$(date +%s)
    cooldown=$(stall_policy_query stall_retry_cooldown_sec 2>/dev/null) || cooldown=600
    if [ "${STALL_ACTED_AT:-0}" -ne 0 ] && [ "$((now - STALL_ACTED_AT))" -lt "$cooldown" ]; then
        return 0
    fi

    # Recovery ceiling depends on how confidently we've ruled out type-C:
    #   usage_state=unknown -> unknown_policy (default escape_only)
    #   usage_state=ok      -> recovery_level (default escape_only)
    local policy
    if [ "$usage_state" = "unknown" ]; then
        policy=$(stall_policy_query unknown_policy 2>/dev/null) || policy="escape_only"
    else
        policy=$(stall_policy_query recovery_level 2>/dev/null) || policy="escape_only"
    fi

    if [ "$policy" = "none" ]; then
        echo "[$(date)] [STALL] $AGENT_ID: stall detected (usage=$usage_state) but policy=none — no action" >&2
        return 0
    fi

    STALL_ACTED_AT=$now
    STALL_UNRESPONSIVE_ATTEMPTS=$((${STALL_UNRESPONSIVE_ATTEMPTS:-0} + 1))

    # STALL_AWAITING_INPUT_GATE (cmd_219): 「入力待ちと名指しできる時だけ
    # 撃つ」。CLAUDE.md「待機の上限」（正当な待機は1800秒まで可）と
    # stall_after_sec（900秒動かねば固着）は同じ「時間」の軸に乗って
    # おり数字をどう動かしても衝突が残る——ここで軸を分ける。検知
    # （is_stalled_pane、上の呼び出し）は一切変えぬ。鍵を撃つか否かだけを
    # 「その画面が何であるか」で決める（待機時間は一切見ない）。
    # queue/reports/gunshi_design_219_stall_wait_budget_conflict.yaml §2 参照。
    local awaiting_input=false kind="unresponsive"
    if pane_awaiting_input "$PANE_TARGET"; then
        awaiting_input=true
    else
        kind="unresponsive_nonmodal"
    fi

    # 通知は名指しできる/できぬに関わらず必ず届ける（cmd_218が塞いだ
    # 「鳴らぬ番犬」の穴を、門の設置で再び開けぬため——通知は門の手前で
    # 呼ぶ）。
    stall_maybe_notify "$AGENT_ID" "$kind" "$STALL_UNRESPONSIVE_ATTEMPTS"

    local hash_frozen_sec=$((now - STALL_HASH_SINCE))
    if [ "$awaiting_input" != "true" ]; then
        local nonmodal_level
        nonmodal_level=$(stall_policy_query nonmodal_recovery_level 2>/dev/null) || nonmodal_level="none"
        if [ "$nonmodal_level" = "none" ]; then
            echo "[$(date)] [STALL] $AGENT_ID: awaiting_input=false hash_frozen_sec=$hash_frozen_sec — 鍵は撃たぬ (usage=$usage_state, policy=$policy)" >&2
            return 0        # STALL_ACTION_TAKEN は立てぬ — inbox_watcher.sh 配送1tick契約を壊すため
        fi
    fi

    STALL_ACTION_TAKEN=1
    echo "[$(date)] [STALL] $AGENT_ID: type-A stall detected (usage=$usage_state, policy=$policy, awaiting_input=$awaiting_input, hash_frozen_sec=$hash_frozen_sec) — Escape x2" >&2
    timeout 5 tmux send-keys -t "$PANE_TARGET" Escape Escape 2>/dev/null || true

    if [ "$policy" = "escape_only" ]; then
        return 0
    fi

    sleep 30
    if ! is_stalled_pane; then
        echo "[$(date)] [STALL] $AGENT_ID: pane moved after Escape — aborting ladder" >&2
        return 0
    fi
    # STALL_AWAITING_INPUT_GATE 再検査（設計§2(c)後段）: モーダルが剥がれた
    # 後に非モーダルで固まった画面へ、後段（nudge）が鍵を撃つのを防ぐ。
    if ! pane_awaiting_input "$PANE_TARGET" && [ "$(stall_policy_query nonmodal_recovery_level 2>/dev/null || echo none)" = "none" ]; then
        echo "[$(date)] [STALL] $AGENT_ID: awaiting_input=false after Escape — aborting ladder (non-modal freeze)" >&2
        return 0
    fi

    echo "[$(date)] [STALL] $AGENT_ID: still stalled after Escape — nudge" >&2

    # Modal gate (cmd_216 F-3 ii → cmd_219 STALL_AWAITING_INPUT_GATE; cmd_229
    # AC-4 R6): this route sends "inbox?" + Enter directly via tmux
    # send-keys, bypassing send_wakeup entirely — so PR#97's 5-route gate
    # table never covered it (gunshi QC finding, the 6th route). Enter into
    # an open modal confirms/selects an option exactly as it would via
    # send_wakeup (see T-MODAL-GATE-01) — gate it the same way, before
    # sending anything. claude type uses the strict three-value gate;
    # non-claude keeps the legacy pane_awaiting_input() binary gate (it
    # covers the permission-confirm dialog footer that pane_has_open_modal()
    # misses).
    local stall_gate_cli
    stall_gate_cli=$(get_effective_cli_type)
    if ! claude_pane_may_enter "$PANE_TARGET" "$stall_gate_cli" pane_awaiting_input; then
        echo "[$(date)] [SKIP-MODAL] $AGENT_ID: modal open — suppressing stall-ladder nudge" >&2
        return 0
    fi

    timeout 5 tmux send-keys -t "$PANE_TARGET" "inbox?" 2>/dev/null || true
    sleep 0.3
    # cmd_229 AC-5 TOCTOU: re-evaluate immediately before Enter — the text
    # send + 0.3s sleep above is exactly the kind of gap P2 (TOCTOU) names.
    if ! claude_pane_may_enter "$PANE_TARGET" "$stall_gate_cli" pane_awaiting_input; then
        echo "[$(date)] [SKIP-MODAL] $AGENT_ID: modal opened between text and Enter — aborting stall-ladder nudge (TOCTOU guard)" >&2
        return 0
    fi
    timeout 5 tmux send-keys -t "$PANE_TARGET" Enter 2>/dev/null || true

    sleep 30
    if ! is_stalled_pane; then
        echo "[$(date)] [STALL] $AGENT_ID: pane moved after nudge — aborting ladder" >&2
        return 0
    fi
    if ! pane_awaiting_input "$PANE_TARGET" && [ "$(stall_policy_query nonmodal_recovery_level 2>/dev/null || echo none)" = "none" ]; then
        echo "[$(date)] [STALL] $AGENT_ID: awaiting_input=false after nudge — aborting ladder (non-modal freeze)" >&2
        return 0
    fi

    # C1-6: command-layer agents never get /clear from the stall ladder either
    # (same protection as the existing Phase 3 escalation).
    if [ "$AGENT_ID" = "shogun" ] || [ "$AGENT_ID" = "karo" ] || [ "$AGENT_ID" = "gunshi" ]; then
        echo "[$(date)] [SKIP] $AGENT_ID: command-layer agent — suppressing /clear in stall ladder" >&2
        return 0
    fi

    echo "[$(date)] [STALL] $AGENT_ID: still stalled after nudge — /clear" >&2
    # force_busy=1: a detected stall is BY DEFINITION busy (is_stalled_pane
    # requires agent_is_busy() true), so send_cli_command's ordinary busy
    # guard must be bypassed here or /clear would never actually fire.
    send_cli_command "/clear" 1
    return 0
}

# ─── Liveness tick (cmd_218 案C) ───
# attempt_stall_recovery() used to be called from inside process_unread()'s
# unread==0 else-branch — reachable only when an inbox write actually fired
# an event (or the single tick right after unread drains to 0). Three gates
# stacked in front of that call site over cmd_171/cmd_209's lifetime — the
# oldest (2026-02-10 fast-path early-return) predates stall detection itself
# by five and a half months — so the watcher's only periodic clock (the 30s
# timeout tick) never reached it during steady-state idle
# (queue/reports/gunshi_design_209_stall_unread_deadlock.yaml §1).
#
# liveness_tick() is called directly from the main loop instead (after the
# testing guard, ahead of the rc branch that dispatches process_unread), so
# stall detection now runs on a wall-clock timer independent of unread state
# or trigger type — structurally immune to future process_unread edits.
# Defined outside the testing guard (like attempt_stall_recovery itself) so
# bats can call it directly without sourcing the (guarded) main loop.
LIVENESS_LAST_TS=${LIVENESS_LAST_TS:-0}
LIVENESS_MIN_INTERVAL=${LIVENESS_MIN_INTERVAL:-20}

liveness_tick() {
    local now
    now=$(date +%s)
    [ "$((now - LIVENESS_LAST_TS))" -ge "$LIVENESS_MIN_INTERVAL" ] || return 0
    LIVENESS_LAST_TS=$now
    attempt_stall_recovery
    return 0   # Never return 1 — set -euo pipefail would kill the watcher
}

# liveness_tick_and_defer: wraps liveness_tick() with the SE-2 one-tick-defer
# contract — if the ladder just sent recovery keys (STALL_ACTION_TAKEN=1),
# the caller (main loop) must skip this iteration's delivery dispatch
# (process_unread) rather than risk landing nudge+Enter on the same tick a
# stalled modal's Escape did (see gunshi_design_209 §2 why_defer_one_tick).
# Returns 1 when the caller should `continue`, 0 otherwise. Split out as its
# own function — rather than inlined in the (testing-guard-skipped) main
# loop — so bats can exercise the defer contract directly.
liveness_tick_and_defer() {
    liveness_tick
    if [ "${STALL_ACTION_TAKEN:-0}" = "1" ]; then
        STALL_ACTION_TAKEN=0
        echo "[$(date)] [STALL] $AGENT_ID: recovery keys sent — deferring delivery one tick" >&2
        return 1
    fi
    return 0
}

# ─── Process cycle ───
process_unread() {
    local trigger="${1:-event}"

    # summary-first: unread_count fast-path (Phase 2/3 optimization)
    # unread_count fast-path lets us skip expensive full reads when idle.
    local fast_info
    fast_info=$(get_unread_count_fast)
    local fast_count
    fast_count=$(echo "$fast_info" | "$SCRIPT_DIR/.venv/bin/python3" -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null)

    if no_idle_full_read "$trigger" && [ "$fast_count" -eq 0 ] 2>/dev/null; then
        # no_idle_full_read guard: unread=0 and timeout path → no full inbox read.
        # (Historical note: this branch used to also carry an unreachable
        # "escalation reset (fast-path)" log guarded by FIRST_UNREAD_SEEN != 0
        # — dead code, since no_idle_full_read() itself requires
        # FIRST_UNREAD_SEEN == 0 to enter this branch. Removed cmd_218; see
        # gunshi_design_209_stall_unread_deadlock.yaml finding_1_4_corroboration.)
        FIRST_UNREAD_SEEN=0
        reset_shogun_defer_state  # QC40-F1/F2: 未読0になったので延期状態を解除
        NEW_CONTEXT_SENT=0
        reset_nudge_throttle
        # Ensure idle flag exists (fast-path recovery).
        # cmd_217: for claude, idle/busy is now read from the two-marker
        # mtime comparison (agent_turn_state) fed by hooks, not from this
        # flag's mere presence — so touching it here would no longer change
        # agent_is_busy()'s verdict, and pane-gating it (as cmd_209 did) was
        # only ever a mitigation for the presence-only design that design
        # replaces. Skip the touch entirely for claude; the idle印 is now
        # exclusively hook-owned (stop_hook_inbox.sh / watcher startup /
        # the 300s stale-busy net below). Non-claude CLIs still don't
        # consult this flag for busy detection, so their touch stays
        # unconditional (unchanged).
        local fastpath_idle_flag_cli
        fastpath_idle_flag_cli=$(get_effective_cli_type)
        if [ "$fastpath_idle_flag_cli" != "claude" ]; then
            touch "${IDLE_FLAG_DIR:-/tmp}/shogun_idle_${AGENT_ID}" 2>/dev/null || true
        fi
        if ! agent_is_busy; then
            # Shogun: only clear input when pane is not active (Lord is away)
            if [ "$AGENT_ID" = "shogun" ] && pane_is_active; then
                : # Lord may be typing — skip C-u
            # cmd_229 AC-8: this C-u had no gate at all before this fix. If a
            # modal with a free-text option is open (e.g. the accident's
            # "3. Type something." choice), this C-u would erase whatever
            # the Lord had started typing into it. Same judgment as the
            # Enter routes — claude strict gate, non-claude legacy binary.
            elif ! claude_pane_may_enter "$PANE_TARGET" "$fastpath_idle_flag_cli" pane_has_open_modal; then
                echo "[$(date)] [SKIP-MODAL] $AGENT_ID: modal open — suppressing fast-path C-u" >&2
            else
                timeout 2 tmux send-keys -t "$PANE_TARGET" C-u 2>/dev/null || true
            fi
        fi
        return 0
    fi

    local info
    info=$(get_unread_info)

    local read_bytes=0
    if [ -f "$INBOX" ]; then
        read_bytes=$(wc -c < "$INBOX" 2>/dev/null || echo 0)
    fi
    update_metrics "${read_bytes:-0}"

    # Handle special CLI commands first (/clear, /model)
    local specials
    specials=$(echo "$info" | "$SCRIPT_DIR/.venv/bin/python3" -c "
import sys, json
data = json.load(sys.stdin)
for s in data.get('specials', []):
    t = s.get('type', '')
    c = (s.get('content', '') or '').replace('\t', ' ').replace('\n', ' ').strip()
    i = s.get('id', '') or ''
    print(f'{t}\t{i}\t{c}')
" 2>/dev/null)

    local clear_seen=0
    local clear_sent=0  # tracks if /clear was actually sent (not just seen)
    local special_deferred=0  # cmd_220 F-D: a clear_command was seen but busy-deferred
    if [ -n "$specials" ]; then
        local msg_type msg_id msg_content cmd
        while IFS=$'\t' read -r msg_type msg_id msg_content; do
            [ -n "$msg_type" ] || continue
            if [ "$msg_type" = "clear_command" ]; then
                clear_seen=1
                # Busy guard: skip /clear if agent is currently processing.
                # Sending /clear during active work destroys in-progress context.
                # cmd_220 F-A/F-D: do NOT mark this message read on this path —
                # it must still be unread on the next cycle, or "deferred to
                # next cycle" is a lie (gunshi RCA L2). F-D: arm
                # FIRST_UNREAD_SEEN here too, so a busy episode made of pure
                # specials (normal_count stays 0) can still reach the 300s
                # stale-busy safety net below instead of being invisible to it
                # (RCA L4 — the net used to live entirely inside the
                # normal_count>0 branch).
                if agent_is_busy && [[ "$AGENT_ID" != "shogun" ]]; then
                    echo "[$(date)] [SKIP] Agent $AGENT_ID is busy — /clear (clear_command) deferred to next cycle" >&2
                    if [ "${FIRST_UNREAD_SEEN:-0}" -eq 0 ]; then
                        FIRST_UNREAD_SEEN=$(date +%s)
                    fi
                    special_deferred=1
                    continue
                fi
            fi
            cmd=$(normalize_special_command "$msg_type" "$msg_content")
            if [ -n "$cmd" ]; then
                if send_cli_command "$cmd"; then
                    # cmd_220: send_cli_command now returns 0 (not 1) for the
                    # shogun-suppression case too (see its comment), so guard
                    # AGENT_ID here explicitly — otherwise a shogun-directed
                    # clear_command that was actually suppressed would still
                    # set clear_sent=1 and wrongly trigger the auto-recovery
                    # task_assigned injection below (T-SHOGUN-005).
                    # cmd_220 subtask2 QC-1: also guard on SEND_DEFERRED — a
                    # modal/busy-suppressed send must not be counted as sent.
                    if [ "$msg_type" = "clear_command" ] && [ "$AGENT_ID" != "shogun" ] && [ "${SEND_DEFERRED:-0}" -eq 0 ]; then
                        clear_sent=1
                    fi
                fi
                # cmd_220 F-A / subtask2 QC-1/QC-3: mark read once handed to
                # send_cli_command UNLESS it reports a transient suppression
                # (SEND_DEFERRED=1 — modal open, or the inner busy-guard race
                # window). NOT every return path here is a final disposition:
                # the modal gate (:703) and inner busy guard (:742) are both
                # "try again later", same as the busy-guard `continue` above.
                # Treat a deferred special exactly like that continue path —
                # leave it unread and arm the F-D stale-busy safety net.
                if [ "${SEND_DEFERRED:-0}" -eq 0 ]; then
                    mark_special_read "$msg_id"
                else
                    special_deferred=1
                    if [ "${FIRST_UNREAD_SEEN:-0}" -eq 0 ]; then
                        FIRST_UNREAD_SEEN=$(date +%s)
                    fi
                fi
            else
                # normalize_special_command rejected the payload (e.g.
                # malformed model_switch) — it can't become valid by
                # retrying, so mark it read instead of re-logging the same
                # [SKIP] every cycle forever.
                mark_special_read "$msg_id"
            fi
        done <<< "$specials"
    fi

    # /clear は Codex で /new へ変換される。再起動直後の取りこぼし防止として
    # 追加 task_assigned を自動投入し、次サイクルで確実に wake-up 可能にする。
    # 案B+待機: Karo がタスク YAML を cancelled に更新するまでの猶予を確保してから
    # status チェックを行い、cancelled/idle の場合はスキップする。
    # clear_sent（実際に送信）のみauto-recoveryを起動。busy時スキップは対象外。
    if [ "$clear_sent" -eq 1 ]; then
        # Wait for Karo to update task YAML status (cancellation race condition mitigation).
        # send_cli_command already slept 3s for /clear; add 5s more = ~8s total before check.
        sleep 5
        local recovery_id
        recovery_id=$(enqueue_recovery_task_assigned)
        if [[ "$recovery_id" == SKIP_CANCELLED:* ]]; then
            echo "[$(date)] [AUTO-RECOVERY] skipped for $AGENT_ID — task is ${recovery_id#SKIP_CANCELLED:} (not restarting)" >&2
        elif [ -n "$recovery_id" ] && [ "$recovery_id" != "SKIP_DUPLICATE" ] && [ "$recovery_id" != "ERROR" ]; then
            echo "[$(date)] [AUTO-RECOVERY] queued task_assigned for $AGENT_ID ($recovery_id)" >&2
        fi
        info=$(get_unread_info)
    fi

    # Send wake-up nudge for normal messages (with escalation)
    local normal_count
    normal_count=$(echo "$info" | "$SCRIPT_DIR/.venv/bin/python3" -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null)

    # Check if unread messages include task_assigned (for context reset)
    local has_task_assigned
    has_task_assigned=$(echo "$info" | "$SCRIPT_DIR/.venv/bin/python3" -c "import sys,json; print(1 if json.load(sys.stdin).get('has_task_assigned') else 0)" 2>/dev/null)

    if [ "$normal_count" -gt 0 ] 2>/dev/null; then
        local now
        now=$(date +%s)

        # When the agent is busy/thinking, do NOT escalate. Interrupting with Escape or /clear
        # can terminate the current thought. Also pause the escalation timer while busy so we
        # don't immediately jump to Phase 2/3 once it becomes idle.
        # Exception: shogun — ntfy must be delivered immediately.
        # Safety net: if busy detection persists for >5 min, assume false-busy (stale flag)
        # and force-create idle flag to allow nudge delivery.
        if agent_is_busy && [[ "$AGENT_ID" != "shogun" ]]; then
            local busy_cli
            busy_cli=$(get_effective_cli_type)
            # Stale busy safety net: if agent has been "busy" for >5 minutes with
            # unread messages, force-create idle flag. This recovers from false-busy
            # deadlock where stop_hook failed to create the flag.
            local stale_busy_limit=300  # 5 minutes
            # cmd_217 D-3: この閾値の名は FIRST_UNREAD_SEEN のままだが、
            # このbusy分岐に限っては「未読が現れてからbusyで居続けた齢」
            # ≒busy印の齢の近似として使っている（未読=まさに今取り組んで
            # いるタスクそのものであり得るため——N-3の実例参照）。
            local busy_flag_age_sec=$((now - FIRST_UNREAD_SEEN))
            local force_idle=0
            if [ "${FIRST_UNREAD_SEEN:-0}" -gt 0 ] && [ "$busy_flag_age_sec" -ge "$stale_busy_limit" ]; then
                # cmd_217 D-1 STALE_BUSY_REQUIRES_FROZEN_PANE: age だけでは
                # 「本物の仕事（busyかつ画面が動いている）」と「本物の固着
                # （busyかつ画面が動いていない）」を区別できない（N-3:
                # 300秒安全網がレビュー中の軍師自身へ誤発火した実例）。
                # is_stalled_pane()と同じ機構（pane_hash_frozen_sec）で
                # 画面停止も併せて要求する。閾値はstall_after_secと
                # 混ぜず、この安全網自身のstale_busy_limitを使う。
                local hash_frozen_sec hash_capture_rc
                pane_hash_frozen_sec STALE_BUSY_HASH STALE_BUSY_HASH_SINCE
                hash_capture_rc=$?
                hash_frozen_sec="$PANE_HASH_FROZEN_SEC"
                if [ "$hash_capture_rc" -eq 0 ] && [ "$hash_frozen_sec" -ge "$stale_busy_limit" ]; then
                    force_idle=1
                fi
                # else: 画面が動いている、または capture 不能（判定不能を
                # 固着と断じない、T-D4）→ force_idle=0 のまま下のelseへ。
            fi

            if [ "$force_idle" -eq 1 ]; then
                # cmd_217 AC3/§3: this is the SOLE upper bound on permanent-busy
                # under the two-marker design (Stop hook不発 is the only failure
                # mode that can produce it). Wording + one-shot ntfy make the
                # hook-unarmed suspicion visible instead of silently recovering.
                if [[ "$busy_cli" == "claude" ]]; then
                    echo "[$(date)] WARNING: $AGENT_ID busy for ${busy_flag_age_sec}s with $normal_count unread AND pane frozen for ${hash_frozen_sec}s — forcing idle flag (stale busy recovery; hook不発の疑い)" >&2
                    if [ "${STALE_BUSY_NTFY_SENT:-0}" -eq 0 ]; then
                        type branch_policy_notify &>/dev/null && branch_policy_notify "${AGENT_ID}: ${stale_busy_limit}秒busy継続+画面停止のため強制idle化(hook不発の疑い)" 2>/dev/null || true
                        STALE_BUSY_NTFY_SENT=1
                    fi
                else
                    echo "[$(date)] WARNING: $AGENT_ID busy for ${busy_flag_age_sec}s with $normal_count unread AND pane frozen for ${hash_frozen_sec}s — forcing idle flag (stale busy recovery)" >&2
                fi
                touch "${IDLE_FLAG_DIR:-/tmp}/shogun_idle_${AGENT_ID}"
                # Fall through to normal nudge/escalation below
            else
                if [[ "$busy_cli" == "claude" ]]; then
                    # Claude Code: Stop hook will catch unread messages when the agent's
                    # turn ends. No nudge needed at all — just log and skip completely.
                    # Set FIRST_UNREAD_SEEN so the stale-busy safety net (above) can
                    # activate if the stop hook never fires.
                    if [ "${FIRST_UNREAD_SEEN:-0}" -eq 0 ]; then
                        FIRST_UNREAD_SEEN=$now
                    fi
                    echo "[$(date)] $normal_count unread for $AGENT_ID but agent is busy (claude) — Stop hook will deliver" >&2
                else
                    # Codex/Copilot/Kimi/OpenCode: No Stop hook. Pause escalation timer while busy.
                    FIRST_UNREAD_SEEN=$now
                    echo "[$(date)] $normal_count unread for $AGENT_ID but agent is busy ($busy_cli) — pausing escalation timer" >&2
                fi
                return 0
            fi
        fi

        # ─── Context reset before new task ───
        # Send /new or /clear once when task_assigned is first detected,
        # to clear stale context from the previous task.
        # Skip if: (1) already sent this batch, (2) clear_command already handled above,
        #          (3) agent is shogun (human-controlled).
        if [ "$has_task_assigned" = "1" ] && [ "$NEW_CONTEXT_SENT" -eq 0 ] && [ "$clear_seen" -eq 0 ]; then
            # cmd_217: send_context_reset now returns 1 when it defers
            # (busy/modal) instead of always 0 — only mark NEW_CONTEXT_SENT
            # on an actual send, so a busy agent gets retried next cycle
            # instead of the reset being silently skipped forever.
            if send_context_reset; then
                NEW_CONTEXT_SENT=1
            fi
        fi

        # If startup prompt was just sent (Codex), skip follow-up nudge this cycle.
        # The prompt itself contains full recovery instructions (identify + read YAML + work).
        if [ "$STARTUP_PROMPT_SENT" -eq 1 ]; then
            STARTUP_PROMPT_SENT=0
            echo "[$(date)] [SKIP] Startup prompt just sent to $AGENT_ID — skipping nudge this cycle" >&2
            FIRST_UNREAD_SEEN=$now
            return 0
        fi

        # Track when we first saw unread messages
        if [ "$FIRST_UNREAD_SEEN" -eq 0 ]; then
            FIRST_UNREAD_SEEN=$now
        fi

        if [ "${ASW_DISABLE_ESCALATION:-0}" = "1" ]; then
            echo "[$(date)] $normal_count unread for $AGENT_ID (escalation disabled)" >&2
            if disable_normal_nudge; then
                echo "[$(date)] [SKIP] disable_normal_nudge=1, no normal nudge for $AGENT_ID" >&2
            else
                send_wakeup "$normal_count"
            fi
            return 0
        fi

        local age=$((now - FIRST_UNREAD_SEEN))

        if [ "$age" -lt "$ESCALATE_PHASE1" ]; then
            # Phase 1 (0-2 min): Standard nudge
            echo "[$(date)] $normal_count unread for $AGENT_ID (${age}s)" >&2
            if disable_normal_nudge; then
                echo "[$(date)] [SKIP] disable_normal_nudge=1, deferring to escalation-only path" >&2
            else
                send_wakeup "$normal_count"
            fi
        elif [ "$age" -lt "$ESCALATE_PHASE2" ]; then
            # Phase 2 (2-4 min): Escape + nudge
            echo "[$(date)] $normal_count unread for $AGENT_ID (${age}s — escalating: Escape+nudge)" >&2
            send_wakeup_with_escape "$normal_count"
        else
            # Phase 3 (4+ min): /clear (throttled to once per 5 min)
            if [ "$LAST_CLEAR_TS" -lt "$((now - ESCALATE_COOLDOWN))" ]; then
                local effective_cli
                effective_cli=$(get_effective_cli_type)
                if [[ "$effective_cli" == "codex" ]]; then
                    # Codex /clear -> /new は会話を切ってしまうため、安全側に倒す。
                    echo "[$(date)] ESCALATION Phase 3: $AGENT_ID unresponsive for ${age}s, but cli=codex — skipping /clear." >&2
                    FIRST_UNREAD_SEEN=$now  # Reset timer (no destructive action)
                    send_wakeup "$normal_count"
                elif [ "$AGENT_ID" = "shogun" ] || [ "$AGENT_ID" = "karo" ] || [ "$AGENT_ID" = "gunshi" ]; then
                    # Command-layer agents (karo/gunshi/shogun): suppress /clear even in Phase 3
                    echo "[$(date)] [SKIP] ESCALATION Phase 3: $AGENT_ID suppressed (command-layer agent, ${age}s). Using Escape+nudge." >&2
                    FIRST_UNREAD_SEEN=$now  # Reset timer
                    send_wakeup_with_escape "$normal_count"
                else
                    echo "[$(date)] ESCALATION Phase 3: Agent $AGENT_ID unresponsive for ${age}s. Sending /clear." >&2
                    send_cli_command "/clear"
                    LAST_CLEAR_TS=$now
                    FIRST_UNREAD_SEEN=0  # Reset — will re-detect on next cycle
                    NEW_CONTEXT_SENT=0
                fi
            else
                # Cooldown active — fall back to Escape+nudge
                echo "[$(date)] $normal_count unread for $AGENT_ID (${age}s — /clear cooldown, using Escape+nudge)" >&2
                send_wakeup_with_escape "$normal_count"
            fi
        fi
    elif [ "${special_deferred:-0}" -eq 1 ]; then
        # cmd_220 F-D: normal_count is 0 (a deferred clear_command doesn't
        # count as a normal message), so the branch above — and the 300s
        # stale-busy safety net inside it — is unreachable for pure-special
        # traffic (gunshi RCA gunshi_rca_ashigaru1_baton_drop_fix2, L4: the
        # net and its ntfy lived entirely inside normal_count>0). Mirror just
        # the net here, gated on FIRST_UNREAD_SEEN (armed above at the defer
        # point) instead of normal_count, so a deferred special is not
        # stranded behind a permanently-busy agent forever. Deliberately do
        # NOT fall into the normal-message nudge/escalation ladder below —
        # there is no normal message to nudge about, and do NOT reset
        # FIRST_UNREAD_SEEN here — the message is still genuinely unread.
        if agent_is_busy && [[ "$AGENT_ID" != "shogun" ]]; then
            local special_now
            special_now=$(date +%s)
            local stale_busy_limit=300  # 5 minutes — same bound as the normal-message net above
            local special_busy_flag_age_sec=$((special_now - FIRST_UNREAD_SEEN))
            if [ "${FIRST_UNREAD_SEEN:-0}" -gt 0 ] && [ "$special_busy_flag_age_sec" -ge "$stale_busy_limit" ]; then
                # cmd_217 D-1 STALE_BUSY_REQUIRES_FROZEN_PANE: same hash-frozen
                # AND as the normal-message net above — age alone is not the
                # signature of a genuine stall (N-3). Shares STALE_BUSY_HASH/
                # STALE_BUSY_HASH_SINCE with that site (same continuous
                # freeze-tracking across cycles; the two branches are
                # mutually exclusive per invocation).
                local hash_frozen_sec hash_capture_rc
                pane_hash_frozen_sec STALE_BUSY_HASH STALE_BUSY_HASH_SINCE
                hash_capture_rc=$?
                hash_frozen_sec="$PANE_HASH_FROZEN_SEC"
                if [ "$hash_capture_rc" -eq 0 ] && [ "$hash_frozen_sec" -ge "$stale_busy_limit" ]; then
                    local special_busy_cli
                    special_busy_cli=$(get_effective_cli_type)
                    if [[ "$special_busy_cli" == "claude" ]]; then
                        echo "[$(date)] WARNING: $AGENT_ID busy for ${special_busy_flag_age_sec}s with a deferred special pending AND pane frozen for ${hash_frozen_sec}s — forcing idle flag (stale busy recovery; hook不発の疑い)" >&2
                        if [ "${STALE_BUSY_NTFY_SENT:-0}" -eq 0 ]; then
                            type branch_policy_notify &>/dev/null && branch_policy_notify "${AGENT_ID}: ${stale_busy_limit}秒busy継続+画面停止のため強制idle化(hook不発の疑い、延期中特殊型あり)" 2>/dev/null || true
                            STALE_BUSY_NTFY_SENT=1
                        fi
                    else
                        echo "[$(date)] WARNING: $AGENT_ID busy for ${special_busy_flag_age_sec}s with a deferred special pending AND pane frozen for ${hash_frozen_sec}s — forcing idle flag (stale busy recovery)" >&2
                    fi
                    touch "${IDLE_FLAG_DIR:-/tmp}/shogun_idle_${AGENT_ID}"
                fi
                # else: screen still moving, or capture indeterminate — do
                # not force idle (T-D4).
            fi
        fi
        return 0
    else
        # No unread messages — reset escalation tracker
        if [ "$FIRST_UNREAD_SEEN" -ne 0 ]; then
            echo "[$(date)] All messages read for $AGENT_ID — escalation reset" >&2
        fi
        FIRST_UNREAD_SEEN=0
        NEW_CONTEXT_SENT=0
        reset_nudge_throttle
        reset_shogun_defer_state  # QC40-F1/F2: 未読0になったので延期状態を解除

        # ─── Stall detection (cmd_171 / T1) ───
        # cmd_218: attempt_stall_recovery() moved out of process_unread()
        # entirely — it now runs from liveness_tick() in the main loop,
        # ahead of process_unread() each iteration, independent of unread
        # state. See gunshi_design_209_stall_unread_deadlock.yaml §2 (案C).

        # Ensure idle flag exists when all messages are read.
        # cmd_217: claude no longer touches idle印 here at all — this
        # pane-gated touch (cmd_171/C1-4, cmd_209 gate) was the ONE thing
        # that could manufacture a permanent false-idle under the old
        # presence-only design (§1-2/§3, gunshi_design_217): the mtime
        # comparison it fed never mattered because agent_is_busy() only
        # checked existence. Under the two-marker design idle印 is written
        # exclusively by hooks (stop_hook_inbox.sh normal exit, watcher
        # startup) and the 300s stale-busy net below — removing this touch
        # is what closes off the "恒久idleを作り得るのは門付きtouchだけ"
        # finding. Non-claude CLIs never consult this flag for busy
        # detection, so their touch stays unconditional (existing
        # stop_hook-flag-loss recovery is unchanged for them).
        local idle_flag_cli
        idle_flag_cli=$(get_effective_cli_type)
        if [ "$idle_flag_cli" != "claude" ]; then
            touch "${IDLE_FLAG_DIR:-/tmp}/shogun_idle_${AGENT_ID}" 2>/dev/null || true
        fi
        # Clear stale nudge text from input field (Codex CLI prefills last input on idle).
        # Only send C-u when agent is idle — during Working it would be disruptive.
        if ! agent_is_busy; then
            # Shogun: only clear input when pane is not active (Lord is away)
            if [ "$AGENT_ID" = "shogun" ] && pane_is_active; then
                : # Lord may be typing — skip C-u
            # cmd_229 AC-8: same ungated-C-u fix as the fast-path branch above.
            elif ! claude_pane_may_enter "$PANE_TARGET" "$idle_flag_cli" pane_has_open_modal; then
                echo "[$(date)] [SKIP-MODAL] $AGENT_ID: modal open — suppressing all-read C-u" >&2
            else
                timeout 2 tmux send-keys -t "$PANE_TARGET" C-u 2>/dev/null || true
            fi
        fi
    fi
}

process_unread_once() {
    process_unread "startup"
}

# ─── Startup & Main loop (skipped in testing mode) ───
if [ "${__INBOX_WATCHER_TESTING__:-}" != "1" ]; then

# ─── Startup: process any existing unread messages ───
process_unread_once

# ─── Main loop: event-driven via inotifywait ───
# Timeout 30s: WSL2 /mnt/c/ can miss inotify events.
# Shorter timeout = faster escalation retry for stuck agents.
INOTIFY_TIMEOUT="${INOTIFY_TIMEOUT:-30}"

while true; do
    # Block until file is modified OR timeout
    # Backend-specific file watching: inotifywait (Linux) or fswatch (macOS)
    set +e
    if [ "${WATCH_BACKEND:-inotifywait}" = "fswatch" ]; then
        # macOS: fswatch -1 exits after one event. Use timeout for safety net.
        # gtimeout (from coreutils) or perl fallback for macOS timeout
        if command -v gtimeout &>/dev/null; then
            gtimeout "$INOTIFY_TIMEOUT" fswatch -1 --event Updated --event Renamed "$INBOX" 2>/dev/null
            rc=$?
            # gtimeout returns 124 on timeout
            if [ "$rc" -eq 124 ]; then rc=2; else rc=0; fi
        else
            # Fallback: use background fswatch + sleep timeout
            fswatch -1 --event Updated --event Renamed "$INBOX" &>/dev/null &
            FSWATCH_PID=$!
            WAITED=0
            while [ "$WAITED" -lt "$INOTIFY_TIMEOUT" ] && kill -0 "$FSWATCH_PID" 2>/dev/null; do
                sleep 2
                WAITED=$((WAITED + 1))
            done
            if kill -0 "$FSWATCH_PID" 2>/dev/null; then
                kill "$FSWATCH_PID" 2>/dev/null
                wait "$FSWATCH_PID" 2>/dev/null
                rc=2  # timeout
            else
                wait "$FSWATCH_PID" 2>/dev/null
                rc=0  # event
            fi
        fi
    else
        # Linux: inotifywait (original behavior)
        inotifywait -q -t "$INOTIFY_TIMEOUT" -e modify -e close_write "$INBOX" 2>/dev/null
        rc=$?
    fi
    set -e

    # rc=0: event fired (instant delivery)
    # rc=1: watch invalidated — Claude Code uses atomic write (tmp+rename),
    #        which replaces the inode. inotifywait sees DELETE_SELF → rc=1.
    #        File still exists with new inode. Treat as event, re-watch next loop.
    # rc=2: timeout (30s safety net for WSL2 inotify gaps / macOS fswatch timeout)
    # All cases: check for unread, then loop back (re-watches new inode)
    sleep 0.3

    # cmd_218: liveness_tick runs on its own wall-clock timer, ahead of and
    # independent of the unread-driven dispatch below — see liveness_tick's
    # and liveness_tick_and_defer's definitions for why.
    if ! liveness_tick_and_defer; then
        continue
    fi

    if [ "$rc" -eq 2 ]; then
        if should_process_timeout_tick; then
            process_unread "timeout"
        fi
    else
        process_unread "event"
    fi
done

fi  # end testing guard

# Source shared agent status library outside the testing guard so that
# agent_is_busy_check() is available in test mode too.
# In normal mode it was already sourced above; double-sourcing is harmless.
_agent_status_lib="${SCRIPT_DIR}/lib/agent_status.sh"
if [ -f "$_agent_status_lib" ] && ! type agent_is_busy_check &>/dev/null; then
    source "$_agent_status_lib"
fi

# Same double-source guard for stall_policy_query() (cmd_171), so it is
# available in test mode too.
_stall_policy_lib="${SCRIPT_DIR}/lib/stall_policy.sh"
if [ -f "$_stall_policy_lib" ] && ! type stall_policy_query &>/dev/null; then
    source "$_stall_policy_lib"
fi

# Same double-source guard for branch_policy_notify() (cmd_182), so it is
# available in test mode too.
_branch_policy_lib="${SCRIPT_DIR}/lib/branch_policy.sh"
if [ -f "$_branch_policy_lib" ] && ! type branch_policy_notify &>/dev/null; then
    source "$_branch_policy_lib"
fi
