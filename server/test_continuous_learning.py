import sqlite3,tempfile,unittest
from pathlib import Path
import learning

class LearningTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.db=Path(self.temp.name)/'history.sqlite'
        with sqlite3.connect(self.db) as c:
            c.execute('CREATE TABLE history(id INTEGER PRIMARY KEY,raw TEXT,corrected TEXT,polished TEXT,edited TEXT)')
            c.execute('CREATE TABLE meetings(id INTEGER PRIMARY KEY,transcript TEXT,notes TEXT)')
            c.execute("INSERT INTO history VALUES(1,'check the payroll report tomorrow','check the payroll report tomorrow','Check the payroll report tomorrow.',NULL)")
            c.execute("INSERT INTO meetings VALUES(1,'Alex will send the report.','Send the report.')")
        learning.initialize(self.db)
    def tearDown(self):self.temp.cleanup()
    def test_feedback_roundtrip_and_idempotence(self):
        target='Check the payroll report tomorrow?'
        self.assertTrue(learning.save_feedback(self.db,'dictation',1,'',target,'Check the payroll report tomorrow.'))
        self.assertFalse(learning.save_feedback(self.db,'dictation',1,'',target,target))
        self.assertEqual(learning.status(self.db)['corrections'],1)
        self.assertEqual(learning.dataset(self.db)[0]['target'],target)
        self.assertEqual(len(learning.relevant_examples(self.db,'please check the payroll report tomorrow')),1)
        self.assertEqual(learning.relevant_examples(self.db,'send the lunch menu'),[])
    def test_stale_missing_and_wrong_task_rejected(self):
        with self.assertRaises(RuntimeError):learning.save_feedback(self.db,'dictation',1,'','Check it?','stale')
        with self.assertRaises(LookupError):learning.save_feedback(self.db,'dictation',99,'','Check it?')
        with self.assertRaises(ValueError):learning.save_feedback(self.db,'arbitrary',1,'','Check it?')
    def test_meetings_separate_and_original_preserved(self):
        learning.save_feedback(self.db,'meeting_notes',1,'','Alex: send the report.','Send the report.')
        self.assertEqual(learning.relevant_examples(self.db,'Alex will send the report tomorrow'),[])
        with learning.connection(self.db) as c:row=c.execute('SELECT * FROM meetings WHERE id=1').fetchone()
        self.assertEqual(row['notes'],'Send the report.')
        self.assertEqual(learning.meeting_view(self.db,row)['notes'],'Alex: send the report.')
        self.assertEqual(learning.dataset(self.db)[0]['task'],'meeting_notes')
    def test_regenerated_meeting_does_not_reuse_stale_labels(self):
        learning.save_feedback(self.db,'meeting_notes',1,'','Alex: send the report.')
        with sqlite3.connect(self.db) as c:c.execute("UPDATE meetings SET transcript='Sam will send the report.',notes='Sam: send report.' WHERE id=1")
        self.assertEqual(learning.dataset(self.db),[])
        learning.save_feedback(self.db,'meeting_notes',1,'','Sam: send the report.','Sam: send report.')
        self.assertEqual(learning.dataset(self.db)[0]['source'],'Sam will send the report.')
    def test_deleted_history_not_used(self):
        learning.save_feedback(self.db,'dictation',1,'','Check the payroll report tomorrow?')
        with sqlite3.connect(self.db) as c:c.execute('DELETE FROM history')
        self.assertEqual(learning.dataset(self.db),[])
        self.assertEqual(learning.relevant_examples(self.db,'check the payroll report tomorrow'),[])
    def test_long_dictation_still_finds_a_relevant_correction(self):
        # Scoring against the union made the denominator grow with the dictation,
        # so long speech matched nothing and production logged examples=0
        # everywhere. Relevance must survive length.
        learning.save_feedback(self.db,'dictation',1,'','Check the payroll report tomorrow?')
        padding=' '.join('unrelated filler sentence about scheduling and logistics'.split()*20)
        long_text='please check the payroll report tomorrow. '+padding
        self.assertEqual(len(learning.relevant_examples(self.db,long_text)),1)
    def test_long_dictation_still_rejects_an_unrelated_correction(self):
        # The other direction: broader matching must not admit examples whose
        # content the speaker never mentioned.
        learning.save_feedback(self.db,'dictation',1,'','Check the payroll report tomorrow?')
        unrelated=' '.join('we should renegotiate the shipping contract before the container leaves the port'.split()*20)
        self.assertEqual(learning.relevant_examples(self.db,unrelated),[])
    def test_observations_not_labels(self):self.assertEqual(learning.dataset(self.db),[])
if __name__=='__main__':unittest.main()
