#!/bin/zsh
# tmux-manager — fzf preview helper (live / archive / group)
# Called as standalone script from fzf --preview.
# Usage: preview.sh live <session> | archive <file> | group <uuid>

TMUX_MANAGER_DIR="${0:A:h:h}"
source "$TMUX_MANAGER_DIR/lib/archive_format.sh"

mode="$1"
target="$2"

_divider() {
  echo "\033[90m────────────────────────────────\033[0m"
}

_pane_line() {
  local widx="$1" pidx="$2" pcmd="$3" ppath="$4" ptitle="$5" sid="$6"
  if [[ "$ptitle" == "OC |"* ]]; then
    local oc="${ptitle#OC | }"
    if [ -n "$sid" ]; then
      printf "  w%s.%s \033[33m●\033[0m opencode \033[36m\"%s\"\033[0m \033[90m[%s]\033[0m\n" "$widx" "$pidx" "$oc" "$sid"
    else
      printf "  w%s.%s \033[33m●\033[0m opencode \033[36m\"%s\"\033[0m\n" "$widx" "$pidx" "$oc"
    fi
    printf "        \033[90m%s\033[0m\n" "$ppath"
  elif [ -n "$pcmd" ] && [ "$pcmd" != "zsh" ] && [ "$pcmd" != "bash" ]; then
    printf "  w%s.%s \033[33m●\033[0m %s\n" "$widx" "$pidx" "$pcmd"
    printf "        \033[90m%s\033[0m\n" "$ppath"
  else
    printf "  w%s.%s \033[90m○\033[0m %s\n" "$widx" "$pidx" "$ppath"
  fi
}

_split_saved_lines() {
  local raw="$1"
  [ -z "$raw" ] && return
  if [[ "$raw" == *$'\037'* ]]; then
    printf '%s\n' "$raw" | tr '\037' '\n'
  else
    printf '%s\n' "$raw" | tr ',' '\n'
  fi
}

