#!/usr/bin/env bash
# Remove the unattended reaper.
#
# Removes one file and stops the job. The reap log stays where it is: it is the record of
# what was stopped and this script does not get to decide you are done with it.
set -euo pipefail

LABEL="com.claudetop.autoreap"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
if [ -f "$PLIST" ]; then
  rm "$PLIST"
  echo "removed $PLIST"
else
  echo "nothing installed at $PLIST"
fi
echo
echo "left in place: $HOME/.claude/state/reap.log"
