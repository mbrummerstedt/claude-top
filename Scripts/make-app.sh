#!/usr/bin/env bash
# Assemble ClaudeTop.app from `swift build` output plus an Info.plist.
#
# There is no Xcode project on purpose. A MenuBarExtra app needs no storyboards or nibs,
# and keeping everything in SPM means every file is reviewable in a diff and buildable
# from a terminal, which matters when an agent is doing the implementation.
#
# Writes only into build/ inside this repository. Nothing is installed and nothing outside
# it is touched; drag the result to /Applications yourself if you want it there.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-release}"
APP="$ROOT/build/ClaudeTop.app"
BINARY="$ROOT/.build/$CONFIGURATION/ClaudeTopApp"

swift build -c "$CONFIGURATION" --product ClaudeTopApp

[ -x "$BINARY" ] || { echo "no binary at $BINARY" >&2; exit 1; }

# The only path this script may clear, checked rather than assumed. A build script that
# deletes is one variable expansion away from deleting something else, and this one runs
# on a machine where that would matter.
case "$APP" in
  */build/ClaudeTop.app) ;;
  *) echo "refusing to clear an unexpected path: $APP" >&2; exit 1 ;;
esac
[ -e "$APP" ] && chmod -R u+w "$APP" && find "$APP" -mindepth 1 -delete

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/ClaudeTop"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>ClaudeTop</string>
    <key>CFBundleDisplayName</key>
    <string>ClaudeTop</string>
    <key>CFBundleIdentifier</key>
    <string>dev.claudetop.ClaudeTop</string>
    <key>CFBundleExecutable</key>
    <string>ClaudeTop</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Ad-hoc signing, which is enough to run locally. A build that opens on someone else's
# machine without a Gatekeeper warning needs a Developer ID certificate and notarization,
# which needs the paid Apple Developer Program. The App Sandbox stays off either way:
# reading other processes' environments and shelling out to docker are both incompatible
# with it, which also rules out the Mac App Store.
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null \
  || echo "note: ad-hoc signing failed, the app will still run locally" >&2

echo "built $APP"
echo
echo "run it:   open \"$APP\""
echo "quit it:  osascript -e 'tell application \"ClaudeTop\" to quit'"
