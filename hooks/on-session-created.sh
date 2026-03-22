#!/usr/bin/env zsh
# tmux-manager — session-created hook helper
# Called by tmux set-hook: assigns UUID to newly created sessions.

TMUX_MANAGER_DIR="${0:A:h:h}"
source "$TMUX_MANAGER_DIR/conf/defaults.conf"
source "$TMUX_MANAGER_DIR/lib/core.sh"
_tmux_ensure_uuid "$@"

# Sync cmux workspace tab name to the new session name
if [[ -n "${CMUX_BUNDLE_ID:-}" ]] || [[ -S "${CMUX_SOCKET_PATH:-}" ]]; then
  if command -v cmux &>/dev/null; then
    _cmux_sn=$(tmux display-message -p '#{session_name}' 2>/dev/null)
    if [ -n "$_cmux_sn" ]; then
      _cmux_cwd=$(tmux display-message -p '#{pane_current_path}' 2>/dev/null)
      _cmux_label="$_cmux_sn"
      _cmux_br=$(git -C "$_cmux_cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
      [ -n "$_cmux_br" ] && _cmux_label="${_cmux_sn} (${_cmux_br})"
      cmux rename-tab "$_cmux_label" 2>/dev/null || true
    fi
    unset _cmux_sn _cmux_cwd _cmux_label _cmux_br
  fi
fi
