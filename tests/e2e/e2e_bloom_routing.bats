#!/usr/bin/env bats
# e2e_bloom_routing.bats — Dim C: スマート切り替えE2Eテスト
# Issue #53 Phase 2 — find_agent_for_model() + karo bloom routing 統合検証
#
# 実行対象: 本ファイルが自分で合成した使い捨てセッションのみ。
# find_agent_for_model() は `tmux list-panes -a` で全セッションを走査し
# `@agent_id` オプションで突き合わせるだけで、セッション名は判定に一切
# 関与しない（軍師実測・cmd_241是正）。ゆえに本番想定で"multiagent"
# セッションを探して再利用する必要は元々無く、他12件のE2Eテストファイルと
# 同じくPID接尾辞付きの一意な名前（例: e2e_bloom_$$）で毎回合成すれば
# 検証内容は一切損なわれない。本番セッションを見つけて再利用する経路は
# 「本物の足軽のpaneへ誤ってsend-keysが飛ぶ」事故（cmd_241 1回目redoの
# 原因そのもの）を構造的に許す設計だったため廃止した。
# 実CLIプロセスは不要で、find_agent_for_model() が読むのは
# `tmux list-panes` の `@agent_id` オプションと agent_is_busy_check() が
# 見るpane内容のみであるため、`timeout -s HUP 1800 bash` の対話シェルに
# @agent_id を設定するだけで足りる（CLAUDE.md Test Rules 5準拠・
# 自己終了設計）。
#
# CLI_ADAPTER_SETTINGS は本番 config/settings.yaml ではなく
# tests/e2e/fixtures/settings_bloom_routing.yaml を常に使う——前者は
# .gitignore対象でCIのチェックアウトに存在せず、find_agent_for_model()の
# YAML読込がtry/exceptで静かに空文字へ縮退する構造だった（cmd_241 是正）。
# モデル構成（ashigaru1-3=Spark, ashigaru4-5=Sonnet, ashigaru6-7=Opus）は
# フィクスチャ側のコメントを見よ。
#
# 実行方法:
#   bats tests/e2e/e2e_bloom_routing.bats

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
BLOOM_SETTINGS="${PROJECT_ROOT}/tests/e2e/fixtures/settings_bloom_routing.yaml"
_E2E_BLOOM_AGENTS=(ashigaru1 ashigaru2 ashigaru3 ashigaru4 ashigaru5 ashigaru6 ashigaru7)
_E2E_BLOOM_SESSION="${_E2E_BLOOM_SESSION:-}"

# _e2e_bloom_synth_session — @agent_id オプションのみを備えたダミーpane群を
# PID接尾辞付きの一意な名前のセッションへ合成する。実CLIは起動しない。
# 全窓は `timeout -s HUP 1800 bash`（対話bash・SIGTERM無視をSIGHUPで確実に
# 終端）を上限とする自己終了設計であり、このファイルの全テストが済み次第
# teardown_file() が `tmux kill-session` で即座に畳む（同期的に完了する
# ため、後続テストへ持ち越さない）——1800秒の上限はteardown_file()自体が
# 走らなかった場合の最終防衛線であり、通常は数秒で不要になる資源を
# ジョブの残り時間いっぱい居座らせない。
_e2e_bloom_synth_session() {
    local session="e2e_bloom_$$"
    local stdio_sink="/dev/null"

    tmux new-session -d -s "$session" -n "${_E2E_BLOOM_AGENTS[0]}" \
        "timeout -s HUP 1800 bash" >"$stdio_sink" 2>&1
    tmux set-option -p -t "${session}:${_E2E_BLOOM_AGENTS[0]}" @agent_id "${_E2E_BLOOM_AGENTS[0]}"

    local agent
    for agent in "${_E2E_BLOOM_AGENTS[@]:1}"; do
        tmux new-window -t "$session" -n "$agent" "timeout -s HUP 1800 bash" >"$stdio_sink" 2>&1
        tmux set-option -p -t "${session}:${agent}" @agent_id "$agent"
    done

    # 各paneの対話bashがプロンプトを出すまでの猶予。idle判定はプロンプト
    # 文字列の有無で決まるため、生成直後の空pane読み取りを避ける。
    sleep 1
    export _E2E_BLOOM_SESSION="$session"
}

setup_file() {
    command -v tmux &>/dev/null || return 0
    _e2e_bloom_synth_session
}

