#!/usr/bin/env bats
# Tests for plugins/cmux.sh — cmux plugin detection, notification, metadata, and workspace logic
# Note: Functions that call cmux/tmux CLI are not testable offline.
# We test the pure parsing, detection, and data extraction logic.

load helpers/setup

# Helper: create archive with CMUX data
create_cmux_archive() {
  local name="${1:-cmux-test}" uuid="${2:-cmux-test-uuid}" cmux_entries="${3:-}"
  local file="$TMUX_ARCHIVE_DIR/${name}_20250101_120000.archive"
  cat > "$file" << EOF
FORMAT_VERSION=2
SESSION_NAME=$name
SESSION_UUID=$uuid
ARCHIVED_AT=2025-01-01 12:00:00
---WINDOWS---
1|main|tiled
---PANES---
$name|1|0|/tmp|zsh|zsh
---OPENCODE---
---CLAUDE-CODE---
---CMUX---
${cmux_entries}
EOF
  echo "$file"
}

@test "cmux plugin functions exist after sourcing" {
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/cmux.sh'
    typeset -f _tmux_cmux_is_inside >/dev/null && echo 'is_inside:ok'
    typeset -f _tmux_cmux_has_cli >/dev/null && echo 'has_cli:ok'
    typeset -f _tmux_cmux_notify >/dev/null && echo 'notify:ok'
    typeset -f _tmux_cmux_notify_save >/dev/null && echo 'notify_save:ok'
    typeset -f _tmux_cmux_notify_restore >/dev/null && echo 'notify_restore:ok'
    typeset -f _tmux_cmux_notify_restore_fail >/dev/null && echo 'notify_restore_fail:ok'
    typeset -f _tmux_cmux_rename_workspace >/dev/null && echo 'rename_workspace:ok'
    typeset -f _tmux_cmux_workspace_label >/dev/null && echo 'workspace_label:ok'
    typeset -f _tmux_cmux_capture_session >/dev/null && echo 'capture_session:ok'
    typeset -f _tmux_cmux_restore_metadata >/dev/null && echo 'restore_metadata:ok'
    typeset -f _tmux_cmux_setup_passthrough >/dev/null && echo 'setup_passthrough:ok'
  ")
  [[ "$result" == *"is_inside:ok"* ]]
  [[ "$result" == *"has_cli:ok"* ]]
  [[ "$result" == *"notify:ok"* ]]
  [[ "$result" == *"notify_save:ok"* ]]
  [[ "$result" == *"notify_restore:ok"* ]]
  [[ "$result" == *"notify_restore_fail:ok"* ]]
  [[ "$result" == *"rename_workspace:ok"* ]]
  [[ "$result" == *"workspace_label:ok"* ]]
  [[ "$result" == *"capture_session:ok"* ]]
  [[ "$result" == *"restore_metadata:ok"* ]]
  [[ "$result" == *"setup_passthrough:ok"* ]]
}

