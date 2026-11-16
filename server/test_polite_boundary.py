import unittest
from polish import repair_polite_request_boundaries as repair, copyedit

class PoliteBoundaryTests(unittest.TestCase):
    source="I think we have made the interface bland can you please fix it, review it and make it readable I'm concerned about the visuals."
    output="I think we have made the interface bland can you please fix it, review it, and make it readable. I'm concerned about the visuals."
    def test_preserves_comma_cleanup(self):
        want="I think we have made the interface bland. Can you please fix it, review it, and make it readable? I'm concerned about the visuals."
        self.assertEqual(repair(self.source,self.output),want)
        self.assertEqual(copyedit(self.source,lambda *_:self.output)[0],want)
    def test_modals_and_existing_boundary(self):
        for modal in ['can','could','would','will']:
            a=self.source.replace('can',modal);b=self.output.replace('can',modal)
            self.assertIn('readable? I',repair(a,b))
            ready=repair(a,b);self.assertEqual(repair(a,ready),ready)
    def test_reporting_quotation_and_hypothetical_contexts_abstain(self):
        for prefix in ['He said ','I asked ','The phrase is ','If this happens ','The question is ','I wonder whether ','For example ']:
            a=prefix+self.source;b=prefix+self.output;self.assertEqual(repair(a,b),b)
        self.assertEqual(repair('"'+self.source+'"',self.output),self.output)
    def test_changed_anchors_or_content_abstain(self):
        for b in [self.output.replace('interface bland','layout bland'),self.output.replace('review it','delete it'),self.output.replace("I'm",'They are')]:
            self.assertEqual(repair(self.source,b),b)
    def test_nominal_and_incomplete_request_abstain(self):
        for phrase in ['can you please fix it is the question','can you please fix it if needed','can you please fix it and']:
            a='The interface is bland '+phrase+" I'm worried.";b=a.replace(" I'm",". I'm");self.assertEqual(repair(a,b),b)
    def test_multiple_requests_and_no_right_boundary_abstain(self):
        for a,b in [(self.source+' Can you please check?',self.output+' Can you please check?'),(self.source.replace("I'm concerned",'We are concerned'),self.output.replace("I'm concerned",'We are concerned'))]:
            self.assertEqual(repair(a,b),b)
    def test_later_metalinguistic_context_abstains(self):
        for tail in ['not asking you to do it','quoting a request','describing a sentence','giving an example']:
            a=self.source.replace('concerned about the visuals',tail)
            b=self.output.replace('concerned about the visuals',tail)
            self.assertEqual(repair(a,b),b)
    def test_statements_and_apologies_remain(self):
        for a in ['The interface is bland. You can fix it. I am concerned.',self.source+' Sorry about that.']:
            self.assertEqual(repair(a,a),a)

if __name__=='__main__':unittest.main()
