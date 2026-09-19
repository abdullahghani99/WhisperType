"""The gate has to fail when it should. These prove it does."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPORT = Path(__file__).resolve().parent / 'polish_report.py'
spec = importlib.util.spec_from_file_location('polish_report', REPORT)
report = importlib.util.module_from_spec(spec); spec.loader.exec_module(report)


def case(identifier, source, output, rejection=None, status='edited'):
    return {'id': identifier, 'input': source, 'output': output,
            'status': status, 'rejection': rejection, 'seconds': 1.0}


def referenced(identifier, source, output, reference, rejection=None, status='edited'):
    row = case(identifier, source, output, rejection, status)
    row['reference'] = reference
    return row


def run(*arms):
    """Run the gate as a subprocess so the exit code is what is tested."""
    with tempfile.TemporaryDirectory() as directory:
        paths = []
        for index, rows in enumerate(arms):
            path = Path(directory) / f'arm{index}.jsonl'
            path.write_text(''.join(json.dumps(r) + '\n' for r in rows))
            paths.append(str(path))
        finished = subprocess.run([sys.executable, str(REPORT), *paths, '--json'],
                                  capture_output=True, text=True)
        return finished.returncode, finished.stdout


class ClassifierTests(unittest.TestCase):
    def test_hedges_are_not_filler(self):
        # An earlier version counted kind/know/like as filler by reusing
        # polish.FILLER_WORDS, which is a guard exemption list.
        for text in ('I kind of agree.', 'Do you know the answer?', 'I like the report.'):
            with self.subTest(text=text):
                self.assertFalse(report.classify(case(1, text, text))['needed_cleanup'])
                self.assertEqual(report.classify(case(1, text, text))['outcome'], 'correctly_unchanged')

    def test_deleting_a_hedge_is_never_a_cleanup(self):
        row = report.classify(case(1, 'um I kind of agree', 'I agree.'))
        self.assertTrue(row['needed_cleanup'])          # "um" is real filler
        self.assertFalse(row['hedges_preserved'])
        self.assertEqual(row['outcome'], 'not_cleaned')

    def test_real_filler_removal_is_a_cleanup(self):
        row = report.classify(case(1, 'um so you know the report is ready', 'The report is ready.'))
        self.assertEqual(row['outcome'], 'cleaned')


class GateTests(unittest.TestCase):
    def test_passing_comparison_exits_zero(self):
        base = [case(1, 'um the report is ready', 'um the report is ready')]
        candidate = [case(1, 'um the report is ready', 'The report is ready.')]
        code, out = run(base, candidate)
        self.assertEqual(code, 0)
        self.assertTrue(json.loads(out)['passed'])

    def test_newly_lost_fact_exits_nonzero(self):
        base = [case(1, 'Send 15 copies.', 'Send 15 copies.')]
        candidate = [case(1, 'Send 15 copies.', 'Send 50 copies.')]
        code, out = run(base, candidate)
        self.assertEqual(code, 1)
        self.assertIn('numbers/negation newly lost', ' '.join(json.loads(out)['failures']))

    def test_a_new_failure_is_not_offset_by_an_unrelated_fix(self):
        # Totals would net to zero here; per-case checking must still fail.
        base = [case(1, 'Send 15 copies.', 'Send 50 copies.'), case(2, 'Send 8 boxes.', 'Send 8 boxes.')]
        candidate = [case(1, 'Send 15 copies.', 'Send 15 copies.'), case(2, 'Send 8 boxes.', 'Send 3 boxes.')]
        code, _ = run(base, candidate)
        self.assertEqual(code, 1)

    def test_newly_deleted_hedge_exits_nonzero(self):
        base = [case(1, 'um I kind of agree', 'I kind of agree.')]
        candidate = [case(1, 'um I kind of agree', 'I agree.')]
        code, out = run(base, candidate)
        self.assertEqual(code, 1)
        self.assertIn('hedge', ' '.join(json.loads(out)['failures']))

    def test_rewording_a_clean_dictation_fails_because_it_loses_content(self):
        # "ready" disappears. It fails as a meaning regression, not merely
        # because a clean input was touched.
        base = [case(1, 'The report is ready.', 'The report is ready.')]
        candidate = [case(1, 'The report is ready.', 'The report has been completed.')]
        code, out = run(base, candidate)
        self.assertEqual(code, 1)
        self.assertIn('content newly dropped', ' '.join(json.loads(out)['failures']))

    def test_punctuation_only_edit_to_a_clean_dictation_is_silent(self):
        # Restoring capitalisation and a full stop is the job, not a deviation.
        base = [case(1, 'the report is ready', 'the report is ready')]
        candidate = [case(1, 'the report is ready', 'The report is ready.')]
        code, out = run(base, candidate)
        payload = json.loads(out)
        self.assertEqual(code, 0)
        self.assertEqual(payload['failures'], [])
        self.assertEqual(payload['warnings'], [])

    def test_adding_a_word_to_a_clean_dictation_fails(self):
        # "now" is a content word the speaker never said, so this is a meaning
        # change, not a stylistic one.
        base = [case(1, 'the report is ready', 'The report is ready.')]
        candidate = [case(1, 'the report is ready', 'The report is now ready.')]
        code, out = run(base, candidate)
        self.assertEqual(code, 1)
        self.assertIn('newly invented', ' '.join(json.loads(out)['failures']))

    def test_harmless_rewording_of_a_clean_dictation_only_warns(self):
        # Contractions expanded: no content added, dropped or reordered.
        base = [case(1, "it's ready and it's approved", "It's ready and it's approved.")]
        candidate = [case(1, "it's ready and it's approved", 'It is ready and it is approved.')]
        code, out = run(base, candidate)
        payload = json.loads(out)
        self.assertEqual(code, 2)
        self.assertEqual(payload['failures'], [])
        self.assertTrue(any('already-clean' in w for w in payload['warnings']))

    def test_mismatched_corpora_are_refused(self):
        base = [case(1, 'The report is ready.', 'The report is ready.')]
        candidate = [case(2, 'Something else.', 'Something else.')]
        code, _ = run(base, candidate)
        self.assertEqual(code, 1)

    def test_same_id_with_retranscribed_text_is_refused(self):
        base = [case(1, 'Send 15 copies.', 'Send 15 copies.')]
        candidate = [case(1, 'Send 50 copies.', 'Send 50 copies.')]
        code, _ = run(base, candidate)
        self.assertEqual(code, 1)

    def test_empty_replay_is_refused(self):
        code, _ = run([], [case(1, 'a b c', 'a b c')])
        self.assertEqual(code, 1)


class AuditCounterexampleTests(unittest.TestCase):
    """Cases that passed the gate in Codex's 2026-09-08 review. Each must fail."""

    def test_invented_content_fails(self):
        base = [case(1, 'The report is ready.', 'The report is ready.')]
        candidate = [case(1, 'The report is ready.', 'The report is ready and approved.')]
        code, out = run(base, candidate)
        self.assertEqual(code, 1)
        self.assertIn('newly invented', ' '.join(json.loads(out)['failures']))

    def test_reversed_attribution_fails(self):
        base = [case(1, 'Alex owes Sam money.', 'Alex owes Sam money.')]
        candidate = [case(1, 'Alex owes Sam money.', 'Sam owes Alex money.')]
        code, out = run(base, candidate)
        self.assertEqual(code, 1)
        self.assertIn('order newly broken', ' '.join(json.loads(out)['failures']))

    def test_repetition_allowance_covers_only_the_duplicates(self):
        # Exempting the root outright let every occurrence of the action vanish.
        source = 'Review review the report and then review the budget.'
        base = [case(1, source, source)]
        candidate = [case(1, source, 'The report and the budget.')]
        code, out = run(base, candidate)
        self.assertEqual(code, 1)
        self.assertIn('newly dropped', ' '.join(json.loads(out)['failures']))
        # ...while collapsing a genuine adjacent duplicate stays allowed.
        self.assertEqual(report.dropped_content('the report is ready now now',
                                                'The report is ready now.'), [])

    def test_quality_regression_is_visible_and_not_a_promotion_pass(self):
        base = [case(1, 'um the report is ready', 'The report is ready.')]
        candidate = [case(1, 'um the report is ready', 'um the report is ready')]
        code, out = run(base, candidate)
        payload = json.loads(out)
        self.assertEqual(code, 2)
        self.assertTrue(payload['meaning_intact'])
        self.assertFalse(payload['passed'])