@test "cmux_is_inside returns false without CMUX env vars" {
  result=$(zsh -c "
    unset CMUX_BUNDLE_ID CMUX_SOCKET_PATH
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/cmux.sh'
    _tmux_cmux_is_inside && echo 'inside' || echo 'outside'
  ")
  [ "$result" = "outside" ]
}

@test "cmux_is_inside returns true with CMUX_BUNDLE_ID" {
  result=$(zsh -c "
    export CMUX_BUNDLE_ID=com.cmuxterm.app
    unset CMUX_SOCKET_PATH
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/cmux.sh'
    _tmux_cmux_is_inside && echo 'inside' || echo 'outside'
  ")
  [ "$result" = "inside" ]
}

@test "cmux_is_inside returns true with valid CMUX_SOCKET_PATH" {
  local sock
  sock=$(mktemp -d)/cmux.sock
  # Create a Unix socket for testing
  python3 -c "
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind('$sock')
s.listen(1)
" &
  local py_pid=$!
  sleep 0.2

  result=$(zsh -c "
    unset CMUX_BUNDLE_ID
    export CMUX_SOCKET_PATH='$sock'
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/cmux.sh'
    _tmux_cmux_is_inside && echo 'inside' || echo 'outside'
  ")
  kill $py_pid 2>/dev/null || true
  rm -f "$sock"
  [ "$result" = "inside" ]
}

@test "cmux_notify_save skips when not inside cmux" {
  result=$(zsh -c "
    unset CMUX_BUNDLE_ID CMUX_SOCKET_PATH
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/cmux.sh'
    _tmux_cmux_notify_save 'test-session' '/tmp/test.archive' 'auto'
    echo ok
  ")
  [ "$result" = "ok" ]
}

@test "cmux_notify_restore_fail skips when not inside cmux" {
  result=$(zsh -c "
    unset CMUX_BUNDLE_ID CMUX_SOCKET_PATH
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/cmux.sh'
    _tmux_cmux_notify_restore_fail 'test failure'
    echo ok
  ")
  [ "$result" = "ok" ]
}

@test "cmux_workspace_label returns session name without git" {
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/cmux.sh'
    _tmux_cmux_workspace_label 'my-session' '/nonexistent/path'
  ")
  [ "$result" = "my-session" ]
}

@test "cmux_workspace_label appends branch in git repo" {
  local tmpdir
  tmpdir=$(mktemp -d)
  git -C "$tmpdir" init -q -b feature/test
  git -C "$tmpdir" commit --allow-empty -m "init" -q

  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/cmux.sh'
    _tmux_cmux_workspace_label 'my-session' '$tmpdir'
  ")
  rm -rf "$tmpdir"
  [ "$result" = "my-session (feature/test)" ]
}

@test "cmux_workspace_label handles empty cwd" {
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/cmux.sh'
    _tmux_cmux_workspace_label 'my-session' ''
  ")
  [ "$result" = "my-session" ]
}

@test "cmux_restore_metadata parses CMUX section correctly" {
  local file
  file=$(create_cmux_archive "cmux-meta" "cmux-meta-uuid" "ws-123|my-workspace|3000,8080")

  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/cmux.sh'
    cmux_lines=\$(_tmux_af_section_lines '$file' '---CMUX---' '')
    echo \"\$cmux_lines\" | while IFS='|' read -r wid wlabel ports; do
      [ -z \"\$wid\" ] && [ -z \"\$wlabel\" ] && continue
      echo \"id=\$wid\"
      echo \"label=\$wlabel\"
      echo \"ports=\$ports\"
    done
  ")
  [[ "$result" == *"id=ws-123"* ]]
  [[ "$result" == *"label=my-workspace"* ]]
  [[ "$result" == *"ports=3000,8080"* ]]
}

@test "cmux_restore_metadata handles empty CMUX section" {
  local file
  file=$(create_cmux_archive "cmux-empty" "cmux-empty-uuid" "")

  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/cmux.sh'
    cmux_lines=\$(_tmux_af_section_lines '$file' '---CMUX---' '')
    content=\$(echo \"\$cmux_lines\" | tr -d '[:space:]')
    [ -z \"\$content\" ] && echo 'empty' || echo 'has_data'
  ")
  [ "$result" = "empty" ]
}

@test "cmux_rename_workspace skips when not inside cmux" {
  result=$(zsh -c "
    unset CMUX_BUNDLE_ID CMUX_SOCKET_PATH
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/cmux.sh'
    _tmux_cmux_rename_workspace 'test-name'
    echo ok
  ")
  [ "$result" = "ok" ]
}

@test "cmux_rename_workspace skips empty name" {
  result=$(zsh -c "
    export CMUX_BUNDLE_ID=com.cmuxterm.app
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/cmux.sh'
    _tmux_cmux_rename_workspace ''
    echo ok
  ")
  [ "$result" = "ok" ]
}

@test "archive section parsing: OPENCODE ends at CMUX marker" {
  local file
  file=$(create_cmux_archive "section-test" "section-uuid" "ws-456|workspace|8080")
  # Add OC entry between OPENCODE and CMUX
  local tmpfile
  tmpfile=$(mktemp)
  awk '
    /^---OPENCODE---$/ { print; print "2|0|ses_abc|AI Chat|/tmp"; next }
    { print }
  ' "$file" > "$tmpfile"
  mv "$tmpfile" "$file"

  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    oc_lines=\$(_tmux_af_section_lines '$file' '---OPENCODE---' '---CLAUDE-CODE---')
    cmux_lines=\$(_tmux_af_section_lines '$file' '---CMUX---' '')
    oc_count=\$(echo \"\$oc_lines\" | grep -c '^[0-9]' 2>/dev/null || echo 0)
    cmux_count=\$(echo \"\$cmux_lines\" | grep -c '^ws-' 2>/dev/null || echo 0)
    echo \"oc=\$oc_count cmux=\$cmux_count\"
  ")
  [[ "$result" == *"oc=1"* ]]
  [[ "$result" == *"cmux=1"* ]]
}

@test "cmux_notify passes urgency value correctly to cmux CLI" {
  # Stub cmux to capture the arguments it receives
  local stub_dir
  stub_dir=$(mktemp -d)
  cat > "$stub_dir/cmux" << 'STUB'
#!/bin/sh
# Capture all arguments to a log file
echo "$@" >> "$CMUX_STUB_LOG"
STUB
  chmod +x "$stub_dir/cmux"

  local log_file
  log_file=$(mktemp)

  result=$(zsh -c "
    export PATH='$stub_dir:\$PATH'
    export CMUX_STUB_LOG='$log_file'
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/cmux.sh'
    _tmux_cmux_notify 'Test Title' 'Test Body' low
  ")

  local logged
  logged=$(cat "$log_file")
  rm -f "$log_file"
  rm -rf "$stub_dir"

  # Should contain: notify --title Test Title --body Test Body --urgency low
  [[ "$logged" == *"--urgency low"* ]]
  # Must NOT contain double --urgency (the old bug)
  ! [[ "$logged" == *"--urgency --urgency"* ]]
}

@test "cmux_notify defaults urgency to normal when not specified" {
  local stub_dir
  stub_dir=$(mktemp -d)
  cat > "$stub_dir/cmux" << 'STUB'
#!/bin/sh
echo "$@" >> "$CMUX_STUB_LOG"
STUB
  chmod +x "$stub_dir/cmux"

  local log_file
  log_file=$(mktemp)

  result=$(zsh -c "
    export PATH='$stub_dir:\$PATH'
    export CMUX_STUB_LOG='$log_file'
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/cmux.sh'
    _tmux_cmux_notify 'Title' 'Body'
  ")

  local logged
  logged=$(cat "$log_file")
  rm -f "$log_file"
  rm -rf "$stub_dir"

  [[ "$logged" == *"--urgency normal"* ]]
}

@test "cmux_notify_save auto mode passes low urgency" {
  local stub_dir
  stub_dir=$(mktemp -d)
  cat > "$stub_dir/cmux" << 'STUB'
#!/bin/sh
echo "$@" >> "$CMUX_STUB_LOG"
STUB
  chmod +x "$stub_dir/cmux"

  local log_file
  log_file=$(mktemp)

  result=$(zsh -c "
    export PATH='$stub_dir:\$PATH'
    export CMUX_STUB_LOG='$log_file'
    export CMUX_BUNDLE_ID=com.cmuxterm.app
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/cmux.sh'
    _tmux_cmux_notify_save 'my-session' '/tmp/test.archive' 'auto'
  ")

  local logged
  logged=$(cat "$log_file")
  rm -f "$log_file"
  rm -rf "$stub_dir"

  [[ "$logged" == *"--urgency low"* ]]
  ! [[ "$logged" == *"--urgency --urgency"* ]]
}

@test "cmux_notify_save manual mode passes normal urgency" {
  local stub_dir
  stub_dir=$(mktemp -d)
  cat > "$stub_dir/cmux" << 'STUB'
#!/bin/sh
echo "$@" >> "$CMUX_STUB_LOG"
STUB
  chmod +x "$stub_dir/cmux"

  local log_file
  log_file=$(mktemp)

  result=$(zsh -c "
    export PATH='$stub_dir:\$PATH'
    export CMUX_STUB_LOG='$log_file'
    export CMUX_BUNDLE_ID=com.cmuxterm.app
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/cmux.sh'
    _tmux_cmux_notify_save 'my-session' '/tmp/test.archive' 'manual'
  ")

  local logged
  logged=$(cat "$log_file")
  rm -f "$log_file"
  rm -rf "$stub_dir"

  [[ "$logged" == *"--urgency normal"* ]]
}

@test "cmux_notify_restore_fail passes critical urgency" {
  local stub_dir
  stub_dir=$(mktemp -d)
  cat > "$stub_dir/cmux" << 'STUB'
#!/bin/sh
echo "$@" >> "$CMUX_STUB_LOG"
STUB
  chmod +x "$stub_dir/cmux"

  local log_file
  log_file=$(mktemp)

  result=$(zsh -c "
    export PATH='$stub_dir:\$PATH'
    export CMUX_STUB_LOG='$log_file'
    export CMUX_BUNDLE_ID=com.cmuxterm.app
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/cmux.sh'
    _tmux_cmux_notify_restore_fail 'session creation failed'
  ")

  local logged
  logged=$(cat "$log_file")
  rm -f "$log_file"
  rm -rf "$stub_dir"

  [[ "$logged" == *"--urgency critical"* ]]
  ! [[ "$logged" == *"--urgency --urgency"* ]]
}

@test "cmux_notify_restore passes normal urgency" {
  local stub_dir
  stub_dir=$(mktemp -d)
  cat > "$stub_dir/cmux" << 'STUB'
#!/bin/sh
echo "$@" >> "$CMUX_STUB_LOG"
STUB
  chmod +x "$stub_dir/cmux"

  local log_file
  log_file=$(mktemp)

  result=$(zsh -c "
    export PATH='$stub_dir:\$PATH'
    export CMUX_STUB_LOG='$log_file'
    export CMUX_BUNDLE_ID=com.cmuxterm.app
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/cmux.sh'
    _tmux_cmux_notify_restore 'my-session'
  ")

  local logged
  logged=$(cat "$log_file")
  rm -f "$log_file"
  rm -rf "$stub_dir"

  [[ "$logged" == *"--urgency normal"* ]]
}

@test "init.sh loads cmux plugin from plugins dir" {
  result=$(zsh -c "
    export TMUX_MANAGER_DIR='$TMUX_MANAGER_DIR'
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    for p in '$TMUX_MANAGER_DIR/plugins'/*.sh(N); do source \"\$p\"; done
    typeset -f _tmux_cmux_is_inside >/dev/null && echo 'loaded' || echo 'missing'
  ")
  [ "$result" = "loaded" ]
}
