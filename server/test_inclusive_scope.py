"""Source-aligned inclusive scope and deliberate emphasis; synthetic controls."""
import unittest
from polish import restore_explicit_inclusive_scope as scope
from polish import restore_explicit_quantifier_emphasis as emphasis
from polish import copyedit

class InclusiveScopeTests(unittest.TestCase):
    def test_complete_example_span_keeps_inclusive_request(self):
        source='Can you please sort everything out including 12 and 13. Leave the draft alone.'
        output='Can you please sort out 12 and 13? Leave the draft alone.'
        self.assertEqual(scope(source,output),'Can you please sort everything out, including 12 and 13? Leave the draft alone.')
    def test_without_particle_and_capitalization(self):
        self.assertEqual(scope('Could you check everything including alpha and beta.','Could you CHECK alpha and beta?'),'Could you CHECK everything, including alpha and beta?')
    def test_no_narrowing_is_unchanged(self):
        for source,output in [('Please check only alpha and beta.','Please check alpha and beta.'),('Please check everything including alpha and beta.','Please check everything, including alpha and beta.'),('Please check everything. Include alpha and beta.','Please check alpha and beta.')]:
            self.assertEqual(scope(source,output),output)
    def test_changed_objects_or_verbs_and_repeated_spans_abstain(self):
        source='Can you please sort everything out including alpha and beta.'
        for output in ['Can you please sort out alpha and gamma?','Can you please delete alpha and beta?','Can you please sort out only alpha and beta?','Can you please sort out alpha and beta? Can you please sort out alpha and beta?','He asked them to sort out alpha and beta.']:
            self.assertEqual(scope(source,output),output)
        self.assertEqual(scope(source+' '+source,'Can you please sort out alpha and beta?'),'Can you please sort out alpha and beta?')
    def test_corrections_and_quotes_abstain(self):
        for prefix in ['Sorry, ', 'I mean ', 'Rather, ', '"']:
            source=prefix+'Can you please sort everything out including alpha and beta.'
            output='Can you please sort out alpha and beta?'
            self.assertEqual(scope(source,output),output)
    def test_unrelated_stutter_cleanup_survives_repair(self):
        source='I I checked the draft. Can you please sort everything out including alpha and beta.'
        output='I checked the draft. Can you please sort out alpha and beta?'
        self.assertEqual(scope(source,output),'I checked the draft. Can you please sort everything out, including alpha and beta?')

class QuantifierEmphasisTests(unittest.TestCase):
    def test_explicit_emphasis_restored_other_cleanup_preserved(self):
        source='Please check everything, and by everything I mean everything, including the images and descriptions. you know Thanks.'
        output='Please check everything, including the images and descriptions. Thanks.'
        self.assertEqual(emphasis(source,output),'Please check everything, and by everything I mean everything, including the images and descriptions. Thanks.')
    def test_closed_quantifiers_and_capitalization(self):
        for q in ['everyone','everybody','nothing']:
            source=f'We mean {q}, by {q} I mean {q}, in this group.'
            output=f'We mean {q.upper()}, in this group.'
            self.assertEqual(emphasis(source,output),f'We mean {q.upper()}, by {q} I mean {q}, in this group.')
    def test_correction_not_emphasis(self):
        for source in ['Please check everything, by everything I mean the documents, including the images.','Please check everything everything including the images.','Please check everything, and by everything I mean everything, including the images. Sorry, only the text.','"Please check everything, and by everything I mean everything, including the images."']:
            output='Please check everything, including the images.'
            self.assertEqual(emphasis(source,output),output)
    def test_different_anchor_boundary_or_already_present_abstains(self):
        source='Please check everything, and by everything I mean everything, including the images.'
        for output in ['Please check everything. Including the images.','Please delete everything, including the images.','Please check everything, including other images.',source,'Please check everything, including the images. Please check everything, including the images.']:
            self.assertEqual(emphasis(source,output),output)
    def test_pipeline_preserves_emphasis_and_legitimate_cleanup(self):
        source='Please please check everything, and by everything I mean everything, including the images.'
        output='Please check everything, including the images.'
        result,_=copyedit(source,lambda *_:output)
        self.assertEqual(result,'Please check everything, and by everything I mean everything, including the images.')

if __name__=='__main__':unittest.main()
