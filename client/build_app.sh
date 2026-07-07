#!/bin/bash
# Build WhisperType.app — a menu-bar app bundle so macOS TCC will grant
# Microphone + Accessibility permissions by stable identity. Ad-hoc signed
# (fine for personal / same-machine use). Run from the client/ directory.
#
#   ./build_app.sh          # build + assemble WhisperType.app
#   open WhisperType.app      # launch it
#
set -euo pipefail
cd "$(dirname "$0")"

APP="WhisperType.app"
BIN_NAME="WhisperType"

echo "==> swift build (release)"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)/$BIN_NAME"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_PATH" "$APP/Contents/MacOS/$BIN_NAME"
cp Info.plist "$APP/Contents/Info.plist"

# Prefer a stable, trusted identity so TCC (Accessibility/Microphone) grants
# persist across rebuilds. Order: Apple Development > self-signed "WhisperType
# Dev" > ad-hoc. Ad-hoc changes identity every build and loses permissions.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Apple Development' | head -1 | awk '{print $2}')"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v 2>/dev/null | grep 'WhisperType Dev' | head -1 | awk '{print $2}')"
fi
SIGN="${IDENTITY:--}"   # fall back to ad-hoc "-" if nothing found

echo "==> codesign with identity: ${IDENTITY:-ad-hoc}"
codesign --force --deep --sign "$SIGN" \
    --options runtime \
    --entitlements <(cat <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
EOF
) "$APP" 2>&1 | tail -2 || codesign --force --deep --sign "$SIGN" "$APP"

echo "==> done: $(pwd)/$APP  (signed: ${IDENTITY:-ad-hoc})"
echo "First run: grant Microphone (prompted) and Accessibility"
echo "(System Settings > Privacy & Security > Accessibility), then relaunch."
