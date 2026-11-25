import unittest
from polish import restore_question_before_alternative as repair, copyedit


class QuestionAlternativeTests(unittest.TestCase):
    def test_question_and_alternative_preserve_other_cleanup(self):
        s='But I added the settings as well, what more do I need to add? Or let me sign in on the tablet and then you take it from there, correct?'
        o='I added the settings as well. Let me sign in on the tablet, and then you can take it from there, correct?'
        want='I added the settings as well. What more do I need to add? Or let me sign in on the tablet, and then you can take it from there, correct?'
        self.assertEqual(repair(s,o),want)
        self.assertEqual(repair(s,want),want)

    def test_existing_or_is_not_doubled(self):
        s='I saved the new configuration, how can we verify it? Or let us run another check.'
        o='I saved the new configuration. Or let us run another check.'
        self.assertEqual(repair(s,o),'I saved the new configuration. How can we verify it? Or let us run another check.')

    def test_copyedit_keeps_cleanup_and_call_count(self):
        s='But I added the settings as well, what more do I need to add? Or let me sign in on the tablet and then you take it from there, correct?'
        o='I added the settings as well. Let me sign in on the tablet, and then you can take it from there, correct?'
        calls=[]
        def generate(system,text):
            calls.append(text)
            return o
        result,diag=copyedit(s,generate)
        self.assertIn('What more do I need to add? Or let me',result)
        self.assertNotIn('But I',result)
        self.assertEqual(len(calls),1)
        self.assertIn('question_before_alternative',diag['local_repairs'])

    def test_retained_and_rephrased_question_abstain(self):
        s='I saved the new configuration, how can we verify it? Or let us run another check.'
        for o in [s, 'I saved the new configuration. How could we verify it? Or let us run another check.', 'I saved the new configuration. Let us run another check to verify it.']:
            self.assertEqual(repair(s,o),o)

    def test_report_nominal_conditional_and_quotation_abstain(self):
        for prefix in ['She said I saved the new configuration, ', 'The question is how I saved the new configuration, ', 'If I saved the new configuration, ', '"I saved the new configuration, ']:
            s=prefix+'how can we verify it? Or let us run another check.'
            o='I saved the new configuration. Let us run another check.'
            self.assertEqual(repair(s,o),o)

    def test_corrections_retractions_and_answer_abstain(self):
        for s in ['I saved the new configuration, how can we verify it? Sorry, let us run another check.', 'I saved the new configuration, how can we verify it? Or let us run another check. Ignore that question.', 'I saved the new configuration, how can we verify it? We can test it. Or let us run another check.', 'I saved the new configuration, how can we verify it? Or let us rephrase that question.']:
            o='I saved the new configuration. Let us run another check.'
            self.assertEqual(repair(s,o),o)

    def test_changed_or_nonadjacent_anchors_abstain(self):
        s='I saved the new configuration, how can we verify it? Or let us run another check.'
        for o in ['I saved the updated setup. Let us run another check.', 'I saved the new configuration. We can run another check.', 'I saved the new configuration. It looks fine. Let us run another check.']:
            self.assertEqual(repair(s,o),o)

    def test_question_paraphrased_after_alternative_abstains(self):
        s='I added the settings as well, what more do I need to add? Or let me sign in on the tablet.'
        for o in ['I added the settings as well. Let me sign in on the tablet. Am I missing anything?', 'I added the settings as well. Let me sign in on the tablet. What else is missing?']:
            self.assertEqual(repair(s,o),o)

    def test_ambiguous_repeat_and_missing_source_boundary_abstain(self):
        s='I saved the new configuration, how can we verify it? Or let us run another check.'
        o='I saved the new configuration. Let us run another check.'
        for source in [s+' '+s, s.replace('configuration,','configuration'),s.replace('verify it?','verify it')]:
            self.assertEqual(repair(source,o),o)


if __name__=='__main__': unittest.main()
