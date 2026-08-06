#!/usr/bin/env bash
# Shared helpers for stall_policy / baton_watchdog config (cmd_171).
#
# NOTE: config/settings.yaml is git-ignored (instance-local config; see
# .gitignore). Every query below MUST return a safe default when the
# section — or the file itself — is absent, so behavior never regresses
# to "exit 1" on a fresh checkout (cmd_163 BL-3 lesson).

STALL_POLICY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STALL_POLICY_SETTINGS="${STALL_POLICY_SETTINGS:-$STALL_POLICY_ROOT/config/settings.yaml}"

stall_policy_python() {
    if [[ -x "$STALL_POLICY_ROOT/.venv/bin/python3" ]]; then
        printf '%s\n' "$STALL_POLICY_ROOT/.venv/bin/python3"
    else
        command -v python3
    fi
}

stall_policy_query() {
    local query="$1"
    local python_bin
    python_bin="$(stall_policy_python)"

    "$python_bin" - "$STALL_POLICY_SETTINGS" "$query" <<'PY'
import sys

try:
    import yaml
except Exception as exc:
    raise SystemExit(f"PyYAML is required to read stall_policy: {exc}")

settings_path, query = sys.argv[1], sys.argv[2]

# Safe defaults (cmd_171 §2.2). stall_policy.enabled is False so automated
# recovery stays opt-in until explicitly enabled (lord's authorization).
DEFAULT_STALL_POLICY = {
    "enabled": False,
    "stall_after_sec": 480,
    "hash_sample_interval_sec": 30,
    "stall_retry_cooldown_sec": 600,
    "recovery_level": "escape_only",
    "unknown_policy": "escape_only",
    "usage_limit_threshold_pct": 95,
    "usage_cache_ttl_sec": 120,
    "usage_limit_pane_patterns": [
        "usage limit",
        "rate limit",
        "limit reached",
        "resets at",
    ],
}

try:
    with open(settings_path, "r", encoding="utf-8") as fh:
        settings = yaml.safe_load(fh) or {}
except FileNotFoundError:
    settings = {}

policy = settings.get("stall_policy")
if not isinstance(policy, dict):
    policy = {}

def policy_get(key):
    value = policy.get(key)
    if value is None:
        return DEFAULT_STALL_POLICY[key]
    return value

if query == "enabled":
    print("true" if policy_get("enabled") is True else "false")
elif query in (
    "stall_after_sec",
    "hash_sample_interval_sec",
    "stall_retry_cooldown_sec",
    "usage_limit_threshold_pct",
    "usage_cache_ttl_sec",
):
    print(int(policy_get(query)))
elif query in ("recovery_level", "unknown_policy"):
    print(str(policy_get(query)))
elif query == "usage_limit_pane_patterns":
    patterns = policy_get("usage_limit_pane_patterns")
    if not isinstance(patterns, list) or not patterns:
        patterns = DEFAULT_STALL_POLICY["usage_limit_pane_patterns"]
    print("\n".join(str(p) for p in patterns))
else:
    raise SystemExit(f"unknown stall_policy query: {query}")
PY
}

