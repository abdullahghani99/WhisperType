from polish import collapse_repeated_named_command
import re
import unittest
from polish import (copyedit,rejection_reason,rehearing,clean_stutters,spoken_symbols,looped_transcription,punctuation_is_faithful,
                    project_punctuation,words,starts_question,SYSTEM,EXAMPLES)

class CopyeditingTests(unittest.TestCase):
    def test_short_conditional_normalization_keeps_full_semantic_guard(self):
        from polish import conditional_restart_basis
        source = 'Since Orion and Vega if they approved it why is the draft still pending?'
        proposal = 'Since Orion and Vega approved it, why is the draft still pending?'
        expected = proposal.replace('Since', 'If')
        output, diag = copyedit(source, lambda *_: proposal)
        self.assertEqual(output, expected)
        self.assertIsNone(rejection_reason(conditional_restart_basis(source, output), output))
        self.assertIsNotNone(rejection_reason(conditional_restart_basis(source, output), expected.replace('pending', 'approved')))
        for original in ['Since Orion and Vega approved it, why is it pending?',
                         'Since Orion if he approved it why is it pending? Since Orion approved it, send it.',
                         'Since Orion if he approved it, sorry, he did approve it, why is it pending?']:
            self.assertEqual(conditional_restart_basis(original, 'If Orion approved it, why is it pending?'), original)

    def test_manner_aside_repairs_only_introduced_sentence_break(self):
        source = 'It should be Atlas or something right how we normally do it with our other platforms'
        proposed = 'It should be Atlas or something right? How we normally do it with our other platforms.'
        output, _ = copyedit(source, lambda *_: proposed)
        self.assertEqual(output, 'It should be Atlas or something—how we normally do it with our other platforms, right?')
        authored = 'It should be Atlas or something, right? How do we normally do it with our other platforms?'
        self.assertEqual(copyedit(authored, lambda *_: authored)[0], authored)

    def test_manner_conditional_and_nominal_have_different_boundaries(self):
        cases = [
            ('It should be Atlas or something right how we usually do it if the account is ready.',
             'It should be Atlas, or something right? How we usually do it if the account is ready.',
             'It should be Atlas or something—how we usually do it if the account is ready, right?'),
            ('It should be Atlas or something right how we actually do it depends on the account.',
             'It should be Atlas, or something right how we actually do it depends on the account.',
             'It should be Atlas or something, right? How we actually do it depends on the account.')]
        for source, proposal, expected in cases:
            self.assertEqual(copyedit(source, lambda *_: proposal)[0], expected)
            self.assertIsNone(rejection_reason(source, expected))

    def test_temporal_frame_retains_explicit_later_request(self):
        source = "You decide and go ahead and while you do that can you also include Morgan's changes."
        proposal = "You decide and go ahead. While you do that, can you also include Morgan's changes."
        output, diag = copyedit(source, lambda *_: proposal)
        self.assertEqual(output, proposal[:-1] + '?')
        self.assertIn('framed_request', diag['local_repairs'])

    def test_temporal_frame_preserves_statements_quotes_and_reporting_predicates(self):
        from polish import repair_framed_request
        for text in ['While you do that, you can include the changes.',
                     'While you do that, can you help me is all she said.',
                     'The label is "while you do that can you help me."']:
            self.assertEqual(repair_framed_request(text, text), text)

    def test_descriptive_attachment_keeps_one_subject_and_coordinated_details(self):
        cases = [
            ('The parcel, the label and seal on the parcel, for this the parcel does not arrive.',
             'The parcel, the label, and the seal on the parcel do not arrive.',
             'The parcel, with the label and seal on it, does not arrive.'),
            ('The parcel, the label on the parcel, for this the parcel does not arrive. Keep both copies.',
             'The parcel and the label on the parcel do not arrive. Keep both copies.',
             'The parcel, with the label on it, does not arrive. Keep both copies.'),
            ('The image, the caption on the image, for this the image is unclear.',
             'The image and the caption on the image are unclear.',
             'The image, with the caption on it, is unclear.')]
        for source, proposed, expected in cases:
            self.assertEqual(copyedit(source, lambda *_: proposed)[0], expected)
            self.assertIsNone(rejection_reason(source, expected))

    def test_descriptive_attachment_preserves_distinct_subjects_and_animate_heads(self):
        from polish import restore_descriptive_attachment
        cases = ['The parcel and the label on the parcel do not arrive.',
                 'The parcel, the label and the seal do not arrive.',
                 'The woman, the label on the woman, for this the woman does not arrive.',
                 'Not the parcel, the label on the parcel, for this the parcel does not arrive.',
                 'The parcel, the label or seal on the parcel, for this the parcel does not arrive.',
                 'The title is "the parcel, the label on the parcel, for this the parcel does not arrive."']
        for source in cases:self.assertEqual(restore_descriptive_attachment(source, source), source)

    def test_exception_repair_restores_group_and_retains_source_wording(self):
        source = 'We tried access for ten people yesterday. Everyone got access instead of these people because I think their accounts differed. Can you check?'
        proposal = 'We tried access for ten people yesterday. Instead, everyone got access because I think their accounts differed. Can you check?'
        output, diag = copyedit(source, lambda *_: proposal)
        self.assertEqual(output, source)
        self.assertIn('excluded_group', diag['local_repairs'])

    def test_explicit_exception_before_and_after_predicate(self):
        from polish import restore_excluded_group
        for source in ['Everyone except Maya got access.', 'Everyone got access except Maya.',
                       'Everybody received the email apart from those reviewers.',
                       'Everyone other than Luis got access.']:
            proposal = re.sub(r'(?:except Maya |other than Luis )', '', source)
            proposal = re.sub(r' (?:except Maya|apart from those reviewers)', '', proposal)
            self.assertEqual(restore_excluded_group(source, proposal), source)
            self.assertEqual(copyedit(source, lambda *_: proposal)[0], source)

    def test_exception_abstains_on_alternative_actions_and_ambiguous_alignment(self):
        from polish import restore_excluded_group
        pairs = [('Everyone got access instead of a refund.', 'Everyone got access.'),
                 ('Everyone got access instead of these people from Finance.', 'Everyone got access.'),
                 ('Everyone got access except Maya Johnson.', 'Everyone got access.'),
                 ('Everyone except Maya got access. Everyone got access later.', 'Everyone got access. Everyone got access later.'),
                 ('Everyone except Maya got access.', 'Everyone except Luis got access.'),
                 ('The label is "Everyone except Maya got access."', 'The label is "Everyone got access."'),
                 ('Everyone got access instead of these people, sorry, those people.', 'Everyone got access.')]
        for source, proposed in pairs:self.assertEqual(restore_excluded_group(source, proposed), proposed)

    def test_conditional_restart_restores_uncertainty_and_keeps_cleanup(self):
        prefix = 'Please retain the original draft, approval records, contract terms, delivery dates and supporting documents for our independent review. '
        source = prefix + 'Since Orion and Vega if they approved it why is the draft actually still pending?'
        proposal = prefix + 'Since Orion and Vega approved it, why is the draft actually still pending?'
        out, diag = copyedit(source, lambda *_: proposal)
        self.assertEqual(out, proposal.replace('Since', 'If'))
        self.assertIn('conditional_restart', diag['local_repairs'])

    def test_repeated_actors_cannot_transfer_a_condition_to_an_assertion(self):
        from polish import repair_conditional_restart, repair_embedded_question
        source = 'Since Orion if he approved it why is the draft pending? Since Orion approved it, send the copy.'
        proposal = 'If Orion approved it, why is the draft pending? Since Orion approved it, send the copy.'
        self.assertEqual(repair_conditional_restart(source, proposal), proposal)
        source = 'I discussed with you that what should we publish today? I discussed with you that we should publish today.'
        proposal = 'I discussed with you what we should publish today. I discussed with you that we should publish today.'
        self.assertEqual(repair_embedded_question(source, proposal), proposal)

    def test_conditional_restart_abstains_on_assertions_corrections_and_quotes(self):
        from polish import repair_conditional_restart
        for source in ['Since Orion and Vega approved it, why is it pending?',
                       'Since Orion and Vega if they approved it, sorry, they did approve it.',
                       'The title is "Since Orion if he approved it why is it pending?"',
                       'Since Orion approved it, I wonder if Vega approved it.',
                       'Since Orion if he did not approve it why is it pending?']:
            proposal = 'Since Orion and Vega approved it, why is it pending?'
            self.assertEqual(repair_conditional_restart(source, proposal), proposal)

    def test_embedded_question_restores_choice_without_losing_other_questions(self):
        source = 'Which draft is ready? I discussed with you that what should we actually publish? Keep both copies.'
        proposal = 'Which draft is ready? I discussed with you that we should actually publish. Keep both copies.'
        out, diag = copyedit(source, lambda *_: proposal)
        self.assertEqual(out, 'Which draft is ready? I discussed with you: what should we actually publish? Keep both copies.')
        self.assertIn('embedded_question', diag['local_repairs'])

    def test_embedded_question_accepts_faithful_indirect_and_statement_forms(self):
        from polish import repair_embedded_question
        pairs = [('I discussed with you that what should we actually publish?',
                  'I discussed with you what we should actually publish.'),
                 ('I discussed with you that we should actually publish.',
                  'I discussed with you that we should actually publish.'),
                 ('What matters is that we should publish the draft.',
                  'What matters is that we should publish the draft.'),
                 ('I asked you: what should we publish today?', 'I asked you what we should publish today.'),
                 ('The title is "I discussed with you that what should we publish today?"',
                  'The title is "I discussed with you that we should publish today."')]
        for source, output in pairs:self.assertEqual(repair_embedded_question(source, output), output)

    def test_confirmation_retains_source_time_reference_without_extra_inference(self):
        source = "That was the main point of it, isn't it? Keep the original."
        proposal = source.replace("isn't", "wasn't")
        calls = []
        def generate(*_):calls.append(1);return proposal
        out, diag = copyedit(source, generate)
        self.assertEqual(out, source)
        self.assertEqual(len(calls), 1)
        self.assertIn('confirmation_tense', diag['local_repairs'])

    def test_confirmation_abstains_on_changed_anchor_correction_and_quote(self):
        from polish import restore_confirmation_tense
        for source, proposal in [
            ("It is the point of it, isn't it?", "It was a different subject, wasn't it?"),
            ("It is the point of it, isn't it? Sorry, wasn't it?", "It is the point of it, wasn't it?"),
            ('''The label is "the point of it, isn't it?"''', '''The label is "the point of it, wasn't it?"'''),
            ("That was the point of it, wasn't it?", "That was the point of it, wasn't it?")]:
            self.assertEqual(restore_confirmation_tense(source, proposal), proposal)

    def test_confirmation_manner_attaches_aside_and_keeps_uncertainty(self):
        source = 'I think it should be sign in with Atlas or something right how we actually do it with the other other platforms'
        proposal = source.replace('other other', 'other').replace('right how', 'right, how') + '?'
        out, diag = copyedit(source, lambda *_: proposal)
        self.assertEqual(out, 'I think it should be sign in with Atlas or something—how we actually do it with the other platforms, right?')
        self.assertIn('confirmation_manner', diag['local_repairs'])

    def test_confirmation_manner_preserves_separate_questions_and_literal_directions(self):
        from polish import repair_confirmation_manner_boundary
        cases = ['It should be Atlas or something, right? How do we actually do it elsewhere?',
                 'It should be Atlas or something right how do we actually do it elsewhere?',
                 'It should be on the right where we normally place the button.',
                 'The label is "it should be Atlas or something right how we normally do it".']
        for source in cases:self.assertEqual(repair_confirmation_manner_boundary(source, source), source)

    def test_copular_fragment_retains_modifiers_and_other_clauses(self):
        from polish import collapse_copular_fragments
        source = "It's suddenly just it's very abrupt when you open it. I think we can improve it."
        expected = "It's suddenly just very abrupt when you open it. I think we can improve it."
        self.assertEqual(collapse_copular_fragments(source), expected)
        out, diag = copyedit(source, lambda *_: source)
        self.assertEqual(out, expected)
        self.assertIn('copular_fragment', diag['local_repairs'])
        self.assertIsNone(rejection_reason(source, out))

    def test_copular_fragment_abstains_on_predicates_quotes_polarity_and_subjects(self):
        from polish import collapse_copular_fragments
        cases = ["It's ready, it's very abrupt when you open it.",
                 "It's just she's very abrupt when speaking.",
                 "It's just it's not ready for release.",
                 "It's not it's ready for release.",
                 "It's just. It's very abrupt when you open it.",
                 'The title is "it is just it is very abrupt".',
                 "It's very, it's very good today.",
                 "It's actually it's", "It's just it's only a draft."]
        for value in cases:
            with self.subTest(value=value):self.assertEqual(collapse_copular_fragments(value), value)

    def test_each_question_boundary_is_independently_recovered(self):
        from polish import repair_local_question_boundaries
        source = "The draft is ready. Can you send it. Where do we put the original?"
        expected = "The draft is ready. Can you send it? Where do we put the original?"
        self.assertEqual(repair_local_question_boundaries(source, source), expected)
        out, diag = copyedit(source, lambda *_: source)
        self.assertEqual(out, expected)
        self.assertEqual(diag['local_repairs'], ['question_boundary'])

    def test_question_pivot_preserves_following_statement(self):
        from polish import repair_local_question_boundaries
        source = ("We need a test account. What is that best way so we give them access "
                  "to the sandbox right but obviously I do not want production changes.")
        expected = source.replace('right but', 'right? But')
        self.assertEqual(repair_local_question_boundaries(source, source), expected)
        self.assertTrue(expected.endswith('production changes.'))
        self.assertIsNone(rejection_reason(source, expected))

    def test_discourse_infinitive_question_and_plain_heading_are_distinct(self):
        from polish import repair_local_question_boundaries
        source = 'And how to now connect this account. Also, the draft is ready.'
        self.assertEqual(repair_local_question_boundaries(source, source), source.replace('account.', 'account?'))
        for source in ('How to connect this account.', 'Chapter one. And how to connect this account.',
                       'The heading is: And how to connect this account.'):
            self.assertEqual(repair_local_question_boundaries(source, source), source)

    def test_local_question_boundary_abstains_on_nonquestions_and_identifiers(self):
        from polish import repair_local_question_boundaries
        cases = ['What is important is that we keep the original.',
                 'How is that done is unclear.', 'I know how we connect it.',
                 'How do we connect it depends on the account.',
                 'Can you help me is all she said.', 'How do we finish it remains to be seen.',
                 'The label says "Can you send it."', 'Can you check example.org. The draft is ready.',
                 'Can you check the U.S. report.', 'Can you check version 2.5. It is ready.',
                 'What is right but obviously incomplete?', 'Do it. The draft is ready.',
                 'Can you send it? But obviously retain the original.']
        for source in cases:
            with self.subTest(source=source):self.assertEqual(repair_local_question_boundaries(source, source), source)

    def test_local_cleanup_adds_no_inference_and_preserves_rejection_safety(self):
        source = "It's actually it's very slow today. Can you check it."
        calls = []
        def generate(*_):calls.append(True);return source
        out, diag = copyedit(source, generate)
        self.assertEqual(out, "It's actually very slow today. Can you check it?")
        self.assertEqual(len(calls), 1)
        self.assertIsNone(rejection_reason(source, out))

    def test_qualified_restart_survives_an_unrelated_question_failure(self):
        source = ("So can you finish the task. And also I cannot see the headings right now "
                  "when I'm generating, trying to generate a document.")
        proposal = ("Can you finish the task. Also I cannot see the headings "
                    "when I'm trying to generate a document.")
        output, diag = copyedit(source, lambda *_: proposal)
        self.assertEqual(output, "So can you finish the task? And also I cannot see the headings right now "
                         "when I'm trying to generate a document.")
        self.assertTrue(diag['reused_candidate'])
        self.assertIsNone(rejection_reason(source, output))

    def test_question_boundary_inference_does_not_change_statements_or_quotes(self):
        for source in ('We can finish the task. Send it tomorrow.',
                       '"Can you finish the task." That is the quotation.'):
            self.assertEqual(project_punctuation(source, source), source)
        self.assertEqual(project_punctuation('Can you finish the task. Send it tomorrow.',
                                            'Can you finish the task. Send it tomorrow.'),
                         'Can you finish the task. Send it tomorrow.')

    def test_demonstrative_clause_deletion_preserves_distinct_point(self):
        source = ('We have the templates for every department, so we have those '
                  'rules already there. I can send the templates to you.')
        output = ('We have the templates for every department, so I can send '
                  'the templates to you.')
        self.assertEqual(rejection_reason(source, output), 'deleted_finite_clause')
        for determiner in ('this', 'that', 'these', 'those'):
            noun = 'reference' if determiner in ('this', 'that') else 'references'
            source = f'We have the templates. We have {determiner} {noun} already available. I can send it.'
            with self.subTest(determiner=determiner):
                self.assertEqual(rejection_reason(source, 'We have the templates. I can send it.'),
                                 'deleted_finite_clause')

    def test_demonstratives_allow_restarts_deduplication_and_coordination(self):
        pairs = [
            ('We have that, we have the template ready.', 'We have the template ready.'),
            ('We have those, we have those templates ready.', 'We have those templates ready.'),
            ('We have those rules already there. We have those rules already there.',
             'We have those rules already there.'),
            ('We have those rules already there, sorry, we still need to write them.',
             'We still need to write them.'),
            ('I reviewed this draft. I approved this draft.', 'I reviewed and approved this draft.'),
        ]
        from polish import deleted_finite_clause
        for source, output in pairs:
            with self.subTest(source=source):
                self.assertFalse(deleted_finite_clause(source, output))

    def test_attribution_uses_the_aligned_verb_occurrence(self):
        from polish import internal_attribution_changed
        # The project and the people can both "start" without sharing a subject.
        self.assertFalse(internal_attribution_changed(
            'We started with a draft. Here is the project, which started in May.',
            'We started with a draft. Here is the project. It started in May.'))
        # Reusing a verb elsewhere must not license changing this occurrence.
        self.assertTrue(internal_attribution_changed(
            'We reviewed the draft. You reviewed the final report.',
            'We reviewed the draft. We reviewed the final report.'))
        self.assertIsNone(rejection_reason(
            'Whenever I want it, want to close it, it stays open.',
            'Whenever I want to close it, it stays open.'))

    def test_conditional_cues_cannot_use_the_content_loss_budget(self):
        pairs = [
            ('Please review the draft, check the spelling, grammar, layout and formatting. '
             'If everything is fine, otherwise revise it.',
             'Please review the draft, check the spelling, grammar, layout and formatting. '
             'If everything is fine, revise it.'),
            ('Please check the draft, spelling, grammar, layout, formatting and references. '
             'Unless the editor approves it, hold publication.',
             'Please check the draft, spelling, grammar, layout, formatting and references. '
             'The editor approves it; hold publication.'),
            ('The draft is otherwise fine. Please check the spelling, grammar, formatting, '
             'references and page numbers.',
             'The draft is fine. Please check the spelling, grammar, formatting, '
             'references and page numbers.'),
        ]
        for source, output in pairs:
            with self.subTest(source=source):
                self.assertEqual(rejection_reason(source, output), 'conditional_cue_removed')

    def test_conditional_cleanup_keeps_final_cue(self):
        pairs = [
            ('If it is ready, send it, otherwise otherwise wait.',
             'If it is ready, send it; otherwise wait.'),
            ('If it is ready, send it; otherwise wait, sorry, otherwise ask me.',
             'If it is ready, send it; otherwise ask me.'),
            ('Unless unless the editor approves it, hold publication.',
             'Unless the editor approves it, hold publication.'),
            ('If the draft is ready, um, send it. Otherwise, wait.',
             'If the draft is ready, send it. Otherwise, wait.'),
        ]
        for source, output in pairs:
            with self.subTest(source=source):
                self.assertIsNone(rejection_reason(source, output))

    def test_conditional_recovery_restores_deleted_branch_cue(self):
        source = ('Please review the draft, check the spelling, grammar, layout and formatting. '
                  'If everything is fine, otherwise revise it.')
        proposal = source.replace('otherwise ', '')
        output, event = copyedit(source, lambda *args: proposal)
        self.assertIn('otherwise', words(output))
        self.assertEqual(words(output), words(source))
        self.assertEqual(event['status'], 'verbatim_recovery')
        self.assertEqual(event['rejection'], 'conditional_cue_removed')

    def test_internal_subject_must_stay_with_its_predicate(self):
        pairs = [
            ('Note here is that we... You actually asked me to update the report.',
             'Note here is that we actually asked me to update the report.'),
            ('The issue is that she approved the report and we sent it.',
             'The issue is that we approved the report and sent it.'),
            ('Please remember that they reviewed the report and you sent it.',
             'Please remember that you reviewed the report and sent it.'),
        ]
        for source, output in pairs:
            with self.subTest(source=source):
                self.assertIsNotNone(rejection_reason(source, output))

    def test_internal_subject_allows_corrections_and_punctuation(self):
        pairs = [
            ('Note that I sent it, sorry, we sent it.', 'Note that we sent it.'),
            ('Well, you reviewed it, I mean I reviewed it.', 'Well, I reviewed it.'),
            ('The issue is that she actually approved the report and we sent it.',
             'The issue is that she approved the report. We sent it.'),
            ('Please remember that we will review the report and you can send it.',
             'Please remember that we will review the report, and you can send it.'),
            ('Can you check when were they given access?',
             'Can you check when they were given access?'),
            ("The issue is they're reviewing it and we're waiting.",
             'The issue is they are reviewing it, and we are waiting.'),
        ]
        for source, output in pairs:
            with self.subTest(source=source):
                self.assertIsNone(rejection_reason(source, output))

    def test_complete_deleted_point_is_not_a_restart(self):
        pairs = [
            ('They, I called them, they confirmed the delivery and sent the tracking information.',
             'They confirmed the delivery and sent the tracking information.'),
            ('You have the draft. And you are working on it, correct? Please check its spelling and layout.',
             'You have the draft, correct? Please check its spelling and layout.'),
        ]
        for source, output in pairs:
            with self.subTest(source=source):
                self.assertIsNotNone(rejection_reason(source, output))

    def test_deleted_clause_guard_allows_coordination_and_punctuation(self):
        pairs = [
            ('I called them. I emailed them.', 'I called and emailed them.'),
            ('We checked it. We approved it.', 'We checked and approved it.'),
            ('You are reviewing it. You are approving it.',
             'You are reviewing and approving it.'),
            ('We are currently reviewing the draft.', 'We are, currently, reviewing the draft.'),
            ('We have naming conventions for the folders.', 'We have a naming convention for the folders.'),
            ('You are reviewing the draft.', "You're reviewing the draft."),
        ]
        for source, output in pairs:
            with self.subTest(source=source):
                self.assertIsNone(rejection_reason(source, output))

    def test_deleted_clause_guard_allows_corrections_and_fragments(self):
        pairs = [
            ('I called them, sorry, I emailed them.', 'I emailed them.'),
            ('We checked it. We checked it.', 'We checked it.'),
            ('The thing is we have basically I have a, I have a contact.',
             'The thing is I have a contact.'),
            ('She is really like, her work speaks for itself.', 'Her work speaks for itself.'),
        ]
        # The last edit can still be refused by the existing initial-attribution
        # rule; this new check must not misidentify its fragment as a lost point.
        from polish import deleted_finite_clause
        for source, output in pairs:
            with self.subTest(source=source):
                self.assertFalse(deleted_finite_clause(source, output))
    def test_question_period_projection_preserves_words_after_grammar_edit(self):
        source = "Why don't you download the recording and look it for yourself as well."
        proposal = "Why don't you download the recording and look at it for yourself as well?"
        expected = source[:-1] + '?'
        self.assertEqual(project_punctuation(source, proposal), expected)
        self.assertTrue(punctuation_is_faithful(source, expected))
        replies = iter([proposal[:-1] + '.', proposal])
        result, event = copyedit(source, lambda *_: next(replies))
        self.assertEqual(result, expected)
        self.assertEqual(event['status'], 'punctuation_projection')
        self.assertEqual(words(result, expand=False), words(source, expand=False))

    def test_question_period_projection_does_not_reinterpret_other_boundaries(self):
        controls = [
            ('I can send it.', 'I can send it?'),
            ('What I need is the original.', 'What I need is the original?'),
            ("What's very important is that we keep the original.",
             "What's very important is that we keep the original?"),
            ('Do it however you want.', 'Do it however you want?'),
            ('Can you send it. Is that possible.', 'Can you send it. Is that possible?'),
            ('Can you check the U.S.', 'Can you check the U.S.?'),
            ('Can you send it...', 'Can you send it?'),
            ('Can you send it!', 'Can you send it?'),
            ('Can you send it?', 'Can you send it.'),
            ('Can you check version 2.2.', 'Can you check version 2.2?'),
            ('Can you check https://example.com.', 'Can you check https://example.com?'),
            ('Can you say "send it".', 'Can you say "send it"?'),
        ]
        for source, proposal in controls:
            with self.subTest(source=source):
                self.assertEqual(project_punctuation(source, proposal), source)

    def test_pseudo_clefts_are_statements_but_echo_questions_survive(self):
        from polish import starts_question
        for source in ["What's very important is that we keep the draft.",
                       'What is missing is the original.',
                       'What was wrong was the order.']:
            with self.subTest(source=source):
                self.assertFalse(starts_question(source))
                self.assertIsNone(rejection_reason(source, source))
                self.assertTrue(starts_question(source[:-1] + '?'))
        for source in ['What is important here?', 'What is the missing draft?',
                       'What was wrong with the order?']:
            self.assertTrue(starts_question(source))

    def test_prefixed_and_topic_questions_need_punctuation(self):
        for source in ['Also, can you send the draft.',
                       'So, looking into the project, how do we connect the tools.',
                       'Regarding the draft, can we send it.']:
            self.assertEqual(rejection_reason(source, source), 'question_punctuation')
        from polish import starts_question
        self.assertFalse(starts_question('Regarding the draft, I know how we connect the tools.'))
        self.assertFalse(starts_question('Also, send the draft.'))

    def test_first_question_projection_preserves_following_statements(self):
        source = 'Can you finish these all for the draft. Then send the original.'
        proposal = 'Can you finish all of these for the draft? Then send the original.'
        expected = 'Can you finish these all for the draft? Then send the original.'
        self.assertEqual(project_punctuation(source, proposal), expected)
        self.assertTrue(punctuation_is_faithful(source, expected))
        # Later boundaries are not inferred from a question earlier in the text.
        self.assertEqual(project_punctuation('Can you send it. Is that possible.',
                                             'Can you send it. Is that possible?'),
                         'Can you send it. Is that possible.')

    def test_apology_is_not_a_global_content_deletion_permission(self):
        pairs = [
            ('Sorry, please send the draft and archive the original.', 'Please send the draft.'),
            ('Sorry, please send the draft and archive the original.', 'Sorry, please send the draft.'),
            ('Send it to John, sorry, to Jane. Sorry for the delay.', 'Send it to Jane.'),
            ('I mean please send the draft and archive the original.', 'Please send the draft.'),
            ('Archive the original. Send it to John, sorry, to Jane.', 'Send it to Jane.'),
            ('Archive the original and send it to John, sorry, to Jane.', 'Send it to Jane.'),
        ]
        for source, output in pairs:
            with self.subTest(source=source, output=output):
                self.assertIsNotNone(rejection_reason(source, output))

    def test_local_corrections_and_independent_apologies_still_clean_up(self):
        pairs = [
            ('Send the draft, sorry, I mean the original.', 'Send the original.'),
            ('Sorry, not the draft, but the original.', 'Not the draft, but the original.'),
            ('Sorry, not family permits, but family visas.', 'Family visas, but not family permits.'),
            ('Send it to John, sorry, to Jane. Sorry for the delay.',
             'Send it to Jane. Sorry for the delay.'),
            ('I called them, sorry, I emailed them.', 'I emailed them.'),
            ('Sorry, can you please continue?', 'Sorry, can you continue?'),
            ('The client said sorry for the delay.', 'The client said sorry for the delay.'),
        ]
        for source, output in pairs:
            with self.subTest(source=source): self.assertIsNone(rejection_reason(source, output))

    def test_literal_knowledge_is_not_filler(self):
        source = 'You know my work. Please review the draft.'
        self.assertEqual(rejection_reason(source, 'My work. Please review the draft.'), 'literal_clause_removed')
        self.assertIsNone(rejection_reason('Please, you know, review my work.', 'Please review my work.'))
        self.assertIsNone(rejection_reason(source, source))

    def test_dictionary_names_require_a_local_nonfiller_substitution(self):
        for source, output in [
            ('Please send the report, you know.', 'Please send the report to Microsoft.'),
            ('Well, please send the report.', 'Please send the report to Microsoft.'),
            ('Please send the report actually tomorrow.', 'Please send the report to Microsoft tomorrow.'),
        ]:
            with self.subTest(source=source):
                self.assertEqual(rejection_reason(source, output, known_terms=['Microsoft']), 'new_content')
        self.assertIsNone(rejection_reason('Please send it to Microsystems.',
                                          'Please send it to Microsoft.', known_terms=['Microsoft']))

    def test_numeric_references_stay_prose_and_actual_lists_survive(self):
        source = 'See how references 1, 2, and 3 are merged into the text.'
        output = 'See how references:\n1. 1\n2. 2\n3. 3\nare merged into the text.'
        self.assertEqual(rejection_reason(source, output), 'numeric_reference_list')
        self.assertIsNone(rejection_reason(source, source))
        self.assertIsNone(rejection_reason('List these references: 1, 2, and 3.',
                                          'List these references:\n1. 1\n2. 2\n3. 3.'))
        self.assertIsNone(rejection_reason('First review the draft then send the original.',
                                          '1. Review the draft\n2. Then send the original.'))

    def test_protected_words_restore_without_discarding_valid_cleanup(self):
        pairs = [
            ('Sorry, man, I have actually been busy.', 'I have been busy.', 'Sorry, man, I have been busy.'),
            ('Sorry, please review the draft.', 'Please review the draft.', 'Sorry, please review the draft.'),
            ('You know my work and actually my draft.', 'My work and my draft.', 'You know my work and my draft.'),
            ('Please review it. You know my work and actually my draft.',
             'Please review it. My work and my draft.', 'Please review it. You know my work and my draft.'),
        ]
        for source, proposal, expected in pairs:
            calls = []
            def generate(*args):
                calls.append(args); return proposal
            with self.subTest(source=source):
                result, event = copyedit(source, generate)
                self.assertEqual(result, expected)
                self.assertEqual(len(calls), 1)
                self.assertTrue(event['restored_source_words'])
        # Restoring the prefix cannot license deletion of an unrelated point.
        source = 'Sorry, please send the draft and archive the original.'
        result, _ = copyedit(source, lambda *_: 'Please send the draft.')
        self.assertIn('archive', result)

    def test_qualified_restart_keeps_trying_and_does_not_flatten_activities(self):
        source = "When I'm generating, trying to generate a report, I cannot see the headers."
        proposal = "When I'm generating a report, I cannot see the headers."
        result, event = copyedit(source, lambda *_: proposal)
        self.assertEqual(result, "When I'm trying to generate a report, I cannot see the headers.")
        self.assertTrue(event['restored_source_words'])
        from polish import restore_qualified_restart
        controls = [
            'We distinguish generating, trying to generate, and reviewing as three different activities.',
            "When I'm not generating, trying to generate a report, I check the draft.",
            "When I'm generating, trying to generate a report, or reviewing, I check the draft.",
            "When I'm generating, trying to generate a report, I count both activities.",
            "When I'm writing, trying to read a report, I check the draft.",
        ]
        for value in controls:
            with self.subTest(value=value): self.assertEqual(restore_qualified_restart(value, proposal), proposal)

    def test_related_categories_cannot_be_merged_by_deleting_the_separator(self):
        source = 'The reviewer and reviewer related and the top ones remain.'
        proposal = 'The reviewer and reviewer-related top ones remain.'
        self.assertEqual(rejection_reason(source, proposal), 'related_coordination')
        result, event = copyedit(source, lambda *_: proposal)
        self.assertEqual(result, 'The reviewer and reviewer-related and the top ones remain.')
        self.assertTrue(event['restored_source_words'])
        for source, proposal in [
            ('The reviewers and editors and leads remain.', 'The reviewers, editors, and leads remain.'),
            ('The reviewers and reviewers and leads remain.', 'The reviewers and leads remain.'),
            ('The reviewer related and the top ones remain.', 'The reviewer-related, the top ones remain.'),
        ]:
            self.assertIsNone(rejection_reason(source, proposal))

    def test_free_choice_attachment_keeps_contrast_and_ambiguous_readings(self):
        source = 'Update the draft however you want to do it because I need it.'
        proposal = 'Update the draft. However, you want to do it because I need it.'
        self.assertEqual(rejection_reason(source, proposal), 'free_choice_attachment')
        self.assertEqual(project_punctuation(source, proposal), source)
        from polish import free_choice_span
        for value in [
            'Update the draft. However, you want to do it differently.',
            'I prefer a table however you want to do it as text.',
            'However hard you try, the task stays difficult.',
            'Update the phrase "however you want to do it" in the draft.',
        ]:
            self.assertIsNone(free_choice_span(value))
            self.assertIsNone(rejection_reason(value, value))

    def test_deleted_question_cannot_be_discounted_as_a_tag(self):
        source = ('Should we renew the draft? Do we make it right? '
                  'What do we do next? We need a draft, right?')
        output = 'Should we renew the draft? What do we do next? We need a draft, right?'
        self.assertEqual(rejection_reason(source, output), 'deleted_question')
        from polish import deleted_tag_ending_question
        for predicate in ('right', 'correct', 'okay'):
            with self.subTest(predicate=predicate):
                self.assertTrue(deleted_tag_ending_question(
                    f'We need a draft. Is it {predicate}? Please send it.',
                    'We need a draft. Please send it.'))

    def test_deleted_question_allows_repetition_tags_and_local_correction(self):
        from polish import deleted_tag_ending_question
        pairs = [
            ('We need a draft, right?', 'We need a draft.'),
            ('We need a draft. Right?', 'We need a draft.'),
            ('Do we make it right? Do we make it right?', 'Do we make it right?'),
            ('Do we make it right? Sorry, I mean do we leave it alone?',
             'Do we leave it alone?'),
            ('Do we make it right? No, I mean do we leave it alone?',
             'Do we leave it alone?'),
            ('Can we check it, right?', 'Can we check it?'),
            ('We discussed whether we make it right.', 'We discussed whether we make it right.'),
        ]
        for source, output in pairs:
            with self.subTest(source=source):
                self.assertFalse(deleted_tag_ending_question(source, output))
                # The existing polarity check still rejects removing an
                # explicit No. This repair must not weaken that separate guard.
                expected = 'numbers_or_negation' if 'No, I mean' in source else None
                self.assertEqual(rejection_reason(source, output), expected)
        # Apologizing for confusion does not withdraw the preceding question.
        self.assertTrue(deleted_tag_ending_question(
            'We need a draft. Do we make it right? Sorry for the confusion. Please send it.',
            'We need a draft. Sorry for the confusion. Please send it.'))

    def test_missing_question_mark_recovery_receives_specific_context(self):
        source = 'By the way, have you checked the draft.'
        calls = []
        def generate(system, text):
            calls.append(system)
            return source if len(calls) == 1 else source[:-1] + '?'
        output, event = copyedit(source, generate)
        self.assertEqual(output, source[:-1] + '?')
        self.assertEqual(event['status'], 'punctuation_recovery')
        self.assertIn('opening sentence is a direct question', calls[1])

    def test_statement_recovery_does_not_receive_question_instruction(self):
        source = 'By the way what I need is the original'
        calls = []
        def generate(system, text):
            calls.append(system)
            return '' if len(calls) == 1 else source + '.'
        output, event = copyedit(source, generate)
        self.assertEqual(output, source + '.')
        self.assertNotIn('opening sentence is a direct question', calls[1])

    def test_discourse_prefix_does_not_hide_question_punctuation(self):
        for source in ('By the way, have you checked the draft.',
                       "So by the way, don't you need the original."):
            with self.subTest(source=source):
                self.assertTrue(starts_question(source))
                self.assertEqual(rejection_reason(source, source), 'question_punctuation')
                self.assertIsNone(rejection_reason(source, source[:-1] + '?'))

    def test_discourse_prefix_keeps_statements_and_embedded_questions(self):
        for source in ('By the way, I have checked the draft.',
                       'By the way, what I need is the original.',
                       'So by the way, the report explains how we checked it.'):
            with self.subTest(source=source):
                self.assertFalse(starts_question(source))
                self.assertIsNone(rejection_reason(source, source))

    def test_do_it_imperative_can_receive_punctuation(self):
        source = 'Do it however you want to do it but keep a backup.'
        output = 'Do it however you want to do it, but keep a backup.'
        self.assertFalse(starts_question(source))
        self.assertTrue(punctuation_is_faithful(source, output))
        for question in ('Do you want a backup?', 'Does it need a backup?', 'Do it?'):
            self.assertTrue(starts_question(question))
        self.assertEqual(rejection_reason('Do it?', 'Do it.'), 'question_intent')

    def test_preserves_intent(self):
        pairs=[("Don't you use the documentation skills?","Don't use the documentation skills."),
               ('Can you check the report?','The report is ready.'),
               ('Do not approve $150.','Do approve $150.'),
               ('Send 15 copies.','Send 50 copies.'),
               ('Alex owes Sam fifty dollars.','Sam owes Alex fifty dollars.'),
               ('You are saying the report is late.','I am saying the report is late.'),
               ('What is the update?','What is the update? It is complete.'),
               ('overtime and approved overtime','approved overtime')]
        for src,out in pairs:
            with self.subTest(src=src):self.assertIsNotNone(rejection_reason(src,out))
    def test_incomplete_new_sentence_rejected(self):
        self.assertEqual(rejection_reason('he is getting the same check his message','He is getting the same check. His message'),'unfinished_sentence')
        self.assertIsNotNone(rejection_reason("But shouldn't that be visible","But shouldn't that be visible."))
    def test_useful_edits(self):
        pairs=[('he cannot see his earning','He cannot see his earnings.'),('why are we not deploying and get the job done','Why are we not deploying and getting the job done?'),
               ("Let's close the points and what I was thinking is we make a post.","Let's close the points. What I was thinking is we make a post."),
               ('This includes leaves, this includes overtime and approved overtime.','This includes leaves, overtime and approved overtime.'),
               ('Please check the queue. Then check the report.','1. Please check the queue.\n2. Then check the report.'),
               ('send it to John sorry to Jane','Send it to Jane.')]
        for src,out in pairs:
            with self.subTest(src=src):self.assertIsNone(rejection_reason(src,out))
    def test_recovery_keeps_words_and_restores_punctuation(self):
        outputs=iter(['The report is finished.','What is the update? Can you check?'])
        out,event=copyedit('what is the update can you check',lambda *args:next(outputs))
        self.assertEqual(out,'What is the update? Can you check?')
        self.assertEqual(event['status'],'punctuation_recovery')
    def test_invalid_recovery_cannot_overwrite_words(self):
        out,event=copyedit('what is the update',lambda *args:'The report is finished.')
        self.assertEqual(out,'what is the update');self.assertEqual(event['status'],'verbatim_recovery')
    def test_clear_stutters_not_emphasis(self):
        self.assertEqual(clean_stutters('the the report is very very good'),'the report is very very good')
        self.assertEqual(clean_stutters('Is the... Or can we generate reports?'),'can we generate reports?')
        self.assertEqual(clean_stutters('no, no, never'),'no, no, never')
    def test_personalization_cannot_inject_example_content(self):
        outs=iter(['Send the private password.','Can we check the queue?'])
        out,_=copyedit('can we check the queue',lambda *args:next(outs),[{'before':'report','after':'private password'}])
        self.assertEqual(out,'Can we check the queue?')
    def test_embedded_wh_clause_is_not_forced_into_question(self):
        self.assertFalse(starts_question('What I need is a report'))
        self.assertFalse(starts_question('Where we go next depends on funding'))
        self.assertTrue(starts_question('What do I need'))
        self.assertIsNone(rejection_reason('what I need is a report','What I need is a report.'))
    def test_nominal_wh_subject_statements_do_not_owe_question_marks(self):
        statements = [
            'What the team told me actually was that the kits were incomplete.',
            'What our production team reported was a shortage.',
            'What my manager requested is a report.',
            'What the customer needs is more time.',
        ]
        for source in statements:
            with self.subTest(source=source):
                self.assertFalse(starts_question(source))
                self.assertIsNone(rejection_reason(source, source))

    def test_nominal_wh_subject_exception_preserves_real_questions(self):
        questions = [
            'What did the team tell you?',
            'What does the customer need?',
            'What the hell did the manager say was missing?',
            'What the hell is this?',
            'What is the team doing?',
            'What the team told you was correct?',
        ]
        for source in questions:
            with self.subTest(source=source):
                self.assertIsNotNone(rejection_reason(source, source[:-1] + '.'))

    def test_nominal_wh_statement_allows_punctuation_recovery(self):
        source = 'what the team told me was that kits are missing'
        expected = 'What the team told me was that kits are missing.'
        outputs = iter(['The kits are complete.', expected])
        result, event = copyedit(source, lambda *args: next(outputs))
        self.assertEqual(result, expected)
        self.assertEqual(event['status'], 'punctuation_recovery')
    def test_projection_preserves_words_when_model_drops_them(self):
        src='the report includes overtime and approved overtime can you check the totals'
        proposal='The report includes overtime and approved overtime. Can you check totals?'
        result=project_punctuation(src,proposal)
        self.assertEqual(words(src,False),words(result,False))
        self.assertIn('overtime. Can',result)
        self.assertIn('the totals?',result)
        self.assertTrue(punctuation_is_faithful(src,result))
        self.assertEqual(project_punctuation('Send 1.25 units','Send 1,25 units.'),'Send 1.25 units.')
    def test_projection_preserves_identifiers(self):
        src='use person@example.com and https://example.com/CaseSensitive and 1.25 units today'
        proposal='Use person@example.com, and https://example.com/CaseSensitive, and 1.25 units.'
        result=project_punctuation(src,proposal)
        self.assertIn('person@example.com',result)
        self.assertEqual(project_punctuation('use person@example.com','Use person@example.com.'),'Use person@example.com.')
        self.assertIn('https://example.com/CaseSensitive',result)
        self.assertIn('1.25',result)
        self.assertEqual(words(src,False),words(result,False))
    def test_preprocessing_never_deletes_a_distinct_listed_item(self):
        # A restart-removal rule was added in v0.5.2 and reverted in v0.5.3: it
        # deleted a deliberately distinct activity, and because copyedit validates
        # against clean_stutters' output, the guard never saw the loss. Any future
        # preprocessing must leave these intact.
        listed='We distinguish generating, trying to generate, and reviewing as three different activities.'
        self.assertIn('generating',clean_stutters(listed))
        negated="I'm not generating, trying to generate a report."
        self.assertIn('not generating',clean_stutters(negated))
    def test_preprocessing_cannot_hide_a_deletion_from_the_guard(self):
        # The structural rule: whatever clean_stutters removes is invisible to
        # rejection_reason. An identity generator must therefore be a no-op.
        source='We distinguish generating, trying to generate, and reviewing as three different activities.'
        result,diagnostic=copyedit(source,lambda system,text:text)
        self.assertIn('generating',result)
        self.assertEqual(diagnostic['status'],'unchanged')
    def test_general_and_qualified_pair_is_still_protected(self):
        # Structurally identical to a restart: one duplicated root, one adjacent
        # swap. It must stay rejected, which is why the guard was left alone.
        self.assertIsNotNone(rejection_reason('overtime and approved overtime','approved overtime'))
    def test_attribution_swap_is_still_rejected(self):
        self.assertIsNotNone(rejection_reason('Alex owes Sam fifty dollars.','Sam owes Alex fifty dollars.'))
        self.assertIsNotNone(rejection_reason('the invoice blocks the shipment','the shipment blocks the invoice'))
    def test_prompt_examples_all_pass_the_guard(self):
        # A demonstrated edit the guard would reject teaches the model to be
        # overruled into punctuation-only output. That is the regression.
        for source,target in EXAMPLES:
            with self.subTest(source=source):
                self.assertIsNone(rejection_reason(source,target))
    def test_prompt_still_names_filler_and_formatting(self):
        # De-enumerating the filler list and weakening the list rule is exactly
        # what turned polishing into punctuation restoration. Measured on the
        # reference corpus: this prompt removes 48% of filler where the version
        # that dropped the enumeration removed 9%.
        for token in ('you know', 'I mean', 'sort of'):
            self.assertIn(token, SYSTEM)
        self.assertTrue(re.search(r'immediately repeated words', SYSTEM))
        self.assertTrue(re.search(r'numbered', SYSTEM))
        self.assertTrue(re.search(r'PARAGRAPHS', SYSTEM))
        # Self-corrections resolve to the speaker's final intent.
        self.assertIn('final intended version', SYSTEM)
    def test_numbers_must_be_equivalent_not_merely_similar(self):
        # A substring test accepted these: "15" occurs inside "150", and extra
        # output numbers were permitted outright.
        self.assertIsNotNone(rejection_reason('Send 15 copies.','Send 150 copies.'))
        self.assertIsNotNone(rejection_reason('Send the report.','Send the report at 9.'))
        long_source=('Please review the complete quarterly report carefully and send 15 copies '
                     'to the regional managers before Friday.')
        self.assertIsNotNone(rejection_reason(long_source,long_source.replace('15','150')))

    def test_spoken_numbers_written_as_digits_are_equivalent(self):
        for src,out in [('is that a ten on ten approach','Is that a 10/10 approach?'),
                        ('we need two hundred thousand units','We need 200,000 units.'),
                        ('the rate is five percent','The rate is 5%.'),
                        ('the rate is 3.75 percent until 2026-10-12','The rate is 3.75% until 2026-10-12.')]:
            with self.subTest(src=src): self.assertIsNone(rejection_reason(src,out))

    def test_spoken_symbols_need_evidence_of_naming(self):
        # Preprocessing runs before the guard, so an unevidenced conversion is
        # invisible to it: these were mangled and accepted with rejection=None.
        for text in ('The keyboard hyphen key is broken.','Please explain slash commands.',
                     'we should explain hyphen usage clearly'):
            with self.subTest(text=text):
                self.assertEqual(spoken_symbols(text), text)
                result,diagnostic=copyedit(text, lambda system,value: value)
                self.assertEqual(diagnostic['status'],'unchanged')

    def test_spoken_symbols_become_symbols(self):
        # Whisper transcribes the word; nothing used to convert it, so dictating
        # a filename typed "report hyphen final".
        self.assertEqual(spoken_symbols('call it report hyphen final hyphen v2'),
                         'call it report-final-v2')
        self.assertEqual(spoken_symbols('the file is q3 underscore final'), 'the file is q3_final')
        self.assertEqual(spoken_symbols('name it AE2 hyphen DIGI'), 'name it AE2-DIGI')
        # An identifier is its own evidence, without a naming cue.
        self.assertEqual(spoken_symbols('use AE2 hyphen DIGI today'), 'use AE2-DIGI today')

    def test_spoken_symbols_leave_the_words_alone(self):
        # A function word on either side means the symbol name is a noun.
        for text in ('the hyphen key is broken', 'please add a dash to the file name',
                     'it is a hyphen between them', 'use the slash command'):
            with self.subTest(text=text):
                self.assertEqual(spoken_symbols(text), text)

    def test_spoken_quantities_cannot_disappear_or_change(self):
        for source, proposal in [
            ('We need five boxes.', 'We need boxes.'),
            ('We need five boxes.', 'We need fifteen boxes.'),
            ('Send two boxes and two labels.', 'Send two boxes and labels.'),
            ('Send 5 boxes.', 'Send boxes.'),
            ('Move from one to two.', 'Move from two to one.'),
            ('Send five boxes and 2 labels.', 'Send 2 boxes and five labels.'),
        ]:
            with self.subTest(source=source, proposal=proposal):
                result, event = copyedit(source, lambda *args: proposal)
                self.assertEqual(result, source)
                self.assertEqual(event['rejection'], 'numbers_or_negation')

    def test_quantity_representation_can_change_in_either_direction(self):
        for source, output in [('We need five boxes.', 'We need 5 boxes.'),
                               ('We need 5 boxes.', 'We need five boxes.'),
                               ('Send two hundred and five boxes.', 'Send 205 boxes.'),
                               ('Send one million two hundred thousand units.', 'Send 1,200,000 units.'),
                               ('Send two boxes and two labels.', 'Send 2 boxes and 2 labels.')]:
            with self.subTest(source=source):
                self.assertIsNone(rejection_reason(source, output))

    def test_symbol_cue_cannot_leak_to_another_expression(self):
        for source in [
            'Open the folder. Please explain slash commands.',
            'Name it report. The keyboard hyphen key is broken.',
            'Open the folder and please explain slash commands.',
            'The HTML slash syntax needs explanation.',
        ]:
            with self.subTest(source=source):
                seen = []
                def identity(system, value):
                    seen.append(value)
                    return value
                result, event = copyedit(source, identity)
                self.assertEqual(seen, [source])
                self.assertEqual(result, source)
                self.assertEqual(event['status'], 'unchanged')

    def test_symbol_conversion_is_a_checked_output_proposal(self):
        source = 'Call it report hyphen final hyphen v2.'
        seen = []
        def identity(system, value):
            seen.append(value)
            return value
        result, event = copyedit(source, identity)
        self.assertEqual(seen, [source])
        self.assertEqual(result, 'Call it report-final-v2.')
        self.assertIsNone(event['rejection'])

    def test_a_hedge_may_never_be_dropped(self):
        # Three releases asked the prompt for this and the model dropped them
        # anyway, so it is enforced. Real cases from a held-out draw.
        for src,out in [("Wouldn't that be a good thing? I think let's do that.",
                         "Wouldn't that be a good thing? Let's do that."),
                        ('Because in my opinion and I may be wrong, Uli becomes the director',
                         'Because in my opinion, Uli becomes the director'),
                        ('which I believe should relatively help you much better',
                         'which I believe should help you much better')]:
            with self.subTest(src=src):
                self.assertEqual(rejection_reason(src,out),'hedge_removed')

    def test_hedges_that_survive_are_accepted(self):
        for src,out in [('i kind of agree but the numbers are sort of soft',
                          'I kind of agree, but the numbers are sort of soft.'),
                        ('um so i think we should ship it by friday',
                          'I think we should ship it by Friday.')]:
            with self.subTest(src=src): self.assertIsNone(rejection_reason(src,out))

    def test_recogniser_loops_are_detected(self):
        # Both real: an 8-minute press returned one sentence 32 times, and an
        # earlier capture returned "I-0" 48 times and was inserted unnoticed.
        self.assertTrue(looped_transcription('What is the job of a Guardian? ' +
                                             'We have to find the right Guardian. '*32))
        self.assertTrue(looped_transcription('IA, I-2, ' + 'I-0, '*48))

    def test_ordinary_speech_is_not_a_loop(self):
        # Measured over 300 real dictations the most-repeated 6-gram occurs at
        # most twice, so deliberate repetition must stay under the threshold.
        for text in ('I think we should ship the thing by Friday and then review it.',
                     'the report is ready now now can you check it please and confirm',
                     'very very good indeed, very very good',
                     'yes yes yes absolutely'):
            with self.subTest(text=text):
                self.assertFalse(looped_transcription(text))

    def test_multilingual_punctuation(self):
        self.assertTrue(punctuation_is_faithful('متى ينتهي العمل','متى ينتهي العمل؟'))
        self.assertFalse(punctuation_is_faithful('¿Cuándo estará listo?','Estará listo mañana.'))

