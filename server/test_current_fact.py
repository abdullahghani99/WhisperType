"""Synthetic source-alignment controls; no private dictation content."""
import unittest
import polish

class CurrentFactTests(unittest.TestCase):
    def test_current_activity_is_not_a_plan(self):
        source = "We may change later. But again, you know our plans, right? Right now, we're using Cedar 2.4. We will compare other tools tomorrow."
        proposal = "We may change later. But again, you know our plans are to use Cedar 2.4 right now. We will compare other tools tomorrow."
        self.assertEqual(polish.restore_current_fact_after_plan_tag(source, proposal), source)
        final, diag = polish.copyedit(source, lambda *_: proposal)
        self.assertEqual(final, source)

    def test_expanded_auxiliary_and_other_actor(self):
        source = 'You know their plans, right? Right now, they are testing the new prototype.'
        proposal = 'You know their plans are to test the new prototype right now.'
        self.assertEqual(polish.restore_current_fact_after_plan_tag(source, proposal), source)

    def test_abstains_on_unsupported_or_ambiguous_changes(self):
        source = "You know our plans, right? Right now, we're building the new prototype."
        proposal = 'You know our plans are to build the new prototype right now.'
        pairs = [
            (proposal, proposal),
            (source.replace('right?', 'right,'), proposal),
            (source.replace("we're", "they're"), proposal),
            (source.replace("we're", 'we may be'), proposal),
            (source.replace('the new', 'perhaps the new'), proposal),
            (source, proposal.replace('prototype', 'factory')),
            ('"' + source + '"', '"' + proposal + '"'),
            ("'" + source + "'", "'" + proposal + "'"),
            ('Correction: ' + source, 'Correction: ' + proposal),
            (source + ' ' + source, proposal),
            (source, proposal + ' ' + proposal),
            (source, source),
        ]
        for src, out in pairs:
            with self.subTest(src=src, out=out):
                self.assertEqual(polish.restore_current_fact_after_plan_tag(src, out), out)


class CurrentFactBoundaryTests(unittest.TestCase):
    def test_comma_to_future_clause_and_reordered_timing(self):
        source = "You know our plans right? Right now we are using Cedar 2.4, we'll move to Maple tomorrow."
        proposal = "You know our plans right now are to use Cedar 2.4. We'll move to Maple tomorrow."
        expected = "You know our plans, right? Right now, we are using Cedar 2.4. We'll move to Maple tomorrow."
        self.assertEqual(polish.restore_current_fact_after_plan_tag(source, proposal), expected)
        final, _ = polish.copyedit(source, lambda *_: proposal)
        self.assertIn("plans right? Right now we are using Cedar 2.4.", final)
        self.assertIn("We'll move to Maple tomorrow.", final)

    def test_old_timing_order_also_handles_missing_commas(self):
        source = "You know my plans right? Right now I am testing the new service."
        proposal = 'You know my plans are to test the new service right now.'
        self.assertEqual(polish.restore_current_fact_after_plan_tag(source, proposal),
                         'You know my plans, right? Right now, I am testing the new service.')

    def test_comma_boundary_requires_unchanged_future_continuation(self):
        source = "You know our plans right? Right now we are using Cedar, we'll move to Maple tomorrow."
        proposal = "You know our plans right now are to use Cedar. We'll move to Maple tomorrow."
        pairs = [
            (source.replace(", we'll move to Maple tomorrow", ', with a backup'), proposal),
            (source, proposal.replace('Maple', 'Birch')),
            (source.replace('using Cedar', 'using Cedar, Maple and Birch'), proposal),
            (source.replace('right?', 'right,'), proposal),
            (source.replace('we are', 'they are'), proposal),
            (source.replace('we are', 'we may be'), proposal),
            (source.replace('we are using', 'we are not using'), proposal),
            (source.replace("we'll move", 'we are moving'), proposal),
            ('"' + source + '"', '"' + proposal + '"'),
            ('Sorry, ' + source, 'Sorry, ' + proposal),
            (source, proposal.replace('right now', 'tomorrow')),
            (source, proposal.replace('right now are to', 'were going to')),
            (source, source),
            (proposal, proposal),
        ]
        for src, out in pairs:
            with self.subTest(src=src, out=out):
                self.assertEqual(polish.restore_current_fact_after_plan_tag(src, out), out)

if __name__ == '__main__': unittest.main()
