import unittest
import polish as p

class TopicQuestionFrameTests(unittest.TestCase):
 def test_explicit_question(self):
  for frame in ['My issue is','Our question is','The concern is']:
   for q in ['why is nothing ready yet?','how can we finish this?','when will they arrive?','where did it go?']:
    a=frame+' that '+q
    self.assertEqual(p.copyedit(a,lambda *_:a)[0],frame+': '+q[0].upper()+q[1:])
 def test_keeps_separate_questions_and_commands(self):
  a='My issue is that why is nothing ready yet? What is stopping us? Keep the interface intact.'
  self.assertEqual(p.copyedit(a,lambda *_:a)[0],a.replace('is that why','is: Why'))
 def test_grammatical_nominal_and_uncertain_controls(self):
  for a in ['My issue is that nothing is ready.','My question is why nothing is ready.','My issue is that why matters more than how.','I think my issue is that why is nothing ready?','My issue might be that why is nothing ready?','My issue is that why is nothing ready.']:
   self.assertEqual(p.repair_topic_question_frame(a,a),a)
 def test_quotes_corrections_and_duplicate_anchors(self):
  for a in ['He said "My issue is that why is nothing ready?"','My issue is that why is nothing ready? Sorry, I mean the tests.','My issue is that why is nothing ready? My issue is that why is nothing ready?']:
   self.assertEqual(p.repair_topic_question_frame(a,a),a)
 def test_preserves_already_cleaned_or_different_clause(self):
  a='My issue is that why is nothing ready?'
  for b in ['My issue is: Why is nothing ready?','Why is nothing ready?','My issue is that why is the work incomplete?','He said my issue is that why is nothing ready?']:
   self.assertEqual(p.repair_topic_question_frame(a,b),b)
 def test_later_sentence_frame(self):
  a='We need the report. My concern is that how can we finish it?'
  self.assertEqual(p.copyedit(a,lambda *_:a)[0],a.replace('is that how','is: How'))
if __name__=='__main__':unittest.main()
