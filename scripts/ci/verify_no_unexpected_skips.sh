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
# skipped per-file via `[ -f "$f" ] || continue`, matching the historical
# behavior this replaces. But if that leaves zero files actually checked
# (including the no-args case), the gate errors out instead of silently
# reporting success — measuring nothing must never look like passing
# (cmd_241 F-4).
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

SKIP_COUNT=0
CHECKED_COUNT=0
TAP_OUT="$(mktemp)"
trap 'rm -f "$TAP_OUT"' EXIT
for f in "$@"; do
    [ -f "$f" ] || continue
    CHECKED_COUNT=$((CHECKED_COUNT + 1))
    echo "::group::${f}"
    # Redirect to a regular file rather than capturing via $(...). A test
    # file that spawns a detached process (e.g. a synthesized tmux session
    # for E2E fixtures) can leave a descendant holding stdout open past
    # bats' own exit; `$(...)` waits for that pipe to reach EOF and hangs
    # until the job's timeout-minutes kills it, even though bats itself
    # already finished (cmd_241, observed on PR#122 run 32306695113 — this
    # gate step never printed anything and was cancelled after 4 minutes).
    # A file redirect has no such wait: the shell only waits for the
    # direct child (bats) to exit, not for anything it left running.
    bats "${BATS_ARGS[@]}" "$f" --tap >"$TAP_OUT" 2>/dev/null || true
    # Count skips, excluding known CI-environment skips (e.g. "claude not installed")
    COUNT=$(grep "^ok.*# skip" "$TAP_OUT" | grep -cv "CI environment" || true)
    if [ "$COUNT" -gt 0 ]; then
        echo "::error::${COUNT} unexpected SKIP(s) in ${f}"
    fi
    SKIP_COUNT=$((SKIP_COUNT + COUNT))
    echo "::endgroup::"
done

if [ "$CHECKED_COUNT" -eq 0 ]; then
    echo "::error::verify_no_unexpected_skips.sh: 0 files were actually checked (all args were missing/unexpanded globs). Refusing to report success without measuring anything."
    exit 1
fi

if [ "$SKIP_COUNT" -gt 0 ]; then
    echo "::error::${SKIP_COUNT} tests were SKIPPED unexpectedly. SKIP = FAIL policy (FR-054)."
    exit 1
fi
echo "All tests executed (0 unexpected skips, ${CHECKED_COUNT} file(s) checked)"