baton_watchdog_query() {
    local query="$1"
    local python_bin
    python_bin="$(stall_policy_python)"

    "$python_bin" - "$STALL_POLICY_SETTINGS" "$query" <<'PY'
import sys

try:
    import yaml
except Exception as exc:
    raise SystemExit(f"PyYAML is required to read baton_watchdog: {exc}")

settings_path, query = sys.argv[1], sys.argv[2]

# Safe defaults (cmd_171 §2.2). enabled defaults to True: baton_watchdog is
# notify-only (no key injection), so it carries no destructive side effect.
#
# periodic_clear_* (cmd_172/P7) is a distinct, opt-in feature layered on top
# of the same watchdog process: unlike B-1/B-2/B-3 notification, it actually
# triggers a /clear via clear_command, so it defaults to disabled even though
# baton_watchdog itself defaults to enabled (lord's dual-safety-valve policy).
DEFAULT_BATON_WATCHDOG = {
    "enabled": True,
    "baton_lost_after_sec": 900,
    "baton_ntfy_after_sec": 1800,
    "baton_d1_ntfy_after_sec": 900,
    "progress_stall_after_sec": 5400,
    "baton_b4b_ntfy_after_sec": 900,
    "baton_b4c_stale_after_sec": 5400,
    "poll_interval_sec": 60,
    "periodic_clear_enabled": False,
    "periodic_clear_idle_sec": 1800,
    "periodic_clear_agents": ["karo", "gunshi"],
    # cmd_189: B-4c(check_b4c_once)専用。list_stale_inbox_agentsの
    # 呼び出し側が対象を名指しする形で使う設定であり、D-1(check_d1_once)
    # には一切効かない(D-1は無引数呼び出しのまま)。
    "baton_b4c_machine_exempt_agents": ["shogun"],
    "baton_b4c_machine_stale_after_sec": 86400,
    # cmd_197: cmd側の任意フィールド `awaiting: lord` による除外(check_once)
    # 専用の長い安全網。除外は「発報を止める」のではなく「急かす間隔を
    # 延ばす」だけであることの実体——印が付いたまま丸1日超放置されたら
    # 印の正誤にかかわらず必ず発火する。
    # 【cmd_208/措置B是正】既定を86400→3600へ。実測失敗尺（cmd_203/cmd_204
    # の人待ち印が実は機械の手番だったまま12時間09分すり抜けた件）が
    # 24時間の網より小さく、従来の既定ではこの型の失敗を原理的に
    # 捕まえられなかった（gunshi_design_208.yaml G-2）。
    "baton_lost_human_held_after_sec": 3600,
    "usage_warn_pct": 80,
    "usage_resume_below_pct": 50,
    "usage_check_interval_sec": 300,
}

try:
    with open(settings_path, "r", encoding="utf-8") as fh:
        settings = yaml.safe_load(fh) or {}
except FileNotFoundError:
    settings = {}

policy = settings.get("baton_watchdog")
if not isinstance(policy, dict):
    policy = {}

def policy_get(key):
    value = policy.get(key)
    if value is None:
        return DEFAULT_BATON_WATCHDOG[key]
    return value

if query in ("enabled", "periodic_clear_enabled"):
    print("true" if policy_get(query) is True else "false")
elif query in ("baton_lost_after_sec", "baton_ntfy_after_sec", "baton_d1_ntfy_after_sec", "progress_stall_after_sec", "baton_b4b_ntfy_after_sec", "baton_b4c_stale_after_sec", "poll_interval_sec", "periodic_clear_idle_sec", "usage_warn_pct", "usage_resume_below_pct", "usage_check_interval_sec", "baton_b4c_machine_stale_after_sec", "baton_lost_human_held_after_sec"):
    print(int(policy_get(query)))
elif query == "periodic_clear_agents":
    agents = policy_get(query)
    if not isinstance(agents, list) or not agents:
        agents = DEFAULT_BATON_WATCHDOG["periodic_clear_agents"]
    print("\n".join(str(a) for a in agents))
elif query == "baton_b4c_machine_exempt_agents":
    # periodic_clear_agentsと違い、空リストは「除外なし」という意味の
    # ある設定値である(cmd_189)。空を既定へ差し替えてはならない
    # (差し替えると空リストによる巻き戻し弁が効かなくなる)。
    agents = policy_get(query)
    if not isinstance(agents, list):
        agents = DEFAULT_BATON_WATCHDOG[query]
    print("\n".join(str(a) for a in agents))
else:
    raise SystemExit(f"unknown baton_watchdog query: {query}")
PY
}

# shogun_input_guard_query (cmd_182): thresholds for the shogun-pane nudge
# defer mechanism (send_wakeup in scripts/inbox_watcher.sh). Deferring —
# not dropping — a nudge while the lord is actively typing prevents nudge
# text from corrupting an in-progress keystroke (the "issue 37" →
# "inbox137" incident). Safe defaults must survive an absent config
# section or file (cmd_163 BL-3).
shogun_input_guard_query() {
    local query="$1"
    local python_bin
    python_bin="$(stall_policy_python)"

    "$python_bin" - "$STALL_POLICY_SETTINGS" "$query" <<'PY'
import sys

try:
    import yaml
except Exception as exc:
    raise SystemExit(f"PyYAML is required to read shogun_input_guard: {exc}")

settings_path, query = sys.argv[1], sys.argv[2]

# Safe defaults (cmd_182). guard_sec=60: the practical boundary between
# "mid-keystroke pause" and "stepped away" (see gunshi cmd_182 design
# review). defer_ntfy_after_sec=300: only fall back to ntfy as a rare
# insurance path if deferral drags on — never the primary delivery path.
DEFAULT_SHOGUN_INPUT_GUARD = {
    "shogun_input_guard_sec": 60,
    "shogun_defer_ntfy_after_sec": 300,
}

try:
    with open(settings_path, "r", encoding="utf-8") as fh:
        settings = yaml.safe_load(fh) or {}
except FileNotFoundError:
    settings = {}

policy = settings.get("shogun_input_guard")
if not isinstance(policy, dict):
    policy = {}

def policy_get(key):
    value = policy.get(key)
    if value is None:
        return DEFAULT_SHOGUN_INPUT_GUARD[key]
    return value

if query in ("shogun_input_guard_sec", "shogun_defer_ntfy_after_sec"):
    print(int(policy_get(query)))
else:
    raise SystemExit(f"unknown shogun_input_guard query: {query}")
PY
}
