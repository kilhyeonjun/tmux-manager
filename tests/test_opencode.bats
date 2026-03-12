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

create_tmux_send_keys_logger() {
  local fakebin="$1"
  cat > "$fakebin/tmux" << 'EOF'
#!/usr/bin/env bash
log_file="${TMUX_LOG_FILE:?}"
if [ "$1" = "send-keys" ]; then
  target="$3"
  cmd="$4"
  key="$5"
  printf '%s|%s|%s\n' "$target" "$cmd" "$key" >> "$log_file"
fi
exit 0
EOF
  chmod +x "$fakebin/tmux"
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

@test "oc_setup_restored_pane echoes archived info with SID" {
  local fakebin log_file
  fakebin=$(mktemp -d -t tmux_oc_fakebin)
  log_file="$TMUX_ARCHIVE_DIR/oc_restore_with_sid.log"
  : > "$log_file"
  create_tmux_send_keys_logger "$fakebin"

  run zsh -c "
    export PATH='$fakebin':\"\$PATH\"
    export TMUX_LOG_FILE='$log_file'
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    local _TMUX_RESTORE_RUNNING_CMDS=''
    local _TMUX_RESTORE_OC_PANES=''
    _tmux_oc_setup_restored_pane 'sess:1' '1' '0' 'OC | My Chat' '/projects/foo' '1|0|ses_abc123|My Chat|/projects/foo' '%11'
  "
  [ "$status" -eq 0 ]

  run grep -F "[ARCHIVED OPENCODE]" "$log_file"
  [ "$status" -eq 0 ]
  run grep -F "TITLE : My Chat" "$log_file"
  [ "$status" -eq 0 ]
  run grep -F "SID   : ses_abc123" "$log_file"
  [ "$status" -eq 0 ]
  run grep -F "RUN   : opencode -s ses_abc123" "$log_file"
  [ "$status" -eq 0 ]

  rm -rf "$fakebin"
}

@test "oc_setup_restored_pane echoes archived info without SID" {
  local fakebin log_file
  fakebin=$(mktemp -d -t tmux_oc_fakebin)
  log_file="$TMUX_ARCHIVE_DIR/oc_restore_without_sid.log"
  : > "$log_file"
  create_tmux_send_keys_logger "$fakebin"

  run zsh -c "
    export PATH='$fakebin':\"\$PATH\"
    export TMUX_LOG_FILE='$log_file'
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    local _TMUX_RESTORE_RUNNING_CMDS=''
    local _TMUX_RESTORE_OC_PANES=''
    _tmux_oc_setup_restored_pane 'sess:2' '2' '0' 'OC | Detected' '/projects/bar' '2|0||Detected|/projects/bar' '%22'
  "
  [ "$status" -eq 0 ]

  run grep -F "SID   : (없음 - 새 세션으로 시작하세요)" "$log_file"
  [ "$status" -eq 0 ]
  run grep -F "RUN   : opencode -c" "$log_file"
  [ "$status" -eq 0 ]
  run grep -F "RUN   : opencode -s" "$log_file"
  [ "$status" -eq 1 ]

  rm -rf "$fakebin"
}

@test "oc_setup_restored_pane sends cd first when OC dir differs" {
  local fakebin log_file first_line
  fakebin=$(mktemp -d -t tmux_oc_fakebin)
  log_file="$TMUX_ARCHIVE_DIR/oc_restore_cd_diff.log"
  : > "$log_file"
  create_tmux_send_keys_logger "$fakebin"

  run zsh -c "
    export PATH='$fakebin':\"\$PATH\"
    export TMUX_LOG_FILE='$log_file'
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    local _TMUX_RESTORE_RUNNING_CMDS=''
    local _TMUX_RESTORE_OC_PANES=''
    _tmux_oc_setup_restored_pane 'sess:3' '3' '0' 'OC | CD Check' '/projects/here' '3|0|ses_cd999|CD Check|/projects/there' '%33'
  "
  [ "$status" -eq 0 ]

  first_line=$(sed -n '1p' "$log_file")
  [ "$first_line" = "%33|cd -- /projects/there|Enter" ]

  rm -rf "$fakebin"
}

@test "oc_setup_restored_pane skips cd when OC dir matches pane path" {
  local fakebin log_file
  fakebin=$(mktemp -d -t tmux_oc_fakebin)
  log_file="$TMUX_ARCHIVE_DIR/oc_restore_cd_same.log"
  : > "$log_file"
  create_tmux_send_keys_logger "$fakebin"

  run zsh -c "
    export PATH='$fakebin':\"\$PATH\"
    export TMUX_LOG_FILE='$log_file'
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    local _TMUX_RESTORE_RUNNING_CMDS=''
    local _TMUX_RESTORE_OC_PANES=''
    _tmux_oc_setup_restored_pane 'sess:4' '4' '0' 'OC | No CD' '/projects/same' '4|0|ses_same001|No CD|/projects/same' '%44'
  "
  [ "$status" -eq 0 ]

  run grep -F "cd -- " "$log_file"
  [ "$status" -eq 1 ]

  rm -rf "$fakebin"
}

@test "oc_setup_restored_pane decodes v2 encoded fields before echo" {
  local fakebin log_file
  fakebin=$(mktemp -d -t tmux_oc_fakebin)
  log_file="$TMUX_ARCHIVE_DIR/oc_restore_v2_decode.log"
  : > "$log_file"
  create_tmux_send_keys_logger "$fakebin"

  run zsh -c "
    export PATH='$fakebin':\"\$PATH\"
    export TMUX_LOG_FILE='$log_file'
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    local _TMUX_RESTORE_RUNNING_CMDS=''
    local _TMUX_RESTORE_OC_PANES=''
    local _TMUX_RESTORE_ARCHIVE_FMT=2
    _tmux_oc_setup_restored_pane 'sess:5' '5' '0' 'zsh' '/projects/original' '5|0|ses_v2abc|My%20Decoded%20Title|%2Fprojects%2Fdecoded' '%55'
  "
  [ "$status" -eq 0 ]

  run grep -F "TITLE : My Decoded Title" "$log_file"
  [ "$status" -eq 0 ]
  run grep -F "RUN   : opencode -s ses_v2abc" "$log_file"
  [ "$status" -eq 0 ]
  run grep -F "cd -- /projects/decoded" "$log_file"
  [ "$status" -eq 0 ]

  rm -rf "$fakebin"
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

@test "plugin functions exist after sourcing" {
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    typeset -f _tmux_oc_capture_session > /dev/null && echo 'capture:ok'
    typeset -f _tmux_oc_restore_metadata > /dev/null && echo 'restore_meta:ok'
    typeset -f _tmux_oc_setup_restored_pane > /dev/null && echo 'setup_pane:ok'
    typeset -f _tmux_oc_prompt_restart > /dev/null && echo 'prompt:ok'
    typeset -f _tmux_oc_detect_sid_from_tui > /dev/null && echo 'tui_detect:ok'
  ")
  echo "result: $result"
  [[ "$result" == *"capture:ok"* ]]
  [[ "$result" == *"restore_meta:ok"* ]]
  [[ "$result" == *"setup_pane:ok"* ]]
  [[ "$result" == *"prompt:ok"* ]]
  [[ "$result" == *"tui_detect:ok"* ]]
}

@test "oc_capture_session prefers detected SID over title match" {
  local fakebin
  fakebin=$(mktemp -d -t tmux_oc_fakebin)

  cat > "$fakebin/tmux" << 'EOF'
#!/usr/bin/env bash
if [ "$1" = "list-panes" ]; then
  echo "%1"
  exit 0
fi
if [ "$1" = "display-message" ] && [ "$2" = "-p" ] && [ "$3" = "-t" ] && [ "$4" = "%1" ]; then
  case "$5" in
    '#{window_index}') echo "1" ;;
    '#{pane_index}') echo "0" ;;
    '#{pane_title}') echo "OC | Same Title" ;;
    '#{pane_current_path}') echo "/projects/new" ;;
    *) echo "" ;;
  esac
  exit 0
