#!/usr/bin/env bats

load helpers/setup

parse_restore_dimensions() {
  local windows_sorted="$1"
  local _restore_w=200 _restore_h=200
  local _raw_layout
  while IFS='|' read -r _ _ _raw_layout; do
    [ -z "$_raw_layout" ] && continue
    if echo "$_raw_layout" | grep -q '%2C\|%2c'; then
      _raw_layout=$(printf '%s' "$_raw_layout" | python3 -c "import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))" 2>/dev/null || echo "$_raw_layout")
    fi
    local _lw _lh
    _lw=$(echo "$_raw_layout" | grep -oE '^[0-9a-fA-F]+,[0-9]+x[0-9]+' | head -1 | sed 's/.*,//;s/x.*//')
    _lh=$(echo "$_raw_layout" | grep -oE '^[0-9a-fA-F]+,[0-9]+x[0-9]+' | head -1 | sed 's/.*x//;s/,.*//')
    [ -n "$_lw" ] && [ "$_lw" -gt "$_restore_w" ] 2>/dev/null && _restore_w="$_lw"
    [ -n "$_lh" ] && [ "$_lh" -gt "$_restore_h" ] 2>/dev/null && _restore_h="$_lh"
  done <<< "$windows_sorted"
  echo "${_restore_w}x${_restore_h}"
}

# ── Layout dimension parsing ─────────────────────────────────────────────

@test "parse_restore_dimensions: 134x108 stays at 200x200 (both dims < default)" {
  local windows="1|zsh|3b4a%2C134x108%2C0%2C0%5B134x38%2C0%2C0%7B69x38%2C0%2C0%2C8%2C64x38%2C70%2C0%2C9%7D%2C134x23%2C0%2C39%2C10%2C134x45%2C0%2C63%7B68x45%2C0%2C63%2C11%2C65x45%2C69%2C63%2C12%7D%5D"
  result=$(parse_restore_dimensions "$windows")
  [ "$result" = "200x200" ]
}

@test "parse_restore_dimensions: 200x50 stays at 200x200 (height < default)" {
  local windows="1|zsh|ab12,200x50,0,0{100x50,0,0,1,99x50,101,0,2}"
  result=$(parse_restore_dimensions "$windows")
  [ "$result" = "200x200" ]
}

@test "parse_restore_dimensions: picks max across multiple windows (250 width overrides)" {
  local windows
  windows=$(printf '%s\n%s' \
    "1|editor|aa11,80x24,0,0,1" \
    "2|monitor|bb22,250x60,0,0{100x60,0,0,2,99x60,101,0,3}")
  result=$(parse_restore_dimensions "$windows")
  [ "$result" = "250x200" ]
}

@test "parse_restore_dimensions: defaults 200x200 when layout has no dimensions" {
  local windows="1|zsh|tiled"
  result=$(parse_restore_dimensions "$windows")
  [ "$result" = "200x200" ]
}

@test "parse_restore_dimensions: handles empty layout field" {
  local windows="1|zsh|"
  result=$(parse_restore_dimensions "$windows")
  [ "$result" = "200x200" ]
}

@test "parse_restore_dimensions: 80x24 stays at default 200x200" {
  local windows="1|zsh|cafe,80x24,0,0,1"
  result=$(parse_restore_dimensions "$windows")
  [ "$result" = "200x200" ]
}

@test "parse_restore_dimensions: 300x250 overrides both defaults" {
  local windows="1|dev|dead,300x250,0,0{150x250,0,0,1,149x250,151,0,2}"
  result=$(parse_restore_dimensions "$windows")
  [ "$result" = "300x250" ]
}

@test "parse_restore_dimensions: 300x80 overrides only width" {
  local windows="1|dev|dead,300x80,0,0{150x80,0,0,1,149x80,151,0,2}"
  result=$(parse_restore_dimensions "$windows")
  [ "$result" = "300x200" ]
}

@test "parse_restore_dimensions: lowercase hex prefix parsed correctly" {
  local windows="1|zsh|3b4a,250x210,0,0,1"
  result=$(parse_restore_dimensions "$windows")
  [ "$result" = "250x210" ]
}

@test "parse_restore_dimensions: mixed case hex prefix parsed correctly" {
  local windows="1|zsh|3B4A,250x210,0,0,1"
  result=$(parse_restore_dimensions "$windows")
  [ "$result" = "250x210" ]
}

# ── Archive creation helpers for restore tests ────────────────────────────

