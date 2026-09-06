#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$(mktemp -d /tmp/vf-agent-tests.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT
swiftc -parse-as-library "$ROOT/remote-agent/Sources/vfinsert/AgentProtocol.swift" "$ROOT/tests/agent/AgentTests.swift" -o "$SCRATCH/agent-tests"
"$SCRATCH/agent-tests"
