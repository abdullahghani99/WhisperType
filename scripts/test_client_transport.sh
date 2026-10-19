#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$(mktemp -d /tmp/whispertype-transport.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT
swift build --package-path "$ROOT/client" --target WhisperTypeKit
BIN="$(swift build --package-path "$ROOT/client" --show-bin-path)"
if [ -e "$BIN/WhisperTypeKit.swiftmodule" ] && [ -f "$BIN/WhisperTypeKit.o" ]; then
    MODULES="$BIN"
    OBJECTS=("$BIN/WhisperTypeKit.o")
else
    MODULES="$BIN/Modules"
    OBJECTS=("$BIN/WhisperTypeKit.build/"*.o)
fi
swiftc -parse-as-library -I "$MODULES" "${OBJECTS[@]}" \
    "$ROOT/client/Sources/WhisperType/ServerClient.swift" "$ROOT/tests/transport/TransportTests.swift" -o "$SCRATCH/tests"
"$SCRATCH/tests"
