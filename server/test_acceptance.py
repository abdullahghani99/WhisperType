import unittest
from polish import restore_explicit_acceptance as restore, copyedit

class AcceptanceTests(unittest.TestCase):
    def test_response_before_question(self):
        self.assertEqual(restore('Yes please. Is the update ready or no?','Is the update ready or no?'),'Yes, please. Is the update ready or no?')
        self.assertEqual(restore('Yes, please! what changed','What changed?'),'Yes, please! What changed?')
    def test_explicit_go_ahead_preserves_question_and_capitalization_cleanup(self):
        self.assertEqual(restore('Yes, please go ahead.','Please go ahead.'),'Yes, please go ahead.')
        self.assertEqual(restore('yes please proceed with the review','Please proceed with the review.'),'Yes, please proceed with the review.')
    def test_already_complete_and_changed_content_stay(self):
        src='Yes please. Is the update ready?'
        for out in ['Yes, please. Is the update ready?','Is the report ready?','The update is ready.','Is the update not ready?','']:
            self.assertEqual(restore(src,out),out)
    def test_unrelated_yes_and_no_consent_not_inferred(self):
        for src in ['Yes, I wonder whether it is ready.','Please go ahead.','No, please go ahead.','Did I say yes please?','Yes, please tell me what happened.']:
            self.assertEqual(restore(src,'Please go ahead.'),'Please go ahead.')
    def test_quotes_and_corrections_abstain(self):
        for src in ['"Yes, please go ahead."','Yes, please go ahead. Actually, no.','Yes, please go ahead. No, stop.','Yes please. Is it ready? Sorry, ignore that.','Yes please. Is it ready? I withdraw my approval.']:
            for out in ['Please go ahead.','Is it ready?']:
                self.assertEqual(restore(src,out),out)
    def test_legitimate_other_cleanup_not_reversed(self):
        # Out of scope when the question itself has been rewritten; do not
        # restore arbitrary words or return the unpolished source.
        src='Yes please. Is there actually any update?'
        self.assertEqual(restore(src,'Is there any update?'),'Is there any update?')
    def test_full_pipeline(self):
        for src,out,expected in [('Yes please. Is there any further update on this or no?','Is there any further update on this or no?','Yes, please. Is there any further update on this or no?'),('Yes, please go ahead.','Please go ahead.','Yes, please go ahead.')]:
            result,diagnostic=copyedit(src,lambda *_:out)
            self.assertEqual(result,expected)
            self.assertIn('explicit_acceptance',diagnostic['local_repairs'])

if __name__=='__main__':unittest.main()
