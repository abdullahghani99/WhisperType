import unittest
from polish import restore_device_operating_state, copyedit

class DeviceStateTests(unittest.TestCase):
    def test_power_state_survives_without_undoing_cleanup(self):
        source='Um, do we need the printer on now for the test or are we finished?'
        edited='Do we need the printer now for the test, or are we finished?'
        self.assertEqual(restore_device_operating_state(source, edited), 'Do we need the printer on now for the test, or are we finished?')
    def test_off_state_and_negation(self):
        self.assertEqual(restore_device_operating_state('We do not want the server off during the update.', 'We do not want the server during the update.'), 'We do not want the server off during the update.')
    def test_pipeline_uses_existing_meaning_gate(self):
        source='Do we need the printer on now for the test or are we finished?'
        result, diag=copyedit(source, lambda *_:'Do we need the printer now for the test, or are we finished?')
        self.assertEqual(result, 'Do we need the printer on now for the test, or are we finished?')
        self.assertIn('device_operating_state',diag['local_repairs'])
    def test_availability_location_and_scheduling_are_unchanged(self):
        for source,edited in [
            ('Do we need the printer now?', 'Do we need the printer now?'),
            ('I need the monitor on the desk now.', 'I need the monitor on the desk now.'),
            ('We need the unit on Friday.', 'We need the unit Friday.'),
            ('Leave the camera on display for now.', 'Leave the camera on display for now.'),
            ('We want the camera off the shelf now.', 'We want the camera off the shelf now.'),
        ]:
            with self.subTest(source=source):self.assertEqual(restore_device_operating_state(source,edited),edited)
    def test_corrections_and_quotes_abstain(self):
        for source,edited in [
            ('I need the unit on now, sorry, off now.', 'I need the unit off now.'),
            ('Keep the camera on now, actually off.', 'Keep the camera now, actually off.'),
            ('He said "keep the camera on now".', 'He said "keep the camera now".'),
            ("The phrase 'keep the camera on now' is quoted.", "The phrase 'keep the camera now' is quoted."),
        ]:
            with self.subTest(source=source):self.assertEqual(restore_device_operating_state(source,edited),edited)
    def test_changed_predicate_actor_or_anchor_abstains(self):
        for source,edited in [
            ('I need the camera on now for the call.', 'You need the camera now for the call.'),
            ('I need the camera on now for the call.', 'I need the camera now for the interview.'),
            ('I need the camera on now.', 'I want the camera now.'),
            ('I need the camera on now.', 'I need the camera off now.'),
            ('I need the camera on now.', 'I need the camera switched on now.'),
            ('I need the camera on now.', 'I need the camera. Now.'),
        ]:
            with self.subTest(source=source):self.assertEqual(restore_device_operating_state(source,edited),edited)
    def test_ambiguous_repeated_anchors_abstain(self):
        source='We need the unit on now and we need the unit off tonight.'
        edited='We need the unit now and we need the unit tonight.'
        self.assertEqual(restore_device_operating_state(source,edited),edited)
    def test_ambiguous_scheduling_restart_and_possessive_abstain(self):
        for source,edited in [
            ('We need the camera on for Friday.', 'We need the camera for Friday.'),
            ("We need the printer on today's inventory.", "We need the printer today's inventory."),
        ]:
            with self.subTest(source=source):self.assertEqual(restore_device_operating_state(source,edited),edited)
    def test_real_stutter_cleanup_and_existing_state_are_preserved(self):
        for source,edited in [
            ('Turn it on, turn it on now.', 'Turn it on now.'),
            ('I need, I need the camera on now.', 'I need the camera on now.'),
            ('Please leave the screens off overnight.', 'Please leave the screens off overnight.'),
        ]:
            with self.subTest(source=source):self.assertEqual(restore_device_operating_state(source,edited),edited)

if __name__=='__main__': unittest.main()
