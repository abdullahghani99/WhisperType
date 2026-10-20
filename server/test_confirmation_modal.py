import unittest
import polish as p

class Tests(unittest.TestCase):
 def test_directive(self):
  for who in ['you','we','they']:
   self.assertTrue(p.added_directive_modal(f'{who} actually bring all historical images.',f'{who} should bring all historical images.'))
 def test_controls(self):
  for a,b in [('We asked should we get this from the clinic?', 'We asked if we should get this from the clinic.'),('You should bring all images.','You should bring all images.'),('You ought to bring all images.','You should bring all images.'),('You bring all images, sorry, you should bring all images.','You should bring all images.'),('You bring all images. They should remove old files.','You bring all images. They should remove old files.'),('You bring all images. You bring all images.','You should bring all images.')]:self.assertFalse(p.added_directive_modal(a,b),(a,b))
 def test_confirmation(self):
  a="We need this finished. Right? Don't forget the tests. Do this properly."
  b="We need this finished. Don't forget the tests. Do this properly."
  c=p.copyedit(a,lambda *_:b)[0];self.assertIn('. Right?',c);self.assertNotIn('properly?',c)
 def test_questions_and_imperatives(self):
  for t in ['Do this properly.','Do that carefully.','Do it now.']:self.assertEqual(p.repair_local_question_boundaries(t,t),t)
  for t in ['Do these files match.','Do those teams agree.','Does this work.','Do you understand.']:self.assertTrue(p.repair_local_question_boundaries(t,t).endswith('?'),t)
 def test_confirmation_abstains(self):
  for a,b in [('Turn right. Keep walking.','Turn right. Keep walking.'),('The title is "Right?"','The title is "Right?"'),('We finished the task. Right? Sorry, ignore that.','We finished the task. Sorry, ignore that.'),('We finished the task. Right? They approved the change.','The task is finished. They approved the change.')]:self.assertEqual(p.restore_standalone_confirmation(a,b),b)
if __name__=='__main__':unittest.main()
