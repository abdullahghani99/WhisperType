"""Install the client while preserving its LaunchAgent configuration."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time
import uuid

def configuration(previous, binary, updates=None):
    config=dict(previous)
    env=dict(previous.get('EnvironmentVariables',{})); env.update(updates or {})
    config.update(Label=previous.get('Label','app.whispertype.client'),ProgramArguments=[str(binary)],
                  RunAtLoad=True,KeepAlive={'SuccessfulExit':False},ProcessType='Interactive',EnvironmentVariables=env)
    return config

def replace_app(staged, destination, backup, activate, deactivate, restore):
    """Only remove a candidate that this transaction actually installed."""
    moved_previous = installed = False
    try:
        if destination.exists():
            os.replace(destination, backup); moved_previous = True
        os.replace(staged, destination); installed = True
        activate()
    except BaseException:
        deactivate()
        if installed and destination.exists(): shutil.rmtree(destination)
        if moved_previous: os.replace(backup, destination)
        restore()
        raise

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--uninstall',action='store_true')
    parser.add_argument('--environment',type=Path,help='JSON string-valued overrides; unspecified settings are preserved')
    args=parser.parse_args()
    root=Path(__file__).resolve().parent
    destination=Path('/Applications/WhisperType.app')
    binary=destination/'Contents/MacOS/WhisperType'
    plist=Path.home()/'Library/LaunchAgents/app.whispertype.client.plist'
    previous=plist.read_bytes() if plist.exists() else None
    updates=json.loads(args.environment.read_text()) if args.environment else {}
    if not isinstance(updates,dict) or not all(isinstance(k,str) and isinstance(v,str) for k,v in updates.items()):
        raise SystemExit('Environment overrides must contain string keys and values')
    if not args.uninstall:
        subprocess.run(['bash',str(root/'build_app.sh')],check=True)
        subprocess.run(['codesign','--verify','--strict',str(root/'WhisperType.app')],check=True)
    # A normal quit can preserve unsaved work or be canceled by the user. Never
    # force-kill an app merely because it has not finished saving a recording.
    subprocess.run(['osascript','-e','tell application id "app.whispertype.client" to quit'],capture_output=True)
    for _ in range(100):
        commands=subprocess.check_output(['ps','-axo','comm='],text=True).splitlines()
        if str(binary) not in commands: break
        time.sleep(.1)
    else: raise SystemExit('WhisperType is still running; finish or cancel its quit dialog, then try again')
    if (plist.read_bytes() if plist.exists() else None) != previous:
        raise SystemExit('Login settings changed during the build; inspect and try again')
    domain='gui/'+str(os.getuid())
    if args.uninstall:
        subprocess.run(['launchctl','bootout',domain,str(plist)],capture_output=True)
        plist.unlink(missing_ok=True)
        if destination.exists(): shutil.rmtree(destination)
        print('App and login item removed. Recovery recordings, preferences and server data are retained.'); return
    token=uuid.uuid4().hex[:10]
    staged=destination.with_name('.WhisperType-staged-'+token+'.app')
    backup=destination.with_name('.WhisperType-previous-'+token+'.app')
    shutil.copytree(root/'WhisperType.app',staged)
    had_app=destination.exists()
    subprocess.run(['launchctl','bootout',domain,str(plist)],capture_output=True)
    def activate():
        config=configuration(plistlib.loads(previous) if previous else {},binary,updates)
        plist.parent.mkdir(parents=True,exist_ok=True)
        temporary=plist.with_suffix('.new'); temporary.write_bytes(plistlib.dumps(config)); temporary.chmod(0o600); os.replace(temporary,plist)
        subprocess.run(['launchctl','bootstrap',domain,str(plist)],check=True)
        # A successful bootstrap only means launchd accepted the plist. Require
        # the new executable to remain alive beyond its initial startup.
        time.sleep(2)
        commands=subprocess.check_output(['ps','-axo','comm='],text=True).splitlines()
        if str(binary) not in commands: raise RuntimeError('Installed app exited during startup')
        print('Installed WhisperType and preserved its login settings. Grant access in Microphone settings, then return to the app.')
        if had_app: print('Previous app retained for rollback:',backup)
    def restore():
        if previous:
            plist.write_bytes(previous); plist.chmod(0o600)
            subprocess.run(['launchctl','bootstrap',domain,str(plist)],check=True)
        else: plist.unlink(missing_ok=True)
    replace_app(staged,destination,backup,activate,
                lambda: subprocess.run(['launchctl','bootout',domain,str(plist)],capture_output=True),restore)

if __name__=='__main__': main()
