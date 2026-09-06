#!/bin/bash
# The old 8B-only pipeline could train a model that the live 14B never used.
# Use one explicit, fingerprinted workflow for the actual serving model.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 scripts/learning_cycle.py "$@"
