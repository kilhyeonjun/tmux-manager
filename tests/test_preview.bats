#!/usr/bin/env bats
# Tests for lib/preview.sh — fzf preview helper
# Note: 'live' mode requires a running tmux server.
# We test 'archive' mode (file-based) and 'group' mode (cache-based).

load helpers/setup

@test "preview.sh archive mode renders file header" {
  local file
  file=$(create_test_archive "preview-proj" "prev-uuid")

  result=$(zsh "$TMUX_MANAGER_DIR/lib/preview.sh" archive "$file" 2>&1)
  echo "result: $result"

  # Should contain session name and 'archived'
  [[ "$result" == *"preview-proj"* ]]
  [[ "$result" == *"archived"* ]]
}

@test "preview.sh archive mode shows window/pane count" {
  local file
  file=$(create_test_archive "count-proj" "count-uuid")

  result=$(zsh "$TMUX_MANAGER_DIR/lib/preview.sh" archive "$file" 2>&1)
  echo "result: $result"

  # Fixture has 2 windows, 2 panes
  [[ "$result" == *"2w"* ]]
  [[ "$result" == *"2p"* ]]
}

@test "preview.sh archive mode shows OC restore info" {
  local file="$TMUX_ARCHIVE_DIR/oc_preview_test.archive"
  cat > "$file" << 'EOF'
SESSION_NAME=oc-preview
SESSION_UUID=oc-prev-uuid
ARCHIVED_AT=2025-01-15 14:30:00
---WINDOWS---
1|main|tiled
---PANES---
oc-preview|1|0|/projects/foo|zsh|OC | AI Chat
---OPENCODE---
1|0|ses_abc123|AI Chat|/projects/foo
EOF

  result=$(zsh "$TMUX_MANAGER_DIR/lib/preview.sh" archive "$file" 2>&1)
  echo "result: $result"

  # Should show OC restore info
  [[ "$result" == *"opencode"* ]]
  [[ "$result" == *"AI Chat"* ]]
  [[ "$result" == *"ses_abc123"* ]]
}

@test "preview.sh archive mode with missing file exits 1" {
  run zsh "$TMUX_MANAGER_DIR/lib/preview.sh" archive "/tmp/nonexistent_file.archive"
  echo "output: $output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"파일 없음"* ]]
}

@test "preview.sh group mode with cache file" {
  local cache_file
  cache_file=$(mktemp -t tmux_test_cache)
  cat > "$cache_file" << 'EOF'
test-uuid|proj-a  2025-01-01  2w
test-uuid|proj-a  2025-01-02  3w
other-uuid|proj-b  2025-01-03  1w
EOF

  result=$(TMUX_GROUP_PREVIEW_CACHE="$cache_file" \
    zsh "$TMUX_MANAGER_DIR/lib/preview.sh" group "test-uuid" 2>&1)
  echo "result: $result"

  # Should show group header
  [[ "$result" == *"test-uuid"* ]]
  # Should show 2 entries for test-uuid (from cache)
  local entry_count
  entry_count=$(echo "$result" | grep -c "proj-a")
  [ "$entry_count" -eq 2 ]

  rm -f "$cache_file"
}

@test "preview.sh group mode with empty uuid exits 1" {
  run zsh "$TMUX_MANAGER_DIR/lib/preview.sh" group ""
  echo "output: $output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"UUID"* ]]
}

@test "preview.sh exits with error on unknown mode" {
  run zsh "$TMUX_MANAGER_DIR/lib/preview.sh" invalid_mode "arg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage"* ]]
}

@test "preview.sh exits with error on no arguments" {
  run zsh "$TMUX_MANAGER_DIR/lib/preview.sh"
  [ "$status" -eq 1 ]
}

@test "preview.sh archive mode handles multi-pane windows" {
  local file="$TMUX_ARCHIVE_DIR/multi_pane_test.archive"
  cat > "$file" << 'EOF'
SESSION_NAME=multi-pane
SESSION_UUID=mp-uuid
ARCHIVED_AT=2025-02-01 10:00:00
---WINDOWS---
1|editor|main-vertical
2|terminals|even-horizontal
---PANES---
multi-pane|1|0|/home/user/project|nvim|editor
multi-pane|1|1|/home/user/project|zsh|terminal
multi-pane|2|0|/var/log|tail|logs
multi-pane|2|1|/tmp|zsh|shell
---OPENCODE---
EOF

  result=$(zsh "$TMUX_MANAGER_DIR/lib/preview.sh" archive "$file" 2>&1)
  echo "result: $result"

  # Should show all 4 panes
  [[ "$result" == *"multi-pane"* ]]
  [[ "$result" == *"4p"* ]]
  # nvim and tail are non-shell commands — should be highlighted
  [[ "$result" == *"nvim"* ]]
  [[ "$result" == *"tail"* ]]
}