class MeaningVersusQualityTests(unittest.TestCase):
    """The gate must fail on accepted meaning loss and only warn on a rejection."""

    def test_deletion_accepted_by_the_guard_still_fails(self):
        # The v0.5.2 restart bug: rejection=None, yet a distinct activity is gone.
        source = 'We distinguish generating, trying to generate, and reviewing as three different activities.'
        base = [case(1, source, source, rejection=None)]
        candidate = [case(1, source, 'We distinguish trying to generate, and reviewing as three different activities.',
                          rejection=None)]
        code, out = run(base, candidate)
        self.assertEqual(code, 1)
        self.assertIn('content newly dropped', ' '.join(json.loads(out)['failures']))

    def test_new_guard_rejection_warns_but_does_not_fail(self):
        source = 'um the quarterly report is ready'
        base = [case(1, source, 'The quarterly report is ready.', rejection=None)]
        candidate = [case(1, source, source, rejection='new_content', status='punctuation_recovery')]
        code, out = run(base, candidate)
        payload = json.loads(out)
        self.assertEqual(code, 2)            # quality regression, meaning intact
        self.assertEqual(payload['failures'], [])
        self.assertTrue(payload['meaning_intact'])
        self.assertFalse(payload['passed'])
        self.assertTrue(any('new guard rejection' in w for w in payload['warnings']))

    def test_removing_a_tag_question_is_allowed(self):
        # "..., right?" is a verbal tic the reference removes; its question mark
        # goes with it and that is not a lost question.
        source = 'everything is there right?'
        base = [case(1, source, 'Everything is there, right?')]
        candidate = [case(1, source, 'Everything is there.')]
        code, out = run(base, candidate)
        self.assertEqual(json.loads(out)['failures'], [])

    def test_newly_lost_question_mark_fails(self):
        source = 'can you check the report?'
        base = [case(1, source, 'Can you check the report?')]
        candidate = [case(1, source, 'You can check the report.')]
        code, out = run(base, candidate)
        self.assertEqual(code, 1)
        self.assertIn('question mark', ' '.join(json.loads(out)['failures']))

    def test_removing_real_filler_is_not_a_content_drop(self):
        source = 'um so basically the report is you know ready'
        row = report.classify(case(1, source, 'The report is ready.'))
        self.assertEqual(row['dropped_content'], [])
        self.assertTrue(row['content_preserved'])




