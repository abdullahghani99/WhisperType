"""Real loopback agent checks. Never prepares a target or posts key events."""
import http.client
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import time

binary = sys.argv[1]
with tempfile.TemporaryDirectory(prefix='vf-agent-http-') as root:
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    key = secrets.token_hex(32)
    env = dict(os.environ, VF_AGENT_PORT=str(port), VF_AGENT_HOST='127.0.0.1', VF_AGENT_KEY=key, VF_AGENT_DATA_DIR=root)
    process = subprocess.Popen([binary], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        def request(method, path, body=None, headers=None):
            connection = http.client.HTTPConnection('127.0.0.1', port, timeout=3)
            try:
                connection.request(method, path, body=body, headers=headers or {})
                response = connection.getresponse()
                return response.status, json.loads(response.read())
            finally:
                connection.close()
        for attempt in range(100):
            try:
                code, health = request('GET', '/health')
                break
            except OSError:
                if process.poll() is not None:
                    raise AssertionError('Agent exited during startup')
                time.sleep(.05)
        else:
            raise AssertionError('Agent did not start')
        assert code == 200 and health['paired'] is True
        checks = 1
        for path in ['/insert', '/prepare', '/unknown']:
            code, _ = request('POST', path, b'{}')
            assert code == 401, (path, code)
            checks += 1
        auth = {'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'}
        code, _ = request('POST', '/insert', b'{}', auth)
        assert code == 422
        checks += 1
        # A valid payload without preparation can never insert, even if this
        # binary was already granted Accessibility by the user.
        import uuid
        code, _ = request('POST', '/insert', json.dumps({'id': str(uuid.uuid4()), 'text': 'Synthetic test that must never be typed.'}), auth)
        assert code in (403, 409)
        assert not list(Path(root).glob('*.json'))
        checks += 1
        with socket.create_connection(('127.0.0.1', port), timeout=3) as connection:
            connection.sendall(b'POST /insert HTTP/1.1\r\nContent-Length: -20\r\n\r\n')
            response = connection.recv(4096)
            assert b'413' in response.split(b'\r\n')[0]
            checks += 1
        assert process.poll() is None
        print(f'Agent loopback HTTP: {checks} checks passed. No target prepared; no insertion attempted.')
    finally:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait()
