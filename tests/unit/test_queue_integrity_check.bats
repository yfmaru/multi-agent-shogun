#!/usr/bin/env bats
#
# cmd_211 P-211-A -- scripts/queue_integrity_check.sh / queue_integrity_check.py
#
# Background (queue/reports/gunshi_design_211.yaml section 1.3, "M-1"):
# an Edit whose anchor spans an entry-boundary heading line ("  - id: cmd_XXX")
# can silently drop that heading line. The following entry's body then merges
# into the previous entry's YAML mapping. This is valid YAML (no parser error),
# and duplicate keys resolve last-wins, so the earlier entry's own values
# vanish from the parsed result without a trace.
#
# All fixtures live under a fresh tmp dir per test -- queue/ itself is never
# touched (production file is out of scope for this task, see task YAML
# "触れるな" section).

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/queue_integrity.XXXXXX")"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

run_check() {
    bash "$PROJECT_ROOT/scripts/queue_integrity_check.sh" "$1"
}

@test "healthy multi-entry fixture passes with exit 0" {
    cat > "$TEST_TMPDIR/healthy.yaml" <<'EOF'
commands:
  - id: cmd_A
    timestamp: "2026-08-01T00:00:00"
    status: done
    karo_note: "note A"
  - id: cmd_B
    timestamp: "2026-08-02T00:00:00"
    status: pending
    karo_note: "note B"
EOF

    run run_check "$TEST_TMPDIR/healthy.yaml"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *"OK:"* ]] || { echo "$output"; false; }
}

@test "full heading+id line dropped, entries merge -- caught by C-1, NOT C-2 (design repro)" {
    # Reproduces gunshi_design_211 section 1.3's repro exactly: dropping
    # cmd_B's whole "  - id: cmd_B" line merges its fields into cmd_A. Since
    # both entries share the same schema, this produces duplicate keys
    # within one mapping (C-1's job) -- but raw heading count and parsed
    # entry count both drop from 2 to 1 in lockstep, so C-2 stays silent.
    # This is the exact reason the design doc insists on both checks.
    cat > "$TEST_TMPDIR/merged_entries.yaml" <<'EOF'
commands:
  - id: cmd_A
    timestamp: "2026-08-01T00:00:00"
    status: done
    karo_note: "note A"
    timestamp: "2026-08-02T00:00:00"
    status: pending
    karo_note: "note B"
EOF

    run run_check "$TEST_TMPDIR/merged_entries.yaml"
    [ "$status" -ne 0 ] || { echo "unexpected pass: $output"; false; }
    [[ "$output" == *"C-1 duplicate key"* ]] || { echo "$output"; false; }
    [[ "$output" != *"C-2 count mismatch"* ]] || { echo "unexpected C-2 firing on a clean merge: $output"; false; }
}

@test "entry's id line lost but list item survives independently -- caught by C-2, NOT C-1" {
    # A different corruption shape: only the "id: cmd_B" text is lost while
    # the list-item dash itself survives (e.g. "  - id: cmd_B\n    " was
    # dropped from an anchor but "  - " remained). The entry stays its own
    # separate mapping with no "id" key, so raw heading-line count (1) and
    # parsed entry count (2) diverge -- with no key collision anywhere, so
    # C-1 has nothing to report.
    cat > "$TEST_TMPDIR/lost_id_field.yaml" <<'EOF'
commands:
  - id: cmd_A
    timestamp: "2026-08-01T00:00:00"
    status: done
  - timestamp: "2026-08-02T00:00:00"
    status: pending
    karo_note: "id line for this entry was lost"
EOF

    run run_check "$TEST_TMPDIR/lost_id_field.yaml"
    [ "$status" -ne 0 ] || { echo "unexpected pass: $output"; false; }
    [[ "$output" == *"C-2 count mismatch"* ]] || { echo "$output"; false; }
    [[ "$output" != *"C-1 duplicate key"* ]] || { echo "unexpected C-1 firing with no key collision: $output"; false; }
}

@test "duplicate top-level key with intact heading count is caught by C-1 (cmd_201-style)" {
    # Mirrors the live cmd_201 corruption found during gunshi_design_211's
    # investigation: karo_note appears twice inside the SAME entry, with no
    # heading line lost at all. Raw id-heading count == parsed entry count,
    # so C-2 alone sees nothing wrong -- only C-1 catches this.
    cat > "$TEST_TMPDIR/dup_top_level.yaml" <<'EOF'
commands:
  - id: cmd_201
    timestamp: "2026-08-02T22:06:00"
    status: done
    karo_note: |
      2026-08-05 22:13 detailed record that gets silently discarded.
    karo_note: |
      2026-08-02 22:06 short original note.
  - id: cmd_202
    timestamp: "2026-08-05T22:10:00"
    status: pending
    karo_note: "unrelated entry, untouched"
EOF

    run run_check "$TEST_TMPDIR/dup_top_level.yaml"
    [ "$status" -ne 0 ] || { echo "unexpected pass: $output"; false; }
    [[ "$output" == *"C-1 duplicate key 'karo_note'"* ]] || { echo "$output"; false; }
    [[ "$output" == *"cmd_201"* ]] || { echo "$output"; false; }
    # This is the exact case the design doc says count reconciliation alone
    # (13/13) failed to catch -- assert C-2 stays silent here.
    [[ "$output" != *"C-2 count mismatch"* ]] || { echo "C-2 should not fire when counts match: $output"; false; }
}

