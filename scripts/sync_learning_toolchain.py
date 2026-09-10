"""Install matching learning tools after deployment; never prepare data or train."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import tempfile
import urllib.request
import uuid

FILES = ('server/polish.py', 'server/learning.py', 'scripts/learning_cycle.py',
         'scripts/evaluate_polish.py', 'scripts/split_training.py')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition, message):
    if not condition: raise ValueError(message)


def install(source, root, releases, health):
    if not root.exists():
        return {'learning_sync': 'not_configured'}
    with (root / 'learning-cycle.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        manifest = json.loads((source / 'manifest.json').read_text())
        require(re.fullmatch(r'[0-9a-f]{40}', manifest['source_commit']), 'Invalid source identity')
        require(set(manifest['files']) == set(FILES), 'Unexpected toolchain files')
        for name in FILES:
            require(sha(source / name) == manifest['files'][name], 'Bundle mismatch: ' + name)
        release = health.get('release', '')
        require(release and Path(release).name == release, 'Invalid release identity')
        require(health.get('status') == 'ok', 'Serving service is not healthy')
        require(health.get('polish_uses_prompt_model') and health.get('prompt_model') == 'mlx-community/Qwen2.5-14B-Instruct-4bit', 'Model route needs review')
        live = releases / release
        deployed = json.loads((live / 'release-manifest.json').read_text())
        for name in ('polish.py', 'learning.py'):
            expected = manifest['files']['server/' + name]
            require(sha(live / name) == deployed['sha256'][name] == expected, 'Serving/source mismatch: ' + name)
        require(health.get('polish_policy_sha256') == manifest['files']['server/polish.py'], 'Loaded policy mismatch')
        link = root / 'toolchain'
        require(not link.exists() or link.is_symlink(), 'Preserve and version the existing toolchain directory first')
        manifest['serving_release_at_install'] = release
        versions = root / 'toolchain-versions'; versions.mkdir(exist_ok=True, mode=0o700)
        version = versions / (manifest['source_commit'][:12] + '-' + manifest['files']['server/polish.py'][:8])
        if version.exists():
            existing = json.loads((version / 'manifest.json').read_text())
            require(existing['source_commit'] == manifest['source_commit'] and existing['files'] == manifest['files'], 'Version collision')
            for name in FILES:
                require(sha(version / name) == manifest['files'][name], 'Installed version mismatch')
            manifest = existing
        else:
            with tempfile.TemporaryDirectory(dir=versions, prefix='.install-') as temporary:
                staged = Path(temporary) / 'version'; staged.mkdir(mode=0o700)
                for name in FILES:
                    target = staged / name; target.parent.mkdir(exist_ok=True, mode=0o700)
                    shutil.copyfile(source / name, target); target.chmod(0o600)
                (staged / 'manifest.json').write_text(json.dumps(manifest, indent=2))
                (staged / 'manifest.json').chmod(0o600)
                os.rename(staged, version)
        next_link = root / ('toolchain-' + uuid.uuid4().hex)
        try:
            next_link.symlink_to(version); os.replace(next_link, link)
        finally:
            next_link.unlink(missing_ok=True)
        summary = root / ('manifest-' + uuid.uuid4().hex)
        summary.write_text(json.dumps(manifest, indent=2)); summary.chmod(0o600)
        os.replace(summary, root / 'toolchain-manifest.json')
        return {'learning_sync': 'aligned', 'release': release, 'source_commit': manifest['source_commit']}


def sync(repo, ssh, scp, host, python, root=None, plist=None):
    remote = subprocess.check_output(ssh + ['mktemp -d /tmp/whispertype-learning.XXXXXX'], text=True).strip()
    if not remote.startswith('/tmp/whispertype-learning.'): raise RuntimeError('Unexpected staging path')
    try:
        with tempfile.TemporaryDirectory(prefix='whispertype-learning-') as directory:
            source = Path(directory)
            for name in FILES:
                target = source / name; target.parent.mkdir(exist_ok=True)
                shutil.copyfile(repo / name, target)
            manifest = {'source_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip(),
                        'files': {name: sha(source / name) for name in FILES}}
            (source / 'manifest.json').write_text(json.dumps(manifest))
            shutil.copyfile(Path(__file__), source / 'install.py')
            subprocess.run(scp + ['-r', str(source) + '/.', host + ':' + remote + '/'], check=True)
            command = [python, remote + '/install.py', '--install-local', remote]
            if root: command += ['--server-root', root]
            if plist: command += ['--plist', plist]
            subprocess.run(ssh + [shlex.join(command)], check=True)
    finally:
        subprocess.run(ssh + ['rm -rf ' + shlex.quote(remote)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--install-local', type=Path)
    parser.add_argument('--host'); parser.add_argument('--via')
    parser.add_argument('--python', default='/opt/homebrew/bin/python3.13')
    parser.add_argument('--server-root')
    parser.add_argument('--plist')
    args = parser.parse_args()
    if args.install_local:
        os.umask(0o077)
        root = Path.home() / 'whispertype-learning'
        if not root.exists(): print(json.dumps({'learning_sync': 'not_configured'})); return
        config = plistlib.loads(Path(args.plist or Path.home() / 'Library/LaunchAgents/app.whispertype.server.plist').expanduser().read_bytes())
        argv = config['ProgramArguments']; port = argv[argv.index('--port') + 1]
        health = json.load(urllib.request.urlopen('http://127.0.0.1:' + port + '/health', timeout=8))
        print(json.dumps(install(args.install_local, root, Path(args.server_root or Path.home() / 'whispertype').expanduser() / 'releases', health)))
    else:
        if not args.host: parser.error('--host is required')
        ssh = ['ssh', '-o', 'BatchMode=yes']; scp = ['scp', '-q', '-o', 'BatchMode=yes']
        if args.via: ssh += ['-J', args.via]; scp += ['-J', args.via]
        # Omit local-machine defaults so remote home paths are resolved there.
        sync(Path(__file__).resolve().parents[1], ssh + [args.host], scp, args.host, args.python, args.server_root, args.plist)


if __name__ == '__main__': main()
