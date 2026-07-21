#!/bin/bash
# One-command install for the WhisperType menu-bar client:
#   1. builds + signs the app (build_app.sh)
#   2. installs it to /Applications
#   3. sets it to auto-start at login (LaunchAgent, RunAtLoad; no KeepAlive so
#      quitting it stays quit)
#
#   ./install.sh            # build, install, enable auto-start, launch
#   ./install.sh --uninstall
#
set -euo pipefail
cd "$(dirname "$0")"

APP="WhisperType.app"
DEST="/Applications/$APP"
LABEL="app.whispertype.client.client"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN="$DEST/Contents/MacOS/WhisperType"

if [ "${1:-}" = "--uninstall" ]; then
    echo "==> uninstalling"
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    osascript -e 'quit app "WhisperType"' 2>/dev/null || true
    pkill -f "$DEST" 2>/dev/null || true
    rm -rf "$DEST"
    echo "==> removed $DEST, login item, and stopped the app. (Server on ms2 untouched.)"
    exit 0
fi

echo "==> building the app"
./build_app.sh

echo "==> installing to /Applications"
osascript -e 'quit app "WhisperType"' 2>/dev/null || true
pkill -f "$DEST" 2>/dev/null || true
sleep 1
rm -rf "$DEST"
cp -R "$APP" "$DEST"
# Keep only ONE app: /Applications is canonical; remove the local build copy so
# there aren't two WhisperTypes floating around.
rm -rf "$APP"

echo "==> enabling auto-start at login"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PL
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"   # RunAtLoad launches it now (and at every login)

echo "==> done. WhisperType is in /Applications and will start at login."
echo "   First run: grant Microphone (prompted) and Accessibility"
echo "   (System Settings ▸ Privacy & Security ▸ Accessibility), then it's ready."
