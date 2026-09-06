import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
def module(path):
    spec = importlib.util.spec_from_file_location(path.stem, path)
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value); return value

release = module(ROOT/'server/deploy_release.py')
training = module(ROOT/'scripts/split_training.py')
semantic = module(ROOT/'scripts/semantic_gate.py')
agent = module(ROOT/'remote-agent/deploy_agent.py')
client = module(ROOT/'client/install.py')

class ReleaseAndTrainingTests(unittest.TestCase):
    def test_failed_app_backup_never_deletes_original(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); old=root/'app'; staged=root/'staged'; backup=root/'backup'
            old.mkdir(); staged.mkdir(); (old/'identity').write_text('original')
            with patch.object(client.os,'replace',side_effect=PermissionError('synthetic denied rename')):
                with self.assertRaises(PermissionError):
                    client.replace_app(staged,old,backup,lambda: None,lambda: None,lambda: None)
            self.assertEqual((old/'identity').read_text(),'original')
            self.assertTrue(staged.exists())

    def test_startup_failure_stops_candidate_then_restores_previous_app(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); old=root/'app'; staged=root/'staged'; backup=root/'backup'
            old.mkdir(); staged.mkdir(); (old/'identity').write_text('original'); (staged/'identity').write_text('candidate')
            calls=[]
            def activate():
                self.assertEqual((old/'identity').read_text(),'candidate'); raise RuntimeError('synthetic startup failure')
            def deactivate(): calls.append(('stop',(old/'identity').read_text()))
            def restore(): calls.append(('restart',(old/'identity').read_text()))
            with self.assertRaises(RuntimeError): client.replace_app(staged,old,backup,activate,deactivate,restore)
            self.assertEqual(calls,[('stop','candidate'),('restart','original')])
            self.assertEqual((old/'identity').read_text(),'original')

    def test_failed_first_install_removes_only_candidate(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); old=root/'app'; staged=root/'staged'; backup=root/'backup'; staged.mkdir()
            def fail(): raise RuntimeError('synthetic failure')
            with self.assertRaises(RuntimeError): client.replace_app(staged,old,backup,fail,lambda: None,lambda: None)
            self.assertFalse(old.exists()); self.assertFalse(backup.exists())

    def test_client_install_preserves_pairing_and_server_configuration(self):
        old={'EnvironmentVariables':{'VF_API_KEY':'test','VF_REMOTE_AGENT_KEY':'paired','VF_SERVER_URL':'http://localhost:9000'}}
        changed=client.configuration(old,Path('/Applications/Test.app/Contents/MacOS/Test'))
        self.assertEqual(changed['EnvironmentVariables'],old['EnvironmentVariables'])
        self.assertEqual(changed['KeepAlive'],{'SuccessfulExit':False})
    def test_semantic_approval_cannot_be_reused_for_other_weights(self):
        report={'human_approved':True,'automated_invariants_pass':True,'fixture_sha256':'fixture','prompt_sha256':'prompt',
                'models':[{'label':'candidate','adapter_sha256':'new'}]}
        semantic.validate(report,'new')
        with self.assertRaises(ValueError): semantic.validate(report,'other')
        report['human_approved']=False
        with self.assertRaises(ValueError): semantic.validate(report,'new')

    def test_agent_settings_survive_staging(self):
        old={'EnvironmentVariables':{'VF_AGENT_KEY':'existing key','VF_AGENT_HOST':'192.168.1.10','EXTRA':'keep'}}
        env=agent.agent_environment(old,{'VF_AGENT_PORT':'9001'},'release')
        self.assertEqual(env['VF_AGENT_KEY'],'existing key'); self.assertEqual(env['EXTRA'],'keep')
        self.assertEqual(env['VF_AGENT_HOST'],'192.168.1.10'); self.assertEqual(env['VF_AGENT_PORT'],'9001')
        self.assertNotIn('VF_AGENT_RELEASE',old['EnvironmentVariables'])
    def test_upgrade_preserves_every_existing_setting_and_data_location(self):
        previous = {'Label':'test.agent', 'WorkingDirectory':'/old/source',
                    'ProgramArguments':['/old/python','-m','uvicorn','server:app','--host','127.0.0.1','--port','9000'],
                    'EnvironmentVariables':{'VF_API_KEY':'synthetic-only','VF_POLISH':'0','VF_PROMPT':'0','UNRELATED':'retained'}}
        changed = release.configuration(previous, Path('/root'), Path('/root/releases/new'), {'VF_KEEPALIVE_SEC':'500'})
        env = changed['EnvironmentVariables']
        for key,value in previous['EnvironmentVariables'].items(): self.assertEqual(env[key], value)
        self.assertEqual(env['VF_DB_PATH'], '/old/source/history.sqlite')
        self.assertEqual(env['VF_POLISH_ADAPTER'], '/old/source/lora-polish')
        self.assertEqual(changed['ProgramArguments'][-3:], ['127.0.0.1','--port','9000'])
        self.assertEqual(previous['EnvironmentVariables'].get('VF_KEEPALIVE_SEC'), None)

    def test_explicit_override_and_existing_external_storage_survive(self):
        changed = release.configuration({'EnvironmentVariables':{'VF_DB_PATH':'/data/custom.sqlite','VF_API_KEY':'old'}}, Path('/root'), Path('/root/release'), {'VF_API_KEY':'new'})
        self.assertEqual(changed['EnvironmentVariables']['VF_DB_PATH'], '/data/custom.sqlite')
        self.assertEqual(changed['EnvironmentVariables']['VF_API_KEY'], 'new')

    def test_three_partitions_are_disjoint_even_with_duplicate_inputs(self):
        rows = [{'messages':[{'role':'user','content':f'<<<BEGIN>>>\nInput {i}\n<<<END>>>'},{'role':'assistant','content':f'Edited {i}'}]} for i in range(30)]
        split = training.split(rows + rows[:10])
        keys = {name:{training.input_key(row) for row in part} for name,part in split.items()}
        self.assertFalse(keys['train'] & keys['valid']); self.assertFalse(keys['train'] & keys['test']); self.assertFalse(keys['test'] & keys['valid'])
        self.assertEqual(sum(map(len, keys.values())), 30)
        self.assertEqual(split, training.split(rows + rows[:10]))

    def test_conflicting_gold_and_tiny_datasets_are_rejected(self):
        with self.assertRaises(ValueError): training.split([])
        a = {'messages':[{'role':'user','content':' Same  Input '},{'role':'assistant','content':'A'}]}
        b = {'messages':[{'role':'user','content':'same input'},{'role':'assistant','content':'B'}]}
        with self.assertRaises(ValueError): training.split([a,b])

if __name__ == '__main__': unittest.main()
