"""Synthetic regression checks: no models, personal data, or live endpoints."""
import asyncio
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest.mock import patch

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE))
from inference_worker import InferenceWorker, InferenceBusy


class ReliabilityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        stub = types.ModuleType('mlx_lm')
        stub.load = lambda *a, **kw: (None, None)
        stub.generate = lambda *a, **kw: ''
        self.env = patch.dict(os.environ, {
            'VF_DB_PATH': str(base/'history.sqlite'), 'VF_SPOOL_DIR': str(base/'spool'),
            'VF_VOCAB_PATH': str(base/'vocab.json'), 'VF_API_KEY': '', 'VF_POLISH': '0', 'VF_PROMPT': '0'})
        self.env.start(); self.addCleanup(self.env.stop)
        sys.modules['mlx_lm'] = stub
        spec = importlib.util.spec_from_file_location('reliability_server', HERE/'server.py')
        self.m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.m)
        self.m._init_db()
        self.m._WHISPER_LOCAL = False
        self.actual_remote = self.m._transcribe_remote
        self.m._transcribe_remote = lambda *a: 'A useful transcript.'
        from fastapi.testclient import TestClient
        self.client = TestClient(self.m.app)
        self.addCleanup(self.client.close)

    def job(self, title='Meeting 2026-09-06'):
        with sqlite3.connect(self.m.DB_PATH) as con:
            n = con.execute("INSERT INTO meetings (title,status) VALUES (?, 'processing')", (title,)).lastrowid
        Path(self.m.SPOOL_DIR).mkdir(exist_ok=True)
        Path(self.m._spool_path(n)).write_bytes(b'original audio')
        return n

    def test_auth_is_default_for_all_sensitive_routes(self):
        self.m.API_KEY = 'test-key'
        for path in ['/history','/meetings','/meeting/1','/vocab','/voiceprints','/suggestions','/learning/status']:
            self.assertEqual(self.client.get(path).status_code, 401, path)
        self.assertEqual(self.client.post('/retranscribe?id=1').status_code, 401)
        self.assertEqual(self.client.get('/health').status_code, 200)
        self.assertEqual(self.client.get('/history', headers={'Authorization':'Bearer test-key'}).status_code, 200)
        self.m.API_KEY = ''
        self.assertEqual(self.client.get('/history').status_code, 200)

    def test_correction_api_roundtrip_stale_protection_and_deletion(self):
        original = "Can we check the payroll report."
        hid = self.m._capture(original, original, original, 1, 1, 1, b"audio")
        body = {"id": hid, "edited": "Can we check the payroll report?", "expected": original}
        self.assertEqual(self.client.post('/correct', json=body).status_code, 200)
        self.assertEqual(self.client.get('/learning/status').json()['corrections'], 1)
        self.assertEqual(self.client.get('/history').json()['items'][0]['polished'], original)
        self.assertEqual(self.client.get('/history').json()['items'][0]['edited'], body['edited'])
        self.assertEqual(self.client.post('/correct', json=body).status_code, 409)
        self.assertEqual(self.client.delete('/history/'+str(hid)).status_code, 200)
        with sqlite3.connect(self.m.DB_PATH) as con:
            self.assertEqual(con.execute('SELECT count(*) FROM learning_feedback').fetchone()[0], 0)

    def test_meeting_corrections_are_separate_and_displayed(self):
        hid = self.job()
        with sqlite3.connect(self.m.DB_PATH) as con:
            con.execute("UPDATE meetings SET status='done',transcript='Alex will send the report.',notes='Send the report.' WHERE id=?", (hid,))
        body = {"task": "meeting_notes", "id": hid, "edited": "Alex: send the report.", "expected": "Send the report."}
        self.assertEqual(self.client.post('/learning/feedback',json=body).status_code,200)
        self.assertEqual(self.client.get('/meeting/'+str(hid)).json()['notes'],body['edited'])
        self.assertEqual(self.client.get('/learning/status').json()['feedback']['meeting_notes'],1)
        self.assertEqual(self.client.post('/learning/feedback',json={**body,'task':[]}).status_code,400)

    def test_spool_failure_is_not_accepted(self):
        with patch.object(self.m.os, 'makedirs', side_effect=OSError('disk unavailable')):
            response = self.client.post('/meeting', files={'file': ('x.wav', b'audio')})
        self.assertEqual(response.status_code, 507)
        self.assertEqual(self.client.get('/meetings').json()['items'][0]['status'], 'error')
        self.assertFalse(self.m._meeting_tasks)

    def test_streamed_upload_limit_empty_body_and_backlog(self):
        import io
        n = self.job()
        Path(self.m._spool_path(n)).unlink()
        with self.assertRaises(self.m.HTTPException) as raised:
            self.m._write_meeting_spool(n, io.BytesIO(b'oversize'), 2)
        self.assertEqual(raised.exception.status_code, 413)
        self.assertFalse(Path(self.m._spool_path(n)).exists())
        self.assertFalse(list(Path(self.m.SPOOL_DIR).glob('*.pending')))
        self.assertEqual(self.client.post('/meeting', files={'file':('empty.wav',b'')}).status_code, 422)
        with patch.dict(os.environ, {'VF_MAX_PENDING_MEETINGS':'1'}):
            self.assertEqual(self.client.post('/meeting',files={'file':('a.wav',b'audio')}).status_code,429)

    def test_vocabulary_removal_restore_rejects_later_conflict(self):
        self.client.post('/vocab', json={'replacements':{'helo':'hello'}})
        removed = self.client.post('/vocab/remove', json={'kind':'replacements','key':'helo','value':'hello'})
        self.assertEqual(removed.status_code,200)
        restored = self.client.post('/vocab/restore', json={'kind':'replacements','key':'helo','value':'hello'})
        self.assertEqual(restored.status_code,200)
        self.client.post('/vocab', json={'replacements':{'helo':'new correction'}})
        self.assertEqual(self.client.post('/vocab/restore',json={'kind':'replacements','key':'helo','value':'hello'}).status_code,409)

    def test_real_speech_is_not_removed_just_for_its_wording(self):
        self.assertEqual(self.m._strip_hallucinations('Thanks for watching.', has_speech=True), 'Thanks for watching.')
        phrase='Please subscribe. We publish a new lesson each Friday.'
        self.assertEqual(self.m._strip_hallucinations(phrase, has_speech=True),phrase)
        self.assertEqual(self.m._strip_hallucinations('Thanks for watching.',has_speech=False),'')

    def test_legacy_remote_translation_requires_an_actual_translation(self):
        from unittest.mock import Mock
        missing=Mock(status_code=404)
        transcript=Mock(status_code=200); transcript.json.return_value={'text':'La reunión será el viernes.'}
        with patch.object(self.m,'_transcribe_remote',self.actual_remote), patch.object(self.m.requests,'post',side_effect=[missing,transcript]), patch.object(self.m,'_translate_transcript',return_value='The meeting will be on Friday.') as translate:
            self.assertEqual(self.m._transcribe_remote(b'audio','x.wav','es',True),'The meeting will be on Friday.')
            translate.assert_called_once_with('La reunión será el viernes.')
        with self.assertRaises(RuntimeError): self.m._translate_transcript('Texto sin modelo')

    def test_no_speech_is_an_error_not_a_successful_empty_dictation(self):
        async def no_speech(*args): return '', 1
        with patch.object(self.m,'_run_asr',side_effect=no_speech):
            response=self.client.post('/dictate',files={'file':('silence.wav',b'audio')})
        self.assertEqual(response.status_code,422)
        self.assertEqual(self.client.get('/history').json()['items'],[])

    def test_vocabulary_values_are_literal_and_empty_triggers_are_rejected(self):
        self.assertEqual(self.client.post('/vocab',json={'snippets':{'':'bad'}}).status_code,422)
        self.m._vocab['replacements']={'workspace':r'C:\new\scripts'}
        self.assertEqual(self.m.apply_vocab('Open workspace'),r'Open C:\new\scripts')

    def test_transcript_commit_precedes_spool_deletion(self):
        n = self.job()
        original = self.m._meeting_set
        def fail_commit(job, **columns):
            if 'transcript' in columns:
                self.assertTrue(Path(self.m._spool_path(n)).exists())
                raise OSError('injected commit failure')
            return original(job, **columns)
        with patch.object(self.m, '_meeting_set', side_effect=fail_commit):
            asyncio.run(self.m._process_meeting(n, b'audio', None, False, True))
        self.assertTrue(Path(self.m._spool_path(n)).exists())

    def test_translation_without_diarizer_and_with_remote_fallback(self):
        for local in [False, True]:
            n = self.job()
            self.m._WHISPER_LOCAL = local
            seen = []
            def remote(audio, filename, language, translate=False):
                seen.append(translate)
                return 'Translated meeting.'
            with patch.object(self.m, '_transcribe_remote', side_effect=remote), patch.object(
                    self.m, '_transcribe_local_segments', side_effect=RuntimeError('local failed')):
                asyncio.run(self.m._process_meeting(n, b'audio', None, False, True))
            self.assertEqual(seen, [True])
            self.assertEqual(self.m._meeting_row(n)['status'], 'done')
            self.assertFalse(Path(self.m._spool_path(n)).exists())

    def test_notes_pending_and_manual_title_preserved(self):
        n = self.job()
        self.m._model = object()
        self.m._meeting_title = lambda text: 'Generated title'
        def notes(text):
            row = self.m._meeting_row(n)
            self.assertEqual(row['status'], 'processing')
            self.assertEqual(row['transcript'], 'A useful transcript.')
            self.assertFalse(Path(self.m._spool_path(n)).exists())
            with sqlite3.connect(self.m.DB_PATH) as con:
                con.execute("UPDATE meetings SET title='My title', title_manual=1 WHERE id=?", (n,))
            return 'Useful notes.'
        self.m._meeting_notes = notes
        asyncio.run(self.m._process_meeting(n, b'audio', None, False, False))
        row = self.m._meeting_row(n)
        self.assertEqual((row['title'],row['notes_status'],row['status']), ('My title','ready','done'))

    def test_restart_after_transcript_commit_keeps_result(self):
        n = self.job()
        self.m._meeting_set(n, transcript='Committed words', notes_status='generating')
        Path(self.m._spool_path(n)).unlink()
        self.m._init_db()
        self.assertEqual(self.m._meeting_row(n)['status'], 'processing')
        asyncio.run(self.m._run_spooled_meeting(n))
        self.assertEqual(self.m._meeting_row(n)['transcript'], 'Committed words')
        self.assertEqual(self.m._meeting_row(n)['status'], 'done')

    def test_deletion_removes_spool_and_does_not_recreate_job(self):
        n = self.job()
        self.assertEqual(self.client.delete(f'/meeting/{n}').status_code, 200)
        self.assertFalse(Path(self.m._spool_path(n)).exists())
        with self.assertRaises(asyncio.CancelledError):
            asyncio.run(self.m._process_meeting(n, b'audio', None, False, False))
        self.assertIsNone(self.m._meeting_row(n))

    def test_remote_call_does_not_block_event_loop(self):
        def slow(*args):
            time.sleep(.15)
            return 'A useful transcript'
        self.m._transcribe_remote = slow
        async def run():
            task = asyncio.create_task(self.m._run_asr(b'audio','x.wav',None))
            start = time.monotonic()
            await asyncio.sleep(.01)
            self.assertLess(time.monotonic()-start,.1)
            await task
        asyncio.run(run())

    def test_polish_preserves_amounts_and_negation(self):
        bad = self.m._polish_failed
        self.assertTrue(bad('Do not approve the transfer of 500 dollars', 'Do approve the transfer of 5000 dollars'))
        self.assertTrue(bad('Do not approve', 'Do approve'))
        self.assertTrue(bad('Pay 500', 'Pay 5000'))
        self.assertFalse(bad('um pay 500 dollars', 'Pay 500 dollars.'))
        self.assertFalse(bad('first fix tests then ship code', '1. Fix tests\n2. Ship code'))


class WorkerTests(unittest.TestCase):
    def test_cancelled_running_work_never_overlaps_and_priority_is_respected(self):
        worker = InferenceWorker(capacity=2)
        entered, release = threading.Event(), threading.Event()
        order=[]
        def blocked():
            entered.set(); release.wait(2); order.append('running')
        async def run():
            running=asyncio.create_task(worker.submit(blocked))
            while not entered.is_set(): await asyncio.sleep(.001)
            running.cancel()
            with self.assertRaises(asyncio.CancelledError): await running
            background=asyncio.create_task(worker.submit(lambda: order.append('background'), priority=10))
            foreground=asyncio.create_task(worker.submit(lambda: order.append('foreground'), priority=0))
            await asyncio.sleep(.01)
            with self.assertRaises(InferenceBusy): await worker.submit(lambda: None)
            self.assertEqual(order, [])
            release.set()
            await asyncio.gather(background, foreground)
        asyncio.run(run())
        self.assertEqual(order, ['running','foreground','background'])


if __name__ == '__main__': unittest.main()
