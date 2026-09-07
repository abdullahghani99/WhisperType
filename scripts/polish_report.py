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

Results are split by what a failure actually costs, and checked PER CASE so a
candidate cannot earn a new failure by happening to fix an unrelated one.

FAILURES (non-zero exit) are meaning regressions in output that was ACCEPTED and
shown to the user:

  facts      numbers and negation, via polish.facts
  hedges     "kind of", "sort of", "maybe", "probably", "I think"
  questions  a question mark present in the input must survive
  content    a non-filler word present in the input must survive

WARNINGS (reported, exit 0) are quality costs: the guard dec‍lined an edit and
fell back to punctuation or verbatim. The user sees less polishing, never wrong
words. An earlier version treated a rise in guard rejections as a safety
failure, which reads the signal backwards -- a rejection is the guard working.

The meaning checks re-derive everything from the ORIGINAL input instead of
trusting `rejection`. The v0.5.2 restart bug was accepted with `rejection=None`
because preprocessing had rewritten the source the guard validated against, so a
gate that trusts the guard cannot see that class of bug at all.

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


def question_marks(text):
    return sum(text.count(mark) for mark in '?؟？')


def dropped_content(source, output):
    """Content words present in the ORIGINAL input but missing from the output.

    Note which list is used for what. `polish.FILLER_WORDS` is consulted here as
    a REMOVAL PERMISSION -- the words polishing is allowed to drop -- which is
    what it was designed for. It is not used to decide what needs removing;
    that misuse is what made this script reward deleting "kind of".

    Compared against `source` rather than `clean_stutters(source)` on purpose: a
    preprocessing step that rewrites the source hides its deletions from the
    guard, and this check exists to catch exactly that.

    Counts, not a set. A set cannot see the bug this exists to catch: "generating"
    and "generate" share the root `generat`, so deleting the abandoned form leaves
    the root present and a set comparison reports nothing missing. That collapse is
    also why the guard's order check was the only signal available.

    A count that falls because the speaker immediately repeated themselves
    ("the report is ready now now") is allowed -- collapsing an adjacent duplicate
    is the edit we want. Any other drop is reported. This is deliberately strict:
    a legitimate clause dedup ("this includes leaves, this includes overtime" ->
    "this includes leaves, overtime") will be flagged and needs a human to wave it
    through. A false positive here costs one review; a false negative ships a
    dictation with a point missing.
    """
    removable = polish.FUNCTION_WORDS | polish.FILLER_WORDS
    def counts(text):
        tally = Counter()
        for word in polish.words(text):
            if word not in removable: tally[polish.root(word)] += 1
        return tally
    source_words = polish.words(source)
    repeated = {polish.root(a) for a, b in zip(source_words, source_words[1:])
                if polish.root(a) == polish.root(b)}
    present, kept = counts(source), counts(output)
    return sorted(r for r, n in present.items()
                  if kept[r] < n and r not in repeated)


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
        'dropped_content': dropped_content(source, output),
        'seconds': item.get('seconds'),
    }
    row['hedges_preserved'] = row['hedges_after'] >= row['hedges_before']
    row['questions_preserved'] = question_marks(output) >= question_marks(source)
    row['content_preserved'] = not row['dropped_content']
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
        'questions_lost': sum(1 for r in rows if not r['questions_preserved']),
        'content_dropped': sum(1 for r in rows if not r['content_preserved']),
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
    """Per-case results, split by what a failure actually costs.

    FAILURES are meaning regressions in text that was ACCEPTED and shown to the
    user. WARNINGS are quality costs, where the guard declined an edit and fell
    back to punctuation or verbatim: the user sees less polishing, never wrong
    words.

    An earlier version counted a rise in guard REJECTIONS as a safety failure.
    That reads the signal backwards -- a rejection is the guard working, and its
    fallback is safe by construction. Blocking on it would reject a candidate for
    being ambitious while ignoring the case that actually hurts: an edit that was
    accepted and lost meaning.

    The meaning checks deliberately re-derive everything from the ORIGINAL input
    rather than trusting `rejection`. The v0.5.2 restart bug was accepted with
    `rejection=None` precisely because preprocessing had already rewritten the
    source the guard validated against, so a gate that trusts the guard's verdict
    cannot see that class of bug at all.
    """
    failures, warnings = [], []
    for base_item, candidate_item in pairs:
        before, after = classify(base_item), classify(candidate_item)
        case = after['id']

        # --- meaning: fatal ---
        if before['facts_preserved'] and not after['facts_preserved']:
            failures.append(f'case {case}: numbers/negation newly lost')
        if before['hedges_preserved'] and not after['hedges_preserved']:
            failures.append(f'case {case}: a hedge was newly deleted')
        if before['questions_preserved'] and not after['questions_preserved']:
            failures.append(f'case {case}: a question mark was newly lost')
        newly_dropped = set(after['dropped_content']) - set(before['dropped_content'])
        if newly_dropped:
            failures.append(f'case {case}: content newly dropped from accepted output '
                            f'({sorted(newly_dropped)[:4]})')

        # --- quality: reported, not fatal ---
        if before['rejection'] not in SAFETY and after['rejection'] in SAFETY:
            warnings.append(f'case {case}: new guard rejection ({after["rejection"]}) '
                            f'-> safe fallback, less polishing')
        if before['outcome'] == 'cleaned' and after['outcome'] == 'not_cleaned':
            warnings.append(f'case {case}: cleanup regressed')
        if before['outcome'] == 'correctly_unchanged' and after['outcome'] == 'edited_clean_input':
            warnings.append(f'case {case}: an already-clean dictation was edited')
    return failures, warnings


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
    failures, warnings = [], []
    if len(loaded) == 2:
        failures, warnings = gate(paired(loaded[0], loaded[1], args.replay[0], args.replay[1]))

    if args.json:
        print(json.dumps({'reports': reports, 'failures': failures, 'warnings': warnings,
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
            print('  meaning regressions in accepted output -- these fail the gate:')
            if failures:
                for f in failures: print('    FAIL  ' + f)
            else:
                print(f'    PASS  {len(loaded[0])} cases: no facts, hedges, questions or'
                      ' content newly lost')
            print('  quality costs -- reported, not fatal (guard declined, output stayed safe):')
            if warnings:
                for w in warnings[:12]: print('    warn  ' + w)
                if len(warnings) > 12: print(f'    ... and {len(warnings)-12} more')
            else:
                print('    none')

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
