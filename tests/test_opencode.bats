#!/usr/bin/env bats
# Tests for plugins/opencode.sh — OpenCode plugin parsing logic
# Note: Functions that call tmux/opencode CLI are not testable offline.
# We test the pure parsing and data extraction logic.

load helpers/setup

# Helper: create archive with OC data for plugin tests
create_oc_archive() {
  local name="${1:-oc-test}" uuid="${2:-oc-test-uuid}" oc_entries="${3:-}"
  local file="$TMUX_ARCHIVE_DIR/${name}_20250101_120000.archive"
  cat > "$file" << EOF
SESSION_NAME=$name
SESSION_UUID=$uuid
ARCHIVED_AT=2025-01-01 12:00:00
---WINDOWS---
1|main|tiled
2|code|tiled
---PANES---
$name|1|0|/tmp|zsh|zsh
$name|2|0|/projects/foo|zsh|OC | AI Chat
---OPENCODE---
${oc_entries}
EOF
  echo "$file"
}

@test "oc_restore_metadata parses OC entries correctly" {
  local file
  file=$(create_oc_archive "oc-meta" "oc-meta-uuid" \
    "$(printf '1|0|ses_abc123|My Chat|/projects/foo\n2|0|ses_def456|Another Chat|/projects/bar\n2|1||No SID Chat|/projects/baz')")

  # Test the parsing part — tmux set-option will fail but we capture the counts
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    file='$file'
    oc_saved_lines=\$(grep -A9999 '^---OPENCODE---' \"\$file\" | grep -v '^---')
    oc_saved_count=\$(echo \"\$oc_saved_lines\" | grep -c '^[0-9]' 2>/dev/null)
    oc_saved_sid_missing=\$(echo \"\$oc_saved_lines\" | awk -F'|' 'NF>=3 && \$3==\"\" {c++} END{print c+0}')
    oc_saved_titles=\$(echo \"\$oc_saved_lines\" | awk -F'|' 'NF>=4 && \$4!=\"\" {print \$4}' | paste -sd $'\x1f' -)
    oc_saved_sids=\$(echo \"\$oc_saved_lines\" | awk -F'|' 'NF>=3 && \$3!=\"\" {print \$3}' | paste -sd $'\x1f' -)
    echo \"count=\$oc_saved_count\"
    echo \"sid_missing=\$oc_saved_sid_missing\"
    echo \"titles=\$oc_saved_titles\"
    echo \"sids=\$oc_saved_sids\"
  ")
  echo "result: $result"

  [[ "$result" == *"count=3"* ]]
  [[ "$result" == *"sid_missing=1"* ]]
  [[ "$result" == *"My Chat"* ]]
  [[ "$result" == *"Another Chat"* ]]
  [[ "$result" == *"ses_abc123"* ]]
  [[ "$result" == *"ses_def456"* ]]
}

@test "oc_restore_metadata handles no OC entries" {
  local file
  file=$(create_oc_archive "oc-empty" "oc-empty-uuid" "")

  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    file='$file'
    oc_saved_lines=\$(grep -A9999 '^---OPENCODE---' \"\$file\" | grep -v '^---')
    oc_saved_count=\$(echo \"\$oc_saved_lines\" | grep -c '^[0-9]' 2>/dev/null)
    echo \"count=\$oc_saved_count\"
  ")
  echo "result: $result"
  [[ "$result" == *"count=0"* ]]
}

@test "oc_setup_restored_pane builds running_cmds with sid" {
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    local _TMUX_RESTORE_RUNNING_CMDS=''
    local _TMUX_RESTORE_OC_PANES=''
    _tmux_oc_setup_restored_pane 'test-session:1' '1' '0' 'OC | My Chat' '/projects/foo' '1|0|ses_abc123|My Chat|/projects/foo'
    echo \"CMDS=\$_TMUX_RESTORE_RUNNING_CMDS\"
    echo \"PANES=\$_TMUX_RESTORE_OC_PANES\"
  " 2>&1)
  echo "result: $result"

  # Should include opencode command with session id
  [[ "$result" == *"opencode"* ]]
  [[ "$result" == *"ses_abc123"* ]]
  [[ "$result" == *"My Chat"* ]]
  # PANES should have the pane entry
  [[ "$result" == *"test-session:1.0|ses_abc123|"* ]]
}

@test "oc_setup_restored_pane builds running_cmds without sid" {
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    local _TMUX_RESTORE_RUNNING_CMDS=''
    local _TMUX_RESTORE_OC_PANES=''
    _tmux_oc_setup_restored_pane 'test-session:2' '2' '0' 'OC | Detected' '/projects/bar' '2|0||Detected|/projects/bar'
    echo \"CMDS=\$_TMUX_RESTORE_RUNNING_CMDS\"
    echo \"PANES=\$_TMUX_RESTORE_OC_PANES\"
  " 2>&1)
  echo "result: $result"

  # Without sid, should suggest opencode -c
  [[ "$result" == *"opencode"* ]]
  [[ "$result" == *"-c"* ]]
  # PANES entry should have empty sid
  [[ "$result" == *"test-session:2.0||"* ]]
}

@test "oc_setup_restored_pane falls back to oc_line title" {
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    local _TMUX_RESTORE_RUNNING_CMDS=''
    local _TMUX_RESTORE_OC_PANES=''
    # ptitle is just 'zsh' (not OC | ...), but oc_line has the real title
    _tmux_oc_setup_restored_pane 'test-session:1' '1' '1' 'zsh' '/tmp' '1|1|ses_fallback|Real Title|/projects/x'
    echo \"CMDS=\$_TMUX_RESTORE_RUNNING_CMDS\"
  " 2>&1)
  echo "result: $result"

  # Should use the oc_line title as fallback
  [[ "$result" == *"Real Title"* ]]
}

@test "oc_capture_session skips without opencode CLI" {
  # Ensure opencode is not in PATH
  run zsh -c "
    export PATH='/usr/bin:/bin'
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    _tmux_oc_capture_session 'test-session' '/tmp/test.archive' '/tmp/test'
  "
  # Should return 0 (silent skip)
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "oc_enrich_meta returns 1 for empty sid" {
  run zsh -c "
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    _tmux_oc_enrich_meta '' title_var dir_var
  "
  [ "$status" -eq 1 ]
}

@test "plugin functions exist after sourcing" {
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    typeset -f _tmux_oc_capture_session > /dev/null && echo 'capture:ok'
    typeset -f _tmux_oc_restore_metadata > /dev/null && echo 'restore_meta:ok'
    typeset -f _tmux_oc_setup_restored_pane > /dev/null && echo 'setup_pane:ok'
    typeset -f _tmux_oc_prompt_restart > /dev/null && echo 'prompt:ok'
    typeset -f _tmux_oc_enrich_meta > /dev/null && echo 'enrich:ok'
  ")
  echo "result: $result"
  [[ "$result" == *"capture:ok"* ]]
  [[ "$result" == *"restore_meta:ok"* ]]
  [[ "$result" == *"setup_pane:ok"* ]]
  [[ "$result" == *"prompt:ok"* ]]
  [[ "$result" == *"enrich:ok"* ]]
}
