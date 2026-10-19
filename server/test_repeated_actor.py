import unittest
import polish

class RepeatedActorConditionalTests(unittest.TestCase):
    def test_complete_output_restores_both_premises_and_cleans_restart(self):
        for actor,pronoun,predicate,question,command in [
            ('Orion','he','approved it','why is it pending','send the copy'),
            ('Atlas and Vega','they','reviewed the draft','why was the deadline missed','keep the original draft'),
            ('Morgan','she','signed the form','why would we wait','please file the signed form')]:
            source=f'Since {actor} if {pronoun} {predicate} {question}? Since {actor} {predicate}, {command}.'
            expected=f'If {actor} {predicate}, {question}? Since {actor} {predicate}, {command}.'
            for cue in ['Since','If']:
                for premise in ['',f'Since {actor} {predicate}, ']:
                    proposal=f'{cue} {actor} {predicate}, {question}? {premise}{command.capitalize() if not premise else command}.'
                    calls=[]
                    def generate(*args): calls.append(args);return proposal
                    output,_=polish.copyedit(source,generate)
                    self.assertEqual(output,expected)
                    self.assertEqual(len(calls),1)
                    self.assertIsNone(polish.rejection_reason(polish.conditional_restart_basis(source,output),output))

    def test_no_transfer_without_both_independent_anchors(self):
        source='Since Orion if he approved it why is it pending? Since Orion approved it, send the copy.'
        for proposal in [
            'Since Orion approved it, send the copy. Why is it pending?',
            'Since Orion approved it, why is it pending? If Orion approved it, send the copy.',
            'Since Orion approved it, why is it pending? Send another copy.',
            'Since Orion approved it, why is it approved? Send the copy.',
            'Since Vega approved it, why is it pending? Send the copy.',
            'Since Orion approved it, why is it pending?',
            'Since Orion approved it, why is it pending? Send the copy. Delete the draft.']:
            self.assertIsNone(polish.repeated_actor_conditional_pair(source,proposal))
            self.assertEqual(polish.conditional_restart_basis(source,proposal),source)

    def test_ambiguous_or_different_source_clauses_abstain(self):
        proposal='Since Orion approved it, why is it pending? Send the copy.'
        for source in [
            'Since Orion approved it, why is it pending? Since Orion approved it, send the copy.',
            'Since Orion if he approved it why is it pending? Since Vega approved it, send the copy.',
            'Since Orion if he approved it why is it pending? Since Orion rejected it, send the copy.',
            'Since Orion if he approved it why is it pending? If Orion approved it, send the copy.',
            'Since Orion if he approved it why is it pending? Since Orion approved it, why is it pending?',
            'Since Orion if he approved it why is it pending? Since Orion approved it, the copy was sent.',
            'Since Orion if he approved it why is it pending? Since Orion approved it, sorry, send the copy.',
            'The title is "Since Orion if he approved it why is it pending? Since Orion approved it, send the copy."']:
            self.assertIsNone(polish.repeated_actor_conditional_pair(source,proposal))

    def test_normalized_basis_cannot_license_loss_elsewhere(self):
        source='Since Orion if he approved it why is it pending? Since Orion approved it, send the original copy.'
        proposal='If Orion approved it, why is it pending? Since Orion approved it, send the original copy.'
        basis=polish.conditional_restart_basis(source,proposal)
        self.assertNotEqual(basis,source)
        self.assertIsNotNone(polish.rejection_reason(basis,proposal.replace('pending','complete')))
        self.assertEqual(polish.conditional_restart_basis(source,proposal.replace('original','revised')),source)

if __name__=='__main__':unittest.main()
