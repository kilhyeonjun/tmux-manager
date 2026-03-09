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

_tmux_archive_safe_name() {
  local raw="$1"
  [ -z "$raw" ] && { echo "session"; return; }
  local safe
  safe=$(printf '%s' "$raw" | tr -c '[:alnum:]_.-' '_')
  while [[ "$safe" == [._-]* ]]; do
    safe="${safe#?}"
  done
  while [[ "$safe" == *[._-] ]]; do
    safe="${safe%?}"
  done
  [ -z "$safe" ] && safe="session"
  echo "$safe"
}

_tmux_archive_lock_dir() {
  echo "$TMUX_ARCHIVE_DIR/.tmux-manager.lock"
}

_tmux_archive_lock_acquire() {
  local timeout_sec="${1:-20}"
  case "$timeout_sec" in
    ''|*[!0-9]*) timeout_sec=20 ;;
  esac

  mkdir -p "$TMUX_ARCHIVE_DIR" 2>/dev/null || return 1
  local lockdir
  lockdir=$(_tmux_archive_lock_dir)
  local waited=0
  local stale_after="${TMUX_MANAGER_LOCK_STALE_AFTER:-300}"
  case "$stale_after" in
    ''|*[!0-9]*) stale_after=300 ;;
  esac
  [ "$stale_after" -lt 1 ] 2>/dev/null && stale_after=300

  while ! mkdir "$lockdir" 2>/dev/null; do
    local created_at_file="$lockdir/created_at"
    local now
    now=$(date +%s)
    local created_at=0
    [ -f "$created_at_file" ] && created_at=$(cat "$created_at_file" 2>/dev/null)
    case "$created_at" in
      ''|*[!0-9]*) created_at=0 ;;
    esac

    if [ "$created_at" -gt 0 ] 2>/dev/null && [ $((now - created_at)) -gt "$stale_after" ]; then
      rm -rf "$lockdir" 2>/dev/null || true
      continue
    fi

    if [ "$waited" -ge "$timeout_sec" ]; then
      echo "\033[31m아카이브 락 획득 실패: ${lockdir}\033[0m" >&2
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done

  date +%s > "$lockdir/created_at" 2>/dev/null || true
  printf '%s\n' "$$" > "$lockdir/pid" 2>/dev/null || true
  return 0
}

_tmux_archive_lock_release() {
  local lockdir
  lockdir=$(_tmux_archive_lock_dir)
  rm -rf "$lockdir" 2>/dev/null || true
}

_tmux_archive_with_lock() {
  local timeout_sec="$1"
  shift
  [ "$#" -eq 0 ] && return 1
  _tmux_archive_lock_acquire "$timeout_sec" || return 1
  "$@"
  local rc=$?
  _tmux_archive_lock_release
  return $rc
}
