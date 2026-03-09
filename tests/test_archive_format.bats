#!/usr/bin/env bats

load helpers/setup

@test "archive format helpers escape and unescape round-trip" {
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    raw='a|b%/c'
    esc=\$(_tmux_af_escape "\$raw")
    dec=\$(_tmux_af_unescape "\$esc")
    echo "RAW=\$raw"
    echo "ESC=\$esc"
    echo "DEC=\$dec"
  ")

  [[ "$result" == *"ESC="*"%7C"* ]]
  [[ "$result" == *"DEC=a|b%/c"* ]]
}

@test "archive header get decodes v2 encoded session name" {
  local file="$TMUX_ARCHIVE_DIR/v2_header.archive"
  cat > "$file" << 'EOF'
FORMAT_VERSION=2
SESSION_NAME=my%7Cproj%25name
SESSION_UUID=u-1
ARCHIVED_AT=2025-01-01 12:00:00
---WINDOWS---
1|main|tiled
---PANES---
my|1|0|/tmp|zsh|zsh
---OPENCODE---
EOF

  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    _tmux_af_header_get '$file' SESSION_NAME
  ")
  [ "$result" = "my|proj%name" ]
}

@test "archive section parser works when OPENCODE marker is missing" {
  local file="$TMUX_ARCHIVE_DIR/no_oc_marker.archive"
  cat > "$file" << 'EOF'
SESSION_NAME=no-oc
SESSION_UUID=uuid-x
ARCHIVED_AT=2025-01-01 12:00:00
---WINDOWS---
1|main|tiled
---PANES---
no-oc|1|0|/tmp|zsh|zsh
no-oc|1|1|/tmp|vim|vim
EOF

  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    _tmux_af_section_lines '$file' '---PANES---' '---OPENCODE---' | grep -c '[^[:space:]]'
  ")
  [ "$result" -eq 2 ]
}

@test "set_session_name_copy safely replaces special characters" {
  local src="$TMUX_ARCHIVE_DIR/src.archive"
  local dst="$TMUX_ARCHIVE_DIR/dst.archive"
  cat > "$src" << 'EOF'
FORMAT_VERSION=2
SESSION_NAME=old
SESSION_UUID=u-1
ARCHIVED_AT=2025-01-01 12:00:00
---WINDOWS---
1|main|tiled
---PANES---
old|1|0|/tmp|zsh|zsh
---OPENCODE---
EOF

  run zsh -c "
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    _tmux_af_set_session_name_copy '$src' '$dst' 'new/&|name'
  "
  [ "$status" -eq 0 ]

  decoded=$(zsh -c "
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    _tmux_af_header_get '$dst' SESSION_NAME
  ")
  [ "$decoded" = "new/&|name" ]
}

@test "archive header get keeps literal value for invalid format version" {
  local file="$TMUX_ARCHIVE_DIR/invalid_fmt.archive"
  cat > "$file" << 'EOF'
FORMAT_VERSION=abc
SESSION_NAME=legacy%7Cname%25x
SESSION_UUID=u-legacy
ARCHIVED_AT=2025-01-01 12:00:00
---WINDOWS---
1|main|tiled
---PANES---
legacy|1|0|/tmp|zsh|zsh
---OPENCODE---
EOF

  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    _tmux_af_header_get '$file' SESSION_NAME
  ")
  [ "$result" = "legacy%7Cname%25x" ]
}

@test "set_session_name_copy appends SESSION_NAME when header is missing" {
  local src="$TMUX_ARCHIVE_DIR/no_name_src.archive"
  local dst="$TMUX_ARCHIVE_DIR/no_name_dst.archive"
  cat > "$src" << 'EOF'
FORMAT_VERSION=1
SESSION_UUID=u-no-name
ARCHIVED_AT=2025-01-01 12:00:00
---WINDOWS---
1|main|tiled
---PANES---
tmp|1|0|/tmp|zsh|zsh
---OPENCODE---
EOF

  run zsh -c "
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    _tmux_af_set_session_name_copy '$src' '$dst' 'inserted-name'
  "
  [ "$status" -eq 0 ]

  run grep -c '^SESSION_NAME=inserted-name$' "$dst"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "archive unescape tolerates malformed percent sequence" {
  result=$(zsh -c "
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    _tmux_af_unescape 'bad%ZZvalue%2Fok'
  ")
  [ "$result" = "bad%ZZvalue/ok" ]
}

@test "archive format v2 requires working python3 runtime" {
  local fakebin
  fakebin=$(mktemp -d -t tmux_fake_python)
  cat > "$fakebin/python3" << 'EOF'
#!/usr/bin/env bash
exit 127
EOF
  chmod +x "$fakebin/python3"

  run zsh -c "
    export PATH='$fakebin':\"\$PATH\"
    source '$TMUX_MANAGER_DIR/lib/archive_format.sh'
    _tmux_af_require_python3 'v2 test'
  "
  [ "$status" -eq 1 ]
  [[ "$output" == *"python3"* ]]

  rm -rf "$fakebin"
}
