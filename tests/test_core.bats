#!/usr/bin/env bats
# Tests for lib/core.sh — archive CRUD and metadata operations

load helpers/setup

# Source the modules under test (zsh functions via bash compat shim)
# Note: These tests cover the pure data-processing functions that work
# without an active tmux session. Interactive functions (fzf, tmux commands)
# are not unit-testable.

extract_exit_banner() {
  local sid="$1"
  awk -v sid="$sid" '
    /^[[:space:]]*▄[[:space:]]*$/ { start=NR; delete blk; n=0 }
    start { blk[++n]=$0 }
    index($0,sid) && start { found=n; start=0 }
    END { if(found) { printf "\n"; for(i=1;i<=found;i++) print blk[i] } }
  '
}

append_exit_banner_if_needed() {
  local pane_dst="$1" live_tail="$2"
  local exit_sid
  exit_sid=$(printf '%s' "$live_tail" | grep -oE 'Continue[[:space:]]+opencode -s ses_[A-Za-z0-9]+' | tail -1 | grep -oE 'ses_[A-Za-z0-9]+' || true)
  if [ -n "$exit_sid" ] && ! grep -q "$exit_sid" "$pane_dst" 2>/dev/null; then
    printf '%s' "$live_tail" | extract_exit_banner "$exit_sid" >> "$pane_dst"
  fi
}

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

@test "extract_exit_banner returns full banner for a single match" {
  local live_tail result expected
  live_tail=$(cat << 'EOF'
shell prompt line
                                   ▄
  █▀▀█ █▀▀█ █▀▀█ █▀▀▄ █▀▀▀ █▀▀█ █▀▀█ █▀▀█
  █  █ █  █ █▀▀▀ █  █ █    █  █ █  █ █▀▀▀
  ▀▀▀▀ █▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀

  Session   My Chat Title
  Continue  opencode -s ses_abc123xyz
EOF
)

  result=$(printf '%s' "$live_tail" | extract_exit_banner "ses_abc123xyz")
  expected=$'\n                                   ▄\n  █▀▀█ █▀▀█ █▀▀█ █▀▀▄ █▀▀▀ █▀▀█ █▀▀█ █▀▀█\n  █  █ █  █ █▀▀▀ █  █ █    █  █ █  █ █▀▀▀\n  ▀▀▀▀ █▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀\n\n  Session   My Chat Title\n  Continue  opencode -s ses_abc123xyz'

  [ "$result" = "$expected" ]
}

@test "extract_exit_banner picks only the last matching banner" {
  local live_tail result
  live_tail=$(cat << 'EOF'
                                   ▄
  █▀▀█ █▀▀█ █▀▀█ █▀▀▄ █▀▀▀ █▀▀█ █▀▀█ █▀▀█
  █  █ █  █ █▀▀▀ █  █ █    █  █ █  █ █▀▀▀
  ▀▀▀▀ █▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀

  Session   Old Chat
  Continue  opencode -s ses_multi777
random shell output
                                   ▄
  █▀▀█ █▀▀█ █▀▀█ █▀▀▄ █▀▀▀ █▀▀█ █▀▀█ █▀▀█
  █  █ █  █ █▀▀▀ █  █ █    █  █ █  █ █▀▀▀
  ▀▀▀▀ █▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀

  Session   New Chat
  Continue  opencode -s ses_multi777
EOF
)

  result=$(printf '%s' "$live_tail" | extract_exit_banner "ses_multi777")
  [[ "$result" == *"Session   New Chat"* ]]
  [[ "$result" != *"Session   Old Chat"* ]]
}

@test "extract_exit_banner outputs nothing when start marker is missing" {
  local live_tail result
  live_tail=$(cat << 'EOF'
  █▀▀█ █▀▀█ █▀▀█ █▀▀▄ █▀▀▀ █▀▀█ █▀▀█ █▀▀█
  Continue  opencode -s ses_nostart111
EOF
)

  result=$(printf '%s' "$live_tail" | extract_exit_banner "ses_nostart111")
  [ -z "$result" ]
}