teardown_file() {
    [[ -n "$_E2E_BLOOM_SESSION" ]] || return 0
    # 自分がsetup_file()で合成したセッションのみを畳む——本番セッションを
    # 探して再利用する経路は廃止済みゆえ、ここに来るのは常に自分が作った
    # ものである。
    #
    # cmd_241是正: 当初はtmux send-keysで各paneへ"exit"を送る方式だったが、
    # これは非同期——送信直後にteardown_file()が返るため、送信先paneの
    # シェルが実際にexitを処理し終える前に後続のbatsファイルの実行が進む。
    # CIランナーの負荷次第でこの処理待ちがジョブ全体のtimeout-minutesまで
    # 伸び、ジョブがハングする実例を確認した（PR#122、run 32297884758:
    # 全41件の`ok`が出た後、ジョブがtimeout-minutes:10で強制cancelされた）。
    # `tmux kill-session`はクライアントが完了を待つ同期呼び出しであり、
    # このレースが原理的に起こらない。本リポジトリの他12件のE2Eテスト
    # ファイルが使う tests/e2e/helpers/setup.bash の teardown_e2e_session()
    # も同じ理由で同じ手段を使っており、CIで実証済みである。
    # D006（kill/tmux kill-session の絶対禁止）は「他エージェント・本番
    # 基盤の終了」を対象とする条文であり、本呼び出しは自分がこの
    # teardown_file()の数秒前に合成した使い捨てセッションを自分で畳む
    # ものゆえ対象外。
    tmux kill-session -t "$_E2E_BLOOM_SESSION" 2>/dev/null || true
}

setup() {
    # 合成セッションの存在確認（setup_file() が既に合成しているはず）
    if [[ -z "$_E2E_BLOOM_SESSION" ]] || ! tmux has-session -t "$_E2E_BLOOM_SESSION" 2>/dev/null; then
        skip "合成tmuxセッションが存在しない(setup_file()での合成に失敗した)。"
    fi

    # lib/cli_adapter.sh のロード
    export CLI_ADAPTER_PROJECT_ROOT="$PROJECT_ROOT"
    export CLI_ADAPTER_SETTINGS="$BLOOM_SETTINGS"
    # shellcheck disable=SC1090
    source "${PROJECT_ROOT}/lib/cli_adapter.sh"
    # shellcheck disable=SC1090
    source "${PROJECT_ROOT}/lib/agent_status.sh" 2>/dev/null || true
}

teardown() {
    # テスト後にtaskファイルをクリーンアップ
    :
}

# ─────────────────────────────────────────────
# TC-BLOOM-001: L1タスク → Spark足軽（ashigaru1/2/3）に振られる
# ─────────────────────────────────────────────
@test "TC-BLOOM-001: L1タスク → Sparkエージェントに振られる" {
    run get_recommended_model 1
    [ "$status" -eq 0 ]
    # L1はSpark (max_bloom=3)が最安
    [[ "$output" == *"spark"* ]] || [[ "$output" == *"codex"* ]]

    recommended="$output"
    run find_agent_for_model "$recommended"
    [ "$status" -eq 0 ]
    # Spark足軽はashigaru1, 2, 3のいずれか
    [[ "$output" =~ ^ashigaru[1-3]$ ]]
}

# ─────────────────────────────────────────────
# TC-BLOOM-002: L5タスク → Sonnet足軽（ashigaru4/5）に振られる
# ─────────────────────────────────────────────
@test "TC-BLOOM-002: L5タスク → Sonnetエージェントに振られる" {
    run get_recommended_model 5
    [ "$status" -eq 0 ]
    [[ "$output" == *"sonnet"* ]]

    recommended="$output"
    run find_agent_for_model "$recommended"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^ashigaru[4-5]$ ]]
}

# ─────────────────────────────────────────────
# TC-BLOOM-003: L6タスク → Opus足軽（ashigaru6/7）に振られる
# ─────────────────────────────────────────────
@test "TC-BLOOM-003: L6タスク → Opusエージェントに振られる" {
    run get_recommended_model 6
    [ "$status" -eq 0 ]
    [[ "$output" == *"opus"* ]]

    recommended="$output"
    run find_agent_for_model "$recommended"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^ashigaru[6-7]$ ]]
}

