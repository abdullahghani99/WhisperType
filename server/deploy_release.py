"""Stage a complete release; activation is a separate, explicit operation.

Run on the server Mac. Existing model, authentication, retention and network
settings are preserved. No vocabulary, audio or model weights ship in a release.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import subprocess
import sys
import time
import urllib.request
import uuid

FILES = ('server.py', 'inference_worker.py', 'diarize.py',
         'requirements-lock.txt', 'requirements-diarize-lock.txt')

def configuration(previous, root, release, updates):
    config = dict(previous)
    env = dict(previous.get('EnvironmentVariables', {}))
    env.update(updates)
    old_root = Path(previous.get('WorkingDirectory', root))
    # Moving source into a release must never move the live data or adapter.
    for key, path in {'VF_DB_PATH': old_root / 'history.sqlite', 'VF_VOCAB_PATH': old_root / 'vocab.json',
                      'VF_SPOOL_DIR': old_root / 'spool', 'VF_POLISH_ADAPTER': old_root / 'lora-polish'}.items():
        env.setdefault(key, str(path))
    env['VF_DIARIZE_PY'] = str(release / 'diarize-venv/bin/python')
    env['VF_DIARIZE_SCRIPT'] = str(release / 'diarize.py')
    env['VF_RELEASE_ID'] = release.name
    env.setdefault('PATH', '/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin')
    old_args = previous.get('ProgramArguments', [])
    def option(name, fallback):
        return old_args[old_args.index(name)+1] if name in old_args and old_args.index(name)+1 < len(old_args) else fallback
    port = str(env.get('VF_PORT', option('--port', '8790')))
    bind = str(env.get('VF_BIND_HOST', option('--host', '0.0.0.0')))
    config.update(Label=previous.get('Label', 'app.whispertype.server'),
                  ProgramArguments=[str(release / 'venv/bin/python'), '-m', 'uvicorn', 'server:app', '--host', bind, '--port', port],
                  WorkingDirectory=str(release), EnvironmentVariables=env,
                  RunAtLoad=True, KeepAlive=True)
    config.setdefault('StandardOutPath', str(root / 'whispertype.log'))
    config.setdefault('StandardErrorPath', str(root / 'whispertype.log'))
    return config

def atomic_write(path, data):
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex)
    try:
        with temporary.open('xb') as file:
            os.chmod(temporary, 0o600); file.write(data); file.flush(); os.fsync(file.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--root', type=Path, default=Path.home() / 'whispertype')
    parser.add_argument('--plist', type=Path, default=Path.home() / 'Library/LaunchAgents/app.whispertype.server.plist')
    parser.add_argument('--environment', type=Path, help='Optional explicit overrides; unspecified existing settings survive')
    parser.add_argument('--activate', action='store_true')
    args = parser.parse_args()
    if sys.version_info[:2] != (3, 13): raise SystemExit('Use Python 3.13 for the tested lock files')
    source = args.source.resolve(); root = args.root.resolve(); plist = args.plist.expanduser().resolve()
    manifest = json.loads((source / 'release-manifest.json').read_text())
    for name in FILES:
        if hashlib.sha256((source / name).read_bytes()).hexdigest() != manifest['sha256'].get(name):
            raise SystemExit('Release manifest mismatch: ' + name)
    root.mkdir(parents=True, exist_ok=True)
    release = root / 'releases' / (manifest['revision'] + '-' + uuid.uuid4().hex[:8])
    release.mkdir(parents=True, mode=0o700)
    for name in FILES: shutil.copy2(source / name, release / name)
    shutil.copy2(source / 'release-manifest.json', release / 'release-manifest.json')
    previous_bytes = plist.read_bytes() if plist.exists() else None
    previous = plistlib.loads(previous_bytes) if previous_bytes else {}
    updates = json.loads(args.environment.read_text()) if args.environment else {}
    if not isinstance(updates, dict) or not all(isinstance(k, str) and isinstance(v, str) for k,v in updates.items()):
        raise SystemExit('Environment overrides must be a JSON object of strings')
    with (release / 'install.log').open('wb') as log:
        for directory, lock in [('venv', 'requirements-lock.txt'), ('diarize-venv', 'requirements-diarize-lock.txt')]:
            subprocess.run([sys.executable, '-m', 'venv', str(release / directory)], check=True, stdout=log, stderr=log)
            python = str(release / directory / 'bin/python')
            subprocess.run([python, '-m', 'pip', 'install', '-r', str(release / lock)], check=True, stdout=log, stderr=log)
            subprocess.run([python, '-m', 'pip', 'check'], check=True, stdout=log, stderr=log)
        subprocess.run([str(release/'venv/bin/python'), '-c', 'import mlx_lm,mlx_whisper,fastapi,uvicorn,inference_worker'], cwd=release, check=True, stdout=log, stderr=log)
        subprocess.run([str(release/'diarize-venv/bin/python'), '-c', 'from pyannote.audio import Pipeline; import torch,numpy'], check=True, stdout=log, stderr=log)
    candidate = configuration(previous, root, release, updates)
    candidate_path = release / 'launch-agent.plist'
    atomic_write(candidate_path, plistlib.dumps(candidate))
    print(json.dumps({'release': str(release), 'staged': True, 'activation_requested': args.activate}), flush=True)
    if not args.activate: return
    # Refuse to race a concurrent operator edit made while dependencies installed.
    if (plist.read_bytes() if plist.exists() else None) != previous_bytes:
        raise SystemExit('LaunchAgent changed during staging; inspect and stage again')
    database = Path(candidate['EnvironmentVariables']['VF_DB_PATH'])
    if database.exists():
        with sqlite3.connect(database) as live, sqlite3.connect(release / 'before-activation.sqlite') as backup:
            live.backup(backup)
        os.chmod(release / 'before-activation.sqlite', 0o600)
    if previous_bytes: atomic_write(release / 'previous-launch-agent.plist', previous_bytes)
    plist.parent.mkdir(parents=True, exist_ok=True)
    domain = 'gui/' + str(os.getuid())
    subprocess.run(['launchctl', 'bootout', domain, str(plist)], capture_output=True)
    try:
        atomic_write(plist, plistlib.dumps(candidate))
        subprocess.run(['launchctl', 'bootstrap', domain, str(plist)], check=True)
        port = candidate['ProgramArguments'][-1]
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            try:
                with urllib.request.urlopen('http://127.0.0.1:' + port + '/health', timeout=3) as response:
                    health = json.load(response)
                    if health.get('status') == 'ok' and health.get('release') == release.name:
                        print(json.dumps({'activated': True, 'release': str(release)})); return
            except (OSError, ValueError): pass
            time.sleep(2)
        raise RuntimeError('New service did not become healthy')
    except BaseException:
        subprocess.run(['launchctl', 'bootout', domain, str(plist)], capture_output=True)
        if previous_bytes:
            atomic_write(plist, previous_bytes)
            subprocess.run(['launchctl', 'bootstrap', domain, str(plist)], check=True)
        else: plist.unlink(missing_ok=True)
        # Never overwrite a database containing new user writes during rollback.
        # Additive migrations remain compatible; the snapshot is for manual recovery.
        raise

if __name__ == '__main__': main()
