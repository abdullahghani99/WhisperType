"""Deterministic, input-grouped train/validation/test splits.

Deduplicate before splitting; only training edits are oversampled. The test
partition stays untouched by training and hyperparameter selection.
"""
import argparse
import hashlib
import json
from pathlib import Path
import random
import re

def input_key(row):
    messages = row['messages']
    source = next(m['content'] for m in messages if m['role'] == 'user')
    source = source.replace('<<<BEGIN>>>', '').replace('<<<END>>>', '')
    return re.sub(r'\s+', ' ', source).strip().casefold()

def split(rows, seed=7):
    groups = {}
    for row in rows:
        key = input_key(row)
        if not key: continue
        if key in groups and groups[key]['messages'][-1]['content'] != row['messages'][-1]['content']:
            raise ValueError('Conflicting gold outputs for the same normalized input; review the source data')
        groups[key] = row
    if len(groups) < 10: raise ValueError('At least 10 unique inputs are required for three separate partitions')
    keys = sorted(groups)
    random.Random(seed).shuffle(keys)
    held = max(1, len(keys)//10)
    partitions = {'test': keys[:held], 'valid': keys[held:held*2], 'train': keys[held*2:]}
    output = {name: [groups[key] for key in members] for name,members in partitions.items()}
    train = []
    for row in output['train']:
        target = re.sub(r'\s+', ' ', row['messages'][-1]['content']).strip().casefold()
        train.extend([row] * (5 if input_key(row) != target else 1))
    random.Random(seed).shuffle(train); output['train'] = train
    return output

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path); parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    source = args.source.read_bytes()
    partitions = split([json.loads(line) for line in source.splitlines() if line.strip()])
    args.destination.mkdir(parents=True, exist_ok=True)
    for name, rows in partitions.items():
        (args.destination / (name+'.jsonl')).write_text(''.join(json.dumps(row, ensure_ascii=False)+'\n' for row in rows))
    (args.destination/'split-manifest.json').write_text(json.dumps({'seed':7, 'source_sha256':hashlib.sha256(source).hexdigest(), 'counts':{k:len(v) for k,v in partitions.items()}}, indent=2))
    print({name:len(rows) for name,rows in partitions.items()})

if __name__ == '__main__': main()
