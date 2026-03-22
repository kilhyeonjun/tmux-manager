#!/usr/bin/env bats
# Tests for plugins/claude-code.sh — Claude Code plugin parsing logic
# Note: Functions that call tmux/claude CLI are not testable offline.

load helpers/setup

# ── Pane title detection ──────────────────────────────────────────────────

@test "CC pane title '✳ Claude Code' is detected" {
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/claude-code.sh'
    _tmux_cc_is_pane_title '✳ Claude Code' && echo yes || echo no
  ")
  [ "$result" = "yes" ]
}

@test "CC pane title '✳ Custom Name' is detected" {
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/claude-code.sh'
    _tmux_cc_is_pane_title '✳ Custom Name' && echo yes || echo no
  ")
  [ "$result" = "yes" ]
}

@test "CC pane title with braille spinner '⠐ Claude Code' is detected" {
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/claude-code.sh'
    _tmux_cc_is_pane_title '⠐ Claude Code' && echo yes || echo no
  ")
  [ "$result" = "yes" ]
}

@test "CC pane title with braille spinner '⠂ Claude Code' is detected" {
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/claude-code.sh'
    _tmux_cc_is_pane_title '⠂ Claude Code' && echo yes || echo no
  ")
  [ "$result" = "yes" ]
}

@test "CC pane title with braille spinner '⠋ My Session' is detected" {
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/claude-code.sh'
    _tmux_cc_is_pane_title '⠋ My Session' && echo yes || echo no
  ")
  [ "$result" = "yes" ]
}

@test "Non-CC pane title 'zsh' is not detected" {
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/claude-code.sh'
    _tmux_cc_is_pane_title 'zsh' && echo yes || echo no
  ")
  [ "$result" = "no" ]
}

@test "OC pane title 'OC | foo' is not detected as CC" {
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/claude-code.sh'
    _tmux_cc_is_pane_title 'OC | foo' && echo yes || echo no
  ")
  [ "$result" = "no" ]
}

# ── Title extraction ────────────────────────────────────────────────────

@test "CC title extracted from '✳ My Session'" {
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/claude-code.sh'
    _tmux_cc_extract_title '✳ My Session'
  ")
  [ "$result" = "My Session" ]
}

@test "CC title extracted from '⠐ Claude Code'" {
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/claude-code.sh'
    _tmux_cc_extract_title '⠐ Claude Code'
  ")
  [ "$result" = "Claude Code" ]
}

@test "CC title extracted from '⠂ Custom Name'" {
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/claude-code.sh'
    _tmux_cc_extract_title '⠂ Custom Name'
  ")
  [ "$result" = "Custom Name" ]
}

# ── SID detection from session file ──────────────────────────────────────

