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

# ── Edge case tests ──────────────────────────────────────────────────────

@test "archive_meta handles empty file gracefully" {
  local file="$TMUX_ARCHIVE_DIR/empty_test.archive"
  touch "$file"
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    _tmux_archive_meta '$file'
  ")
  echo "result: $result"
  # Should return _legacy with empty fields
  [[ "$result" == "_legacy|"* ]]
}

@test "archive_meta handles file with no windows" {
  local file="$TMUX_ARCHIVE_DIR/nowin_test.archive"
  cat > "$file" << 'EOF'
SESSION_NAME=no-windows
SESSION_UUID=nowin-uuid
ARCHIVED_AT=2025-01-01 12:00:00
---WINDOWS---
---PANES---
---OPENCODE---
EOF
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    _tmux_archive_meta '$file'
  ")
  echo "result: $result"
  # uuid present, wins=0, oc_count=0
  [[ "$result" == "nowin-uuid|no-windows|"* ]]
  [[ "$result" == *"|0|0|0|"* ]]
}

@test "archive_meta handles file without OPENCODE section" {
  local file="$TMUX_ARCHIVE_DIR/nooc_test.archive"
  cat > "$file" << 'EOF'
SESSION_NAME=no-oc
SESSION_UUID=nooc-uuid
ARCHIVED_AT=2025-01-01 12:00:00
---WINDOWS---
1|editor|tiled
---PANES---
no-oc|1|0|/tmp|vim|vim
EOF
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    _tmux_archive_meta '$file'
  ")
  echo "result: $result"
  [[ "$result" == "nooc-uuid|no-oc|"* ]]
  # 1 window, 0 oc
  [[ "$result" == *"|1|0|0|"* ]]
}

@test "archive_meta detects AUTO_ARCHIVED flag" {
  local file="$TMUX_ARCHIVE_DIR/auto_test.archive"
  cat > "$file" << 'EOF'
SESSION_NAME=auto-sess
SESSION_UUID=auto-uuid
ARCHIVED_AT=2025-01-01 12:00:00
AUTO_ARCHIVED=true
---WINDOWS---
1|main|tiled
---PANES---
auto-sess|1|0|/tmp|zsh|zsh
---OPENCODE---
EOF
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    _tmux_archive_meta '$file'
  ")
  echo "result: $result"
  # is_auto=1 (4th field)
  local is_auto=$(echo "$result" | cut -d'|' -f4)
  [ "$is_auto" = "1" ]
}

@test "archive_meta extracts OC title and sid" {
  local file="$TMUX_ARCHIVE_DIR/octitle_test.archive"
  cat > "$file" << 'EOF'
SESSION_NAME=oc-titles
SESSION_UUID=octitle-uuid
ARCHIVED_AT=2025-01-01 12:00:00
---WINDOWS---
1|main|tiled
---PANES---
oc-titles|1|0|/tmp|zsh|OC | my chat
---OPENCODE---
1|0|ses_xyz789|my chat|/projects/foo
EOF
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    _tmux_archive_meta '$file'
  ")
  echo "result: $result"
  # oc_title=my chat (field 8), oc_sid=ses_xyz789 (field 9)
  local oc_title=$(echo "$result" | cut -d'|' -f8)
  local oc_sid=$(echo "$result" | cut -d'|' -f9)
  [ "$oc_title" = "my chat" ]
  [ "$oc_sid" = "ses_xyz789" ]
}

@test "archive_delete_file returns 1 for non-existent file" {
  run zsh -c "
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    _tmux_archive_delete_file '/tmp/nonexistent_archive_file.archive'
  "
  [ "$status" -eq 1 ]
}

