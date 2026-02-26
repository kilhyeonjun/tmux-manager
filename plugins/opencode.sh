# tmux-manager — OpenCode plugin
# Provides OC session capture, restore, and restart functionality.
# If this plugin is not loaded, core archive/restore still works — OC features are skipped.

# ── Capture ─────────────────────────────────────────────────────────────────
# Append OpenCode session data to the archive file's ---OPENCODE--- section.
# Called from lib/core.sh during `tmux-archive save`.
_tmux_oc_capture_session() {
  local session="$1" file="$2" base="$3"
  command -v opencode &>/dev/null || return 0

  local oc_list=$(opencode session list 2>/dev/null)
  local pane_ids=$(tmux list-panes -t "$session" -F '#{pane_id}' 2>/dev/null)

  echo "$pane_ids" | while read -r _pid; do
    [ -z "$_pid" ] && continue
    local _widx _pidx _title _ppath
    _widx=$(tmux display-message -p -t "$_pid" '#{window_index}' 2>/dev/null)
    _pidx=$(tmux display-message -p -t "$_pid" '#{pane_index}' 2>/dev/null)
    _title=$(tmux display-message -p -t "$_pid" '#{pane_title}' 2>/dev/null)
    _ppath=$(tmux display-message -p -t "$_pid" '#{pane_current_path}' 2>/dev/null)

    local pane_file="${base}_w${_widx}_p${_pidx}.pane"
    local detected_sid=''
    if [ -f "$pane_file" ]; then
      detected_sid=$(grep -Eo 'ses_[A-Za-z0-9]+' "$pane_file" | tail -1)
    fi

    if [[ "$_title" == "OC |"* ]]; then
      local oc_title="${_title#OC | }"
      local oc_sid=$(echo "$oc_list" | awk -v t="$oc_title" 'index($0, t) > 0 {print $1;
      exit}')
      [ -z "$oc_sid" ] && oc_sid="$detected_sid"
      local oc_dir="$_ppath"
      if [ -n "$oc_sid" ]; then
        _tmux_oc_enrich_meta "$oc_sid" oc_title oc_dir
      fi
      echo "${_widx}|${_pidx}|${oc_sid}|${oc_title}|${oc_dir}" >> "$file"
    elif [ -n "$detected_sid" ]; then
      local fallback_title='(detected)'
      local fallback_dir="$_ppath"
      _tmux_oc_enrich_meta "$detected_sid" fallback_title fallback_dir
      echo "${_widx}|${_pidx}|${detected_sid}|${fallback_title}|${fallback_dir}" >> "$file"
    fi
  done
}

# ── Enrich metadata via `opencode export` ───────────────────────────────────
# Usage: _tmux_oc_enrich_meta <sid> <title_var> <dir_var>
# Modifies the caller's variables via dynamic scoping.
_tmux_oc_enrich_meta() {
  local sid="$1" title_var="$2" dir_var="$3"
  [ -z "$sid" ] && return 1
  local oc_meta=$(opencode export "$sid" 2>/dev/null | python3 -c \
    'import sys,json; d=json.load(sys.stdin).get("info",{}); t=d.get("title","").replace("|","/"); p=d.get("directory",""); print(t); print(p)' 2>/dev/null)
  if [ -n "$oc_meta" ]; then
    local exported_title="${oc_meta%%$'\n'*}"
    local exported_dir="${oc_meta#*$'\n'}"
    [ -n "$exported_title" ] && eval "$title_var=\$exported_title"
    [ -n "$exported_dir" ] && eval "$dir_var=\$exported_dir"
  fi
}

