#!/bin/zsh

_tmux_af_format_version() {
  local file="$1"
  [ ! -f "$file" ] && { echo 1; return; }
  local v
  v=$(grep '^FORMAT_VERSION=' "$file" | cut -d= -f2 | head -1)
  case "$v" in
    ''|*[!0-9]*) echo 1 ;;
    *) echo "$v" ;;
  esac
}

_tmux_af_has_python3() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 -c 'import urllib.parse' >/dev/null 2>&1
}

_tmux_af_require_python3() {
  local context="${1:-아카이브 포맷 v2}"
  if _tmux_af_has_python3; then
    return 0
  fi
  echo "\033[31m${context}에는 python3가 필요합니다\033[0m" >&2
  return 1
}

_tmux_af_escape() {
  local s="$1"
  s="${s//$'\r'/}"
  if ! _tmux_af_has_python3; then
    printf '%s' "$s"
    return 0
  fi
  printf '%s' "$s" | python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=""), end="")'
}

_tmux_af_unescape() {
  local s="$1"
  if ! _tmux_af_has_python3; then
    printf '%s' "$s"
    return 0
  fi
  printf '%s' "$s" | python3 -c 'import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read()), end="")'
}

_tmux_af_header_get_raw() {
  local file="$1" key="$2"
  [ ! -f "$file" ] && return 1
  grep "^${key}=" "$file" | head -1 | cut -d= -f2-
}

_tmux_af_header_get() {
  local file="$1" key="$2"
  local v
  v=$(_tmux_af_header_get_raw "$file" "$key")
  [ -z "$v" ] && { echo ''; return; }
  local fmt
  fmt=$(_tmux_af_format_version "$file")
  if [ "$fmt" -ge 2 ] 2>/dev/null; then
    _tmux_af_unescape "$v"
  else
    echo "$v"
  fi
}

_tmux_af_section_lines() {
  local file="$1" start_marker="$2" end_marker="$3"
  [ ! -f "$file" ] && return 1
  awk -v s="$start_marker" -v e="$end_marker" '
    $0==s {insec=1; next}
    insec {
      if (e != "" && $0==e) exit
      if ($0 ~ /^---/ && e == "") next
      print
    }
  ' "$file"
}

_tmux_af_set_session_name_copy() {
  local src="$1" dst="$2" new_name="$3"
  [ ! -f "$src" ] && return 1
  local fmt
  fmt=$(_tmux_af_format_version "$src")
  local out_name="$new_name"
  if [ "$fmt" -ge 2 ] 2>/dev/null; then
    out_name=$(_tmux_af_escape "$new_name")
  fi
  awk -v n="$out_name" 'BEGIN{done=0}
    {
      if ($0 ~ /^SESSION_NAME=/) {
        print "SESSION_NAME=" n
        done=1
      } else {
        print $0
      }
    }
    END {
      if (!done) print "SESSION_NAME=" n
    }
  ' "$src" > "$dst"
}

_tmux_af_decode_field_if_needed() {
  local fmt="$1" val="$2"
  if [ "$fmt" -ge 2 ] 2>/dev/null; then
    _tmux_af_unescape "$val"
  else
    echo "$val"
  fi
}
