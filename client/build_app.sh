#!/bin/bash
# Build VoiceFlow.app — a menu-bar app bundle so macOS TCC will grant
# Microphone + Accessibility permissions by stable identity. Ad-hoc signed
# (fine for personal / same-machine use). Run from the client/ directory.
#
#   ./build_app.sh          # build + assemble VoiceFlow.app
#   open VoiceFlow.app      # launch it
#
set -euo pipefail
cd "$(dirname "$0")"

APP="VoiceFlow.app"
BIN_NAME="VoiceFlow"

# Keep the churny build output OUTSIDE the source tree (default: a Caches dir).
# The project lives in OneDrive; syncing hundreds of MB of build artifacts is
# what corrupted the checkout, so builds write here instead and never sync.
SCRATCH="${VF_SCRATCH:-$HOME/Library/Caches/voiceflow-build}"
mkdir -p "$SCRATCH"

echo "==> swift build (release, scratch=$SCRATCH)"
swift build -c release --scratch-path "$SCRATCH"
BIN_PATH="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/$BIN_NAME"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$BIN_NAME"
cp Info.plist "$APP/Contents/Info.plist"

# Stamp the build. VERSION is the single source of truth for the release
# number; CFBundleVersion carries the commit so a running app can always be
# traced back to the exact source -- 109 commits shipped as "0.1" with no way
# to tell which one you were running, which made every regression report start
# from guesswork.
VF_VERSION="$(cat ../VERSION 2>/dev/null || echo 0.0.0)"
VF_BUILD="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then VF_BUILD="$VF_BUILD-dirty"; fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VF_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VF_BUILD" "$APP/Contents/Info.plist"
echo "==> stamped $VF_VERSION ($VF_BUILD)"
[ -f icon/AppIcon.icns ] && cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# SPM emits a resource bundle beside the binary; the fonts live there. Copy the
# TTFs into Contents/Resources so CTFontManagerRegisterFontsForURL can find them.
BIN_DIR="$(dirname "$BIN_PATH")"
find "$BIN_DIR" -name "*.bundle" -maxdepth 1 -print0 2>/dev/null | while IFS= read -r -d '' b; do
  find "$b" -name "Inter-*.ttf" -exec cp {} "$APP/Contents/Resources/" \; 2>/dev/null || true
done
[ -d Sources/VoiceFlow/Resources ] && cp Sources/VoiceFlow/Resources/Inter-*.ttf "$APP/Contents/Resources/" 2>/dev/null || true

# Prefer a stable, trusted identity so TCC (Accessibility/Microphone) grants
# persist across rebuilds. Order: Apple Development > self-signed "VoiceFlow
# Dev" > ad-hoc. Ad-hoc changes identity every build and loses permissions.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Apple Development' | head -1 | awk '{print $2}')"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v 2>/dev/null | grep 'VoiceFlow Dev' | head -1 | awk '{print $2}')"
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
