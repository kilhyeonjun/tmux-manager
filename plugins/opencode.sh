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

_tmux_oc_detect_sid_from_tui() {
  local pane_target="$1" pane_cwd="$2"
  local OC_DB="${_TMUX_OC_DB:-/Users/gameduo/.local/share/opencode/opencode.db}"
  [ -f "$OC_DB" ] || return 1
  command -v sqlite3 &>/dev/null || return 1

  local pane_content
  pane_content=$(tmux capture-pane -t "$pane_target" -p -S 0 2>/dev/null) || return 1
  [ -z "$pane_content" ] && return 1

  local db_rows
  db_rows=$(sqlite3 "$OC_DB" "SELECT id, title FROM session WHERE directory = '${pane_cwd//\'/\'\'}' ORDER BY time_updated DESC LIMIT 20;" 2>/dev/null)

  if [ -n "$db_rows" ]; then
    local sid title short
    while IFS='|' read -r sid title; do
      [ -z "$sid" ] || [ -z "$title" ] && continue
      short="${title:0:30}"
      if echo "$pane_content" | grep -qF "$short"; then
        echo "$sid"
        return 0
      fi
    done <<< "$db_rows"
  fi

  if [ -n "$_TMUX_OC_INDEX_CACHE" ] && [ -f "$_TMUX_OC_INDEX_CACHE" ]; then
    while IFS=$'\t' read -r sid title dir; do
      [ -z "$sid" ] || [ -z "$title" ] && continue
      [ "$dir" != "$pane_cwd" ] && continue
      short="${title:0:30}"
      if echo "$pane_content" | grep -qF "$short"; then
        echo "$sid"
        return 0
      fi
    done < "$_TMUX_OC_INDEX_CACHE"
  fi

  local fallback_sid
  fallback_sid=$(sqlite3 "$OC_DB" "SELECT id FROM session WHERE directory = '${pane_cwd//\'/\'\'}' ORDER BY time_updated DESC LIMIT 1;" 2>/dev/null)
  [ -n "$fallback_sid" ] && echo "$fallback_sid" && return 0

  return 1
}

