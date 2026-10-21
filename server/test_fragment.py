import unittest
import polish as p
class FragmentCleanupTests(unittest.TestCase):
 def test_abandoned_determiner(self):
  for subject in ['you still have','we have','they already have']:
   a=f'Where are we stuck? And the, on the task list, on item three, {subject} eleven tasks.'
   expected=a.replace('And the,','And')
   self.assertEqual(p.copyedit(a,lambda *_:a)[0],expected)
 def test_determiner_controls(self):
  for a in ['And the, on the shelf, green box needs paint.','And the, on the task list, item that we need is missing.','And the list, on the desk, has eleven tasks.','The quote is "And the, on the list, we have eleven tasks."','And the, on the list, we have eleven tasks. Sorry, I mean ten.']:
   self.assertEqual(p.remove_stranded_determiner_restart(a,a),a)
 def test_modal_filler_commas(self):
  for modal in ['can','could','will','would','should','must','may','might']:
   a=f'And then it {modal}, you know, use different words.'
   b=a.replace(' you know,','')
   self.assertEqual(p.copyedit(a,lambda *_:b)[0],b.replace(modal+',',modal))
 def test_then_with_added_label_quote(self):
  a='Should I click not now and then, you know, take it from there?'
  b='Should I click "not now" and then, take it from there?'
  self.assertEqual(p.remove_stranded_filler_comma(a,b),b.replace('then,','then'))
 def test_filler_before_retained_parenthetical(self):
  for a,b in [('We can, you know, if needed, check again.','We can, if needed, check again.'),('And then, you know, after lunch, check again.','And then, after lunch, check again.')]:
   self.assertEqual(p.remove_stranded_filler_comma(a,b),b)
 def test_retained_parentheticals(self):
  for a in ['It can, as you know, use different words.','It can, if needed, use different words.','And then, after lunch, take it from there.','The label says "it can, you know, use words."','It can, you know the answer, use different words.']:
   self.assertEqual(p.remove_stranded_filler_comma(a,a),a)
if __name__=='__main__':unittest.main()
