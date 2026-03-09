# tmux-manager — core archive operations, groups, fzf manager UI
# Sourced by init.sh

if ! typeset -f _tmux_af_format_version > /dev/null 2>&1; then
  source "$TMUX_MANAGER_DIR/lib/archive_format.sh" 2>/dev/null
fi
if ! typeset -f _tmux_archive_with_lock > /dev/null 2>&1; then
  source "$TMUX_MANAGER_DIR/lib/utils.sh" 2>/dev/null
fi

# ── UUID helper ─────────────────────────────────────────────────────────────
_tmux_ensure_uuid() {
  local session="${1:-$(tmux display-message -p '#{session_name}' 2>/dev/null)}"
  [ -z "$session" ] && return 1
  local uuid=$(tmux show-option -t "$session" -qv @archive_uuid 2>/dev/null)
  if [ -z "$uuid" ]; then
    uuid=$(uuidgen)
    tmux set-option -t "$session" @archive_uuid "$uuid" 2>/dev/null
  fi
  echo "$uuid"
}

# ── Single archive file + .pane deletion ────────────────────────────────────
_tmux_archive_delete_file_unlocked() {
  local file="$1"
  [ ! -f "$file" ] && return 1
  local name=$(_tmux_af_header_get "$file" SESSION_NAME)
  local fbase="${file%.archive}"
  rm -f "${fbase}"_w*_p*.pane 2>/dev/null
  rm -f "$file" && echo "\033[31m✓ 삭제: $name\033[0m"
}

_tmux_archive_delete_file() {
  _tmux_archive_with_lock 10 _tmux_archive_delete_file_unlocked "$1"
}

