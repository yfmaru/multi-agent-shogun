#!/usr/bin/env python3
"""
Queue Integrity Check (cmd_211 P-211-A)

Detects silent data-loss corruption in single-slot queue YAML files such as
queue/shogun_to_karo.yaml. The known failure mechanism (M-1, see
queue/reports/gunshi_design_211.yaml section 1.3): an Edit whose anchor spans
an entry-boundary heading line ("  - id: cmd_XXX") can drop that heading line.
The following entry's body then silently merges into the previous entry's
YAML mapping. This is valid YAML, so a plain parser raises nothing; duplicate
keys are resolved last-wins and the previous entry's own values disappear
from the parsed result without any error.

Four checks, ordered by detection power (most to least):

  C-1 duplicate key detection  -- catches the corruption signature itself:
      when two adjacent entries merge because a heading line was dropped in
      full, the merged mapping ends up with the same field name twice
      (timestamp, status, karo_note, ...). This fires regardless of how long
      ago the merge happened, since the duplicate keys are baked into the
      document itself.
  C-2 heading/entry count reconciliation -- catches a narrower but distinct
      failure: an entry's own "- id: cmd_X" line is lost while the list-item
      dash itself survives (e.g. only the "id: cmd_X" text is dropped, not
      the leading "- "). That entry stays a separate parsed list item with
      no "id" key, so raw heading-line count and parsed entry count diverge
      even though no key collides within any single mapping (C-1 is blind
      to this case; the two checks cover disjoint failure shapes).
  C-3 id-set monotonicity vs. the last snapshot (if any) -- optional; skipped
      when no queue/.snapshots/ directory exists yet (wired by P-211-B).
      Ids explicitly recorded in queue/.removed_ids are not treated as
      violations, since Karo manually deleting completed cmds is legitimate.
  C-4 field shape (cmd_221 C-4, see queue/reports/
      gunshi_design_awaiting_scheme_and_write_conflict.yaml section b5) --
      unlike C-1/C-2/C-3, this is intentionally schema-dependent. It answers
      a blind spot the other three cannot: an Edit anchor that lands *inside*
      a plain scalar value (not on an entry-boundary heading line) gets
      silently absorbed as a line-continuation of that scalar, so no key is
      duplicated, no heading line is lost, and no id disappears -- C-1/C-2/C-3
      all pass cleanly on this shape (confirmed by reproduction; see the
      design doc's b3 capability table). C-4 instead checks each entry
      field's *value* against the shape it is supposed to have (regex for
      id, known-vocabulary membership for status/awaiting, ISO8601
      parseability for timestamp/awaiting_since, integer type for
      awaiting_budget_sec). Reported as WARNINGS, not violations, for this
      initial rollout (PB-1 mitigation: an unmeasured vocabulary guess would
      manufacture false positives on every ordinary Edit) -- C-4 findings do
      not affect the exit code.

Exit code: 0 if no C-1/C-2/C-3 problems found, 1 otherwise. C-4 findings are
warnings only and never affect the exit code (see C-4 above). Output is
written so it can be forwarded verbatim into an inbox_write.sh message body
by the caller.
"""

import argparse
import re
import sys
from datetime import date, datetime
from pathlib import Path

import yaml

# C-4 known-vocabulary domains, measured (not guessed -- PB-1) from
# queue/shogun_to_karo.yaml's live content plus all queue/.snapshots/
# generations at the time of implementation (2026-08-09): status values seen
# were {done: 200, in_progress: 40, pending: 7}; awaiting values seen were
# {external: 12, lord: 7}. "shogun" is included per cmd_221's approved design
# (queue/reports/gunshi_design_awaiting_scheme_and_write_conflict.yaml a4)
# even though no live entry uses it yet, since a sibling task (cmd_221
# W-1/awaiting-shogun) is adding it in parallel.
KNOWN_STATUS_VALUES = {"done", "in_progress", "pending"}
KNOWN_AWAITING_VALUES = {"lord", "external", "shogun"}
ID_FIELD_RE = re.compile(r'^cmd_\d+$')

