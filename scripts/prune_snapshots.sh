#!/usr/bin/env bash
# prune_snapshots.sh - keep only the newest N generations of a snapshot
# series, deleting older ones (cmd_211 P-211-B, design section 4 L2).
#
# Usage: prune_snapshots.sh <snapshot_dir> <basename> [N]
#   N defaults to 20. Snapshot files are expected to be named
#   "<basename>.<ISO8601-basic-timestamp>.yaml", which sorts
#   lexicographically = chronologically, so plain `sort` orders oldest-first.

set -u

SNAPSHOT_DIR="${1:?snapshot dir required}"
BASENAME="${2:?basename required}"
KEEP="${3:-20}"

[ -d "$SNAPSHOT_DIR" ] || exit 0

mapfile -t FILES < <(ls -1 "${SNAPSHOT_DIR}/${BASENAME}."*.yaml 2>/dev/null | sort)

COUNT=${#FILES[@]}
if [ "$COUNT" -le "$KEEP" ]; then
    exit 0
fi

EXCESS=$((COUNT - KEEP))
for ((i = 0; i < EXCESS; i++)); do
    rm -f "${FILES[$i]}"
done

exit 0