class InventedWordsAreNotRehearings(unittest.TestCase):
    """The spelling allowance compared an added word against ANY source word, so
    "handle" passed as a re-hearing of "do" -- it resembles the unrelated word
    "and" at 2/3. The transcript then said the speaker asked how to *handle*
    external blockers when they asked how to *do* them."""

    def test_a_common_verb_is_not_a_rehearing_of_another(self):
        self.assertEqual(
            rejection_reason('how do we now do these external blockers',
                                    'How do we now handle these external blockers?'),
            'new_content')

    def test_a_word_beside_the_one_it_resembles_is_an_addition(self):
        """"repeat" resembles "report" -- but "report" is still in the output, so
        nothing was re-heard and an instruction was added. Raising the minimum
        word length hid the "do"/"handle" case without touching this mechanism."""
        self.assertEqual(rejection_reason('Please send the report.',
                                          'Please repeat and send the report.'), 'new_content')

    def test_the_dictionary_cannot_license_a_new_recipient(self):
        """Knowing how Microsoft is spelled does not establish that this
        utterance mentioned Microsoft."""
        self.assertEqual(rejection_reason('Please send the report.',
                                          'Please send the report to Microsoft.',
                                          known_terms=['Microsoft']), 'new_content')

    def test_a_rehearing_requires_something_to_have_been_replaced(self):
        self.assertFalse(rehearing('microsoft', [], known_terms=['Microsoft']))
        self.assertTrue(rehearing('microsoft', ['microsystems'], known_terms=['Microsoft']))

    def test_a_term_the_speaker_keeps_in_their_dictionary_is_not_invented(self):
        """A word they wrote down themselves is a correction, not an invention.
        This clears the ADDITION only: an edit can still be refused for what it
        removed, which is why the allowance is worth 2 of 903 accepted outputs
        rather than the large gain predicted for it."""
        source = ['open', 'the', 'erp', 'system', 'tomorrow']
        self.assertTrue(rehearing('erp42', source, known_terms=['ERP42']))
        self.assertFalse(rehearing('erp42', source))   # resemblance alone cannot reach it

