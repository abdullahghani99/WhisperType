#!/bin/bash
# Exercise real CoreMedia input and AVAudioConverter without opening a microphone.
set -euo pipefail
cd "$(dirname "$0")/.."
TEMP_TEST="$(mktemp -d)"
trap 'rm -rf "$TEMP_TEST"' EXIT
cp tests/live/NativeMicrophonePCM.swift "$TEMP_TEST/main.swift"
swiftc client/Sources/WhisperType/SessionMicrophone.swift client/Sources/WhisperType/AudioDevices.swift "$TEMP_TEST/main.swift" -o "$TEMP_TEST/check"
"$TEMP_TEST/check"
