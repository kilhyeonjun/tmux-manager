# tmux-manager

A modular tmux session archiver, restorer, and manager with an interactive fzf UI.

Archive your tmux sessions — windows, panes, scrollback, layouts — and restore them later. Supports UUID-based session grouping, auto-archiving via cron, and an optional [OpenCode](https://github.com/opencode-ai/opencode) plugin for capturing AI coding sessions.

## Features

- **Session archiving** — Save all windows, panes, layouts, scrollback, and working directories
- **Session restore** — Recreate archived sessions with original structure and scrollback
- **UUID grouping** — Sessions are tracked by UUID, so renames don't break archive history
- **Interactive manager** — fzf-powered UI for browsing, restoring, and deleting archives
- **Auto-archive** — Cron/LaunchAgent support for periodic snapshots
- **Auto-cleanup** — Configurable per-UUID max and optional age-based expiry
- **Status bar integration** — Git branch, process metrics (CPU/MEM), and archive age in tmux pane borders
- **Plugin system** — OpenCode plugin included; core works independently without plugins

## Requirements

- **zsh** (primary shell)
- **tmux** ≥ 3.2
- **fzf** — interactive selection UI
- **macOS** (primary target; Linux should work but is untested)

## Installation

```zsh
git clone https://github.com/kilhyeonjun/tmux-manager.git ~/tmux-manager
```

Add to your `~/.zshrc`:

```zsh
source ~/tmux-manager/init.sh
```

This will:
1. Load configuration defaults
2. Source core libraries and any plugins in `plugins/`
3. Register tmux hooks (UUID assignment, status refresh) when inside tmux
4. Auto-launch the session manager when opening a new terminal outside tmux

### Hook Registration

For sessions created before `init.sh` is sourced (e.g., the very first tmux session), add to your `~/.tmux.conf` or `~/.tmux.conf.local`:

```tmux
# Replace ~/tmux-manager with your actual install path
set-hook -g session-created "run-shell '~/tmux-manager/hooks/on-session-created.sh \"#{hook_session_name}\"'"
```

## Usage

### CLI: `tmux-archive`

```
tmux-archive save [session]          # Archive a session (interactive if no arg)
tmux-archive save-and-kill [session] # Archive then kill the session
tmux-archive restore [file]          # Restore from an archive file (interactive if no arg)
tmux-archive list                    # List all archives
tmux-archive delete [file]           # Delete an archive (interactive if no arg)
```

### Interactive Manager: `tmux-manager`

Run `tmux-manager` (or just open a new terminal — it auto-launches).

**Level 1 — Session list** (active sessions):
| Key | Action |
|-----|--------|
| `Enter` | Attach/switch to session |
| `Ctrl+N` | Create new session |
| `Ctrl+R` | Rename session |
| `Ctrl+D` | Archive + delete session |
| `Ctrl+A` | Open archive manager |
| `ESC` | Exit |

**Level 2 — Archive manager** (UUID groups):
| Key | Action |
|-----|--------|
| `Enter` | Browse group snapshots |
| `Ctrl+S` | Save new archive |
| `Ctrl+X` | Delete entire group |
| `Ctrl+L` | Refresh |
| `ESC` | Back |

**Level 3 — Snapshot list** (individual archives within a group):
| Key | Action |
|-----|--------|
| `Enter` | Restore snapshot |
| `Ctrl+D` | Delete single archive |
| `Ctrl+X` | Delete entire group |
| `Ctrl+L` | Refresh |
| `ESC` | Back |

### Auto-Archive (Cron)

Schedule `cron/autoarchive.sh` to periodically snapshot all active sessions:

```zsh
# Every 30 minutes
*/30 * * * * /path/to/tmux-manager/cron/autoarchive.sh
```

Or with a macOS LaunchAgent (`~/Library/LaunchAgents/com.tmux-manager.autoarchive.plist`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.tmux-manager.autoarchive</string>
    <key>ProgramArguments</key>
    <array>
        <string>/path/to/tmux-manager/cron/autoarchive.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>1800</integer>
</dict>
</plist>
```

## Configuration

Override defaults in your `~/.zshrc` **before** sourcing `init.sh`:

```zsh
# Archive storage location (default: ~/.tmux/archives)
export TMUX_ARCHIVE_DIR="$HOME/.tmux/archives"

# Auto-archive scrollback lines (default: 200)
export TMUX_ARCHIVE_AUTO_SCROLLBACK_LINES=200

# Max auto-archives per UUID before cleanup (default: 10)
export TMUX_ARCHIVE_AUTO_MAX_PER_UUID=10

# Delete auto-archives older than N days; 0 = disabled (default: 0)
export TMUX_ARCHIVE_AUTO_MAX_AGE_DAYS=0

# Enable auto-archive cleanup (default: 1)
export TMUX_ARCHIVE_AUTO_CLEANUP=1

# Status bar refresh debounce in seconds (default: 2)
export TMUX_MANAGER_DEBOUNCE_SEC=2

source ~/tmux-manager/init.sh
```

## Archive File Format

Archives are plain text files with `|`-delimited fields:

```
SESSION_NAME=my-project
SESSION_UUID=XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
ARCHIVED_AT=2025-02-26 20:30:00
AUTO_ARCHIVED=true
SCROLLBACK_MODE=recent
SCROLLBACK_LINES=200
---WINDOWS---
1|editor|main-vertical
2|terminal|even-horizontal
---PANES---
my-project|1|0|/Users/me/project|nvim|editor
my-project|1|1|/Users/me/project|zsh|terminal
my-project|2|0|/Users/me/project|zsh|terminal
---OPENCODE---
1|1|ses_abc123|My AI Chat|/Users/me/project
```

Scrollback content is stored in separate `.pane` files alongside the `.archive` file.

## Plugin System

Plugins are zsh scripts placed in `plugins/`. They are auto-sourced by `init.sh`.

### Core ↔ Plugin Interface

The core checks for plugin functions using `typeset -f`:

```zsh
if typeset -f _tmux_oc_capture_session > /dev/null 2>&1; then
    _tmux_oc_capture_session "$session" "$file" "$base"
fi
```

If no plugin defines the function, the call is silently skipped.

### OpenCode Plugin

The included `plugins/opencode.sh` provides:

- **Capture**: Detects OpenCode panes by title (`OC | ...`), resolves session IDs from scrollback, enriches metadata via `opencode export`
- **Restore metadata**: Sets `@oc_saved_*` tmux session options for status bar display
- **Pane setup**: Restores OC pane titles and prepares restart commands
- **Restart prompt**: After restore, offers to auto-launch OpenCode sessions on attach

Plugin functions communicate with the core via **zsh dynamic scoping** — the restore function declares local variables that plugin functions modify directly.

### Writing a Plugin

Create `plugins/my-plugin.sh`:

```zsh
# Called during tmux-archive save, after ---OPENCODE--- header
_tmux_my_capture() {
    local session="$1" file="$2" base="$3"
    # Append custom data to $file
}

# Called during tmux-archive restore
_tmux_my_restore() {
    local file="$1" session_name="$2"
    # Read custom data from $file, set up session
}
```

## Project Structure

```
tmux-manager/
├── init.sh                    # Entrypoint (source from .zshrc)
├── conf/defaults.conf         # Default configuration
├── lib/
│   ├── utils.sh               # Common utilities
│   ├── metrics.sh             # BFS process tree CPU/MEM metrics
│   ├── core.sh                # Archive CRUD, groups, fzf manager UI
│   ├── restore.sh             # Session restore logic
│   ├── status.sh              # Status bar refresh (standalone, called by tmux)
│   └── preview.sh             # fzf preview panels (standalone, called by fzf)
├── plugins/
│   └── opencode.sh            # OpenCode AI session support
├── hooks/
│   ├── tmux-hooks.conf        # Hook registration (sourced inside tmux)
│   └── on-session-created.sh  # UUID assignment helper
├── cron/
│   └── autoarchive.sh         # Cron/LaunchAgent script
└── tests/
    ├── helpers/setup.bash     # Test fixtures
    ├── test_core.bats         # Core function tests
    ├── test_metrics.bats      # Metrics tests
    └── test_status.bats       # Status + validation tests
```

## Migration from Monolithic Scripts

If you're migrating from standalone `~/.tmux-functions.sh` / `~/.tmux-status.sh` / etc.:

1. Clone this repo and source `init.sh` in your `~/.zshrc` (replacing the old `source ~/.tmux-functions.sh`)
2. Remove old source lines for `~/.tmux-status.sh`, `~/.tmux-preview.sh`, `~/.tmux-autoarchive.sh`
3. Update `.tmux.conf.local` hook paths to point to `tmux-manager/hooks/on-session-created.sh`
4. Update tmux `#()` calls for status/preview to use `tmux-manager/lib/status.sh` and `tmux-manager/lib/preview.sh`
5. Existing archive files are fully backward-compatible — no migration needed

## License

MIT