class GeneratedAngleWrappers(unittest.TestCase):
    def test_initial_candidate_cannot_add_an_outer_wrapper(self):
        source = 'Please send the report.'
        replies = iter(['<Please send the report.>', source])
        result, diagnostic = copyedit(source, lambda *_: next(replies))
        self.assertEqual(result, source)
        self.assertEqual(diagnostic['rejection'], 'generated_wrapper')

    def test_punctuation_recovery_cannot_add_an_outer_wrapper(self):
        source = 'I meant the report.'
        replies = iter(['The report is complete.', '<I meant the report.>'])
        result, _ = copyedit(source, lambda *_: next(replies))
        self.assertEqual(result, source)

    def test_word_equality_does_not_make_a_wrapper_faithful(self):
        self.assertFalse(punctuation_is_faithful('Send the report.', '<Send the report.>'))

    def test_literal_outer_brackets_are_preserved(self):
        source = '<Send the report.>'
        result, diagnostic = copyedit(source, lambda *_: source)
        self.assertEqual(result, source)
        self.assertIsNone(diagnostic['rejection'])
        self.assertTrue(punctuation_is_faithful(source, source))

    def test_inline_literal_brackets_do_not_license_an_outer_wrapper(self):
        self.assertEqual(rejection_reason('Send <customer> the report.',
                                          '<Send <customer> the report.>'),
                         'generated_wrapper')

