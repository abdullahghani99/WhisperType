import re
import unittest
from polish import (copyedit,rejection_reason,clean_stutters,spoken_symbols,punctuation_is_faithful,
                    project_punctuation,words,starts_question,SYSTEM,EXAMPLES)

class CopyeditingTests(unittest.TestCase):
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

    def test_multilingual_punctuation(self):
        self.assertTrue(punctuation_is_faithful('متى ينتهي العمل','متى ينتهي العمل؟'))
        self.assertFalse(punctuation_is_faithful('¿Cuándo estará listo?','Estará listo mañana.'))
if __name__=='__main__':unittest.main()
