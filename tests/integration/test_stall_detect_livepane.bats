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

# ─── V-3 caveat (added subtask_209_v5_modal_footer_fix, 2026-08-08) ───
# V-3 feeds FOOTER_TEXT to the pane via a SINGLE printf with no trailing
# newline, so it is tmux's OWN line-wrap tracking that splits it across
# rows — the exact mechanism `-J` was designed to undo. That means V-3
# covers only a TERMINAL-side wrap, not the actual bug: Claude Code paints
# the modal footer with absolute cursor positioning, so the footer is split
# by the APP, and tmux never sets its wrap-continuation flag for it — `-J`
# does nothing for that case. Measured fact: the pre-fix implementation
# (R0, i.e. this file's logic before the modal-footer-anchor block below
# existed) passes V-3 at every width in 40-70, identically to the fixed
# implementation (queue/reports/gunshi_design_209_v5_redesign.yaml M-4).
# V-3 cannot tell a correct fix from a broken one. T-MODAL-01/02 below
# reproduce the APP-side split via absolute cursor positioning and are the
# tests that actually exercise the bug and the fix.
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

# ─── T-MODAL-01..04 (cmd_209 AC2 v5, subtask_209_v5_modal_footer_fix) ───
#
# MODAL_FOOTER below is the literal text captured 2026-08-08 by opening a
# REAL AskUserQuestion modal in an isolated width-44 tmux pane (Step 0 of
# this subtask's task YAML) — not a desk transcription. No leading indent
# was observed in that live capture (unlike FOOTER_TEXT above, which gunshi
# measured with a 2-column indent on 2026-08-06); the difference doesn't
# matter for detection since the anchor check is a substring match, but the
# raw capture is reproduced here byte-for-byte for anyone re-verifying.
#
# All fixtures below split MODAL_FOOTER via ANSI absolute cursor positioning
# (`\033[<row>;1H`), not a single printf relying on tmux's own line wrap.
# This is the one detail the whole subtask hinges on: Claude Code paints
# this footer with absolute positioning, so in production the split carries
# no tmux wrap-continuation flag and `-J` cannot rejoin it. A single long
# printf (as V-3 uses) lets tmux wrap it FOR us, which DOES carry that flag
# — `-J` rejoins it trivially, and the resulting test can't distinguish a
# correct fix from the original bug (see the V-3 caveat comment above).
MODAL_FOOTER='Enter to select · ↑/↓ to navigate · Esc to cancel'

# split_modal_footer_cmd <width> — builds a printf command that paints
# MODAL_FOOTER split across two rows the way the app does at <width>
# columns: row 1 gets the first <width> characters, row 2 gets the rest.
split_modal_footer_cmd() {
    local width="$1"
    local row1="${MODAL_FOOTER:0:$width}"
    local row2="${MODAL_FOOTER:$width}"
    printf "printf '\\\\033[2J\\\\033[1;1H%%s\\\\033[2;1H%%s' '%s' '%s'; sleep 15" "$row1" "$row2"
}

# T-MODAL-01: single-width reproduction of the actual production bug.
# Ashigaru3/4/5/6/7 and gunshi panes are all 44 columns
# (gunshi_design_209_v5_redesign.yaml M-3) — this is the exact width that
# went undetected for 8 days.
@test "T-MODAL-01: agent_is_busy_check reports busy when the modal footer is split by the APP (absolute positioning) at width 44" {
    local name="tmodal01_${SESSION_SUFFIX}"
    tmux new-session -d -s "$name" -x 44 -y 12 "$(split_modal_footer_cmd 44)"
    sleep 0.15
    run agent_is_busy_check "$name" claude
    [ "$status" -eq 0 ]
}

# T-MODAL-02: width sweep 39-50 — the measured blind band (M-2: the footer
# is 49 columns wide, so pane widths 39-50 are exactly where it splits
# without fitting on one row). Every width in this band must report busy;
# this is the regression guard for the blind band itself, mirroring V-3's
# role for the (already-working) -J rejoin case.
@test "T-MODAL-02: agent_is_busy_check reports busy across the measured blind band (widths 39-50) for an APP-side split modal footer" {
    local fail_widths=()
    local w name rc
    for w in $(seq 39 50); do
        name="tmodal02_w${w}_${SESSION_SUFFIX}"
        tmux new-session -d -s "$name" -x "$w" -y 12 "$(split_modal_footer_cmd "$w")"
        sleep 0.15
        # `if` guards the call so a nonzero (idle) result doesn't trip bats'
        # errexit and abort the loop before we can record which width failed.
        if agent_is_busy_check "$name" claude; then
            rc=0
        else
            rc=$?
        fi
        if [ "$rc" -ne 0 ]; then
            fail_widths+=("${w}:rc=${rc}")
        fi
    done
    if [ "${#fail_widths[@]}" -ne 0 ]; then
        echo "widths that did NOT report busy: ${fail_widths[*]}"
        false
    fi
}

# T-MODAL-03: footer residue lingers ABOVE a blank line, with a bare idle
# prompt as the true bottom line (fixture_matrix f7 in
# gunshi_design_209_v5_redesign.yaml). This is the regression guard for
# "末尾ブロック限定" (design要点2): scanning all 5 lines instead of only the
# bottom contiguous block would make this false-busy.
@test "T-MODAL-03: agent_is_busy_check stays idle when modal-footer residue sits above a blank line, with a bare prompt as the true bottom line" {
    local name="tmodal03_${SESSION_SUFFIX}"
    tmux new-session -d -s "$name" -x 65 -y 12 \
        "printf '\033[2J\033[1;1HEnter to select \xc2\xb7 \xe2\x86\x91/\xe2\x86\x93 to navigate \xc2\xb7 Esc to\033[2;1Hcancel\033[4;1H\xe2\x9d\xaf'; sleep 15"
    sleep 0.15
    run agent_is_busy_check "$name" claude
    [ "$status" -eq 1 ]
}

# T-MODAL-04: an orphaned footer fragment ("cancel", with its "Enter to
# select..." prefix already scrolled out of the captured 5-line tail) sits
# directly ADJACENT (no blank line) to the true bottom line, which is
# ordinary non-prompt, non-busy text (fixture_matrix f9). The bottom block
# ends up as the concatenation of both lines — this must NOT match any
# anchor, because the orphaned fragment alone doesn't contain "enter to
# select", "to navigate", or "↑/↓". Guards against a future block-joining
# implementation (e.g. R-D″) that reconstructs logical lines by adjacency
# and could blur this boundary (gunshi_design_209_v5_redesign.yaml risk R-4).
@test "T-MODAL-04: agent_is_busy_check stays idle when an orphaned footer fragment is adjacent to a non-prompt bottom line" {
    local name="tmodal04_${SESSION_SUFFIX}"
    tmux new-session -d -s "$name" -x 65 -y 12 \
        "printf '\033[2J\033[1;1Hcancel\033[2;1Hsome other status text'; sleep 15"
    sleep 0.15
    run agent_is_busy_check "$name" claude
    [ "$status" -eq 1 ]
}