class ReferenceAwareDrops(unittest.TestCase):
    """References can confirm exact repetition cleanup, not waive meaning checks."""

    SOURCE = 'keep going keep going I finally like it so keep going'

    def test_a_drop_the_reference_also_made_is_not_a_regression(self):
        base = [referenced('c1', self.SOURCE, 'Keep going. Keep going! I finally like it, so keep going.',
                           'Keep going! I finally like it, so keep going.')]
        candidate = [referenced('c1', self.SOURCE, 'Keep going! I finally like it, so keep going.',
                                'Keep going! I finally like it, so keep going.')]
        code, out = run(base, candidate)
        # Exit 1 is a meaning failure, 2 is warnings only. Agreeing with the
        # reference must not be a meaning failure; a style warning is fine.
        self.assertNotEqual(code, 1, f'agreeing with the accepted reference must not fail:\n{out}')
        self.assertNotIn('content newly dropped', out)
        self.assertNotIn('order newly broken', out)

    def test_a_drop_the_reference_kept_still_fails(self):
        source = 'make sure that you make them or first audit them on a full ten on ten'
        base = [referenced('c2', source, 'Make sure that you make them or first audit them on a full 10-on-10.',
                           'Make sure that you make them or first audit them on a full 10-on-10.')]
        candidate = [referenced('c2', source, 'Make sure that you audit them on a full 10-on-10.',
                                'Make sure that you make them or first audit them on a full 10-on-10.')]
        code, out = run(base, candidate)
        self.assertEqual(code, 1, f'dropping what the reference kept must still fail:\n{out}')
        self.assertIn('content newly dropped', out)

    def test_without_a_reference_every_new_drop_still_fails(self):
        source = 'please audit the numbers carefully before Friday'
        base = [case('c3', source, 'Please audit the numbers carefully before Friday.')]
        candidate = [case('c3', source, 'Please audit the numbers before Friday.')]
        code, out = run(base, candidate)
        self.assertEqual(code, 1, f'a production replay has no reference to excuse a drop:\n{out}')
        self.assertIn('content newly dropped', out)

    def test_reference_omission_does_not_license_losing_a_qualifier(self):
        source = 'Please audit the numbers carefully before Friday.'
        shortened = 'Please audit the numbers before Friday.'
        code, out = run([referenced('qualifier', source, source, shortened)],
                        [referenced('qualifier', source, shortened, shortened)])
        self.assertEqual(code, 1)
        self.assertIn('content newly dropped', out)

    def test_reference_reordering_does_not_license_a_different_role_reversal(self):
        source = 'Alice tells Bob that Carol owes Dan.'
        reference = 'Bob was told by Alice that Carol owes Dan.'
        candidate = 'Alice tells Bob that Dan owes Carol.'
        code, out = run([referenced('roles', source, source, reference)],
                        [referenced('roles', source, candidate, reference)])
        self.assertEqual(code, 1)
        self.assertIn('order newly broken', out)

    def test_even_matching_reference_cannot_license_reversed_ownership(self):
        source = 'Alice tells Bob that Carol owes Dan.'
        candidate = 'Alice tells Bob that Dan owes Carol.'
        code, out = run([referenced('same-roles', source, source, candidate)],
                        [referenced('same-roles', source, candidate, candidate)])
        self.assertEqual(code, 1)
        self.assertIn('order newly broken', out)

    def test_repetition_cleanup_does_not_hide_an_additional_deletion(self):
        source = 'Keep going keep going and audit the numbers carefully before Friday.'
        candidate = 'Keep going and audit the numbers before Friday.'
        code, out = run([referenced('extra-drop', source, source, candidate)],
                        [referenced('extra-drop', source, candidate, candidate)])
        self.assertEqual(code, 1)
        self.assertIn('content newly dropped', out)


