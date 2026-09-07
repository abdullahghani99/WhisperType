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

    def test_editing_an_already_clean_dictation_exits_nonzero(self):
        base = [case(1, 'The report is ready.', 'The report is ready.')]
        candidate = [case(1, 'The report is ready.', 'The report has been completed.')]
        code, _ = run(base, candidate)
        self.assertEqual(code, 1)

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


if __name__ == '__main__':
    unittest.main()
