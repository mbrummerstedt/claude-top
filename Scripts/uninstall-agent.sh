#!/usr/bin/env bash
# Remove the sampler LaunchAgent.
#
# Removes exactly one file and nothing else. The database and the reap log are left where
# they are: they are your history, and this script does not get to decide you are done
# with them. Both paths are printed so you can remove them yourself if you want to.
set -euo pipefail

LABEL="com.claudetop.sampler"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true

if [ -f "$PLIST" ]; then
  rm "$PLIST"
  echo "removed $PLIST"
else
  echo "nothing installed at $PLIST"
fi

echo
echo "left in place, remove yourself if you want them gone:"
echo "  $HOME/.claude/state/resources.db"
echo "  $HOME/.claude/state/reap.log"