class RepeatedCommandTests(unittest.TestCase):
 def test_additive_same_named_target_keeps_scope_and_other_cleanup(self):
  source='Please remove ToolBox. We have ToolBox and ToolBox Chat. Remove Atlas. And remove Atlas as well.'
  proposal='Please remove ToolBox. We have ToolBox and ToolBox Chat. Remove Atlas and remove Atlas as well.'
  calls=[]
  def gen(*_):calls.append(True);return proposal
  out,diag=copyedit(source,gen)
  self.assertEqual(out, 'Please remove ToolBox. We have ToolBox and ToolBox Chat. Remove Atlas as well.')
  self.assertEqual(len(calls),1);self.assertIn('repeated_named_command',diag['local_repairs']);self.assertIsNone(rejection_reason(source,out))
 def test_idempotent_named_variations(self):
  for source,expected in [('Disable Sync Helper. And disable Sync Helper as well.','Disable Sync Helper as well.'),('Remove Atlas and remove Atlas as well.','Remove Atlas as well.')]:
   self.assertEqual(collapse_repeated_named_command(source),expected)
 def test_distinct_actions_polarity_emphasis_quotes_and_generic_targets_survive(self):
  for text in ['Remove Atlas. And remove Orion as well.','Remove Atlas. And disable Atlas as well.',
    'Remove Atlas from the list. And remove Atlas from the folder as well.',
    'Do not remove Atlas. And remove Atlas as well.', 'Remove Atlas. And do not remove Atlas as well.',
    'Remove Atlas! And remove Atlas as well.', 'Remove Atlas, remove Atlas as well.',
    'Remove Atlas again. And remove Atlas again as well.',
    'Remove the duplicate. And remove the duplicate as well.',
    'Remove This Item. And remove This Item as well.',
    'Remove Another Copy. And remove Another Copy as well.',
    'For emphasis. Remove Atlas. And remove Atlas as well.',
    'Repeat exactly. Remove Atlas. And remove Atlas as well.',
    'Send Payment. And send Payment as well.',
    'The label says "Remove Atlas. And remove Atlas as well."',
    'Remove Atlas. And remove Atlas as well?',
    'Remove Atlas. And remove Atlas as well as Orion.',
    'Remove Atlas. After the test, remove Atlas as well.']:
   with self.subTest(text=text):self.assertEqual(collapse_repeated_named_command(text),text)