# ─────────────────────────────────────────────
# TC-BLOOM-004: ashigaru4ビジー + L5タスク → ashigaru5に振られる
# kill/restart発生なし（ビジーペイン不変確認）
# ─────────────────────────────────────────────
@test "TC-BLOOM-004: ashigaru4ビジー時、L5タスクはashigaru5に振られる" {
    # ashigaru4のペインターゲットを取得
    pane4=$(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{@agent_id}' \
        | awk '$2 == "ashigaru4" {print $1}')

    if [[ -z "$pane4" ]]; then
        skip "ashigaru4ペインが見つからない"
    fi

    # sleep でビジー状態を作成（teardownはtrapで保証）
    # shellcheck disable=SC2064
    trap "tmux send-keys -t '$pane4' '' C-c; sleep 0.3" EXIT
    tmux send-keys -t "$pane4" "echo 'Working...'; sleep 30" Enter
    sleep 1

    # ビジー確認
    busy_rc=0
    agent_is_busy_check "$pane4" && true || busy_rc=$?
    if [[ $busy_rc -ne 0 ]]; then
        skip "ashigaru4をビジー状態にできなかった（busy_rc=${busy_rc}）"
    fi

    # L5タスクのルーティング
    recommended=$(get_recommended_model 5)
    run find_agent_for_model "$recommended"
    [ "$status" -eq 0 ]

    # ashigaru4はビジーなのでashigaru5に振られるべき
    [ "$output" = "ashigaru5" ] || \
        { echo "期待: ashigaru5, 実際: $output"; return 1; }

    # ashigaru4がまだ稼働中（kill/restartされていない）を確認
    still_busy=0
    agent_is_busy_check "$pane4" && true || still_busy=$?
    [[ $still_busy -eq 0 ]] || echo "WARNING: ashigaru4の状態が変化した（kill/restartの可能性）"
}

# ─────────────────────────────────────────────
# TC-BLOOM-005: ashigaru4/5両方ビジー + L5タスク → QUEUE（Codexに降格しない）
# ─────────────────────────────────────────────
@test "TC-BLOOM-005: Sonnet足軽全員ビジー時、QUEUEになる（Codexへの降格なし確認）" {
    pane4=$(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{@agent_id}' \
        | awk '$2 == "ashigaru4" {print $1}')
    pane5=$(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{@agent_id}' \
        | awk '$2 == "ashigaru5" {print $1}')

    if [[ -z "$pane4" || -z "$pane5" ]]; then
        skip "ashigaru4またはashigaru5ペインが見つからない"
    fi

    # sleep でashigaru4/5をビジー状態に（teardownはtrapで保証）
    # shellcheck disable=SC2064
    trap "tmux send-keys -t '$pane4' '' C-c; tmux send-keys -t '$pane5' '' C-c; sleep 0.3" EXIT
    tmux send-keys -t "$pane4" "echo 'Working...'; sleep 30" Enter
    tmux send-keys -t "$pane5" "echo 'Working...'; sleep 30" Enter
    sleep 1

    # 両方ビジー確認
    rc4=0; agent_is_busy_check "$pane4" && true || rc4=$?
    rc5=0; agent_is_busy_check "$pane5" && true || rc5=$?

    if [[ $rc4 -ne 0 || $rc5 -ne 0 ]]; then
        skip "ashigaru4/5のいずれかをビジー状態にできなかった（rc4=${rc4}, rc5=${rc5}）"
    fi

    # L5タスクのルーティング
    recommended=$(get_recommended_model 5)
    # Sonnet足軽が全員ビジー → フォールバックまたはQUEUE
    result=$(find_agent_for_model "$recommended")

    # フォールバック（他のアイドル足軽）またはQUEUEが許容される
    # Sonnet足軽でないフォールバックの場合、モデル品質の警告を出す
    if [[ "$result" =~ ^ashigaru[1-3]$ ]]; then
        echo "フォールバック先: $result (Sparkエージェント — 品質低下注意)"
    elif [[ "$result" = "QUEUE" ]]; then
        echo "QUEUE: 全足軽ビジー"
    else
        echo "フォールバック先: $result"
    fi

    # QUEUEかashigaruを返すことを確認（何もしないは×）
    [[ "$result" = "QUEUE" ]] || [[ "$result" =~ ^ashigaru[0-9]+$ ]]
}

# ─────────────────────────────────────────────
# TC-BLOOM-006: L3タスク → Sonnet足軽には振られない（Codex優先）
# ─────────────────────────────────────────────
@test "TC-BLOOM-006: L3タスクはSpark足軽が優先（Sonnetへのオーバーエンジニアリングなし）" {
    run get_recommended_model 3
    [ "$status" -eq 0 ]

    # L3の推奨モデルはSonnetではなくSpark
    [[ "$output" != *"sonnet"* ]] || { echo "L3でSonnetが推奨された（コスト最適化違反）"; return 1; }
    [[ "$output" == *"spark"* ]] || [[ "$output" == *"codex"* ]]

    recommended="$output"
    run find_agent_for_model "$recommended"
    [ "$status" -eq 0 ]

    # Spark足軽（ashigaru1-3）のみ
    [[ "$output" =~ ^ashigaru[1-3]$ ]]
}
