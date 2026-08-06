#!/usr/bin/env bats
# test_stall_detect_livepane.bats — cmd_209 P-2 livebug fix, real-tmux checks (V-3/V-4)
#
# Why this file exists (and why it's NOT in tests/unit/):
# tests/unit/test_stall_detect.bats mocks tmux entirely, so it can only prove
# agent_is_busy_check() sends the right arguments and reacts correctly to
# fixture strings we hand it — it cannot prove that a REAL tmux pane, at a
# REAL width, actually wraps an AskUserQuestion-style modal footer the way
# the fixtures assume. That gap is exactly how the original bug shipped:
# unit tests were green, the real pane was not. See
# queue/reports/gunshi_design_209_livebug.yaml section "V-3" for the full
# rationale. This file is the type of check that would have caught the bug
# at design time.
#
# All tmux sessions here are self-terminating (`... ; sleep N`), per
# CLAUDE.md's Test Rules #5 and the D006 restriction (agents cannot kill
# processes they started) — no explicit `tmux kill-session` is ever called.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup_file() {
    command -v tmux &>/dev/null || skip "tmux not available"
    export PROJECT_ROOT="$SCRIPT_DIR"
}

setup() {
    # shellcheck disable=SC1090
    source "$PROJECT_ROOT/lib/agent_status.sh"
    SESSION_SUFFIX="$$_${BATS_TEST_NUMBER:-0}_${RANDOM}"
}

# The exact AskUserQuestion modal footer text and 2-column indent gunshi
# measured live (queue/reports/gunshi_design_209_livebug.yaml, 実験2) — the
# indent is what makes a narrow pane split "Esc to" from "cancel" instead of
# breaking mid-word.
FOOTER_TEXT='  Enter to select · ↑/↓ to navigate · Esc to cancel'

# ─── V-3: width sweep 40-70 — proves the fix is NOT width-dependent ───
#
# This is the test that most directly answers the question the original bug
# raised: does the fix work at every pane width in production (43/44/65
# columns), or only at the one width someone happened to test? Sweeping the
# full 40-70 range (well past the three known production widths) proves the
# fix is structural (undoing tmux's own wrap tracking via -J), not a
# coincidence that happens to work at 44 columns.
@test "V-3: agent_is_busy_check reports busy across pane widths 40-70 once -J rejoins the wrapped modal footer" {
    local fail_widths=()
    local w name rc
    for w in $(seq 40 70); do
        name="v3_w${w}_${SESSION_SUFFIX}"
        tmux new-session -d -s "$name" -x "$w" -y 12 \
            "printf '%s' '$FOOTER_TEXT'; sleep 15"
        # Give tmux a moment to render before capturing.
        sleep 0.05
        agent_is_busy_check "$name" claude
        rc=$?
        if [ "$rc" -ne 0 ]; then
            fail_widths+=("${w}:rc=${rc}")
        fi
    done
    if [ "${#fail_widths[@]}" -ne 0 ]; then
        echo "widths that did NOT report busy: ${fail_widths[*]}"
        false
    fi
}

# ─── V-4: T-BUSY-008 real-tmux equivalent — old marker + idle prompt → idle ───
#
# Mirrors tests/unit/test_send_wakeup.bats's T-BUSY-008 (mocked) against a
# real pane: an old "esc to interrupt" busy marker sits above the current
# bottom line, which is a bare idle prompt. agent_is_busy_check() must key
# off the LAST line only (T-BUSY-008's original false-busy fix) — that
# discipline must survive the -J change (R-2/the "触るな" instruction: only
# the capture call gains -J, the last-line-only rule is untouched).
@test "V-4: agent_is_busy_check stays idle when an old busy marker lingers above a bottom-line idle prompt" {
    local name="v4_${SESSION_SUFFIX}"
    # printf: line 1 = stale busy marker (scrollback), line 2 = current idle
    # prompt (no trailing newline, so it stays the last-written row).
    tmux new-session -d -s "$name" -x 65 -y 12 \
        "printf 'Old task \xe2\x80\xa2 esc to interrupt\n\xe2\x9d\xaf '; sleep 15"
    sleep 0.05
    run agent_is_busy_check "$name" claude
    [ "$status" -eq 1 ]
}
