#!/bin/bash
# Show recent whispertype dictation history from the server's capture store.
#   scripts/history.sh [N]        # default 15
set -euo pipefail
exec python3 "$(dirname "$0")/history.py" "${1:-15}"
