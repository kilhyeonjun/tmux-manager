#!/usr/bin/env bats

load helpers/setup

setup() {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  export TMUX_REAL
  TMUX_REAL=$(command -v tmux)
  export TMUX_TEST_SOCKET="tmgr_it_${BATS_TEST_NUMBER}_$$"
  export TMUX=""
  FAKEBIN=$(mktemp -d -t tmux_it_fakebin)
  cat > "$FAKEBIN/tmux" << 'EOF'
#!/usr/bin/env bash
exec "$TMUX_REAL" -L "$TMUX_TEST_SOCKET" "$@"
EOF
  chmod +x "$FAKEBIN/tmux"
  export PATH="$FAKEBIN:$PATH"
}

teardown() {
  tmux kill-server >/dev/null 2>&1 || true
  rm -rf "$FAKEBIN"
}

@test "integration: save and restore keeps window indexes and names" {
  run zsh <<'EOF'
setopt local_options nonomatch
source "$TMUX_MANAGER_DIR/conf/defaults.conf"
source "$TMUX_MANAGER_DIR/lib/archive_format.sh"
source "$TMUX_MANAGER_DIR/lib/core.sh"
source "$TMUX_MANAGER_DIR/lib/restore.sh"

tmux start-server || { echo START_FAIL; exit 11; }
tmux new-session -d -s itest -n main || { echo NEW_FAIL; exit 12; }
tmux set-option -t itest base-index 1 || { echo BASEIDX_FAIL; exit 13; }
tmux set-window-option -t itest pane-base-index 1 || { echo PANEBASE_FAIL; exit 14; }
tmux rename-window -t itest:1 'main|w' || { echo RENAME_FAIL; exit 15; }
tmux new-window -d -t itest:3 -n 'code|w' || { echo NEWWIN_FAIL; exit 16; }
tmux split-window -d -t itest:3 -c /tmp || { echo SPLIT_FAIL; exit 17; }
tmux select-layout -t itest:3 tiled || { echo LAYOUT_FAIL; exit 18; }

tmux-archive save itest || { echo SAVE_FAIL; exit 19; }
setopt local_options null_glob
file=""
for f in "$TMUX_ARCHIVE_DIR"/*.archive; do
  file="$f"
  break
done
echo FILE="$file"
[ -n "$file" ] || exit 10

tmux kill-session -t itest || { echo KILL_FAIL; exit 20; }
tmux-archive restore "$file" || { echo RESTORE_FAIL; exit 21; }

echo 'WINDOWS:'
tmux list-windows -t itest -F '#{window_index}|#{window_name}' | sort
echo 'PANES:'
tmux list-panes -t itest:3 -F '#{pane_index}|#{pane_current_path}' | sort
EOF
  [ "$status" -eq 0 ]
  [[ "$output" == *"WINDOWS:"* ]]
  [[ "$output" == *"1|main|w"* ]]
  [[ "$output" == *"3|code|w"* ]]
}

@test "integration: restore works for legacy archive without OPENCODE marker" {
  local file="$TMUX_ARCHIVE_DIR/legacy_no_oc.archive"
  cat > "$file" << 'EOF'
SESSION_NAME=legacy-restore
SESSION_UUID=legacy-uuid
ARCHIVED_AT=2025-01-01 12:00:00
---WINDOWS---
1|main|tiled
---PANES---
legacy-restore|1|0|/tmp|zsh|zsh
EOF

  run zsh -c "
    export TMUX_MANAGER_DIR='$TMUX_MANAGER_DIR'
    export TMUX_ARCHIVE_DIR='$TMUX_ARCHIVE_DIR'
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    source '$TMUX_MANAGER_DIR/lib/restore.sh'
    tmux start-server
    tmux-archive restore '$file'
    tmux has-session -t legacy-restore
  "
  [ "$status" -eq 0 ]
}

@test "integration: restore succeeds with plugin disabled and enabled" {
  local file="$TMUX_ARCHIVE_DIR/plugin_case.archive"
  cat > "$file" << 'EOF'
FORMAT_VERSION=2
SESSION_NAME=plugin-case
SESSION_UUID=plugin-uuid
ARCHIVED_AT=2025-01-01 12:00:00
---WINDOWS---
1|main|tiled
---PANES---
plugin-case|1|0|/tmp|zsh|OC %7C Test
---OPENCODE---
1|0|ses_test001|Test%7CTitle|/tmp
EOF

  run zsh -c "
    export TMUX_MANAGER_DIR='$TMUX_MANAGER_DIR'
    export TMUX_ARCHIVE_DIR='$TMUX_ARCHIVE_DIR'
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    source '$TMUX_MANAGER_DIR/lib/restore.sh'
    tmux start-server

    tmux-archive restore '$file'
    tmux kill-session -t plugin-case

    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    tmux-archive restore '$file'
    tmux show-option -t plugin-case -qv @oc_saved_count
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"1"* ]]
}

@test "integration: restore fails on malformed WINDOWS section" {
  local file="$TMUX_ARCHIVE_DIR/malformed_windows.archive"
  cat > "$file" << 'EOF'
SESSION_NAME=bad-windows
SESSION_UUID=bad-win-uuid
ARCHIVED_AT=2025-01-01 12:00:00
---WINDOWS---
main|not-index|tiled
---PANES---
bad-windows|1|0|/tmp|zsh|zsh
EOF

  run zsh -c "
    export TMUX_MANAGER_DIR='$TMUX_MANAGER_DIR'
    export TMUX_ARCHIVE_DIR='$TMUX_ARCHIVE_DIR'
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    source '$TMUX_MANAGER_DIR/lib/restore.sh'
    tmux start-server
    tmux-archive restore '$file'
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"WINDOWS 섹션 없음"* ]]
}

@test "integration: restore tolerates malformed OPENCODE rows" {
  local file="$TMUX_ARCHIVE_DIR/malformed_oc_rows.archive"
  cat > "$file" << 'EOF'
FORMAT_VERSION=2
SESSION_NAME=oc-malformed
SESSION_UUID=oc-malformed-uuid
ARCHIVED_AT=2025-01-01 12:00:00
---WINDOWS---
1|main|tiled
---PANES---
oc-malformed|1|0|/tmp|zsh|OC%20%7C%20One
---OPENCODE---
this-is-not-a-valid-row
1|0|ses_valid001|One%20Title|%2Ftmp
1|x|ses_bad002|Bad%20Pane|%2Ftmp
EOF

  run zsh -c "
    export TMUX_MANAGER_DIR='$TMUX_MANAGER_DIR'
    export TMUX_ARCHIVE_DIR='$TMUX_ARCHIVE_DIR'
    source '$TMUX_MANAGER_DIR/conf/defaults.conf'
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/lib/core.sh'
    source '$TMUX_MANAGER_DIR/lib/restore.sh'
    source '$TMUX_MANAGER_DIR/plugins/opencode.sh'
    tmux start-server
    tmux-archive restore '$file'
    tmux show-option -t oc-malformed -qv @oc_saved_count
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"1"* ]]
}
