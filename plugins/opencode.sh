# tmux-manager — OpenCode plugin
# Provides OC session capture, restore, and restart functionality.
# If this plugin is not loaded, core archive/restore still works — OC features are skipped.

if ! typeset -f _tmux_af_format_version > /dev/null 2>&1; then
  source "$TMUX_MANAGER_DIR/lib/archive_format.sh" 2>/dev/null
fi

# ── Capture ─────────────────────────────────────────────────────────────────
# Append OpenCode session data to the archive file's ---OPENCODE--- section.
# Called from lib/core.sh during `tmux-archive save`.
_tmux_oc_detect_sid_from_pane() {
  local pane_file="$1"
  [ -f "$pane_file" ] || return 1

  local sid=''
  sid=$(grep -Eo 'opencode[[:space:]]+-s[[:space:]]+ses_[A-Za-z0-9]+' "$pane_file" 2>/dev/null | awk '{print $3}' | tail -1)
  [ -z "$sid" ] && sid=$(grep -Eo 'ses_[A-Za-z0-9]+' "$pane_file" 2>/dev/null | tail -1)
  [ -z "$sid" ] && return 1
  echo "$sid"
}

_tmux_oc_sid_from_title() {
  local title="$1" list_json="$2" list_table="$3"
  [ -z "$title" ] && return 1

  local sid=''
  if [ -n "$list_json" ]; then
    sid=$(python3 -c 'import json,sys
title=sys.argv[1].strip()
raw=sys.stdin.read().strip()
if not raw:
    raise SystemExit(0)
try:
    data=json.loads(raw)
except Exception:
    raise SystemExit(0)
items=data if isinstance(data,list) else [data]
for item in items:
    if not isinstance(item,dict):
        continue
    sid=item.get("id","")
    ititle=item.get("title")
    if not ititle and isinstance(item.get("info"),dict):
        ititle=item["info"].get("title","")
    if isinstance(sid,str) and sid.startswith("ses_") and isinstance(ititle,str) and ititle.strip()==title:
        print(sid)
        break' "$title" <<< "$list_json" 2>/dev/null)
  fi

  if [ -z "$sid" ] && [ -n "$list_table" ]; then
    sid=$(echo "$list_table" | awk -v t="$title" 'index($0, t) > 0 {print $1; exit}')
  fi

  [ -z "$sid" ] && return 1
  echo "$sid"
}

_tmux_oc_capture_session() {
  local session="$1" file="$2" base="$3"
  command -v opencode &>/dev/null || return 0
  local fmt
  fmt=$(_tmux_af_format_version "$file")

  local oc_list_json=$(opencode session list --format json 2>/dev/null)
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
    detected_sid=$(_tmux_oc_detect_sid_from_pane "$pane_file")

    if [[ "$_title" == "OC |"* ]]; then
      local oc_title="${_title#OC | }"
      local oc_sid="$detected_sid"
      if [ -z "$oc_sid" ]; then
        oc_sid=$(_tmux_oc_sid_from_title "$oc_title" "$oc_list_json" "$oc_list")
      fi
      local oc_dir="$_ppath"
      if [ -n "$oc_sid" ]; then
        _tmux_oc_enrich_meta "$oc_sid" oc_title oc_dir
      fi
      if [ "$fmt" -ge 2 ] 2>/dev/null; then
        oc_sid=$(_tmux_af_escape "$oc_sid")
        oc_title=$(_tmux_af_escape "$oc_title")
        oc_dir=$(_tmux_af_escape "$oc_dir")
      fi
      echo "${_widx}|${_pidx}|${oc_sid}|${oc_title}|${oc_dir}" >> "$file"
    elif [ -n "$detected_sid" ]; then
      local fallback_title='(detected)'
      local fallback_dir="$_ppath"
      _tmux_oc_enrich_meta "$detected_sid" fallback_title fallback_dir
      if [ "$fmt" -ge 2 ] 2>/dev/null; then
        detected_sid=$(_tmux_af_escape "$detected_sid")
        fallback_title=$(_tmux_af_escape "$fallback_title")
        fallback_dir=$(_tmux_af_escape "$fallback_dir")
      fi
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
  [[ "$title_var" == [a-zA-Z_][a-zA-Z0-9_]* ]] || return 1
  [[ "$dir_var" == [a-zA-Z_][a-zA-Z0-9_]* ]] || return 1
  local oc_meta=$(opencode export "$sid" 2>/dev/null | python3 -c \
    'import sys,json; d=json.load(sys.stdin).get("info",{}); t=d.get("title","").replace("|","/"); p=d.get("directory",""); print(t); print(p)' 2>/dev/null)
  if [ -n "$oc_meta" ]; then
    local exported_title="${oc_meta%%$'\n'*}"
    local exported_dir="${oc_meta#*$'\n'}"
    if [ -n "$exported_title" ]; then
      if typeset -n _tmux_oc_tref="$title_var" 2>/dev/null; then
        _tmux_oc_tref="$exported_title"
      else
        eval "$title_var=\$exported_title"
      fi
    fi
    if [ -n "$exported_dir" ]; then
      if typeset -n _tmux_oc_dref="$dir_var" 2>/dev/null; then
        _tmux_oc_dref="$exported_dir"
      else
        eval "$dir_var=\$exported_dir"
      fi
    fi
  fi
}

# ── Restore metadata ────────────────────────────────────────────────────────
# Set @oc_saved_* tmux options from archive data.
# Called from lib/restore.sh during restore.
_tmux_oc_restore_metadata() {
  local file="$1" session_name="$2"
  local fmt
  fmt=$(_tmux_af_format_version "$file")
  local oc_saved_lines
  oc_saved_lines=$(_tmux_af_section_lines "$file" '---OPENCODE---' '')
  local oc_saved_count=0 oc_saved_sid_missing=0
  local oc_saved_titles='' oc_saved_sids=''
  local widx pidx sid title dir
  while IFS='|' read -r widx pidx sid title dir; do
    [ -z "$widx" ] && continue
    sid=$(_tmux_af_decode_field_if_needed "$fmt" "$sid")
    title=$(_tmux_af_decode_field_if_needed "$fmt" "$title")
    oc_saved_count=$((oc_saved_count + 1))
    if [ -z "$sid" ]; then
      oc_saved_sid_missing=$((oc_saved_sid_missing + 1))
    else
      if [ -z "$oc_saved_sids" ]; then oc_saved_sids="$sid"; else oc_saved_sids="${oc_saved_sids}$'\x1f'${sid}"; fi
    fi
    if [ -n "$title" ]; then
      if [ -z "$oc_saved_titles" ]; then oc_saved_titles="$title"; else oc_saved_titles="${oc_saved_titles}$'\x1f'${title}"; fi
    fi
  done <<< "$oc_saved_lines"

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
  local target="$1" widx="$2" pidx="$3" ptitle="$4" ppath="$5" oc_line="$6" pane_target="$7"
  [ -z "$pane_target" ] && pane_target="${target}.${pidx}"
  local fmt="${_TMUX_RESTORE_ARCHIVE_FMT:-1}"

  local oc_title="${ptitle#OC | }"
  if [ -z "$oc_title" ] || [ "$oc_title" = "$ptitle" ]; then
    oc_title=$(echo "$oc_line" | cut -d'|' -f4)
  fi
  oc_title=$(_tmux_af_decode_field_if_needed "$fmt" "$oc_title")
  [ -z "$oc_title" ] && oc_title='(detected)'

  tmux select-pane -t "$pane_target" -T "OC | ${oc_title}" 2>/dev/null

  local oc_sid
  oc_sid=$(echo "$oc_line" | cut -d'|' -f3)
  oc_sid=$(_tmux_af_decode_field_if_needed "$fmt" "$oc_sid")
  local oc_dir
  oc_dir=$(echo "$oc_line" | cut -d'|' -f5)
  oc_dir=$(_tmux_af_decode_field_if_needed "$fmt" "$oc_dir")
  [ -z "$oc_dir" ] && oc_dir="$ppath"

  if [ -n "$oc_sid" ]; then
    if [ -n "$oc_dir" ] && [ "$oc_dir" != "$ppath" ]; then
      local qdir="${(q)oc_dir}"
      tmux send-keys -t "$pane_target" "cd -- $qdir" Enter
    fi
    _TMUX_RESTORE_RUNNING_CMDS="${_TMUX_RESTORE_RUNNING_CMDS}  w${widx}.${pidx}: \033[33mopencode\033[0m (\"\033[36m${oc_title}\033[0m\")\n           → cd ${oc_dir} && opencode -s ${oc_sid}\n"
    local esc_sid esc_dir esc_title
    esc_sid=$(_tmux_af_escape "$oc_sid")
    esc_dir=$(_tmux_af_escape "$oc_dir")
    esc_title=$(_tmux_af_escape "$oc_title")
    _TMUX_RESTORE_OC_PANES="${_TMUX_RESTORE_OC_PANES}${pane_target}|${esc_sid}|${esc_dir}|${esc_title}\n"
  else
    _TMUX_RESTORE_RUNNING_CMDS="${_TMUX_RESTORE_RUNNING_CMDS}  w${widx}.${pidx}: \033[33mopencode\033[0m (\"${oc_title}\")\n           → opencode -c\n"
    local esc_ppath esc_title
    esc_ppath=$(_tmux_af_escape "$ppath")
    esc_title=$(_tmux_af_escape "$oc_title")
    _TMUX_RESTORE_OC_PANES="${_TMUX_RESTORE_OC_PANES}${pane_target}||${esc_ppath}|${esc_title}\n"
  fi
}

# ── OC restart prompt ───────────────────────────────────────────────────────
# Interactive prompt: re-launch OpenCode sessions after restore.
# Creates tmux hooks for post-attach auto-execution.
_tmux_oc_prompt_restart() {
  local session_name="$1" oc_panes="$2"
  [ -z "$oc_panes" ] && return 0
  [[ -t 0 ]] || return 0

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
      sid=$(_tmux_af_unescape "$sid")
      dir=$(_tmux_af_unescape "$dir")
      title=$(_tmux_af_unescape "$title")
      [ -z "$dir" ] && dir='/'
      local qdir="${(q)dir}"
      if [ -n "$sid" ]; then
        echo "tmux send-keys -t '$tgt' \"cd -- $qdir\" Enter" >> "$oc_script"
        echo "sleep 0.3" >> "$oc_script"
        echo "tmux send-keys -t '$tgt' 'opencode -s $sid' Enter" >> "$oc_script"
      else
        echo "tmux send-keys -t '$tgt' \"cd -- $qdir\" Enter" >> "$oc_script"
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
      sid=$(_tmux_af_unescape "$sid")
      dir=$(_tmux_af_unescape "$dir")
      title=$(_tmux_af_unescape "$title")
      [ -z "$dir" ] && dir='/'
      local safe_title="${title//\'/  }"
      local safe_dir="${dir//\'/  }"
      local qdir="${(q)dir}"
      echo "tmux send-keys -t '$tgt' \"cd -- $qdir\" Enter" >> "$info_script"
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