# ── Restore metadata ────────────────────────────────────────────────────────
# Set @oc_saved_* tmux options from archive data.
# Called from lib/restore.sh during restore.
_tmux_oc_restore_metadata() {
  local file="$1" session_name="$2"
  local oc_saved_lines=$(grep -A9999 '^---OPENCODE---' "$file" | grep -v '^---')
  local oc_saved_count=$(echo "$oc_saved_lines" | grep -c '^[0-9]' 2>/dev/null)
  local oc_saved_titles=$(echo "$oc_saved_lines" | awk -F'|' 'NF>=4 && $4!="" {print $4}' | paste -sd $'\x1f' -)
  local oc_saved_sids=$(echo "$oc_saved_lines" | awk -F'|' 'NF>=3 && $3!="" {print $3}' | paste -sd $'\x1f' -)
  local oc_saved_sid_missing=$(echo "$oc_saved_lines" | awk -F'|' 'NF>=3 && $3=="" {c++} END{print c+0}')

  if [ "$oc_saved_count" -gt 0 ] 2>/dev/null; then
    tmux set-option -t "$session_name" @oc_saved_count "$oc_saved_count" 2>/dev/null
    tmux set-option -t "$session_name" @oc_saved_titles "$oc_saved_titles" 2>/dev/null
    tmux set-option -t "$session_name" @oc_saved_sids "$oc_saved_sids" 2>/dev/null
    tmux set-option -t "$session_name" @oc_saved_sid_missing "$oc_saved_sid_missing" 2>/dev/null
  else
    tmux set-option -u -t "$session_name" @oc_saved_count 2>/dev/null
    tmux set-option -u -t "$session_name" @oc_saved_titles 2>/dev/null
    tmux set-option -u -t "$session_name" @oc_saved_sids 2>/dev/null
    tmux set-option -u -t "$session_name" @oc_saved_sid_missing 2>/dev/null
  fi
}

# ── Pane restore handler ────────────────────────────────────────────────────
# Handle OC-specific pane setup during restore.
# Appends to _TMUX_RESTORE_RUNNING_CMDS and _TMUX_RESTORE_OC_PANES
# (declared in the calling restore function — zsh dynamic scoping).
_tmux_oc_setup_restored_pane() {
  local target="$1" widx="$2" pidx="$3" ptitle="$4" ppath="$5" oc_line="$6"

  local oc_title="${ptitle#OC | }"
  if [ -z "$oc_title" ] || [ "$oc_title" = "$ptitle" ]; then
    oc_title=$(echo "$oc_line" | cut -d'|' -f4)
  fi
  [ -z "$oc_title" ] && oc_title='(detected)'

  tmux select-pane -t "${target}.${pidx}" -T "OC | ${oc_title}" 2>/dev/null

  local oc_sid=$(echo "$oc_line" | cut -d'|' -f3)
  local oc_dir=$(echo "$oc_line" | cut -d'|' -f5)
  [ -z "$oc_dir" ] && oc_dir="$ppath"

  if [ -n "$oc_sid" ]; then
    if [ -n "$oc_dir" ] && [ "$oc_dir" != "$ppath" ]; then
      tmux send-keys -t "${target}.${pidx}" "cd $oc_dir" Enter
    fi
    _TMUX_RESTORE_RUNNING_CMDS="${_TMUX_RESTORE_RUNNING_CMDS}  w${widx}.${pidx}: \033[33mopencode\033[0m (\"\033[36m${oc_title}\033[0m\")\n           → cd ${oc_dir} && opencode -s ${oc_sid}\n"
    _TMUX_RESTORE_OC_PANES="${_TMUX_RESTORE_OC_PANES}${target}.${pidx}|${oc_sid}|${oc_dir}|${oc_title}\n"
  else
    _TMUX_RESTORE_RUNNING_CMDS="${_TMUX_RESTORE_RUNNING_CMDS}  w${widx}.${pidx}: \033[33mopencode\033[0m (\"${oc_title}\")\n           → opencode -c\n"
    _TMUX_RESTORE_OC_PANES="${_TMUX_RESTORE_OC_PANES}${target}.${pidx}||${ppath}|${oc_title}\n"
  fi
}

