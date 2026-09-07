"""Score a polish replay on whether it cleaned up correctly, not on how much it edited.

Reads the JSONL that evaluate_polish.py writes. Pass two files to compare a
baseline against a candidate; comparison mode is a GATE and exits non-zero when
any requirement fails, so a deploy script can depend on it.

Edit volume is a diagnostic, never a target. Requiring "more editing" or "more
lists" rewards a prompt that rewrites dictations nobody asked it to touch, so
each case is classified by what its INPUT actually needed:

  needs_cleanup  the input carries unambiguous filler or an immediate repetition
                 -> the output must be measurably cleaner
  already_clean  it carries neither
                 -> unchanged is the correct answer and counts as a pass

Two properties are treated as regressions no matter what the cleanup numbers
say, and are checked PER CASE rather than as totals, so a candidate cannot earn
a new failure by happening to fix an unrelated one:

  facts      numbers and negation, via polish.facts
  hedges     "kind of", "sort of", "maybe", "probably", "I think"

The hedge check exists because an earlier version of this script scored
"I kind of agree." -> "I agree." as a successful cleanup. It counted `kind`,
`know` and `like` as filler by reusing polish.FILLER_WORDS -- which is a guard
EXEMPTION list, deliberately permissive about what may be removed, and therefore
exactly the wrong list for deciding what SHOULD be removed. It also marked
"Do you know the answer?" and "I like the report." as needing cleanup. Only
unambiguous filler counts here; anything context-dependent is a diagnostic.
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

# Rejections that mean the model changed or invented meaning. A rise in any of
# these vetoes a candidate. This is a SUBSET of all rejections by design: the
# rest (content_or_order, unfinished_sentence) mean the guard declined an edit,
# which costs quality but never correctness. Total fallbacks are reported
# separately as `fallbacks`, so the two are never confused.
SAFETY = ('new_content', 'numbers_or_negation', 'lost_question', 'question_intent', 'attribution')
# Detection is deliberately CONSERVATIVE and under-detects. Only these are
# filler in every context. "you know" and "i mean" are not: "Do you know the
# answer?" and "I mean it" are literal. Whether they are discourse markers
# depends on punctuation the ASR input does not carry, so they are reported as a
# diagnostic (`marker_phrases`) and never used to demand a deletion.
#
# The consequence is that a dictation whose only filler is "you know" counts as
# already_clean, where leaving it unchanged scores as a pass. So these numbers
# are a floor on cleanup, not a measure of it, and promotion still requires
# reading cases (`--show`) rather than trusting the totals.
FILLER_TOKENS = frozenset(('um', 'uh', 'er', 'hmm'))
MARKER_PHRASES = (r'\byou know\b', r'\bi mean\b')
HEDGES = (r'\bkind of\b', r'\bsort of\b', r'\bmaybe\b', r'\bprobably\b', r'\bi think\b')


def normalised(text):
    return [re.sub(r'[^\w]', '', w).lower() for w in text.split()]


def word_change(source, output):
    a, b = normalised(source), normalised(output)
    matcher = difflib.SequenceMatcher(None, a, b)
    changed = sum(max(o[2] - o[1], o[4] - o[3]) for o in matcher.get_opcodes() if o[0] != 'equal')
    return changed, changed / max(1, len(a)) * 100


def filler_count(text):
    return sum(1 for w in normalised(text) if w in FILLER_TOKENS)


def marker_count(text):
    """Diagnostic only: may be discourse filler or literal. Never a requirement."""
    return sum(len(re.findall(p, text, re.I)) for p in MARKER_PHRASES)


def hedge_count(text):
    return sum(len(re.findall(p, text, re.I)) for p in HEDGES)


def has_repetition(text):
    return bool(re.search(r'\b(\w+)\s+\1\b', text, re.I))


def classify(item):
    source, output = item['input'], item['output']
    changed, percent = word_change(source, output)
    repetition_before = has_repetition(source)
    row = {
        'id': item.get('id'), 'status': item.get('status'), 'rejection': item.get('rejection'),
        'word_changed': changed, 'word_percent': percent,
        'filler_before': filler_count(source), 'filler_after': filler_count(output),
        'repetition_after': has_repetition(output),
        'hedges_before': hedge_count(source), 'hedges_after': hedge_count(output),
        'markers_before': marker_count(source), 'markers_after': marker_count(output),
        'paragraphs': output.count('\n\n'),
        'lists': len(re.findall(r'^\s*(?:[-*]|\d+[.)])\s', output, re.M)),
        'facts_preserved': polish.facts(polish.clean_stutters(source)) == polish.facts(output),
        'seconds': item.get('seconds'),
    }
    row['hedges_preserved'] = row['hedges_after'] >= row['hedges_before']
    row['needed_cleanup'] = row['filler_before'] > 0 or repetition_before
    if row['needed_cleanup']:
        # Every defect the input carried must be resolved.
        resolved = []
        if row['filler_before'] > 0: resolved.append(row['filler_after'] == 0)
        if repetition_before: resolved.append(not row['repetition_after'])
        cleaned = bool(resolved) and all(resolved)
        # Deleting a hedge is never a successful cleanup, whatever else improved.
        row['outcome'] = 'cleaned' if cleaned and row['hedges_preserved'] else 'not_cleaned'
    else:
        row['outcome'] = 'correctly_unchanged' if changed == 0 else 'edited_clean_input'
    return row


def summarise(rows, label):
    total = len(rows)
    needed = [r for r in rows if r['needed_cleanup']]
    clean = [r for r in rows if not r['needed_cleanup']]
    cleaned = sum(1 for r in needed if r['outcome'] == 'cleaned')
    left_alone = sum(1 for r in clean if r['outcome'] == 'correctly_unchanged')
    rejections = Counter(r['rejection'] for r in rows if r['rejection'])
    return {
        'label': label, 'cases': total,
        'needed_cleanup': len(needed), 'cleaned': cleaned,
        'cleaned_pct': f'{cleaned/len(needed)*100:.0f}%' if needed else '-',
        'already_clean': len(clean), 'left_alone': left_alone,
        'punctuation_only': sum(1 for r in rows if r['word_changed'] == 0),
        'median_word_edit': f"{statistics.median([r['word_percent'] for r in rows]):.1f}%" if rows else '-',
        'marker_phrases_left': sum(r['markers_after'] for r in rows),
        'with_paragraphs': sum(1 for r in rows if r['paragraphs'] > 0),
        'with_lists': sum(1 for r in rows if r['lists'] > 0),
        'facts_lost': sum(1 for r in rows if not r['facts_preserved']),
        'hedges_lost': sum(1 for r in rows if not r['hedges_preserved']),
        'fallbacks': sum(1 for r in rows if r['rejection']),
        'safety_rejections': sum(n for reason, n in rejections.items() if reason in SAFETY),
        'median_seconds': f"{statistics.median([r['seconds'] for r in rows if r['seconds']]):.1f}" if any(r['seconds'] for r in rows) else '-',
        'rejections': dict(rejections),
    }


def load(path):
    items = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    if not items: raise SystemExit(f'{path}: no cases; nothing to score')
    return items


def paired(base_items, candidate_items, path_a, path_b):
    """Both arms must have scored the SAME inputs, or the comparison is void."""
    a = {str(i.get('id')): i for i in base_items}
    b = {str(i.get('id')): i for i in candidate_items}
    if set(a) != set(b):
        only_a, only_b = sorted(set(a) - set(b))[:5], sorted(set(b) - set(a))[:5]
        raise SystemExit(f'{path_a.name} and {path_b.name} scored different cases '
                         f'({len(a)} vs {len(b)}); only in first: {only_a}, only in second: {only_b}')
    mismatched = [k for k in a if a[k]['input'] != b[k]['input']]
    if mismatched:
        raise SystemExit(f'Same ids but different input text for {len(mismatched)} case(s) '
                         f'(e.g. {mismatched[:3]}). A retranscribed dictation cannot be compared; '
                         f're-run both arms against one frozen corpus.')
    return [(a[k], b[k]) for k in sorted(a)]


def gate(pairs):
    """Per-case requirements. Totals can hide a new failure behind a fixed one."""
    failures = []
    for base_item, candidate_item in pairs:
        before, after = classify(base_item), classify(candidate_item)
        case = after['id']
        if before['facts_preserved'] and not after['facts_preserved']:
            failures.append(f'case {case}: numbers/negation newly lost')
        if before['hedges_preserved'] and not after['hedges_preserved']:
            failures.append(f'case {case}: a hedge was newly deleted')
        if before['rejection'] not in SAFETY and after['rejection'] in SAFETY:
            failures.append(f'case {case}: new safety rejection ({after["rejection"]})')
        if before['outcome'] == 'cleaned' and after['outcome'] == 'not_cleaned':
            failures.append(f'case {case}: cleanup regressed')
        if before['outcome'] == 'correctly_unchanged' and after['outcome'] == 'edited_clean_input':
            failures.append(f'case {case}: an already-clean dictation was edited')
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('replay', type=Path, nargs='+', help='One or two evaluate_polish JSONL outputs')
    parser.add_argument('--show', type=int, default=0, help='Print this many needs-cleanup cases in full for reading')
    parser.add_argument('--json', action='store_true', help='Emit machine-readable results')
    args = parser.parse_args()
    if len(args.replay) > 2: parser.error('Pass at most two replays')

    loaded = [load(path) for path in args.replay]
    reports = [summarise([classify(i) for i in items], path.stem)
               for items, path in zip(loaded, args.replay)]
    failures = []
    if len(loaded) == 2:
        failures = gate(paired(loaded[0], loaded[1], args.replay[0], args.replay[1]))

    if args.json:
        print(json.dumps({'reports': reports, 'failures': failures,
                          'passed': not failures and len(loaded) == 2}, indent=2))
    else:
        keys = [k for k in reports[0] if k not in ('label', 'rejections')]
        width = max(len(k) for k in keys) + 2
        print()
        print(' ' * width + '  '.join(f'{r["label"][:24]:>24}' for r in reports))
        for key in keys:
            print(f'{key:<{width}}' + '  '.join(f'{str(r[key]):>24}' for r in reports))
        for r in reports:
            print(f'\n{r["label"]} rejections: {r["rejections"] or "none"}')
        if len(loaded) == 2:
            print('\nGate (per case, candidate vs baseline):')
            if failures:
                for f in failures: print('  FAIL  ' + f)
            else:
                print(f'  PASS  {len(loaded[0])} cases, no new meaning, hedge, safety or cleanup regression')

    if args.show:
        for items, path in zip(loaded, args.replay):
            print(f'\n===== {path.stem}: needs-cleanup cases =====')
            shown = 0
            for item in items:
                row = classify(item)
                if not row['needed_cleanup']: continue
                print(f"\n--- id {row['id']}  {row['status']}/{row['rejection']}  {row['outcome']} ---")
                print('IN :', item['input'][:400])
                print('OUT:', item['output'][:400])
                shown += 1
                if shown >= args.show: break

    if failures: raise SystemExit(1)


if __name__ == '__main__':
    main()