class PolishingCompletionTests(unittest.TestCase):
    def test_reporting_predicate_boundary_keeps_other_questions(self):
        source='Did you review the scoring? How do we measure this and how do we do it in a proper manner is very important. Have you created those forms?'
        proposal=source.replace('manner is', 'manner? Is')
        actual,diag=copyedit(source,lambda *_:proposal)
        self.assertEqual(actual,source)
        self.assertIn('nominal_boundary',diag['local_repairs'])

    def test_nominal_reporting_does_not_force_question_retry(self):
        for source,proposal in [('How is that done is unclear.','How that is done is unclear.'),
                                ('Can you help me is all she said.','Can you help me, is all she said.')]:
            calls=[]
            def edit(*_):calls.append(True);return proposal
            self.assertEqual(copyedit(source,edit)[0],proposal)
            self.assertEqual(len(calls),1)

    def test_real_questions_are_not_nominalized(self):
        from polish import nominal_reporting_clause,repair_nominal_boundaries
        for text in ['How do we know this is important.', 'How do we prove the issue is unclear.',
                     'How is that done? Is it important?', 'How do we do it if timing is important.',
                     'How do we know it depends on the account.', 'How do we handle it is the question?',
                     'Why do they think the process is important.', 'What is that?',
                     'The title is "How is that done is unclear."']:
            self.assertFalse(nominal_reporting_clause(text),text)
            self.assertEqual(repair_nominal_boundaries(text,text),text)

    def test_intensifier_restoration_keeps_cleaned_stutters(self):
        source="Sorry, man, I've been really, really occupied with the the audits. I'll reply tomorrow."
        proposal="Sorry, man, I've been really occupied with the audits. I'll reply tomorrow."
        out,diag=copyedit(source,lambda *_:proposal)
        self.assertEqual(out,proposal.replace('really occupied','really, really occupied'))
        self.assertIn('repeated_emphasis',diag['local_repairs'])

    def test_intensifiers_do_not_move_between_clauses(self):
        from polish import restore_repeated_emphasis
        for source,output in [('It is very very good. It is very late.','It is good. It is very late.'),
                              ('It is very very good. It is very very good.','It is very good. It is very good.'),
                              ('It is really. Really helpful.','It is really helpful.'),
                              ('The the task is done.','The task is done.'),
                              ('I am really really sorry, no, I am happy.','I am happy.')]:
            self.assertEqual(restore_repeated_emphasis(source,output),output)

    def test_quoted_title_restores_literal_words_without_discarding_cleanup(self):
        source='The the title is "it is just it is very abrupt". Please save it.'
        proposal='The title is "It is just very abrupt." Please save it.'
        out,diag=copyedit(source,lambda *_:proposal)
        self.assertIn('"it is just it is very abrupt"',out)
        self.assertNotIn('The the',out)
        self.assertIn('literal_fragment',diag['local_repairs'])
        self.assertIn('abrupt\". Please save it.',out)

    def test_quote_spacing_does_not_duplicate_existing_terminator(self):
        source='The title is "raw text".'
        proposal='The title is "raw text" .'
        output,_=copyedit(source,lambda *_:proposal)
        self.assertEqual(output,proposal)
        self.assertEqual(output.count('.'),1)

    def test_incomplete_copula_keeps_unfinished_words(self):
        for source,proposal in [("It's actually it's", "It's actually."),
                                ("It's fine. It's actually it's", "It's fine. It's actually.")]:
            self.assertEqual(copyedit(source,lambda *_:proposal)[0],source+'...')
        complete="It's actually it's very abrupt."
        self.assertEqual(copyedit(complete,lambda *_:"It's actually very abrupt.")[0],"It's actually very abrupt.")

    def test_literal_restore_does_not_guess_missing_or_reordered_quotes(self):
        from polish import restore_literal_fragments
        for source,proposal in [('She said "it is just it is abrupt".','She said "It is just abrupt."'),
                                ('The title is "a".','The title is now a.'),
                                ('The label is "a". The title is "b".','The title is "b". The label is "a".')]:
            self.assertEqual(restore_literal_fragments(source,proposal),proposal)

    def test_explicit_emphasis_and_unmarked_conflict_are_not_resolved(self):
        for source,proposal in [('For emphasis. Remove Atlas. And remove Atlas as well.','For emphasis, remove Atlas.'),
                                ('Do not remove Atlas. And remove Atlas as well.','Do not remove Atlas.'),
                                ('For emphasis. Send Payment. And send Payment as well.','For emphasis, send Payment.')]:
            self.assertEqual(copyedit(source,lambda *_:proposal)[0],source)
        source='Remove Atlas, sorry, disable Atlas.'
        self.assertEqual(copyedit(source,lambda *_:'Disable Atlas.')[0],'Disable Atlas.')

    def test_adjacent_other_restart_preserves_marked_emphasis(self):
        source='Use the other other platforms for this.'
        self.assertEqual(copyedit(source,lambda *_:source)[0],'Use the other platforms for this.')
        from polish import collapse_adjacent_other
        for text in ['Use the other, other platforms.', 'The title is "the other other platforms".',
                     'For emphasis, use the other other platforms.', 'Use the other other option.',
                     'Use other other platforms.']:
            self.assertEqual(collapse_adjacent_other(text,text),text)

    def test_explicit_other_emphasis_survives_the_whole_model_path(self):
        source='For emphasis, use the other other platforms.'
        proposal='For emphasis, use the other platforms.'
        self.assertEqual(copyedit(source,lambda *_:proposal)[0],source)

    def test_saved_later_question_intent_remains_question(self):
        source='We need a test account. What is that best way so we give them access to the sandbox right but obviously I do not want production changes.'
        proposal='We need a test account. The best way is to give them access to the sandbox, but I do not want any production changes.'
        output,_=copyedit(source,lambda *_:proposal)
        self.assertIn('What is that best way',output)
        self.assertIn('right? But obviously I do not want production changes.',output)

