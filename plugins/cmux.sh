# tmux-manager — cmux plugin
# Provides cmux notification, workspace metadata capture, and OSC passthrough support.
# If this plugin is not loaded, core archive/restore still works — cmux features are skipped.

if ! typeset -f _tmux_af_format_version > /dev/null 2>&1; then
  source "$TMUX_MANAGER_DIR/lib/archive_format.sh" 2>/dev/null
fi

# ── Detection ──────────────────────────────────────────────────────────────
# Check if running inside cmux terminal
_tmux_cmux_is_inside() {
  # cmux sets CMUX_BUNDLE_ID when running inside cmux terminal
  [[ -n "${CMUX_BUNDLE_ID:-}" ]] && return 0
  # fallback: check for cmux socket path
  [[ -S "${CMUX_SOCKET_PATH:-}" ]] && return 0
  return 1
}

# Check if cmux CLI is available
_tmux_cmux_has_cli() {
  command -v cmux &>/dev/null
}

# ── tmux server startup ───────────────────────────────────────────────────
# When inside cmux, start tmux server with -D (no-daemon) as a background
# job so run-shell subprocesses maintain cmux process ancestry for socket auth.
# Must be called BEFORE tmux new-session, not inline with flags.
_tmux_cmux_ensure_server() {
  _tmux_cmux_is_inside || return 0
  # Skip if server already running
  tmux list-sessions &>/dev/null 2>&1 && return 0
  # Start server in foreground mode as background job to keep cmux ancestry
  tmux -D start-server &
  # Wait for server to be ready
  local _tries=0
  while ! tmux list-sessions &>/dev/null 2>&1 && [ "$_tries" -lt 20 ]; do
    sleep 0.1
    _tries=$((_tries + 1))
  done
}

# ── Notification ───────────────────────────────────────────────────────────
# Send a notification via cmux notify CLI.
# Usage: _tmux_cmux_notify <title> <body>
_tmux_cmux_notify() {
  _tmux_cmux_has_cli || return 0
  local title="$1" body="$2"
  cmux notify --title "$title" --body "$body" 2>/dev/null || true
}

# Called after successful archive save
_tmux_cmux_notify_save() {
  local session="$1" file="$2" auto_mode="$3"
  _tmux_cmux_is_inside || return 0
  if [ "$auto_mode" = 'auto' ]; then
    _tmux_cmux_notify "Auto Archive" "${session}: saved"
  else
    _tmux_cmux_notify "Archive Saved" "${session}: $(basename "$file")"
  fi
}

# Called after successful restore
_tmux_cmux_notify_restore() {
  local session_name="$1"
  _tmux_cmux_is_inside || return 0
  _tmux_cmux_notify "Session Restored" "$session_name"
}

# Called on restore failure
_tmux_cmux_notify_restore_fail() {
  local reason="$1"
  _tmux_cmux_is_inside || return 0
  _tmux_cmux_notify "Restore Failed" "$reason"
}

# ── Workspace rename ──────────────────────────────────────────────────
# Rename the cmux workspace tab to match the tmux session name.
# Optionally appends git branch info when available.
_tmux_cmux_rename_workspace() {
  _tmux_cmux_is_inside || return 0
  _tmux_cmux_has_cli || return 0
  local name="$1"
  [ -z "$name" ] && return 0
  cmux rename-workspace "$name" 2>/dev/null || true
}

# Build a workspace label from session name + optional git branch.
_tmux_cmux_workspace_label() {
  local session_name="$1" cwd="$2"
  local label="$session_name"
  if [ -n "$cwd" ]; then
    local branch
    branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ -n "$branch" ]; then
      label="${session_name} (${branch})"
    fi
  fi
  echo "$label"
}

# ── Capture ────────────────────────────────────────────────────────────────
# Append cmux workspace metadata to the archive file's ---CMUX--- section.
# Called from lib/core.sh during `tmux-archive save`.
_tmux_cmux_capture_session() {
  local session="$1" file="$2" base="$3"
  _tmux_cmux_has_cli || return 0

  local fmt
  fmt=$(_tmux_af_format_version "$file")

  # Query cmux for workspace info via socket API
  local workspace_id='' workspace_label=''
  workspace_id=$(cmux current-workspace --format json 2>/dev/null | python3 -c '
import json, sys
try:
  d = json.load(sys.stdin)
  print(d.get("id", ""))
except: pass' 2>/dev/null) || true

  workspace_label=$(cmux current-workspace --format json 2>/dev/null | python3 -c '
import json, sys
try:
  d = json.load(sys.stdin)
  print(d.get("label", ""))
except: pass' 2>/dev/null) || true

  # Collect listening ports for this session's panes
  local ports=''
  ports=$(cmux current-workspace --format json 2>/dev/null | python3 -c '
import json, sys
try:
  d = json.load(sys.stdin)
  ps = d.get("ports", [])
  print(",".join(str(p) for p in ps))
except: pass' 2>/dev/null) || true

  if [ -n "$workspace_id" ] || [ -n "$workspace_label" ]; then
    if [ "$fmt" -ge 2 ] 2>/dev/null; then
      workspace_id=$(_tmux_af_escape "$workspace_id")
      workspace_label=$(_tmux_af_escape "$workspace_label")
      ports=$(_tmux_af_escape "$ports")
    fi
    echo "${workspace_id}|${workspace_label}|${ports}" >> "$file"
  fi
}

# ── Restore metadata ──────────────────────────────────────────────────────
# Read cmux workspace metadata from archive and set tmux session options.
# Called from lib/restore.sh during restore.
_tmux_cmux_restore_metadata() {
  local file="$1" session_name="$2"
  local fmt
  fmt=$(_tmux_af_format_version "$file")
  local cmux_lines
  cmux_lines=$(_tmux_af_section_lines "$file" '---CMUX---' '')
  [ -z "$(echo "$cmux_lines" | tr -d '[:space:]')" ] && return 0

  local workspace_id workspace_label ports
  while IFS='|' read -r workspace_id workspace_label ports; do
    [ -z "$workspace_id" ] && [ -z "$workspace_label" ] && continue
    workspace_id=$(_tmux_af_decode_field_if_needed "$fmt" "$workspace_id")
    workspace_label=$(_tmux_af_decode_field_if_needed "$fmt" "$workspace_label")
    ports=$(_tmux_af_decode_field_if_needed "$fmt" "$ports")

    [ -n "$workspace_id" ] && \
      tmux set-option -t "$session_name" @cmux_workspace_id "$workspace_id" 2>/dev/null
    [ -n "$workspace_label" ] && \
      tmux set-option -t "$session_name" @cmux_workspace_label "$workspace_label" 2>/dev/null
    [ -n "$ports" ] && \
      tmux set-option -t "$session_name" @cmux_ports "$ports" 2>/dev/null
    break  # only first line
  done <<< "$cmux_lines"
}

# ── OSC Passthrough ────────────────────────────────────────────────────────
# Auto-enable allow-passthrough when running tmux inside cmux.
# Called from hooks/tmux-hooks.conf during hook registration.
_tmux_cmux_setup_passthrough() {
  _tmux_cmux_is_inside || return 0

  # Enable passthrough so OSC sequences (notifications, clipboard) propagate to cmux
  tmux set -g allow-passthrough on 2>/dev/null || true

  # Also set the specific passthrough options for notification sequences
  # OSC 9 (iTerm2), OSC 99 (Kitty), OSC 777 (rxvt-unicode) are used by cmux
  tmux set -g set-clipboard on 2>/dev/null || true
}
