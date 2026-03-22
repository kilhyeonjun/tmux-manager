#!/usr/bin/env bash
# bats test helpers — common setup/teardown

export TMUX_MANAGER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export TMUX_ARCHIVE_DIR="$(mktemp -d -t tmux_test_archives)"
export TMUX_ARCHIVE_AUTO_MAX_PER_UUID=10
export TMUX_ARCHIVE_AUTO_MAX_AGE_DAYS=0
export TMUX_ARCHIVE_AUTO_CLEANUP=1
export TMUX_ARCHIVE_AUTO_SCROLLBACK_LINES=200
export TMUX_MANAGER_DEBOUNCE_SEC=2

setup() {
  mkdir -p "$TMUX_ARCHIVE_DIR"
}

teardown() {
  rm -rf "$TMUX_ARCHIVE_DIR"
}

# Create a minimal archive file for testing
create_test_archive() {
  local name="${1:-test-session}"
  local uuid="${2:-$(uuidgen)}"
  local ts="${3:-$(date +%Y%m%d_%H%M%S)}"
  local safe_name=$(echo "$name" | tr ' ' '_')
  local file="$TMUX_ARCHIVE_DIR/${safe_name}_${ts}.archive"

  cat > "$file" << EOF
SESSION_NAME=$name
SESSION_UUID=$uuid
ARCHIVED_AT=$(date '+%Y-%m-%d %H:%M:%S')
SCROLLBACK_MODE=full
---WINDOWS---
1|main|tiled
2|editor|tiled
---PANES---
$name|1|0|/tmp|zsh|zsh
$name|2|0|/home|vim|vim
---OPENCODE---
---CLAUDE-CODE---
---CMUX---
EOF
  echo "$file"
}

# Create an auto-archived test archive
create_auto_archive() {
  local name="${1:-test-session}"
  local uuid="${2:-$(uuidgen)}"
  local ts="${3:-$(date +%Y%m%d_%H%M%S)}"
  local safe_name=$(echo "$name" | tr ' ' '_')
  local file="$TMUX_ARCHIVE_DIR/${safe_name}_${ts}.archive"

  cat > "$file" << EOF
SESSION_NAME=$name
SESSION_UUID=$uuid
ARCHIVED_AT=$(date '+%Y-%m-%d %H:%M:%S')
AUTO_ARCHIVED=true
SCROLLBACK_MODE=recent
SCROLLBACK_LINES=200
---WINDOWS---
1|main|tiled
---PANES---
$name|1|0|/tmp|zsh|zsh
---OPENCODE---
---CLAUDE-CODE---
---CMUX---
EOF
  echo "$file"
}
