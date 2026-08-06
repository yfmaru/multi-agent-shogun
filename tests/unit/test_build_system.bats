#!/usr/bin/env bats
# test_build_system.bats — ビルドシステム（build_instructions.sh）ユニットテスト
#
# B案（cmd_203）後の構成: instructions/<role>.md（手書き版）を唯一の素材とし、
# 各CLIの自動読込ファイル（AGENTS.md / .github/copilot-instructions.md /
# agents/default/system.md / .opencode/agents/*.md）を生成する。
# instructions/generated/（roles/+common/由来の中間生成物）はcmd_203 T3で廃止済み。
#
# テスト構成:
#   - ビルド実行テスト: スクリプト正常終了
#   - AGENTS.md / copilot-instructions.md / .opencode/agents 生成テスト
#   - 冪等性テスト: 2回ビルドで差分なし
#
# SKIP は使用しない（SKIP=0ルール遵守）。

# --- セットアップ ---

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export BUILD_SCRIPT="$PROJECT_ROOT/scripts/build_instructions.sh"

    # 素材ファイルの存在確認（前提条件）。B案後は手書き版のみが素材である。
    [ -f "$PROJECT_ROOT/instructions/shogun.md" ] || return 1
    [ -f "$PROJECT_ROOT/instructions/karo.md" ] || return 1
    [ -f "$PROJECT_ROOT/instructions/gunshi.md" ] || return 1
    [ -f "$PROJECT_ROOT/instructions/ashigaru.md" ] || return 1
    [ -d "$PROJECT_ROOT/instructions/cli_specific" ] || return 1

    # ビルド実行（全テストの前に1回のみ）
    bash "$BUILD_SCRIPT" > /dev/null 2>&1 || true
}

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    BUILD_SCRIPT="$PROJECT_ROOT/scripts/build_instructions.sh"
}

# =============================================================================
# ビルド実行テスト
# =============================================================================

@test "build: build_instructions.sh exits with status 0" {
    run bash "$BUILD_SCRIPT"
    [ "$status" -eq 0 ]
}

@test "opencode: generated markdown is LF-only and has no trailing whitespace [R6]" {
    local file

    for file in "$PROJECT_ROOT"/.opencode/agents/*.md; do
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
# 内容検証テスト — 素材が手書き版であること
# =============================================================================

@test "content: .opencode/agents/shogun.md is built from instructions/shogun.md (not roles/)" {
    grep -q "Source: instructions/shogun.md" "$PROJECT_ROOT/.opencode/agents/shogun.md"
}

@test "content: .opencode/agents/karo.md is built from instructions/karo.md (not roles/)" {
    grep -q "Source: instructions/karo.md" "$PROJECT_ROOT/.opencode/agents/karo.md"
}

@test "content: .opencode/agents/ashigaru1.md is built from instructions/ashigaru.md (not roles/)" {
    grep -q "Source: instructions/ashigaru.md" "$PROJECT_ROOT/.opencode/agents/ashigaru1.md"
}

@test "content: .opencode/agents/gunshi.md is built from instructions/gunshi.md (not roles/)" {
    grep -q "Source: instructions/gunshi.md" "$PROJECT_ROOT/.opencode/agents/gunshi.md"
}

@test "content: .opencode/agents/*.md carry the hand-written front matter as Role Configuration" {
    local file
    for file in "$PROJECT_ROOT"/.opencode/agents/*.md; do
        case "$file" in *-runtime.md) continue ;; esac
        grep -q '^## Role Configuration$' "$file" || { echo "missing Role Configuration in $file" >&2; return 1; }
    done
}

# =============================================================================
# AGENTS.md 生成テスト
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

@test "opencode-agent: exactly one frontmatter block in each generated agent file [T0]" {
    local file count

    for file in "$PROJECT_ROOT"/.opencode/agents/*.md; do
        case "$file" in
            *-runtime.md) continue ;;
        esac
        count=$(grep -c '^---$' "$file")
        [ "$count" -eq 2 ] || { echo "FAIL: $file has $count '---' lines (expected 2)" >&2; false; }
    done
}

@test "opencode-agent: role body frontmatter is stripped regardless of whether instructions/<role>.md currently has one [T0]" {
    local role_file="$PROJECT_ROOT/instructions/shogun.md"
    local backup="$BATS_TEST_TMPDIR/shogun.md.bak"
    cp "$role_file" "$backup"

    # front matterを取り除いた版で一時的に上書きし、無front matterの入力でも
    # 壊れないことを確認する（既存awkは有無どちらのケースにも対応済み）。
    awk 'NR==1 && /^---$/ {infm=1; next} infm && /^---$/ {infm=0; next} infm {next} {print}' "$backup" > "$role_file"

    run bash "$BUILD_SCRIPT"
    local build_status="$status"
    local count=0
    if [ -f "$PROJECT_ROOT/.opencode/agents/shogun.md" ]; then
        count=$(grep -c '^---$' "$PROJECT_ROOT/.opencode/agents/shogun.md")
    fi

    # Always restore, even if the assertions below fail.
    cp "$backup" "$role_file"
    bash "$BUILD_SCRIPT" > /dev/null 2>&1 || true

    [ "$build_status" -eq 0 ]
    [ "$count" -eq 2 ] || { echo "FAIL: shogun.md has $count '---' lines when instructions/shogun.md has no front matter (expected 2)" >&2; false; }
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

@test "codex-clear: AGENTS.md has no bare '/clear sent (max once' in escalation table" {
    # AGENTS.mdはCLAUDE.mdから生成される唯一のCodex自動読込ファイルであり、
    # 比較表(cli_specific由来)以外で/clearが命令として現れないこと
    run grep -c '`/clear` sent (max once' "$PROJECT_ROOT/AGENTS.md"
    [ "$output" = "0" ]
}

@test "codex-clear: AGENTS.md protocol uses CLI-neutral context reset" {
    # CLAUDE.mdのclear_command行がCLI中立表現になっていること
    grep -q "context reset command via send-keys" "$PROJECT_ROOT/AGENTS.md"
}

# =============================================================================
# 冪等性テスト
# =============================================================================

@test "idempotent: second build produces identical output" {
    local targets=(
        "$PROJECT_ROOT/AGENTS.md"
        "$PROJECT_ROOT/.github/copilot-instructions.md"
        "$PROJECT_ROOT/agents/default/system.md"
    )
    local f

    # 1st build
    bash "$BUILD_SCRIPT" > /dev/null 2>&1
    local checksums_first
    checksums_first=$(
        { for f in "${targets[@]}"; do md5sum "$f"; done
          find "$PROJECT_ROOT/.opencode/agents" -name "*.md" ! -name '*-runtime.md' -type f -exec md5sum {} \;
        } | sort
    )

    # 2nd build
    bash "$BUILD_SCRIPT" > /dev/null 2>&1
    local checksums_second
    checksums_second=$(
        { for f in "${targets[@]}"; do md5sum "$f"; done
          find "$PROJECT_ROOT/.opencode/agents" -name "*.md" ! -name '*-runtime.md' -type f -exec md5sum {} \;
        } | sort
    )

    [ "$checksums_first" = "$checksums_second" ]
}
