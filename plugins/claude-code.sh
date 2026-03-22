# tmux-manager — Claude Code plugin
# Provides CC session capture, restore, and restart functionality.
# If this plugin is not loaded, core archive/restore still works — CC features are skipped.

if ! typeset -f _tmux_af_format_version > /dev/null 2>&1; then
  source "$TMUX_MANAGER_DIR/lib/archive_format.sh" 2>/dev/null
fi

# ── Detection helpers ─────────────────────────────────────────────────────

# Check if a pane title belongs to Claude Code.
# Claude Code uses ✳ (idle) and Braille dot spinners (⠁⠂⠄⠈⠐⠠⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏) as prefix.
_tmux_cc_is_pane_title() {
  local title="$1"
  [[ "$title" == '✳ '* ]] && return 0
  [[ "$title" == [⠁⠂⠄⠈⠐⠠⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]' '* ]] && return 0
  return 1
}

# Extract the human-readable title by stripping the prefix character + space.
_tmux_cc_extract_title() {
  local title="$1"
  # In zsh, ? matches a single multibyte character
  echo "${title#? }"
}

# Detect Claude Code session ID from ~/.claude/sessions/<pid>.json
_tmux_cc_detect_sid_from_pid() {
  local claude_pid="$1"
  [ -z "$claude_pid" ] && return 1
  local session_file="$HOME/.claude/sessions/${claude_pid}.json"
  [ -f "$session_file" ] || return 1
  python3 -c "
import json
with open('$session_file') as f:
    d = json.load(f)
    sid = d.get('sessionId', '')
    if sid: print(sid)
" 2>/dev/null || return 1
}

# Detect session ID from sessions-index.json by cwd
_tmux_cc_detect_sid_from_index() {
  local pane_cwd="$1"
  [ -z "$pane_cwd" ] && return 1

  # Convert cwd to project path: /Users/foo/bar → -Users-foo-bar
  local proj_path
  proj_path="${pane_cwd//\//-}"
  local index_file="$HOME/.claude/projects/${proj_path}/sessions-index.json"
  [ -f "$index_file" ] || return 1

  python3 -c "
import json
with open('$index_file') as f:
    d = json.load(f)
    entries = d.get('entries', d if isinstance(d, list) else [])
    best = None
    for e in entries:
        if not best or e.get('modified','') > best.get('modified',''):
            best = e
    if best and best.get('sessionId'):
        print(best['sessionId'])
" 2>/dev/null || return 1
}

# Detect session ID by scanning ~/.claude/sessions/*.json matching cwd
_tmux_cc_detect_sid_from_sessions() {
  local pane_cwd="$1"
  [ -z "$pane_cwd" ] && return 1
  local sessions_dir="$HOME/.claude/sessions"
  [ -d "$sessions_dir" ] || return 1

  python3 -c "
import json, glob, os
cwd = '''${pane_cwd}'''
best_sid, best_time = '', 0
for f in glob.glob(os.path.join(os.path.expanduser('~'), '.claude', 'sessions', '*.json')):
    try:
        with open(f) as fh:
            d = json.load(fh)
            if d.get('cwd') == cwd:
                t = d.get('startedAt', 0)
                if t > best_time:
                    best_time = t
                    best_sid = d.get('sessionId', '')
    except: pass
if best_sid: print(best_sid)
" 2>/dev/null || return 1
}

# Find claude CLI PID in process subtree of a pane
_tmux_cc_find_claude_pid() {
  local pane_pid="$1" cc_ps_cache="$2"
  [ -z "$pane_pid" ] && return 1

  if [ -n "$cc_ps_cache" ]; then
    local found_pid
    found_pid=$(echo "$cc_ps_cache" | awk -F'\t' -v p="$pane_pid" '$1+0==p+0 && $2=="CC_RUNNING" {print $3; exit}')
    [ -n "$found_pid" ] && echo "$found_pid" && return 0
  fi
  return 1
}

