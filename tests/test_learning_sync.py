import fcntl
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('learning_sync', Path(__file__).resolve().parents[1] / 'scripts/sync_learning_toolchain.py')
sync = importlib.util.module_from_spec(spec); spec.loader.exec_module(sync)


class LearningSyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name); self.source = base / 'source'; self.root = base / 'learning'
        self.root.mkdir(); self.releases = base / 'releases'; live = self.releases / 'release-1'; live.mkdir(parents=True)
        self.files = {}
        for name in sync.FILES:
            p = self.source / name; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(name)
            self.files[name] = sync.sha(p)
        for name in ('polish.py', 'learning.py'): (live / name).write_bytes((self.source / 'server' / name).read_bytes())
        self.manifest = {'source_commit': 'a' * 40, 'files': self.files}
        (self.source / 'manifest.json').write_text(json.dumps(self.manifest))
        (live / 'release-manifest.json').write_text(json.dumps({'sha256': {n: self.files['server/' + n] for n in ('polish.py', 'learning.py')}}))
        self.health = {'status': 'ok', 'release': 'release-1', 'polish_uses_prompt_model': True,
                       'prompt_model': 'mlx-community/Qwen2.5-14B-Instruct-4bit', 'polish_policy_sha256': self.files['server/polish.py']}

    def install(self):
        return sync.install(self.source, self.root, self.releases, self.health)

    def test_matching_release_installs_and_preserves_previous_version(self):
        old = self.root / 'old'; old.mkdir(); (self.root / 'toolchain').symlink_to(old)
        self.assertEqual(self.install()['learning_sync'], 'aligned')
        self.assertTrue(old.exists())
        self.assertEqual(sync.sha(self.root / 'toolchain/server/polish.py'), self.files['server/polish.py'])
        self.assertEqual(self.install()['learning_sync'], 'aligned')

    def test_loaded_policy_mismatch_does_not_switch(self):
        self.health['polish_policy_sha256'] = 'different'
        with self.assertRaises(ValueError): self.install()
        self.assertFalse((self.root / 'toolchain').exists())

    def test_manifest_or_payload_mismatch_does_not_switch(self):
        (self.releases / 'release-1/polish.py').write_text('concurrent edit')
        with self.assertRaises(ValueError): self.install()
        self.assertFalse((self.root / 'toolchain').exists())

    def test_active_learning_is_not_replaced(self):
        with (self.root / 'learning-cycle.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError): self.install()
        self.assertFalse((self.root / 'toolchain').exists())


if __name__ == '__main__': unittest.main()