RAW_ID_LINE_RE = re.compile(r'^  - id: cmd_', re.MULTILINE)
BLOCK_ID_LINE_RE = re.compile(r'^\s*- id:\s*(cmd_\S+)')


class DuplicateKeyEvent:
    def __init__(self, key, line, mapping_start_line):
        self.key = key
        self.line = line
        self.mapping_start_line = mapping_start_line


def _make_duplicate_key_loader(events):
    """Build a SafeLoader subclass that records (does not raise on) duplicate
    keys within any single YAML mapping, so a full parse can still complete
    and every duplicate in the document gets reported at once."""

    class DuplicateKeyLoader(yaml.SafeLoader):
        pass

    def construct_mapping(loader, node, deep=False):
        mapping = {}
        for key_node, value_node in node.value:
            key = loader.construct_object(key_node, deep=deep)
            line = key_node.start_mark.line + 1
            if key in mapping:
                events.append(DuplicateKeyEvent(key, line, node.start_mark.line + 1))
            value = loader.construct_object(value_node, deep=deep)
            mapping[key] = value
        return mapping

    DuplicateKeyLoader.add_constructor(
        yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, construct_mapping
    )
    return DuplicateKeyLoader


def _nearest_cmd_block(raw_lines, line_no):
    """Find the id of the nearest preceding '  - id: cmd_XXX'-style heading
    line, so a duplicate key can be attributed to the cmd block it fell in."""
    for i in range(min(line_no, len(raw_lines)) - 1, -1, -1):
        m = BLOCK_ID_LINE_RE.match(raw_lines[i])
        if m:
            return m.group(1)
    return None


def check_duplicate_keys(raw_text):
    """C-1: duplicate keys within any single mapping in the document."""
    events = []
    loader_cls = _make_duplicate_key_loader(events)
    try:
        yaml.load(raw_text, Loader=loader_cls)
    except yaml.YAMLError as exc:
        return [f"C-1: could not complete duplicate-key scan, YAML parse error: {exc}"]

    raw_lines = raw_text.splitlines()
    problems = []
    for ev in events:
        block_id = _nearest_cmd_block(raw_lines, ev.line) or "(no preceding '- id:' heading found)"
        problems.append(
            f"C-1 duplicate key '{ev.key}' at line {ev.line} "
            f"(mapping starts at line {ev.mapping_start_line}) in block {block_id}: "
            f"the earlier occurrence's value was silently discarded (YAML last-wins)."
        )
    return problems


def _entries_key(data):
    if not isinstance(data, dict):
        return None
    if 'commands' in data:
        return 'commands'
    if 'queue' in data:
        return 'queue'
    return None


def check_entry_count(raw_text, parsed):
    """C-2: raw '  - id: cmd_' heading count vs. parsed entry count."""
    raw_count = len(RAW_ID_LINE_RE.findall(raw_text))

    key = _entries_key(parsed)
    if key is None:
        # No 'commands'/'queue' top-level list means this document is out of
        # scope for entry-count reconciliation -- same skip C-3 applies when
        # no snapshot exists yet, not a problem to report.
        return []

    entries = parsed.get(key)
    if not isinstance(entries, list):
        return [f"C-2: top-level '{key}' is not a list; cannot compare entry count."]

    parsed_count = len(entries)
    if raw_count != parsed_count:
        return [
            f"C-2 count mismatch: raw '  - id: cmd_' heading lines = {raw_count}, "
            f"parsed '{key}' entries = {parsed_count}. "
            "An entry's id line was likely lost while it stayed a separate "
            "list item (no id key), or a stray line elsewhere coincidentally "
            "matches the heading pattern."
        ]
    return []


def _truncate(value, length=60):
    """Render a (possibly non-string) field value as a display snippet capped
    at `length` chars, per the reporting format cmd_221 specifies: 'キー名・
    cmd_id・実際の値の先頭60字'."""
    text = value if isinstance(value, str) else repr(value)
    if len(text) > length:
        return text[:length] + "..."
    return text


