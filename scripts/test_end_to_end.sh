#!/bin/bash
# Real speech in, real text on screen -- the acceptance test that was missing.
#
# Every release up to v0.8.1 was certified by unit tests, request contracts and a
# server health check. None of them touched the path the speaker actually uses,
# because it was assumed to need a human at a microphone. macOS synthesises the
# speech and an ordinary AppKit process receives the insertion, so the whole loop
# runs unattended.
#
# Covers: server transcription and polishing of real audio, the local insertion
# transaction against a real accessibility tree, the receipt, and the wall clock
# the speaker actually waits.
# Does NOT cover: microphone capture (no device is opened) and Screen Sharing
# insertion (needs the paired agent on a second Mac).
#
# Requires Accessibility for the terminal running it, and steals focus for a
# couple of seconds while the target window is up.
#
# NOT part of the default gate, and never run it casually: it opens a window and
# TAKES FOCUS for a few seconds. Run it deliberately, when the Mac is free.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="${VF_SERVER:-$(defaults read com.whispertype.client vf_serverURL 2>/dev/null || echo http://127.0.0.1:8790)}"
echo "==> this test takes over the screen for about 20 seconds"
SCRATCH="$(mktemp -d /tmp/vf-e2e.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT

SPEECH="${VF_SPEECH:-So basically, um, I think we should ship the thing by Friday. Can you please check the numbers, the numbers, before you send it?}"
echo "==> synthesising the dictation"
say -v "${VF_VOICE:-Daniel}" -o "$SCRATCH/speech.aiff" "$SPEECH"
afconvert -f WAVE -d LEI16@16000 -c 1 "$SCRATCH/speech.aiff" "$SCRATCH/speech.wav"

# Success is the compiler's exit status. Deciding it from a grep is the bug that
# let scripts/test_client.sh pass a build it had never checked.
echo "==> building the target application and the driver"
build() {
    local out="$1"; shift
    if ! swiftc -O "$@" -o "$out" >"$SCRATCH/build.log" 2>&1; then
        echo "BUILD FAILED:"; grep -E "error:" "$SCRATCH/build.log" | head -10; exit 1
    fi
}
# The target must be a real .app: an unbundled executable never becomes the
# frontmost application, so the focused-application query returns nothing and
# there is no destination to insert into (observed as ax=-25204).
APP="$SCRATCH/InsertionTarget.app"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>InsertionTarget</string>
  <key>CFBundleIdentifier</key><string>com.whispertype.test.insertiontarget</string>
  <key>CFBundleExecutable</key><string>InsertionTarget</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
build "$APP/Contents/MacOS/InsertionTarget" "$ROOT/tests/live/InsertionTarget.swift"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
build "$SCRATCH/acceptance" -parse-as-library \
    "$ROOT/client/Sources/WhisperTypeKit/AudioUpload.swift" \
    "$ROOT/client/Sources/WhisperType/CaptureDestination.swift" \
    "$ROOT/client/Sources/WhisperType/NativePasteInserter.swift" \
    "$ROOT/tests/live/EndToEndAcceptance.swift"

echo "==> dictating against $SERVER"
"$SCRATCH/acceptance" "$SCRATCH/speech.wav" "$SERVER" "$APP/Contents/MacOS/InsertionTarget"