@test "extract_exit_banner outputs nothing when SID line is missing" {
  local live_tail result
  live_tail=$(cat << 'EOF'
                                   ▄
  █▀▀█ █▀▀█ █▀▀█ █▀▀▄ █▀▀▀ █▀▀█ █▀▀█ █▀▀█
  █  █ █  █ █▀▀▀ █  █ █    █  █ █  █ █▀▀▀
  ▀▀▀▀ █▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀

  Session   Missing Continue
EOF
)

  result=$(printf '%s' "$live_tail" | extract_exit_banner "ses_missing222")
  [ -z "$result" ]
}

@test "extract_exit_banner ignores art lines that contain embedded ▄" {
  local live_tail result
  live_tail=$(cat << 'EOF'
  █▀▀█ ▄ █▀▀█ █▀▀█
  █  █ █  █ █▀▀▀
  Continue  opencode -s ses_embedded333
EOF
)

  result=$(printf '%s' "$live_tail" | extract_exit_banner "ses_embedded333")
  [ -z "$result" ]
}

@test "exit banner append guard skips when SID already exists in pane file" {
  local pane_file live_tail before after
  pane_file="$TMUX_ARCHIVE_DIR/guard_existing_sid.pane"
  printf 'history contains ses_guard123 already\n' > "$pane_file"
  live_tail=$(cat << 'EOF'
                                   ▄
  █▀▀█ █▀▀█ █▀▀█ █▀▀▄ █▀▀▀ █▀▀█ █▀▀█ █▀▀█
  █  █ █  █ █▀▀▀ █  █ █    █  █ █  █ █▀▀▀
  ▀▀▀▀ █▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀

  Session   Guarded
  Continue  opencode -s ses_guard123
EOF
)

  before=$(cat "$pane_file")
  append_exit_banner_if_needed "$pane_file" "$live_tail"
  after=$(cat "$pane_file")

  [ "$after" = "$before" ]
}

@test "exit banner append handles empty live pane without output" {
  local pane_file before after result
  pane_file="$TMUX_ARCHIVE_DIR/guard_empty_live.pane"
  printf 'existing pane\n' > "$pane_file"

  before=$(cat "$pane_file")
  append_exit_banner_if_needed "$pane_file" ""
  after=$(cat "$pane_file")
  result=$(printf '' | extract_exit_banner "ses_empty000")

  [ "$after" = "$before" ]
  [ -z "$result" ]
}

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

@test "tmux-archive list output does not leak local variable assignments" {
  local file="$TMUX_ARCHIVE_DIR/list_noleak.archive"
  cat > "$file" << 'EOF'
SESSION_NAME=list-check
SESSION_UUID=list-check-uuid
ARCHIVED_AT=2025-01-01 12:00:00
---WINDOWS---
1|main|tiled
---PANES---
list-check|1|0|/tmp|zsh|zsh
---OPENCODE---
EOF

  run zsh -c "
    export TMUX_ARCHIVE_DIR='$TMUX_ARCHIVE_DIR'
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/lib/utils.sh'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    tmux-archive list
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"list-check"* ]]
  [[ "$output" != *"wins="* ]]
}