def _is_iso8601(value):
    """True if `value` is already a datetime/date (PyYAML auto-converts an
    unquoted ISO-looking scalar) or a string datetime.fromisoformat() can
    parse. All real timestamp/awaiting_since values in queue/shogun_to_karo.yaml
    are quoted strings, but an unquoted one is not itself a corruption."""
    if isinstance(value, date):  # datetime is a subclass of date
        return True
    if not isinstance(value, str):
        return False
    try:
        datetime.fromisoformat(value)
        return True
    except ValueError:
        return False


def check_field_shapes(parsed):
    """C-4: field-shape check (see module docstring). Schema-dependent by
    design -- catches the type-1 "text absorbed into a plain scalar"
    corruption shape that C-1/C-2/C-3 cannot see (b3 capability table).
    Returns WARNINGS, not violations: callers must not fold these into the
    exit-code-affecting problem list during this initial rollout (PB-1)."""
    key = _entries_key(parsed)
    if key is None:
        return []
    entries = parsed.get(key)
    if not isinstance(entries, list):
        return []

    warnings = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        cmd_id = entry.get('id') if isinstance(entry.get('id'), str) else '(no id)'

        if 'id' in entry:
            id_val = entry['id']
            if not isinstance(id_val, str) or not ID_FIELD_RE.match(id_val):
                warnings.append(
                    f"C-4 field shape (warning): {cmd_id} の `id` が `cmd_<数字>` の形でない: "
                    f"'{_truncate(id_val)}'"
                )

        if 'status' in entry:
            status_val = entry['status']
            if not isinstance(status_val, str) or status_val not in KNOWN_STATUS_VALUES:
                warnings.append(
                    f"C-4 field shape (warning): {cmd_id} の `status` が既知の語彙に無い: "
                    f"'{_truncate(status_val)}'"
                )

        if 'awaiting' in entry:
            awaiting_val = entry['awaiting']
            if not isinstance(awaiting_val, str) or awaiting_val not in KNOWN_AWAITING_VALUES:
                warnings.append(
                    f"C-4 field shape (warning): {cmd_id} の `awaiting` が既知の語彙に無い: "
                    f"'{_truncate(awaiting_val)}'"
                )

        for field in ('timestamp', 'awaiting_since'):
            if field in entry:
                val = entry[field]
                if not _is_iso8601(val):
                    warnings.append(
                        f"C-4 field shape (warning): {cmd_id} の `{field}` がISO8601として解釈できない: "
                        f"'{_truncate(val)}'"
                    )

        if 'awaiting_budget_sec' in entry:
            val = entry['awaiting_budget_sec']
            if not isinstance(val, int) or isinstance(val, bool):
                warnings.append(
                    f"C-4 field shape (warning): {cmd_id} の `awaiting_budget_sec` が整数でない: "
                    f"'{_truncate(val)}'"
                )

    return warnings


def _extract_ids(parsed):
    key = _entries_key(parsed)
    if key is None:
        return set()
    entries = parsed.get(key)
    if not isinstance(entries, list):
        return set()
    ids = set()
    for entry in entries:
        if isinstance(entry, dict) and entry.get('id') is not None:
            ids.add(entry.get('id'))
    return ids


def _load_removed_ids(removed_ids_path):
    if not removed_ids_path.exists():
        return set()
    ids = set()
    for line in removed_ids_path.read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if line and not line.startswith('#'):
            ids.add(line)
    return ids


