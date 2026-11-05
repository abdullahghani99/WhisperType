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
class TopicalDemonstrativeTests(unittest.TestCase):
 def test_negative_question_survives_legitimate_cleanup(self):
  a="the delivery option shouldn't this be actually selected by the buyer"
  b="The delivery option shouldn't be selected by the buyer."
  result,diag=p.copyedit(a,lambda *_:b)
  self.assertEqual(result,"The delivery option: Shouldn't this be selected by the buyer?")
  self.assertIn('topical_demonstrative_question',diag['local_repairs'])
 def test_positive_inversion_and_topic(self):
  for a,b,want in [
   ('on the inspection is this complete','On the inspection, this is complete.','On the inspection: Is this complete?'),
   ('about our records are these available','About our records, these are available.','About our records: Are these available?'),
   ('on the integration is this using the api','On the integration, this is using the API.','On the integration: Is this using the API?'),
   ("the test couldn't that be repeated", "The test couldn't be repeated.", "The test: Couldn't that be repeated?")]:
   self.assertEqual(p.copyedit(a,lambda *_:b)[0],want)
 def test_real_statements_reports_and_nominal_complements_abstain(self):
  for a in ["The delivery option shouldn't be selected by the buyer.",'On the inspection, this is complete.',
   'I wonder whether this is complete.',"He asked about the option: shouldn't this be selected?",
   "The option that he asked about shouldn't this be selected",'The issue is whether this is complete.',
   'Maybe on the inspection is this complete','The manager asked is this complete',
   'The question is this complete list.', 'The report says is this complete']:
   self.assertEqual(p.restore_topical_demonstrative_question(a,a),a)
 def test_changed_predicate_subject_and_extra_content_abstain(self):
  a="the delivery option shouldn't this be selected by the buyer"
  for b in ["The delivery option shouldn't be selected by the seller.","The delivery option should be selected by the buyer.",
   "The delivery option shouldn't be selected by the buyer tomorrow.","The delivery option shouldn't be selected by them.",
   "The delivery option shouldn't be selected by the buyer. Notify them."]:
   self.assertEqual(p.restore_topical_demonstrative_question(a,b),b)
 def test_quotations_corrections_and_multiple_utterances_abstain(self):
  a='on the inspection is this complete';b='On the inspection, this is complete.'
  for source in ['"'+a+'"',"'"+a+"'",a+' sorry I mean the review',a+'? '+a+'?', 'I asked '+a]:
   self.assertEqual(p.restore_topical_demonstrative_question(source,b),b)
  for output in ['"'+b+'"',b+' Sorry, the review.']:
   self.assertEqual(p.restore_topical_demonstrative_question(a,output),output)
 def test_keeps_modality_and_existing_questions(self):
  a='on the inspection is this possibly complete';b='On the inspection, this is possibly complete.'
  self.assertEqual(p.restore_topical_demonstrative_question(a,b),'On the inspection: Is this possibly complete?')
  changed='On the inspection, this is complete.'
  self.assertEqual(p.restore_topical_demonstrative_question(a,changed),changed)
  question='On the inspection, is this possibly complete?'
  self.assertEqual(p.restore_topical_demonstrative_question(a,question),question)

if __name__=='__main__':unittest.main()
