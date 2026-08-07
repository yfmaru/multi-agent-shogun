#!/usr/bin/env bash
#
# queue_integrity_check.sh - detect silent single-slot-YAML corruption
# (cmd_211 P-211-A). Thin wrapper around queue_integrity_check.py, following
# the same PYTHON_BIN resolution convention as slim_yaml.sh.
#
# Usage: bash queue_integrity_check.sh [path]
#   path defaults to queue/shogun_to_karo.yaml (relative to repo root)
#

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PYTHON_BIN="${SHOGUN_PYTHON_BIN:-${PROJECT_ROOT}/.venv/bin/python3}"

if [ ! -x "$PYTHON_BIN" ]; then
    PYTHON_BIN="python3"
fi

"$PYTHON_BIN" "$SCRIPT_DIR/queue_integrity_check.py" "$@"
exit $?
