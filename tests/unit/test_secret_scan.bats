#!/usr/bin/env bats
# tests/unit/test_secret_scan.bats
#
# scripts/secret_scan.sh の単体試験（cmd_242 T-5）。
#
# 全specimenは合成（CLAUDE.md「Secrets Discipline」準拠。本物の秘密は
# 一切用いない）。各testは独立した一時gitリポジトリを建て、そこへ検体を
# 書き込んで走査する——本物のqueue/settings.yamlには一切触れない。

load "../test_helper/bats-support/load"
load "../test_helper/bats-assert/load"

setup() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export SECRET_SCAN="$PROJECT_ROOT/scripts/secret_scan.sh"
    export TEST_REPO="$(mktemp -d "${BATS_TMPDIR:-/tmp}/secret_scan_test.XXXXXX")"
    git -C "$TEST_REPO" init -q
    git -C "$TEST_REPO" config user.email "test@example.invalid"
    git -C "$TEST_REPO" config user.name "secret-scan-test"
}

teardown() {
    rm -rf "$TEST_REPO"
}

# <char> <count> 個のcharを連結して返す（vendor形式の長さ要件を厳密に
# 満たすため。手打ちで数えるとズレる）。
repeat() {
    printf "%${2}s" | tr ' ' "$1"
}

# 秘密鍵ブロックのマーカーを2断片へ分けて連結する。1行に完全な
# "-----BEGIN...PRIVATE KEY-----"を書くと、このテストファイル自身が
# 追跡ツリーに乗った時点でsecret_scan.sh --all(CI)がこのソース行に
# 自己反応する(実測: PR#125 CIで検出、cmd_242)。断片単独ではどちらの
# 行もvendor正規表現に一致しない。
pem_marker() {
    local head="-----BEGIN RSA"
    local tail="PRIVATE KEY-----"
    printf '%s %s' "$head" "$tail"
}

# ファイルを書いてgit add（--allモード用。committはしない —
# git ls-filesはindexで足りる）。
add_file() {
    local rel="$1" content="$2"
    mkdir -p "$(dirname "$TEST_REPO/$rel")"
    printf '%s\n' "$content" > "$TEST_REPO/$rel"
    git -C "$TEST_REPO" add "$rel"
}

run_scan_all() {
    # secret_scan.shはcwdからgit rev-parse --show-toplevelでrepo_rootを
    # 決めるため、$TEST_REPOの中で走らせねば本物のプロジェクトツリーを
    # 誤って走査してしまう(実測で踏んだ罠)。
    cd "$TEST_REPO"
    run bash "$SECRET_SCAN" --all --ignore-file "$TEST_REPO/.secretscanignore"
}

# ============================================================
# AC-3: 合成検体10種の検出力（10/10）
# ============================================================

@test "T-SCAN-001: detects AWS access key format" {
    add_file "fixture.txt" "aws_key = AKIA$(repeat A 16)"
    run_scan_all
    assert_output --partial "rule=aws-access-key" || { echo "$output"; false; }
    [ "$status" -eq 1 ] || { echo "status=$status output=$output"; false; }
}

@test "T-SCAN-002: detects GitHub token format" {
    add_file "fixture.txt" "gh_token = ghp_$(repeat A 36)"
    run_scan_all
    assert_output --partial "rule=github-token" || { echo "$output"; false; }
}

@test "T-SCAN-003: detects Slack token format" {
    add_file "fixture.txt" "slack = xoxb-$(repeat A 10)"
    run_scan_all
    assert_output --partial "rule=slack-token" || { echo "$output"; false; }
}

@test "T-SCAN-004: detects Google API key format" {
    add_file "fixture.txt" "google = AIza$(repeat A 35)"
    run_scan_all
    assert_output --partial "rule=google-api-key" || { echo "$output"; false; }
}

@test "T-SCAN-005: detects Anthropic API key format" {
    add_file "fixture.txt" "anthropic = sk-ant-$(repeat A 20)"
    run_scan_all
    assert_output --partial "rule=anthropic-api-key" || { echo "$output"; false; }
}

@test "T-SCAN-006: detects OpenAI-style API key format (and not as anthropic)" {
    add_file "fixture.txt" "openai = sk-$(repeat A 25)"
    run_scan_all
    assert_output --partial "rule=openai-api-key" || { echo "$output"; false; }
    refute_output --partial "rule=anthropic-api-key"
}

