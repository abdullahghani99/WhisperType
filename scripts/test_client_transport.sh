#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$(mktemp -d /tmp/whispertype-transport.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT
swift build --package-path "$ROOT/client" --target WhisperTypeKit
BIN="$(swift build --package-path "$ROOT/client" --show-bin-path)"
swiftc -parse-as-library -I "$BIN/Modules" "$BIN/WhisperTypeKit.build/"*.o \
    "$ROOT/client/Sources/WhisperType/ServerClient.swift" "$ROOT/tests/transport/TransportTests.swift" -o "$SCRATCH/tests"
"$SCRATCH/tests"