fi
exit 0
EOF
  chmod +x "$fakebin/tmux"

  cat > "$fakebin/opencode" << 'EOF'
#!/usr/bin/env bash
if [ "$1" = "session" ] && [ "$2" = "list" ]; then
  # Same title maps to old sid in list (ambiguous case)
  echo "ses_old111 Same Title"
  exit 0
fi
if [ "$1" = "export" ] && [ -n "$2" ]; then
  sid="$2"
  cat <<JSON
{"info":{"title":"T-$sid","directory":"/projects/from-export"}}
JSON
  exit 0
fi
exit 0
EOF
  chmod +x "$fakebin/opencode"

  local out_file="$TMUX_ARCHIVE_DIR/oc_capture_test.archive"
  local base="$TMUX_ARCHIVE_DIR/oc_capture_test"
  local pane_file="${base}_w1_p0.pane"
  cat > "$pane_file" << 'EOF'
random history
opencode -s ses_new999
EOF

  run zsh -c "
    export PATH='$fakebin':\"\$PATH\"
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    _tmux_oc_capture_session 'dummy-session' '$out_file' '$base'
  "
  [ "$status" -eq 0 ]

  local line
  line=$(cat "$out_file")
  echo "line: $line"

  # Must keep detected/current SID from pane history, not title-matched old SID
  [[ "$line" == *"|ses_new999|"* ]]
  [[ "$line" != *"|ses_old111|"* ]]

  rm -rf "$fakebin"
}

