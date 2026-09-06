"""Stage a verified server release over SSH, optionally through a jump host."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import tempfile

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', required=True)
    parser.add_argument('--via')
    parser.add_argument('--python', default='/opt/homebrew/bin/python3.13')
    parser.add_argument('--root')
    parser.add_argument('--plist')
    parser.add_argument('--environment', type=Path)
    parser.add_argument('--activate', action='store_true')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10']
    scp = ['scp', '-q', '-o', 'BatchMode=yes']
    if args.via: ssh += ['-J', args.via]; scp += ['-J', args.via]
    ssh += [args.host]
    remote = subprocess.check_output(ssh + ['mktemp -d /tmp/whispertype-release.XXXXXX'], text=True).strip()
    if not remote.startswith('/tmp/whispertype-release.'): raise SystemExit('Unexpected staging path')
    files = ['server.py', 'inference_worker.py', 'diarize.py', 'requirements-lock.txt', 'requirements-diarize-lock.txt', 'deploy_release.py']
    revision = subprocess.check_output(['git', 'rev-parse', '--short', 'HEAD'], cwd=repo, text=True).strip()
    manifest = {'revision': revision, 'sha256': {name: hashlib.sha256((repo/'server'/name).read_bytes()).hexdigest() for name in files}}
    try:
        with tempfile.TemporaryDirectory(prefix='whispertype-release-') as directory:
            path = Path(directory) / 'release-manifest.json'; path.write_text(json.dumps(manifest, indent=2))
            subprocess.run(scp + [str(repo/'server'/name) for name in files] + [str(path), args.host + ':' + remote + '/'], check=True)
            command = [args.python, remote + '/deploy_release.py', '--source', remote]
            for name in ('root', 'plist'):
                if getattr(args, name): command += ['--' + name, getattr(args, name)]
            if args.environment:
                subprocess.run(scp + [str(args.environment), args.host + ':' + remote + '/environment.json'], check=True)
                subprocess.run(ssh + ['chmod 600 ' + shlex.quote(remote + '/environment.json')], check=True)
                command += ['--environment', remote + '/environment.json']
            if args.activate: command += ['--activate']
            subprocess.run(ssh + [shlex.join(command)], check=True)
    finally:
        subprocess.run(ssh + ['rm -rf ' + shlex.quote(remote)], check=True)

if __name__ == '__main__': main()
