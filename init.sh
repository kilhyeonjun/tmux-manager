#!/usr/bin/env zsh
# tmux-manager — entrypoint
# Source this file in your .zshrc:
#   source ~/path/to/tmux-manager/init.sh

TMUX_MANAGER_DIR="${0:A:h}"
export TMUX_MANAGER_DIR

# Configuration defaults
source "$TMUX_MANAGER_DIR/conf/defaults.conf"

# Core libraries
source "$TMUX_MANAGER_DIR/lib/utils.sh"
source "$TMUX_MANAGER_DIR/lib/metrics.sh"
source "$TMUX_MANAGER_DIR/lib/archive_format.sh"
source "$TMUX_MANAGER_DIR/lib/core.sh"
source "$TMUX_MANAGER_DIR/lib/restore.sh"

# Auto-load plugins
for _tmux_mgr_plugin in "$TMUX_MANAGER_PLUGINS_DIR"/*.sh(N); do
  source "$_tmux_mgr_plugin"
done
unset _tmux_mgr_plugin

# Register tmux hooks (only inside interactive tmux sessions)
if [[ -n "$TMUX" ]] && [[ -t 0 ]]; then
  source "$TMUX_MANAGER_DIR/hooks/tmux-hooks.conf"
fi

# Auto-launch session manager on terminal open (opt-in via TMUX_MANAGER_AUTO_LAUNCH=1)
if [[ "$TMUX_MANAGER_AUTO_LAUNCH" == '1' ]] && command -v tmux &>/dev/null && [ -z "$TMUX" ] && [[ -t 0 ]] && command -v fzf &>/dev/null; then
  tmux-manager
fi
