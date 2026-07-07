#!/bin/bash
# Show recent WhisperType dictation history from the server's capture store.
#   scripts/history.sh [N]        # default 15
N="${1:-15}"
URL="${VF_SERVER_URL:-http://127.0.0.1:8790}"
DIR="$(dirname "$0")"
curl -s --max-time 8 "${URL}/history?limit=${N}" | python3 "${DIR}/_history_print.py"
