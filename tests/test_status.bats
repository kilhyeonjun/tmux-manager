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
  local tmux_env="/tmp/tmux-test/default,123,0"
  local socket_key
  socket_key=$(printf '%s' "/tmp/tmux-test/default" | tr -c '[:alnum:]_.-' '_')
  local lockfile="/tmp/.tmux-status-lock-$(id -u)-${socket_key}"
  rm -f "$lockfile"

  # Without tmux, refresh_tabs will exit early (no pane_data)
  # but should create the lockfile first
  run env TMUX_MANAGER_DEBOUNCE_SEC=30 TMUX="$tmux_env" zsh "$TMUX_MANAGER_DIR/lib/status.sh" refresh_tabs
  [ -f "$lockfile" ]

  # Record lockfile timestamp
  local first_mtime
  first_mtime=$(stat -f%m "$lockfile" 2>/dev/null)

  # Running again immediately should exit due to debounce
  run env TMUX_MANAGER_DEBOUNCE_SEC=30 TMUX="$tmux_env" zsh "$TMUX_MANAGER_DIR/lib/status.sh" refresh_tabs
  local second_mtime
  second_mtime=$(stat -f%m "$lockfile" 2>/dev/null)

  # Lockfile should not be updated (debounce skipped execution)
  [ "$first_mtime" = "$second_mtime" ]

  rm -f "$lockfile"
}

@test "status.sh lockfile differs by tmux socket" {
  local key_a key_b lock_a lock_b
  key_a=$(printf '%s' '/tmp/tmux-A/default' | tr -c '[:alnum:]_.-' '_')
  key_b=$(printf '%s' '/tmp/tmux-B/default' | tr -c '[:alnum:]_.-' '_')
  lock_a="/tmp/.tmux-status-lock-$(id -u)-${key_a}"
  lock_b="/tmp/.tmux-status-lock-$(id -u)-${key_b}"
  rm -f "$lock_a" "$lock_b"

  run env TMUX_MANAGER_DEBOUNCE_SEC=30 TMUX='/tmp/tmux-A/default,111,0' zsh "$TMUX_MANAGER_DIR/lib/status.sh" refresh_tabs
  [ -f "$lock_a" ]

  run env TMUX_MANAGER_DEBOUNCE_SEC=30 TMUX='/tmp/tmux-B/default,222,0' zsh "$TMUX_MANAGER_DIR/lib/status.sh" refresh_tabs
  [ -f "$lock_b" ]

  rm -f "$lock_a" "$lock_b"
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
