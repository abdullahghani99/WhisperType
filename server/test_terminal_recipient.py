import unittest
from polish import restore_terminal_recipient as repair, copyedit

class TerminalRecipientTests(unittest.TestCase):
    def test_preserve_recipient_without_undoing_cleanup(self):
        source='Um, can you check the overdue deliveries for you?'
        output='Can you check the overdue deliveries for me?'
        self.assertEqual(repair(source, output), 'Can you check the overdue deliveries for you?')

    def test_prepositional_objects(self):
        for prep in ['for','to','from','with','about','against']:
            source=f'I reviewed the complete record {prep} them.'
            output=f'I reviewed the complete record {prep} us.'
            self.assertEqual(repair(source,output),source)
            self.assertEqual(repair(source,source),source)

    def test_earlier_cleanup_preserved(self):
        source='Um, I am ready. So can you collect the new files from her?'
        output='I am ready. Can you collect the new files from him?'
        self.assertEqual(repair(source,output),'I am ready. Can you collect the new files from her?')

    def test_correction_and_report_abstain(self):
        for prefix in ['Sorry, ', 'Actually, ', 'I mean, ', 'She said, ', 'She asked, ', 'Quote: ', '"']:
            source=prefix+'can you check the overdue deliveries for you?'
            output='Can you check the overdue deliveries for me?'
            self.assertEqual(repair(source,output),output)

    def test_explicit_recipient_correction_is_not_undone(self):
        source='Can you check the overdue deliveries for you? Sorry, for me.'
        output='Can you check the overdue deliveries for me?'
        self.assertEqual(repair(source,output),output)

    def test_changed_context_and_nonterminal_possessive_abstain(self):
        for source,output in [
            ('Can you check the overdue deliveries for you?','Can I check the overdue deliveries for me?'),
            ('Can you check the overdue deliveries for you?','Can you check the overdue invoices for me?'),
            ('Can you check the overdue deliveries for you?','Can you check the overdue deliveries with me?'),
            ('I collected the new files with her help.','I collected the new files with his help.'),
            ('This is for you.','This is for me.'),
            ('Can you check the overdue deliveries for you?','Can you check the overdue deliveries for me? I am ready.')]:
            self.assertEqual(repair(source,output),output)

    def test_full_copyedit_keeps_one_generation_and_cleanup(self):
        source='Um, can you check the overdue deliveries for you?'
        generated='Can you check the overdue deliveries for me?'
        calls=[]
        def generate(system,text):
            calls.append(text);return generated
        result,diag=copyedit(source,generate)
        self.assertEqual(result,'Can you check the overdue deliveries for you?')
        self.assertEqual(len(calls),1)
        self.assertIn('terminal_recipient',diag['local_repairs'])

if __name__=='__main__':unittest.main()