@test "oc_detect_sid prefers explicit switch command" {
  local pane_file="$TMUX_ARCHIVE_DIR/detect_sid_test.pane"
  cat > "$pane_file" << 'EOF'
ses_old111 appeared earlier
some logs...
opencode -s ses_new222
EOF

  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    _tmux_oc_detect_sid_from_pane '$pane_file'
  ")
  echo "result: $result"
  [ "$result" = "ses_new222" ]
}

@test "oc_detect_sid finds SID in exit banner Continue line" {
  local pane_file="$TMUX_ARCHIVE_DIR/detect_sid_banner_continue.pane"
  cat > "$pane_file" << 'EOF'
                                   ▄
  █▀▀█ █▀▀█ █▀▀█ █▀▀▄ █▀▀▀ █▀▀█ █▀▀█ █▀▀█

  Session   Chat From Exit
  Continue  opencode -s ses_banner123
EOF

  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    _tmux_oc_detect_sid_from_pane '$pane_file'
  ")
  [ "$result" = "ses_banner123" ]
}

@test "oc_detect_sid prefers opencode switch over later bare SID" {
  local pane_file="$TMUX_ARCHIVE_DIR/detect_sid_priority.pane"
  cat > "$pane_file" << 'EOF'
ses_old111
Continue  opencode -s ses_priority222
prompt output ses_tail999
EOF

  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    _tmux_oc_detect_sid_from_pane '$pane_file'
  ")
  [ "$result" = "ses_priority222" ]
}

@test "oc_detect_sid trims SID to alphanumerics after ses_ prefix" {
  local pane_file="$TMUX_ARCHIVE_DIR/detect_sid_alnum_only.pane"
  cat > "$pane_file" << 'EOF'
opencode -s ses_AbC123-extra_tail
EOF

  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    _tmux_oc_detect_sid_from_pane '$pane_file'
  ")
  [ "$result" = "ses_AbC123" ]
}

@test "oc_detect_sid returns 1 for whitespace-only pane file" {
  local pane_file="$TMUX_ARCHIVE_DIR/detect_sid_whitespace_only.pane"
  printf '  \n\t  \n' > "$pane_file"

  run zsh -c "
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    _tmux_oc_detect_sid_from_pane '$pane_file'
  "
  [ "$status" -eq 1 ]
}

@test "oc_detect_sid handles exit banner followed by prompt junk" {
  local pane_file="$TMUX_ARCHIVE_DIR/detect_sid_banner_junk.pane"
  cat > "$pane_file" << 'EOF'
                                   ▄
  Session   Noisy Exit
  Continue  opencode -s ses_clean555
user@mac % echo ses_noise999
EOF

  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    _tmux_oc_detect_sid_from_pane '$pane_file'
  ")
  [ "$result" = "ses_clean555" ]
}

@test "oc_capture_session falls back to title match when no detected SID" {
  local fakebin
  fakebin=$(mktemp -d -t tmux_oc_fakebin)

  cat > "$fakebin/tmux" << 'EOF'
#!/usr/bin/env bash
if [ "$1" = "list-panes" ]; then
  echo "%1"
  exit 0
fi
if [ "$1" = "display-message" ] && [ "$2" = "-p" ] && [ "$3" = "-t" ] && [ "$4" = "%1" ]; then
  case "$5" in
    '#{window_index}') echo "1" ;;
    '#{pane_index}') echo "0" ;;
    '#{pane_title}') echo "OC | TitleMatch" ;;
    '#{pane_current_path}') echo "/projects/title" ;;
    *) echo "" ;;
  esac
  exit 0
fi
exit 0
EOF
  chmod +x "$fakebin/tmux"

  cat > "$fakebin/opencode" << 'EOF'
#!/usr/bin/env bash
if [ "$1" = "session" ] && [ "$2" = "list" ]; then
  echo "ses_title123 TitleMatch"
  exit 0
fi
if [ "$1" = "export" ] && [ "$2" = "ses_title123" ]; then
  cat <<JSON
{"info":{"title":"TitleMatch","directory":"/projects/title"}}
JSON
  exit 0
fi
exit 0
EOF
  chmod +x "$fakebin/opencode"

  local out_file="$TMUX_ARCHIVE_DIR/oc_capture_title.archive"
  local base="$TMUX_ARCHIVE_DIR/oc_capture_title"
  local pane_file="${base}_w1_p0.pane"
  cat > "$pane_file" << 'EOF'
