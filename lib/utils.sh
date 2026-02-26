# tmux-manager — common utilities
# Sourced by init.sh

# Enter a tmux session (switch if inside tmux, attach otherwise)
_tmux_enter_session() {
  local session_name="$1"
  [ -z "$session_name" ] && return 1
  if [ -n "$TMUX" ]; then
    tmux switch-client -t "$session_name" 2>/dev/null
  else
    tmux attach -t "$session_name" 2>/dev/null
  fi
}