@test "T-SCAN-007: detects JWT format" {
    add_file "fixture.txt" "jwt = eyJ$(repeat A 10).eyJ$(repeat A 10).$(repeat A 10)"
    run_scan_all
    assert_output --partial "rule=jwt-token" || { echo "$output"; false; }
}

@test "T-SCAN-008: detects private key block" {
    add_file "fixture.pem" "$(pem_marker)"
    run_scan_all
    assert_output --partial "rule=secret-key-block" || { echo "$output"; false; }
}

@test "T-SCAN-009: detects credential-embedded URL" {
    # URLを前半・後半の2変数へ分ける(pem_markerと同じ理由による自己反応回避)。
    local scheme_and_user="https://svc-test"
    local pass_and_path=":p4ssTEST@internal.example.invalid/api"
    add_file "fixture.txt" "endpoint = ${scheme_and_user}${pass_and_path}"
    run_scan_all
    assert_output --partial "rule=credential-url" || { echo "$output"; false; }
}

@test "T-SCAN-010: detects ntfy topic URL (and excludes docs.ntfy.sh)" {
    # "https://ntfy"と".sh/topic..."を2断片に分ける(自己反応回避、pem_marker参照)。
    local ntfy_host="https://ntfy"
    local ntfy_path=".sh/some-real-looking-topic-abc"
    add_file "fixture.txt" "sub = ${ntfy_host}${ntfy_path}"
    add_file "fixture2.txt" "see https://docs.ntfy.sh/subscribe/ for details"
    run_scan_all
    assert_output --partial "rule=ntfy-topic-url" || { echo "$output"; false; }
    refute_output --partial "fixture2.txt"
}

# ============================================================
# T-1: 引用符付き秘密代入規則（真陽性）
# ============================================================

@test "T-SCAN-011: detects quoted secret-like assignment with sufficient entropy" {
    # 開き引用符側と閉じ引用符側を2断片に分ける(自己反応回避、pem_marker参照:
    # secret_scan.shの代入規則は開始・終了の引用符が同一行に無いと発火しない
    # ため、分割すればどちらの行も単独では一致しない)。
    local key_and_open='const val NTFY_TOPIC = "qz7-nK2m'
    local value_close='LwR9"'
    add_file "fixture.kt" "${key_and_open}${value_close}"
    run_scan_all
    assert_output --partial "rule=secret-assignment" || { echo "$output"; false; }
}

# ============================================================
# AC-5: 出力規律 — 検出した値そのものを出力しない
# ============================================================

@test "T-SCAN-012: output never contains the detected secret value" {
    local secret="AKIA$(repeat Z 16)"
    add_file "fixture.txt" "aws_key = ${secret}"
    run_scan_all
    refute_output --partial "$secret" || { echo "SECRET VALUE LEAKED INTO OUTPUT: $output"; false; }
    assert_output --partial "valuelen="
}

# ============================================================
# 誤検知フィルタの回帰試験（4フィルタ）
# ============================================================

@test "T-SCAN-013: suppresses placeholder-word values" {
    add_file "fixture.txt" 'ntfy_topic: "your-topic-name-here"'
    run_scan_all
    [ "$status" -eq 0 ] || { echo "status=$status output=$output"; false; }
    refute_output --partial "rule=secret-assignment"
}

@test "T-SCAN-014: suppresses test-/fake-/mock- prefixed synthetic values" {
    add_file "fixture.txt" 'ntfy_topic: "test-fixture-topic-12345"'
    add_file "fixture2.txt" 'auth_token: "fake-fixture-token-12345"'
    run_scan_all
    [ "$status" -eq 0 ] || { echo "status=$status output=$output"; false; }
    refute_output --partial "rule=secret-assignment"
}

@test "T-SCAN-015: suppresses variable/command-substitution references (not literals)" {
    add_file "fixture.sh" 'topic="$(branch_policy_query ntfy_topic)"'
    add_file "fixture2.sh" 'auth_file="${script_dir}/config/ntfy_auth.env"'
    run_scan_all
    [ "$status" -eq 0 ] || { echo "status=$status output=$output"; false; }
    refute_output --partial "rule=secret-assignment"
}