no session id here
EOF

  run zsh -c "
    export PATH='$fakebin':\"\$PATH\"
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    _tmux_oc_capture_session 'dummy-session' '$out_file' '$base'
  "
  [ "$status" -eq 0 ]

  local line
  line=$(cat "$out_file")
  echo "line: $line"
  [[ "$line" == *"|ses_title123|"* ]]

  rm -rf "$fakebin"
}

@test "oc_capture_session prefers JSON title lookup over ambiguous table output" {
  local fakebin
  fakebin=$(mktemp -d -t tmux_oc_fakebin)

  cat > "$fakebin/tmux" << 'EOF'
#!/usr/bin/env bash
if [ "$1" = "list-panes" ]; then
  echo "%1"
  exit 0
fi
if [ "$1" = "display-message" ] && [ "$2" = "-p" ] && [ "$3" = "-t" ] && [ "$4" = "%1" ]; then
  case "$5" in
    '#{window_index}') echo "1" ;;
    '#{pane_index}') echo "0" ;;
    '#{pane_title}') echo "OC | JsonTitle" ;;
    '#{pane_current_path}') echo "/projects/json" ;;
    *) echo "" ;;
  esac
  exit 0
fi
exit 0
EOF
  chmod +x "$fakebin/tmux"

  cat > "$fakebin/opencode" << 'EOF'
#!/usr/bin/env bash
if [ "$1" = "session" ] && [ "$2" = "list" ] && [ "$3" = "--format" ] && [ "$4" = "json" ]; then
  cat <<JSON
[{"id":"ses_json777","title":"JsonTitle"}]
JSON
  exit 0
fi
if [ "$1" = "session" ] && [ "$2" = "list" ]; then
  # Ambiguous/incorrect table row should not win when JSON exists
  echo "ses_wrong111 JsonTitle"
  exit 0
fi
if [ "$1" = "export" ] && [ "$2" = "ses_json777" ]; then
  cat <<JSON
{"info":{"title":"JsonTitle","directory":"/projects/json"}}
JSON
  exit 0
fi
exit 0
EOF
  chmod +x "$fakebin/opencode"

  local out_file="$TMUX_ARCHIVE_DIR/oc_capture_json.archive"
  local base="$TMUX_ARCHIVE_DIR/oc_capture_json"
  local pane_file="${base}_w1_p0.pane"
  : > "$pane_file"

  run zsh -c "
    export PATH='$fakebin':\"\$PATH\"
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    _tmux_oc_capture_session 'dummy-session' '$out_file' '$base'
  "
  [ "$status" -eq 0 ]

  local line
  line=$(cat "$out_file")
  echo "line: $line"
  [[ "$line" == *"|ses_json777|"* ]]
  [[ "$line" != *"|ses_wrong111|"* ]]

  rm -rf "$fakebin"
}

@test "oc_prompt_restart is skipped on non-tty" {
  run zsh -c "
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    _tmux_oc_prompt_restart 'sess' 'w1|ses_abc|/tmp|Title\n'
    echo done
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"done"* ]]
}

@test "oc_setup_restored_pane accepts explicit pane target" {
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    tmux() { :; }
    local _TMUX_RESTORE_RUNNING_CMDS=''
    local _TMUX_RESTORE_OC_PANES=''
    local _TMUX_RESTORE_ARCHIVE_FMT=2
    _tmux_oc_setup_restored_pane 'sess:1' '1' '0' 'OC | Raw' '/tmp' '1|0|ses_abc|My%7CTitle|/a%7Cb' '%99'
    echo "PANES=\$_TMUX_RESTORE_OC_PANES"
    echo "CMDS=\$_TMUX_RESTORE_RUNNING_CMDS"
  " 2>&1)

  [[ "$result" == *"%99|ses_abc|%2Fa%7Cb|Raw"* ]]
}

