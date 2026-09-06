#!/bin/bash
# Build, install, and preserve configuration; --uninstall retains user data.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$ROOT/install.py" "$@"
