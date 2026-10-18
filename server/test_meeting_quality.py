import json
import unittest
import meeting_quality as q

class MeetingEvidenceTests(unittest.TestCase):
    def render(self,text,**sections):
        s={key:[] for key in q.HEADINGS};s.update({k:[q.passages(text)[i]['text'] for i in ids] for k,ids in sections.items()})
        return q.selected_notes(q.passages(text),json.dumps(s))
    def test_only_source_words_survive(self):
        text='**Alex:** I will send the report Friday. We have not decided whether to launch.'
        result=self.render(text,action_items=[0],open_questions=[1])
        self.assertIn('Alex: I will send the report Friday.',result)
        self.assertIn('We have not decided whether to launch.',result)
    def test_advice_not_upgraded_to_commitment(self):
        text='We discussed backups. You should enable snapshots. For example, we will migrate next year.'
        result=self.render(text,summary=[0],action_items=[1,2])
        self.assertNotIn('Action items',result)
    def test_unknown_ids_and_schema_never_publish(self):
        source=q.passages('A real sentence.')
        for out in ['not json','[]','{}',json.dumps({**{k:[] for k in q.HEADINGS},'summary':[True]}),json.dumps({**{k:[] for k in q.HEADINGS},'summary':[9]})]:
            with self.assertRaises(ValueError):q.selected_notes(source,out)
    def test_decision_negation_and_actual_negative_decision(self):
        text='We have not decided whether to launch. We decided not to publish until review.'
        result=self.render(text,decisions=[0,1])
        self.assertNotIn('whether to launch',result)
        self.assertIn('decided not to publish',result)
    def test_speaker_and_amount_preserved(self):
        text='**Alex:** I will review the $500.50 budget on Friday.\n\n**Blair:** I will send the report Monday.'
        result=self.render(text,action_items=[0,1])
        self.assertIn('$500.50',result);self.assertIn('Blair: I will send',result)
    def test_condition_and_negation_cannot_be_cropped(self):
        source=q.passages('I will send the report if the review passes.')
        selected={k:[] for k in q.HEADINGS}
        selected['action_items']=['I will send the report']
        with self.assertRaises(ValueError):q.selected_notes(source,json.dumps(selected))
        selected['action_items']=[source[0]['text']]
        self.assertIn('if the review passes',q.selected_notes(source,json.dumps(selected)))
    def test_summary_speaker_number_is_valid_but_new_amount_is_not(self):
        source=q.passages('**Speaker 1:** The budget is 100 dollars.')
        selected={k:[] for k in q.HEADINGS};selected['summary']=['Speaker 1 described a budget of 100 dollars.']
        self.assertIn('Speaker 1 described',q.selected_notes(source,json.dumps(selected)))
        selected['summary']=['The budget is 50 dollars.']
        with self.assertRaises(ValueError):q.selected_notes(source,json.dumps(selected))
    def test_invented_quote_is_rejected(self):
        source=q.passages('We discussed backups.')
        selected={k:[] for k in q.HEADINGS};selected['action_items']=['Alex will send a reconciliation sheet.']
        with self.assertRaises(ValueError):q.selected_notes(source,json.dumps(selected))
    def test_adjacent_source_sentences_form_a_valid_summary(self):
        text='**Alex:** First, generate text. Then convert it to speech.'
        selected={k:[] for k in q.HEADINGS};selected['summary']=['First, generate text. Then convert it to speech.']
        self.assertIn('Then convert it to speech.',q.selected_notes(q.passages(text),json.dumps(selected)))
    def test_addressing_someone_never_introduces_self(self):
        for text in ['Thank you, Maya.','Maya, can you help?','She said "I am Maya."','If I said I am Maya, that would be wrong.',"I'm Maya's colleague."]:
            self.assertFalse(q.self_introduced('**Speaker 1:** '+text,'Speaker 1','Maya'),text)
    def test_introductions_are_local_to_the_correct_speaker(self):
        for text in ["I'm Alex.",'Hi, my name is Alex.','This is Alex speaking.','Alex here.']:
            self.assertTrue(q.self_introduced('**Speaker 1:** '+text,'Speaker 1','Alex'),text)
        self.assertFalse(q.self_introduced('**Speaker 2:** I am Alex.','Speaker 1','Alex'))

if __name__=='__main__':unittest.main()