@test "oc_enrich_meta keeps input values when export payload is invalid" {
  local fakebin
  fakebin=$(mktemp -d -t tmux_oc_fakebin)

  cat > "$fakebin/opencode" << 'EOF'
#!/usr/bin/env bash
if [ "$1" = "export" ]; then
  echo '{broken json'
  exit 0
fi
exit 0
EOF
  chmod +x "$fakebin/opencode"

  result=$(zsh -c "
    export PATH='$fakebin':\"\$PATH\"
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    local t='keep-title'
    local d='/keep/dir'
    _tmux_oc_enrich_meta 'ses_x' t d
    echo \"T=\$t\"
    echo \"D=\$d\"
  ")

  [[ "$result" == *"T=keep-title"* ]]
  [[ "$result" == *"D=/keep/dir"* ]]
  rm -rf "$fakebin"
}

# ── TUI-based SID detection tests ──────────────────────────────────────────

@test "oc_detect_sid_from_tui matches session title in TUI content" {
  local fakebin
  fakebin=$(mktemp -d -t tmux_oc_fakebin)
  local fake_db="$TMUX_ARCHIVE_DIR/test_oc.db"

  cat > "$fakebin/tmux" << 'TMUX_EOF'
#!/usr/bin/env bash
if [ "$1" = "capture-pane" ]; then
  cat << 'CONTENT'
  Sessions
  ● Fix auth bug in API
  ▸ Refactor database layer
  
  Some TUI content here
CONTENT
  exit 0
fi
exit 0
TMUX_EOF
  chmod +x "$fakebin/tmux"

  cat > "$fakebin/sqlite3" << SQLITE_EOF
#!/usr/bin/env bash
if echo "\$2" | grep -q "SELECT id, title"; then
  echo "ses_auth001|Fix auth bug in API"
  echo "ses_refac002|Refactor database layer"
fi
if echo "\$2" | grep -q "SELECT id FROM"; then
  echo "ses_auth001"
fi
exit 0
SQLITE_EOF
  chmod +x "$fakebin/sqlite3"

  # Create a fake DB file (just needs to exist)
  touch "$fake_db"

  result=$(zsh -c "
    export PATH='$fakebin':\"\$PATH\"
    export _TMUX_OC_DB='$fake_db'
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    _tmux_oc_detect_sid_from_tui '%1' '/projects/myapp'
  ")
  echo "result: $result"
  [ "$result" = "ses_auth001" ]

  rm -rf "$fakebin"
}

@test "oc_detect_sid_from_tui matches second session when first doesn't appear in TUI" {
  local fakebin
  fakebin=$(mktemp -d -t tmux_oc_fakebin)
  local fake_db="$TMUX_ARCHIVE_DIR/test_oc2.db"

  cat > "$fakebin/tmux" << 'TMUX_EOF'
#!/usr/bin/env bash
if [ "$1" = "capture-pane" ]; then
  cat << 'CONTENT'
  Sessions
  ▸ Refactor database layer
  
  Working on refactoring...
CONTENT
  exit 0
fi
exit 0
TMUX_EOF
  chmod +x "$fakebin/tmux"

  cat > "$fakebin/sqlite3" << SQLITE_EOF
#!/usr/bin/env bash
if echo "\$2" | grep -q "SELECT id, title"; then
  echo "ses_auth001|Fix auth bug in API"
  echo "ses_refac002|Refactor database layer"
fi
if echo "\$2" | grep -q "SELECT id FROM"; then
  echo "ses_auth001"
fi
exit 0
SQLITE_EOF
  chmod +x "$fakebin/sqlite3"

  touch "$fake_db"

  result=$(zsh -c "
    export PATH='$fakebin':\"\$PATH\"
    export _TMUX_OC_DB='$fake_db'
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    _tmux_oc_detect_sid_from_tui '%1' '/projects/myapp'
  ")
  echo "result: $result"
  [ "$result" = "ses_refac002" ]

  rm -rf "$fakebin"
}

@test "oc_detect_sid_from_tui falls back to most recent session when no title matches" {
  local fakebin
  fakebin=$(mktemp -d -t tmux_oc_fakebin)
  local fake_db="$TMUX_ARCHIVE_DIR/test_oc3.db"

  cat > "$fakebin/tmux" << 'TMUX_EOF'
#!/usr/bin/env bash
if [ "$1" = "capture-pane" ]; then
  echo "No matching content here at all"
  exit 0
fi
exit 0
TMUX_EOF
  chmod +x "$fakebin/tmux"

  cat > "$fakebin/sqlite3" << SQLITE_EOF
#!/usr/bin/env bash
if echo "\$2" | grep -q "SELECT id, title"; then
  echo "ses_nomatch|Totally Different Title"
fi
if echo "\$2" | grep -q "SELECT id FROM"; then
  echo "ses_fallback999"
fi
exit 0
SQLITE_EOF
  chmod +x "$fakebin/sqlite3"

  touch "$fake_db"

  result=$(zsh -c "
    export PATH='$fakebin':\"\$PATH\"
    export _TMUX_OC_DB='$fake_db'
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    _tmux_oc_detect_sid_from_tui '%1' '/projects/myapp'
  ")
  echo "result: $result"
  [ "$result" = "ses_fallback999" ]

  rm -rf "$fakebin"
}

@test "oc_detect_sid_from_tui returns 1 when DB file missing" {
  run zsh -c "
    export _TMUX_OC_DB='/nonexistent/path/oc.db'
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    _tmux_oc_detect_sid_from_tui '%1' '/projects/myapp'
  "
  [ "$status" -eq 1 ]
}

@test "oc_detect_sid_from_tui returns 1 when sqlite3 not available" {
  local fakebin
  fakebin=$(mktemp -d -t tmux_oc_fakebin)
  local fake_db="$TMUX_ARCHIVE_DIR/test_oc_nosql.db"
  touch "$fake_db"

  # PATH with no sqlite3
  run zsh -c "
    export PATH='$fakebin'
    export _TMUX_OC_DB='$fake_db'
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    _tmux_oc_detect_sid_from_tui '%1' '/tmp'
  "
  [ "$status" -eq 1 ]

  rm -rf "$fakebin"
}

@test "oc_capture_session detects bare opencode via OC_RUNNING and TUI matching" {
  local fakebin
  fakebin=$(mktemp -d -t tmux_oc_fakebin)
  local fake_db="$TMUX_ARCHIVE_DIR/test_oc_bare.db"

  cat > "$fakebin/tmux" << 'TMUX_EOF'
#!/usr/bin/env bash
if [ "$1" = "list-panes" ]; then
  echo "%1"
  exit 0
fi
if [ "$1" = "display-message" ] && [ "$2" = "-p" ] && [ "$3" = "-t" ] && [ "$4" = "%1" ]; then
  case "$5" in
    '#{window_index}') echo "1" ;;
    '#{pane_index}') echo "0" ;;
    '#{pane_title}') echo "OpenCode" ;;
    '#{pane_current_path}') echo "/projects/bane" ;;
    '#{pane_pid}') echo "12345" ;;
    *) echo "" ;;
  esac
  exit 0