_tmux_oc_capture_session() {
  local session="$1" file="$2" base="$3"
  command -v opencode &>/dev/null || return 0
  local fmt
  fmt=$(_tmux_af_format_version "$file")

  local _oc_idx_file="${_TMUX_OC_INDEX_CACHE:-}"
  local _oc_ps_file="${_TMUX_OC_PS_CACHE:-}"
  local _oc_idx=''
  if [ -n "$_oc_idx_file" ] && [ -f "$_oc_idx_file" ]; then
    _oc_idx=$(cat "$_oc_idx_file")
  fi
  if [ -z "$_oc_idx" ]; then
    _oc_idx=$(opencode session list --format json 2>/dev/null | python3 -c '
import json,sys
try:
  data=json.load(sys.stdin)
  for s in (data if isinstance(data,list) else []):
    sid=s.get("id",""); title=s.get("title","").replace("|","/"); d=s.get("directory","")
    if sid: print(f"{sid}\t{title}\t{d}")
except: pass' 2>/dev/null)
  fi

  local _oc_ps=''
  if [ -n "$_oc_ps_file" ] && [ -f "$_oc_ps_file" ]; then
    _oc_ps=$(cat "$_oc_ps_file")
  fi
  if [ -z "$_oc_ps" ]; then
    local _all_pane_pids=$(tmux list-panes -t "$session" -F '#{pane_pid}' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    _oc_ps=$(ps -axo pid=,ppid=,args= 2>/dev/null | awk -v roots="$_all_pane_pids" '
      BEGIN { split(roots, r, ","); for(i in r) root[r[i]+0]=1 }
      { pid=$1+0; ppid=$2+0; $1=""; $2=""; a[pid]=$0; p[pid]=ppid }
      END {
        for(rt in root) {
          queue[1]=rt; head=1; tail=1; found=0
          while(head<=tail && !found) {
            for(pid in p) {
              if(p[pid]==queue[head]) {
                tail++; queue[tail]=pid
                if(a[pid] ~ /[[:space:]]opencode([[:space:]]|$)/ && a[pid] !~ /eslint/) found=1
              }
            }
            head++
          }
          delete queue
          if(found) print rt "\tOC_RUNNING"
        }
      }' 2>/dev/null)
  fi

  local pane_ids=$(tmux list-panes -t "$session" -F '#{pane_id}' 2>/dev/null)

  echo "$pane_ids" | while read -r _pid; do
    [ -z "$_pid" ] && continue
    local _widx _pidx _title _ppath
    _widx=$(tmux display-message -p -t "$_pid" '#{window_index}' 2>/dev/null)
    _pidx=$(tmux display-message -p -t "$_pid" '#{pane_index}' 2>/dev/null)
    _title=$(tmux display-message -p -t "$_pid" '#{pane_title}' 2>/dev/null)
    _ppath=$(tmux display-message -p -t "$_pid" '#{pane_current_path}' 2>/dev/null)

    local pane_file="${base}_w${_widx}_p${_pidx}.pane"

    local is_oc_running=false
    local pane_pid=$(tmux display-message -p -t "$_pid" '#{pane_pid}' 2>/dev/null)
    [ -n "$pane_pid" ] && [ -n "$_oc_ps" ] && \
      echo "$_oc_ps" | awk -F'\t' -v p="$pane_pid" '$1+0==p+0 {found=1} END{exit !found}' && is_oc_running=true

    [[ "$_title" == "OC |"* ]] && is_oc_running=true
    [[ "$_title" == "OpenCode" ]] && is_oc_running=true

    if [ "$is_oc_running" = true ]; then
      local oc_sid=''
      oc_sid=$(_tmux_oc_detect_sid_from_tui "$_pid" "$_ppath" 2>/dev/null) || true

      if [ -z "$oc_sid" ]; then
        oc_sid=$(_tmux_oc_detect_sid_from_pane "$pane_file" 2>/dev/null) || true
      fi

      local oc_title='(detected)'
      local oc_dir="$_ppath"
      if [ -n "$oc_sid" ] && [ -n "$_oc_idx" ]; then
        local _meta=$(echo "$_oc_idx" | awk -F'\t' -v s="$oc_sid" '$1==s {print $2 "\t" $3; exit}')
        if [ -n "$_meta" ]; then
          local _et="${_meta%%$'\t'*}"
          local _ed="${_meta#*$'\t'}"
          [ -n "$_et" ] && oc_title="$_et"
          [ -n "$_ed" ] && oc_dir="$_ed"
        fi
      fi
      if [[ "$_title" == "OC |"* ]] && [ "$oc_title" = '(detected)' ]; then
        oc_title="${_title#OC | }"
      fi
      if [ "$fmt" -ge 2 ] 2>/dev/null; then
        oc_sid=$(_tmux_af_escape "$oc_sid")
        oc_title=$(_tmux_af_escape "$oc_title")
        oc_dir=$(_tmux_af_escape "$oc_dir")
      fi
      echo "${_widx}|${_pidx}|${oc_sid}|${oc_title}|${oc_dir}" >> "$file"
    fi
  done
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
      local qdir
      qdir=$(printf '%q' "$oc_dir")
      tmux send-keys -t "$pane_target" "cd -- $qdir" Enter
    fi
    # Echo OC session info directly into the pane so user sees it on attach
    tmux send-keys -t "$pane_target" " echo ''" Enter
    tmux send-keys -t "$pane_target" " echo '  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'" Enter
    tmux send-keys -t "$pane_target" " echo '  [ARCHIVED OPENCODE]'" Enter
    tmux send-keys -t "$pane_target" " echo '  TITLE : ${oc_title}'" Enter
    tmux send-keys -t "$pane_target" " echo '  SID   : ${oc_sid}'" Enter
    tmux send-keys -t "$pane_target" " echo '  RUN   : opencode -s ${oc_sid}'" Enter
    tmux send-keys -t "$pane_target" " echo '  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'" Enter
    tmux send-keys -t "$pane_target" " echo ''" Enter
    _TMUX_RESTORE_RUNNING_CMDS="${_TMUX_RESTORE_RUNNING_CMDS}  w${widx}.${pidx}: \033[33mopencode\033[0m (\"\033[36m${oc_title}\033[0m\")\n           → cd ${oc_dir} && opencode -s ${oc_sid}\n"
    local esc_sid esc_dir esc_title
    esc_sid=$(_tmux_af_escape "$oc_sid")
    esc_dir=$(_tmux_af_escape "$oc_dir")
    esc_title=$(_tmux_af_escape "$oc_title")
    _TMUX_RESTORE_OC_PANES="${_TMUX_RESTORE_OC_PANES}${pane_target}|${esc_sid}|${esc_dir}|${esc_title}\n"
  else
    # No SID — still show info so user knows this was an OC pane
    tmux send-keys -t "$pane_target" " echo ''" Enter
    tmux send-keys -t "$pane_target" " echo '  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'" Enter
    tmux send-keys -t "$pane_target" " echo '  [ARCHIVED OPENCODE]'" Enter
    tmux send-keys -t "$pane_target" " echo '  TITLE : ${oc_title}'" Enter
    tmux send-keys -t "$pane_target" " echo '  SID   : (없음 - 새 세션으로 시작하세요)'" Enter
    tmux send-keys -t "$pane_target" " echo '  RUN   : opencode -c'" Enter
    tmux send-keys -t "$pane_target" " echo '  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'" Enter
    tmux send-keys -t "$pane_target" " echo ''" Enter
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
      local qdir
      qdir=$(printf '%q' "$dir")
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
      local qdir
      qdir=$(printf '%q' "$dir")
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