# ── Capture ─────────────────────────────────────────────────────────────────
# Append Claude Code session data to the archive file's ---CLAUDE-CODE--- section.
# Called from lib/core.sh during `tmux-archive save`.
_tmux_cc_capture_session() {
  local session="$1" file="$2" base="$3"
  command -v claude &>/dev/null || return 0
  # Exclude if 'claude' resolves to Claude.app
  local claude_path
  claude_path=$(command -v claude 2>/dev/null)
  [[ "$claude_path" == *"Claude.app"* ]] && return 0

  local fmt
  fmt=$(_tmux_af_format_version "$file")

  local _cc_ps="${_TMUX_CC_PS_CACHE_DATA:-}"
  if [ -z "$_cc_ps" ] && [ -n "${_TMUX_CC_PS_CACHE:-}" ] && [ -f "$_TMUX_CC_PS_CACHE" ]; then
    _cc_ps=$(cat "$_TMUX_CC_PS_CACHE")
  fi
  if [ -z "$_cc_ps" ]; then
    local _all_pane_pids
    _all_pane_pids=$(tmux list-panes -t "$session" -F '#{pane_pid}' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    _cc_ps=$(ps -axo pid=,ppid=,args= 2>/dev/null | awk -v roots="$_all_pane_pids" '
      BEGIN { split(roots, r, ","); for(i in r) root[r[i]+0]=1 }
      { pid=$1+0; ppid=$2+0; $1=""; $2=""; a[pid]=$0; p[pid]=ppid }
      END {
        for(rt in root) {
          queue[1]=rt; head=1; tail=1; found=0; fpid=0
          while(head<=tail && !found) {
            for(pid in p) {
              if(p[pid]==queue[head]) {
                tail++; queue[tail]=pid
                if(a[pid] ~ /[[:space:]]claude([[:space:]]|$)/ && a[pid] !~ /Claude\.app/) { found=1; fpid=pid }
              }
            }
            head++
          }
          delete queue
          if(found) print rt "\tCC_RUNNING\t" fpid
        }
      }' 2>/dev/null)
  fi

  local pane_ids
  pane_ids=$(tmux list-panes -t "$session" -F '#{pane_id}' 2>/dev/null)

  echo "$pane_ids" | while read -r _pid; do
    [ -z "$_pid" ] && continue
    local _widx _pidx _title _ppath
    _widx=$(tmux display-message -p -t "$_pid" '#{window_index}' 2>/dev/null)
    _pidx=$(tmux display-message -p -t "$_pid" '#{pane_index}' 2>/dev/null)
    _title=$(tmux display-message -p -t "$_pid" '#{pane_title}' 2>/dev/null)
    _ppath=$(tmux display-message -p -t "$_pid" '#{pane_current_path}' 2>/dev/null)

    local is_cc_running=false
    local pane_pid claude_pid
    pane_pid=$(tmux display-message -p -t "$_pid" '#{pane_pid}' 2>/dev/null)

    # Check process cache
    if [ -n "$pane_pid" ] && [ -n "$_cc_ps" ]; then
      claude_pid=$(echo "$_cc_ps" | awk -F'\t' -v p="$pane_pid" '$1+0==p+0 {print $3; exit}')
      [ -n "$claude_pid" ] && is_cc_running=true
    fi

    # Check pane title
    _tmux_cc_is_pane_title "$_title" && is_cc_running=true

    if [ "$is_cc_running" = true ]; then
      local cc_sid=''

      # Method 1: PID file
      if [ -n "$claude_pid" ]; then
        cc_sid=$(_tmux_cc_detect_sid_from_pid "$claude_pid" 2>/dev/null) || true
      fi

      # Method 2: sessions-index.json fallback
      if [ -z "$cc_sid" ]; then
        cc_sid=$(_tmux_cc_detect_sid_from_index "$_ppath" 2>/dev/null) || true
      fi

      # Method 3: scan ~/.claude/sessions/*.json by cwd
      if [ -z "$cc_sid" ]; then
        cc_sid=$(_tmux_cc_detect_sid_from_sessions "$_ppath" 2>/dev/null) || true
      fi

      local cc_title='(detected)'
      if _tmux_cc_is_pane_title "$_title"; then
        cc_title=$(_tmux_cc_extract_title "$_title")
      fi
      # If title is just "Claude Code", try sessions-index for a better title
      if [ "$cc_title" = 'Claude Code' ] || [ "$cc_title" = '(detected)' ]; then
        if [ -n "$cc_sid" ]; then
          local proj_path
          proj_path="${_ppath//\//-}"
          local idx_file="$HOME/.claude/projects/${proj_path}/sessions-index.json"
          if [ -f "$idx_file" ]; then
            local idx_title
            idx_title=$(python3 -c "
import json
with open('$idx_file') as f:
    d = json.load(f)
    entries = d.get('entries', d if isinstance(d, list) else [])
    for e in entries:
        if e.get('sessionId') == '$cc_sid':
            s = e.get('summary') or e.get('firstPrompt','')
            if s: print(s[:60])
            break
" 2>/dev/null)
            [ -n "$idx_title" ] && cc_title="$idx_title"
          fi
        fi
      fi

      local cc_dir="$_ppath"
      if [ "$fmt" -ge 2 ] 2>/dev/null; then
        cc_sid=$(_tmux_af_escape "$cc_sid")
        cc_title=$(_tmux_af_escape "$cc_title")
        cc_dir=$(_tmux_af_escape "$cc_dir")
      fi
      echo "${_widx}|${_pidx}|${cc_sid}|${cc_title}|${cc_dir}" >> "$file"
    fi
  done
}

# ── Restore metadata ────────────────────────────────────────────────────────
# Set @cc_saved_* tmux options from archive data.
_tmux_cc_restore_metadata() {
  local file="$1" session_name="$2"
  local fmt
  fmt=$(_tmux_af_format_version "$file")
  local cc_saved_lines
  cc_saved_lines=$(_tmux_af_section_lines "$file" '---CLAUDE-CODE---' '---CMUX---')
  local cc_saved_count=0 cc_saved_sid_missing=0
  local cc_saved_titles='' cc_saved_sids=''
  local widx pidx sid title dir
  while IFS='|' read -r widx pidx sid title dir; do
    [ -z "$widx" ] && continue
    sid=$(_tmux_af_decode_field_if_needed "$fmt" "$sid")
    title=$(_tmux_af_decode_field_if_needed "$fmt" "$title")
    cc_saved_count=$((cc_saved_count + 1))
    if [ -z "$sid" ]; then
      cc_saved_sid_missing=$((cc_saved_sid_missing + 1))
    else
      if [ -z "$cc_saved_sids" ]; then cc_saved_sids="$sid"; else cc_saved_sids="${cc_saved_sids}$'\x1f'${sid}"; fi
    fi
    if [ -n "$title" ]; then
      if [ -z "$cc_saved_titles" ]; then cc_saved_titles="$title"; else cc_saved_titles="${cc_saved_titles}$'\x1f'${title}"; fi
    fi
  done <<< "$cc_saved_lines"

  if [ "$cc_saved_count" -gt 0 ] 2>/dev/null; then
    tmux set-option -t "$session_name" @cc_saved_count "$cc_saved_count" 2>/dev/null
    tmux set-option -t "$session_name" @cc_saved_titles "$cc_saved_titles" 2>/dev/null
    tmux set-option -t "$session_name" @cc_saved_sids "$cc_saved_sids" 2>/dev/null
    tmux set-option -t "$session_name" @cc_saved_sid_missing "$cc_saved_sid_missing" 2>/dev/null
  else
    tmux set-option -u -t "$session_name" @cc_saved_count 2>/dev/null
    tmux set-option -u -t "$session_name" @cc_saved_titles 2>/dev/null
    tmux set-option -u -t "$session_name" @cc_saved_sids 2>/dev/null
    tmux set-option -u -t "$session_name" @cc_saved_sid_missing 2>/dev/null
  fi
}

# ── Pane restore handler ────────────────────────────────────────────────────
_tmux_cc_setup_restored_pane() {
  local target="$1" widx="$2" pidx="$3" ptitle="$4" ppath="$5" cc_line="$6" pane_target="$7"
  [ -z "$pane_target" ] && pane_target="${target}.${pidx}"
  local fmt="${_TMUX_RESTORE_ARCHIVE_FMT:-1}"

  local cc_title
  if _tmux_cc_is_pane_title "$ptitle"; then
    cc_title=$(_tmux_cc_extract_title "$ptitle")
  else
    cc_title="$ptitle"
  fi
  if [ -z "$cc_title" ] || [ "$cc_title" = "$ptitle" ]; then
    cc_title=$(echo "$cc_line" | cut -d'|' -f4)
  fi
  cc_title=$(_tmux_af_decode_field_if_needed "$fmt" "$cc_title")
  [ -z "$cc_title" ] && cc_title='(detected)'

  tmux select-pane -t "$pane_target" -T "✳ ${cc_title}" 2>/dev/null

  local cc_sid
  cc_sid=$(echo "$cc_line" | cut -d'|' -f3)
  cc_sid=$(_tmux_af_decode_field_if_needed "$fmt" "$cc_sid")
  local cc_dir
  cc_dir=$(echo "$cc_line" | cut -d'|' -f5)
  cc_dir=$(_tmux_af_decode_field_if_needed "$fmt" "$cc_dir")
  [ -z "$cc_dir" ] && cc_dir="$ppath"

  if [ -n "$cc_sid" ]; then
    if [ -n "$cc_dir" ] && [ "$cc_dir" != "$ppath" ]; then
      local qdir
      qdir=$(printf '%q' "$cc_dir")
      tmux send-keys -t "$pane_target" "cd -- $qdir" Enter
    fi
    tmux send-keys -t "$pane_target" " echo ''" Enter
    tmux send-keys -t "$pane_target" " echo '  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'" Enter
    tmux send-keys -t "$pane_target" " echo '  [ARCHIVED CLAUDE-CODE]'" Enter
    tmux send-keys -t "$pane_target" " echo '  TITLE : ${cc_title}'" Enter
    tmux send-keys -t "$pane_target" " echo '  SID   : ${cc_sid}'" Enter
    tmux send-keys -t "$pane_target" " echo '  RUN   : claude --resume ${cc_sid}'" Enter
    tmux send-keys -t "$pane_target" " echo '  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'" Enter
    tmux send-keys -t "$pane_target" " echo ''" Enter
    _TMUX_RESTORE_RUNNING_CMDS="${_TMUX_RESTORE_RUNNING_CMDS}  w${widx}.${pidx}: \033[35mclaude-code\033[0m (\"\033[36m${cc_title}\033[0m\")\n           → cd ${cc_dir} && claude --resume ${cc_sid}\n"
    local esc_sid esc_dir esc_title
    esc_sid=$(_tmux_af_escape "$cc_sid")
    esc_dir=$(_tmux_af_escape "$cc_dir")
    esc_title=$(_tmux_af_escape "$cc_title")
    _TMUX_RESTORE_CC_PANES="${_TMUX_RESTORE_CC_PANES}${pane_target}|${esc_sid}|${esc_dir}|${esc_title}\n"
  else
    tmux send-keys -t "$pane_target" " echo ''" Enter
    tmux send-keys -t "$pane_target" " echo '  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'" Enter
    tmux send-keys -t "$pane_target" " echo '  [ARCHIVED CLAUDE-CODE]'" Enter
    tmux send-keys -t "$pane_target" " echo '  TITLE : ${cc_title}'" Enter
    tmux send-keys -t "$pane_target" " echo '  SID   : (없음 - 새 세션으로 시작하세요)'" Enter
    tmux send-keys -t "$pane_target" " echo '  RUN   : claude'" Enter
    tmux send-keys -t "$pane_target" " echo '  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'" Enter
    tmux send-keys -t "$pane_target" " echo ''" Enter
    _TMUX_RESTORE_RUNNING_CMDS="${_TMUX_RESTORE_RUNNING_CMDS}  w${widx}.${pidx}: \033[35mclaude-code\033[0m (\"${cc_title}\")\n           → claude\n"
    local esc_ppath esc_title
    esc_ppath=$(_tmux_af_escape "$ppath")
    esc_title=$(_tmux_af_escape "$cc_title")
    _TMUX_RESTORE_CC_PANES="${_TMUX_RESTORE_CC_PANES}${pane_target}||${esc_ppath}|${esc_title}\n"
  fi
}

# ── CC restart prompt ───────────────────────────────────────────────────────
_tmux_cc_prompt_restart() {
  local session_name="$1" cc_panes="$2"
  [ -z "$cc_panes" ] && return 0
  [[ -t 0 ]] || return 0

  echo -n "\033[35mclaude-code 재실행할까요? (y/N): \033[0m"
  local cc_confirm
  read -r cc_confirm

  if [ "$cc_confirm" = 'y' ] || [ "$cc_confirm" = 'Y' ]; then
    local cc_script
    cc_script=$(mktemp -t tmux_cc)
    echo '#!/bin/zsh' > "$cc_script"
    echo 'sleep 0.8' >> "$cc_script"
    echo -e "$cc_panes" | while IFS='|' read -r tgt sid dir title; do
      [ -z "$tgt" ] && continue
      sid=$(_tmux_af_unescape "$sid")
      dir=$(_tmux_af_unescape "$dir")
      [ -z "$dir" ] && dir='/'
      local qdir
      qdir=$(printf '%q' "$dir")
      if [ -n "$sid" ]; then
        echo "tmux send-keys -t '$tgt' \"cd -- $qdir\" Enter" >> "$cc_script"
        echo "sleep 0.3" >> "$cc_script"
        echo "tmux send-keys -t '$tgt' 'claude --resume $sid' Enter" >> "$cc_script"
      else
        echo "tmux send-keys -t '$tgt' \"cd -- $qdir\" Enter" >> "$cc_script"
        echo "sleep 0.3" >> "$cc_script"
        echo "tmux send-keys -t '$tgt' 'claude' Enter" >> "$cc_script"
      fi
    done
    echo "rm -f '$cc_script'" >> "$cc_script"
    echo "tmux set-hook -u -t '$session_name' client-attached" >> "$cc_script"
    echo "tmux set-hook -u -t '$session_name' client-session-changed" >> "$cc_script"
    chmod +x "$cc_script"
    tmux set-hook -t "$session_name" client-attached "run-shell '$cc_script'"
    tmux set-hook -t "$session_name" client-session-changed "run-shell '$cc_script'"
    echo "\033[32m✓ claude-code: attach 후 자동 실행 예약\033[0m"
  else
    local info_script
    info_script=$(mktemp -t tmux_cc_info)
    echo '#!/bin/zsh' > "$info_script"
    echo 'sleep 0.8' >> "$info_script"
    echo -e "$cc_panes" | while IFS='|' read -r tgt sid dir title; do
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
      echo "tmux send-keys -t '$tgt' \"echo '[ARCHIVED CLAUDE-CODE]'\" Enter" >> "$info_script"
      echo "tmux send-keys -t '$tgt' \"echo 'TITLE: ${safe_title}'\" Enter" >> "$info_script"
      if [ -n "$sid" ]; then
        echo "tmux send-keys -t '$tgt' \"echo 'SID: ${sid}'\" Enter" >> "$info_script"
        echo "tmux send-keys -t '$tgt' \"echo 'DIR: ${safe_dir}'\" Enter" >> "$info_script"
        echo "tmux send-keys -t '$tgt' \"echo 'RUN: claude --resume ${sid}'\" Enter" >> "$info_script"
      else
        echo "tmux send-keys -t '$tgt' \"echo 'DIR: ${safe_dir}'\" Enter" >> "$info_script"
        echo "tmux send-keys -t '$tgt' \"echo 'RUN: claude'\" Enter" >> "$info_script"
      fi
    done
    echo "rm -f '$info_script'" >> "$info_script"
    echo "tmux set-hook -u -t '$session_name' client-attached" >> "$info_script"
    echo "tmux set-hook -u -t '$session_name' client-session-changed" >> "$info_script"
    chmod +x "$info_script"
    tmux set-hook -t "$session_name" client-attached "run-shell '$info_script'"
    tmux set-hook -t "$session_name" client-session-changed "run-shell '$info_script'"
    echo "\033[90mℹ attach 후 Claude Code 복원 정보 표시\033[0m"
  fi
}