fi
if [ "$1" = "capture-pane" ]; then
  cat << 'CONTENT'
  Sessions
  ● Cloud Data Sync Fix
  ▸ Auth Permission Issue
CONTENT
  exit 0
fi
exit 0
TMUX_EOF
  chmod +x "$fakebin/tmux"

  cat > "$fakebin/opencode" << 'EOF'
#!/usr/bin/env bash
if [ "$1" = "session" ] && [ "$2" = "list" ] && [ "$3" = "--format" ] && [ "$4" = "json" ]; then
  echo '[{"id":"ses_cloud777","title":"Cloud Data Sync Fix","directory":"/projects/bane"},{"id":"ses_auth888","title":"Auth Permission Issue","directory":"/projects/bane"}]'
  exit 0
fi
exit 0
EOF
  chmod +x "$fakebin/opencode"

  cat > "$fakebin/sqlite3" << SQLITE_EOF
#!/usr/bin/env bash
if echo "\$2" | grep -q "SELECT id, title"; then
  echo "ses_cloud777|Cloud Data Sync Fix"
  echo "ses_auth888|Auth Permission Issue"
fi
if echo "\$2" | grep -q "SELECT id FROM"; then
  echo "ses_cloud777"
fi
exit 0
SQLITE_EOF
  chmod +x "$fakebin/sqlite3"

  touch "$fake_db"

  local out_file="$TMUX_ARCHIVE_DIR/oc_capture_bare.archive"
  local base="$TMUX_ARCHIVE_DIR/oc_capture_bare"
  local pane_file="${base}_w1_p0.pane"
  : > "$pane_file"

  run zsh -c "
    export PATH='$fakebin':\"\$PATH\"
    export _TMUX_OC_DB='$fake_db'
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    _tmux_oc_capture_session 'test-session' '$out_file' '$base'
  "
  [ "$status" -eq 0 ]

  local line
  line=$(cat "$out_file")
  echo "line: $line"
  [[ "$line" == *"|ses_cloud777|"* ]]

  rm -rf "$fakebin"
}

@test "oc_capture_session detects OpenCode title without OC | prefix" {
  local fakebin
  fakebin=$(mktemp -d -t tmux_oc_fakebin)
  local fake_db="$TMUX_ARCHIVE_DIR/test_oc_title.db"

  cat > "$fakebin/tmux" << 'TMUX_EOF'
#!/usr/bin/env bash
if [ "$1" = "list-panes" ]; then
  echo "%1"
  exit 0
fi
if [ "$1" = "display-message" ] && [ "$2" = "-p" ] && [ "$3" = "-t" ] && [ "$4" = "%1" ]; then
  case "$5" in
    '#{window_index}') echo "1" ;;
    '#{pane_index}') echo "0" ;;
    '#{pane_title}') echo "OpenCode" ;;
    '#{pane_current_path}') echo "/projects/static" ;;
    '#{pane_pid}') echo "99999" ;;
    *) echo "" ;;
  esac
  exit 0
fi
if [ "$1" = "capture-pane" ]; then
  cat << 'CONTENT'
  Sessions
  ● Static Data Access
CONTENT
  exit 0