@test "archives_for_uuid returns empty for non-existent UUID" {
  create_test_archive "proj" "existing-uuid" "20250101_120000"

  result=$(zsh -c "
    TMUX_ARCHIVE_DIR='$TMUX_ARCHIVE_DIR'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    _tmux_archives_for_uuid 'nonexistent-uuid-12345'
  ")
  echo "result: '$result'"
  [ -z "$(echo "$result" | tr -d '[:space:]')" ]
}

@test "archives_for_uuid returns 1 for empty argument" {
  run zsh -c "
    TMUX_ARCHIVE_DIR='$TMUX_ARCHIVE_DIR'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    _tmux_archives_for_uuid ''
  "
  [ "$status" -eq 1 ]
}

@test "archive_groups returns empty for empty directory" {
  # TMUX_ARCHIVE_DIR already points to empty temp dir
  result=$(zsh -c "
    TMUX_ARCHIVE_DIR='$TMUX_ARCHIVE_DIR'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    _tmux_archive_groups
  ")
  echo "result: '$result'"
  [ -z "$(echo "$result" | tr -d '[:space:]')" ]
}

@test "build_group_preview_cache creates valid cache file" {
  local uuid="cache-uuid"
  create_test_archive "proj-a" "$uuid" "20250101_120000"
  create_test_archive "proj-a" "$uuid" "20250102_120000"
  create_test_archive "other" "other-uuid" "20250103_120000"

  local cache_file
  cache_file=$(zsh -c "
    TMUX_ARCHIVE_DIR='$TMUX_ARCHIVE_DIR'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    _tmux_build_group_preview_cache
  ")
  echo "cache_file: $cache_file"
  [ -n "$cache_file" ]
  [ -f "$cache_file" ]

  # Cache should contain entries for both UUIDs
  local cache_lines
  cache_lines=$(grep -c '[^[:space:]]' "$cache_file")
  echo "cache lines: $cache_lines"
  [ "$cache_lines" -ge 3 ]

  # Both UUIDs should appear
  grep -q "$uuid" "$cache_file"
  grep -q "other-uuid" "$cache_file"

  rm -f "$cache_file"
}

@test "autoarchive_cleanup does nothing when disabled" {
  local uuid="nocleanup-uuid"
  for i in $(seq -w 1 12); do
    create_auto_archive "proj" "$uuid" "20250101_12${i}00"
    sleep 0.1
  done

  local count_before
  count_before=$(ls -1 "$TMUX_ARCHIVE_DIR"/*.archive 2>/dev/null | wc -l | tr -d ' ')
  [ "$count_before" -eq 12 ]

  zsh -c "
    TMUX_ARCHIVE_DIR='$TMUX_ARCHIVE_DIR'
    TMUX_ARCHIVE_AUTO_CLEANUP=0
    TMUX_ARCHIVE_AUTO_MAX_PER_UUID=5
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    _tmux_autoarchive_cleanup
  "

  local count_after
  count_after=$(ls -1 "$TMUX_ARCHIVE_DIR"/*.archive 2>/dev/null | wc -l | tr -d ' ')
  echo "after (disabled): $count_after"
  [ "$count_after" -eq 12 ]
}

@test "autoarchive_cleanup skips non-auto archives" {
  local uuid="mixed-uuid"
  # 8 auto + 4 manual = 12 total
  for i in $(seq -w 1 8); do
    create_auto_archive "proj" "$uuid" "20250101_10${i}00"
    sleep 0.1
  done
  for i in $(seq -w 1 4); do
    create_test_archive "proj" "$uuid" "20250101_20${i}00"
    sleep 0.1
  done

  local count_before
  count_before=$(ls -1 "$TMUX_ARCHIVE_DIR"/*.archive 2>/dev/null | wc -l | tr -d ' ')
  [ "$count_before" -eq 12 ]

  zsh -c "
    TMUX_ARCHIVE_DIR='$TMUX_ARCHIVE_DIR'
    TMUX_ARCHIVE_AUTO_CLEANUP=1
    TMUX_ARCHIVE_AUTO_MAX_PER_UUID=5
    TMUX_ARCHIVE_AUTO_MAX_AGE_DAYS=0
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    _tmux_autoarchive_cleanup
  "

  local count_after
  count_after=$(ls -1 "$TMUX_ARCHIVE_DIR"/*.archive 2>/dev/null | wc -l | tr -d ' ')
  echo "after mixed cleanup: $count_after"
  # 4 manual should survive + up to 5 auto = 9 max
  # manual archives are NOT touched by auto cleanup
  local manual_count
  manual_count=$(grep -rL 'AUTO_ARCHIVED=true' "$TMUX_ARCHIVE_DIR"/*.archive 2>/dev/null | wc -l | tr -d ' ')
  echo "manual surviving: $manual_count"
  [ "$manual_count" -eq 4 ]
}

@test "archive_delete_group returns 1 for empty argument" {
  run zsh -c "
    TMUX_ARCHIVE_DIR='$TMUX_ARCHIVE_DIR'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    _tmux_archive_delete_group ''
  "
  [ "$status" -eq 1 ]
}

@test "archive_meta handles special characters in session name" {
  local file="$TMUX_ARCHIVE_DIR/special_test.archive"
  cat > "$file" << 'EOF'
SESSION_NAME=my project (v2)
SESSION_UUID=special-uuid
ARCHIVED_AT=2025-01-01 12:00:00
---WINDOWS---
1|main|tiled
---PANES---
my project (v2)|1|0|/tmp|zsh|zsh
---OPENCODE---
EOF
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    _tmux_archive_meta '$file'
  ")
  echo "result: $result"
  [[ "$result" == *"my project (v2)"* ]]
  [[ "$result" == *"special-uuid"* ]]
}

@test "archive_safe_name normalizes unsafe characters" {
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/lib/utils.sh'
    _tmux_archive_safe_name '../my session|name*'
  ")
  [ "$result" = "my_session_name" ]
}

@test "archive lock times out when lock directory is held" {
  run zsh -c "
    export TMUX_ARCHIVE_DIR='$TMUX_ARCHIVE_DIR'
    source '$TMUX_MANAGER_DIR/lib/utils.sh'
    lockdir=\$(_tmux_archive_lock_dir)
    mkdir -p \"\$lockdir\"
    date +%s > \"\$lockdir/created_at\"
    _tmux_archive_with_lock 1 true
  "
  [ "$status" -eq 1 ]
  [[ "$output" == *"락 획득 실패"* ]]
}
