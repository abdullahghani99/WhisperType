#!/bin/bash
# Focus selection policy only: no UI, microphone, server or synthesized events.
set -euo pipefail
cd "$(dirname "$0")/.."
TEMP_TEST="$(mktemp -d)"
trap 'rm -rf "$TEMP_TEST"' EXIT
cp tests/live/DestinationFocus.swift "$TEMP_TEST/main.swift"
swiftc client/Sources/WhisperType/CaptureDestination.swift "$TEMP_TEST/main.swift" -o "$TEMP_TEST/check"
"$TEMP_TEST/check"
