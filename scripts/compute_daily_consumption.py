#!/usr/bin/env python3
"""
compute_daily_consumption.py - per-agent token consumption for one date.

Reproduces the ad-hoc aggregation method 軍師 used in
queue/reports/gunshi_172_survey.yaml (§1/§2) and
queue/reports/gunshi_172_closeout.yaml (s2_p1_effect_remeasured), as a
reusable script (cmd_178 PC-2).

Usage: compute_daily_consumption.py <YYYY-MM-DD> <claude_projects_dir>
Prints CSV rows (no header) to stdout: one row per agent that had at
least one turn on that date.
"""
import json
import glob
import os
import re
import sys
from datetime import datetime

ROLE_PATTERN = re.compile(r'貴殿は\s*\*\*([a-z]+[0-9]*)\*\*\s*である')

# Relative API pricing weights, per gunshi_172_survey.yaml weighting_note.
WEIGHTS = {
    'cache_read_input_tokens': 0.1,
    'input_tokens': 1.0,
    'cache_creation_input_tokens': 1.25,
    'output_tokens': 5.0,
}


def detect_role(lines):
    """Role = first '貴殿は **<role>** である' match found from the top of
    the file ("冒頭" per the survey's method). Taking only the first match
    (rather than any match anywhere) matters: a session's own jsonl can
    later quote other agents' hook text (e.g. while reading CLAUDE.md
    examples), which would otherwise be misread as a role change."""
    for line in lines:
        m = ROLE_PATTERN.search(line)
        if m:
            return m.group(1)
    return None


def main():
    if len(sys.argv) != 3:
        print("Usage: compute_daily_consumption.py <YYYY-MM-DD> <claude_projects_dir>", file=sys.stderr)
        sys.exit(1)
    date, log_dir = sys.argv[1], sys.argv[2]

    agents = {}  # role -> {"turns": int, "weighted": float, "contexts": [int]}

    for path in glob.glob(os.path.join(log_dir, '*.jsonl')):
        try:
            with open(path, encoding='utf-8', errors='ignore') as f:
                lines = f.readlines()
        except OSError:
            continue

        role = detect_role(lines)
        if role is None:
            continue

        for line in lines:
            try:
                d = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                continue
            timestamp = d.get('timestamp', '')
            if not timestamp:
                continue
            try:
                ts_local = datetime.fromisoformat(timestamp.replace("Z", "+00:00")).astimezone()
            except ValueError:
                continue
            if ts_local.strftime('%Y-%m-%d') != date:
                continue
            usage = (d.get('message') or {}).get('usage') or {}
            if not usage:
                continue

            it = usage.get('input_tokens') or 0
            cc = usage.get('cache_creation_input_tokens') or 0
            cr = usage.get('cache_read_input_tokens') or 0
            ot = usage.get('output_tokens') or 0
            if it == 0 and cc == 0 and cr == 0 and ot == 0:
                continue  # not a real turn (streaming no-op / zero-usage line)

            weighted = (
                it * WEIGHTS['input_tokens']
                + cc * WEIGHTS['cache_creation_input_tokens']
                + cr * WEIGHTS['cache_read_input_tokens']
                + ot * WEIGHTS['output_tokens']
            )
            context = it + cc + cr  # what got fed in, per turn (F1 in the survey)

            stat = agents.setdefault(role, {'turns': 0, 'weighted': 0.0, 'contexts': []})
            stat['turns'] += 1
            stat['weighted'] += weighted
            stat['contexts'].append(context)

    grand_total = sum(a['weighted'] for a in agents.values())

    for role in sorted(agents):
        stat = agents[role]
        turns = stat['turns']
        if turns == 0:
            continue
        weighted = stat['weighted']
        share_pct = (weighted / grand_total * 100) if grand_total else 0.0
        avg_context = sum(stat['contexts']) / turns
        max_context = max(stat['contexts'])
        print(f"{date},{role},{turns},{weighted:.1f},{share_pct:.2f},{avg_context:.1f},{max_context}")


if __name__ == '__main__':
    main()
