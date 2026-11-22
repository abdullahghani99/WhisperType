import json
import unittest
import meeting_quality as q


class DeletionInstructionTests(unittest.TestCase):
    def notes(self, source, summary='The team discussed warehouse capacity.'):
        return q.selected_notes(q.passages(source), json.dumps({
            'summary': [summary], 'decisions': [], 'action_items': [], 'open_questions': []}))

    def test_retains_instruction_and_prerequisite_without_invented_owner(self):
        out = self.notes('**Alex:** Do not erase the records. We need an assessment before I decide.\n\n**Sam:** The assessment remains open.')
        self.assertIn('Alex: Do not erase the records. We need an assessment before I decide.', out)
        self.assertNotIn('Action items', out)
        self.assertNotIn('Decisions', out)

    def test_interrupted_causal_continuation_is_marked(self):
        out = self.notes("**Alex:** Don't delete. Give me an analysis of the archive,\n\n**Sam:** Okay, regarding the warehouse,\n\n**Alex:** so I can understand and then decide.")
        self.assertIn('archive, … so I can understand and then decide.', out)
        self.assertNotIn('regarding the warehouse', out)

    def test_never_attaches_other_speakers_prerequisite(self):
        out = self.notes("**Alex:** Don't delete the archive.\n\n**Sam:** Give me an analysis of the archive so I can decide.")
        self.assertIn("Alex: Don't delete the archive.", out)
        self.assertNotIn('Give me', out)

    def test_later_overrides_and_completed_conditions_abstain(self):
        for end in ['Actually, delete the archive now.', 'I approve deleting the archive.', 'I withdraw that hold.', 'The audit is complete.']:
            with self.subTest(end=end):
                out = self.notes("**Alex:** Don't delete the archive until the audit is complete.\n\n**Sam:** "+end)
                self.assertNotIn('Instructions stated', out)

    def test_hypothetical_or_quoted_context_abstains(self):
        for start in ['If the audit fails, what should the operator hear?', 'The manager says:', 'For this example:', 'Imagine this conversation:']:
            with self.subTest(start=start):
                self.assertNotIn('Instructions stated', self.notes('**Sam:** '+start+"\n\n**Alex:** Don't delete the archive."))
        self.assertNotIn('Instructions stated', self.notes('**Alex:** "Do not delete the archive."'))

    def test_later_example_disavowal_abstains(self):
        self.assertNotIn('Instructions stated', self.notes("**Alex:** Don't delete the archive.\n\n**Sam:** That was just an example."))

    def test_historical_and_read_aloud_context_abstain(self):
        for text in ['Yesterday the operator heard this.', 'I am reading from the manual.', 'Previously this instruction applied.']:
            self.assertNotIn('Instructions stated', self.notes('**Sam:** '+text+"\n\n**Alex:** Don't delete the archive."))

    def test_question_permission_and_incomplete_text_abstain(self):
        for text in ["Don't delete the archive?", 'We approved deleting the archive.', 'Do not delete the archive,']:
            self.assertNotIn('Instructions stated', self.notes('**Alex:** '+text))

    def test_existing_instruction_paraphrase_not_duplicated(self):
        summary='Alex instructed not to delete the archive until the audit is complete.'
        out=self.notes("**Alex:** Don't delete the archive until the audit is complete.", summary)
        self.assertNotIn('Instructions stated', out)
        out=self.notes("**Alex:** Don't delete the archive.", 'Alex advises against deleting the archive, and Sam requests an analysis.')
        self.assertNotIn('Instructions stated', out)

    def test_existing_cleanup_and_other_sections_preserved(self):
        source=q.passages("**Alex:** Don't delete the archive.\n\n**Sam:** I will review the layout tomorrow.")
        raw=json.dumps({'summary':['The team discussed the layout.'], 'decisions':[], 'action_items':['I will review the layout tomorrow.'], 'open_questions':[]})
        out=q.selected_notes(source, raw)
        self.assertIn('The team discussed the layout.', out)
        self.assertIn('Sam: I will review the layout tomorrow.', out)
        self.assertIn("Alex: Don't delete the archive.", out)


if __name__=='__main__': unittest.main()