# ── OC restart prompt ───────────────────────────────────────────────────────
# Interactive prompt: re-launch OpenCode sessions after restore.
# Creates tmux hooks for post-attach auto-execution.
_tmux_oc_prompt_restart() {
  local session_name="$1" oc_panes="$2"
  [ -z "$oc_panes" ] && return 0

  echo -n "\033[34mopencode 재실행할까요? (y/N): \033[0m"
  local oc_confirm
  read -r oc_confirm

  if [ "$oc_confirm" = 'y' ] || [ "$oc_confirm" = 'Y' ]; then
    local oc_script
    oc_script=$(mktemp -t tmux_oc)
    echo '#!/bin/zsh' > "$oc_script"
    echo 'sleep 0.8' >> "$oc_script"
    echo -e "$oc_panes" | while IFS='|' read -r tgt sid dir title; do
      [ -z "$tgt" ] && continue
      if [ -n "$sid" ]; then
        echo "tmux send-keys -t '$tgt' 'cd ${dir:-/}' Enter" >> "$oc_script"
        echo "sleep 0.3" >> "$oc_script"
        echo "tmux send-keys -t '$tgt' 'opencode -s $sid' Enter" >> "$oc_script"
      else
        echo "tmux send-keys -t '$tgt' 'cd ${dir:-/}' Enter" >> "$oc_script"
        echo "sleep 0.3" >> "$oc_script"
        echo "tmux send-keys -t '$tgt' 'opencode -c' Enter" >> "$oc_script"
      fi
    done
    echo "rm -f '$oc_script'" >> "$oc_script"
    echo "tmux set-hook -u -t '$session_name' client-attached" >> "$oc_script"
    echo "tmux set-hook -u -t '$session_name' client-session-changed" >> "$oc_script"
    chmod +x "$oc_script"
    tmux set-hook -t "$session_name" client-attached "run-shell '$oc_script'"
    tmux set-hook -t "$session_name" client-session-changed "run-shell '$oc_script'"
    echo "\033[32m✓ opencode: attach 후 자동 실행 예약\033[0m"
  else
    local info_script
    info_script=$(mktemp -t tmux_oc_info)
    echo '#!/bin/zsh' > "$info_script"
    echo 'sleep 0.8' >> "$info_script"
    echo -e "$oc_panes" | while IFS='|' read -r tgt sid dir title; do
      [ -z "$tgt" ] && continue
      local safe_title="${title//\'/  }"
      local safe_dir="${dir//\'/  }"
      echo "tmux send-keys -t '$tgt' 'cd ${dir:-/}' Enter" >> "$info_script"
      echo "sleep 0.3" >> "$info_script"
      echo "tmux send-keys -t '$tgt' \"echo '[ARCHIVED OPENCODE]'\" Enter" >> "$info_script"
      echo "tmux send-keys -t '$tgt' \"echo 'TITLE: ${safe_title}'\" Enter" >> "$info_script"
      if [ -n "$sid" ]; then
        echo "tmux send-keys -t '$tgt' \"echo 'SID: ${sid}'\" Enter" >> "$info_script"
        echo "tmux send-keys -t '$tgt' \"echo 'DIR: ${safe_dir}'\" Enter" >> "$info_script"
        echo "tmux send-keys -t '$tgt' \"echo 'RUN: opencode -s ${sid}'\" Enter" >> "$info_script"
      else
        echo "tmux send-keys -t '$tgt' \"echo 'DIR: ${safe_dir}'\" Enter" >> "$info_script"
        echo "tmux send-keys -t '$tgt' \"echo 'RUN: opencode -c'\" Enter" >> "$info_script"
      fi
    done
    echo "rm -f '$info_script'" >> "$info_script"
    echo "tmux set-hook -u -t '$session_name' client-attached" >> "$info_script"
    echo "tmux set-hook -u -t '$session_name' client-session-changed" >> "$info_script"
    chmod +x "$info_script"
    tmux set-hook -t "$session_name" client-attached "run-shell '$info_script'"
    tmux set-hook -t "$session_name" client-session-changed "run-shell '$info_script'"
    echo "\033[90mℹ attach 후 OpenCode 복원 정보 표시\033[0m"
  fi
}