@test "duplicate nested key with intact heading count is caught by C-1 (cmd_203-style)" {
    # Mirrors the live cmd_203 corruption: a nested pending_followups[].status
    # key duplicated within one list item, entry/heading count unaffected.
    cat > "$TEST_TMPDIR/dup_nested.yaml" <<'EOF'
commands:
  - id: cmd_203
    timestamp: "2026-08-05T00:00:00"
    status: done
    pending_followups:
      - id: t3_dispatch
        declared_by: karo
        status: done
        status: pending
EOF

    run run_check "$TEST_TMPDIR/dup_nested.yaml"
    [ "$status" -ne 0 ] || { echo "unexpected pass: $output"; false; }
    [[ "$output" == *"C-1 duplicate key 'status'"* ]] || { echo "$output"; false; }
    [[ "$output" == *"cmd_203"* ]] || { echo "$output"; false; }
    [[ "$output" != *"C-2 count mismatch"* ]] || { echo "C-2 should not fire when counts match: $output"; false; }
}

@test "C-3 flags an id missing from the current file vs. the last snapshot" {
    mkdir -p "$TEST_TMPDIR/.snapshots"
    cat > "$TEST_TMPDIR/.snapshots/target.20260807120000.yaml" <<'EOF'
commands:
  - id: cmd_A
    status: done
  - id: cmd_B
    status: pending
EOF

    cat > "$TEST_TMPDIR/target.yaml" <<'EOF'
commands:
  - id: cmd_A
    status: done
EOF

    run run_check "$TEST_TMPDIR/target.yaml"
    [ "$status" -ne 0 ] || { echo "unexpected pass: $output"; false; }
    [[ "$output" == *"C-3 monotonicity violation"* ]] || { echo "$output"; false; }
    [[ "$output" == *"cmd_B"* ]] || { echo "$output"; false; }
}

@test "C-3 does not false-positive when the removal is recorded in .removed_ids" {
    mkdir -p "$TEST_TMPDIR/.snapshots"
    cat > "$TEST_TMPDIR/.snapshots/target.20260807120000.yaml" <<'EOF'
commands:
  - id: cmd_A
    status: done
  - id: cmd_B
    status: done
EOF

    cat > "$TEST_TMPDIR/target.yaml" <<'EOF'
commands:
  - id: cmd_A
    status: done
EOF

    echo "cmd_B" > "$TEST_TMPDIR/.removed_ids"

    run run_check "$TEST_TMPDIR/target.yaml"
    [ "$status" -eq 0 ] || { echo "expected pass when removal is recorded: $output"; false; }
}

@test "C-3 is skipped when no .snapshots directory exists yet (P-211-B not wired)" {
    cat > "$TEST_TMPDIR/target.yaml" <<'EOF'
commands:
  - id: cmd_A
    status: done
EOF

    run run_check "$TEST_TMPDIR/target.yaml"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "default target path is queue/shogun_to_karo.yaml relative to the script when no argument given" {
    mkdir -p "$TEST_TMPDIR/repo/scripts" "$TEST_TMPDIR/repo/queue"
    cp "$PROJECT_ROOT/scripts/queue_integrity_check.sh" "$TEST_TMPDIR/repo/scripts/"
    cp "$PROJECT_ROOT/scripts/queue_integrity_check.py" "$TEST_TMPDIR/repo/scripts/"
    cat > "$TEST_TMPDIR/repo/queue/shogun_to_karo.yaml" <<'EOF'
commands:
  - id: cmd_A
    status: done
EOF

    run bash "$TEST_TMPDIR/repo/scripts/queue_integrity_check.sh"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *"shogun_to_karo.yaml"* ]] || { echo "$output"; false; }
}

@test "runs against the real queue/shogun_to_karo.yaml within a reasonable time budget" {
    real_file="$PROJECT_ROOT/queue/shogun_to_karo.yaml"
    [ -f "$real_file" ] || skip "queue/shogun_to_karo.yaml not present in this checkout"

    start_ns=$(date +%s%N)
    run run_check "$real_file"
    end_ns=$(date +%s%N)
    elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))

    echo "elapsed_ms=${elapsed_ms} exit_status=${status}"
    # Target from gunshi_design_211 AC#5 measurement is ~15ms; a generous
    # 2000ms bound avoids CI-runner flakiness while still catching any
    # accidental O(n^2) blowup.
    [ "$elapsed_ms" -lt 2000 ] || { echo "too slow: ${elapsed_ms}ms"; false; }
}
