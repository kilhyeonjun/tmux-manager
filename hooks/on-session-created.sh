#!/usr/bin/env zsh
# tmux-manager — session-created hook helper
# Called by tmux set-hook: assigns UUID to newly created sessions.

TMUX_MANAGER_DIR="${0:A:h:h}"
source "$TMUX_MANAGER_DIR/conf/defaults.conf"
source "$TMUX_MANAGER_DIR/lib/core.sh"
_tmux_ensure_uuid "$@"