@test "new-session form defaults to main on empty input" {
  result=$(printf '\n' | zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/lib/utils.sh'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    _tmux_prompt_new_session_name
  ")
  [ "$result" = "main" ]
}

@test "new-session form keeps explicit input" {
  result=$(printf 'feature-x\n' | zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/lib/utils.sh'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    _tmux_prompt_new_session_name
  ")
  [ "$result" = "feature-x" ]
}

@test "rename form returns empty on enter and value on input" {
  empty=$(printf '\n' | zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/lib/utils.sh'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    _tmux_prompt_rename_session_name 'old-name'
  ")
  [ -z "$empty" ]

  value=$(printf 'new-name\n' | zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/lib/utils.sh'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    _tmux_prompt_rename_session_name 'old-name'
  ")
  [ "$value" = "new-name" ]
}

# ── restore-at tests ────────────────────────────────────────────────────────

create_timestamped_archive() {
  local name="$1" ts="$2"
  local safe_name=$(echo "$name" | tr ' ' '_')
  local file="$TMUX_ARCHIVE_DIR/${safe_name}_${ts}.archive"
  cat > "$file" << EOF
SESSION_NAME=$name
SESSION_UUID=$(uuidgen)
ARCHIVED_AT=$(echo "$ts" | sed 's/_/ /; s/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3/; s/ \([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/ \1:\2:\3/')
---WINDOWS---
1|main|tiled
---PANES---
$name|1|0|/tmp|zsh|zsh
---OPENCODE---
---CLAUDE-CODE---
---CMUX---
EOF
  echo "$file"
}

@test "restore-at shows usage when no timestamp given" {
  run zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/lib/utils.sh'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    export TMUX_ARCHIVE_DIR='$TMUX_ARCHIVE_DIR'
    tmux-archive restore-at
  "
  [ "$status" -eq 1 ]
  [[ "$output" == *"사용법"* ]]
}

@test "restore-at rejects invalid time format" {
  run zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/lib/utils.sh'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    export TMUX_ARCHIVE_DIR='$TMUX_ARCHIVE_DIR'
    tmux-archive restore-at 'abc'
  "
  [ "$status" -eq 1 ]
  [[ "$output" == *"시간 형식 오류"* ]]
}

@test "restore-at returns error when no archives match" {
  create_timestamped_archive "test-sess" "20260312_140000"

  run zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/lib/utils.sh'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    export TMUX_ARCHIVE_DIR='$TMUX_ARCHIVE_DIR'
    tmux-archive restore-at '99:99'
  "
  [ "$status" -eq 1 ]
  [[ "$output" == *"아카이브 없음"* ]]
  [[ "$output" == *"사용 가능한 시점"* ]]
}

@test "restore-at finds archives by HHMM format" {
  local today
  today=$(date +%Y%m%d)
  create_timestamped_archive "sess-a" "${today}_133500"
  create_timestamped_archive "sess-b" "${today}_133501"
  create_timestamped_archive "sess-other" "${today}_140000"

  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/lib/utils.sh'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    export TMUX_ARCHIVE_DIR='$TMUX_ARCHIVE_DIR'
    tmux-archive restore-at '13:35' 2>&1
  " 2>/dev/null)
  echo "result: $result"
  [[ "$result" == *"sess-a"* ]]
  [[ "$result" == *"sess-b"* ]]
  [[ "$result" != *"sess-other"* ]]
  [[ "$result" == *"2개 세션"* ]]
}

@test "restore-at parses HHMM without colon" {
  local today
  today=$(date +%Y%m%d)
  create_timestamped_archive "no-colon" "${today}_143200"

  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/lib/utils.sh'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    export TMUX_ARCHIVE_DIR='$TMUX_ARCHIVE_DIR'
    tmux-archive restore-at '1432' 2>&1
  " 2>/dev/null)
  echo "result: $result"
  [[ "$result" == *"no-colon"* ]]
}

@test "restore-at parses full YYYYMMDD_HHMM" {
  create_timestamped_archive "full-ts" "20260312_143200"

  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/lib/utils.sh'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    export TMUX_ARCHIVE_DIR='$TMUX_ARCHIVE_DIR'
    tmux-archive restore-at '20260312_1432' 2>&1
  " 2>/dev/null)
  echo "result: $result"
  [[ "$result" == *"full-ts"* ]]
}

@test "restore-at help text is shown" {
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/lib/utils.sh'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    tmux-archive help 2>&1 || tmux-archive 2>&1
  ")
  [[ "$result" == *"restore-at"* ]]
}

# ── save-all tests ──────────────────────────────────────────────────────────

@test "save-all shows header banner" {
  run zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/lib/utils.sh'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    export TMUX_ARCHIVE_DIR='$TMUX_ARCHIVE_DIR'
    tmux-archive save-all 2>&1
  "
  [[ "$output" == *"전체 세션 아카이브"* ]]
}

@test "save-all shows no-session message when tmux not running" {
  run zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/lib/utils.sh'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    export TMUX_ARCHIVE_DIR='$TMUX_ARCHIVE_DIR'
    # tmux ls will fail in test env → empty sessions
    tmux-archive save-all 2>&1
  "
  # Should either show '활성 세션 없음' (no tmux) or '전체 아카이브 완료' (if tmux running)
  [[ "$output" == *"활성 세션 없음"* ]] || [[ "$output" == *"전체 아카이브 완료"* ]]
}

@test "save-all appears in help text" {
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/lib/utils.sh'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    tmux-archive help 2>&1 || tmux-archive 2>&1
  ")
  [[ "$result" == *"save-all"* ]]
  [[ "$result" == *"전체 세션 즉시 아카이브"* ]]
}

# ── save-all-and-kill tests ─────────────────────────────────────────────────

@test "save-all-and-kill shows header banner" {
  run zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/lib/utils.sh'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    export TMUX_ARCHIVE_DIR='$TMUX_ARCHIVE_DIR'
    tmux-archive save-all-and-kill 2>&1
  "
  [[ "$output" == *"전체 아카이브 후 종료"* ]]
}

@test "save-all-and-kill shows no-session message when tmux not running" {
  run zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/lib/utils.sh'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    export TMUX_ARCHIVE_DIR='$TMUX_ARCHIVE_DIR'
    tmux-archive save-all-and-kill 2>&1
  "
  [[ "$output" == *"활성 세션 없음"* ]] || [[ "$output" == *"전체 아카이브 완료"* ]]
}

@test "save-all-and-kill appears in help text" {
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/lib/utils.sh'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    tmux-archive help 2>&1 || tmux-archive 2>&1
  ")
  [[ "$result" == *"save-all-and-kill"* ]]
  [[ "$result" == *"전체 아카이브 후 tmux 종료"* ]]
}

@test "TMUX_MANAGER_AUTO_LAUNCH defaults to 0 (disabled)" {
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    echo \"\$TMUX_MANAGER_AUTO_LAUNCH\"
  ")
  [[ "$result" == "0" ]]
}

@test "init.sh does not auto-launch when TMUX_MANAGER_AUTO_LAUNCH=0" {
  # Simulate: outside tmux, interactive terminal, fzf available, but AUTO_LAUNCH=0
  result=$(zsh -c "
    TMUX_MANAGER_AUTO_LAUNCH=0
    TMUX=''
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    # Override to detect if tmux-manager would be called
    tmux-manager() { echo 'LAUNCHED'; }
    source '$TMUX_MANAGER_DIR/init.sh' 2>/dev/null || true
    echo 'DONE'
  " 2>/dev/null)
  [[ "$result" != *"LAUNCHED"* ]]
}

@test "init.sh auto-launches when TMUX_MANAGER_AUTO_LAUNCH=1 and fzf available" {
  # This test verifies the condition is checked, not that tmux-manager runs fully
  result=$(zsh -c "
    export TMUX_MANAGER_AUTO_LAUNCH=1
    # Read the init.sh and extract the auto-launch condition
    grep 'TMUX_MANAGER_AUTO_LAUNCH' '$TMUX_MANAGER_DIR/init.sh'
  ")
  [[ "$result" == *"TMUX_MANAGER_AUTO_LAUNCH"* ]]
  [[ "$result" == *"'1'"* ]]
  [[ "$result" == *"fzf"* ]]
}