if __name__ == '__main__':
    unittest.main()


class MetricsCountDefectsNotSpeech(unittest.TestCase):
    """These two metrics drove a week of decisions and were wrong four times in
    one day: they counted "B2B Builder" and "AE2 AE3" as repeated words, and
    counted deliberate speech — "we have to pay what we have to pay", "potato,
    potato", "What is the best way? What is the best approach?" — as defects
    polish had failed to remove. A metric that invents damage is worse than no
    metric, so these deliberately UNDERCOUNT rather than guess."""

    def count(self, text):
        return report.adjacent_duplicates(text) + report.restated_ngrams(text)

    def test_acronyms_are_not_repeated_words(self):
        self.assertEqual(self.count('B2B Builder and the AE2 AE3 review'), 0)

    def test_a_real_stutter_is_counted(self):
        self.assertGreater(self.count('the the numbers are wrong'), 0)

    def test_a_restarted_clause_is_counted(self):
        self.assertGreater(self.count('we need to, we need to ship it'), 0)
        self.assertGreater(self.count('I think we should, we should ship on Friday'), 0)

    def test_parallel_phrasing_across_sentences_is_not_a_defect(self):
        self.assertEqual(self.count('What is the best way? What is the best approach?'), 0)

    def test_idiom_and_emphasis_are_not_defects(self):
        self.assertEqual(self.count('we have to pay what we have to pay'), 0)
        self.assertEqual(self.count('It is potato, potato.'), 0)

    def test_ordinary_prose_is_clean(self):
        self.assertEqual(self.count('Send the report to the team and copy the board'), 0)
