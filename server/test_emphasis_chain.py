import unittest
import polish

class CoordinatedEmphasisTests(unittest.TestCase):
    def test_full_runs_preserve_exact_source_counts_and_are_idempotent(self):
        for word in ['over','again','tons','lots','more']:
            for n in [2,3,4]:
                source='We need '+(' and '.join([word]*n))+' for this.'
                for m in [1,2,3,4,5]:
                    proposed='We need '+(' and '.join([word]*m))+' for this.'
                    result=polish.restore_aligned_nuance(source,proposed)
                    self.assertEqual(result,source)
                    self.assertEqual(polish.restore_aligned_nuance(source,result),result)
    def test_pipeline_does_not_expand_an_already_restored_run(self):
        source='Can you fix the draft? Dude why must we check it over and over and over again?'
        proposed='Can you fix the draft? Why must we check it over and over again?'
        result,_=polish.copyedit(source,lambda *_:proposed)
        self.assertEqual(result,source)
    def test_accepted_cleanup_remains(self):
        source='Um, we check it over and over and over again.'
        proposed='We check it over and over again.'
        self.assertEqual(polish.restore_aligned_nuance(source,proposed),'We check it over and over and over again.')
    def test_real_stutter_and_unrepeated_source_are_unchanged(self):
        for source,output in [('We have the the report.','We have the report.'),('We check it over again.','We check it over again.'),('We need more, more details.','We need more details.')]:
            self.assertEqual(polish.restore_aligned_nuance(source,output),output)
    def test_corrections_and_quotes_abstain(self):
        for source,output in [('We check it over and over, sorry, only once.','We check it only once.'),('He said "we check it over and over again".','He said "we check it over again".'),('We check it over and over again.','We check it "over again".')]:
            self.assertEqual(polish.restore_aligned_nuance(source,output),output)
    def test_changed_anchors_and_sentence_boundaries_abstain(self):
        source='We check it over and over again tomorrow.'
        for output in ['We review it over again tomorrow.','We check it over again today.','We check it. Over again tomorrow.','We check it over. Again tomorrow.']:
            self.assertEqual(polish.restore_aligned_nuance(source,output),output)
    def test_source_boundaries_and_explicit_retractions_abstain(self):
        for source,output in [
            ('We check it. Over and over. Again tomorrow.', 'We check it over again tomorrow.'),
            ('We check it over and over again, actually only once.', 'We check it over again, actually only once.'),
            ("He wrote 'we check it over and over again'.", "He wrote 'we check it over again'."),
        ]:
            self.assertEqual(polish.restore_aligned_nuance(source,output),output)
    def test_rephrased_emphasis_is_not_augmented(self):
        source='We check the draft over and over again.'
        proposed='We check the draft over again and again.'
        self.assertEqual(polish.copyedit(source,lambda *_:proposed)[0],proposed)

    def test_ambiguous_duplicate_phrases_abstain(self):
        source='We check it over and over again today. They check it over and over again tomorrow.'
        output='We check it over again today. They check it over again tomorrow.'
        self.assertEqual(polish.restore_aligned_nuance(source,output),output)

if __name__=='__main__':unittest.main()
