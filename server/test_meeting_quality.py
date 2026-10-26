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
    def test_omitted_explicit_commitment_is_recovered_from_source(self):
        text="**Alex:** We'll set the repository up and publish the code."
        selected={k:[] for k in q.HEADINGS}
        self.assertIn("Alex: We'll set the repository up",q.selected_notes(q.passages(text),json.dumps(selected)))
    def test_curly_contractions_keep_real_commitments(self):
        text="**Alex:** We’ll review the draft tomorrow."
        self.assertIn('We’ll review',q.selected_notes(q.passages(text),json.dumps({k:[] for k in q.HEADINGS})))
    def test_predictions_and_hypothetical_quotes_are_not_auto_tasks(self):
        for text in ["**Alex:** We will be late.","**Alex:** For example. I will send the report.","**Alex:** Suppose we migrate. I will send the report."]:
            with self.assertRaises(ValueError):q.selected_notes(q.passages(text),json.dumps({k:[] for k in q.HEADINGS}))
    def test_auto_task_retains_its_condition(self):
        text='**Alex:** I will send the report if the review passes.'
        self.assertIn('if the review passes',q.selected_notes(q.passages(text),json.dumps({k:[] for k in q.HEADINGS})))
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


class CommitmentDispositionTests(unittest.TestCase):
    def notes(self,source,summary='The report was discussed.'):
        response={k:[] for k in q.HEADINGS};response['summary']=[summary]
        return q.selected_notes(q.passages(source),json.dumps(response))

    def test_withdrawn_commitment_is_not_recreated_as_an_active_task(self):
        source='**Alex:** I will send the report Friday.\n\n**Blair:** Please wait.\n\n**Alex:** I withdraw that commitment.'
        self.assertNotIn('Action items',self.notes(source))

    def test_unrelated_commitment_survives_later_retraction(self):
        source='**Alex:** I will send the report Friday. I will publish the draft Monday. I withdraw that commitment.'
        notes=self.notes(source)
        self.assertIn('Alex: I will send the report Friday.',notes)
        self.assertNotIn('Alex: I will publish the draft Monday.',notes)

    def test_other_speaker_cannot_retract_your_commitment(self):
        source='**Alex:** I will send the report Friday.\n\n**Blair:** I withdraw that commitment.'
        self.assertIn('Alex: I will send the report Friday.',self.notes(source))

    def test_going_to_commitment_keeps_retraction_on_the_nearest_task(self):
        source="**Alex:** I will send the report Friday. I'm going to publish the draft Monday. I withdraw that commitment."
        notes=self.notes(source)
        self.assertIn('Alex: I will send the report Friday.',notes)
        self.assertNotIn("Alex: I'm going to publish the draft Monday.",notes)

    def test_conditional_question_remains_with_accepted_response(self):
        source='**Alex:** If legal approves, can you send the report Friday?\n\n**Blair:** I will send the report Friday.'
        notes=self.notes(source)
        self.assertIn('Alex: If legal approves, can you send the report Friday? Blair: I will send the report Friday.',notes)

    def test_explicit_role_play_does_not_become_a_real_task(self):
        source='**Alex:** Imagine a manager saying this.\n\n**Blair:** I will send the report Friday.\n\n**Alex:** That was our example dialogue, not a real assignment.'
        self.assertNotIn('Action items',self.notes(source))

if __name__ == '__main__': unittest.main()

class MeetingAcknowledgedCommitmentTests(unittest.TestCase):
    def render(self,text):
        return q.selected_notes(q.passages(text),json.dumps({k:[] for k in q.HEADINGS}))

    def test_acknowledgment_and_just_preserve_complete_commitment(self):
        text='**A:** Log in and check the option.\n\n**B:** Ok, I will check.\n\n**A:** I will just enter the entry.'
        output=self.render(text)
        self.assertIn('B: Ok, I will check.',output)
        self.assertIn('A: I will just enter the entry.',output)

    def test_discussion_and_call_are_explicit_tasks(self):
        output=self.render('**A:** I will discuss that. I will give you a call.')
        self.assertIn('I will discuss that.',output)
        self.assertIn('I will give you a call.',output)

    def test_prediction_and_incomplete_send_are_not_recovered(self):
        for text in ["**A:** I'll send you.", '**A:** Okay, I will be late.', '**A:** Yes, I will probably send the report.', '**A:** For example. Okay, I will send the report.']:
            with self.assertRaises(ValueError):self.render(text)

    def test_negation_condition_retraction_still_apply(self):
        output=self.render('**A:** Okay, I will send the report if approved.')
        self.assertIn('if approved',output)
        for text in ['**A:** Okay, I will not send the report.', '**A:** Okay, I will send the report. I withdraw that commitment.']:
            with self.assertRaises(ValueError):self.render(text)

    def test_real_request_does_not_transfer_owner(self):
        output=self.render('**A:** Please send the report.\n\n**B:** Yes, I will send it tomorrow.')
        self.assertIn('B: Yes, I will send it tomorrow.',output)
        self.assertNotIn('A: Yes',output)