# ── Archive metadata parser ─────────────────────────────────────────────────
_tmux_archive_meta() {
  local file="$1"
  [ ! -f "$file" ] && return 1
  local parsed
  parsed=$(awk '
    BEGIN {
      FS="\\|"
      in_windows=0
      in_oc=0
      fmt=1
      name=""
      uuid=""
      date=""
      is_auto=0
      wins=0
      oc_count=0
      sid_missing=0
      oc_title=""
      oc_sid=""
    }
    /^FORMAT_VERSION=/ {
      v=substr($0,16)
      if (v ~ /^[0-9]+$/) fmt=v+0
      next
    }
    /^SESSION_NAME=/ {
      if (name=="") name=substr($0,14)
      next
    }
    /^SESSION_UUID=/ {
      if (uuid=="") uuid=substr($0,14)
      next
    }
    /^ARCHIVED_AT=/ {
      if (date=="") date=substr($0,13)
      next
    }
    /^AUTO_ARCHIVED=true$/ {
      is_auto=1
      next
    }
    /^---WINDOWS---$/ {
      in_windows=1
      in_oc=0
      next
    }
    /^---PANES---$/ {
      in_windows=0
      in_oc=0
      next
    }
    /^---OPENCODE---$/ {
      in_windows=0
      in_oc=1
      next
    }
    {
      if (in_windows && $0 ~ /[^[:space:]]/) wins++
      if (in_oc) {
        widx=$1
        sid=$3
        title=$4
        if (widx != "") {
          oc_count++
          if (sid == "") sid_missing++
          if (oc_title == "" && title != "") oc_title=title
          if (oc_sid == "" && sid != "") oc_sid=sid
        }
      }
    }
    END {
      if (uuid=="") uuid="_legacy"
      printf "%d\037%s\037%s\037%s\037%d\037%d\037%d\037%d\037%s\037%s", fmt, uuid, name, date, is_auto, wins, oc_count, sid_missing, oc_title, oc_sid
    }
  ' "$file") || return 1

  local fmt uuid name date is_auto wins oc_count sid_missing oc_title oc_sid
  IFS=$'\037' read -r fmt uuid name date is_auto wins oc_count sid_missing oc_title oc_sid <<< "$parsed"

  name=$(_tmux_af_decode_field_if_needed "$fmt" "$name")
  oc_title=$(_tmux_af_decode_field_if_needed "$fmt" "$oc_title")
  oc_sid=$(_tmux_af_decode_field_if_needed "$fmt" "$oc_sid")

  printf '%s|%s|%s|%d|%d|%d|%d|%s|%s\n' "$uuid" "$name" "$date" "$is_auto" "$wins" "$oc_count" "$sid_missing" "$oc_title" "$oc_sid"
}

_tmux_archive_meta_bulk() {
  setopt local_options nonomatch
  local files=("$TMUX_ARCHIVE_DIR"/*.archive(N))
  [ "${#files[@]}" -eq 0 ] && return 0

  awk '
    function hexdigit(c, p) {
      c=toupper(c)
      p=index("0123456789ABCDEF", c)
      if (p==0) return -1
      return p-1
    }
    function urldecode(s,    out,i,ch,h1,h2,d1,d2) {
      out=""
      for (i=1; i<=length(s); i++) {
        ch=substr(s,i,1)
        if (ch=="%" && i+2<=length(s)) {
          h1=substr(s,i+1,1)
          h2=substr(s,i+2,1)
          d1=hexdigit(h1)
          d2=hexdigit(h2)
          if (d1>=0 && d2>=0) {
            out = out sprintf("%c", d1*16 + d2)
            i += 2
            continue
          }
        }
        out = out ch
      }
      return out
    }
    function reset_state() {
      fmt=1
      name=""
      uuid=""
      date=""
      is_auto=0
      wins=0
      oc_count=0
      sid_missing=0
      oc_title=""
      oc_sid=""
      in_windows=0
      in_oc=0
    }
    function emit_current(    out_name,out_title,out_sid) {
      if (curr_file=="") return
      if (uuid=="") uuid="_legacy"
      out_name=name
      out_title=oc_title
      out_sid=oc_sid
      if (fmt>=2) {
        out_name=urldecode(out_name)
        out_title=urldecode(out_title)
        out_sid=urldecode(out_sid)
      }
      printf "%s|%s|%s|%s|%d|%d|%d|%d|%s|%s\n", curr_file, uuid, out_name, date, is_auto, wins, oc_count, sid_missing, out_title, out_sid
    }
    FNR==1 {
      emit_current()
      curr_file=FILENAME
      reset_state()
    }
    /^FORMAT_VERSION=/ {
      v=substr($0,16)
      if (v ~ /^[0-9]+$/) fmt=v+0
      next
    }
    /^SESSION_NAME=/ {
      if (name=="") name=substr($0,14)
      next
    }
    /^SESSION_UUID=/ {
      if (uuid=="") uuid=substr($0,14)
      next
    }
    /^ARCHIVED_AT=/ {
      if (date=="") date=substr($0,13)
      next
    }
    /^AUTO_ARCHIVED=true$/ {
      is_auto=1
      next
    }
    /^---WINDOWS---$/ {
      in_windows=1
      in_oc=0
      next
    }
    /^---PANES---$/ {
      in_windows=0
      in_oc=0
      next
    }
    /^---OPENCODE---$/ {
      in_windows=0
      in_oc=1
      next
    }
    {
      if (in_windows && $0 ~ /[^[:space:]]/) wins++
      if (in_oc) {
        widx=$1
        sid=$3
        title=$4
        if (widx != "") {
          oc_count++
          if (sid == "") sid_missing++
          if (oc_title == "" && title != "") oc_title=title
          if (oc_sid == "" && sid != "") oc_sid=sid
        }
      }
    }
    END {
      emit_current()
    }
  ' "${files[@]}"
}

# ── UUID group aggregation ──────────────────────────────────────────────────
_tmux_archive_groups() {
  _tmux_archive_meta_bulk | awk -F'|' '
    NF>=10 {
      uuid=$2; name=$3; date=$4; is_auto=$5; oc_cnt=$7; sid_miss=$8
      count[uuid]++
      if (is_auto+0 > 0) auto_count[uuid]++
      oc_total[uuid]+=oc_cnt+0
      sid_missing_total[uuid]+=sid_miss+0
      if (date > latest[uuid]) latest[uuid]=date
      if (!(uuid in sname)) sname[uuid]=name
    }
    END {
      for (u in count) {
        ac = (u in auto_count) ? auto_count[u] : 0
        oct = (u in oc_total) ? oc_total[u] : 0
        sm = (u in sid_missing_total) ? sid_missing_total[u] : 0
        printf "%s|%s|%d|%s|%d|%d|%d\n", u, sname[u], count[u], latest[u], ac, oct, sm
      }
    }'
}

# ── Archives for a specific UUID (time-descending) ──────────────────────────
_tmux_archives_for_uuid() {
  local target_uuid="$1"
  [ -z "$target_uuid" ] && return 1
  _tmux_archive_meta_bulk | sort -t'|' -k4 -r | while IFS='|' read -r f uuid name date is_auto wins oc_count sid_missing oc_title oc_sid; do
    [ -z "$f" ] && continue
    if [ "$uuid" = "$target_uuid" ]; then
      local tag=''
      [ "$is_auto" -gt 0 ] 2>/dev/null && tag=' [auto]'
      if [ "$oc_count" -gt 0 ] 2>/dev/null; then
        tag="${tag} [OC:${oc_count}]"
        [ "$sid_missing" -gt 0 ] 2>/dev/null && tag="${tag} [sid?:${sid_missing}]"
      fi
      printf '%s|%s  %s  \033[90m%sw\033[0m%s\n' "$f" "$name" "$date" "$wins" "$tag"
    fi
  done
}

# ── Build group preview cache for fzf ───────────────────────────────────────
_tmux_build_group_preview_cache() {
  local cache_file=$(mktemp -t tmux_group_preview)
  [ -z "$cache_file" ] && return 1
  typeset -A shown
  _tmux_archive_meta_bulk | sort -t'|' -k4 -r | while IFS='|' read -r f uuid name date is_auto wins oc_count sid_missing oc_title oc_sid; do
    [ -z "$f" ] && continue
    [ -z "$uuid" ] && uuid='_legacy'
    local n=${shown[$uuid]:-0}
    [ "$n" -ge 10 ] && continue
    local tag=''
    [ "$is_auto" -gt 0 ] 2>/dev/null && tag=' [auto]'
    if [ "$oc_count" -gt 0 ] 2>/dev/null; then
      tag="${tag} [OC:${oc_count}]"
      [ "$sid_missing" -gt 0 ] 2>/dev/null && tag="${tag} [sid?:${sid_missing}]"
    fi
    local title_hint=''
    if [ -n "$oc_title" ]; then
      title_hint=" - ${oc_title}"
      [ -n "$oc_sid" ] && title_hint="${title_hint} [${oc_sid}]"
    fi
    printf '%s|%s  %s  %sw%s%s\n' "$uuid" "$name" "$date" "$wins" "$tag" "$title_hint" >> "$cache_file"
    shown[$uuid]=$((n + 1))
  done
  echo "$cache_file"
}

# ── UUID group deletion ─────────────────────────────────────────────────────
_tmux_archive_delete_group_unlocked() {
  local target_uuid="$1"
  [ -z "$target_uuid" ] && return 1
  local deleted=0
  for f in "$TMUX_ARCHIVE_DIR"/*.archive; do
    [ ! -f "$f" ] && continue
    local uuid=$(_tmux_af_header_get "$f" SESSION_UUID)
    [ -z "$uuid" ] && uuid='_legacy'
    if [ "$uuid" = "$target_uuid" ]; then
      local fbase="${f%.archive}"
      rm -f "${fbase}"_w*_p*.pane 2>/dev/null
      rm -f "$f"
      deleted=$((deleted + 1))
    fi
  done
  echo "\033[31m✓ 그룹 삭제: ${deleted}개 아카이브\033[0m"
}

_tmux_archive_delete_group() {
  _tmux_archive_with_lock 20 _tmux_archive_delete_group_unlocked "$1"
}

# ── Auto-archive all active sessions ────────────────────────────────────────
_tmux_autoarchive_all() {
  mkdir -p "$TMUX_ARCHIVE_DIR"
  local sessions=$(tmux ls -F '#{session_name}' 2>/dev/null)
  [ -z "$sessions" ] && return
  echo "$sessions" | while read -r s; do
    _tmux_ensure_uuid "$s" >/dev/null
    tmux-archive save "$s" auto
  done
}

# ── Auto-archive cleanup (per-UUID max + optional age limit) ────────────────
_tmux_autoarchive_cleanup_unlocked() {
  [ "$TMUX_ARCHIVE_AUTO_CLEANUP" != '1' ] && return
  setopt local_options nonomatch
  local now=$(date +%s)
  local max_per_uuid="$TMUX_ARCHIVE_AUTO_MAX_PER_UUID"
  local max_age_days="$TMUX_ARCHIVE_AUTO_MAX_AGE_DAYS"
  case "$max_per_uuid" in
    ''|*[!0-9]*) max_per_uuid=10 ;;
  esac
  case "$max_age_days" in
    ''|*[!0-9]*) max_age_days=0 ;;
  esac
  local use_age_limit=false
  [ "$max_age_days" -gt 0 ] && use_age_limit=true
  local max_age_secs=$((max_age_days * 86400))

  local uuids=$(for f in "$TMUX_ARCHIVE_DIR"/*.archive;
  do
    [ ! -f "$f" ] && continue
    grep -q '^AUTO_ARCHIVED=true' "$f" || continue
    local uuid=$(_tmux_af_header_get "$f" SESSION_UUID)
    [ -z "$uuid" ] && uuid='_legacy'
    echo "$uuid"
  done | sort -u)

  while IFS= read -r uuid; do
    [ -z "$uuid" ] && continue
    local idx=0
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      idx=$((idx + 1))
      local should_delete=false
      [ $idx -gt $max_per_uuid ] && should_delete=true
      if [ "$should_delete" = false ] && [ "$use_age_limit" = true ]; then
        local fdate=$(grep '^ARCHIVED_AT=' "$f" | cut -d= -f2-)
        local fsecs=$(date -j -f '%Y-%m-%d %H:%M:%S' "$fdate" +%s 2>/dev/null)
        if [ -n "$fsecs" ] && [ $((now - fsecs)) -gt $max_age_secs ]; then
          should_delete=true
        fi
      fi
      if [ "$should_delete" = true ]; then
        local fbase="${f%.archive}"
        rm -f "${fbase}"_w*_p*.pane 2>/dev/null
        rm -f "$f"
      fi
    done < <(for f in "$TMUX_ARCHIVE_DIR"/*.archive; do
      [ ! -f "$f" ] && continue
      grep -q '^AUTO_ARCHIVED=true' "$f" || continue
      local fuuid=$(_tmux_af_header_get "$f" SESSION_UUID)
      [ -z "$fuuid" ] && fuuid='_legacy'
      [ "$fuuid" = "$uuid" ] && echo "$f"
    done | sort -r)
  done <<< "$uuids"
}

_tmux_autoarchive_cleanup() {
  _tmux_archive_with_lock 60 _tmux_autoarchive_cleanup_unlocked
}

_tmux_archive_save_unlocked() {
  setopt local_options pipefail
  local session="$1"
  local auto_mode="$2"

  local uuid
  uuid=$(_tmux_ensure_uuid "$session") || return 1
  local ts
  ts=$(date +%Y%m%d_%H%M%S)
  local safe_name
  safe_name=$(_tmux_archive_safe_name "$session")
  local file="$TMUX_ARCHIVE_DIR/${safe_name}_${ts}.archive"
  local escaped_session
  escaped_session=$(_tmux_af_escape "$session")
  local tmp_file
  tmp_file=$(mktemp "${TMUX_ARCHIVE_DIR}/.${safe_name}_${ts}.XXXXXX.tmp") || {
    echo "\033[31m아카이브 임시 파일 생성 실패\033[0m"
    return 1
  }

  if ! {
    echo "FORMAT_VERSION=2"
    echo "SESSION_NAME=$escaped_session"
    echo "SESSION_UUID=$uuid"
    echo "ARCHIVED_AT=$(date '+%Y-%m-%d %H:%M:%S')"
    if [ "$auto_mode" = 'auto' ]; then
      echo "AUTO_ARCHIVED=true"
      echo "SCROLLBACK_MODE=recent"
      echo "SCROLLBACK_LINES=$TMUX_ARCHIVE_AUTO_SCROLLBACK_LINES"
    else
      echo "SCROLLBACK_MODE=full"
    fi
    echo "---WINDOWS---"
    tmux list-windows -t "$session" -F "#{window_index}$(printf '\t')#{window_name}$(printf '\t')#{window_layout}" 2>/dev/null | while IFS=$'\t' read -r widx wname wlayout; do
      printf '%s|%s|%s\n' "$widx" "$(_tmux_af_escape "$wname")" "$(_tmux_af_escape "$wlayout")"
    done
    echo "---PANES---"
    tmux list-panes -t "$session" -F "#{session_name}$(printf '\t')#{window_index}$(printf '\t')#{pane_index}$(printf '\t')#{pane_current_path}$(printf '\t')#{pane_current_command}$(printf '\t')#{pane_title}" 2>/dev/null | while IFS=$'\t' read -r sn widx pidx ppath pcmd ptitle; do
      printf '%s|%s|%s|%s|%s|%s\n' \
        "$(_tmux_af_escape "$sn")" "$widx" "$pidx" \
        "$(_tmux_af_escape "$ppath")" "$(_tmux_af_escape "$pcmd")" "$(_tmux_af_escape "$ptitle")"
    done
  } > "$tmp_file"; then
    rm -f "$tmp_file"
    echo "\033[31m아카이브 저장 실패: $session\033[0m"
    return 1
  fi

  local wins_count panes_count
  wins_count=$(_tmux_af_section_lines "$tmp_file" '---WINDOWS---' '---PANES---' | grep -c '[^[:space:]]' 2>/dev/null)
  panes_count=$(_tmux_af_section_lines "$tmp_file" '---PANES---' '' | grep -c '[^[:space:]]' 2>/dev/null)
  if [ "$wins_count" -le 0 ] 2>/dev/null || [ "$panes_count" -le 0 ] 2>/dev/null; then
    rm -f "$tmp_file"
    echo "\033[31m아카이브 저장 실패: 필수 섹션(WINDOWS/PANES) 검증 실패\033[0m"
    return 1
  fi

  echo "---OPENCODE---" >> "$tmp_file"
  if typeset -f _tmux_oc_capture_session > /dev/null 2>&1; then
    _tmux_oc_capture_session "$session" "$tmp_file" "${file%.archive}"
  fi
  if ! mv -f "$tmp_file" "$file"; then
    rm -f "$tmp_file"
    echo "\033[31m아카이브 파일 finalize 실패: $session\033[0m"
    return 1
  fi

  local base="${file%.archive}"
  local capture_start='-'
  local auto_lines="$TMUX_ARCHIVE_AUTO_SCROLLBACK_LINES"
  case "$auto_lines" in
    ''|*[!0-9]*) auto_lines=200 ;;
  esac
  if [ "$auto_mode" = 'auto' ]; then
    capture_start="-${auto_lines}"
  fi
  tmux list-panes -t "$session" -F '#{window_index}|#{pane_index}' 2>/dev/null | while IFS='|' read -r _widx _pidx; do
    tmux capture-pane -t "${session}:${_widx}.${_pidx}" -p -S "$capture_start" > "${base}_w${_widx}_p${_pidx}.pane" 2>/dev/null
  done
  [ "$auto_mode" != 'auto' ] && echo "\033[32m✓ 아카이브 저장: $session → $file\033[0m"
}

# ═══════════════════════════════════════════════════════════════════════════
#  tmux-archive CLI
# ═══════════════════════════════════════════════════════════════════════════
tmux-archive() {
  setopt local_options nonomatch typeset_silent
  mkdir -p "$TMUX_ARCHIVE_DIR"
  local cmd="${1:-help}"
  case "$cmd" in
    save)
      local session="$2"
      local auto_mode="$3"
      if [ -z "$session" ]; then
        session=$(tmux ls -F '#{session_name}' 2>/dev/null | fzf --height=40% --reverse --header='아카이브할 세션 선택')
        [ -z "$session" ] && return
      fi
      if ! tmux has-session -t "$session" 2>/dev/null; then
        echo "\033[31m세션 '$session' 없음\033[0m"; return 1
      fi
      _tmux_archive_with_lock 30 _tmux_archive_save_unlocked "$session" "$auto_mode"
      ;;
    save-and-kill)
      local session="$2"
      if [ -z "$session" ]; then
        session=$(tmux ls -F '#{session_name}' 2>/dev/null | fzf --height=40% --reverse --header='아카이브 후 종료할 세션 선택')
        [ -z "$session" ] && return
      fi
      tmux-archive save "$session" || return 1
      tmux kill-session -t "$session" 2>/dev/null && \
        echo "\033[33m✓ 세션 종료됨: $session\033[0m"
      ;;
    restore)
      _tmux_archive_restore "$2"
      ;;
    list)
      local files=("$TMUX_ARCHIVE_DIR"/*.archive(N))
      if [ ! -d "$TMUX_ARCHIVE_DIR" ] || [ "${#files[@]}" -eq 0 ]; then
        echo "\033[90m아카이브 없음\033[0m"; return
      fi
      echo '\033[1;36m━━━ tmux 아카이브 목록 ━━━\033[0m'
      echo ''
      _tmux_archive_meta_bulk | sort -t'|' -k4 -r | while IFS='|' read -r f uuid name date is_auto wins oc_count sid_missing oc_title oc_sid; do
        printf '  \033[36m%-18s\033[0m  %s  \033[90m%sw\033[0m\n' "$name" "$date" "$wins"
      done
      ;;
    delete)
      local file="$2"
      if [ -z "$file" ]; then
        file=$(_tmux_archive_meta_bulk | sort -t'|' -k4 -r | while IFS='|' read -r f uuid name date is_auto wins oc_count sid_missing oc_title oc_sid; do
          printf '%s|%s  %s\n' "$f" "$name" "$date"
        done | fzf --height=50% --reverse --header='삭제할 아카이브 선택' -d'|' --with-nth=2 | cut -d'|' -f1)
        [ -z "$file" ] && return
      fi
      _tmux_archive_delete_file "$file"
      ;;
    *)
      echo 'tmux-archive <command>'
      echo ''
      echo '  save [session]         세션 아카이브 저장'
      echo '  save-and-kill [session] 아카이브 저장 후 세션 종료'
      echo '  restore [file]         아카이브에서 복원'
      echo '  list                   아카이브 목록'
      echo '  delete [file]          아카이브 삭제'
      ;;
  esac
}

# ═══════════════════════════════════════════════════════════════════════════
#  Archive Manager — Level 1: UUID group list
# ═══════════════════════════════════════════════════════════════════════════
_tmux_archive_manager() {
  setopt local_options nonomatch typeset_silent
  while true; do
    local archive_count=$(print -rl -- "$TMUX_ARCHIVE_DIR"/*.archive(N) | wc -l | tr -d ' ')
    clear
    echo '\033[1;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m'
    echo '\033[1;34m  📦 아카이브 매니저          \033[90m'"${archive_count}"'개\033[0m'
    echo '\033[1;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m'
    echo '\033[33mEnter\033[0m 그룹 열기  \033[32mCtrl+S\033[0m 새 아카이브  \033[31mCtrl+X\033[0m 그룹 삭제  \033[36mCtrl+L\033[0m 새로고침  \033[90mESC\033[0m 돌아가기'
    echo ''

    if [ "$archive_count" -eq 0 ] 2>/dev/null || [ "$archive_count" = "0" ]; then
      echo '  \033[90m아카이브 없음\033[0m'
      echo ''
      local result
      result=$(echo "아카이브 없음 — Ctrl+S로 새 아카이브 생성" | \
        fzf --height=30% --reverse --ansi \
            --header='아카이브 매니저' \
            --expect='ctrl-s,ctrl-l' \
            --disabled)
      local akey
      akey=$(echo "$result" | head -1)
      if [ "$akey" = 'ctrl-s' ]; then
        _tmux_archive_save_flow
        continue
      elif [ "$akey" = 'ctrl-l' ]; then
        continue
      else
        return
      fi
    fi

    # Group list
    local glist
    glist=$(_tmux_archive_groups | sort -t'|' -k4 -r | while IFS='|' read -r uuid name total latest auto_cnt oc_total sid_missing_total; do
      local label="$name"
      [ "$uuid" = '_legacy' ] && label="(레거시)"
      local auto_hint=''
      local oc_hint=''
      [ "$auto_cnt" -gt 0 ] 2>/dev/null && auto_hint=" \033[90m[auto:${auto_cnt}]\033[0m"
      [ "$oc_total" -gt 0 ] 2>/dev/null && oc_hint=" \033[34m[OC:${oc_total}]\033[0m"
      [ "$sid_missing_total" -gt 0 ] 2>/dev/null && oc_hint="${oc_hint} \033[31m[sid?:${sid_missing_total}]\033[0m"
      printf '%s|%-18s  \033[90m%s\033[0m  \033[36m%s개\033[0m%b%b\n' "$uuid" "$label" "$latest" "$total" "$auto_hint" "$oc_hint"
    done)
    if [ -z "$(echo "$glist" | tr -d '[:space:]')" ]; then
      echo '  \033[90m표시할 그룹 없음 (Ctrl+L 새로고침)\033[0m'
      sleep 0.6
      continue
    fi

    local preview_cache
    preview_cache=$(_tmux_build_group_preview_cache)
    local result
    result=$(echo "$glist" | \
      fzf --height=60% --reverse --ansi \
          --header='세션 그룹 선택' \
          --expect='ctrl-s,ctrl-x,ctrl-l' \
          -d'|' --with-nth=2 \
          --preview="TMUX_GROUP_PREVIEW_CACHE=${preview_cache} zsh $TMUX_MANAGER_DIR/lib/preview.sh group {1}" \
          --preview-window=right:45%:wrap)
    [ -n "$preview_cache" ] && rm -f "$preview_cache"

    local akey
    akey=$(echo "$result" | head -1)
    local chosen_uuid
    chosen_uuid=$(echo "$result" | tail -1 | cut -d'|' -f1)
    local chosen_name
    chosen_name=$(echo "$result" | tail -1 | cut -d'|' -f2 | awk '{print $1}')

    if [ "$akey" = 'ctrl-s' ]; then
      _tmux_archive_save_flow
      continue
    elif [ "$akey" = 'ctrl-l' ]; then
      continue
    elif [ "$akey" = 'ctrl-x' ] && [ -n "$chosen_uuid" ]; then
      echo -n "\033[31m'$chosen_name' 그룹 전체 삭제할까요? (y/N): \033[0m"
      local dconfirm
      read -r dconfirm
      if [ "$dconfirm" = 'y' ] || [ "$dconfirm" = 'Y' ]; then
        _tmux_archive_delete_group "$chosen_uuid"
      fi
      sleep 0.5
      continue
    elif [ -n "$chosen_uuid" ]; then
      _tmux_archive_level2 "$chosen_uuid" "$chosen_name"
      continue
    else
      return
    fi
  done
}

# ═══════════════════════════════════════════════════════════════════════════
#  Archive Manager — Level 2: snapshots within a group
# ═══════════════════════════════════════════════════════════════════════════
_tmux_archive_level2() {
  setopt local_options nonomatch typeset_silent
  local target_uuid="$1"
  local group_name="$2"
  while true; do
    clear
    echo '\033[1;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m'
    echo '\033[1;34m  📦 '"$group_name"'\033[0m'
    echo '\033[1;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m'
    echo '\033[33mEnter\033[0m 복원  \033[31mCtrl+D\033[0m 단일 삭제  \033[31mCtrl+X\033[0m 그룹 전체 삭제  \033[36mCtrl+L\033[0m 새로고침  \033[90mESC\033[0m 돌아가기'
    echo ''

    local alist
    alist=$(_tmux_archives_for_uuid "$target_uuid")
    if [ -z "$(echo "$alist" | tr -d '[:space:]')" ]; then
      echo '  \033[90m아카이브 없음\033[0m'
      sleep 1
      return
    fi

    local result
    result=$(echo "$alist" | \
      fzf --height=60% --reverse --ansi \
          --header="${group_name} 스냅샷" \
          --expect='ctrl-d,ctrl-x,ctrl-l' \
          -d'|' --with-nth=2 \
          --preview="zsh $TMUX_MANAGER_DIR/lib/preview.sh archive {1}" \
          --preview-window=right:45%:wrap)

    local akey
    akey=$(echo "$result" | head -1)
    local achoice
    achoice=$(echo "$result" | tail -1 | cut -d'|' -f1)
    local aname
    aname=$(echo "$result" | tail -1 | cut -d'|' -f2 | awk '{print $1}')

    if [ "$akey" = 'ctrl-d' ] && [ -n "$achoice" ]; then
      echo -n "\033[31m'$aname' 아카이브 삭제할까요? (y/N): \033[0m"
      local dconfirm
      read -r dconfirm
      if [ "$dconfirm" = 'y' ] || [ "$dconfirm" = 'Y' ]; then
        _tmux_archive_delete_file "$achoice"
      fi
      sleep 0.5
      continue
    elif [ "$akey" = 'ctrl-l' ]; then
      continue
    elif [ "$akey" = 'ctrl-x' ]; then
      echo -n "\033[31m'$group_name' 그룹 전체 삭제할까요? (y/N): \033[0m"
      local dconfirm
      read -r dconfirm
      if [ "$dconfirm" = 'y' ] || [ "$dconfirm" = 'Y' ]; then
        _tmux_archive_delete_group "$target_uuid"
      fi
      sleep 0.5
      return
    elif [ -n "$achoice" ]; then
      local session_name
      session_name=$(_tmux_af_header_get "$achoice" SESSION_NAME)
      if tmux has-session -t "$session_name" 2>/dev/null; then
        echo "\033[31m세션 '$session_name' 이미 존재. 다른 이름으로 복원할까요?\033[0m"
        local rname
        read -r 'rname?새 이름 (빈값=취소): '
        if [ -z "$rname" ]; then
          sleep 0.5; continue
        fi
        local tmpfile
        tmpfile=$(mktemp)
        _tmux_af_set_session_name_copy "$achoice" "$tmpfile" "$rname"
        tmux-archive restore "$tmpfile" || { rm -f "$tmpfile"; echo "\033[31m복원 실패\033[0m"; sleep 0.8; continue; }
        rm -f "$tmpfile"
        session_name="$rname"
      else
        tmux-archive restore "$achoice" || { echo "\033[31m복원 실패\033[0m"; sleep 0.8; continue; }
      fi
      if _tmux_af_section_lines "$achoice" '---OPENCODE---' '' | grep -q '^[0-9]'; then
        sleep 1.5
      fi
      if _tmux_enter_session "$session_name"; then
        return
      fi
      echo "\033[31m세션 진입 실패: $session_name\033[0m"
      sleep 0.8
      continue
    else
      return
    fi
  done
}

# ── Save flow (session select → save → optional kill) ───────────────────────
_tmux_archive_save_flow() {
  local session
  session=$(tmux ls -F '#{session_name}' 2>/dev/null | \
    fzf --height=40% --reverse --header='아카이브할 세션 선택')
  [ -z "$session" ] && return
  tmux-archive save "$session"
  echo -n "\033[33m세션도 종료할까요? (y/N): \033[0m"
  local kill_confirm
  read -r kill_confirm
  if [ "$kill_confirm" = 'y' ] || [ "$kill_confirm" = 'Y' ]; then
    tmux kill-session -t "$session" 2>/dev/null && echo "\033[33m$session 종료됨\033[0m"
  fi
  sleep 0.5
}

# ═══════════════════════════════════════════════════════════════════════════
#  Main session manager (fzf)
# ═══════════════════════════════════════════════════════════════════════════
tmux-manager() {
  setopt local_options nonomatch typeset_silent
  local archive_count=$(print -rl -- "$TMUX_ARCHIVE_DIR"/*.archive(N) | wc -l | tr -d ' ')
  if ! tmux ls &>/dev/null; then
    clear
    echo '\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m'
    echo '\033[1;36m  ❐ tmux 세션 매니저\033[0m'
    echo '\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m'
    echo ''
    echo '  \033[90m활성 세션 없음\033[0m'
    if [ "$archive_count" -gt 0 ] 2>/dev/null; then
      echo "  \033[34m아카이브 ${archive_count}개 있음\033[0m"
      echo ''
      echo '  \033[32m1\033[0m 새 세션 생성  \033[34m2\033[0m 아카이브 매니저  \033[90m3\033[0m 취소'
      echo ''
      local opt
      read -r 'opt?선택: '
      case "$opt" in
        1)
          local name
          read -r 'name?세션 이름 (Enter=main): '
          tmux new -s "${name:-main}"
          ;;
        2) _tmux_archive_manager ;;
        *) return ;;
      esac
    else
      echo ''
      local name
      read -r 'name?새 세션 이름 (Enter=main): '
      tmux new -s "${name:-main}"
    fi
    return
  fi
  while true; do
    clear
    local total=$(tmux ls | wc -l | tr -d ' ')
    archive_count=$(print -rl -- "$TMUX_ARCHIVE_DIR"/*.archive(N) | wc -l | tr -d ' ')
    local archive_hint=''
    [ "$archive_count" -gt 0 ] 2>/dev/null && archive_hint="  \033[90m📦 ${archive_count}개\033[0m"
    echo '\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m'
    echo '\033[1;36m  ❐ tmux 세션 매니저          \033[90m세션 '"$total"'개\033[0m'"$archive_hint"
    echo '\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m'
    echo '\033[33mEnter\033[0m 접속  \033[31mCtrl+D\033[0m 삭제  \033[32mCtrl+N\033[0m 새 세션  \033[35mCtrl+R\033[0m 이름변경  \033[34mCtrl+A\033[0m 📦아카이브  \033[90mESC\033[0m 취소'
    echo ''
    local metrics
    metrics=$(_tmux_session_metrics)
    typeset -A sess_cpu sess_mem
    while IFS='|' read -r ms mcpu mmem; do
      [ -z "$ms" ] && continue
      sess_cpu[$ms]="$mcpu"
      sess_mem[$ms]="$mmem"
    done <<< "$metrics"
    local list
    list=$(tmux ls -F '#{session_name}|#{session_windows}|#{?session_attached,1,0}|#{session_activity}' | \
      while IFS='|' read -r name wins attached ts; do
        local ago='' sstate=''
        if [ "$attached" = '1' ]; then
          sstate='\033[32m● attached\033[0m'
        else
          sstate='\033[90m○ detached\033[0m'
        fi
        if [ -n "$ts" ]; then
          local now
          now=$(date +%s)
          local diff=$((now - ts))
          if [ $diff -lt 60 ]; then ago="${diff}초 전"
          elif [ $diff -lt 3600 ]; then ago="$((diff/60))분 전"
          elif [ $diff -lt 86400 ]; then ago="$((diff/3600))시간 전"
          else ago="$((diff/86400))일 전"
          fi
        fi
        local pane_titles
        pane_titles=$(tmux list-panes -t "$name" -F '#{pane_title}' 2>/dev/null)
        local oc_count
        oc_count=$(echo "$pane_titles" | grep -c '^OC |')
        local oc_saved_count
        oc_saved_count=$(tmux show-option -t "$name" -qv @oc_saved_count 2>/dev/null)
        local oc_saved_sid_missing
        oc_saved_sid_missing=$(tmux show-option -t "$name" -qv @oc_saved_sid_missing 2>/dev/null)
        local oc_hint=''
        [ "$oc_count" -gt 0 ] 2>/dev/null && oc_hint=" \033[34m[OC:${oc_count}]\033[0m"
        if [ -n "$oc_saved_count" ] && [ "$oc_saved_count" -gt 0 ] 2>/dev/null; then
          oc_hint="${oc_hint} \033[90m[OC(hist):${oc_saved_count}]\033[0m"
          [ -n "$oc_saved_sid_missing" ] && [ "$oc_saved_sid_missing" -gt 0 ] 2>/dev/null && oc_hint="${oc_hint} \033[31m[sid?:${oc_saved_sid_missing}]\033[0m"
        fi
        local cpu="${sess_cpu[$name]:-0.0}"
        local mem="${sess_mem[$name]:-0}"
        local metric_hint=" \033[90mC${cpu}% M${mem}M\033[0m"
        printf '%s|%-18s \033[36m%sw\033[0m  %b  \033[90m%s\033[0m%b%b\n' "$name" "$name" "$wins" "$sstate" "$ago" "$metric_hint" "$oc_hint"
      done)
    local session
    session=$(echo "$list" | \
      fzf --height=60% --reverse --ansi \
          --header='세션 선택' \
          --expect='ctrl-d,ctrl-n,ctrl-r,ctrl-a' \
          -d'|' --with-nth=2 \
          --preview="zsh $TMUX_MANAGER_DIR/lib/preview.sh live {1}" \
          --preview-window=right:45%:wrap)
    local key
    key=$(echo "$session" | head -1)
    local choice
    choice=$(echo "$session" | tail -1 | cut -d'|' -f1)
    if [ "$key" = 'ctrl-n' ]; then
      local name
      read -r 'name?새 세션 이름: '
      tmux new -s "${name:-$(date +%H%M%S)}"
      return
    elif [ "$key" = 'ctrl-r' ] && [ -n "$choice" ]; then
      echo -n "\033[35m$choice → \033[0m"
      local newname
      read -r newname
      if [ -n "$newname" ]; then
        tmux rename-session -t "$choice" "$newname" 2>/dev/null && \
          echo "\033[35m$choice → $newname\033[0m" || \
          echo "\033[31m이름 변경 실패\033[0m"
        sleep 0.5
      fi
      continue
    elif [ "$key" = 'ctrl-d' ] && [ -n "$choice" ]; then
      echo -n "\033[31m$choice 삭제할까요? (y/N): \033[0m"
      local confirm
      read -r confirm
      if [ "$confirm" = 'y' ] || [ "$confirm" = 'Y' ]; then
        if tmux-archive save "$choice" >/dev/null 2>&1; then
          tmux kill-session -t "$choice" 2>/dev/null && echo "\033[31m$choice 삭제됨 (아카이브 저장 완료)\033[0m"
        else
          echo "\033[31m아카이브 저장 실패로 삭제 취소: $choice\033[0m"
        fi
      fi
      sleep 0.5
      tmux ls &>/dev/null || { echo '세션 없음.'; return; }
      continue
    elif [ "$key" = 'ctrl-a' ]; then
      _tmux_archive_manager
      tmux ls &>/dev/null || { echo '세션 없음.'; return; }
      continue
    elif [ -n "$choice" ]; then
      if _tmux_enter_session "$choice"; then
        return
      fi
      echo "\033[31m세션 진입 실패: $choice\033[0m"
      sleep 0.8
      continue
    else
      return
    fi
  done
}
