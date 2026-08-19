#!/usr/bin/env bats
# agent_registry.sh / watcher_supervisor dynamic formation tests

setup() {
    TEST_TMP="$(mktemp -d)"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

teardown() {
    rm -rf "$TEST_TMP"
}

write_settings() {
    local path="$1"
    shift
    cat > "$path" << YAML
$*
YAML
}

load_registry_with() {
    export AGENT_REGISTRY_SETTINGS="$1"
    source "$PROJECT_ROOT/lib/agent_registry.sh"
}

join_lines() {
    tr '\n' ' ' | sed 's/ $//'
}

@test "agent_registry: full cli.agents formation preserves configured order" {
    local settings="$TEST_TMP/settings.yaml"
    write_settings "$settings" 'cli:
  default: codex
  agents:
    shogun:
      type: codex
    karo:
      type: codex
    ashigaru2:
      type: codex
    gunshi:
      type: codex
    gunshi2:
      type: codex'

    load_registry_with "$settings"

    result=$(agent_registry_agents | join_lines)
    [ "$result" = "shogun karo ashigaru2 gunshi gunshi2" ]

    result=$(agent_registry_multiagent_agents | join_lines)
    [ "$result" = "karo ashigaru2 gunshi gunshi2" ]
}

@test "agent_registry: partial override config without karo falls back to legacy formation" {
    local settings="$TEST_TMP/settings.yaml"
    write_settings "$settings" 'cli:
  default: claude
  agents:
    ashigaru5: codex
    ashigaru7: copilot'

    load_registry_with "$settings"

    result=$(agent_registry_multiagent_agents | join_lines)
    [ "$result" = "karo ashigaru1 ashigaru2 ashigaru3 ashigaru4 ashigaru5 ashigaru6 ashigaru7 gunshi" ]
}

@test "agent_registry: pane mapping follows configured order and pane base" {
    local settings="$TEST_TMP/settings.yaml"
    write_settings "$settings" 'cli:
  agents:
    shogun:
      type: codex
    karo:
      type: codex
    ashigaru4:
      type: codex
    gunshi:
      type: codex
    gunshi2:
      type: codex'

    load_registry_with "$settings"

    [ "$(agent_registry_pane_for_agent shogun 1)" = "shogun:main.0" ]
    [ "$(agent_registry_multiagent_pane_for_agent karo 1)" = "multiagent:agents.1" ]
    [ "$(agent_registry_multiagent_pane_for_agent ashigaru4 1)" = "multiagent:agents.2" ]
    [ "$(agent_registry_multiagent_pane_for_agent gunshi2 1)" = "multiagent:agents.4" ]
}

@test "watcher_supervisor: --print-watchers uses dynamic settings and pane base" {
    local settings="$TEST_TMP/settings.yaml"
    write_settings "$settings" 'cli:
  agents:
    shogun:
      type: codex
    karo:
      type: codex
    ashigaru3:
      type: codex
    gunshi:
      type: codex
    gunshi2:
      type: codex'

    run env AGENT_REGISTRY_SETTINGS="$settings" SHOGUN_PANE_BASE=1 \
        bash "$PROJECT_ROOT/scripts/watcher_supervisor.sh" --print-watchers

    [ "$status" -eq 0 ]
    [[ "$output" == *$'shogun\tshogun:main.0\tlogs/inbox_watcher_shogun.log'* ]]
    [[ "$output" == *$'karo\tmultiagent:agents.1\tlogs/inbox_watcher_karo.log'* ]]
    [[ "$output" == *$'ashigaru3\tmultiagent:agents.2\tlogs/inbox_watcher_ashigaru3.log'* ]]
    [[ "$output" == *$'gunshi\tmultiagent:agents.3\tlogs/inbox_watcher_gunshi.log'* ]]
    [[ "$output" == *$'gunshi2\tmultiagent:agents.4\tlogs/inbox_watcher_gunshi2.log'* ]]
}

@test "agent_registry: shogun pane matches the literal pane shutsujin_departure.sh passes to start_watcher_if_missing" {
    local settings="$TEST_TMP/settings.yaml"
    write_settings "$settings" 'cli:
  agents:
    shogun:
      type: codex'

    load_registry_with "$settings"

    local registry_pane
    registry_pane="$(agent_registry_pane_for_agent shogun)"

    # cmd_236: shutsujin_departure.sh は STEP 6.6 で watcher_supervisor.sh
    # の start_watcher_if_missing() を呼ぶ形へ差し替わった（scripts/inbox_watcher.sh
    # への直接nohupではない）。本テストの主旨（agent_registryの計算するshogun
    # paneと、shutsujin側が実際に使うリテラルpaneが一致すること）はそのまま、
    # 照合先の呼び出し形だけ新実装に合わせる。
    local departure_script="$PROJECT_ROOT/shutsujin_departure.sh"
    [ -f "$departure_script" ]
    grep -q "start_watcher_if_missing \"shogun\" \"${registry_pane}\"" "$departure_script" \
        || { echo "agent_registry shogun pane ($registry_pane) not found as literal in $departure_script"; false; }
}

@test "agent_registry: every agent's pane structurally matches watcher_supervisor.sh's pane_exists() grep -qx format (cmd_176 PR#38 regression guard)" {
    load_registry_with "$TEST_TMP/nonexistent_settings.yaml"

    # Mocked `tmux list-panes -a -F "#{session_name}:#{window_name}.#{pane_index}"`
    # output for a freshly-formed session (pane_base=0): shogun's dedicated
    # window pane index 0, plus the multiagent window's per-agent panes.
    local mock_panes="$TEST_TMP/mock_panes.txt"
    {
        echo "shogun:main.0"
        local idx=0
        while IFS= read -r agent; do
            echo "multiagent:agents.${idx}"
            idx=$((idx + 1))
        done < <(agent_registry_multiagent_agents)
    } > "$mock_panes"

    while IFS= read -r agent; do
        local pane
        pane="$(agent_registry_pane_for_agent "$agent" 0)"
        # Same exact-match logic as watcher_supervisor.sh's pane_exists():
        # `grep -qx` against the real tmux list-panes output format.
        grep -qx "$pane" "$mock_panes" \
            || { echo "agent=${agent} pane=${pane} does NOT structurally match pane_exists() format. Mocked tmux list-panes output was:"; cat "$mock_panes"; false; }
    done < <(agent_registry_agents)
}

@test "agent_registry: a shogun pane value without .pane_index (the pre-fix PR#38 defect, e.g. 'shogun:main') fails pane_exists() exact-match" {
    local mock_panes="$TEST_TMP/mock_panes.txt"
    printf 'shogun:main.0\nmultiagent:agents.0\n' > "$mock_panes"

    local broken_pane="shogun:main"
    ! grep -qx "$broken_pane" "$mock_panes" \
        || { echo "BUG: '$broken_pane' unexpectedly matched pane_exists() format — this test should catch the exact PR#38 regression (silent no-op start_watcher_if_missing early-return)"; false; }
}