class SelectedPredictionTests(unittest.TestCase):
    def test_model_selected_prediction_and_incomplete_object_are_not_tasks(self):
        for sentence in ['Okay, I will be late.', "I'll send you.", 'I will call that a success.']:
            src=q.passages('**Alex:** We discussed the report. '+sentence)
            selected={k:[] for k in q.HEADINGS};selected['summary']=['We discussed the report.'];selected['action_items']=[sentence]
            self.assertNotIn('Action items',q.selected_notes(src,json.dumps(selected)))
    def test_complete_actions_and_conditions_stay(self):
        for sentence in ["I'll send you the report.", 'I will deliver it early.', 'I will be reviewing the draft.', 'I will send you the file if approved.']:
            src=q.passages('**Alex:** '+sentence);selected={k:[] for k in q.HEADINGS};selected['action_items']=[sentence]
            self.assertIn(sentence,q.selected_notes(src,json.dumps(selected)))

class FutureSummaryAttributionTests(unittest.TestCase):
    def test_future_action_does_not_become_completed(self):
        source=q.passages('**Alex:** I will just enter the entry.')
        result=q.restore_future_summary_attribution(source,'Alex proceeded to enter an entry.')
        self.assertEqual(result,'Alex said, “I will just enter the entry”.')
    def test_actual_completed_evidence_abstains(self):
        src=q.passages('**Alex:** I will enter it. I entered the entry.')
        summary='Alex proceeded to enter the entry.'
        self.assertEqual(q.restore_future_summary_attribution(src,summary),summary)
    def test_condition_is_quoted_and_owner_is_local(self):
        src=q.passages('**Alex:** I will send the report if approved.\n\n**Blair:** I will send another report.')
        self.assertIn('if approved',q.restore_future_summary_attribution(src,'Alex proceeded to send the report.'))
        summary='Casey proceeded to send the report.'
        self.assertEqual(q.restore_future_summary_attribution(src,summary),summary)
    def test_ambiguous_compound_or_withdrawn_reference_abstains(self):
        for text,summary in [('I will send a report. I will send another report.','Alex proceeded to send a report.'),('I will send the report. I withdraw that commitment.','Alex proceeded to send the report.'),('I will send the report.','Alex proceeded to send the report and close the issue.')]:
            self.assertEqual(q.restore_future_summary_attribution(q.passages('**Alex:** '+text),summary),summary)

class MeetingFollowthroughTests(unittest.TestCase):
    def test_full_conditional_commitment_is_recovered(self):
        text='**Alex:** So if you leave your usernames, I will add you all in.'
        result=q.selected_notes(q.passages(text),json.dumps({k:[] for k in q.HEADINGS}))
        self.assertIn('So if you leave your usernames, I will add you all in.',result)
    def test_same_action_self_question_remains_unconfirmed(self):
        src=q.passages("**Alex:** Okay, I'll send you the map. Do I need to send it again or not?")
        selected={k:[] for k in q.HEADINGS};selected['action_items']=[src[0]['text']]
        with self.assertRaises(ValueError):q.selected_notes(src,json.dumps(selected))
    def test_different_followup_does_not_cancel_real_commitment(self):
        src=q.passages("**Alex:** I'll send the report. Do I need to include charts?")
        self.assertIn("I'll send the report.",q.selected_notes(src,json.dumps({k:[] for k in q.HEADINGS})))

class DisputedEstimateTests(unittest.TestCase):
    def test_explicit_disagreement_stays_with_estimate(self):
        src=q.passages("**Alex:** I don't think you can handle 65%.")
        summary='The group discussed that 65% could be handled by AI.'
        self.assertIn("Alex said, “I don't think you can handle 65%”",q.retain_disputed_numeric_estimate(src,summary))
    def test_different_number_or_topic_and_already_qualified_abstain(self):
        src=q.passages("**Alex:** I don't think you can handle 65%.")
        for summary in ['The estimate was 75% handled automatically.','The budget increased by 65%.','The 65% automation handling estimate was disputed.']:
            self.assertEqual(q.retain_disputed_numeric_estimate(src,summary),summary)
    def test_quotation_and_later_correction_abstain(self):
        for text in ["**Alex:** He said I don't think you can handle 65%.","**Alex:** I don't think you can handle 65%. Actually, I retract that estimate."]:
            summary='The group discussed that 65% could be handled by AI.'
            self.assertEqual(q.retain_disputed_numeric_estimate(q.passages(text),summary),summary)
