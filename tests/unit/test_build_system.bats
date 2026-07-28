#!/usr/bin/env bats
# test_build_system.bats — ビルドシステム（build_instructions.sh）ユニットテスト
# Phase 2+3 品質テスト基盤
#
# テスト構成:
#   - ビルド実行テスト: スクリプト正常終了、ディレクトリ生成
#   - ファイル生成テスト: claude/codex/copilot/opencode各ロールの生成確認
#   - 内容検証テスト: 空でないこと、ロール名・CLI固有セクション含有
#   - AGENTS.md / copilot-instructions.md 生成テスト
#   - 冪等性テスト: 2回ビルドで差分なし
#
# Phase 2+3未実装テストについて:
#   copilot/opencode生成、AGENTS.md、copilot-instructions.md のテストは
#   build_instructions.shが拡張されるまでFAILする（受入基準）。
#   SKIP は使用しない（SKIP=0ルール遵守）。

# --- セットアップ ---

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export BUILD_SCRIPT="$PROJECT_ROOT/scripts/build_instructions.sh"
    export OUTPUT_DIR="$PROJECT_ROOT/instructions/generated"

    # パーツディレクトリの存在確認（前提条件）
    [ -d "$PROJECT_ROOT/instructions/roles" ] || return 1
    [ -d "$PROJECT_ROOT/instructions/common" ] || return 1
    [ -d "$PROJECT_ROOT/instructions/cli_specific" ] || return 1

    # ビルド実行（全テストの前に1回のみ）
    bash "$BUILD_SCRIPT" > /dev/null 2>&1 || true
}

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    BUILD_SCRIPT="$PROJECT_ROOT/scripts/build_instructions.sh"
    OUTPUT_DIR="$PROJECT_ROOT/instructions/generated"
}

# =============================================================================
# ビルド実行テスト
# =============================================================================

@test "build: build_instructions.sh exits with status 0" {
    run bash "$BUILD_SCRIPT"
    [ "$status" -eq 0 ]
}

@test "build: generated/ directory exists after build" {
    [ -d "$OUTPUT_DIR" ]
}

@test "build: generated/ contains at least 6 files" {
    local count
    count=$(find "$OUTPUT_DIR" -name "*.md" -type f | wc -l)
    [ "$count" -ge 6 ]
}

# =============================================================================
# ファイル生成テスト — Claude
# =============================================================================

@test "claude: shogun.md generated" {
    [ -f "$OUTPUT_DIR/shogun.md" ]
}

@test "claude: karo.md generated" {
    [ -f "$OUTPUT_DIR/karo.md" ]
}

@test "claude: ashigaru.md generated" {
    [ -f "$OUTPUT_DIR/ashigaru.md" ]
}

# =============================================================================
# ファイル生成テスト — Codex / OpenCode
# =============================================================================

@test "codex: codex-shogun.md generated" {
    [ -f "$OUTPUT_DIR/codex-shogun.md" ]
}

@test "codex: codex-karo.md generated" {
    [ -f "$OUTPUT_DIR/codex-karo.md" ]
}

@test "codex: codex-ashigaru.md generated" {
    [ -f "$OUTPUT_DIR/codex-ashigaru.md" ]
}

@test "opencode: opencode-shogun.md generated [R6]" {
    [ -f "$OUTPUT_DIR/opencode-shogun.md" ]
}

@test "opencode: opencode-karo.md generated [R6]" {
    [ -f "$OUTPUT_DIR/opencode-karo.md" ]
}

@test "opencode: opencode-ashigaru.md generated [R6]" {
    [ -f "$OUTPUT_DIR/opencode-ashigaru.md" ]
}

@test "opencode: opencode-gunshi.md generated [R6]" {
    [ -f "$OUTPUT_DIR/opencode-gunshi.md" ]
}

@test "antigravity: antigravity-shogun.md generated" {
    [ -f "$OUTPUT_DIR/antigravity-shogun.md" ]
}

@test "antigravity: antigravity-karo.md generated" {
    [ -f "$OUTPUT_DIR/antigravity-karo.md" ]
}

@test "antigravity: antigravity-ashigaru.md generated" {
    [ -f "$OUTPUT_DIR/antigravity-ashigaru.md" ]
}

@test "antigravity: antigravity-gunshi.md generated" {
    [ -f "$OUTPUT_DIR/antigravity-gunshi.md" ]
}

