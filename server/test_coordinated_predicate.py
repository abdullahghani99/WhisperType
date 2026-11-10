import unittest
from polish import restore_distinct_coordinated_predicate as restore, copyedit

class CoordinatedPredicateTests(unittest.TestCase):
    def test_middle_predicate_restored_with_subject_sharing(self):
        source='Please ensure everything is in place and everything is proper and everything is perfect.'
        output='Please ensure everything is in place and perfect.'
        self.assertEqual(restore(source,output),'Please ensure everything is in place and proper and perfect.')
    def test_tense_case_and_other_cleanup_retained(self):
        source='You know, they were ready and they were willing and they were able.'
        output='They were ready and able.'
        self.assertEqual(restore(source,output),'They were ready and willing and able.')
    def test_complete_coordinated_cleanup_kept(self):
        source='Everything is checked and everything is verified and everything is ready.'
        for output in ['Everything is checked, verified and ready.','Everything is checked and verified and ready.',source]:
            self.assertEqual(restore(source,output),output)
    def test_identical_predicate_repetition_may_clean(self):
        source='It is ready and it is ready and it is ready.'
        self.assertEqual(restore(source,'It is ready.'),'It is ready.')
    def test_different_actor_tense_outer_predicate_or_ambiguous_repeat_abstains(self):
        source='It is ready and it is willing and it is able.'
        for output in ['They are ready and able.','It was ready and able.','It is done and able.','It is ready and capable.','It is ready and able. It is ready and able.']:
            self.assertEqual(restore(source,output),output)
        self.assertEqual(restore(source+' '+source,'It is ready and able.'),'It is ready and able.')
        for changed in [source.replace('it is willing','she is willing'),source.replace('it is willing','it was willing')]:
            self.assertEqual(restore(changed,'It is ready and able.'),'It is ready and able.')
    def test_separate_statement_not_given_another_predicate(self):
        source='It is ready and it is willing and it is able. Later it is ready and able.'
        output='It is ready, willing and able. Later it is ready and able.'
        self.assertEqual(restore(source,output),output)
        source='It is ready and it is willing and it is able. It is ready and it is keen and it is able.'
        self.assertEqual(restore(source,'It is ready and able.'),'It is ready and able.')

    def test_negation_correction_quote_and_condition_abstain(self):
        for source in ['It is ready and it is not willing and it is able.','It is ready and it is willing and it is able if approved.','"It is ready and it is willing and it is able."','It is ready and it is willing and it is able. Sorry, willing is wrong.']:
            self.assertEqual(restore(source,'It is ready and able.'),'It is ready and able.')
    def test_complete_pipeline_keeps_legitimate_cleanup(self):
        source='You know, please make sure that everything is in place and everything is proper and everything is perfect. Send the final report tomorrow.'
        output='Please make sure that everything is in place and perfect. Send the final report tomorrow.'
        context='This is the final review of the project. We have already checked the images, downloads, videos and descriptions. '
        source=context+source; output=context+output
        result,_=copyedit(source,lambda *_:output)
        self.assertEqual(result,context+'Please make sure that everything is in place and proper and perfect. Send the final report tomorrow.')

if __name__=='__main__':unittest.main()
