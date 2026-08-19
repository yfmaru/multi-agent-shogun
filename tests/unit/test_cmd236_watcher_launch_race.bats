#!/usr/bin/env bats
# test_cmd236_watcher_launch_race.bats — cmd_236
#
# 背景: 2026-08-19未明、inbox_watcherの起こし手が2つ存在した——
#   (a) shutsujin_departure.sh STEP 6.6: 直接nohup（排他制御なし）
#   (b) scripts/watcher_supervisor.sh の start_watcher_if_missing():
#       flockで排他
# (a)は(b)のlockを一切取らぬため、起動時刻が競合すると同一paneへ
# 二つのwatcherが同時にsend-keysを撃ち、軍師のCLIを実際に殺した
# （cmd_222・cmd_234が一夜止まった）。
#
# 是正方針: 「両者が同じ排他を共有する」——shutsujin_departure.sh
# STEP 6.6を、watcher_supervisor.shの start_watcher_if_missing()（唯一の
# 実装）をsourceして呼ぶ形へ差し替えた。本ファイルは以下を検証する:
#   T-RACE-001: 構造的固定——shutsujin_departure.sh STEP 6.6はもはや
#     scripts/inbox_watcher.sh を直接nohupしておらず、
#     watcher_supervisor.sh を source して start_watcher_if_missing() を
#     呼んでいる（=唯一の実装を両方の起こし手が呼ぶ、という設計の
#     静的な裏付け）
#   T-RACE-002: 実測——「両方の起こし手」を real flock で同時に走らせても
#     （生きたtmuxペイン・生きたwatcherプロセスは一切使わぬfixtureで）、
#     launchされるwatcherは高々1本に留まる（flockによる排他が実際に
#     効いていることの実証。AC2）
#   T-RACE-003: pkillの自己マッチ罠是正（角括弧分割）が
#     shutsujin_departure.sh に適用されていること（CI-GATE-1相当）
#   T-RACE-004: watcher_supervisor.sh は source されても無限ループへ
#     入らない（source時のBASH_SOURCE guardが機能している）
#
# 自己参照テストの禁: 本ファイルのいかなるテストも、現に走っている
# watcher・生きたエージェントpaneを検査対象にしない。T-RACE-002の
# 「同時実行」は、使い捨てのbashサブプロセス2つ（flockでの競合のみを
# 見るfixture）で表現し、Test Rules 5に従いテスト内で完結・自己終了する
# （バックグラウンドジョブはbats のサブシェル終了と共に終わる短命な
# ものであり、`wait`で全て回収してから終了する）。

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SHUTSUJIN_SCRIPT="$PROJECT_ROOT/shutsujin_departure.sh"
SUPERVISOR_SCRIPT="$PROJECT_ROOT/scripts/watcher_supervisor.sh"

