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
    TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/stall_livepane_test.XXXXXX")"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
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

# T-MODAL-02: width sweep 37-50 — 2026-08-06's measurement found a
# 51-column footer form (with a 2-column leading indent), and 2026-08-08's
# found a 49-column form; sweeping 37-50 covers the true blind band for
# both observed forms. Every width in this band must report busy; this is
# the regression guard for the blind band itself, mirroring V-3's role for
# the (already-working) -J rejoin case.
@test "T-MODAL-02: agent_is_busy_check reports busy across the measured blind band (widths 37-50) for an APP-side split modal footer" {
    local fail_widths=()
    local w name rc
    for w in $(seq 37 50); do
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

# ═══════════════════════════════════════════════════════════════════════
# cmd_219 STALL_AWAITING_INPUT_GATE (T-WAIT-L01/L02/L03)
# queue/reports/gunshi_design_219_stall_wait_budget_conflict.yaml §9
#
# Unlike the mocked-tmux tests/unit/test_stall_detect.bats (TC-WAIT-*),
# these run the REAL attempt_stall_recovery()/is_stalled_pane() against a
# REAL tmux pane, and prove the negative claim ("Escape was never sent")
# by checking whether the byte actually arrived at the pane's stdin — not
# by grepping a log line. The pane's own foreground process is
# `read -rsn2 -t N` (raw, silent, exactly 2 bytes — the width of the
# `Escape Escape` the ladder sends): this reads directly off the pty
# without needing canonical-mode newline framing, so an injected ESC byte
# is observed the instant it arrives, and a timeout writes a distinct
# "EMPTY" sentinel to the keylog instead.
#
# stall_after_sec is shortened via a per-test STALL_POLICY_SETTINGS file
# (CI cannot afford the real 900s default) — the causal structure (frozen
# hash → gate → inject-or-not) is identical at any threshold; T-WAIT-L01M
# (manual, not in CI) repeats T-WAIT-L01's causal claim at the real
# threshold once to close the "passed because it was shortened" doubt.
# ═══════════════════════════════════════════════════════════════════════

# write_short_stall_settings <path> [nonmodal_recovery_level]
write_short_stall_settings() {
    local path="$1" nonmodal="${2:-none}"
    cat > "$path" <<EOF
stall_policy:
  enabled: true
  stall_after_sec: 2
  hash_sample_interval_sec: 1
  stall_retry_cooldown_sec: 600
  recovery_level: escape_only
  unknown_policy: escape_only
  nonmodal_recovery_level: ${nonmodal}
EOF
}

# ─── T-WAIT-L01 (AC1): non-modal frozen busy screen → Escape byte never
#     reaches the pane ───

@test "T-WAIT-L01: awaiting_input=false real pane — Escape byte never reaches the pane (AC1)" {
    local name="twaitl01_${SESSION_SUFFIX}"
    local keylog="$TEST_TMPDIR/keylog"
    local settings="$TEST_TMPDIR/settings.yaml"
    write_short_stall_settings "$settings" "none"

    # Static, non-modal, busy-looking text (generic 'esc to' marker, no
    # dialog anchor) — a frozen "画面出力を伴わぬ" screen. read -rsn2 -t5
    # reads exactly 2 raw bytes (the width of "Escape Escape") without
    # waiting for a newline; on timeout it writes the EMPTY sentinel.
    tmux new-session -d -s "$name" -x 60 -y 12 \
        "printf '%s' 'frozen busy screen esc to interrupt'; IFS= read -rsn2 -t5 seq; printf '%q' \"\${seq:-EMPTY}\" > '$keylog'; sleep 1"
    sleep 0.2

    run bash -c "
        export __INBOX_WATCHER_TESTING__=1
        export SCRIPT_DIR='$PROJECT_ROOT'
        export STALL_POLICY_SETTINGS='$settings'
        usage_limit_state() { echo ok; }
        export -f usage_limit_state
        source '$PROJECT_ROOT/scripts/inbox_watcher.sh'
        AGENT_ID='ashigaru9'
        PANE_TARGET='$name'
        CLI_TYPE='claude'
        capture_now=\$(timeout 2 tmux capture-pane -t \"\$PANE_TARGET\" -p 2>/dev/null)
        h=\$(printf '%s' \"\$capture_now\" | cksum | awk '{print \$1}')
        STALL_HASH=\"\$h\"
        STALL_HASH_SINCE=\$(( \$(date +%s) - 5 ))
        attempt_stall_recovery
    "
    [ "$status" -eq 0 ]

    local waited=0
    while [ ! -s "$keylog" ] && [ "$waited" -lt 8 ]; do
        sleep 1
        waited=$((waited + 1))
    done
    [ -s "$keylog" ] || { echo "keylog never populated"; false; }
    grep -qF '\E' "$keylog" \
        && { echo "ESC byte reached the pane — gate failed to block it"; cat "$keylog"; false; }
    grep -q "EMPTY" "$keylog" \
        || { echo "expected the EMPTY timeout sentinel"; cat "$keylog"; false; }
}

# ─── T-WAIT-L02 (AC2): modal footer → Escape bytes DO reach the pane ───

@test "T-WAIT-L02: awaiting_input=true real pane (modal footer) — Escape bytes reach the pane (AC2)" {
    local name="twaitl02_${SESSION_SUFFIX}"
    local keylog="$TEST_TMPDIR/keylog"
    local settings="$TEST_TMPDIR/settings.yaml"
    write_short_stall_settings "$settings" "none"

    tmux new-session -d -s "$name" -x 60 -y 12 \
        "printf '%s' '$MODAL_FOOTER'; IFS= read -rsn2 -t5 seq; printf '%q' \"\${seq:-EMPTY}\" > '$keylog'; sleep 1"
    sleep 0.2

    run bash -c "
        export __INBOX_WATCHER_TESTING__=1
        export SCRIPT_DIR='$PROJECT_ROOT'
        export STALL_POLICY_SETTINGS='$settings'
        usage_limit_state() { echo ok; }
        export -f usage_limit_state
        source '$PROJECT_ROOT/scripts/inbox_watcher.sh'
        AGENT_ID='ashigaru9'
        PANE_TARGET='$name'
        CLI_TYPE='claude'
        capture_now=\$(timeout 2 tmux capture-pane -t \"\$PANE_TARGET\" -p 2>/dev/null)
        h=\$(printf '%s' \"\$capture_now\" | cksum | awk '{print \$1}')
        STALL_HASH=\"\$h\"
        STALL_HASH_SINCE=\$(( \$(date +%s) - 5 ))
        attempt_stall_recovery
    "
    [ "$status" -eq 0 ]

    local waited=0
    while [ ! -s "$keylog" ] && [ "$waited" -lt 8 ]; do
        sleep 1
        waited=$((waited + 1))
    done
    [ -s "$keylog" ] || { echo "keylog never populated"; false; }
    grep -q "EMPTY" "$keylog" \
        && { echo "expected Escape bytes to reach the pane, but read() timed out instead"; cat "$keylog"; false; }
    grep -qF '\E' "$keylog" \
        || { echo "expected the ESC byte representation (\\E) in the keylog"; cat "$keylog"; false; }
}

# ─── T-WAIT-L03: per-second counter (real busy screen mimic) → is_stalled_pane
#     never latches to true, no matter how long it runs past the threshold
#     (前提check実測2 regression guard) ───

@test "T-WAIT-L03: is_stalled_pane never fires while a per-second counter keeps the busy screen changing" {
    local name="twaitl03_${SESSION_SUFFIX}"
    local settings="$TEST_TMPDIR/settings.yaml"
    write_short_stall_settings "$settings" "none"

    tmux new-session -d -s "$name" -x 60 -y 12 \
        "for i in \$(seq 1 8); do printf '\033[2J\033[1;1HWorking (%ss . esc to interrupt)' \"\$i\"; sleep 1; done; sleep 1"
    sleep 0.3

    run bash -c "
        export __INBOX_WATCHER_TESTING__=1
        export SCRIPT_DIR='$PROJECT_ROOT'
        export STALL_POLICY_SETTINGS='$settings'
        usage_limit_state() { echo ok; }
        export -f usage_limit_state
        source '$PROJECT_ROOT/scripts/inbox_watcher.sh'
        AGENT_ID='ashigaru9'
        PANE_TARGET='$name'
        CLI_TYPE='claude'
        rc_all=0
        for i in \$(seq 1 6); do
            if is_stalled_pane; then rc_all=1; fi
            sleep 1
        done
        echo \"rc_all=\$rc_all\"
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "rc_all=0" \
        || { echo "is_stalled_pane latched true on a screen that keeps changing"; echo "$output"; false; }
}
