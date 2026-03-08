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

  run grep -n 'tmux send-keys -t "\${target}\.\${pidx}" "cd -- \$qpath" Enter' "$TMUX_MANAGER_DIR/lib/restore.sh"
  [ "$status" -eq 0 ]
}