@test "T-SCAN-016: suppresses value identical to its own key name" {
    add_file "fixture.kt" 'const val NTFY_TOPIC = "ntfy_topic"'
    run_scan_all
    [ "$status" -eq 0 ] || { echo "status=$status output=$output"; false; }
    refute_output --partial "rule=secret-assignment"
}

@test "T-SCAN-017: bare 'key' is too generic alone — only recognized key-compounds (api_key etc.) count" {
    # prefKey/monkeyPatch のような"key"を含むだけの識別子は単独では
    # 秘密キーとみなさない（実測: 修正前は225ファイル中46件が誤検知——
    # 大半がこの種の識別子であった）。api_key のような複合形のみ対象。
    add_file "fixture.kt" 'prefKey = "some_channel_identifier"'
    add_file "fixture2.kt" 'monkeyPatchTarget = "some_target_class_name"'
    run_scan_all
    [ "$status" -eq 0 ] || { echo "status=$status output=$output"; false; }
    refute_output --partial "rule=secret-assignment"
}

# ============================================================
# allowlist（.secretscanignore）
# ============================================================

@test "T-SCAN-018: allowlist suppresses a pinned (path:line:rule-id) finding" {
    add_file "fixture.pem" "$(pem_marker)"
    local lineno
    lineno=$(grep -n "BEGIN RSA PRIVATE KEY" "$TEST_REPO/fixture.pem" | cut -d: -f1)
    printf 'fixture.pem:%s:secret-key-block  # 試験用固定検体 (cmd_242)\n' "$lineno" > "$TEST_REPO/.secretscanignore"
    run_scan_all
    [ "$status" -eq 0 ] || { echo "status=$status output=$output"; false; }
    refute_output --partial "rule=secret-key-block"
    assert_output --partial "suppressed=1"
}

@test "T-SCAN-019: allowlist line missing reason/cmd_id errors out (exit 2)" {
    add_file "fixture.pem" "$(pem_marker)"
    printf 'fixture.pem:1:secret-key-block\n' > "$TEST_REPO/.secretscanignore"
    run_scan_all
    [ "$status" -eq 2 ] || { echo "expected exit 2 (malformed ignore line), got status=$status output=$output"; false; }
}

@test "T-SCAN-020: allowlist line missing well-formed (reason) cmd_id parens errors out (exit 2)" {
    add_file "fixture.pem" "$(pem_marker)"
    printf 'fixture.pem:1:secret-key-block  # no cmd id here\n' > "$TEST_REPO/.secretscanignore"
    run_scan_all
    [ "$status" -eq 2 ] || { echo "expected exit 2 (malformed ignore line), got status=$status output=$output"; false; }
}

# ============================================================
# 種規則（seed rules） — 合成した種のみ用いる。本物の設定は使わない。
# ============================================================

@test "T-SCAN-021: seed from config/secret_seeds.local detects an untracked-file value elsewhere" {
    mkdir -p "$TEST_REPO/config"
    cat > "$TEST_REPO/config/secret_seeds.local" << 'EOF'
# comment line, ignored
retired-fixture-seed-9f3a2c
EOF
    add_file "docs/notes.md" "旧設定にはretired-fixture-seed-9f3aが使われていた記録がある(語尾切れの部分一致では発火せぬ設計だが、完全一致では検出される)"
    add_file "docs/notes2.md" "退役値: retired-fixture-seed-9f3a2c を含む文書"
    run_scan_all
    assert_output --partial "docs/notes2.md" || { echo "$output"; false; }
    assert_output --partial "rule=seed-match" || { echo "$output"; false; }
    refute_output --partial "docs/notes.md:"
}

@test "T-SCAN-022: seed from \$USER env var detects its literal occurrence (CI env unset)" {
    add_file "docs/notes.md" "leftover reference to ci-fixture-owner-9f3a in an old doc"
    cd "$TEST_REPO"
    run env -u CI "USER=ci-fixture-owner-9f3a" bash "$SECRET_SCAN" --all --ignore-file "$TEST_REPO/.secretscanignore"
    assert_output --partial "rule=seed-match" || { echo "$output"; false; }
}

@test "T-SCAN-023: \$USER seed is silently skipped when CI env var is set" {
    add_file "docs/notes.md" "leftover reference to ci-fixture-owner-9f3a in an old doc"
    cd "$TEST_REPO"
    run env "CI=true" "USER=ci-fixture-owner-9f3a" bash "$SECRET_SCAN" --all --ignore-file "$TEST_REPO/.secretscanignore"
    [ "$status" -eq 0 ] || { echo "status=$status output=$output"; false; }
    refute_output --partial "rule=seed-match"
}

