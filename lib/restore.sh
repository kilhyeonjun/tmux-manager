# tmux-manager — session restore logic
# Sourced by init.sh

# Restore a session from an archive file.
# Called from tmux-archive() restore case in core.sh.
_tmux_archive_restore() {
  local file="$1"
  if [ -z "$file" ]; then
    file=$(ls -1 "$TMUX_ARCHIVE_DIR"/*.archive 2>/dev/null | while read -r f; do
      local name=$(grep '^SESSION_NAME=' "$f" | cut -d= -f2)
      local date=$(grep '^ARCHIVED_AT=' "$f" | cut -d= -f2-)
      local wins=$(grep -c '|' "$f" 2>/dev/null)
      printf '%s|%s  %s\n' "$f" "$name" "$date"
    done | fzf --height=50% --reverse --header='복원할 아카이브 선택' -d'|' --with-nth=2 | cut -d'|' -f1)
    [ -z "$file" ] && return
  fi
  if [ ! -f "$file" ]; then
    echo "\033[31m파일 없음: $file\033[0m"; return 1
  fi

  local session_name=$(grep '^SESSION_NAME=' "$file" | cut -d= -f2)
  if tmux has-session -t "$session_name" 2>/dev/null; then
    echo "\033[31m세션 '$session_name' 이미 존재\033[0m"; return 1
  fi

  tmux new-session -d -s "$session_name"

  # Restore UUID
  local archived_uuid=$(grep '^SESSION_UUID=' "$file" | cut -d= -f2)
  if [ -n "$archived_uuid" ]; then
    tmux set-option -t "$session_name" @archive_uuid "$archived_uuid" 2>/dev/null
  else
    _tmux_ensure_uuid "$session_name" >/dev/null
  fi

  # Create windows
  local first_win=true
  while IFS='|' read -r idx wname layout; do
    if [ "$first_win" = true ]; then
      tmux rename-window -t "${session_name}:1" "$wname" 2>/dev/null
      first_win=false
    else
      tmux new-window -t "${session_name}" -n "$wname"
    fi
  done < <(grep -A9999 '^---WINDOWS---' "$file" | grep -B9999 '^---PANES---' | grep -v '^---')

  local base="${file%.archive}"

  # Plugin hook: restore OC metadata
  if typeset -f _tmux_oc_restore_metadata > /dev/null 2>&1; then
    _tmux_oc_restore_metadata "$file" "$session_name"
  fi

  # Variables for OC plugin (dynamic scoping)
  local _TMUX_RESTORE_RUNNING_CMDS=''
  local _TMUX_RESTORE_OC_PANES=''
  local running_cmds=''

  # Restore panes
  local prev_widx=''
  while IFS='|' read -r sn widx pidx ppath pcmd ptitle; do
    local target="${session_name}:${widx}"

    # Detect OC pane (simple string check — no opencode CLI needed)
    local oc_line=''
    oc_line=$(grep -A9999 '^---OPENCODE---' "$file" | grep "^${widx}|${pidx}|")
    local is_oc=false
    [[ "$ptitle" == "OC |"* ]] && is_oc=true
    [ -n "$oc_line" ] && is_oc=true

    # Create pane and restore scrollback
    if [ "$widx" != "$prev_widx" ]; then
      local pane_file="${base}_w${widx}_p${pidx}.pane"
      if [ -f "$pane_file" ] && grep -q '[^[:space:]]' "$pane_file"; then
        tmux send-keys -t "${target}.${pidx}" " cat '${pane_file}'" Enter
        sleep 0.3
      fi
      local qpath="${(q)ppath}"
      tmux send-keys -t "${target}.${pidx}" "cd -- $qpath" Enter
      prev_widx="$widx"
    else
      tmux split-window -t "$target" -c "$ppath"
      local pane_file="${base}_w${widx}_p${pidx}.pane"
      if [ -f "$pane_file" ] && grep -q '[^[:space:]]' "$pane_file"; then
        tmux send-keys -t "${target}" " cat '${pane_file}'" Enter
        sleep 0.3
      fi
    fi

    # OC pane: delegate to plugin
    if [ "$is_oc" = true ]; then
      if typeset -f _tmux_oc_setup_restored_pane > /dev/null 2>&1; then
        _tmux_oc_setup_restored_pane "$target" "$widx" "$pidx" "$ptitle" "$ppath" "$oc_line"
      fi
    elif [ -n "$pcmd" ] && [ "$pcmd" != "zsh" ] && [ "$pcmd" != "bash" ]; then
      running_cmds="${running_cmds}  w${widx}.${pidx}: \033[33m${pcmd}\033[0m (${ppath})\n"
    fi
  done < <(grep -A9999 '^---PANES---' "$file" | grep -B9999 '^---OPENCODE---' | grep -v '^---')

  # Merge plugin running_cmds
  running_cmds="${_TMUX_RESTORE_RUNNING_CMDS}${running_cmds}"
  local oc_panes="$_TMUX_RESTORE_OC_PANES"

  # Restore window layouts
  while IFS='|' read -r idx wname layout; do
    tmux select-layout -t "${session_name}:${idx}" "$layout" 2>/dev/null
  done < <(grep -A9999 '^---WINDOWS---' "$file" | grep -B9999 '^---PANES---' | grep -v '^---')

  echo "\033[32m✓ 복원 완료: $session_name\033[0m"

  if [ -n "$running_cmds" ]; then
    echo "\033[33m⚠ 다음 프로세스는 수동 재시작 필요:\033[0m"
    echo -e "$running_cmds"
  fi

  # Plugin hook: OC restart prompt
  if [ -n "$oc_panes" ] && typeset -f _tmux_oc_prompt_restart > /dev/null 2>&1; then
    _tmux_oc_prompt_restart "$session_name" "$oc_panes"
  fi
}
