import json
import unittest
from meeting_quality import passages, ground_naming_proposal, selected_notes

class NamingProposalTests(unittest.TestCase):
    def test_wrong_subject_is_grounded_without_inventing_agreement(self):
        source=passages('**Speaker 2:** I suggest we call the media service Aurora.')
        result=ground_naming_proposal(source,'Speaker 2 suggested renaming the planning platform to Aurora.')
        self.assertEqual(result,'Speaker 2 said: “I suggest we call the media service Aurora.”')

    def test_accurate_paraphrase_and_unrelated_summary_unchanged(self):
        source=passages('**Speaker 2:** I suggest we call the media service Aurora.')
        for text in ['Speaker 2 suggested renaming the media service to Aurora.','The meeting discussed platform names.','Speaker 1 suggested renaming the planning platform to Aurora.','Speaker 2 suggested renaming the planning platform to Orion.']:
            self.assertEqual(ground_naming_proposal(source,text),text)

    def test_integration_clause_retains_its_own_exact_source(self):
        source=passages('**Speaker 2:** For the planning platform, should we connect these two together? So what I suggest is that we call this Aurora the media service.')
        text='Speaker 2 suggested renaming the planning platform to Aurora and integrating it with the media service. Tokens were discussed.'
        out=ground_naming_proposal(source,text)
        self.assertEqual(out,'Speaker 2 said: “For the planning platform, should we connect these two together?” “So what I suggest is that we call this Aurora the media service.” Tokens were discussed.')

    def test_compound_claim_without_unique_source_abstains(self):
        source=passages('**Speaker 2:** I suggest we call the media service Aurora.')
        for text in ['Speaker 2 suggested renaming the planning platform to Aurora and integrating it with the media service.','Speaker 2 suggested renaming the planning platform to Aurora and approving the budget.']:
            self.assertEqual(ground_naming_proposal(source,text),text)

    def test_correction_quotation_negation_and_ambiguous_proposals_abstain(self):
        base='**Speaker 2:** I suggest we call the media service Aurora.'
        text='Speaker 2 suggested renaming the planning platform to Aurora.'
        for source in [base+' Actually, I withdraw that proposal.',base+' I propose we call the planning platform Aurora.','**Speaker 2:** "I suggest we call the media service Aurora."','**Speaker 2:** I suggest we call the media service Aurora if approved.','**Speaker 2:** I suggest we call the media service not Aurora.']:
            self.assertEqual(ground_naming_proposal(passages(source),text),text)

    def test_unrelated_discussion_is_not_a_naming_retraction(self):
        source=passages('**Speaker 2:** I suggest we call the media service Aurora. Actually, the server is ready.')
        text='Speaker 2 suggested renaming the planning platform to Aurora.'
        self.assertIn('said:',ground_naming_proposal(source,text))

    def test_quoted_or_reported_summary_claim_abstains(self):
        source=passages('**Speaker 2:** I suggest we call the media service Aurora.')
        for text in ['Someone said Speaker 2 suggested renaming the planning platform to Aurora.', '“Speaker 2 suggested renaming the planning platform to Aurora.”']:
            self.assertEqual(ground_naming_proposal(source,text),text)

    def test_expansion_does_not_drop_a_long_summary(self):
        source=passages('**Speaker 2:** I suggest we call the media service Aurora.')
        text=' '.join(['Context']*145)+'. Speaker 2 suggested renaming the planning platform to Aurora.'
        # A longer proposal can exceed the renderer limit even though the
        # original paragraph fits. In that case retain the original paragraph.
        source=passages('**Speaker 2:** I suggest we call the media service Aurora to reflect its intended use for community stories and recordings.')
        self.assertLessEqual(len(text.split()),160)
        self.assertEqual(ground_naming_proposal(source,text),text)
        result=selected_notes(source,json.dumps({'summary':[text],'decisions':[],'action_items':[],'open_questions':[]}))
        self.assertIn(text,result)

    def test_uncertain_speaker_keeps_uncertain_label(self):
        source=passages('**Uncertain speaker:** I propose we name the media service Aurora.')
        text='Uncertain speaker proposed naming the planning platform as Aurora.'
        self.assertEqual(ground_naming_proposal(source,text),'Uncertain speaker said: “I propose we name the media service Aurora.”')

    def test_complete_notes_keep_commitments_and_other_summary(self):
        source=passages('**Speaker 2:** I suggest we call the media service Aurora. I will send the draft tomorrow.')
        raw=json.dumps({'summary':['Speaker 2 suggested renaming the planning platform to Aurora. The draft was discussed.'],'decisions':[],'action_items':[],'open_questions':[]})
        out=selected_notes(source,raw)
        self.assertIn('“I suggest we call the media service Aurora.” The draft was discussed.',out)
        self.assertIn('Speaker 2: I will send the draft tomorrow.',out)

if __name__=='__main__':unittest.main()
