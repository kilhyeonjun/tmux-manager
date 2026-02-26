#!/usr/bin/env zsh
# tmux-manager — auto-archive cron/LaunchAgent script
# Schedule with crontab or LaunchAgent to snapshot all active sessions.

export PATH="$HOME/.opencode/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

tmux ls &>/dev/null || exit 0

TMUX_MANAGER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$TMUX_MANAGER_DIR/init.sh"

_tmux_autoarchive_all

_tmux_autoarchive_cleanup