def check_monotonicity(parsed, target_path):
    """C-3: id set of the baseline snapshot must be a subset of the current id
    set, minus anything explicitly recorded in .removed_ids. Skipped
    entirely if no queue/.snapshots/ directory exists yet (P-211-B scope).

    S-3 (cmd_221, design doc b5): the baseline is not simply the newest
    snapshot file. A PreToolUse snapshot is taken unconditionally, before any
    integrity check runs (queue_integrity_snapshot.sh), so the newest
    snapshot can itself be a corrupted copy -- e.g. the exact type-2
    ScannerError corruption this suite exists to catch. Blindly trusting
    snapshots[-1] would then either lose the baseline entirely (report a
    parse failure instead of comparing ids) or, if the corruption happened to
    still parse, compare against a baseline that was already wrong. Instead,
    walk from newest to oldest and use the first snapshot that parses --
    corrupted snapshots are skipped as a baseline candidate, not deleted
    (queue/.snapshots/ preserving pre-corruption state is its restore-from
    purpose; see design doc b5 S-3, option (a) was rejected for this reason)."""
    snapshot_dir = target_path.parent / '.snapshots'
    if not snapshot_dir.exists():
        return []

    snapshots = sorted(snapshot_dir.glob(f'{target_path.stem}.*.yaml'))
    if not snapshots:
        return []

    latest = None
    prev_data = None
    parse_errors = []
    for candidate in reversed(snapshots):
        try:
            prev_data = yaml.safe_load(candidate.read_text(encoding='utf-8')) or {}
            latest = candidate
            break
        except yaml.YAMLError as exc:
            parse_errors.append(f"{candidate.name}: {exc}")

    if latest is None:
        return [
            f"C-3: all {len(snapshots)} snapshot(s) under {snapshot_dir} failed "
            "to parse; cannot verify monotonicity. " + " | ".join(parse_errors)
        ]

    prev_ids = _extract_ids(prev_data)
    current_ids = _extract_ids(parsed)
    removed_ids = _load_removed_ids(target_path.parent / '.removed_ids')

    missing = (prev_ids - current_ids) - removed_ids
    if missing:
        return [
            "C-3 monotonicity violation: id(s) present in the last parseable "
            f"snapshot ({latest.name}) are missing now and not recorded in "
            f".removed_ids: {sorted(missing)}. If these were deliberately "
            "deleted/archived, add them to .removed_ids; otherwise this "
            "looks like data loss."
        ]
    return []


def run_checks(target_path):
    """Returns (problems, warnings). `problems` (C-1/C-2/C-3/FATAL) drive the
    exit code; `warnings` (C-4) are reported but never affect it (see module
    docstring)."""
    raw_text = target_path.read_text(encoding='utf-8')

    problems = list(check_duplicate_keys(raw_text))

    try:
        parsed = yaml.safe_load(raw_text)
    except yaml.YAMLError as exc:
        problems.append(f"FATAL: YAML parse failed for {target_path}: {exc}")
        return problems, []

    problems.extend(check_entry_count(raw_text, parsed))
    problems.extend(check_monotonicity(parsed, target_path))
    warnings = check_field_shapes(parsed)
    return problems, warnings


def main():
    parser = argparse.ArgumentParser(
        description="Detect silent single-slot-YAML corruption (cmd_211 P-211-A)."
    )
    parser.add_argument(
        'path',
        nargs='?',
        default=None,
        help="Target YAML path (default: queue/shogun_to_karo.yaml relative to repo root)",
    )
    args = parser.parse_args()

    if args.path:
        target = Path(args.path)
    else:
        target = Path(__file__).resolve().parent.parent / 'queue' / 'shogun_to_karo.yaml'

    if not target.exists():
        print(f"ERROR: target file not found: {target}", file=sys.stderr)
        return 1

    problems, warnings = run_checks(target)

    if problems:
        print(f"QUEUE INTEGRITY CHECK FAILED: {target}", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        if warnings:
            print(f"QUEUE INTEGRITY CHECK WARNINGS: {target}", file=sys.stderr)
            for warning in warnings:
                print(f"  - {warning}", file=sys.stderr)
        return 1

    if warnings:
        print(f"QUEUE INTEGRITY CHECK WARNINGS: {target}", file=sys.stderr)
        for warning in warnings:
            print(f"  - {warning}", file=sys.stderr)

    print(f"OK: {target} passed integrity check (no duplicate keys, count matches, no monotonicity violation).")
    return 0


if __name__ == '__main__':
    sys.exit(main())
