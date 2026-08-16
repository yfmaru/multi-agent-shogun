#!/usr/bin/env bats
# test_user_prompt_submit_hook_liveness.bats — cmd_226 LIVENESS_TRACE_AT_TURN_START
#
# UserPromptSubmit hook 側（ターンの「始まり」）の生存痕跡書き込みを検査する。
# 対をなすstop_hook_inbox.sh側（ターンの「終わり」）の検査は
# tests/unit/test_stop_hook.bats の T-B1〜B4（既存・無改変）。
#
# 設計原本: queue/reports/gunshi_report.yaml
#   gunshi_design_226_turn_start_liveness (§4 implementation_ac AC-1〜7,
#   §5 test_cases TC-UPS-01〜08)。
# AC-8（D-5・baton_watchdog.sh側の任意パッチ）は本PRでは見送った
# （優先度最下位・PR本文に明記）。ゆえにTC-UPS-09も未実装。
#
# テスト構成:
#   TC-UPS-01: 正常系 — transcript_pathがそのまま印へ書かれる
#   TC-UPS-02: 冪等性 — 同じpayloadを2度与えても中身が変わらぬ
#   TC-UPS-03: 差し替え — 既存の印(パスA)がパスBのpayloadで差し替わる。
#              /clear相当の検体を兼ねる（F-4=第2の失敗様態を塞ぐ検査）——
#              「差し替えの検体」と「/clear相当の検体」は意味として別物
#              であり、たまたま同じ一手で両方確かめられているに過ぎない
#              （cmd_226 将軍追加AC-11の趣旨）
#   TC-UPS-04: transcript_path空 — 印を作らず既存の印も壊さぬ
#   TC-UPS-05: 相対パス — 書かぬ。既存の印も壊さぬ（AC-3）
#   TC-UPS-06: AGENT_ID=shogun — 印を作らぬ（AC-4）
#   TC-UPS-07: IDLE_FLAG_DIR書けぬ場所 — exit 0（AC-5。T-217-11cと同型）
#   TC-UPS-08: stdin二度読みの禁止（AC-2）——本ファイルの全テストは
#              stdinを本物のpipe（printf | bash、一度読めば涸れる）で
#              渡している。ここで二度読みを実際に検体化するには、
#              二度目のcatが空を返すことそのものが検体であるため、
#              TC-UPS-01と構造上同一のpipe経由呼び出しで足りる。
#              AC-2が破られれば（stdinを再度catするmutant=M3）本テストも
#              TC-UPS-01も等しく赤くなる。ここでは「AC-2はpipe越しの
#              単一読みを前提にしている」という契約自体に名前を与える。

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
UPS_HOOK="$SCRIPT_DIR/scripts/user_prompt_submit_hook.sh"

setup() {
    [ -f "$UPS_HOOK" ] || return 1
    IDLE_FLAG_DIR="$(mktemp -d "$BATS_TMPDIR/ups_liveness_test.XXXXXX")"
}

teardown() {
    rm -rf "$IDLE_FLAG_DIR"
}

# Helper: run the REAL hook with a mocked tmux (controls L1 agent_id
# resolution) and a given JSON piped through stdin as a genuine
# single-consumption source (a real pipe, not a heredoc/temp file —
# bash heredocs are backed by a regular temp file and would NOT expose
# a double-`cat` regression; a pipe drains for real).
run_ups_hook() {
    local json="$1"
    local agent_id="${2:-ashigaru1}"
    run bash -c "
        tmux() { echo '$agent_id'; return 0; }
        export -f tmux
        export TMUX_PANE='test:0.0'
        export IDLE_FLAG_DIR='$IDLE_FLAG_DIR'
        printf '%s' '$json' | bash '$UPS_HOOK'
    "
}

marker_path() {
    printf '%s' "$IDLE_FLAG_DIR/shogun_transcript_${1:-ashigaru1}"
}

@test "TC-UPS-01: valid transcript_path is written verbatim to the liveness marker" {
    run_ups_hook '{"session_id":"s1","transcript_path":"/fake/sessionA.jsonl"}'
    [ "$status" -eq 0 ] || { echo "expected exit 0, got $status; output: $output"; false; }
    [ -f "$(marker_path)" ] || { echo "expected marker to be created at $(marker_path)"; false; }
    [ "$(cat "$(marker_path)")" = "/fake/sessionA.jsonl" ] \
        || { echo "marker content mismatch: $(cat "$(marker_path)" 2>/dev/null)"; false; }
}

