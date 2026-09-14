#!/bin/bash
# The morning check. Safe to run unattended, every day.
#
# It never trains. Training on an unchanged corpus produces a different model,
# not a better one, and the 926 reference pairs are finished and fully spent --
# so a nightly retrain would burn GPU and drift the model with no new signal.
# What changes is correction labels, and `run_checked_cycle.py` already refuses
# to train until five new ones exist. This reports whether that gate has opened.
#
# What it does check, every day, is that the guard still behaves: a regression
# there is silent, ships to the speaker immediately, and is the one failure this
# project has repeatedly shipped without noticing.
#
# Exit 0 = healthy. Exit 1 = a guard regression; do not deploy anything.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
status=0

echo "==> guard calibration"
if ! python3 scripts/calibrate_guard.py > /tmp/vf-daily-guard.txt 2>&1; then
    echo "   FAIL — an adversarial case was accepted. Nothing should deploy today."
    grep -E "adversarial|desired" /tmp/vf-daily-guard.txt
    status=1
else
    grep -E "heldout|adversarial|desired" /tmp/vf-daily-guard.txt
fi

echo "==> offline gate tests"
python3 scripts/test_polish_report.py 2>&1 | tail -1 || status=1

echo "==> learning gate"
ssh -o ConnectTimeout=20 "${VF_SERVER_HOST:?set VF_SERVER_HOST=user@host}" 'python3 -c "
import json, sqlite3, os
labels = sqlite3.connect(\"file:\" + os.path.expanduser(\"~/whispertype/history.sqlite\") + \"?mode=ro\", uri=True).execute(\"select count(*) from learning_feedback\").fetchone()[0]
state = json.load(open(os.path.expanduser(\"~/whispertype-learning/learning-runs/latest.json\")))
print(\"   correction labels:\", labels)
print(\"   qualifying pairs :\", state.get(\"qualifying_pairs\"), \"(\" + str(state.get(\"status\")) + \")\")
print(\"   TRAIN\" if labels >= state.get(\"approved_feedback\", 0) + 5 else \"   hold - the gate needs five new labels before another run is worth it\")
"' || status=1

exit $status