case "$mode" in
  live)
    session="$target"
    # Header
    created=$(tmux display -t "$session" -p "#{t:session_created}" 2>/dev/null)
    wins=$(tmux list-windows -t "$session" 2>/dev/null | wc -l | tr -d ' ')
    panes=$(tmux list-panes -t "$session" 2>/dev/null | wc -l | tr -d ' ')
    attached=$(tmux display -t "$session" -p "#{?session_attached,attached,detached}" 2>/dev/null)
    printf "\033[1;36m%s\033[0m  \033[90m%s\033[0m\n" "$session" "$attached"
    printf "\033[90m생성: %s  %sw %sp\033[0m\n" "$created" "$wins" "$panes"
    _divider

    oc_list=$(opencode session list 2>/dev/null)

    # Pane list
    tmux list-panes -t "$session" -F '#{window_index}|#{pane_index}|#{pane_current_command}|#{pane_current_path}|#{pane_title}' 2>/dev/null | while IFS='|' read -r widx pidx pcmd ppath ptitle; do
      sid=''
      if [[ "$ptitle" == "OC |"* ]]; then
        oc_title="${ptitle#OC | }"
        sid=$(echo "$oc_list" | awk -v t="$oc_title" 'index($0, t) > 0 {print $1; exit}')
      fi
      _pane_line "$widx" "$pidx" "$pcmd" "$ppath" "$ptitle" "$sid"
    done

    saved_count=$(tmux show-option -t "$session" -qv @oc_saved_count 2>/dev/null)
    saved_titles=$(tmux show-option -t "$session" -qv @oc_saved_titles 2>/dev/null)
    saved_sids=$(tmux show-option -t "$session" -qv @oc_saved_sids 2>/dev/null)
    saved_sid_missing=$(tmux show-option -t "$session" -qv @oc_saved_sid_missing 2>/dev/null)
    if [ -n "$saved_count" ] && [ "$saved_count" -gt 0 ] 2>/dev/null; then
      _divider
      printf "\033[90m아카이브 OpenCode 내역: %s개\033[0m\n" "$saved_count"
      [ -n "$saved_sid_missing" ] && [ "$saved_sid_missing" -gt 0 ] 2>/dev/null && printf "\033[31msid 누락: %s개\033[0m\n" "$saved_sid_missing"
      typeset -a title_arr sid_arr
      if [ -n "$saved_titles" ]; then
        while IFS= read -r t; do
          [ -z "$t" ] && continue
          title_arr+=("$t")
        done < <(_split_saved_lines "$saved_titles")
      fi
      if [ -n "$saved_sids" ]; then
        while IFS= read -r s; do
          [ -z "$s" ] && continue
          sid_arr+=("$s")
        done < <(_split_saved_lines "$saved_sids")
      fi
      local max_items=$#title_arr
      [ $#sid_arr -gt $max_items ] && max_items=$#sid_arr
      local i=1
      while [ $i -le $max_items ]; do
        local t="${title_arr[$i]}"
        local s="${sid_arr[$i]}"
        if [ -n "$t" ] && [ -n "$s" ]; then
          printf "\033[36m%s\033[0m  \033[90m[%s]\033[0m\n" "$t" "$s"
        elif [ -n "$t" ]; then
          printf "\033[36m%s\033[0m\n" "$t"
        elif [ -n "$s" ]; then
          printf "\033[90m%s\033[0m\n" "$s"
        fi
        i=$((i + 1))
      done
    fi

    # Screen preview
    _divider
    printf "\033[90m화면:\033[0m\n"
    tmux capture-pane -t "$session" -p 2>/dev/null | tail -15
    ;;

  archive)
    file="$target"
    [ ! -f "$file" ] && echo "파일 없음" && exit 1

    fmt=$(_tmux_af_format_version "$file")
    name=$(_tmux_af_header_get "$file" SESSION_NAME)
    date=$(_tmux_af_header_get "$file" ARCHIVED_AT)
    wins=$(_tmux_af_section_lines "$file" '---WINDOWS---' '---PANES---' | grep -c '[^[:space:]]' 2>/dev/null)
    panes_raw=$(_tmux_af_section_lines "$file" '---PANES---' '---OPENCODE---')
    [ -z "$(echo "$panes_raw" | tr -d '[:space:]')" ] && panes_raw=$(_tmux_af_section_lines "$file" '---PANES---' '')
    panes=$(echo "$panes_raw" | grep -c '[^[:space:]]' 2>/dev/null)
    printf "\033[1;36m%s\033[0m  \033[90marchived\033[0m\n" "$name"
    printf "\033[90m%s  %sw %sp\033[0m\n" "$date" "$wins" "$panes"
    _divider

    oc_lines=$(_tmux_af_section_lines "$file" '---OPENCODE---' '')
    echo "$panes_raw" | while IFS='|' read -r sn widx pidx ppath pcmd ptitle; do
      [ -z "$sn" ] && continue
      sn=$(_tmux_af_decode_field_if_needed "$fmt" "$sn")
      ppath=$(_tmux_af_decode_field_if_needed "$fmt" "$ppath")
      pcmd=$(_tmux_af_decode_field_if_needed "$fmt" "$pcmd")
      ptitle=$(_tmux_af_decode_field_if_needed "$fmt" "$ptitle")
      oc_sid=$(echo "$oc_lines" | awk -F'|' -v w="$widx" -v p="$pidx" '$1==w && $2==p {print $3; exit}')
      oc_sid=$(_tmux_af_decode_field_if_needed "$fmt" "$oc_sid")
      _pane_line "$widx" "$pidx" "$pcmd" "$ppath" "$ptitle" "$oc_sid"
    done

    oc_count=$(echo "$oc_lines" | grep -c '.' 2>/dev/null)
    if [ "$oc_count" -gt 0 ] 2>/dev/null; then
      _divider
      printf "\033[34m▸ opencode %s개 복원 가능\033[0m\n" "$oc_count"
      echo "$oc_lines" | while IFS='|' read -r widx pidx sid title dir; do
        [ -z "$widx" ] && continue
        sid=$(_tmux_af_decode_field_if_needed "$fmt" "$sid")
        title=$(_tmux_af_decode_field_if_needed "$fmt" "$title")
        dir=$(_tmux_af_decode_field_if_needed "$fmt" "$dir")
        printf "  \033[36m%s\033[0m\n" "$title"
        printf "  \033[90m%s  %s\033[0m\n" "$sid" "$dir"
      done
    fi
    ;;

  group)
    uuid="$target"
    [ -z "$uuid" ] && echo "UUID 없음" && exit 1
    printf "\033[1;34m그룹: %s\033[0m\n" "$uuid"
    _divider
    if [ -n "$TMUX_GROUP_PREVIEW_CACHE" ] && [ -f "$TMUX_GROUP_PREVIEW_CACHE" ]; then
      awk -F'|' -v u="$uuid" '$1==u {print "  "$2}' "$TMUX_GROUP_PREVIEW_CACHE" | head -10
    else
      # Source only what we need for _tmux_archives_for_uuid
      source "$TMUX_MANAGER_DIR/conf/defaults.conf"
      source "$TMUX_MANAGER_DIR/lib/core.sh"
      _tmux_archives_for_uuid "$uuid" | head -10 | while IFS='|' read -r f info; do
        [ -z "$f" ] && continue
        printf "  %s\n" "$info"
      done
    fi
    ;;
  *)
    echo "Usage: $0 live <session> | archive <file> | group <uuid>"
    exit 1
    ;;
esac
