#!/usr/bin/env bash
#
# log_daily_consumption.sh - append one CSV row per agent for today's
# (or a given date's) token consumption to logs/daily/consumption.csv.
#
# Background: cmd_172's acceptance criterion "同一条件で比較計測" turned
# out to be unsatisfiable because no comparable day ever existed
# (queue/reports/gunshi_172_closeout.yaml, s2_p1_effect_remeasured). This
# script makes the daily measurement a standing record so that whenever a
# comparable day does show up, past data is already there (cmd_178, PC-2
# per queue/reports/gunshi_172_closeout.yaml s8_backlog_proposed).
#
# No scheduler exists in this environment (家老実測: crontab空) - this is
# a manual/karo-or-gunshi-invoked one-shot script, not a daemon.
#
# Usage: bash scripts/log_daily_consumption.sh [YYYY-MM-DD] [--force]
#   YYYY-MM-DD  Date to aggregate (default: yesterday, i.e. the most
#               recent fully-closed day; today is always in-progress so
#               its total would be a partial value).
#   --force     Recompute and overwrite an already-recorded date instead
#               of skipping it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLAUDE_PROJECTS_DIR="${SHOGUN_CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects/-mnt-c-tools-multi-agent-shogun}"
OUT_CSV="${PROJECT_ROOT}/logs/daily/consumption.csv"
HEADER="date,agent,turn_count,weighted_total,relative_share_pct,avg_context,max_context"

DATE=""
FORCE=false
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
    *) DATE="$arg" ;;
  esac
done
DATE="${DATE:-$(date -d yesterday +%Y-%m-%d)}"

if [ ! -d "$CLAUDE_PROJECTS_DIR" ]; then
  echo "ABORT: claude projects dir not found: ${CLAUDE_PROJECTS_DIR}" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT_CSV")"

if [ ! -f "$OUT_CSV" ]; then
  echo "$HEADER" > "$OUT_CSV"
fi

if [ "$FORCE" = true ]; then
  # Drop any existing rows for this date before recomputing.
  grep -v "^${DATE}," "$OUT_CSV" > "${OUT_CSV}.tmp" || true
  mv "${OUT_CSV}.tmp" "$OUT_CSV"
elif grep -q "^${DATE}," "$OUT_CSV"; then
  echo "SKIP: ${DATE} already recorded in ${OUT_CSV} (use --force to recompute)" >&2
  exit 0
fi

python3 "${SCRIPT_DIR}/compute_daily_consumption.py" "$DATE" "$CLAUDE_PROJECTS_DIR" >> "$OUT_CSV"

echo "Recorded ${DATE} into ${OUT_CSV}" >&2
