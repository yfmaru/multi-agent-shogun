# Contributing to multi-agent-shogun

Thank you for your interest in contributing to multi-agent-shogun! This document provides guidelines for contributing to the project.

## Table of Contents

1. [How to Contribute](#how-to-contribute)
2. [Project Structure](#project-structure)
3. [.gitignore Whitelist Approach](#gitignore-whitelist-approach)
4. [Coding Conventions](#coding-conventions)
5. [Testing](#testing)
6. [CLAUDE.md へ条文を追加する前に](#claudemd-へ条文を追加する前に)
7. [Pull Request Guidelines](#pull-request-guidelines)
8. [Communication](#communication)

---

## How to Contribute

### Fork, Branch, PR Workflow

1. **Fork the repository** on GitHub
2. **Clone your fork** locally:
   ```bash
   git clone https://github.com/YOUR_USERNAME/multi-agent-shogun.git
   cd multi-agent-shogun
   ```
3. **Create a feature branch**:
   ```bash
   git checkout -b feature/your-feature-name
   ```
4. **Make your changes** and commit them with clear, descriptive messages
5. **Push to your fork**:
   ```bash
   git push origin feature/your-feature-name
   ```
6. **Open a Pull Request** on GitHub

### Before You Start

- Check existing [Issues](https://github.com/yohey-w/multi-agent-shogun/issues) to avoid duplicate work
- For major changes, open a [Discussion](https://github.com/yohey-w/multi-agent-shogun/discussions) first
- Read this entire document to understand our conventions and requirements

---

## Project Structure

Understanding the directory layout will help you navigate the codebase:

```
multi-agent-shogun/
│
├── scripts/              # Core utility scripts
│   ├── inbox_write.sh    # Agent-to-agent messaging (file-based mailbox)
│   ├── inbox_watcher.sh  # Event-driven delivery via inotifywait
│   ├── ntfy.sh           # Push notifications to phone
│   └── build_instructions.sh  # Generate CLI-specific instructions
│
├── instructions/         # Agent behavior definitions
│   ├── shogun.md         # Shogun (commander) instructions
│   ├── karo.md           # Karo (manager) instructions
│   ├── ashigaru.md       # Ashigaru (worker) instructions
│   ├── cli_specific/     # CLI-specific tool descriptions
│   │   ├── claude_tools.md
│   │   ├── codex_tools.md
│   │   ├── copilot_tools.md
│   │   └── opencode_tools.md
│   └── generated/        # Built from templates (do not edit manually)
│
├── lib/                  # Core libraries
│   ├── cli_adapter.sh    # Multi-CLI abstraction layer
│   └── agent_status.sh   # Shared busy/idle detection
│
├── templates/            # Report and context templates
│   ├── context_template.md  # Universal 7-section project context
│   └── integ_*.md        # Integration report templates
│
├── queue/                # Communication and task data
│   ├── shogun_to_karo.yaml  # Command queue
│   ├── inbox/            # Per-agent mailboxes
│   ├── tasks/            # Per-worker task assignments
│   └── reports/          # Completion reports
│
├── config/               # Configuration files
│   ├── settings.yaml     # Language, CLI settings, ntfy topic
│   ├── opencode-permissions.yaml  # OpenCode role boundary source
│   ├── opencode-tui.json  # OpenCode TUI keybinding pinning for tmux
│   └── projects.yaml     # Project registry
│
├── .opencode/
│   └── agents/           # Generated OpenCode agent definitions (do not edit manually)
│
├── tests/                # Test suite
│   ├── unit/             # bats unit tests
│   ├── integration/      # bats integration tests
│   └── e2e/              # bats end-to-end tests and mocks
│
├── docs/                 # Documentation
│   └── philosophy.md     # Design principles
│
├── .github/
│   └── workflows/        # CI/CD pipelines
│       └── test.yml      # GitHub Actions test suite
│
├── shutsujin_departure.sh  # Daily deployment script
├── first_setup.sh          # First-time setup
├── CLAUDE.md               # Core system instructions (auto-loaded)
├── AGENTS.md               # Codex auto-load file
└── Makefile                # Development commands
```

### Key Directories

| Directory | Purpose | Important Notes |
|-----------|---------|-----------------|
| `scripts/` | Core system utilities | All scripts must pass shellcheck |
| `instructions/` | Agent behavior | CLI-specific instructions go in `cli_specific/` |
| `lib/` | Shared libraries | `cli_adapter.sh` handles CLI abstraction |
| `queue/` | Runtime data | Git-ignored, generated at runtime |
| `templates/` | Reusable templates | Used for reports and context files |
| `tests/` | Test suite | bats format, organized by level (unit/integration) |

---

## .gitignore Whitelist Approach

**CRITICAL:** This project uses a **whitelist-based .gitignore** strategy.

### How It Works

1. **Step 1**: Default `*` excludes everything from git
2. **Step 2**: `!*/` allows directory traversal
3. **Step 3**: Individual files and directories are explicitly allowed with `!filename`

### Adding New Files to Git

**Before adding a new file to git, you MUST add it to the .gitignore whitelist:**

```bash
# Example: Adding a new script to git

# 1. Create your file
touch scripts/new_script.sh

# 2. Edit .gitignore and add the whitelist entry
echo '!scripts/new_script.sh' >> .gitignore

# 3. Now git will track it
git add scripts/new_script.sh
git commit -m "feat: add new_script.sh"
```

### What Gets Excluded by Default

The following are intentionally excluded (do NOT whitelist these):

- `projects/` — Contains confidential client information
- `queue/` — Runtime data, generated dynamically
- `memory/` — User-specific persistent memory
- `.claude/commands/` — User-specific skills (not committed)
- `saytask/streaks.yaml` — User-specific task data

### Checking Before Commit

```bash
# Verify your new file is tracked
git status

# If your file doesn't appear, check .gitignore
grep "your_file_name" .gitignore
```

---

## Coding Conventions

### Shell Scripts

All shell scripts must adhere to these standards:

1. **Shellcheck compliance**
   ```bash
   # Run shellcheck before committing
   make lint
   ```
   - Fix all warnings and errors
   - Use `# shellcheck disable=SCXXXX` only when absolutely necessary (with explanation)

2. **Shebang line**
   ```bash
   #!/usr/bin/env bash
   ```

3. **Error handling**
   ```bash
   set -euo pipefail  # Exit on error, undefined vars, pipe failures
   ```

4. **Function documentation**
   ```bash
   # Function: send_message
   # Description: Writes a message to an agent's inbox
   # Arguments:
   #   $1 - target_agent (shogun|karo|ashigaru1-8)
   #   $2 - message content
   # Returns: 0 on success, 1 on error
   send_message() {
       local target_agent="$1"
       local message="$2"
       # ... implementation
   }
   ```

5. **Variable naming**
   - `UPPERCASE` for constants and environment variables
   - `lowercase` for local variables
   - Use `local` for function-scoped variables

6. **Quoting**
   ```bash
   # Always quote variables to prevent word splitting
   echo "$VARIABLE"         # Good
   echo $VARIABLE           # Bad

   # Quote paths with spaces
   cd "$PROJECT_PATH"       # Good
   cd $PROJECT_PATH         # Bad
   ```

### YAML Files

1. **Indentation**: 2 spaces (no tabs)
2. **Booleans**: Use `true`/`false` (lowercase)
3. **Strings**: Quote when necessary, avoid excessive quoting
4. **Comments**: Use `#` for inline explanations

Example:
```yaml
# Task assignment for ashigaru1
task:
  task_id: subtask_001
  description: "Research React 19 features"
  status: assigned
  blockedBy: []  # No dependencies
```

### Markdown Files

1. **Line length**: No hard limit, but aim for readability (80-120 chars for prose)
2. **Headers**: Use ATX-style (`#` prefix)
3. **Code blocks**: Always specify language for syntax highlighting
4. **Links**: Use reference-style for repeated links

---

## Testing

### Test Levels

The project uses a three-tier testing strategy:

| Level | Type | Tool | Location | Run Command |
|-------|------|------|----------|-------------|
| L1 | Unit | bats | `tests/unit/` | `make test` |
| L2 | Integration | bats | `tests/integration/` | `make test-int` |
| L3 | End-to-End | Manual | N/A | Karo executes |

### SKIP = FAIL Policy

**CRITICAL RULE**: A test with SKIP count >= 1 is considered FAILED.

- Tests must either run or explicitly fail
- Do NOT report completion if tests were skipped
- Check prerequisites before running tests

### Running Tests

```bash
# Install test dependencies (first time only)
make install-deps

# Run unit tests
make test

# Run integration tests (Claude Code only)
make test-int

# Run shellcheck linter
make lint

# Build + diff check (CI equivalent)
make check
```

### Writing Tests

All tests use **bats** (Bash Automated Testing System):

```bash
#!/usr/bin/env bats
# test_example.bats

setup() {
    # Setup code runs before each test
    TEST_TMP="$(mktemp -d)"
}

teardown() {
    # Cleanup code runs after each test
    rm -rf "$TEST_TMP"
}

@test "inbox_write.sh creates inbox file" {
    run bash scripts/inbox_write.sh karo 'test message' cmd_new shogun
    [ "$status" -eq 0 ]
    [ -f "queue/inbox/karo.yaml" ]
}
```

### Test Guidelines

1. **Preflight checks**: Verify all prerequisites before running tests
   ```bash
   @test "check tmux is installed" {
       command -v tmux || skip "tmux not installed"
   }
   ```

2. **Isolation**: Tests must not interfere with each other
   - Use temporary directories (`mktemp -d`)
   - Clean up after each test in `teardown()`

3. **Assertions**: Use bats-assert for clear error messages
   ```bash
   load 'test_helper/bats-assert/load'

   @test "example assertion" {
       run some_command
       assert_success
       assert_output --partial "expected text"
   }
   ```

4. **E2E tests**: Only Karo can execute E2E tests (requires multi-agent control)

### Known Pitfalls

Two environment-specific traps found while writing bats tests that touch
`/proc` or process hierarchy (`tests/unit/test_task_complete.bats`,
cmd_190, 2026-08-02). Trap 2 showed the hardest-to-notice symptom:
**green locally, red only on CI.** Trap 1 was caught locally during
implementation, before it ever reached CI.

1. **bash's tail-call `exec` optimization shifts `$PPID` up one level**
   - **Trigger**: In a bats test that runs `bash -c "..."` and inspects
     `$PPID` from inside the invoked script, if the last command in the
     `bash -c` string is the target script itself, bash replaces the
     subshell process with that command via `exec` instead of forking a
     new process for it. The target script's `$PPID` then points to the
     *grandparent* shell instead of the `bash -c` subshell the test
     expected.
   - **Symptom**: Assertions based on `$PPID`/`/proc/$PPID/cmdline`
     intermittently see the wrong parent process, because whether the
     optimization kicks in depends on what follows the target command in
     the string — this can differ across shells/environments, so it
     tends to pass locally and fail only on CI (or vice versa).
   - **Workaround**: Append a no-op command after the target invocation
     inside the `bash -c` string (e.g. `; :`) so the target is no longer
     the tail call and bash forks a real subprocess for it instead of
     replacing the subshell.
   - **Source**: `tests/unit/test_task_complete.bats:295-298`
     (TC-TCOMP-EXP-001/002), found by ashigaru7 during cmd_190
     (`task_complete.sh` `--message-file` work), PR #56, endorsed by
     gunshi QC (`queue/reports/gunshi_qc_190_pr56.yaml`).

2. **`unshare -rm` is rejected on ubuntu-latest (GitHub Actions)**
   - **Trigger**: A bats test that uses an unprivileged user+mount
     namespace (`unshare -rm`) to simulate an unusual `/proc` state (e.g.
     `/proc` unreadable/replaced) for the process under test.
   - **Symptom**: The command works locally (including on macOS, where
     `/proc` doesn't exist at all so the scenario is moot) but on
     `ubuntu-latest` in GitHub Actions, `unshare -rm` itself is refused
     because of AppArmor's unprivileged userns restriction — the test
     that relies on it fails to even set up its precondition. This is
     the same "green locally, red only on CI" shape: nothing about the
     target code changed, only the CI runner's AppArmor policy blocks the
     setup step.
   - **Workaround**: Detect the restriction (`command -v unshare
     >/dev/null 2>&1 && unshare -rm -- true >/dev/null 2>&1`) and `skip`
     the test with a `"(CI environment)"`-tagged reason when it fails,
     per the existing SKIP=FAIL-exempt convention
     (`tests/unit/test_cli_adapter.bats:690`). Don't let the test error
     out — and don't drop coverage entirely either: keep the scenario
     exercised wherever it *can* run (e.g. macOS's natural absence of
     `/proc` covers the same code path by a different route).
   - **Source**: `tests/unit/test_task_complete.bats:336-355`
     (TC-TCOMP-EXP-004), found by ashigaru7 during cmd_190
     (`task_complete.sh` `--message-file` work), PR #56, endorsed by
     gunshi QC (`queue/reports/gunshi_qc_190_pr56.yaml`).

3. **`gh run rerun` replays the recorded commit, not the latest base
   branch content**
   - **Trigger**: A PR is open against a base branch (e.g. `develop`)
     that receives new commits after the PR's last CI run — for
     example, a shared bats baseline file gets fixed on the base branch
     while the PR itself hasn't merged that fix in yet. Someone then
     runs `gh run rerun <run-id> --failed` (or re-runs via the Actions
     UI) expecting the base branch's fix to now apply.
   - **Symptom**: The rerun still fails on the exact same assertion,
     because `gh run rerun` replays the workflow against the commit SHA
     already recorded for that run (the PR branch's own tip) — it does
     **not** re-checkout or merge in anything that has landed on the
     base branch since. Looks like the fix "didn't work," but the fix
     was never present in the code being tested.
   - **Workaround**: Use `gh pr update-branch <PR-number>` instead (a
     GitHub-hosted merge of base into head, done entirely via the
     remote API — no local checkout needed, avoiding the shared-clone
     branch-collision risk class this repo has hit before, cmd_201).
     Only after the branch actually contains the base's new commit does
     re-running CI make sense. When comparing runs, check the run's
     `createdAt`/head SHA against the base branch's latest landing
     time — if the run predates the fix, its result is stale and
     uninformative regardless of pass/fail.
   - **Source**: cmd_203 T2, PR #68 and PR #70 (2026-08-06). On PR #68,
     `gh run rerun 31071117675 --failed` re-ran against headSha
     `585889df` (the PR branch's own unchanged tip) and still failed at
     04:52:18Z UTC — *after* the base-branch fix (PR #72) had already
     landed at 13:47 JST the same day. The run only went green
     (`31073587684`) once the branch actually contained a merge commit
     bringing in `origin/develop` (headSha `c1c9e9cb`); PR #68 needed
     three such merge commits in total (`ddb690fe`, `c6760911`,
     `c1c9e9cb`) because develop moved twice while the PR was open
     (PR #72 at 13:47, PR #73 at 14:14). PR #70 hit the identical
     shape — its CI stayed on a stale run until the branch was updated
     with a real merge of `origin/develop` rather than a rerun. Found
     by ashigaru3, root-caused and verified by gunshi (3-run comparison,
     `queue/inbox/karo.yaml` message `msg_20260806_143818_b3fad97f`,
     2026-08-06 14:38 JST), escalated by shogun.

---

## CLAUDE.md へ条文を追加する前に

CLAUDE.mdは全エージェントが毎セッション読み込む文書である。そこに条文を
足す判断は**全軍への課税**であり、足す前に「本当に常駐させるべきか」を
判定する基準を持つ。

この基準は新規発明ではない。本リポジトリが既に用いていた2つの判断
（batsの罠は本ドキュメントの[Known Pitfalls](#known-pitfalls)へ移設・
`inbox_write`の手順はCLAUDE.mdへ常駐、という2判断）を言語化したものである。

### 判定の2軸

**軸1: 遭遇母数** — 全役職が日常的に通る場面か、特定の作業をする者だけが
通る場面か。

**軸2: 自覚可能性** — 発火の直前に「自分は今この規律の射程に居る」と
気づけるか。気づけるなら参照先を引ける。気づけないなら、あらかじめ
持っていなければ守りようがない。

### 判定表

| 軸2 | 軸1 | 判定 |
|-----|-----|------|
| 気づけない | （問わず） | **常駐**（引けぬのだから持たせるほかない） |
| 気づける | 全員毎日 | **常駐**（毎ターン引く手間のほうが高い） |
| 気づける | 一部 | **移設**（CLAUDE.mdには1行のポインタ） |

判定を書けないなら、その条文をCLAUDE.mdに常駐させてはならない。
`instructions/roles/` 等の役職別ファイルや、本ドキュメントのような
特定作業時に参照するファイルへの移設を検討すること。

### あてはめの例

- `inbox_write`: 全員が毎ターン行い、かつ「本文に記号が混じっている」
  ことに気づかぬまま踏む（実際に踏んだ例がある）→ 軸2気づけない →
  常駐。
- batsの罠: batsテストを書く者だけが遭遇し、その者は「自分は今bats
  を書いている」と自覚している → 軸2気づける・軸1一部 → 移設
  （[Known Pitfalls](#known-pitfalls)へ）。

PRでCLAUDE.mdへ条文を追加・拡張する場合は、PRテンプレートの該当項目に
この判定を1行で書くこと。

---

## Pull Request Guidelines

### Before Submitting

- [ ] All tests pass (`make test`, `make test-int`)
- [ ] Shellcheck passes (`make lint`)
- [ ] Generated instructions are in sync (`make check`)
- [ ] New files are added to `.gitignore` whitelist
- [ ] Commits have clear, descriptive messages
- [ ] Documentation is updated (if applicable)

### PR Title Format

Use conventional commit prefixes:

```
feat: add new CLI adapter for Kimi Code
fix: resolve inbox_watcher rc=1 on atomic writes
docs: update CONTRIBUTING.md with .gitignore rules
test: add unit tests for cli_adapter.sh
refactor: simplify inbox_write.sh message handling
```

### PR Description Template

```markdown
## Summary
Brief description of what this PR does.

## Motivation
Why is this change needed? What problem does it solve?

## Changes
- Bullet list of key changes
- Include file paths for context

## Testing
- [ ] Unit tests added/updated
- [ ] Integration tests pass
- [ ] Manually tested (describe how)

## Screenshots (if applicable)
Add screenshots for UI/UX changes.

## Related Issues
Closes #123
```

### Review Process

1. **Automated checks**: GitHub Actions will run tests and linters
2. **Code review**: At least one maintainer review required
3. **Testing**: Reviewers may request additional tests
4. **Documentation**: Ensure changes are documented

---

## Communication

### GitHub Issues

Use GitHub Issues for:
- **Bug reports** — Include reproduction steps, expected vs. actual behavior, environment details
- **Feature requests** — Describe the use case, proposed solution, alternatives considered
- **Questions** — Ask about implementation details, design decisions

**日本語でのイシュー報告も歓迎します** (Issues in Japanese are welcome).

### GitHub Discussions

Use GitHub Discussions for:
- Design proposals
- Architecture questions
- Best practices
- Showcase your workflow

### Bug Report Template

```markdown
**Describe the bug**
A clear description of what the bug is.

**To Reproduce**
Steps to reproduce the behavior:
1. Run '...'
2. See error

**Expected behavior**
What you expected to happen.

**Actual behavior**
What actually happened.

**Environment**
- OS: [e.g., WSL2 Ubuntu 22.04]
- Claude Code version: [e.g., 1.2.3]
- Shell: [e.g., bash 5.1]

**Additional context**
Any other context about the problem.
```

---

## License

By contributing to multi-agent-shogun, you agree that your contributions will be licensed under the [MIT License](LICENSE).

---

## Credits

Contributions are recognized in the project README. Thank you for making multi-agent-shogun better!
