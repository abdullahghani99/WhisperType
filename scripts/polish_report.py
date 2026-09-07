"""Score a polish replay on whether it cleaned up correctly, not on how much it edited.

Reads the JSONL that evaluate_polish.py writes. Pass two files to compare a
baseline against a candidate.

Edit volume is a diagnostic here, never a target. Requiring "more editing" or
"more lists" rewards a prompt that rewrites dictations nobody asked it to touch,
so every case is first classified by what its INPUT actually needed:

  needs_cleanup  the input carries filler, an immediate repetition or a restart
                 -> the output must be measurably cleaner
  already_clean  it carries none of those
                 -> unchanged is the correct answer and counts as a pass

The safety columns are the ones that can veto a candidate: a rise in
new_content, numbers_or_negation, lost_question or question_intent means the
prompt started inventing or dropping meaning, whatever the cleanup numbers say.
"""
import argparse
from collections import Counter
import difflib
import json
from pathlib import Path
import re
import statistics
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'server'))
import polish

SAFETY = ('new_content', 'numbers_or_negation', 'lost_question', 'question_intent', 'attribution')
FILLER_PHRASES = ('you know', 'i mean', 'sort of', 'kind of')


def normalised(text):
    return [re.sub(r'[^\w]', '', w).lower() for w in text.split()]


def word_change(source, output):
    a, b = normalised(source), normalised(output)
    matcher = difflib.SequenceMatcher(None, a, b)
    changed = sum(max(o[2] - o[1], o[4] - o[3]) for o in matcher.get_opcodes() if o[0] != 'equal')
    return changed, changed / max(1, len(a)) * 100


def filler_count(text):
    tokens = [w for w in normalised(text) if w in polish.FILLER_WORDS]
    phrases = sum(len(re.findall(phrase, text, re.I)) for phrase in FILLER_PHRASES)
    return len(tokens) + phrases


def has_repetition(text):
    return bool(re.search(r'\b(\w+)\s+\1\b', text, re.I))


def has_restart(text):
    return bool(re.search(r'\b\w{4,}ing,?\s+(?:trying|going|about)\s+to\s+\w+', text, re.I))


def classify(item):
    source, output = item['input'], item['output']
    needed = filler_count(source) > 0 or has_repetition(source) or has_restart(source)
    changed, percent = word_change(source, output)
    row = {
        'id': item.get('id'), 'status': item.get('status'), 'rejection': item.get('rejection'),
        'needed_cleanup': needed, 'word_changed': changed, 'word_percent': percent,
        'filler_before': filler_count(source), 'filler_after': filler_count(output),
        'repetition_after': has_repetition(output), 'restart_after': has_restart(output),
        'paragraphs': output.count('\n\n'), 'lists': len(re.findall(r'^\s*(?:[-*]|\d+[.)])\s', output, re.M)),
        'facts_preserved': polish.facts(polish.clean_stutters(source)) == polish.facts(output),
        'seconds': item.get('seconds'),
    }
    if needed:
        # Every defect the input actually carried must be resolved. An earlier
        # version passed a case if the output merely had no repetition, which is
        # true of almost any text, so a baseline that dropped one "uh" and left
        # "basically ... you know" in place scored as cleaned.
        resolved = []
        if row['filler_before'] > 0: resolved.append(row['filler_after'] == 0)
        if has_repetition(source): resolved.append(not row['repetition_after'])
        if has_restart(source): resolved.append(not row['restart_after'])
        row['outcome'] = 'cleaned' if resolved and all(resolved) else 'not_cleaned'
    else:
        row['outcome'] = 'correctly_unchanged' if changed == 0 else 'edited_clean_input'
    return row


