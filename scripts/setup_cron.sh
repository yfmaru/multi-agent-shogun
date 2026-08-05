#!/usr/bin/env bash
# Print or install cron entries for branch policy maintenance.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="print"

usage() {
    cat <<'EOF'
Usage: setup_cron.sh [--print] [--install]

--print    Print the cron block without changing crontab (default).
--install  Install or replace the managed cron block in the current user's crontab.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --print|--dry-run) MODE="print"; shift ;;
        --install) MODE="install"; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

cron_block() {
    cat <<EOF
# multi-agent-shogun branch policy start
0 * * * * bash $SCRIPT_DIR/scripts/branch_drift_check.sh >> $SCRIPT_DIR/logs/branch_drift_check.log 2>&1
0 */6 * * * bash $SCRIPT_DIR/scripts/auto_merge_short_lived.sh >> $SCRIPT_DIR/logs/auto_merge_short_lived.log 2>&1
15 3 * * * bash $SCRIPT_DIR/scripts/stale_issue_audit.sh >> $SCRIPT_DIR/logs/stale_issue_audit.log 2>&1
# multi-agent-shogun branch policy end
EOF
}

if [[ "$MODE" == "print" ]]; then
    cron_block
    exit 0
fi

existing="$(crontab -l 2>/dev/null || true)"
{
    printf '%s\n' "$existing" | sed '/# multi-agent-shogun branch policy start/,/# multi-agent-shogun branch policy end/d'
    cron_block
} | crontab -

echo "[OK] branch policy cron installed"
