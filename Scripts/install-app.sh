#!/usr/bin/env bash
# Build ClaudeTop.app and put it in /Applications.
#
# The app has to live somewhere macOS will vouch for before it can register itself as a
# login item; a bundle run out of a build directory is refused. Nothing else is installed
# and nothing is enabled: start-at-login is a toggle in the app's own panel, so it appears
# in System Settings under Login Items where you can revoke it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="${1:-/Applications}"
APP="$DESTINATION/ClaudeTop.app"

"$ROOT/Scripts/make-app.sh" release >/dev/null

[ -d "$DESTINATION" ] || { echo "no such directory: $DESTINATION" >&2; exit 1; }
[ -w "$DESTINATION" ] || { echo "$DESTINATION is not writable by you" >&2; exit 1; }

# Staged beside the destination and moved into place, never written over in place.
# Overwriting a signed bundle leaves the kernel holding a signature for contents that are
# no longer there, and every later launch is killed outright while `codesign -v` still
# reports the bundle as valid.
STAGING="$DESTINATION/.ClaudeTop.app.incoming"
rm -rf "$STAGING" 2>/dev/null || true
ditto "$ROOT/build/ClaudeTop.app" "$STAGING"

if [ -d "$APP" ]; then
  PREVIOUS="$DESTINATION/.ClaudeTop.app.previous"
  rm -rf "$PREVIOUS" 2>/dev/null || true
  mv "$APP" "$PREVIOUS"
fi
mv "$STAGING" "$APP"
rm -rf "$DESTINATION/.ClaudeTop.app.previous" 2>/dev/null || true

echo "installed $APP"
echo
echo "open it:            open \"$APP\""
echo "start at login:     the toggle at the bottom of its panel"
echo "revoke that later:  System Settings > General > Login Items"
