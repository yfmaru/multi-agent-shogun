#!/usr/bin/env bats
# test_agent_id_resolve.bats — cmd_217 design_1 AGENT_ID_RESOLVE_LADDER
#
# 設計原本: queue/reports/gunshi_report.yaml design_1_agent_id_resolution
# 対象: lib/agent_id_resolve.sh（scripts/user_prompt_submit_hook.sh から
# source される）。関数を直接呼べるよう、無条件 exit 0 を持つhook本体
# ではなく、このライブラリを対象にテストする。
#
# テスト構成:
#   T-A1: TMUX_PANE を unset し、プロセス系譜のみで agent_id が解決される
#   T-A2: TMUX_PANE が誤った pane を指す場合、L1 が誤答を返す
#         （既知の限界。誤答時の挙動を記録する）
#   T-A3: /proc/<pid>/stat の第4フィールドではなく /proc/<pid>/status の
#         PPid を使っていること（構造検査 — comm欄の空白/括弧でずれる罠）
#   T-A4: 系譜に pane_pid が一つも現れない場合、L2 が黙って失敗し
#         L3（session_id対応表）へ落ち、最終的に解決できなければ失敗を返す
#   T-A5: 系譜遡上に上限段数とループ検出があること（構造検査）
#   T-A1-dynamic (cmd_217 QC是正 F-E): T-A1は $$ （呼び出し元シェル自身）
#          がpane_pidに一致し1段目で当たって終わるため、/proc/<pid>/status
#          を読んで親を辿る部分が一度も走らぬ。子シェルを2重に起こし
#          （3つのpid: 孫→子→本体）、本体だけをpane_pidに置くことで
#          実際の多段/proc遡上を走らせる
#   T-SS-L3-1: session_start_hook.sh が stdin の session_id から対応表を書く
#   T-SS-L3-2: session_start_hook.sh は stdin が空/不正JSONでも exit 0

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
LADDER_LIB="$SCRIPT_DIR/lib/agent_id_resolve.sh"
SESSION_START_HOOK="$SCRIPT_DIR/scripts/session_start_hook.sh"

setup_file() {
    [ -f "$LADDER_LIB" ] || return 1
    [ -f "$SESSION_START_HOOK" ] || return 1
}

setup() {
    export IDLE_FLAG_DIR="$(mktemp -d "$BATS_TMPDIR/agent_id_resolve_test.XXXXXX")"
}

teardown() {
    rm -rf "$IDLE_FLAG_DIR"
}

# ─── T-A1: TMUX_PANE unset → L2 (process ancestry) resolves ───

