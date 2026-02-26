#!/usr/bin/env bats
# Tests for lib/core.sh — archive CRUD and metadata operations

load helpers/setup

# Source the modules under test (zsh functions via bash compat shim)
# Note: These tests cover the pure data-processing functions that work
# without an active tmux session. Interactive functions (fzf, tmux commands)
# are not unit-testable.

@test "archive_meta parses well-formed archive file" {
  local file
  file=$(create_test_archive "my-project" "abc-123-uuid")
  # _tmux_archive_meta is zsh — call via zsh
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    _tmux_archive_meta '$file'
  ")
  # Format: uuid|name|date|is_auto|wins|oc_count|sid_missing|oc_title|oc_sid
  echo "result: $result"
  [[ "$result" == *"abc-123-uuid"* ]]
  [[ "$result" == *"my-project"* ]]
  # Should have 2 windows
  [[ "$result" == *"|2|"* ]]
}

@test "archive_meta returns _legacy for files without UUID" {
  local file="$TMUX_ARCHIVE_DIR/legacy_test.archive"
  cat > "$file" << 'EOF'
SESSION_NAME=legacy
ARCHIVED_AT=2025-01-01 12:00:00
---WINDOWS---
1|main|tiled
---PANES---
legacy|1|0|/tmp|zsh|zsh
---OPENCODE---
EOF
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    _tmux_archive_meta '$file'
  ")
  echo "result: $result"
  [[ "$result" == "_legacy|"* ]]
}

@test "archive_meta counts OC entries" {
  local file="$TMUX_ARCHIVE_DIR/oc_test.archive"
  cat > "$file" << 'EOF'
SESSION_NAME=oc-test
SESSION_UUID=oc-uuid
ARCHIVED_AT=2025-01-01 12:00:00
---WINDOWS---
1|main|tiled
---PANES---
oc-test|1|0|/tmp|zsh|OC | my title
---OPENCODE---
1|0|ses_abc123|my title|/projects/foo
1|1||another title|/projects/bar
EOF
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    _tmux_archive_meta '$file'
  ")
  echo "result: $result"
  # oc_count=2, sid_missing=1
  [[ "$result" == *"|2|1|"* ]]
}

@test "archive_groups aggregates by UUID" {
  local uuid="group-test-uuid"
  create_test_archive "proj" "$uuid" "20250101_120000"
  create_test_archive "proj" "$uuid" "20250102_120000"
  create_test_archive "other" "other-uuid" "20250103_120000"

  result=$(zsh -c "
    TMUX_ARCHIVE_DIR='$TMUX_ARCHIVE_DIR'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    _tmux_archive_groups
  ")
  echo "result: $result"
  # group-test-uuid should have count=2
  [[ "$result" == *"$uuid|proj|2|"* ]]
  # other-uuid should have count=1
  [[ "$result" == *"other-uuid|other|1|"* ]]
}

@test "archive_delete_file removes archive and pane files" {
  local file
  file=$(create_test_archive "delete-me")
  local base="${file%.archive}"
  # Create fake pane files
  echo "scrollback" > "${base}_w1_p0.pane"
  echo "scrollback" > "${base}_w2_p0.pane"

  [ -f "$file" ]
  [ -f "${base}_w1_p0.pane" ]

  zsh -c "
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    _tmux_archive_delete_file '$file'
  "

  [ ! -f "$file" ]
  [ ! -f "${base}_w1_p0.pane" ]
  [ ! -f "${base}_w2_p0.pane" ]
}

@test "archive_delete_group removes all archives for UUID" {
  local uuid="del-group-uuid"
  create_test_archive "proj" "$uuid" "20250101_120000"
  create_test_archive "proj" "$uuid" "20250102_120000"
  create_test_archive "keep" "keep-uuid" "20250103_120000"

  local count_before
  count_before=$(ls -1 "$TMUX_ARCHIVE_DIR"/*.archive 2>/dev/null | wc -l | tr -d ' ')
  [ "$count_before" -eq 3 ]

  zsh -c "
    TMUX_ARCHIVE_DIR='$TMUX_ARCHIVE_DIR'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    _tmux_archive_delete_group '$uuid'
  "

  local count_after
  count_after=$(ls -1 "$TMUX_ARCHIVE_DIR"/*.archive 2>/dev/null | wc -l | tr -d ' ')
  [ "$count_after" -eq 1 ]
}

@test "archives_for_uuid filters correctly" {
  local uuid="filter-uuid"
  create_test_archive "proj" "$uuid" "20250101_120000"
  create_test_archive "proj" "$uuid" "20250102_120000"
  create_test_archive "other" "other-uuid" "20250103_120000"

  result=$(zsh -c "
    TMUX_ARCHIVE_DIR='$TMUX_ARCHIVE_DIR'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    _tmux_archives_for_uuid '$uuid'
  " | grep -c '[^[:space:]]')
  echo "result: $result"
  [ "$result" -eq 2 ]
}

@test "autoarchive_cleanup respects max_per_uuid" {
  local uuid="cleanup-uuid"
  # Create 12 auto archives (exceeds max of 10)
  for i in $(seq -w 1 12); do
    create_auto_archive "proj" "$uuid" "20250101_12${i}00"
    sleep 0.1  # ensure different timestamps
  done

  local count_before
  count_before=$(ls -1 "$TMUX_ARCHIVE_DIR"/*.archive 2>/dev/null | wc -l | tr -d ' ')
  [ "$count_before" -eq 12 ]

  zsh -c "
    TMUX_ARCHIVE_DIR='$TMUX_ARCHIVE_DIR'
    TMUX_ARCHIVE_AUTO_CLEANUP=1
    TMUX_ARCHIVE_AUTO_MAX_PER_UUID=10
    TMUX_ARCHIVE_AUTO_MAX_AGE_DAYS=0
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    _tmux_autoarchive_cleanup
  "

  local count_after
  count_after=$(ls -1 "$TMUX_ARCHIVE_DIR"/*.archive 2>/dev/null | wc -l | tr -d ' ')
  echo "after cleanup: $count_after"
  [ "$count_after" -le 10 ]
}