if __name__=='__main__':unittest.main()


class DescriptiveRestartTests(unittest.TestCase):
    def test_resumed_subject_keeps_description_relation_and_predicate(self):
        source = 'The issue is that the parcel, the address label on the parcel, for this the parcel does not arrive correctly.'
        expected = 'The issue is that the parcel, with the address label on it, does not arrive correctly.'
        calls = []
        def generate(*_): calls.append(True); return source
        output, diag = copyedit(source, generate)
        self.assertEqual(output, expected)
        self.assertEqual(len(calls), 1)
        self.assertIn('descriptive_restart', diag['local_repairs'])
        self.assertIsNone(rejection_reason(source, output))

    def test_qualifiers_and_other_clauses_survive(self):
        source = 'I think the diagram, the small label on the diagram, for this, the diagram might not print clearly. Please keep the original.'
        expected = 'I think the diagram, with the small label on it, might not print clearly. Please keep the original.'
        output, _ = copyedit(source, lambda *_: source)
        self.assertEqual(output, expected)

    def test_changed_subject_contrast_correction_and_quotes_abstain(self):
        from polish import collapse_descriptive_restart
        cases = [
            'The parcel, the label on the parcel, for this the label does not print.',
            'The parcel, the label on the box, for this the parcel does not arrive.',
            'The parcel, the label is on the parcel, for this the parcel does not arrive.',
            'Not the parcel, the label on the parcel, for this the parcel does not arrive.',
            'For emphasis, the parcel, the label on the parcel, for this the parcel does not arrive.',
            'The parcel, I mean the label on the parcel, for this the parcel does not arrive.',
            'The parcel, the label and seal on the parcel, for this the parcel does not arrive.',
            'The parcel, the label on the parcel, and the parcel does not arrive.',
            'The parcel, the label on the parcel. For this the parcel does not arrive.',
            'The title is "the parcel, the label on the parcel, for this the parcel does not arrive."',
            'The parcel arrives, but the label does not print.',
            'Neither the parcel nor the label is correct.',
        ]
        for source in cases:
            with self.subTest(source=source):self.assertEqual(collapse_descriptive_restart(source, source), source)

    def test_unaligned_or_repeated_spans_abstain(self):
        from polish import collapse_descriptive_restart
        source = 'The parcel, the label on the parcel, for this the parcel does not arrive.'
        self.assertEqual(collapse_descriptive_restart('The parcel does not arrive.', source), source)
        twice = source + ' ' + source
        self.assertEqual(collapse_descriptive_restart(twice, twice), twice)
        proposal = source.replace('does not arrive', 'might not arrive')
        self.assertEqual(collapse_descriptive_restart(source, proposal), proposal)

    def test_already_clean_output_is_preserved(self):
        from polish import collapse_descriptive_restart
        source = 'The parcel, the label on the parcel, for this the parcel does not arrive.'
        proposal = 'The parcel with the label on it does not arrive.'
        self.assertEqual(collapse_descriptive_restart(source, proposal), proposal)

    def test_entire_result_still_passes_meaning_guard(self):
        source = 'The parcel, the label on the parcel, for this the parcel does not arrive. Keep both copies.'
        proposal = source.replace('does not arrive', 'does arrive')
        output, _ = copyedit(source, lambda *_: proposal)
        self.assertIn('does not arrive', output)
        self.assertIn('Keep both copies.', output)
        self.assertIsNone(rejection_reason(source, output))

    def test_people_animals_and_unknown_heads_keep_their_nouns(self):
        from polish import collapse_descriptive_restart
        for noun in ['woman','child','dog','horse','teacher','patient','robot','device']:
            source = f'The {noun}, the tag on the {noun}, for this the {noun} looks different.'
            self.assertEqual(collapse_descriptive_restart(source, source), source)
