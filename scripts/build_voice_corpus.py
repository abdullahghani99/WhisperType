#!/usr/bin/env python3
"""Build a training split from the outputs the speaker actually accepted.

The 926 Wispr pairs are (their own transcript -> the text they kept). They have
only ever been used to GRADE the policy. A week of hand-written prompt rules
tried to infer by hand what these pairs demonstrate directly, and on genuinely
unseen data it bought nothing -- so this teaches the model from them instead.

Splitting rules, in order of how badly each has already bitten this project:

1. Evaluation is drawn ONLY from pairs no benchmark has ever consumed. A
   previous "150 held-out" claim turned out to be 141 already-consumed cases;
   reservation is not freshness.
2. Nothing in evaluation appears in training or validation, by content hash of
   the input, not by id -- the same dictation can be retranscribed.
3. The evaluation hashes are written out so the consumed ledger can absorb them
   the moment they are used. A slice is fresh exactly once.
"""
import argparse, hashlib, json, os
from pathlib import Path


# Split sizes are a property of a 926-pair corpus, not a runtime choice.
EVALUATION_SIZE = 120
VALIDATION_SIZE = 80


def digest(text: str) -> str:
    return hashlib.sha256(' '.join((text or '').split()).lower().encode()).hexdigest()


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--pairs', type=Path, required=True)
    ap.add_argument('--consumed', type=Path, required=True, help='ledger of inputs a benchmark has already seen')
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()

    pairs = json.loads(args.pairs.read_text())
    ledger = json.loads(args.consumed.read_text())
    consumed = set(ledger.get('consumed_input_sha256') or [])

    rows, seen = [], set()
    for pair in pairs:
        source = pair.get('asrText') or ''
        target = pair.get('formattedText') or ''
        if not source.strip() or not target.strip():
            continue
        key = digest(source)
        if key in seen:                      # the same dictation twice teaches nothing
            continue
        seen.add(key)
        rows.append({'sha256': key, 'source': source, 'target': target,
                     'consumed': key in consumed})

    # Order by hash so the split is reproducible and independent of quality.
    rows.sort(key=lambda r: r['sha256'])
    fresh = [r for r in rows if not r['consumed']]
    if len(fresh) < EVALUATION_SIZE:
        raise SystemExit(f'only {len(fresh)} never-consumed pairs; cannot draw {EVALUATION_SIZE} for evaluation')
    evaluation = fresh[:EVALUATION_SIZE]
    eval_keys = {r['sha256'] for r in evaluation}
    rest = [r for r in rows if r['sha256'] not in eval_keys]
    validation, training = rest[:VALIDATION_SIZE], rest[VALIDATION_SIZE:]

    args.out.mkdir(parents=True, exist_ok=True)
    for name, part in (('train', training), ('validation', validation), ('evaluation', evaluation)):
        path = args.out / f'{name}.jsonl'
        with path.open('w') as handle:
            for row in part:
                handle.write(json.dumps({'source': row['source'], 'target': row['target']}, ensure_ascii=False) + '\n')
        os.chmod(path, 0o600)
    (args.out / 'evaluation-hashes.json').write_text(json.dumps(
        {'sha256': sorted(eval_keys), 'note': 'add to the consumed ledger the moment these are scored'}, indent=2))
    os.chmod(args.out / 'evaluation-hashes.json', 0o600)

    overlap = eval_keys & {r['sha256'] for r in training + validation}
    assert not overlap, f'evaluation leaked into training: {len(overlap)}'
    assert not (eval_keys & consumed), 'evaluation drew a previously consumed input'
    print(f'  usable pairs      {len(rows)} (of {len(pairs)})')
    print(f'  never consumed    {len(fresh)}')
    print(f'  train             {len(training)}')
    print(f'  validation        {len(validation)}')
    print(f'  evaluation        {len(evaluation)}   all fresh, none in train/validation')


if __name__ == '__main__':
    main()
