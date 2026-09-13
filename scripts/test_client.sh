#!/bin/bash
# The client gate: the app must COMPILE, then the tests must pass.
#
# `swift run vf-tests` alone is not a gate. The test target links WhisperTypeKit
# directly and never compiles the app, so v0.7.0 shipped with ServerClient using
# MuLaw without importing WhisperTypeKit: 111 tests passed green while the app did
# not build at all, and only `install.sh` failing caught it.
#
# Success is the compiler's exit status, never a pattern in its output. The first
# version of this script decided from `grep -E "...|Build complete"`, which an
# incremental build does not print (it says "Build of product 'WhisperType'
# complete!"); under `set -e` the empty grep failed the gate on a perfectly good
# build, and the tests below it never ran at all.
set -euo pipefail
cd "$(dirname "$0")/../client"

build() {                                   # $1 = label, $2... = swift build args
    local label="$1"; shift
    local log; log=$(mktemp)
    echo "==> building $label"
    if ! swift build "$@" >"$log" 2>&1; then
        echo "BUILD FAILED:"
        grep -E "error:" "$log" | head -20 || tail -20 "$log"
        rm -f "$log"
        exit 1
    fi
    rm -f "$log"
}

build "the app target (this is what the tests do not cover)" --product WhisperType
if [ -d ../remote-agent ]; then
    (cd ../remote-agent && swift build >/dev/null 2>&1) || { echo "BUILD FAILED: remote agent"; exit 1; }
    echo "==> built the remote agent"
fi

echo "==> tests"
swift run vf-tests

echo "==> actual client request contracts (no network)"
bash ../scripts/test_client_transport.sh
