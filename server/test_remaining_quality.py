import unittest
import polish


class RemainingPolishingTests(unittest.TestCase):
    def edit(self, source, proposed):
        return polish.copyedit(source, lambda *_: proposed)[0]

    def test_question_and_conditional_command_both_survive(self):
        for noun in ('corrections', 'permissions', 'changes'):
            source=f'We posted the update and for the {noun}, what are these {noun} and if they are needed, just do them.'
            proposed=f'We posted the update. For the {noun}, if they are needed, just do them.'
            result=self.edit(source, proposed)
            self.assertIn(f'what are these {noun}? If they are needed, just do them.', result)
            self.assertIn('We posted the update.', result)

    def test_surviving_question_gets_a_boundary(self):
        source='For the changes, what are these changes and if they are needed, just do them.'
        self.assertEqual(self.edit(source, source), 'For the changes, what are these changes? If they are needed, just do them.')

    def test_nominal_quoted_corrected_and_changed_actions_abstain(self):
        for source, proposed in [
            ('For the changes, what are these changes is the question and if they are needed, do them.', 'For the changes, if they are needed, do them.'),
            ('The title is "For the changes, what are these changes and if they are needed, do them."', 'For the changes, if they are needed, do them.'),
            ('For the changes, what are these changes and if they are needed, do them. Sorry, ignore that question.', 'For the changes, if they are needed, do them.'),
            ('For the changes, what are these changes and if they are needed, do them.', 'For the changes, if they are needed, delete them.'),
            ('For the changes, what are these changes and if they are needed, do them.', 'If they are needed, do them. For the changes.'),
        ]:
            self.assertEqual(polish.restore_question_before_condition(source, proposed), proposed)

    def test_domain_and_decimal_request_punctuation(self):
        for target in ['example.org', 'docs.example.org', 'version 2.5', 'the report']:
            source=f'While you do that, can you also check {target}.'
            self.assertEqual(self.edit(source, source), source[:-1]+'?')
        for source in ['The title is "While you do that, can you check example.org."',
                       'While you do that, can you check example.org is the question.',
                       'While you do that, review example.org.']:
            self.assertEqual(polish.repair_framed_request(source, source), source)

    def test_filler_removal_does_not_leave_conjunction_comma(self):
        source='How would that happen so that, you know, everything is synced across the teams?'
        proposed='How would that happen so that, everything is synced across the teams?'
        self.assertEqual(self.edit(source, proposed), 'How would that happen so that everything is synced across the teams?')
        for source in ['Do that so that, if possible, everything is synced.',
                       'Do that so that, as you know, everything is synced.',
                       'Do that so that, everything is synced.']:
            self.assertEqual(polish.remove_stranded_filler_comma(source, source), source)

    def test_exception_specificity_does_not_change_the_group(self):
        for determiner in ('these', 'those', 'the'):
            source=f'Everyone got access except {determiner} external users yesterday.'
            proposed='Everyone got access except users yesterday.'
            # Do not infer a missing modifier or apply to another group.
            self.assertEqual(polish.restore_exception_specificity(source, proposed), proposed)
            proposed='Everyone got access except external users yesterday.'
            self.assertEqual(self.edit(source, proposed), source)
        source='Everyone got access except these users yesterday.'
        for proposed in ['Nobody got access except users yesterday.',
                         'Everyone got access except reviewers yesterday.',
                         'Everyone got access except users tomorrow.']:
            self.assertEqual(polish.restore_exception_specificity(source, proposed), proposed)


class OrderedConditionalTests(unittest.TestCase):
    def test_same_actor_other_order_and_two_conditions(self):
        question='Since Orion if he approved it why is it pending?'
        for other in ['Since Orion approved it, send the copy.', 'If Orion approved it, send the copy.',
                      'Since Vega approved it, send the copy.', 'Since Orion rejected it, send the copy.']:
            for source in [question+' '+other, other+' '+question]:
                proposed=source.replace(question,'Since Orion approved it, why is it pending?')
                result,_=polish.copyedit(source, lambda *_: proposed)
                self.assertEqual(result,source.replace(question,'If Orion approved it, why is it pending?'))

    def test_sentence_alignment_never_transfers_or_changes_a_premise(self):
        source='Since Orion if he approved it why is it pending? If Vega reviewed it, send the copy.'
        for proposed in ['Since Orion approved it, why is it pending? Since Vega reviewed it, send the copy.',
                         'Since Orion approved it, why is it pending? If Orion reviewed it, send the copy.',
                         'If Vega reviewed it, send the copy. Since Orion approved it, why is it pending?',
                         'Since Orion approved it, why is it pending? If Vega reviewed it, delete the copy.']:
            self.assertIsNone(polish.aligned_conditional_sentences(source, proposed))

class NuanceTests(unittest.TestCase):
    def test_confirmation_question_retained_but_filler_can_go(self):
        source='I paste images within these sessions, right? So I need this.'
        candidate='I paste images within these sessions, so I need this.'
        self.assertEqual(polish.copyedit(source,lambda *_: candidate)[0],source)
        source='Right, please send the draft.'
        candidate='Please send the draft.'
        self.assertEqual(polish.restore_aligned_nuance(source,candidate),candidate)

    def test_emphasis_retained_without_flattening_legitimate_stutter_cleanup(self):
        source='We have tons and tons of reports.'
        candidate='We have tons of reports.'
        self.assertEqual(polish.copyedit(source,lambda *_: candidate)[0],source)
        source='We have the the report.'
        candidate='We have the report.'
        self.assertEqual(polish.copyedit(source,lambda *_: candidate)[0],candidate)

    def test_tense_retained_without_blocking_agreement_or_correction(self):
        source='And then we have a problem in the factory.'
        candidate='And then we had a problem in the factory.'
        self.assertEqual(polish.copyedit(source,lambda *_: candidate)[0],source)
        for source,candidate in [('They is ready for the meeting.','They are ready for the meeting.'),
                                 ('We have a problem, sorry, we had a problem.','We had a problem.')]:
            self.assertEqual(polish.restore_aligned_nuance(source,candidate),candidate)

if __name__ == '__main__': unittest.main()
