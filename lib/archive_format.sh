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

_tmux_af_is_unreserved_byte() {
  local b="$1"
  [ -z "$b" ] && return 1
  (( b >= 48 && b <= 57 )) && return 0
  (( b >= 65 && b <= 90 )) && return 0
  (( b >= 97 && b <= 122 )) && return 0
  (( b == 45 || b == 46 || b == 95 || b == 126 )) && return 0
  return 1
}

_tmux_af_hex_to_dec() {
  local hex="$1"
  [[ "$hex" == [0-9A-Fa-f][0-9A-Fa-f] ]] || return 1
  echo $((16#$hex))
}

_tmux_af_escape() {
  local s="$1"
  s="${s//$'\r'/}"
  if ! _tmux_af_has_python3; then
    local out='' hex byte dec
    while IFS= read -r hex; do
      [ -z "$hex" ] && continue
      dec=$((16#$hex))
      if _tmux_af_is_unreserved_byte "$dec"; then
        byte=$(printf "\\$(printf '%03o' "$dec")")
        out+="$byte"
      else
        out+="%${hex}"
      fi
    done < <(printf '%s' "$s" | LC_ALL=C hexdump -v -e '/1 "%02X\n"')
    printf '%s' "$out"
    return 0
  fi
  printf '%s' "$s" | python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=""), end="")'
}

_tmux_af_unescape() {
  local s="$1"
  if ! _tmux_af_has_python3; then
    local out='' i=1 len=${#s} ch hex dec byte
    while [ "$i" -le "$len" ]; do
      ch="${s:$((i-1)):1}"
      if [ "$ch" = '%' ] && [ $((i + 2)) -le "$len" ]; then
        hex="${s:$i:2}"
        if dec=$(_tmux_af_hex_to_dec "$hex"); then
          byte=$(printf "\\$(printf '%03o' "$dec")")
          out+="$byte"
          i=$((i + 3))
          continue
        fi
      fi
      out+="$ch"
      i=$((i + 1))
    done
    printf '%s' "$out"
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
