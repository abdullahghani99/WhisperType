#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$(mktemp -d /tmp/whispertype-transport.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT
swiftc -parse-as-library "$ROOT/client/Sources/WhisperType/ServerClient.swift" "$ROOT/tests/transport/TransportTests.swift" -o "$SCRATCH/tests"
"$SCRATCH/tests"