setup() {
    TEST_TMP="$(mktemp -d)"
    mkdir -p "$TEST_TMP/scripts" "$TEST_TMP/queue/inbox" "$TEST_TMP/logs"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# ---------------------------------------------------------------------------
# T-RACE-001: shutsujin_departure.sh STEP 6.6 は watcher_supervisor.sh を
# source し、start_watcher_if_missing() を経由してのみ起動する
# （scripts/inbox_watcher.sh への直接nohupが残っていないこと）。
# ---------------------------------------------------------------------------
@test "T-RACE-001: STEP 6.6 sources watcher_supervisor.sh and calls start_watcher_if_missing (no direct nohup)" {
    grep -q 'source "\$SCRIPT_DIR/scripts/watcher_supervisor.sh"' "$SHUTSUJIN_SCRIPT"

    # STEP 6.6のブロック（STEP 6.6の見出しからSTEP 6.6.5の見出しの手前まで）
    # を切り出し、その範囲内に start_watcher_if_missing 呼び出しが
    # shogun/karo/ashigaru/gunshiの4種とも存在し、かつ
    # "scripts/inbox_watcher.sh"への直接nohup（"nohup ... inbox_watcher.sh"
    # の形）が一切残っていないことを確認する。
    # 境界判定は「見出し行そのもの」（行頭が "    # STEP 6.6.5:"）に限定する。
    # 見出し文字列への言及（コメント内の相互参照等）まで拾うと、本文中で
    # "STEP 6.6.5" と書いた説明コメントに反応して境界が早期に閉じてしまう。
    local block
    block="$(awk '/^    # STEP 6\.6: inbox_watcher起動/{p=1} /^    # STEP 6\.6\.5:/{p=0} p{print}' "$SHUTSUJIN_SCRIPT")"

    echo "$block" | grep -q 'start_watcher_if_missing "shogun"'
    echo "$block" | grep -q 'start_watcher_if_missing "karo"'
    echo "$block" | grep -q 'start_watcher_if_missing "ashigaru\${i}"'
    echo "$block" | grep -q 'start_watcher_if_missing "gunshi"'

    ! echo "$block" | grep -q 'nohup.*scripts/inbox_watcher\.sh'
}

# ---------------------------------------------------------------------------
# T-RACE-002 (AC2・本cmdの肝): 「両方の起こし手」——shutsujin側の新実装が
# 呼ぶ経路と、watcher_supervisor側の既存実装が呼ぶ経路——が同時に同じ
# agent+paneへ向けて start_watcher_if_missing() を呼んでも、launchされる
# watcherは高々1本に留まる。両呼び出しは実プロセス2本として真に並行に
# 走らせ、排他は（モックせぬ）実 flock に委ねる。
#
# nohup・tmux・pgrepはモックする（生きたtmuxペイン・生きたwatcher
# プロセスを使わぬための決め打ちfixtureであり、検証したい性質は
# 「flockが2本の同時呼び出しのうち1本しか本体へ進ませぬこと」の一点)。
# pgrepは「既存watcher無し」を返す（=各呼び出し内で唯一分岐するのは
# flockの成否のみ、という単純化）。
# ---------------------------------------------------------------------------
@test "T-RACE-002: two concurrent callers sharing start_watcher_if_missing launch at most one watcher" {
    local agent="cmd236race_$$"
    local pane="faketest:0.0"
    local lockfile="/tmp/shogun_watcher_start_${agent}.lock"
    local launched_log="$TEST_TMP/launched.log"
    rm -f "$lockfile"

    # 呼び出し1回分を実行する子スクリプト。実プロセスとして2本
    # 並行起動するための土台（flockの効果を「同一シェル内の関数呼び出し
    # 2回」ではなく真の並行プロセスで検証するため）。値はすべて環境変数
    # 経由で渡す（quoted heredocゆえエスケープの罠が無い）。
    cat > "$TEST_TMP/caller.sh" << 'CALLER'
#!/usr/bin/env bash
set -euo pipefail
pane_exists() { return 0; }
ensure_inbox_file() { :; }
pgrep() { return 1; }
tmux() { echo "codex"; }
nohup() { echo "launched by $$" >> "$LAUNCHED_LOG"; }

eval "$(
    awk '/^start_watcher_if_missing\(\)/{p=1} p{print} /^\}$/{if(p){p=0}}' \
        "$SUPERVISOR_SCRIPT"
)"

start_watcher_if_missing "$AGENT" "$PANE" "$WATCHER_LOG"
CALLER
    chmod +x "$TEST_TMP/caller.sh"

    # 真に同時発火させるため、2本を実プロセスとして並行起動する。
    AGENT="$agent" PANE="$pane" LAUNCHED_LOG="$launched_log" \
        WATCHER_LOG="$TEST_TMP/watcher.log" SUPERVISOR_SCRIPT="$SUPERVISOR_SCRIPT" \
        "$TEST_TMP/caller.sh" &
    pid1=$!
    AGENT="$agent" PANE="$pane" LAUNCHED_LOG="$launched_log" \
        WATCHER_LOG="$TEST_TMP/watcher.log" SUPERVISOR_SCRIPT="$SUPERVISOR_SCRIPT" \
        "$TEST_TMP/caller.sh" &
    pid2=$!

    wait "$pid1"
    wait "$pid2"

    rm -f "$lockfile"

    [ -f "$launched_log" ]
    [ "$(wc -l < "$launched_log")" -eq 1 ]
}

# ---------------------------------------------------------------------------
# T-RACE-003 (CI-GATE-1): pkillの自己マッチ罠是正。shutsujin_departure.sh
# は角括弧分割済みのパターンのみを持ち、無防備な
# pkill -f "inbox_watcher.sh" は残っていない。
# ---------------------------------------------------------------------------
@test "T-RACE-003: pkill against inbox_watcher.sh uses bracket-split to avoid self-match" {
    grep -q 'pkill -f "inbox_watch\[e\]r.sh"' "$SHUTSUJIN_SCRIPT"
    ! grep -qF 'pkill -f "inbox_watcher.sh"' "$SHUTSUJIN_SCRIPT"
}

# ---------------------------------------------------------------------------
# T-RACE-004: watcher_supervisor.sh は source されても無限メインループへ
# 入らない（shutsujin_departure.shがsourceする前提の安全条件）。有界
# timeoutで検証し、抜けられなければタイムアウトさせてFAILとする。
# ---------------------------------------------------------------------------
@test "T-RACE-004: sourcing watcher_supervisor.sh does not enter the infinite main loop" {
    run timeout 10 bash -c "source '$SUPERVISOR_SCRIPT'; echo SOURCED_RETURNED"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SOURCED_RETURNED"* ]]
}

# ---------------------------------------------------------------------------
# T-RACE-005: 直接実行時（従来どおりの起動経路）は引き続きmainループへ
# 入る——--print-watchersの即時終了パスで、直接実行の分岐自体は生きて
# いることを確認する（本cmdでガードを追加した副作用でSTEP 6.6.5の
# 直接起動が壊れていないことの回帰）。
# ---------------------------------------------------------------------------
@test "T-RACE-005: direct execution still honors --print-watchers (guard did not break direct-exec path)" {
    run timeout 10 bash "$SUPERVISOR_SCRIPT" --print-watchers
    [ "$status" -eq 0 ]
    [[ "$output" == *"shogun"* ]]
    [[ "$output" == *"karo"* ]]
}