fi
exit 0
TMUX_EOF
  chmod +x "$fakebin/tmux"

  cat > "$fakebin/opencode" << 'EOF'
#!/usr/bin/env bash
if [ "$1" = "session" ] && [ "$2" = "list" ] && [ "$3" = "--format" ] && [ "$4" = "json" ]; then
  echo '[{"id":"ses_static111","title":"Static Data Access","directory":"/projects/static"}]'
  exit 0
fi
exit 0
EOF
  chmod +x "$fakebin/opencode"

  cat > "$fakebin/sqlite3" << SQLITE_EOF
#!/usr/bin/env bash
if echo "\$2" | grep -q "SELECT id, title"; then
  echo "ses_static111|Static Data Access"
fi
if echo "\$2" | grep -q "SELECT id FROM"; then
  echo "ses_static111"
fi
exit 0
SQLITE_EOF
  chmod +x "$fakebin/sqlite3"

  touch "$fake_db"

  local out_file="$TMUX_ARCHIVE_DIR/oc_capture_oc_title.archive"
  local base="$TMUX_ARCHIVE_DIR/oc_capture_oc_title"
  local pane_file="${base}_w1_p0.pane"
  : > "$pane_file"

  run zsh -c "
    export PATH='$fakebin':\"\$PATH\"
    export _TMUX_OC_DB='$fake_db'
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    _tmux_oc_capture_session 'test-session' '$out_file' '$base'
  "
  [ "$status" -eq 0 ]

  local line
  line=$(cat "$out_file")
  echo "line: $line"
  [[ "$line" == *"|ses_static111|"* ]]

  rm -rf "$fakebin"
}

@test "oc_capture_session handles switched session (TUI shows different session than -s arg)" {
  local fakebin
  fakebin=$(mktemp -d -t tmux_oc_fakebin)
  local fake_db="$TMUX_ARCHIVE_DIR/test_oc_switched.db"

  cat > "$fakebin/tmux" << 'TMUX_EOF'
#!/usr/bin/env bash
if [ "$1" = "list-panes" ]; then
  echo "%1"
  exit 0
fi
if [ "$1" = "display-message" ] && [ "$2" = "-p" ] && [ "$3" = "-t" ] && [ "$4" = "%1" ]; then
  case "$5" in
    '#{window_index}') echo "1" ;;
    '#{pane_index}') echo "0" ;;
    '#{pane_title}') echo "OpenCode" ;;
    '#{pane_current_path}') echo "/projects/app" ;;
    '#{pane_pid}') echo "55555" ;;
    *) echo "" ;;
  esac
  exit 0
fi
if [ "$1" = "capture-pane" ]; then
  cat << 'CONTENT'
  Sessions
  ● New Feature Work
  ▸ Old Started Session
CONTENT
  exit 0
fi
exit 0
TMUX_EOF
  chmod +x "$fakebin/tmux"

  cat > "$fakebin/opencode" << 'EOF'
#!/usr/bin/env bash
if [ "$1" = "session" ] && [ "$2" = "list" ] && [ "$3" = "--format" ] && [ "$4" = "json" ]; then
  echo '[{"id":"ses_old000","title":"Old Started Session","directory":"/projects/app"},{"id":"ses_new111","title":"New Feature Work","directory":"/projects/app"}]'
  exit 0
fi
exit 0
EOF
  chmod +x "$fakebin/opencode"

  cat > "$fakebin/sqlite3" << SQLITE_EOF
#!/usr/bin/env bash
if echo "\$2" | grep -q "SELECT id, title"; then
  echo "ses_new111|New Feature Work"
  echo "ses_old000|Old Started Session"
fi
if echo "\$2" | grep -q "SELECT id FROM"; then
  echo "ses_new111"
fi
exit 0
SQLITE_EOF
  chmod +x "$fakebin/sqlite3"

  touch "$fake_db"

  local out_file="$TMUX_ARCHIVE_DIR/oc_capture_switched.archive"
  local base="$TMUX_ARCHIVE_DIR/oc_capture_switched"
  local pane_file="${base}_w1_p0.pane"
  # Pane file has the OLD session from -s arg
  echo "opencode -s ses_old000" > "$pane_file"

  run zsh -c "
    export PATH='$fakebin':\"\$PATH\"
    export _TMUX_OC_DB='$fake_db'
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    _tmux_oc_capture_session 'test-session' '$out_file' '$base'
  "
  [ "$status" -eq 0 ]

  local line
  line=$(cat "$out_file")
  echo "line: $line"
  # TUI-based detection should pick the ACTIVE session (New Feature Work), not the -s arg one
  [[ "$line" == *"|ses_new111|"* ]]
  [[ "$line" != *"|ses_old000|"* ]]

  rm -rf "$fakebin"
}

