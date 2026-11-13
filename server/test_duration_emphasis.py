import unittest
from polish import restore_duration_emphasis as restore, copyedit

class DurationEmphasisTests(unittest.TestCase):
    def test_repeated_duration_with_surviving_anchors(self):
        self.assertEqual(restore('We waited for days and days before it arrived.', 'We waited for days before it arrived.'), 'We waited for days and days before it arrived.')
    def test_redundant_preposition_cleanup_remains(self):
        src='It stayed broken for a long time and after days and days since we started.'
        out='It stayed broken for a long time and days since we started.'
        self.assertEqual(restore(src,out),'It stayed broken for a long time and days and days since we started.')
    def test_supported_units_and_other_cleanup(self):
        for unit in ['seconds','minutes','hours','days','weeks','months','years']:
            src=f'Um, we waited for {unit} and {unit} before it arrived.'
            out=f'We waited for {unit} before it arrived.'
            self.assertEqual(restore(src,out),f'We waited for {unit} and {unit} before it arrived.')
    def test_ordinary_repeat_and_paraphrase_not_reversed(self):
        for src,out in [('We waited for days days before it arrived.','We waited for days before it arrived.'),('We waited for days and days before it arrived.','We waited for many days before it arrived.'),('We waited for days and nights before it arrived.','We waited for days before it arrived.')]:
            self.assertEqual(restore(src,out),out)
    def test_quotes_corrections_negation_and_boundaries_abstain(self):
        for src in ['"We waited for days and days before it arrived."','We waited for days and days before it arrived. Sorry, hours.','We waited for days and days before it arrived, not weeks.']:
            self.assertEqual(restore(src,'We waited for days before it arrived.'),'We waited for days before it arrived.')
        self.assertEqual(restore('We waited for days and days before it arrived.','We waited for days. Before it arrived.'),'We waited for days. Before it arrived.')
    def test_ambiguous_context_and_already_retained_abstain(self):
        src='We waited for days and days before it arrived.'
        self.assertEqual(restore(src,src),src)
        self.assertEqual(restore(src,'They waited for days before it arrived.'),'They waited for days before it arrived.')
        self.assertEqual(restore(src+' We waited again.','We waited for days before it arrived. We waited again.'),'We waited for days before it arrived. We waited again.')
    def test_full_pipeline(self):
        src='We waited for days and days before it arrived.'
        result,diag=copyedit(src,lambda *_:'We waited for days before it arrived.')
        self.assertEqual(result,src)
        self.assertIn('duration_emphasis',diag['local_repairs'])

if __name__=='__main__':unittest.main()