@test "T-A1: resolve_agent_id_ladder resolves via L2 (process ancestry) when TMUX_PANE is unset" {
    run bash -c "
        unset TMUX_PANE
        tmux() {
            if echo \"\$*\" | grep -q 'list-panes'; then
                echo \"\$\$ ladderagent\"
                return 0
            fi
            return 1
        }
        timeout() { shift; \"\$@\"; }
        export -f tmux timeout
        source '$LADDER_LIB'
        resolve_agent_id_ladder ''
        echo \"AGENT=\$RESOLVED_AGENT_ID VIA=\$RESOLVED_VIA\"
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "AGENT=ladderagent VIA=l2" \
        || { echo "expected L2 resolution; output: $output"; false; }
}

# ─── T-A2: TMUX_PANE points at the wrong pane → L1 returns the wrong
#     answer (documented known limitation, not a bug to fix here) ───

@test "T-A2: resolve_agent_id_ladder trusts whatever TMUX_PANE/display-message says, even if wrong (known limitation)" {
    run bash -c "
        tmux() {
            if echo \"\$*\" | grep -q display-message; then
                echo 'wrongagent'
                return 0
            fi
            return 1
        }
        export -f tmux
        export TMUX_PANE='some:0.0'
        source '$LADDER_LIB'
        resolve_agent_id_ladder ''
        echo \"AGENT=\$RESOLVED_AGENT_ID VIA=\$RESOLVED_VIA\"
    "
    [ "$status" -eq 0 ]
    # L1 is tried first and is trusted as-is — no cross-check against L2/L3
    # exists (gunshi_report.yaml design_1: "本質は順序ではなくL1を単独の
    # 依存にしないこと", not "L1の答えを検証すること").
    echo "$output" | grep -q "AGENT=wrongagent VIA=l1" \
        || { echo "expected L1's (wrong) answer to be trusted as-is; output: $output"; false; }
}

# ─── T-A3 (structural, AC-I3): PPid comes from /proc/<pid>/status, never
#     from an awk field-4 parse of /proc/<pid>/stat ───

@test "T-A3: resolve_agent_id_l2 reads PPid from /proc/<pid>/status, not stat field 4" {
    grep -qF "awk '/^PPid:/{print \$2}' \"/proc/\${pid}/status\"" "$LADDER_LIB" \
        || { echo "expected the PPid-from-status line to be present"; false; }
    # M2 guard: a regression back to the field-4 /proc/<pid>/stat shortcut
    # must not be present anywhere in the ladder.
    ! grep -qF '/proc/${pid}/stat"' "$LADDER_LIB" \
        || { echo "regression: /proc/<pid>/stat field parsing reintroduced (comm-with-spaces trap)"; false; }
}

# ─── T-A4: no pane_pid anywhere in the ancestry → L2 fails silently,
#     falls through to L3, and to total failure if L3 also misses ───

@test "T-A4: resolve_agent_id_ladder falls through L2→L3→failure when nothing matches" {
    run bash -c "
        unset TMUX_PANE
        tmux() {
            if echo \"\$*\" | grep -q 'list-panes'; then
                echo '999999 someotheragent'
                return 0
            fi
            return 1
        }
        timeout() { shift; \"\$@\"; }
        export -f tmux timeout
        source '$LADDER_LIB'
        if resolve_agent_id_ladder 'no-such-session'; then
            echo \"UNEXPECTED_SUCCESS AGENT=\$RESOLVED_AGENT_ID\"
        else
            echo \"EXPECTED_FAILURE AGENT=[\$RESOLVED_AGENT_ID] VIA=[\$RESOLVED_VIA]\"
        fi
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "EXPECTED_FAILURE AGENT=\[\] VIA=\[\]" \
        || { echo "expected ladder to fail cleanly (rc=1, both vars empty) when no rung matches; output: $output"; false; }
}

@test "T-A4b: resolve_agent_id_ladder resolves via L3 when L2 misses but the session map file exists" {
    echo "l3agent" > "$IDLE_FLAG_DIR/shogun_session_sess-xyz"
    run bash -c "
        unset TMUX_PANE
        tmux() {
            if echo \"\$*\" | grep -q 'list-panes'; then
                echo '999999 someotheragent'
                return 0
            fi
            return 1
        }
        timeout() { shift; \"\$@\"; }
        export -f tmux timeout
        export IDLE_FLAG_DIR='$IDLE_FLAG_DIR'
        source '$LADDER_LIB'
        resolve_agent_id_ladder 'sess-xyz'
        echo \"AGENT=\$RESOLVED_AGENT_ID VIA=\$RESOLVED_VIA\"
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "AGENT=l3agent VIA=l3" \
        || { echo "expected L3 resolution via session map; output: $output"; false; }
}

# ─── T-A5 (structural, M3 guard): ancestry walk has a hop cap AND a
#     revisited-pid loop guard ───

@test "T-A5: resolve_agent_id_l2 has both a hop-count cap and a loop guard against revisiting the same pid" {
    grep -qF '"$hop" -lt 10' "$LADDER_LIB" \
        || { echo "expected a hop-count cap (10 rungs) in resolve_agent_id_l2"; false; }
    grep -qF 'seen[$pid]:-' "$LADDER_LIB" \
        || { echo "expected a seen[pid] loop guard in resolve_agent_id_l2"; false; }
}

# ─── T-A1-dynamic (cmd_217 QC是正 F-E): real multi-hop /proc ancestry
#     walk, not the degenerate 1-hop case T-A1 exercises (mock list-panes
#     returns $$ itself as pane_pid, so the /proc/<pid>/status read never
#     runs). AGENT_ID_RESOLVE_L2_START_PID lets the start pid be a real
#     grandchild — the walk must climb two real PPid hops to reach the
#     pane_pid, exercising the /proc read gunshi flagged as untested.
#
#     macOS runner note: macOS has no /proc at all (unlike test_task_
#     complete.bats's EXP-002/004, which reproduce a *missing-permission*
#     /proc that Linux still has). On Darwin the PPid read is
#     unconditionally impossible, so resolve_agent_id_l2 cannot climb
#     past its own start pid there — assert THAT as the correct Darwin
#     behavior (mirrors the repo's existing uname-branch convention)
#     rather than skipping (production runs on WSL2/Linux; the ladder's
#     L1 still covers macOS in practice). ───

@test "T-A1-dynamic: resolve_agent_id_l2 climbs real multi-hop /proc ancestry (grandchild start_pid → parent → grandparent pane_pid)" {
    local script="$IDLE_FLAG_DIR/l2_dynamic.sh"
    cat > "$script" << SCRIPT
unset TMUX_PANE
outer_pid=\$\$
tmux() {
    if echo "\$*" | grep -q 'list-panes'; then
        echo "\$outer_pid multihopagent"
        return 0
    fi
    return 1
}
timeout() { shift; "\$@"; }
export -f tmux timeout
source '$LADDER_LIB'
(
    (
        export AGENT_ID_RESOLVE_L2_START_PID=\$BASHPID
        if [ "\$AGENT_ID_RESOLVE_L2_START_PID" = "\$outer_pid" ]; then
            echo "SETUP_FAILED_SAME_PID"
            exit 1
        fi
        resolve_agent_id_ladder ''
        echo "AGENT=\$RESOLVED_AGENT_ID VIA=\$RESOLVED_VIA START=\$AGENT_ID_RESOLVE_L2_START_PID TARGET=\$outer_pid"
    )
)
SCRIPT
    run bash "$script"
    [ "$status" -eq 0 ]
    ! echo "$output" | grep -q "SETUP_FAILED_SAME_PID" \
        || { echo "test setup bug: nested subshell BASHPID equals the top-level pid, no real hop exercised"; false; }
    if [ "$(uname -s)" = "Darwin" ]; then
        # macOSには/procが元から無く、PPid読み取りは原理的に不能。
        # ゆえに1段目で当たらねば必ず失敗する——それが正しい挙動。
        echo "$output" | grep -q "AGENT= VIA=" \
            || { echo "expected L2 to fail cleanly on Darwin (no /proc to climb); output: $output"; false; }
    else
        echo "$output" | grep -q "AGENT=multihopagent VIA=l2" \
            || { echo "expected L2 to resolve via a real 2-hop /proc ancestry walk (start_pid != pane_pid); output: $output"; false; }
    fi
}

# ─── AC-I1/T-217-11-style: the hook script itself still honors exit 0
#     even when the ladder library resolves nothing at all ───

@test "T-A-exit0: user_prompt_submit_hook.sh still exits 0 when the ladder library is missing entirely" {
    local hook="$SCRIPT_DIR/scripts/user_prompt_submit_hook.sh"
    [ -f "$hook" ]
    run bash -c "
        unset TMUX_PANE
        # Point at a nonexistent lib path by running from a scratch copy
        # whose sibling lib/ dir does not contain agent_id_resolve.sh.
        TMPROOT=\$(mktemp -d)
        mkdir -p \"\$TMPROOT/scripts\" \"\$TMPROOT/lib\" \"\$TMPROOT/logs\"
        cp '$hook' \"\$TMPROOT/scripts/user_prompt_submit_hook.sh\"
        IDLE_FLAG_DIR='$IDLE_FLAG_DIR' bash \"\$TMPROOT/scripts/user_prompt_submit_hook.sh\" < /dev/null
        rc=\$?
        rm -rf \"\$TMPROOT\"
        exit \$rc
    "
    [ "$status" -eq 0 ]
}

# ─── T-SS-L3-1: session_start_hook.sh writes the session_id→agent_id map
#     that resolve_agent_id_l3() reads (design_1 L3) ───

@test "T-SS-L3-1: session_start_hook.sh writes /tmp/shogun_session_<session_id> from stdin JSON" {
    run bash -c "
        tmux() { echo 'l3writeragent'; return 0; }
        export -f tmux
        export TMUX_PANE='test:0.0'
        echo '{\"session_id\":\"sess-l3test\"}' | IDLE_FLAG_DIR='$IDLE_FLAG_DIR' bash '$SESSION_START_HOOK' > /dev/null
    "
    [ "$status" -eq 0 ]
    [ -f "$IDLE_FLAG_DIR/shogun_session_sess-l3test" ] \
        || { echo "expected the session map file to be written"; false; }
    [ "$(cat "$IDLE_FLAG_DIR/shogun_session_sess-l3test")" = "l3writeragent" ] \
        || { echo "expected the map file to contain the resolved agent_id"; false; }
}

# ─── T-SS-L3-2: exit 0 even with empty/malformed stdin (contract: never
#     break Session Start on a bad L3 write) ───

@test "T-SS-L3-2: session_start_hook.sh exits 0 with empty stdin" {
    run bash -c "
        tmux() { echo 'l3emptyagent'; return 0; }
        export -f tmux
        export TMUX_PANE='test:0.0'
        IDLE_FLAG_DIR='$IDLE_FLAG_DIR' bash '$SESSION_START_HOOK' < /dev/null > /dev/null
    "
    [ "$status" -eq 0 ]
}

@test "T-SS-L3-3: session_start_hook.sh exits 0 with malformed JSON on stdin (no map file written)" {
    run bash -c "
        tmux() { echo 'l3badjsonagent'; return 0; }
        export -f tmux
        export TMUX_PANE='test:0.0'
        echo 'not valid json {{{' | IDLE_FLAG_DIR='$IDLE_FLAG_DIR' bash '$SESSION_START_HOOK' > /dev/null
    "
    [ "$status" -eq 0 ]
    ! ls "$IDLE_FLAG_DIR"/shogun_session_* &>/dev/null \
        || { echo "expected no session map file to be written from malformed JSON"; false; }
}
