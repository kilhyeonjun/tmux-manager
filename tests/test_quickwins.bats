#!/usr/bin/env bats
# Structural regression tests for reliability quick wins.

load helpers/setup

@test "init.sh loads plugins from TMUX_MANAGER_PLUGINS_DIR" {
  run grep -n 'for _tmux_mgr_plugin in "\$TMUX_MANAGER_PLUGINS_DIR"/\*.sh(N); do' "$TMUX_MANAGER_DIR/init.sh"
  [ "$status" -eq 0 ]
}

@test "core save path uses temp file then mv finalize" {
  run grep -n 'tmp_file=\$(mktemp "\${TMUX_ARCHIVE_DIR}/\.' "$TMUX_MANAGER_DIR/lib/core.sh"
  [ "$status" -eq 0 ]

  run grep -n 'mv -f "\$tmp_file" "\$file"' "$TMUX_MANAGER_DIR/lib/core.sh"
  [ "$status" -eq 0 ]
}

@test "restore uses quoted cd command" {
  run grep -n 'local qpath="\${(q)ppath}"' "$TMUX_MANAGER_DIR/lib/restore.sh"
  [ "$status" -eq 0 ]

  run grep -n 'tmux send-keys -t "\$pane_target" "cd -- \$qpath" Enter' "$TMUX_MANAGER_DIR/lib/restore.sh"
  [ "$status" -eq 0 ]
}

@test "mutation paths are protected by archive lock helper" {
  run grep -n '_tmux_archive_with_lock 30 _tmux_archive_save_unlocked' "$TMUX_MANAGER_DIR/lib/core.sh"
  [ "$status" -eq 0 ]

  run grep -n '_tmux_archive_with_lock 60 _tmux_autoarchive_cleanup_unlocked' "$TMUX_MANAGER_DIR/lib/core.sh"
  [ "$status" -eq 0 ]

  run grep -n '_tmux_archive_with_lock 60 _tmux_archive_restore_unlocked' "$TMUX_MANAGER_DIR/lib/restore.sh"
  [ "$status" -eq 0 ]
}

@test "archive save and status use shared safe-name sanitizer" {
  run grep -n 'safe_name=\$(_tmux_archive_safe_name "\$session")' "$TMUX_MANAGER_DIR/lib/core.sh"
  [ "$status" -eq 0 ]

  run grep -n 'safe_name=\$(_tmux_archive_safe_name "\$sess_name")' "$TMUX_MANAGER_DIR/lib/status.sh"
  [ "$status" -eq 0 ]
}

@test "archive save path does not hard-require python3" {
  run grep -n '_tmux_af_require_python3.*아카이브 저장' "$TMUX_MANAGER_DIR/lib/core.sh"
  [ "$status" -ne 0 ]
}

@test "archive groups avoid echo -e based aggregation" {
  run grep -n 'echo -e "\$groups"' "$TMUX_MANAGER_DIR/lib/core.sh"
  [ "$status" -ne 0 ]
}
