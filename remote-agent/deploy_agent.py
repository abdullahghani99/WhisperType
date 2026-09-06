"""Stage a signed agent; explicit activation preserves settings and can roll back."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import sys
import time
import urllib.request
import uuid

def agent_environment(previous, updates, release):
    env = dict(previous.get('EnvironmentVariables', {})); env.update(updates)
    env.setdefault('VF_AGENT_PORT', '8791'); env.setdefault('VF_AGENT_HOST', '127.0.0.1')
    env['VF_AGENT_RELEASE'] = release
    return env

def remote(args):
    source = args.remote_source.resolve()
    root = Path.home() / 'Library/Application Support/WhisperType/AgentReleases'
    release = root / uuid.uuid4().hex
    release.mkdir(parents=True, mode=0o700)
    shutil.copy2(source/'Package.swift', release/'Package.swift')
    shutil.copytree(source/'Sources', release/'Sources')
    with (release/'build.log').open('wb') as log:
        subprocess.run(['swift','build','-c','release','--package-path',str(release)], check=True, stdout=log, stderr=log)
    binary_dir = Path(subprocess.check_output(['swift','build','-c','release','--package-path',str(release),'--show-bin-path'], text=True).strip())
    staged = release/'vfinsert.app'
    (staged/'Contents/MacOS').mkdir(parents=True)
    shutil.copy2(binary_dir/'vfinsert', staged/'Contents/MacOS/vfinsert')
    (staged/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleName':'vfinsert','CFBundleIdentifier':'app.whispertype.agent',
        'CFBundleExecutable':'vfinsert','CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.0',
        'CFBundleVersion':release.name,'LSUIElement':True,'LSMinimumSystemVersion':'13.0'}))
    # The caller may choose a stable unlocked identity. Never store or pass a
    # keychain password, suppress a signing failure, or silently fall back.
    subprocess.run(['codesign','--force','--sign',args.sign,str(staged)], check=True)
    subprocess.run(['codesign','--verify','--strict',str(staged)], check=True)
    app = Path.home()/'Applications/vfinsert.app'
    plist = Path.home()/'Library/LaunchAgents/app.whispertype.agent.plist'
    old_bytes = plist.read_bytes() if plist.exists() else None
    old = plistlib.loads(old_bytes) if old_bytes else {}
    updates = json.loads(args.environment.read_text()) if args.environment else {}
    if not isinstance(updates,dict) or not all(isinstance(k,str) and isinstance(v,str) for k,v in updates.items()):
        raise SystemExit('Environment overrides must contain string keys and values')
    env = agent_environment(old, updates, release.name)
    config = dict(old)
    config.update(Label=old.get('Label','app.whispertype.agent'), ProgramArguments=[str(app/'Contents/MacOS/vfinsert')],
                  EnvironmentVariables=env, RunAtLoad=True, KeepAlive=True)
    config.setdefault('StandardOutPath',str(root/'agent.log')); config.setdefault('StandardErrorPath',str(root/'agent.log'))
    candidate = release/'launch-agent.plist'; candidate.write_bytes(plistlib.dumps(config)); candidate.chmod(0o600)
    print(json.dumps({'staged':str(staged),'activation_requested':args.activate}), flush=True)
    if not args.activate: return
    if len(env.get('VF_AGENT_KEY','').encode()) < 32:
        raise SystemExit('Activation requires a pairing key of at least 32 bytes in preserved settings or --environment')
    app.parent.mkdir(parents=True,exist_ok=True); plist.parent.mkdir(parents=True,exist_ok=True)
    previous_app = release/'previous.app'
    if old_bytes:
        previous_plist = release/'previous.plist'; previous_plist.write_bytes(old_bytes); previous_plist.chmod(0o600)
    domain = 'gui/'+str(os.getuid())
    subprocess.run(['launchctl','bootout',domain,str(plist)],capture_output=True)
    had_app = app.exists()
    moved_previous = False
    installed = False
    try:
        if had_app:
            os.replace(app,previous_app); moved_previous = True
        installed = True
        shutil.copytree(staged,app)
        temporary = plist.with_suffix('.new'); temporary.write_bytes(plistlib.dumps(config)); temporary.chmod(0o600); os.replace(temporary,plist)
        subprocess.run(['launchctl','bootstrap',domain,str(plist)],check=True)
        bind = env['VF_AGENT_HOST']; address = '127.0.0.1' if bind == '0.0.0.0' else bind
        deadline = time.monotonic()+15
        while time.monotonic() < deadline:
            try:
                with urllib.request.urlopen('http://'+address+':'+env['VF_AGENT_PORT']+'/health',timeout=2) as response:
                    health=json.load(response)
                    if health.get('release') == release.name and health.get('paired'):
                        print(json.dumps({'activated':True,'accessibility':health.get('accessibility'), 'rollback':str(release)})); return
            except (OSError,ValueError): pass
            time.sleep(.5)
        raise RuntimeError('New paired agent did not become healthy')
    except BaseException:
        subprocess.run(['launchctl','bootout',domain,str(plist)],capture_output=True)
        if installed and app.exists(): shutil.rmtree(app)
        if moved_previous: os.replace(previous_app,app)
        if old_bytes:
            plist.write_bytes(old_bytes); plist.chmod(0o600)
            subprocess.run(['launchctl','bootstrap',domain,str(plist)],check=True)
        else: plist.unlink(missing_ok=True)
        raise

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host'); parser.add_argument('--via')
    parser.add_argument('--sign',default='-',help='Stable, unlocked signing identity; ad-hoc requires a new Accessibility grant')
    parser.add_argument('--environment',type=Path)
    parser.add_argument('--activate',action='store_true')
    parser.add_argument('--remote-source',type=Path)
    args=parser.parse_args()
    if args.remote_source: remote(args); return
    if not args.host: parser.error('--host is required')
    ssh=['ssh','-o','BatchMode=yes','-o','ConnectTimeout=10']; scp=['scp','-q','-o','BatchMode=yes']
    if args.via: ssh += ['-J',args.via]; scp += ['-J',args.via]
    ssh += [args.host]
    stage=subprocess.check_output(ssh+['mktemp -d /tmp/whispertype-agent.XXXXXX'],text=True).strip()
    if not stage.startswith('/tmp/whispertype-agent.'): raise SystemExit('Unexpected staging directory')
    root=Path(__file__).resolve().parent
    try:
        subprocess.run(ssh+['mkdir -p '+shlex.quote(stage+'/Sources/vfinsert')],check=True)
        subprocess.run(scp+[str(root/'Package.swift'),str(root/'deploy_agent.py'),args.host+':'+stage+'/'],check=True)
        subprocess.run(scp+[str(p) for p in (root/'Sources/vfinsert').glob('*.swift')]+[args.host+':'+stage+'/Sources/vfinsert/'],check=True)
        command=['python3',stage+'/deploy_agent.py','--remote-source',stage,'--sign',args.sign]
        if args.environment:
            subprocess.run(scp+[str(args.environment),args.host+':'+stage+'/environment.json'],check=True)
            command += ['--environment',stage+'/environment.json']
        if args.activate: command += ['--activate']
        subprocess.run(ssh+[shlex.join(command)],check=True)
    finally: subprocess.run(ssh+['rm -rf '+shlex.quote(stage)],check=True)

if __name__ == '__main__': main()
