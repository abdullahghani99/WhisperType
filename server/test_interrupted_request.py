import json
import unittest
import meeting_quality as q


class InterruptedRequestTests(unittest.TestCase):
    source = '**Alex:** Send me the complete\n\n**Sam:** Thank you.\n\n**Alex:** list and split\n\n**Sam:** Okay, no problem.\n\n**Alex:** the delayed orders from the discontinued orders.'

    def notes(self, text, summary='The team discussed orders.'):
        return q.selected_notes(q.passages(text), json.dumps({
            'summary': [summary], 'decisions': [], 'action_items': [], 'open_questions': []}))

    def test_full_specification_and_response_order_without_inferred_task(self):
        out = self.notes(self.source)
        expected = ['Alex: “Send me the complete”', 'Sam: “Thank you.”', 'Alex: “list and split”', 'Sam: “Okay, no problem.”', 'Alex: “the delayed orders from the discontinued orders.”']
        self.assertTrue(all(x in out for x in expected))
        self.assertEqual(sorted(out.index(x) for x in expected), [out.index(x) for x in expected])
        self.assertNotIn('Action items', out)
        self.assertNotIn('Decisions', out)
        self.assertIn('The team discussed orders.', out)

    def test_other_document_and_single_interruption(self):
        out = self.notes('**Jo:** Please share us the updated\n\n**Lee:** Sure.\n\n**Jo:** report with the signed totals.')
        self.assertIn('report with the signed totals.', out)

    def test_capability_and_uninterrupted_request_not_promoted(self):
        for text in ['**Alex:** I can send the complete list.', '**Alex:** Send me the complete list.\n\n**Sam:** Okay.', '**Alex:** Send me the complete\n\n**Alex:** list of delayed orders.']:
            with self.subTest(text=text): self.assertNotIn('Request excerpts', self.notes(text))

    def test_refusal_capability_uncertainty_and_other_topic_interruptions(self):
        for response in ["I can't do that.", 'Maybe.', 'I can do that.', 'Okay, if you approve.', 'Yes, regarding the budget.', 'Who has the list?']:
            with self.subTest(response=response):
                self.assertNotIn('Request excerpts', self.notes(self.source.replace('Thank you.', response)))

    def test_framing_and_conditions_not_discarded(self):
        for prefix in ['If the audit passes.', 'For example:', 'Yesterday she said:', 'I am reading the script.', 'Imagine this conversation:']:
            with self.subTest(prefix=prefix): self.assertNotIn('Request excerpts', self.notes('**Sam:** '+prefix+'\n\n'+self.source))

    def test_later_disposition_not_overridden(self):
        for suffix in ['Actually, do not send it.', 'I withdraw that request.', 'That was an example.', "I won't send the report.", 'No longer needed.']:
            with self.subTest(suffix=suffix): self.assertNotIn('Request excerpts', self.notes(self.source+'\n\n**Sam:** '+suffix))

    def test_unfinished_new_topic_or_unknown_speaker_abstains(self):
        for text in [self.source.replace('the delayed orders from the discontinued orders.', 'the delayed orders and'), self.source.replace('the delayed orders from the discontinued orders.', 'The budget is approved.'), self.source.replace('**Sam:** Thank you.', 'Thank you.'), self.source.replace('**Sam:** Okay, no problem.', '**Lee:** Okay, no problem.')]:
            with self.subTest(text=text): self.assertNotIn('Request excerpts', self.notes(text))

    def test_existing_exact_evidence_not_duplicated(self):
        summary='Alex: Send me the complete list and split the delayed orders from the discontinued orders.'
        self.assertNotIn('Request excerpts', self.notes(self.source, summary))

    def test_other_explicit_commitment_preserved(self):
        out=self.notes("**Jo:** I will prepare the budget tomorrow.\n\n"+self.source)
        self.assertIn('Jo: I will prepare the budget tomorrow.', out)
        self.assertIn('Request excerpts', out)

    def test_complete_object_in_readable_summary_not_repeated(self):
        text='**Jo:** Please give us the updated\n\n**Lee:** Sure.\n\n**Jo:** report with the signed totals.'
        self.assertNotIn('Request excerpts', self.notes(text, 'Jo requested an updated report with signed totals from Lee.'))
        self.assertIn('Request excerpts', self.notes(text, 'Jo requested an updated report from Lee.'))
        self.assertIn('Request excerpts', self.notes(text, 'Kim requested an updated report with the signed totals from Lee.'))

    def test_multiple_interrupted_requests_abstain(self):
        self.assertNotIn('Request excerpts', self.notes(self.source+'\n\n'+self.source.replace('Alex','Jo').replace('Sam','Lee')))


if __name__ == '__main__': unittest.main()