@test "T-SCAN-024: absent config/settings.yaml and config/secret_seeds.local are skipped silently (no crash)" {
    add_file "fixture.txt" "nothing secret here"
    run_scan_all
    [ "$status" -eq 0 ] || { echo "status=$status output=$output"; false; }
}

# ============================================================
# 終了コード
# ============================================================

@test "T-SCAN-025: exit 0 when no findings" {
    add_file "fixture.txt" "just some ordinary text with no secrets"
    run_scan_all
    [ "$status" -eq 0 ] || { echo "status=$status output=$output"; false; }
}

@test "T-SCAN-026: exit 1 when block-severity finding is present and unignored" {
    add_file "fixture.pem" "$(pem_marker)"
    run_scan_all
    [ "$status" -eq 1 ] || { echo "status=$status output=$output"; false; }
}

# ============================================================
# --staged / --range モード
# ============================================================

@test "T-SCAN-027: --staged mode scans the git index, not the working tree" {
    add_file "fixture.pem" "$(pem_marker)"
    # working treeを検体除去後の内容へ書き換えるが、indexには残す
    printf 'no secret here\n' > "$TEST_REPO/fixture.pem"
    cd "$TEST_REPO"
    run bash "$SECRET_SCAN" --staged --ignore-file "$TEST_REPO/.secretscanignore"
    assert_output --partial "rule=secret-key-block" || { echo "$output"; false; }
}

@test "T-SCAN-028: --range mode scans files changed between two commits" {
    add_file "fixture.txt" "no secret in the base commit"
    git -C "$TEST_REPO" commit -q -m "base"
    local old_sha
    old_sha=$(git -C "$TEST_REPO" rev-parse HEAD)

    add_file "fixture2.pem" "$(pem_marker)"
    git -C "$TEST_REPO" commit -q -m "add secret"
    local new_sha
    new_sha=$(git -C "$TEST_REPO" rev-parse HEAD)

    cd "$TEST_REPO"
    run bash "$SECRET_SCAN" --range "${old_sha}..${new_sha}" --ignore-file "$TEST_REPO/.secretscanignore"
    assert_output --partial "rule=secret-key-block" || { echo "$output"; false; }
    [ "$status" -eq 1 ] || { echo "status=$status output=$output"; false; }
}

@test "T-SCAN-029: --range mode with old=all-zeros (new branch push) scans full tree at new commit" {
    add_file "fixture.pem" "$(pem_marker)"
    git -C "$TEST_REPO" commit -q -m "first commit on new branch"
    local new_sha
    new_sha=$(git -C "$TEST_REPO" rev-parse HEAD)
    local z40="0000000000000000000000000000000000000000"

    cd "$TEST_REPO"
    run bash "$SECRET_SCAN" --range "${z40}..${new_sha}" --ignore-file "$TEST_REPO/.secretscanignore"
    assert_output --partial "rule=secret-key-block" || { echo "$output"; false; }
    [ "$status" -eq 1 ] || { echo "status=$status output=$output"; false; }
}

@test "T-SCAN-030: --range mode with new=all-zeros (branch deletion) reports no findings" {
    add_file "fixture.pem" "$(pem_marker)"
    git -C "$TEST_REPO" commit -q -m "commit before deletion"
    local old_sha
    old_sha=$(git -C "$TEST_REPO" rev-parse HEAD)
    local z40="0000000000000000000000000000000000000000"

    cd "$TEST_REPO"
    run bash "$SECRET_SCAN" --range "${old_sha}..${z40}" --ignore-file "$TEST_REPO/.secretscanignore"
    [ "$status" -eq 0 ] || { echo "status=$status output=$output"; false; }
}

# ============================================================
# 使用法エラー
# ============================================================

@test "T-SCAN-031: no mode flag errors out (exit 2)" {
    run bash "$SECRET_SCAN"
    [ "$status" -eq 2 ] || { echo "status=$status output=$output"; false; }
}

@test "T-SCAN-032: unknown flag errors out (exit 2)" {
    run bash "$SECRET_SCAN" --bogus-flag
    [ "$status" -eq 2 ] || { echo "status=$status output=$output"; false; }
}
