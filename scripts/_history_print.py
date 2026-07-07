#!/usr/bin/env python3
"""Pretty-print WhisperType /history JSON from stdin."""
import sys, json

d = json.load(sys.stdin)
print(f"total dictations captured: {d['total']}\n")
for r in d["items"]:
    ms = (r.get("asr_ms") or 0) + (r.get("polish_ms") or 0)
    print(f"[{r['ts']}]  {r.get('num_words', 0)}w  {ms}ms")
    raw = r.get("raw") or ""
    polished = r.get("polished") or r.get("corrected") or ""
    if raw and raw != polished:
        print(f"    raw : {raw}")
    print(f"    text: {polished}\n")
