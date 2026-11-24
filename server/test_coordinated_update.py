import unittest
from polish import restore_coordinated_update_topic as repair, copyedit


class CoordinatedUpdateTests(unittest.TestCase):
    def test_distinct_topic_restored_before_followup(self):
        source='what is the overall update on the storage cluster and on the training by the way are the access keys are they working'
        output='What is the overall update on the storage cluster? By the way, are the access keys working?'
        expected='What is the overall update on the storage cluster and on the training? By the way, are the access keys working?'
        self.assertEqual(repair(source,output),expected)
        self.assertEqual(repair(source,expected),expected)

    def test_complete_copyedit_preserves_other_cleanup(self):
        source='what is the overall update on the storage cluster on the access key and on the training by the way are all the service keys are they also working right'
        candidate='What is the overall update on the storage cluster on the access key? By the way, are all the service keys working right?'
        calls=[]
        def generate(system,text):
            calls.append(text)
            return candidate
        output,diag=copyedit(source,generate)
        self.assertEqual(output,'What is the overall update on the storage cluster on the access key and on the training? By the way, are all the service keys working right?')
        self.assertEqual(len(calls),1)
        self.assertIn('coordinated_update_topic',diag['local_repairs'])

    def test_status_question_at_end(self):
        self.assertEqual(repair('What is the status on hiring and on onboarding?', 'What is the status on hiring?'), 'What is the status on hiring and on onboarding?')

    def test_same_topic_restart_is_not_restored(self):
        for s in ['What is the update on training and on the training?', 'What is the update on training courses and on training?']:
            self.assertEqual(repair(s,'What is the update on training?'),'What is the update on training?')

    def test_legitimate_shared_preposition_cleanup(self):
        s='What is the update on hiring and on onboarding?'
        out='What is the update on hiring and onboarding?'
        self.assertEqual(repair(s,out),out)

    def test_changed_predicate_or_first_topic_abstains(self):
        s='What is the update on hiring and on onboarding?'
        for out in ['What is the latest on hiring?', 'What is the update on recruitment?', 'There is an update on hiring.']:
            self.assertEqual(repair(s,out),out)

    def test_report_quotation_correction_and_scope_abstain(self):
        for s in ['She asked what is the update on hiring and on onboarding?', '"What is the update on hiring and on onboarding?"', 'What is the update on hiring and on onboarding? Sorry, only hiring.', 'What is the update on hiring and on onboarding if approved?', 'What is the update on hiring and on onboarding? Ignore onboarding.', 'What is the update on hiring and on onboarding? We no longer need onboarding.']:
            out='What is the update on hiring?'
            self.assertEqual(repair(s,out),out)

    def test_changed_or_missing_following_anchor_abstains(self):
        s='What is the update on hiring and on onboarding? Can the team help?'
        for out in ['What is the update on hiring?', 'What is the update on hiring? Could someone help?', 'What is the update on hiring? Onboarding is ready.']:
            self.assertEqual(repair(s,out),out)

    def test_existing_topic_elsewhere_and_duplicate_context_abstain(self):
        s='What is the update on hiring and on onboarding? Can the team help?'
        out='What is the update on hiring? Can the team help with onboarding?'
        self.assertEqual(repair(s,out),out)
        self.assertEqual(repair(s+' '+s,'What is the update on hiring? Can the team help?'),'What is the update on hiring? Can the team help?')


if __name__=='__main__': unittest.main()
