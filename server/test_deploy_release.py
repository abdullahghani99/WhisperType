import os
import tempfile
import unittest
from pathlib import Path

import deploy_release


class PruneTests(unittest.TestCase):
    def test_keeps_current_and_two_newest_activated(self):
        with tempfile.TemporaryDirectory() as tmp:
            releases = Path(tmp)
            def make(name, created, activated=None):
                r = releases / name; r.mkdir()
                (r / 'release-manifest.json').write_text('{}'); os.utime(r / 'release-manifest.json', (created, created))
                if activated is not None:
                    (r / 'before-activation.sqlite').write_text(''); os.utime(r / 'before-activation.sqlite', (activated, activated))
                return r
            make('a', 1, 2); make('b', 3, 4); make('c', 5)          # c: staged, never activated
            make('d', 6, 7); make('e', 8, 9)
            current = make('f', 10, 11)
            make('g', 12)                                            # staged after current: someone may activate it
            self.assertEqual(deploy_release.prune(releases, current), ['a', 'b', 'c'])
            self.assertEqual(sorted(p.name for p in releases.iterdir()), ['d', 'e', 'f', 'g'])


if __name__ == '__main__':
    unittest.main()
