import unittest
from meeting_quality import numbered_alignment_state, qualify_numbered_alignment as repair, passages, selected_notes
import json

class NumberedAlignmentTests(unittest.TestCase):
    source='**Alex:** The second is setting a policy date. The third is setting a new date by the end of December.\n\n**Blair:** The second is cancelling old orders.\n\n**Alex:** I want to align on point three.'
    summary='They agreed to cancel old orders and set a new date for policy by the end of December.'
    def test_chronology_overwrites_old_number_definition(self):
        d,r=numbered_alignment_state(passages(self.source))
        self.assertEqual(d['two']['text'],'cancelling old orders.')
        self.assertEqual(r['number'],'three')
    def test_qualifies_only_deferred_item(self):
        out=repair(passages(self.source),self.summary)
        self.assertEqual(out,'They agreed to cancel old orders. Setting a new date for policy by the end of December remained subject to alignment on point three.')
    def test_explicit_closure_separates_earlier_fragment(self):
        src=self.source.replace('I want to align','If that exception, actually point three, point two is not an issue we can cancel those orders that’s not an issue I want to a line')
        self.assertIn('remained subject',repair(passages(src),self.summary))
    def test_true_conditional_or_reported_reference_abstains(self):
        for text in ['If needed, I want to align on point three.','If point two is not an issue I want to align on point three.',"If that’s not an issue I want to align on point three.",'I want to align on point three if needed.','Blair said I want to align on point three.','"I want to align on point three."']:
            src=self.source.replace('I want to align on point three.',text)
            self.assertEqual(repair(passages(src),self.summary),self.summary)
    def test_final_disposition_supersedes(self):
        for final in ['We have now agreed.','Point three is not an issue.','Actually, point two.','The third is now approved.', 'Yes, let us go with the end of December.', 'That sounds good; let us do it.', 'Point three is settled.', 'We will proceed with that date.']:
            self.assertEqual(repair(passages(self.source+'\n\n**Alex:** '+final),self.summary),self.summary)
    def test_same_date_in_two_items_is_ambiguous(self):
        src=self.source.replace('cancelling old orders.','setting an invoice date by the end of December.')
        self.assertEqual(repair(passages(src),self.summary),self.summary)
    def test_negated_or_conditional_description_abstains(self):
        for phrase in ['not setting a new date','setting a new date if approved']:
            src=self.source.replace('setting a new date',phrase)
            self.assertEqual(repair(passages(src),self.summary),self.summary)
    def test_quoted_and_already_qualified_summary_preserved(self):
        for out in ['"'+self.summary+'"','They discussed the pending policy date.']:
            self.assertEqual(repair(passages(self.source),out),out)
    def test_length_limit_does_not_drop_summary(self):
        out='Context '*140+self.summary
        self.assertEqual(repair(passages(self.source),out),out)
    def test_complete_notes_keeps_other_sections(self):
        src=passages(self.source+'\n\n**Alex:** I will send the draft.')
        raw=json.dumps({'summary':[self.summary],'decisions':[],'action_items':['I will send the draft.'],'open_questions':[]})
        out=selected_notes(src,raw)
        self.assertIn('remained subject to alignment',out)
        self.assertIn('Alex: I will send the draft.',out)

if __name__=='__main__':unittest.main()
