#!/usr/bin/env python3
"""Turn accepted pairs into mlx_lm LoRA chat data, in the LIVE prompt frame.

The adapter has to serve inside the same system prompt and the same
<dictation> wrapper the server sends, or it is learning one task and being
asked another at inference time.

Deliberately NOT distillation: `distill_gold.py` had a teacher model invent the
ideal output because there were no supervised pairs. There are now 926 real
ones -- the speaker's own transcript against the text they kept -- so the target
is what they accepted, not what a larger model guesses they would have.
"""
import argparse, importlib.util, json, os
from pathlib import Path


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--corpus', type=Path, required=True)
    ap.add_argument('--policy', type=Path, required=True, help='the live polish.py, for its SYSTEM prompt')
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--keep-guard-illegal', action='store_true',
                    help='train on pairs the serving guard would refuse (the first run did)')
    args = ap.parse_args()

    spec = importlib.util.spec_from_file_location('policy', args.policy)
    policy = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(policy)
    system = policy.SYSTEM
    args.out.mkdir(parents=True, exist_ok=True)
    for name in ('train', 'validation'):
        source, written = args.corpus / f'{name}.jsonl', 0
        target = args.out / f'{"valid" if name == "validation" else name}.jsonl'
        refused = 0
        with source.open() as reader, target.open('w') as writer:
            for line in reader:
                row = json.loads(line)
                # An accepted pair the guard would REFUSE teaches the model to
                # produce output the server then throws away. The first run
                # trained on all of them and learned, among other things, to
                # rewrite "10 on 10" as "10/10" -- a minority rendering that
                # appears 6 times against 29 in the same corpus, and one the
                # guard rejects as a changed number. The reference is what the
                # speaker accepted from another tool, not a licence to emit what
                # this one refuses.
                if not args.keep_guard_illegal and policy.rejection_reason(row['source'], row['target']):
                    refused += 1
                    continue
                writer.write(json.dumps({'messages': [
                    {'role': 'system', 'content': system},
                    {'role': 'user', 'content': '<dictation>\n' + row['source'] + '\n</dictation>'},
                    {'role': 'assistant', 'content': row['target']},
                ]}, ensure_ascii=False) + '\n')
                written += 1
        os.chmod(target, 0o600)
        print(f'  {target.name:16} {written} examples  ({refused} dropped: the guard would refuse them)')
    print(f'  system prompt     {len(system)} chars, from {args.policy.name}')


if __name__ == '__main__':
    main()