@test "opencode: generated markdown is LF-only and has no trailing whitespace [R6]" {
    local file

    for file in "$OUTPUT_DIR"/opencode-*.md "$PROJECT_ROOT"/.opencode/agents/*.md; do
        [ -f "$file" ] || continue

        if LC_ALL=C grep -n $'\r' "$file"; then
            echo "CR line ending found in $file" >&2
            return 1
        fi

        if grep -nE '[[:blank:]]+$' "$file"; then
            echo "Trailing whitespace found in $file" >&2
            return 1
        fi
    done
}

# =============================================================================
# ファイル生成テスト — Copilot (Phase 2+3 受入基準)
# =============================================================================

@test "copilot: copilot-shogun.md generated [Phase 2+3]" {
    [ -f "$OUTPUT_DIR/copilot-shogun.md" ]
}

@test "copilot: copilot-karo.md generated [Phase 2+3]" {
    [ -f "$OUTPUT_DIR/copilot-karo.md" ]
}

@test "copilot: copilot-ashigaru.md generated [Phase 2+3]" {
    [ -f "$OUTPUT_DIR/copilot-ashigaru.md" ]
}

# =============================================================================
# 内容検証テスト — 空でないこと
# =============================================================================

@test "content: shogun.md is not empty" {
    [ -s "$OUTPUT_DIR/shogun.md" ]
}

@test "content: karo.md is not empty" {
    [ -s "$OUTPUT_DIR/karo.md" ]
}

@test "content: ashigaru.md is not empty" {
    [ -s "$OUTPUT_DIR/ashigaru.md" ]
}

@test "content: codex-shogun.md is not empty" {
    [ -s "$OUTPUT_DIR/codex-shogun.md" ]
}

@test "content: codex-karo.md is not empty" {
    [ -s "$OUTPUT_DIR/codex-karo.md" ]
}

@test "content: codex-ashigaru.md is not empty" {
    [ -s "$OUTPUT_DIR/codex-ashigaru.md" ]
}

@test "content: opencode-shogun.md is not empty" {
    [ -s "$OUTPUT_DIR/opencode-shogun.md" ]
}

@test "content: opencode-karo.md is not empty" {
    [ -s "$OUTPUT_DIR/opencode-karo.md" ]
}

@test "content: opencode-ashigaru.md is not empty" {
    [ -s "$OUTPUT_DIR/opencode-ashigaru.md" ]
}

@test "content: opencode-gunshi.md is not empty" {
    [ -s "$OUTPUT_DIR/opencode-gunshi.md" ]
}

@test "content: antigravity-shogun.md is not empty" {
    [ -s "$OUTPUT_DIR/antigravity-shogun.md" ]
}

# =============================================================================
# 内容検証テスト — ロール名含有
# =============================================================================

@test "content: shogun.md contains shogun role reference" {
    grep -qi "shogun\|将軍" "$OUTPUT_DIR/shogun.md"
}

@test "content: karo.md contains karo role reference" {
    grep -qi "karo\|家老" "$OUTPUT_DIR/karo.md"
}

@test "content: ashigaru.md contains ashigaru role reference" {
    grep -qi "ashigaru\|足軽" "$OUTPUT_DIR/ashigaru.md"
}

@test "content: codex-shogun.md contains shogun role reference" {
    grep -qi "shogun\|将軍" "$OUTPUT_DIR/codex-shogun.md"
}

@test "content: codex-karo.md contains karo role reference" {
    grep -qi "karo\|家老" "$OUTPUT_DIR/codex-karo.md"
}

@test "content: codex-ashigaru.md contains ashigaru role reference" {
    grep -qi "ashigaru\|足軽" "$OUTPUT_DIR/codex-ashigaru.md"
}

@test "content: opencode-shogun.md contains shogun role reference" {
    grep -qi "shogun\|将軍" "$OUTPUT_DIR/opencode-shogun.md"
}

@test "content: opencode-karo.md contains karo role reference" {
    grep -qi "karo\|家老" "$OUTPUT_DIR/opencode-karo.md"
}

@test "content: opencode-ashigaru.md contains ashigaru role reference" {
    grep -qi "ashigaru\|足軽" "$OUTPUT_DIR/opencode-ashigaru.md"
}

@test "content: opencode-gunshi.md contains gunshi role reference" {
    grep -qi "gunshi\|軍師" "$OUTPUT_DIR/opencode-gunshi.md"
}

@test "content: antigravity-shogun.md contains shogun role reference" {
    grep -qi "shogun\|将軍" "$OUTPUT_DIR/antigravity-shogun.md"
}

# =============================================================================
# 内容検証テスト — CLI固有セクション
# =============================================================================

@test "content: claude files contain Claude-specific tools" {
    # Claude Code固有ツール: Read, Write, Edit, Bash等
    grep -qi "claude\|Read\|Write\|Edit\|Bash" "$OUTPUT_DIR/shogun.md"
}

@test "content: codex files contain Codex-specific content" {
    grep -qi "codex\|AGENTS.md\|Codex" "$OUTPUT_DIR/codex-shogun.md"
}

@test "content: opencode files contain OpenCode-specific content [R6]" {
    grep -qi "opencode\|OpenCode\|--agent" "$OUTPUT_DIR/opencode-shogun.md"
}

@test "content: antigravity files contain Antigravity-specific content" {
    grep -qi "antigravity\|Antigravity\|agy" "$OUTPUT_DIR/antigravity-shogun.md"
}

@test "content: copilot files contain Copilot-specific content [Phase 2+3]" {
    grep -qi "copilot\|Copilot" "$OUTPUT_DIR/copilot-shogun.md"
}

# =============================================================================
# AGENTS.md 生成テスト (Phase 2+3 受入基準)
# =============================================================================

@test "agents: AGENTS.md generated [Phase 2+3]" {
    [ -f "$PROJECT_ROOT/AGENTS.md" ]
}

@test "agents: AGENTS.md contains Codex-specific content [Phase 2+3]" {
    [ -f "$PROJECT_ROOT/AGENTS.md" ] && grep -qi "codex\|agent" "$PROJECT_ROOT/AGENTS.md"
}

# =============================================================================
# OpenCode instruction generation (R6)
# =============================================================================

@test "opencode-inst: instructions/generated/opencode-shogun.md generated [R6]" {
    [ -f "$OUTPUT_DIR/opencode-shogun.md" ]
}

@test "opencode-inst: instructions/generated/opencode-karo.md generated [R6]" {
    [ -f "$OUTPUT_DIR/opencode-karo.md" ]
}

@test "opencode-inst: instructions/generated/opencode-ashigaru.md generated [R6]" {
    [ -f "$OUTPUT_DIR/opencode-ashigaru.md" ]
}

@test "opencode-inst: instructions/generated/opencode-gunshi.md generated [R6]" {
    [ -f "$OUTPUT_DIR/opencode-gunshi.md" ]
}

@test "opencode-agent: .opencode/agents/shogun.md generated [R6]" {
    [ -f "$PROJECT_ROOT/.opencode/agents/shogun.md" ]
}

@test "opencode-agent: generated agent frontmatter contains permission section [R6]" {
    grep -q '^permission:' "$PROJECT_ROOT/.opencode/agents/shogun.md"
}

@test "opencode-agent: tracked agent frontmatter excludes runtime routing [R6]" {
    PROJECT_ROOT="$PROJECT_ROOT" "$PROJECT_ROOT/.venv/bin/python3" - <<'PYEOF'
from pathlib import Path
import os
import yaml

project_root = Path(os.environ["PROJECT_ROOT"])
agents_dir = project_root / ".opencode" / "agents"
for path in sorted(agents_dir.glob("*.md")):
    if path.name.endswith("-runtime.md"):
        continue
    text = path.read_text(encoding="utf-8")
    frontmatter = yaml.safe_load(text.split("---", 2)[1])
    assert "model" not in frontmatter, f"{path.name}: tracked generated agent must not depend on local settings.yaml"
    assert "variant" not in frontmatter, f"{path.name}: tracked generated agent must not depend on local settings.yaml"
PYEOF
}

@test "opencode-agent: ashigaru1 read permissions allow own inbox/report/task [R6]" {
    PROJECT_ROOT="$PROJECT_ROOT" "$PROJECT_ROOT/.venv/bin/python3" - <<'PYEOF'
from pathlib import Path
import os
import yaml

project_root = Path(os.environ["PROJECT_ROOT"])
text = (project_root / ".opencode/agents/ashigaru1.md").read_text(encoding="utf-8")
parts = text.split("---", 2)
frontmatter = yaml.safe_load(parts[1])
perm = frontmatter["permission"]

assert perm["question"] == "deny"
assert perm["read"]["queue/inbox/*"] == "deny"
assert perm["read"]["queue/inbox/ashigaru1.yaml"] == "allow"
assert perm["read"]["queue/tasks/*"] == "deny"
assert perm["read"]["queue/tasks/ashigaru1.yaml"] == "allow"
assert perm["read"]["queue/reports/*"] == "deny"
assert perm["read"]["queue/reports/ashigaru1_report.yaml"] == "allow"

for tool_name in ("glob", "list"):
    assert perm[tool_name]["queue/inbox/*"] == "deny"
    assert perm[tool_name]["queue/inbox/ashigaru1.yaml"] == "allow"
    assert perm[tool_name]["queue/tasks/*"] == "deny"
    assert perm[tool_name]["queue/tasks/ashigaru1.yaml"] == "allow"
    assert perm[tool_name]["queue/reports/*"] == "deny"
    assert perm[tool_name]["queue/reports/ashigaru1_report.yaml"] == "allow"
PYEOF
}

@test "opencode-agent: grep permission is intentionally not path-scoped [R6]" {
    PROJECT_ROOT="$PROJECT_ROOT" "$PROJECT_ROOT/.venv/bin/python3" - <<'PYEOF'
from pathlib import Path
import os
import yaml

agents_dir = Path(os.environ["PROJECT_ROOT"]) / ".opencode/agents"
for path in sorted(agents_dir.glob("*.md")):
    text = path.read_text(encoding="utf-8")
    frontmatter = yaml.safe_load(text.split("---", 2)[1])
    perm = frontmatter["permission"]
    assert "grep" not in perm, f"{path.name}: grep must inherit '*: allow', not path-scoped rules"
    assert "grep intentionally inherits '*: allow'" in text, f"{path.name}: missing intentional grep comment"
PYEOF
}

@test "opencode-agent: shogun can read reports for oversight [R6]" {
    PROJECT_ROOT="$PROJECT_ROOT" "$PROJECT_ROOT/.venv/bin/python3" - <<'PYEOF'
from pathlib import Path
import os
import yaml

path = Path(os.environ["PROJECT_ROOT"]) / ".opencode/agents/shogun.md"
text = path.read_text(encoding="utf-8")
frontmatter = yaml.safe_load(text.split("---", 2)[1])
perm = frontmatter["permission"]

assert perm["read"]["queue/reports/*"] == "allow"
assert perm["glob"]["queue/reports/*"] == "allow"
assert perm["list"]["queue/reports/*"] == "allow"
assert perm["edit"]["queue/reports/*"] == "deny"
PYEOF
}

@test "opencode-agent: inbox edits are denied for every role [R6]" {
    PROJECT_ROOT="$PROJECT_ROOT" "$PROJECT_ROOT/.venv/bin/python3" - <<'PYEOF'
from pathlib import Path
import os
import yaml

agents_dir = Path(os.environ["PROJECT_ROOT"]) / ".opencode/agents"
for path in sorted(agents_dir.glob("*.md")):
    text = path.read_text(encoding="utf-8")
    frontmatter = yaml.safe_load(text.split("---", 2)[1])
    edit = frontmatter["permission"]["edit"]
    inbox_rules = {key: value for key, value in edit.items() if key.startswith("queue/inbox/")}
    exact_rule = edit.get("queue/inbox/*.yaml")
    unexpected_rules = {key: value for key, value in inbox_rules.items() if key != "queue/inbox/*.yaml"}

    assert exact_rule == "deny", f"{path.name}: queue/inbox/*.yaml edit rule missing or not deny: {exact_rule!r}"
    assert not unexpected_rules, f"{path.name}: unexpected inbox edit rules: {unexpected_rules}"
PYEOF
}

@test "opencode-agent: invalid permission YAML fails generation [R6]" {
    local permissions_file
    permissions_file="$BATS_TEST_TMPDIR/opencode-permissions.invalid.yaml"

    printf 'roles: [invalid\n' > "$permissions_file"
    run env OPENCODE_PERMISSIONS_FILE="$permissions_file" bash "$BUILD_SCRIPT"

    [ "$status" -ne 0 ]
}

@test "opencode-config: root edit permissions deny inbox YAML [R6]" {
    PROJECT_ROOT="$PROJECT_ROOT" "$PROJECT_ROOT/.venv/bin/python3" - <<'PYEOF'
from pathlib import Path
import os
import yaml

config = yaml.safe_load((Path(os.environ["PROJECT_ROOT"]) / "config/opencode-permissions.yaml").read_text(encoding="utf-8"))
assert config["common"]["edit_deny"]
assert "queue/inbox/*.yaml" in config["common"]["edit_deny"]
PYEOF
}

@test "opencode-tool: mark-as-read enforces current agent and inbox lock [R6]" {
    local tool_file="$PROJECT_ROOT/.opencode/tools/mark-as-read.ts"

    grep -q 'process.env.OPENCODE_AGENT_ID' "$tool_file"
    grep -q 'Refusing to mark another agent' "$tool_file"
    grep -q 'withInboxLock' "$tool_file"
    grep -q '.lock.d' "$tool_file"
}

# =============================================================================
# copilot-instructions.md 生成テスト (Phase 2+3 受入基準)
# =============================================================================

@test "copilot-inst: .github/copilot-instructions.md generated [Phase 2+3]" {
    [ -f "$PROJECT_ROOT/.github/copilot-instructions.md" ]
}

@test "copilot-inst: contains Copilot-specific content [Phase 2+3]" {
    [ -f "$PROJECT_ROOT/.github/copilot-instructions.md" ] && \
        grep -qi "copilot" "$PROJECT_ROOT/.github/copilot-instructions.md"
}

# =============================================================================
# 冪等性テスト
# =============================================================================

# =============================================================================
# Codex /clear → /new 変換テスト
# =============================================================================
# Codex CLIは/clearでセッション終了するため、AGENTS.mdおよびcodex-*.mdで
# /clearが命令として残存していないことを検証する。
# 比較表や変換説明の文脈での/clear言及はOK。

@test "codex-clear: AGENTS.md has no /clear Recovery section" {
    # /clear Recoveryは/new Recoveryに変換されるべき
    run grep -c "## /clear Recovery" "$PROJECT_ROOT/AGENTS.md"
    [ "$output" = "0" ]
}

@test "codex-clear: AGENTS.md has /new Recovery section" {
    grep -q "## /new Recovery" "$PROJECT_ROOT/AGENTS.md"
}

@test "codex-clear: AGENTS.md has no 'Forbidden after /clear'" {
    run grep -c "Forbidden after /clear" "$PROJECT_ROOT/AGENTS.md"
    [ "$output" = "0" ]
}

@test "codex-clear: AGENTS.md has no 'sends \`/clear\` + Enter via send-keys' (unconverted)" {
    # 変換済みは「sends /new + Enter」になっているべき
    run grep -c 'sends `/clear` + Enter via send-keys$' "$PROJECT_ROOT/AGENTS.md"
    [ "$output" = "0" ]
}

@test "codex-clear: AGENTS.md has no 'delivers \`/clear\` to the agent' (unconverted)" {
    # 変換済みは「delivers /new to the agent」になっているべき
    run grep -c 'delivers `/clear` to the agent →' "$PROJECT_ROOT/AGENTS.md"
    [ "$output" = "0" ]
}

@test "codex-clear: AGENTS.md has no '/clear wipes old context'" {
    run grep -c '`/clear` wipes old context' "$PROJECT_ROOT/AGENTS.md"
    [ "$output" = "0" ]
}

@test "codex-clear: codex-ashigaru.md has no bare '/clear' in escalation table" {
    # 比較表(codex_tools.md由来)以外で/clearが命令として現れないこと
    # エスカレーション行に「/clear sent」があればNG
    run grep -c '`/clear` sent (max once' "$OUTPUT_DIR/codex-ashigaru.md"
    [ "$output" = "0" ]
}

@test "codex-clear: codex-ashigaru.md protocol uses CLI-neutral context reset" {
    # protocol.mdのclear_command行がCLI中立表現になっていること
    grep -q "context reset command via send-keys" "$OUTPUT_DIR/codex-ashigaru.md"
}

@test "codex-clear: codex-karo.md has no bare '/clear' in redo protocol" {
    # Redo Protocolで「delivers /clear to the agent →」がそのまま残っていないこと
    run grep -c 'delivers `/clear` to the agent →' "$OUTPUT_DIR/codex-karo.md"
    [ "$output" = "0" ]
}

@test "codex-clear: codex-gunshi.md protocol uses CLI-neutral context reset" {
    grep -q "context reset command via send-keys" "$OUTPUT_DIR/codex-gunshi.md"
}

@test "codex-clear: codex-shogun.md protocol uses CLI-neutral context reset" {
    grep -q "context reset command via send-keys" "$OUTPUT_DIR/codex-shogun.md"
}

# =============================================================================
# 冪等性テスト
# =============================================================================

@test "idempotent: second build produces identical output" {
    # 1st build
    bash "$BUILD_SCRIPT" > /dev/null 2>&1
    local checksums_first
    checksums_first=$(find "$OUTPUT_DIR" -name "*.md" -type f -exec md5sum {} \; | sort)

    # 2nd build
    bash "$BUILD_SCRIPT" > /dev/null 2>&1
    local checksums_second
    checksums_second=$(find "$OUTPUT_DIR" -name "*.md" -type f -exec md5sum {} \; | sort)

    [ "$checksums_first" = "$checksums_second" ]
}
