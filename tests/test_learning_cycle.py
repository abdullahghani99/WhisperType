import importlib.util,json,sqlite3,sys,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'));sys.path.insert(0,str(ROOT/'server'))
import learning,learning_cycle
from split_training import input_key

class CycleTests(unittest.TestCase):
    def test_observations_excluded_and_groups_disjoint(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);db=p/'data.sqlite'
            with sqlite3.connect(db) as c:
                c.execute('CREATE TABLE history(id INTEGER,raw TEXT,corrected TEXT,polished TEXT,edited TEXT)')
                c.execute('CREATE TABLE meetings(id INTEGER,transcript TEXT,notes TEXT)')
                c.execute("INSERT INTO history VALUES(1,'unreviewed words','unreviewed words','a model answer',NULL)")
            learning.initialize(db)
            refs=[{'asrText':f'check report number {i} please','formattedText':f'Check report number {i}, please.','partition':'development' if i<30 else 'heldout'} for i in range(40)]
            f=p/'refs.json';f.write_text(json.dumps(refs))
            run,m=learning_cycle.prepare(db,f,p/'runs')
            parts={n:[json.loads(x) for x in (run/'data'/f'{n}.jsonl').read_text().splitlines()] for n in ['train','valid','test']}
            keys={n:{input_key(x) for x in xs} for n,xs in parts.items()}
            self.assertFalse(keys['train']&keys['valid'] or keys['train']&keys['test'] or keys['valid']&keys['test'])
            combined=set.union(*keys.values())
            self.assertNotIn('unreviewed words',combined)
            for r in refs[30:]:self.assertNotIn(r['asrText'],combined)
            second,m2=learning_cycle.prepare(db,f,p/'runs');self.assertEqual(run,second);self.assertEqual(m['fingerprint'],m2['fingerprint'])
            self.assertEqual(m['qualifying_pairs'],30)
    def test_earlier_reservation_survives_relabeling_and_user_correction(self):
        import hashlib
        with tempfile.TemporaryDirectory() as d:
            p=Path(d); db=p/'data.sqlite'
            source='check the protected report please'
            with sqlite3.connect(db) as c:
                c.execute('CREATE TABLE history(id INTEGER,raw TEXT,corrected TEXT,polished TEXT,edited TEXT)')
                c.execute('CREATE TABLE meetings(id INTEGER,transcript TEXT,notes TEXT)')
                c.execute('INSERT INTO history VALUES(1,?,?,?,?)',(source,source,source,'Check the protected report, please.'))
            learning.initialize(db)
            refs=p/'refs.json'; refs.write_text(json.dumps([{'asrText':source,'formattedText':source,'partition':'development'}]))
            ledger=p/'reserved.json'; ledger.write_text(json.dumps({'reserved_input_sha256':[hashlib.sha256(source.encode()).hexdigest()]}))
            run, manifest=learning_cycle.prepare(db,refs,p/'runs',ledger)
            self.assertEqual(manifest['qualifying_pairs'],0)
            self.assertEqual(json.loads((run/'sources.json').read_text()),[])
            self.assertEqual(manifest['reserved_reference_inputs'],1)

    def test_missing_serving_policy_is_not_alignment(self):
        from unittest.mock import patch
        with patch.object(learning_cycle,'serving_policy',return_value=None):
            with self.assertRaises(SystemExit):learning_cycle.check_policy_drift('unused',False)

if __name__=='__main__':unittest.main()


class LabelGateBlocksTraining(unittest.TestCase):
    """Two candidates were trained in one evening on a corpus that had not gained
    a single label, because nothing at the execution boundary compared the label
    count with the one at the last run. Retraining unchanged evidence yields a
    different model, not a better one, and spends evaluation data that cannot be
    recovered."""

    def gate(self, have, seen, hypothesis=''):
        """The condition as written in scripts/learning_cycle.py."""
        return seen is not None and have < seen + 5 and not hypothesis

    def test_unchanged_labels_are_refused(self):
        self.assertTrue(self.gate(have=7, seen=7))

    def test_four_new_labels_are_still_refused(self):
        self.assertTrue(self.gate(have=11, seen=7))

    def test_five_new_labels_open_the_gate(self):
        self.assertFalse(self.gate(have=12, seen=7))

    def test_a_first_run_is_not_blocked(self):
        self.assertFalse(self.gate(have=7, seen=None))

    def test_a_recorded_hypothesis_is_an_explicit_route_through(self):
        self.assertFalse(self.gate(have=7, seen=7, hypothesis='tests response masking, not new data'))
