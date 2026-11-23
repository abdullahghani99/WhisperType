import unittest
from polish import repair_numeric_rating_punctuation as repair, copyedit


class NumericRatingTests(unittest.TestCase):
    def test_rating_interior_and_neighboring_question(self):
        src='We reached a full 9 on 10 yesterday. Why did it change?'
        out='We reached a full 9, on 10 yesterday. Why did it change?'
        self.assertEqual(repair(src,out),src)

    def test_internal_sentence_boundary_is_rejoined(self):
        src='It is a perfect 10 out of 10. Can we ship?'
        out='It is a perfect 10. Out of 10. Can we ship?'
        self.assertEqual(repair(src,out),src)

    def test_separate_date_and_sentence_are_preserved(self):
        src='It is a full 10 on 10. On 10 November we meet.'
        out='It is a full 10, on 10. On 10 November we meet.'
        self.assertEqual(repair(src,out),src)

    def test_changed_numbers_or_relation_abstain(self):
        src='We got a full 9 on 10 today.'
        for out in ['We got a full 8, on 10 today.','We got a full 9, out of 10 today.','We got a full 9, on 10.5 today.']:
            self.assertEqual(repair(src,out),out)

    def test_quotation_correction_and_duplicate_context_abstain(self):
        for src in ['She said, "a full 10 on 10".', 'A full 10 on 10, sorry, a 9 on 10.', 'A full 10 on 10 and a full 10 on 10 again.']:
            out=src.replace('10 on 10','10, on 10')
            self.assertEqual(repair(src,out),out)

    def test_source_boundary_and_real_list_abstain(self):
        for src in ['A full 10. On 10 November we meet.', 'Take 10, 20 and 30 items.', 'I need 10 on 10 November.', 'We got a full 10 on 10.5 today.']:
            out=src.replace('10 on','10, on')
            self.assertEqual(repair(src,out),out)

    def test_lists_and_quoted_output_not_joined(self):
        src='We got a full 10 on 10 today.'
        for out in ['We got a full 10.\n\nOn 10 today.', 'We got a full 10, "on 10" today.']:
            self.assertEqual(repair(src,out),out)

    def test_repair_is_idempotent_and_keeps_cleanup(self):
        src='We, we got a rating of 7 out of 10 yesterday. Can you help?'
        out='We got a rating of 7. Out of 10 yesterday. Can you help?'
        expected='We got a rating of 7 out of 10 yesterday. Can you help?'
        self.assertEqual(repair(src,out),expected)
        self.assertEqual(repair(src,expected),expected)

    def test_complete_copyedit_uses_same_call_count(self):
        src='We achieved a full 10 on 10. Can we ship?'
        calls=[]
        def generate(system,text):
            calls.append(text)
            return 'We achieved a full 10, on 10. Can we ship?'
        out,diag=copyedit(src,generate)
        self.assertEqual(out,src)
        self.assertEqual(len(calls),1)
        self.assertIn('numeric_rating_punctuation',diag['local_repairs'])


if __name__=='__main__': unittest.main()