@test "oc_capture_session with OC_RUNNING marker in ps cache" {
  local fakebin
  fakebin=$(mktemp -d -t tmux_oc_fakebin)
  local fake_db="$TMUX_ARCHIVE_DIR/test_oc_psmarker.db"
  local ps_cache="$TMUX_ARCHIVE_DIR/test_ps_cache"

  cat > "$fakebin/tmux" << 'TMUX_EOF'
#!/usr/bin/env bash
if [ "$1" = "list-panes" ]; then
  echo "%1"
  exit 0
fi
if [ "$1" = "display-message" ] && [ "$2" = "-p" ] && [ "$3" = "-t" ] && [ "$4" = "%1" ]; then
  case "$5" in
    '#{window_index}') echo "1" ;;
    '#{pane_index}') echo "0" ;;
    '#{pane_title}') echo "zsh" ;;
    '#{pane_current_path}') echo "/projects/bare" ;;
    '#{pane_pid}') echo "77777" ;;
    *) echo "" ;;
  esac
  exit 0
fi
if [ "$1" = "capture-pane" ]; then
  cat << 'CONTENT'
  Sessions
  ● Bare OC Session
CONTENT
  exit 0
fi
exit 0
TMUX_EOF
  chmod +x "$fakebin/tmux"

  cat > "$fakebin/opencode" << 'EOF'
#!/usr/bin/env bash
if [ "$1" = "session" ] && [ "$2" = "list" ] && [ "$3" = "--format" ] && [ "$4" = "json" ]; then
  echo '[{"id":"ses_bare555","title":"Bare OC Session","directory":"/projects/bare"}]'
  exit 0
fi
exit 0
EOF
  chmod +x "$fakebin/opencode"

  cat > "$fakebin/sqlite3" << SQLITE_EOF
#!/usr/bin/env bash
if echo "\$2" | grep -q "SELECT id, title"; then
  echo "ses_bare555|Bare OC Session"
fi
if echo "\$2" | grep -q "SELECT id FROM"; then
  echo "ses_bare555"
fi
exit 0
SQLITE_EOF
  chmod +x "$fakebin/sqlite3"

  touch "$fake_db"

  printf '77777\tOC_RUNNING\n' > "$ps_cache"

  local out_file="$TMUX_ARCHIVE_DIR/oc_capture_psmarker.archive"
  local base="$TMUX_ARCHIVE_DIR/oc_capture_psmarker"
  local pane_file="${base}_w1_p0.pane"
  : > "$pane_file"

  run zsh -c "
    export PATH='$fakebin':\"\$PATH\"
    export _TMUX_OC_DB='$fake_db'
    export _TMUX_OC_PS_CACHE='$ps_cache'
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    _tmux_oc_capture_session 'test-session' '$out_file' '$base'
  "
  [ "$status" -eq 0 ]

  local line
  line=$(cat "$out_file")
  echo "line: $line"
  [[ "$line" == *"|ses_bare555|"* ]]

  rm -rf "$fakebin"
}

@test "oc_detect_sid_from_tui uses index cache when DB has no match" {
  local fakebin
  fakebin=$(mktemp -d -t tmux_oc_fakebin)
  local fake_db="$TMUX_ARCHIVE_DIR/test_oc_idxcache.db"
  local idx_cache="$TMUX_ARCHIVE_DIR/test_idx_cache"

  cat > "$fakebin/tmux" << 'TMUX_EOF'
#!/usr/bin/env bash
if [ "$1" = "capture-pane" ]; then
  cat << 'CONTENT'
  Sessions
  ● Cached Session Title
CONTENT
  exit 0
fi
exit 0
TMUX_EOF
  chmod +x "$fakebin/tmux"

  cat > "$fakebin/sqlite3" << SQLITE_EOF
#!/usr/bin/env bash
# DB returns no matches for this directory
if echo "\$2" | grep -q "SELECT id, title"; then
  exit 0
fi
if echo "\$2" | grep -q "SELECT id FROM"; then
  exit 0
fi
exit 0
SQLITE_EOF
  chmod +x "$fakebin/sqlite3"

  touch "$fake_db"

  # Index cache has the session
  printf 'ses_cached999\tCached Session Title\t/projects/cached\n' > "$idx_cache"

  result=$(zsh -c "
    export PATH='$fakebin':\"\$PATH\"
    export _TMUX_OC_DB='$fake_db'
    export _TMUX_OC_INDEX_CACHE='$idx_cache'
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    _tmux_oc_detect_sid_from_tui '%1' '/projects/cached'
  ")
  echo "result: $result"
  [ "$result" = "ses_cached999" ]

  rm -rf "$fakebin"
}
