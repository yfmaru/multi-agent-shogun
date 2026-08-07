#!/usr/bin/env bash
# queue_integrity_snapshot.sh - PreToolUse hook (cmd_211 P-211-B, design
# section 4 L2). Snapshots the guarded queue YAML before Edit/Write touches
# it, so that when queue_integrity_post_check.sh (L1) later detects a
# corruption, a known-good version is already sitting in queue/.snapshots/.
# L2 alone is inert -- it only becomes useful paired with L1's detection
# (queue/reports/gunshi_design_211.yaml section 3 AC#4).
#
# Registered as a PreToolUse hook (matcher: "Edit|Write") in
# .claude/settings.json. Reads the hook JSON on stdin and compares
# tool_input.file_path against the guarded target -- a no-op for every
# other path, so it is safe to run for every Edit/Write in the repo.
#
# Env overrides (testing only):
#   __QUEUE_INTEGRITY_SCRIPT_DIR - scripts dir to resolve prune_snapshots.sh
#     from (default: this script's own directory)
#   QUEUE_INTEGRITY_TARGET_PATH - guarded file (default:
#     <repo>/queue/shogun_to_karo.yaml)
#   QUEUE_INTEGRITY_SNAPSHOT_KEEP - generations to retain (default: 20)

set -u

SCRIPT_DIR="${__QUEUE_INTEGRITY_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_PATH="${QUEUE_INTEGRITY_TARGET_PATH:-${PROJECT_ROOT}/queue/shogun_to_karo.yaml}"
KEEP="${QUEUE_INTEGRITY_SNAPSHOT_KEEP:-20}"

INPUT=$(cat)
FILE_PATH=$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('tool_input', {}).get('file_path', ''))
except Exception:
    print('')
" 2>/dev/null)

[ -z "$FILE_PATH" ] && exit 0

TARGET_ABS=$(realpath "$TARGET_PATH" 2>/dev/null || echo "$TARGET_PATH")
FILE_ABS=$(realpath "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")

[ "$FILE_ABS" = "$TARGET_ABS" ] || exit 0
[ -f "$TARGET_ABS" ] || exit 0

SNAPSHOT_DIR="$(dirname "$TARGET_ABS")/.snapshots"
BASENAME="$(basename "$TARGET_ABS" .yaml)"
mkdir -p "$SNAPSHOT_DIR"

TS=$(date -u +%Y%m%dT%H%M%SZ)
cp "$TARGET_ABS" "${SNAPSHOT_DIR}/${BASENAME}.${TS}.yaml"

bash "$SCRIPT_DIR/prune_snapshots.sh" "$SNAPSHOT_DIR" "$BASENAME" "$KEEP"

exit 0