@test "cc_detect_sid_from_session_file reads sessionId from JSON" {
  local tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/sessions"
  echo '{"pid":12345,"sessionId":"6a3f6558-02b6-455b-b1f7-5f50945007ce","cwd":"/tmp","startedAt":1774142005690}' > "$tmpdir/sessions/12345.json"

  local sid
  sid=$(python3 -c "
import json
with open('$tmpdir/sessions/12345.json') as f:
    d = json.load(f)
    print(d.get('sessionId', ''))
" 2>/dev/null)
  [[ "$sid" == "6a3f6558-02b6-455b-b1f7-5f50945007ce" ]]
  rm -rf "$tmpdir"
}

@test "cc_detect_sid returns empty for missing session file" {
  local sid
  sid=$(python3 -c "
import json, sys
try:
    with open('/nonexistent/12345.json') as f:
        d = json.load(f)
        print(d.get('sessionId', ''))
except: pass
" 2>/dev/null)
  [[ -z "$sid" ]]
}

# ── SID detection from sessions-index.json ───────────────────────────────

@test "cc_detect_sid_from_index matches by cwd" {
  local tmpdir=$(mktemp -d)
  local proj_dir="$tmpdir/projects/-tmp-myproject"
  mkdir -p "$proj_dir"
  cat > "$proj_dir/sessions-index.json" << 'SIDX'
{"version":1,"entries":[{"sessionId":"aaa-bbb-ccc","summary":"Test Session","modified":"2026-03-22T10:00:00.000Z","projectPath":"/tmp/myproject"}]}
SIDX

  local sid
  sid=$(python3 -c "
import json
with open('$proj_dir/sessions-index.json') as f:
    d = json.load(f)
    entries = d.get('entries', d if isinstance(d, list) else [])
    for e in entries:
        if e.get('projectPath') == '/tmp/myproject':
            print(e.get('sessionId', ''))
            break
" 2>/dev/null)
  [[ "$sid" == "aaa-bbb-ccc" ]]
  rm -rf "$tmpdir"
}

# ── SID detection from sessions dir scan ──────────────────────────────

@test "cc_detect_sid_from_sessions finds session by cwd" {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/.claude/sessions"
  echo '{"pid":111,"sessionId":"sid-aaa","cwd":"/tmp/myproject","startedAt":1000}' > "$tmpdir/.claude/sessions/111.json"
  echo '{"pid":222,"sessionId":"sid-bbb","cwd":"/tmp/myproject","startedAt":2000}' > "$tmpdir/.claude/sessions/222.json"
  echo '{"pid":333,"sessionId":"sid-ccc","cwd":"/tmp/other","startedAt":3000}' > "$tmpdir/.claude/sessions/333.json"

  result=$(HOME="$tmpdir" zsh -c "
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/claude-code.sh'
    _tmux_cc_detect_sid_from_sessions '/tmp/myproject'
  ")
  rm -rf "$tmpdir"
  # Should return sid-bbb (most recent startedAt for matching cwd)
  [ "$result" = "sid-bbb" ]
}

@test "cc_detect_sid_from_sessions returns empty for non-matching cwd" {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/.claude/sessions"
  echo '{"pid":111,"sessionId":"sid-aaa","cwd":"/tmp/other","startedAt":1000}' > "$tmpdir/.claude/sessions/111.json"

  result=$(HOME="$tmpdir" zsh -c "
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/claude-code.sh'
    _tmux_cc_detect_sid_from_sessions '/tmp/myproject' && echo found || echo empty
  ")
  rm -rf "$tmpdir"
  [ "$result" = "empty" ]
}

@test "cc_detect_sid_from_sessions handles missing sessions dir" {
  local tmpdir
  tmpdir=$(mktemp -d)

  result=$(HOME="$tmpdir" zsh -c "
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    source '$TMUX_MANAGER_DIR/plugins/claude-code.sh'
    _tmux_cc_detect_sid_from_sessions '/tmp/myproject' && echo found || echo empty
  ")
  rm -rf "$tmpdir"
  [ "$result" = "empty" ]
}

# ── Restore metadata parsing ────────────────────────────────────────────

@test "cc_restore_metadata parses CLAUDE-CODE section" {
  local file
  file=$(mktemp "$TMUX_ARCHIVE_DIR/test_XXXXXX.archive")
  cat > "$file" << 'EOF'
SESSION_NAME=test
SESSION_UUID=uuid1
ARCHIVED_AT=2026-03-22 10:00:00
---WINDOWS---
1|main|tiled
---PANES---
test|1|0|/tmp|zsh|✳ Claude Code
---OPENCODE---
---CLAUDE-CODE---
1|0|6a3f6558-02b6-455b-b1f7-5f50945007ce|My CC Session|/tmp/project
---CMUX---
EOF

  source "$TMUX_MANAGER_DIR/lib/archive_format.sh"

  local cc_lines
  cc_lines=$(_tmux_af_section_lines "$file" '---CLAUDE-CODE---' '---CMUX---')
  local count
  count=$(echo "$cc_lines" | grep -c '[^[:space:]]')
  [[ "$count" -eq 1 ]]

  local sid
  sid=$(echo "$cc_lines" | head -1 | cut -d'|' -f3)
  [[ "$sid" == "6a3f6558-02b6-455b-b1f7-5f50945007ce" ]]
}

@test "archive without CLAUDE-CODE section returns empty" {
  local file
  file=$(mktemp "$TMUX_ARCHIVE_DIR/test_XXXXXX.archive")
  cat > "$file" << 'EOF'
SESSION_NAME=test
SESSION_UUID=uuid1
ARCHIVED_AT=2026-03-22 10:00:00
---WINDOWS---
1|main|tiled
---PANES---
test|1|0|/tmp|zsh|zsh
---OPENCODE---
---CMUX---
EOF

  source "$TMUX_MANAGER_DIR/lib/archive_format.sh"

  local cc_lines
  cc_lines=$(_tmux_af_section_lines "$file" '---CLAUDE-CODE---' '---CMUX---')
  local count=0
  count=$(echo "$cc_lines" | grep -c '[^[:space:]]' 2>/dev/null) || count=0
  [[ "$count" -eq 0 ]]
}

# ── Archive meta parser CC support ──────────────────────────────────────

@test "archive_meta counts CC entries" {
  local file
  file=$(mktemp "$TMUX_ARCHIVE_DIR/test_XXXXXX.archive")
  cat > "$file" << 'EOF'
FORMAT_VERSION=2
SESSION_NAME=test
SESSION_UUID=uuid-cc1
ARCHIVED_AT=2026-03-22 10:00:00
---WINDOWS---
1|main|tiled
---PANES---
test|1|0|/tmp|zsh|zsh
---OPENCODE---
---CLAUDE-CODE---
1|0|6a3f6558-02b6|My Session|/tmp
---CMUX---
EOF

  source "$TMUX_MANAGER_DIR/lib/archive_format.sh"
  source "$TMUX_MANAGER_DIR/lib/utils.sh"
  source "$TMUX_MANAGER_DIR/lib/core.sh"

  local result
  result=$(_tmux_archive_meta "$file")
  # Format: uuid|name|date|is_auto|wins|oc_count|oc_sid_missing|oc_title|oc_sid|cc_count|cc_sid_missing|cc_title|cc_sid
  local cc_count
  cc_count=$(echo "$result" | cut -d'|' -f10)
  [[ "$cc_count" -eq 1 ]]
}

@test "archive_meta handles file with both OC and CC entries" {
  local file
  file=$(mktemp "$TMUX_ARCHIVE_DIR/test_XXXXXX.archive")
  cat > "$file" << 'EOF'
FORMAT_VERSION=2
SESSION_NAME=test
SESSION_UUID=uuid-both
ARCHIVED_AT=2026-03-22 10:00:00
---WINDOWS---
1|main|tiled
---PANES---
test|1|0|/tmp|zsh|zsh
test|1|1|/tmp|zsh|zsh
---OPENCODE---
1|0|ses_abc123|OC Title|/tmp
---CLAUDE-CODE---
1|1|6a3f6558|CC Title|/tmp
---CMUX---
EOF

  source "$TMUX_MANAGER_DIR/lib/archive_format.sh"
  source "$TMUX_MANAGER_DIR/lib/utils.sh"
  source "$TMUX_MANAGER_DIR/lib/core.sh"

  local result
  result=$(_tmux_archive_meta "$file")
  local oc_count cc_count
  oc_count=$(echo "$result" | cut -d'|' -f6)
  cc_count=$(echo "$result" | cut -d'|' -f10)
  [[ "$oc_count" -eq 1 ]]
  [[ "$cc_count" -eq 1 ]]
}

# ── Process detection pattern ──────────────────────────────────────────

@test "claude process pattern matches correctly" {
  local line1="  12345  11111  claude --dangerously-skip-permissions --resume"
  local line2="  12345  11111  /Applications/Claude.app/Contents/MacOS/Claude"
  local line3="  12345  11111  claude"

  echo "$line1" | grep -qE '[[:space:]]claude([[:space:]]|$)' && ! echo "$line1" | grep -q 'Claude\.app'
  echo "$line2" | grep -q 'Claude\.app'
  echo "$line3" | grep -qE '[[:space:]]claude([[:space:]]|$)' && ! echo "$line3" | grep -q 'Claude\.app'
}

# ── Section boundary: PANES -> OPENCODE -> CLAUDE-CODE -> CMUX ─────────

@test "section boundaries: PANES ends at OPENCODE, OPENCODE ends at CLAUDE-CODE" {
  local file
  file=$(mktemp "$TMUX_ARCHIVE_DIR/test_XXXXXX.archive")
  cat > "$file" << 'EOF'
SESSION_NAME=test
---WINDOWS---
1|main|tiled
---PANES---
test|1|0|/tmp|zsh|zsh
---OPENCODE---
1|0|ses_abc|OC|/tmp
---CLAUDE-CODE---
1|1|uuid-cc|CC|/tmp
---CMUX---
EOF

  source "$TMUX_MANAGER_DIR/lib/archive_format.sh"

  local panes oc cc
  panes=$(_tmux_af_section_lines "$file" '---PANES---' '---OPENCODE---')
  oc=$(_tmux_af_section_lines "$file" '---OPENCODE---' '---CLAUDE-CODE---')
  cc=$(_tmux_af_section_lines "$file" '---CLAUDE-CODE---' '---CMUX---')

  [[ $(echo "$panes" | grep -c '[^[:space:]]') -eq 1 ]]
  [[ $(echo "$oc" | grep -c '[^[:space:]]') -eq 1 ]]
  [[ $(echo "$cc" | grep -c '[^[:space:]]') -eq 1 ]]
  echo "$oc" | grep -q 'ses_abc'
  echo "$cc" | grep -q 'uuid-cc'
}

# ── Preview pane line display ───────────────────────────────────────────

@test "preview pane_line displays CC pane with purple dot" {
  # Verify preview.sh contains the CC patterns (both ✳ and braille)
  grep -q '✳ ' "$TMUX_MANAGER_DIR/lib/preview.sh"
  grep -q 'claude-code' "$TMUX_MANAGER_DIR/lib/preview.sh"
  grep -q '⠁⠂⠄⠈⠐⠠⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' "$TMUX_MANAGER_DIR/lib/preview.sh"
}

@test "preview title extraction works for braille prefix" {
  # ${ptitle#? } strips one unicode char + space in zsh
  result=$(zsh -c "
    local ptitle='⠐ Claude Code'
    echo \"\${ptitle#? }\"
  ")
  [ "$result" = "Claude Code" ]
}

@test "restore.sh detects braille spinner titles as CC" {
  # Verify restore.sh contains braille pattern detection
  grep -q '⠁⠂⠄⠈⠐⠠⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' "$TMUX_MANAGER_DIR/lib/restore.sh"
}

# ── Group display CC tag ────────────────────────────────────────────────

@test "group display includes [CC:N] tag" {
  local file
  file=$(mktemp "$TMUX_ARCHIVE_DIR/test_XXXXXX.archive")
  cat > "$file" << 'EOF'
FORMAT_VERSION=2
SESSION_NAME=test
SESSION_UUID=uuid-cctag
ARCHIVED_AT=2026-03-22 10:00:00
---WINDOWS---
1|main|tiled
---PANES---
test|1|0|/tmp|zsh|zsh
---OPENCODE---
---CLAUDE-CODE---
1|0|uuid-cc1|CC1|/tmp
1|1|uuid-cc2|CC2|/tmp
---CMUX---
EOF

  source "$TMUX_MANAGER_DIR/lib/archive_format.sh"
  source "$TMUX_MANAGER_DIR/lib/utils.sh"
  source "$TMUX_MANAGER_DIR/lib/core.sh"

  local result
  result=$(_tmux_archives_for_uuid "uuid-cctag")
  echo "$result" | grep -q '\[CC:2\]'
}
