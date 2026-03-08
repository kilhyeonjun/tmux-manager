#!/usr/bin/env bats
# Regression tests for zsh loop-local output leak causing fzf list spacing issues.

load helpers/setup

@test "zsh loop local declaration leaks output without typeset_silent" {
  run zsh -c 'f(){ while read -r x; do local a; a="$x"; done <<< $'"'"'a\nb'"'"';}; f'
  [ "$status" -eq 0 ]
  # Regression signal: zsh prints previous local value like "a=a"
  [[ "$output" == *"a="* ]]
}

@test "typeset_silent suppresses loop local output leak" {
  run zsh -c 'f(){ setopt local_options typeset_silent; while read -r x; do local a; a="$x"; done <<< $'"'"'a\nb'"'"';}; f'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_tmux_archive_manager enables typeset_silent" {
  run grep -A2 '^_tmux_archive_manager() {' "$TMUX_MANAGER_DIR/lib/core.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"typeset_silent"* ]]
}

@test "_tmux_archive_level2 enables typeset_silent" {
  run grep -A2 '^_tmux_archive_level2() {' "$TMUX_MANAGER_DIR/lib/core.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"typeset_silent"* ]]
}

@test "tmux-manager enables typeset_silent" {
  run grep -A2 '^tmux-manager() {' "$TMUX_MANAGER_DIR/lib/core.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"typeset_silent"* ]]
}

@test "core.sh keeps zsh syntax validity after spacing fix" {
  run zsh -n "$TMUX_MANAGER_DIR/lib/core.sh"
  [ "$status" -eq 0 ]
}