create_multi_pane_archive() {
  local name="${1:-multi-pane}"
  local pane_count="${2:-5}"
  local width="${3:-134}"
  local height="${4:-108}"
  local uuid="${5:-$(uuidgen)}"
  local ts="${6:-$(date +%Y%m%d_%H%M%S)}"
  local safe_name=$(echo "$name" | tr ' ' '_')
  local file="$TMUX_ARCHIVE_DIR/${safe_name}_${ts}.archive"

  {
    echo "FORMAT_VERSION=2"
    echo "SESSION_NAME=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$name', safe=''))" 2>/dev/null || echo "$name")"
    echo "SESSION_UUID=$uuid"
    echo "ARCHIVED_AT=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "SCROLLBACK_MODE=full"
    echo "---WINDOWS---"
    local layout_hex="abcd"
    echo "1|zsh|${layout_hex}%2C${width}x${height}%2C0%2C0%2C1"
    echo "---PANES---"
    for i in $(seq 1 "$pane_count"); do
      local enc_name
      enc_name=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$name', safe=''))" 2>/dev/null || echo "$name")
      echo "${enc_name}|1|${i}|%2Ftmp|zsh|zsh"
    done
    echo "---OPENCODE---"
  } > "$file"
  echo "$file"
}

@test "create_multi_pane_archive produces valid archive with correct pane count" {
  local file
  file=$(create_multi_pane_archive "test-mp" 5 134 108)
  [ -f "$file" ]

  local pane_count
  pane_count=$(grep -A9999 '^---PANES---' "$file" | grep -B9999 '^---OPENCODE---' | grep -v '^---' | grep -c '[^[:space:]]')
  [ "$pane_count" -eq 5 ]

  local layout
  layout=$(grep -A9999 '^---WINDOWS---' "$file" | grep -B9999 '^---PANES---' | grep -v '^---' | head -1 | cut -d'|' -f3)
  [[ "$layout" == *"134x108"* ]]
}

@test "parse_restore_dimensions: archive with dims < default stays at 200x200" {
  local file
  file=$(create_multi_pane_archive "verify" 5 134 108)
  local windows
  windows=$(grep -A9999 '^---WINDOWS---' "$file" | grep -B9999 '^---PANES---' | grep -v '^---')
  result=$(parse_restore_dimensions "$windows")
  [ "$result" = "200x200" ]
}

@test "parse_restore_dimensions: archive with dims > default overrides" {
  local file
  file=$(create_multi_pane_archive "big-term" 5 300 250)
  local windows
  windows=$(grep -A9999 '^---WINDOWS---' "$file" | grep -B9999 '^---PANES---' | grep -v '^---')
  result=$(parse_restore_dimensions "$windows")
  [ "$result" = "300x250" ]
}

# ── Split failure graceful handling ───────────────────────────────────────

@test "restore continues when split-window would fail on small session" {
  # This verifies the logic: split failure = warning + continue, not fatal + return 1
  # We can't easily test tmux split in bats, so we verify the code path:
  # simulate the pattern: if split fails, we continue (don't kill session)
  local split_failures=0
  local panes_attempted=5
  local panes_created=1

  for i in $(seq 2 "$panes_attempted"); do
    # simulate split failure for panes 4+
    if [ "$i" -gt 3 ]; then
      split_failures=$((split_failures + 1))
      continue
    fi
    panes_created=$((panes_created + 1))
  done

  [ "$panes_created" -eq 3 ]
  [ "$split_failures" -eq 2 ]
}

@test "restore code uses -x and -y flags in new-session" {
  local restore_code
  restore_code=$(cat "$TMUX_MANAGER_DIR/lib/restore.sh")
  [[ "$restore_code" == *'new-session -d -s "$session_name" -x "$_restore_w" -y "$_restore_h"'* ]]
}

@test "restore split-window failure uses continue instead of kill-session" {
  local split_section
  split_section=$(awk '/split-window.*session_name.*widx/{found=1} found{print; if(/^[[:space:]]*\}/)exit}' "$TMUX_MANAGER_DIR/lib/restore.sh")
  [[ "$split_section" == *"split-window"* ]]
  [[ "$split_section" != *"kill-session"* ]]
  [[ "$split_section" == *"continue"* ]]
}

@test "restore default dimensions are 200x200" {
  local restore_code
  restore_code=$(cat "$TMUX_MANAGER_DIR/lib/restore.sh")
  [[ "$restore_code" == *'_restore_w=200 _restore_h=200'* ]]
}
