#!/usr/bin/env bash
# scripts/ci/verify_no_unexpected_skips.sh
#
# SKIP=FAIL policy (Test Rules #1 / FR-054) gate, shared across every CI test
# job (unit-tests / e2e-tests / integration-tests). Extracted from
# unit-tests' original inline step (cmd_241) so a future fix to this gate
# only has to be made in one place instead of copy-pasted into each job.
#
# Usage:
#   bash scripts/ci/verify_no_unexpected_skips.sh [--filter-tags TAGS] <bats-file> [<bats-file> ...]
#
# --filter-tags TAGS is passed through to `bats` verbatim (e.g.
# '!copilot,!codex' for integration-tests) so re-running a file under this
# gate excludes the same tests the job's own run step excluded.
#
# Remaining arguments are expected to already be an expanded list of .bats
# files (the caller's shell glob, e.g. `tests/*.bats tests/unit/*.bats`). A
# glob that matched nothing (literal pattern passed through unexpanded) is
# silently skipped, matching the historical `[ -f "$f" ] || continue`
# behavior this replaces.
set -euo pipefail

BATS_ARGS=()
while [[ $# -gt 0 && "$1" == --* ]]; do
    case "$1" in
        --filter-tags)
            BATS_ARGS+=(--filter-tags "$2")
            shift 2
            ;;
        *)
            echo "::error::verify_no_unexpected_skips.sh: unknown flag $1" >&2
            exit 1
            ;;
    esac
done

if [ "$#" -eq 0 ]; then
    echo "::warning::verify_no_unexpected_skips.sh: no target files given"
    exit 0
fi

SKIP_COUNT=0
for f in "$@"; do
    [ -f "$f" ] || continue
    RESULT=$(bats "${BATS_ARGS[@]}" "$f" --tap 2>/dev/null || true)
    # Count skips, excluding known CI-environment skips (e.g. "claude not installed")
    COUNT=$(echo "$RESULT" | grep "^ok.*# skip" | grep -cv "CI environment" || true)
    if [ "$COUNT" -gt 0 ]; then
        echo "::error::${COUNT} unexpected SKIP(s) in ${f}"
    fi
    SKIP_COUNT=$((SKIP_COUNT + COUNT))
done

if [ "$SKIP_COUNT" -gt 0 ]; then
    echo "::error::${SKIP_COUNT} tests were SKIPPED unexpectedly. SKIP = FAIL policy (FR-054)."
    exit 1
fi
echo "All tests executed (0 unexpected skips)"