def summarise(rows, label):
    total = len(rows)
    needed = [r for r in rows if r['needed_cleanup']]
    clean = [r for r in rows if not r['needed_cleanup']]
    cleaned = [r for r in needed if r['outcome'] == 'cleaned']
    rejections = Counter(r['rejection'] for r in rows if r['rejection'])
    return {
        'label': label, 'cases': total,
        'needed_cleanup': len(needed),
        'cleaned_successfully': f'{len(cleaned)}/{len(needed)}' + (f' ({len(cleaned)/len(needed)*100:.0f}%)' if needed else ''),
        'already_clean': len(clean),
        'correctly_left_alone': f"{sum(1 for r in clean if r['outcome']=='correctly_unchanged')}/{len(clean)}" if clean else '0/0',
        'punctuation_only': f"{sum(1 for r in rows if r['word_changed']==0)}/{total}" + (f" ({sum(1 for r in rows if r['word_changed']==0)/total*100:.0f}%)" if total else ''),
        'median_word_edit': f"{statistics.median([r['word_percent'] for r in rows]):.1f}%" if rows else '-',
        'with_paragraphs': sum(1 for r in rows if r['paragraphs'] > 0),
        'with_lists': sum(1 for r in rows if r['lists'] > 0),
        'facts_lost': sum(1 for r in rows if not r['facts_preserved']),
        'surviving_repetition': sum(1 for r in rows if r['repetition_after']),
        'safety_rejections': sum(n for reason, n in rejections.items() if reason in SAFETY),
        'rejections': dict(rejections),
        'median_seconds': f"{statistics.median([r['seconds'] for r in rows if r['seconds']]):.1f}" if any(r['seconds'] for r in rows) else '-',
    }


def load(path):
    return [classify(json.loads(line)) for line in path.read_text().splitlines() if line.strip()]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('replay', type=Path, nargs='+', help='One or two evaluate_polish JSONL outputs')
    parser.add_argument('--show', type=int, default=0, help='Print this many needs-cleanup cases in full for reading')
    args = parser.parse_args()
    if len(args.replay) > 2: parser.error('Pass at most two replays')

    reports = [summarise(load(path), path.stem) for path in args.replay]
    keys = [k for k in reports[0] if k not in ('label', 'rejections')]
    width = max(len(k) for k in keys) + 2
    print()
    print(' ' * width + '  '.join(f'{r["label"][:26]:>26}' for r in reports))
    for key in keys:
        print(f'{key:<{width}}' + '  '.join(f'{str(r[key]):>26}' for r in reports))
    for r in reports:
        print(f'\n{r["label"]} rejections: {r["rejections"] or "none"}')

    if len(reports) == 2:
        base, cand = reports
        print('\nGate (candidate vs baseline):')
        def verdict(ok, text): print(('  PASS  ' if ok else '  FAIL  ') + text)
        b_clean = int(base['cleaned_successfully'].split('/')[0]); c_clean = int(cand['cleaned_successfully'].split('/')[0])
        verdict(c_clean >= b_clean, f'cleanup successes {b_clean} -> {c_clean} (must not drop)')
        verdict(cand['safety_rejections'] <= base['safety_rejections'],
                f'safety rejections {base["safety_rejections"]} -> {cand["safety_rejections"]} (must not rise)')
        verdict(cand['facts_lost'] <= base['facts_lost'], f'facts lost {base["facts_lost"]} -> {cand["facts_lost"]} (must not rise)')
        b_left = int(base['correctly_left_alone'].split('/')[0]); c_left = int(cand['correctly_left_alone'].split('/')[0])
        verdict(c_left >= b_left, f'clean inputs left alone {b_left} -> {c_left} (must not drop)')

    if args.show:
        for path in args.replay:
            print(f'\n===== {path.stem}: needs-cleanup cases =====')
            shown = 0
            for line in path.read_text().splitlines():
                if not line.strip(): continue
                item = json.loads(line); row = classify(item)
                if not row['needed_cleanup']: continue
                print(f"\n--- id {row['id']}  {row['status']}/{row['rejection']}  {row['outcome']} ---")
                print('IN :', item['input'][:400])
                print('OUT:', item['output'][:400])
                shown += 1
                if shown >= args.show: break


if __name__ == '__main__':
    main()
