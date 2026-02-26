#!/usr/bin/env bats
# Tests for lib/status.sh — status bar refresh
# Note: Most status.sh functionality requires a live tmux server.
# We test the debounce logic and script structure.

load helpers/setup

@test "status.sh exits with usage on unknown segment" {
  run zsh "$TMUX_MANAGER_DIR/lib/status.sh" unknown_segment
  # Should exit silently (no matching case)
  [ "$status" -eq 0 ]
}

@test "status.sh debounce lockfile creation" {
  local lockfile="/tmp/.tmux-status-lock"
  rm -f "$lockfile"

  # Without tmux, refresh_tabs will exit early (no pane_data)
  # but should create the lockfile first
  run zsh "$TMUX_MANAGER_DIR/lib/status.sh" refresh_tabs
  [ -f "$lockfile" ]

  # Record lockfile timestamp
  local first_mtime
  first_mtime=$(stat -f%m "$lockfile" 2>/dev/null)

  # Running again immediately should exit due to debounce
  run zsh "$TMUX_MANAGER_DIR/lib/status.sh" refresh_tabs
  local second_mtime
  second_mtime=$(stat -f%m "$lockfile" 2>/dev/null)

  # Lockfile should not be updated (debounce skipped execution)
  [ "$first_mtime" = "$second_mtime" ]

  rm -f "$lockfile"
}

@test "status script is valid zsh" {
  run zsh -n "$TMUX_MANAGER_DIR/lib/status.sh"
  [ "$status" -eq 0 ]
}

@test "preview script is valid zsh" {
  run zsh -n "$TMUX_MANAGER_DIR/lib/preview.sh"
  [ "$status" -eq 0 ]
}

@test "init.sh is valid zsh" {
  run zsh -n "$TMUX_MANAGER_DIR/init.sh"
  [ "$status" -eq 0 ]
}

@test "all lib files are valid zsh" {
  for f in "$TMUX_MANAGER_DIR"/lib/*.sh; do
    run zsh -n "$f"
    echo "checking: $f — status: $status"
    [ "$status" -eq 0 ]
  done
}

@test "all plugin files are valid zsh" {
  for f in "$TMUX_MANAGER_DIR"/plugins/*.sh; do
    [ ! -f "$f" ] && skip "no plugins found"
    run zsh -n "$f"
    echo "checking: $f — status: $status"
    [ "$status" -eq 0 ]
  done
}

@test "hooks/on-session-created.sh is valid zsh" {
  run zsh -n "$TMUX_MANAGER_DIR/hooks/on-session-created.sh"
  [ "$status" -eq 0 ]
}

@test "cron/autoarchive.sh is valid zsh" {
  run zsh -n "$TMUX_MANAGER_DIR/cron/autoarchive.sh"
  [ "$status" -eq 0 ]
}