@test "TC-UPS-02: idempotent — same payload given twice leaves marker content unchanged" {
    run_ups_hook '{"session_id":"s1","transcript_path":"/fake/sessionA.jsonl"}'
    [ "$status" -eq 0 ]
    run_ups_hook '{"session_id":"s1","transcript_path":"/fake/sessionA.jsonl"}'
    [ "$status" -eq 0 ]
    [ "$(cat "$(marker_path)")" = "/fake/sessionA.jsonl" ] \
        || { echo "marker content changed across idempotent re-runs: $(cat "$(marker_path)" 2>/dev/null)"; false; }
}

@test "TC-UPS-03: replacement — a new payload (pathB/session s2) overwrites the marker left by pathA/session s1; doubles as a /clear-equivalent specimen for F-4 (second failure mode)" {
    run_ups_hook '{"session_id":"s1","transcript_path":"/fake/sessionA.jsonl"}'
    [ "$status" -eq 0 ]
    [ "$(cat "$(marker_path)")" = "/fake/sessionA.jsonl" ]

    # session_idも変わる — /clear後に新セッションで最初のターンが
    # 始まった場面を模す。F-4は「/clear後、ターンを終えるまで痕跡が
    # 前セッションの凍ったtranscriptを指し続ける」失敗様態であり、
    # ここではその修正（差し替えが即座に起こること）を検体化している。
    run_ups_hook '{"session_id":"s2","transcript_path":"/fake/sessionB.jsonl"}'
    [ "$status" -eq 0 ]
    [ "$(cat "$(marker_path)")" = "/fake/sessionB.jsonl" ] \
        || { echo "expected marker to be replaced with pathB; got: $(cat "$(marker_path)" 2>/dev/null)"; false; }
}

@test "TC-UPS-04: empty transcript_path creates no marker and does not clobber an existing one" {
    printf '/pre/existing.jsonl\n' > "$(marker_path)"
    run_ups_hook '{"session_id":"s1","transcript_path":""}'
    [ "$status" -eq 0 ]
    [ "$(cat "$(marker_path)")" = "/pre/existing.jsonl" ] \
        || { echo "existing marker was clobbered: $(cat "$(marker_path)" 2>/dev/null)"; false; }
}

@test "TC-UPS-05: relative transcript_path is not written and does not clobber an existing marker (AC-3)" {
    printf '/pre/existing.jsonl\n' > "$(marker_path)"
    run_ups_hook '{"session_id":"s1","transcript_path":"relative/path.jsonl"}'
    [ "$status" -eq 0 ]
    [ "$(cat "$(marker_path)")" = "/pre/existing.jsonl" ] \
        || { echo "existing marker was clobbered by a relative path: $(cat "$(marker_path)" 2>/dev/null)"; false; }
}

@test "TC-UPS-06: AGENT_ID=shogun writes no marker (AC-4)" {
    run_ups_hook '{"session_id":"s1","transcript_path":"/fake/sessionA.jsonl"}' "shogun"
    [ "$status" -eq 0 ]
    [ -z "$(find "$IDLE_FLAG_DIR" -name 'shogun_transcript_*' 2>/dev/null)" ] \
        || { echo "expected no shogun_transcript_* marker; found: $(find "$IDLE_FLAG_DIR" -name 'shogun_transcript_*')"; false; }
}

@test "TC-UPS-07: unwritable IDLE_FLAG_DIR still exits 0 (AC-5, same shape as T-217-11c)" {
    run bash -c "
        tmux() { echo 'ashigaru1'; return 0; }
        export -f tmux
        export TMUX_PANE='test:0.0'
        printf '%s' '{\"session_id\":\"s1\",\"transcript_path\":\"/fake/sessionA.jsonl\"}' \
            | IDLE_FLAG_DIR='/nonexistent/no/such/dir' bash '$UPS_HOOK'
    "
    [ "$status" -eq 0 ] || { echo "expected exit 0 even when IDLE_FLAG_DIR is unwritable; got $status. output: $output"; false; }
}

@test "TC-UPS-08: single-consumption stdin — session_id resolution and marker write both succeed reading stdin only once (AC-2)" {
    run_ups_hook '{"session_id":"s1","transcript_path":"/fake/sessionA.jsonl"}'
    [ "$status" -eq 0 ]
    [ -f "$(marker_path)" ] \
        || { echo "marker not created — stdin was likely double-read (a second cat on an already-drained pipe returns empty)"; false; }
    [ "$(cat "$(marker_path)")" = "/fake/sessionA.jsonl" ] \
        || { echo "marker content wrong, suggesting stdin was partially/doubly consumed: $(cat "$(marker_path)" 2>/dev/null)"; false; }
}
