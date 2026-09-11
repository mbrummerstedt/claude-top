#!/usr/bin/env bash
# Install the sampler as a LaunchAgent.
#
# A short-lived job on a 15 second interval, not a resident daemon. Nothing sits in RAM
# between ticks, a crash self-heals on the next one, and there is no long-running process
# to audit later.
#
# Touches exactly one file: ~/Library/LaunchAgents/com.claudetop.sampler.plist.
set -euo pipefail

# Commands are called by absolute path where a shadowed one would hang. An exported
# shell function is inherited by a script, so a `cat` wrapped around a pager turns a
# heredoc into a process waiting on a terminal that is not there.

LABEL="com.claudetop.sampler"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BINARY="${1:-$(cd "$(dirname "$0")/.." && pwd)/.build/release/claude-top}"

if [ ! -x "$BINARY" ]; then
  echo "no claude-top binary at $BINARY" >&2
  echo "build it first:  swift build -c release" >&2
  echo "or pass a path:  Scripts/install-agent.sh /usr/local/bin/claude-top" >&2
  exit 1
fi

# The path is pinned absolutely on purpose. launchd inherits none of an interactive
# shell's PATH, and a machine with version managers early in that PATH would resolve a
# different binary, or none at all.
mkdir -p "$HOME/Library/LaunchAgents"
/bin/cat > "$PLIST" <<PLIST_END
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
        <string>--sample</string>
    </array>
    <key>StartInterval</key>
    <integer>15</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>LowPriorityIO</key>
    <true/>
    <key>Nice</key>
    <integer>5</integer>
    <key>StandardErrorPath</key>
    <string>$HOME/.claude/state/claude-top-sampler.log</string>
</dict>
</plist>
PLIST_END

mkdir -p "$HOME/.claude/state"

# Replacing an existing job, so unload first. Failure here means it was not loaded.
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"

echo "installed $LABEL, sampling every 15s"
echo "  binary:  $BINARY"
echo "  plist:   $PLIST"
echo "  store:   $HOME/.claude/state/resources.db"
echo
echo "check it:      claude-top --since 5m"
echo "remove it:     Scripts/uninstall-agent.sh"
