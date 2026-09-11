#!/usr/bin/env bash
# Install the unattended reaper as a LaunchAgent.
#
# This is the only thing in the project that stops processes with nobody looking, so it is
# opt-in, it is narrower than every other path, and it is installed by running this on
# purpose rather than by anything happening automatically.
#
# What it will stop: processes carrying the env stamp of a Claude session that has exited,
# and Compose projects belonging to that session's worktree, and only once that worktree
# has been *continuously observed* with no session for the quarantine period. Nothing else
# is ever a candidate. Live sessions, Testcontainers clusters, unlabelled containers and
# anything under a `.claude-top-keep` file are all excluded by construction.
#
# Touches exactly one file: ~/Library/LaunchAgents/com.claudetop.autoreap.plist
set -euo pipefail

LABEL="com.claudetop.autoreap"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BINARY="${1:-/usr/local/bin/claude-top}"
QUARANTINE="${2:-8h}"

if [ ! -x "$BINARY" ]; then
  echo "no claude-top binary at $BINARY" >&2
  echo "usage: Scripts/install-autoreap.sh [/path/to/claude-top] [quarantine, default 8h]" >&2
  exit 1
fi

# Ten minutes, not thirty. The quarantine clock only advances while something is watching,
# and a gap longer than half an hour restarts it, so the job that reads the clock has to
# run often enough to keep it. Each run is a fraction of a second.
cat > "$PLIST" <<PLIST_END
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BINARY</string>
        <string>--auto-reap</string>
        <string>--older-than</string>
        <string>$QUARANTINE</string>
    </array>
    <key>StartInterval</key>
    <integer>600</integer>
    <key>RunAtLoad</key>
    <false/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>LowPriorityIO</key>
    <true/>
    <key>Nice</key>
    <integer>5</integer>
    <key>StandardOutPath</key>
    <string>$HOME/.claude/state/claude-top-autoreap.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/.claude/state/claude-top-autoreap.log</string>
</dict>
</plist>
PLIST_END

mkdir -p "$HOME/.claude/state"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"

echo "installed $LABEL"
echo "  checks every 10 minutes, stops nothing until a worktree has been abandoned $QUARANTINE"
echo "  at most 3 worktrees per run, so a mistake stays small enough to notice"
echo
echo "see what it would do:   claude-top --auto-reap --older-than $QUARANTINE --dry-run"
echo "what it has done:       cat ~/.claude/state/reap.log"
echo "its own output:         cat ~/.claude/state/claude-top-autoreap.log"
echo "remove it:              Scripts/uninstall-autoreap.sh"
