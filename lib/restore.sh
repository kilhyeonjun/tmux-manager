if ! typeset -f _tmux_af_format_version > /dev/null 2>&1; then
  source "$TMUX_MANAGER_DIR/lib/archive_format.sh" 2>/dev/null
fi
if ! typeset -f _tmux_archive_with_lock > /dev/null 2>&1; then
  source "$TMUX_MANAGER_DIR/lib/utils.sh" 2>/dev/null
fi

_tmux_archive_restore() {
  _tmux_archive_with_lock 60 _tmux_archive_restore_unlocked "$@"
}

_tmux_archive_restore_unlocked() {
  setopt local_options typeset_silent
  local file="$1"
  if [ -z "$file" ]; then
    if typeset -f _tmux_archive_meta_bulk > /dev/null 2>&1; then
      file=$(_tmux_archive_meta_bulk | sort -t'|' -k4 -r | while IFS='|' read -r f uuid name date is_auto wins oc_count sid_missing oc_title oc_sid; do
        printf '%s|%s  %s  %sw\n' "$f" "$name" "$date" "$wins"
      done | fzf --height=50% --reverse --header='복원할 아카이브 선택' -d'|' --with-nth=2 | cut -d'|' -f1)
    else
      file=$(ls -1 "$TMUX_ARCHIVE_DIR"/*.archive 2>/dev/null | while read -r f; do
        local name date wins
        name=$(_tmux_af_header_get "$f" SESSION_NAME)
        date=$(_tmux_af_header_get "$f" ARCHIVED_AT)
        wins=$(_tmux_af_section_lines "$f" '---WINDOWS---' '---PANES---' | grep -c '[^[:space:]]' 2>/dev/null)
        printf '%s|%s  %s  %sw\n' "$f" "$name" "$date" "$wins"
      done | fzf --height=50% --reverse --header='복원할 아카이브 선택' -d'|' --with-nth=2 | cut -d'|' -f1)
    fi
    [ -z "$file" ] && return
  fi

  if [ ! -f "$file" ]; then
    echo "\033[31m파일 없음: $file\033[0m"
    return 1
  fi

  local fmt
  fmt=$(_tmux_af_format_version "$file")
  if [ "$fmt" -ge 2 ] 2>/dev/null; then
    _tmux_af_require_python3 'FORMAT_VERSION=2 아카이브 복원' || return 1
  fi
  local session_name
  session_name=$(_tmux_af_header_get "$file" SESSION_NAME)
  if [ -z "$session_name" ]; then
    echo "\033[31m복원 실패: SESSION_NAME 누락\033[0m"
    return 1
  fi

  if tmux has-session -t "=$session_name" 2>/dev/null; then
    echo "\033[31m세션 '$session_name' 이미 존재\033[0m"
    return 1
  fi

  local windows_raw panes_raw oc_section
  windows_raw=$(_tmux_af_section_lines "$file" '---WINDOWS---' '---PANES---')
  panes_raw=$(_tmux_af_section_lines "$file" '---PANES---' '---OPENCODE---')
  oc_section=$(_tmux_af_section_lines "$file" '---OPENCODE---' '---CLAUDE-CODE---')
  local cc_section
  cc_section=$(_tmux_af_section_lines "$file" '---CLAUDE-CODE---' '---CMUX---')
  if [ -z "$(echo "$panes_raw" | tr -d '[:space:]')" ]; then
    panes_raw=$(_tmux_af_section_lines "$file" '---PANES---' '')
  fi

  local windows_sorted panes_sorted
  windows_sorted=$(echo "$windows_raw" | awk -F'|' 'NF>=3 && $1 ~ /^[0-9]+$/ {print}' | sort -t'|' -k1,1n)
  panes_sorted=$(echo "$panes_raw" | awk -F'|' 'NF>=6 && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ {print}' | sort -t'|' -k2,2n -k3,3n)

  if [ -z "$(echo "$windows_sorted" | tr -d '[:space:]')" ]; then
    echo "\033[31m복원 실패: WINDOWS 섹션 없음\033[0m"
    return 1
  fi
  if [ -z "$(echo "$panes_sorted" | tr -d '[:space:]')" ]; then
    echo "\033[31m복원 실패: PANES 섹션 없음\033[0m"
    return 1
  fi

  local first_row
  first_row=$(echo "$windows_sorted" | head -1)
  local first_idx first_name first_layout
  IFS='|' read -r first_idx first_name first_layout <<< "$first_row"
  first_name=$(_tmux_af_decode_field_if_needed "$fmt" "$first_name")
  first_layout=$(_tmux_af_decode_field_if_needed "$fmt" "$first_layout")

  local _restore_w=200 _restore_h=200
  local _raw_layout
  while IFS='|' read -r _ _ _raw_layout; do
    [ -z "$_raw_layout" ] && continue
    _raw_layout=$(_tmux_af_decode_field_if_needed "$fmt" "$_raw_layout")
    local _lw _lh
    _lw=$(echo "$_raw_layout" | grep -oE '^[0-9a-fA-F]+,[0-9]+x[0-9]+' | head -1 | sed 's/.*,//;s/x.*//')
    _lh=$(echo "$_raw_layout" | grep -oE '^[0-9a-fA-F]+,[0-9]+x[0-9]+' | head -1 | sed 's/.*x//;s/,.*//')
    [ -n "$_lw" ] && [ "$_lw" -gt "$_restore_w" ] 2>/dev/null && _restore_w="$_lw"
    [ -n "$_lh" ] && [ "$_lh" -gt "$_restore_h" ] 2>/dev/null && _restore_h="$_lh"
  done <<< "$windows_sorted"

  tmux new-session -d -s "$session_name" -x "$_restore_w" -y "$_restore_h" || {
    echo "\033[31m복원 실패: 세션 생성 실패\033[0m"
    if typeset -f _tmux_cmux_notify_restore_fail > /dev/null 2>&1; then
      _tmux_cmux_notify_restore_fail "세션 생성 실패: $session_name"
    fi
    return 1
  }
  local created_session=1

  tmux rename-window -t "$session_name" "$first_name" 2>/dev/null || \
    echo "\033[33m⚠ 첫 윈도우 이름 적용 실패 (기본 이름 유지)\033[0m"

  local current_idx
  current_idx=$(tmux list-windows -t "$session_name" -F '#{window_index}' 2>/dev/null | head -1)
  if [ -n "$current_idx" ] && [ "$current_idx" != "$first_idx" ]; then
    tmux move-window -s "${session_name}:${current_idx}" -t "${session_name}:${first_idx}" 2>/dev/null || \
      echo "\033[33m⚠ 윈도우 인덱스 보정 실패 (기본 인덱스 유지)\033[0m"
  fi

  local row idx wname layout
  local row_num=0
  while IFS='|' read -r idx wname layout; do
    [ -z "$idx" ] && continue
    row_num=$((row_num + 1))
    [ "$row_num" -eq 1 ] && continue
    wname=$(_tmux_af_decode_field_if_needed "$fmt" "$wname")
    tmux new-window -d -t "${session_name}:${idx}" -n "$wname" 2>/dev/null || {
      echo "\033[31m복원 실패: 윈도우 생성 실패 (${idx})\033[0m"
      [ "$created_session" -eq 1 ] && tmux kill-session -t "=$session_name" 2>/dev/null
      return 1
    }
  done <<< "$windows_sorted"

  local archived_uuid
  archived_uuid=$(_tmux_af_header_get "$file" SESSION_UUID)
  if [ -n "$archived_uuid" ]; then
    tmux set-option -t "$session_name" @archive_uuid "$archived_uuid" 2>/dev/null
  else
    _tmux_ensure_uuid "$session_name" >/dev/null
  fi

  if typeset -f _tmux_oc_restore_metadata > /dev/null 2>&1; then
    _tmux_oc_restore_metadata "$file" "$session_name"
  fi
  if typeset -f _tmux_cc_restore_metadata > /dev/null 2>&1; then
    _tmux_cc_restore_metadata "$file" "$session_name"
  fi
  if typeset -f _tmux_cmux_restore_metadata > /dev/null 2>&1; then
    _tmux_cmux_restore_metadata "$file" "$session_name"
  fi

  local base="${file%.archive}"
  local _TMUX_RESTORE_RUNNING_CMDS=''
  local _TMUX_RESTORE_OC_PANES=''
  local _TMUX_RESTORE_CC_PANES=''
  local _TMUX_RESTORE_ARCHIVE_FMT="$fmt"
  local running_cmds=''

  local win_idxes
  win_idxes=$(echo "$windows_sorted" | cut -d'|' -f1)
  local widx
  while IFS= read -r widx; do
    [ -z "$widx" ] && continue
    local window_panes
    window_panes=$(echo "$panes_sorted" | awk -F'|' -v w="$widx" '$2==w {print}')
    [ -z "$(echo "$window_panes" | tr -d '[:space:]')" ] && continue

    local pane_seq=0
    local sn p_widx pidx ppath pcmd ptitle
    while IFS='|' read -r sn p_widx pidx ppath pcmd ptitle; do
      [ -z "$p_widx" ] && continue
      pane_seq=$((pane_seq + 1))
      ppath=$(_tmux_af_decode_field_if_needed "$fmt" "$ppath")
      if [ "$pane_seq" -gt 1 ]; then
        tmux split-window -d -t "${session_name}:${widx}" -c "$ppath" 2>/dev/null || {
          echo "\033[33m⚠ pane split 실패 (w${widx}.p${pidx}) — 공간 부족, 건너뜀\033[0m"
          continue
        }
      fi
    done <<< "$window_panes"

    local actual_panes
    actual_panes=$(tmux list-panes -t "${session_name}:${widx}" -F '#{pane_index}|#{pane_id}' 2>/dev/null | sort -t'|' -k1,1n)
    typeset -a pane_ids
    while IFS='|' read -r _pidx _pid; do
      [ -z "$_pid" ] && continue
      pane_ids+=("$_pid")
    done <<< "$actual_panes"

    pane_seq=0
    while IFS='|' read -r sn p_widx pidx ppath pcmd ptitle; do
      [ -z "$p_widx" ] && continue
      pane_seq=$((pane_seq + 1))
      local pane_target="${pane_ids[$pane_seq]}"
      [ -z "$pane_target" ] && continue

      sn=$(_tmux_af_decode_field_if_needed "$fmt" "$sn")
      ppath=$(_tmux_af_decode_field_if_needed "$fmt" "$ppath")
      pcmd=$(_tmux_af_decode_field_if_needed "$fmt" "$pcmd")
      ptitle=$(_tmux_af_decode_field_if_needed "$fmt" "$ptitle")

      _tmux_wait_for_prompt "$pane_target"

      local pane_file="${base}_w${p_widx}_p${pidx}.pane"
      if [ -f "$pane_file" ] && grep -q '[^[:space:]]' "$pane_file"; then
        local qpane="${(q)pane_file}"
        local _trimmed=$(mktemp)
        awk '{b[NR]=$0}/[^[:space:]]/{l=NR}END{for(i=1;i<=l;i++)print b[i]}' "$pane_file" > "$_trimmed"
        tmux send-keys -t "$pane_target" " cat ${(q)_trimmed}; rm -f ${(q)_trimmed}" Enter
        tmux set-option -p -t "$pane_target" @archive_source_file "$pane_file" 2>/dev/null
      fi
      local qpath="${(q)ppath}"
      tmux send-keys -t "$pane_target" "cd -- $qpath" Enter

      local oc_line=''
      oc_line=$(echo "$oc_section" | awk -F'|' -v w="$p_widx" -v p="$pidx" '$1==w && $2==p {print; exit}')
      local is_oc=false
      [[ "$ptitle" == 'OC |'* ]] && is_oc=true
      [[ "$ptitle" == 'OpenCode' ]] && is_oc=true
      [ -n "$oc_line" ] && is_oc=true

      local cc_line=''
      cc_line=$(echo "$cc_section" | awk -F'|' -v w="$p_widx" -v p="$pidx" '$1==w && $2==p {print; exit}')
      local is_cc=false
      [[ "$ptitle" == '✳ '* ]] && is_cc=true
      [[ "$ptitle" == [⠁⠂⠄⠈⠐⠠⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]' '* ]] && is_cc=true
      [ -n "$cc_line" ] && is_cc=true

      if [ "$is_oc" = true ]; then
        if typeset -f _tmux_oc_setup_restored_pane > /dev/null 2>&1; then
          _tmux_oc_setup_restored_pane "${session_name}:${widx}" "$p_widx" "$pidx" "$ptitle" "$ppath" "$oc_line" "$pane_target"
        fi
      elif [ "$is_cc" = true ]; then
        if typeset -f _tmux_cc_setup_restored_pane > /dev/null 2>&1; then
          _tmux_cc_setup_restored_pane "${session_name}:${widx}" "$p_widx" "$pidx" "$ptitle" "$ppath" "$cc_line" "$pane_target"
        fi
      elif [ -n "$pcmd" ] && [ "$pcmd" != 'zsh' ] && [ "$pcmd" != 'bash' ]; then
        running_cmds="${running_cmds}  w${p_widx}.${pidx}: \033[33m${pcmd}\033[0m (${ppath})\n"
      fi
    done <<< "$window_panes"
  done <<< "$win_idxes"

  while IFS='|' read -r idx wname layout; do
    [ -z "$idx" ] && continue
    layout=$(_tmux_af_decode_field_if_needed "$fmt" "$layout")
    tmux select-layout -t "${session_name}:${idx}" "$layout" 2>/dev/null
  done <<< "$windows_sorted"

  running_cmds="${_TMUX_RESTORE_RUNNING_CMDS}${running_cmds}"
  local oc_panes="$_TMUX_RESTORE_OC_PANES"
  local cc_panes="$_TMUX_RESTORE_CC_PANES"

  echo "\033[32m✓ 복원 완료: $session_name\033[0m"
  if typeset -f _tmux_cmux_notify_restore > /dev/null 2>&1; then
    _tmux_cmux_notify_restore "$session_name"
  fi
  if typeset -f _tmux_cmux_rename_tab > /dev/null 2>&1; then
    local _restore_cwd
    _restore_cwd=$(tmux display-message -t "$session_name" -p '#{pane_current_path}' 2>/dev/null)
    local _restore_label
    _restore_label=$(_tmux_cmux_workspace_label "$session_name" "$_restore_cwd")
    _tmux_cmux_rename_tab "$_restore_label"
  fi
  if [ -n "$running_cmds" ]; then
    echo "\033[33m⚠ 다음 프로세스는 수동 재시작 필요:\033[0m"
    echo -e "$running_cmds"
  fi

  if [ -n "$oc_panes" ] && [[ -t 0 ]] && typeset -f _tmux_oc_prompt_restart > /dev/null 2>&1; then
    _tmux_oc_prompt_restart "$session_name" "$oc_panes"
  fi
  if [ -n "$cc_panes" ] && [[ -t 0 ]] && typeset -f _tmux_cc_prompt_restart > /dev/null 2>&1; then
    _tmux_cc_prompt_restart "$session_name" "$cc_panes"
  fi
}
