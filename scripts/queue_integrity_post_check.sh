#!/usr/bin/env bash
# queue_integrity_post_check.sh - PostToolUse hook (cmd_211 P-211-B, design
# section 4 L1 delivery). Runs queue_integrity_check.sh against the guarded
# queue YAML right after an Edit/Write touches it, and -- only when it
# fails -- delivers the failure to karo via inbox_write.sh.
#
# A stderr-only report is not enough. This is the piece P-211-A's design
# called for but that implementation dropped (queue/reports/
# gunshi_qc_211_pr90.yaml finding F-1): "検知を『表示』ではなく『配送』に
# する" -- the same lesson cmd_208 already drew about baton_lost ("壊れて
# いるのは検知ではなく宛先"). See queue/reports/gunshi_design_211.yaml
# section 4 L1 / section 6 failure-scenario-1.
#
# Registered as a PostToolUse hook (matcher: "Edit|Write") in
# .claude/settings.json. Reads the hook JSON on stdin and compares
# tool_input.file_path against the guarded target -- a no-op for every
# other path, so it is safe to run for every Edit/Write in the repo. A
# clean pass (exit 0 from queue_integrity_check.sh) sends nothing.
#
# Env overrides (testing only):
#   __QUEUE_INTEGRITY_SCRIPT_DIR - scripts dir to resolve
#     queue_integrity_check.sh / inbox_write.sh from (default: this
#     script's own directory)
#   QUEUE_INTEGRITY_TARGET_PATH - guarded file (default:
#     <repo>/queue/shogun_to_karo.yaml)
#   QUEUE_INTEGRITY_INBOX_TARGET - inbox_write.sh destination (default: karo)

set -u

SCRIPT_DIR="${__QUEUE_INTEGRITY_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_PATH="${QUEUE_INTEGRITY_TARGET_PATH:-${PROJECT_ROOT}/queue/shogun_to_karo.yaml}"
INBOX_TARGET="${QUEUE_INTEGRITY_INBOX_TARGET:-karo}"

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

ERR_FILE=$(mktemp)
trap 'rm -f "$ERR_FILE"' EXIT

if bash "$SCRIPT_DIR/queue_integrity_check.sh" "$TARGET_ABS" 2>"$ERR_FILE" 1>/dev/null; then
    exit 0
fi

bash "$SCRIPT_DIR/inbox_write.sh" --to "$INBOX_TARGET" --content-file "$ERR_FILE" \
    --type report_received --from queue_integrity_check

exit 0
