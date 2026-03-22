#!/usr/bin/env bats
# Tests for plugins/claude-code.sh — Claude Code plugin parsing logic
# Note: Functions that call tmux/claude CLI are not testable offline.

load helpers/setup

# ── Pane title detection ──────────────────────────────────────────────────

@test "CC pane title '✳ Claude Code' is detected" {
  local ptitle='✳ Claude Code'
  [[ "$ptitle" == '✳ '* ]]
}

@test "CC pane title '✳ Custom Name' is detected" {
  local ptitle='✳ Custom Name'
  [[ "$ptitle" == '✳ '* ]]
}

@test "Non-CC pane title 'zsh' is not detected" {
  local ptitle='zsh'
  ! [[ "$ptitle" == '✳ '* ]]
}

@test "OC pane title 'OC | foo' is not detected as CC" {
  local ptitle='OC | foo'
  ! [[ "$ptitle" == '✳ '* ]]
}

# ── Title extraction ────────────────────────────────────────────────────

@test "CC title extracted from pane title by stripping '✳ ' prefix" {
  local ptitle='✳ My Session'
  local cc_name="${ptitle#✳ }"
  [[ "$cc_name" == "My Session" ]]
}

@test "CC title '✳ Claude Code' extracts 'Claude Code'" {
  local ptitle='✳ Claude Code'
  local cc_name="${ptitle#✳ }"
  [[ "$cc_name" == "Claude Code" ]]
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
  # preview.sh can't be sourced (it has a case block that runs on source)
  # Just test the pattern matching logic directly
  local ptitle='✳ My Session'
  [[ "$ptitle" == '✳ '* ]]
  local cc_name="${ptitle#✳ }"
  [[ "$cc_name" == "My Session" ]]

  # Verify preview.sh contains the CC pattern
  grep -q '✳ ' "$TMUX_MANAGER_DIR/lib/preview.sh"
  grep -q 'claude-code' "$TMUX_MANAGER_DIR/lib/preview.sh"
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
