"""Require explicit semantic approval tied to the exact candidate weights."""
import argparse
import json
from pathlib import Path
import shlex
import subprocess

def validate(report, candidate_digest):
    if report.get('human_approved') is not True:
        raise ValueError('The semantic report has not been explicitly approved')
    if report.get('automated_invariants_pass') is not True:
        raise ValueError('Semantic invariant checks did not pass')
    candidates=[m for m in report.get('models',[]) if m.get('label')=='candidate']
    if len(candidates)!=1 or candidates[0].get('adapter_sha256')!=candidate_digest:
        raise ValueError('Review belongs to different candidate weights; evaluate the current candidate')
    if not report.get('fixture_sha256') or not report.get('prompt_sha256'):
        raise ValueError('Review is missing fixture or prompt provenance')

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report',type=Path); parser.add_argument('--host',required=True)
    parser.add_argument('--via'); parser.add_argument('--candidate-dir',default='~/whispertype/lora-staging')
    args=parser.parse_args()
    ssh=['ssh','-o','BatchMode=yes','-o','ConnectTimeout=10']
    if args.via: ssh+=['-J',args.via]
    script='''import hashlib,os,pathlib,sys
p=pathlib.Path(os.path.expanduser(sys.argv[1])); h=hashlib.sha256()
assert (p/'adapters.safetensors').exists()
for file in sorted(p.iterdir()):
 if file.suffix in ('.safetensors','.json'): h.update(file.name.encode()); h.update(file.read_bytes())
print(h.hexdigest())
'''
    result=subprocess.run(ssh+[args.host,'python3 - '+shlex.quote(args.candidate_dir)],input=script,text=True,capture_output=True,check=True)
    validate(json.loads(args.report.read_text()),result.stdout.strip())
    print('Semantic review matches the candidate weights and includes explicit approval')

if __name__=='__main__': main()
