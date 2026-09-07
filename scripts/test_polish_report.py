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

    def test_harmless_rewording_of_a_clean_dictation_only_warns(self):
        # A word is added but nothing is lost: worth surfacing, not fatal.
        base = [case(1, 'the report is ready', 'The report is ready.')]
        candidate = [case(1, 'the report is ready', 'The report is now ready.')]
        code, out = run(base, candidate)
        payload = json.loads(out)
        self.assertEqual(code, 0)
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
        self.assertEqual(code, 0)
        self.assertEqual(payload['failures'], [])
        self.assertTrue(any('new guard rejection' in w for w in payload['warnings']))

    def test_newly_lost_question_mark_fails(self):
        source = 'everything is there right?'
        base = [case(1, source, 'Everything is there, right?')]
        candidate = [case(1, source, 'Everything is there.')]
        code, out = run(base, candidate)
        self.assertEqual(code, 1)
        self.assertIn('question mark', ' '.join(json.loads(out)['failures']))

    def test_removing_real_filler_is_not_a_content_drop(self):
        source = 'um so basically the report is you know ready'
        row = report.classify(case(1, source, 'The report is ready.'))
        self.assertEqual(row['dropped_content'], [])
        self.assertTrue(row['content_preserved'])


if __name__ == '__main__':
    unittest.main()
