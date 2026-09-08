"""One bounded learning cycle: explicit feedback/reference data -> staged candidate.

Raw dictations/meetings are observations, not gold labels. No live model is
changed by this command. Run again when feedback grows; identical inputs reuse
their fingerprinted dataset. Private files are created with owner-only access.
"""
import argparse
from collections import Counter
from datetime import datetime,timezone
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'server'))
import learning
import polish
from split_training import split


def key(text): return re.sub(r'\s+',' ',text).strip().casefold()
def digest(value): return hashlib.sha256(json.dumps(value,sort_keys=True,ensure_ascii=False).encode()).hexdigest()
def write(path,value):
    path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    path.write_text(value);path.chmod(0o600)


def prepare(database,references,destination):
    refs=json.loads(references.read_text())
    protected={key(r['asrText']) for r in refs if r['partition']=='heldout'}
    feedback=learning.dataset(database)
    candidates=[{'source':r['asrText'],'target':r['formattedText'],'origin':'wispr_reference','task':'dictation'} for r in refs if r['partition']=='development']
    candidates += feedback
    groups={};conflicts=set();skipped=Counter()
    for row in candidates:
        if row['task']!='dictation': continue
        source,target=row['source'].strip(),row['target'].strip();k=key(source)
        if not source or not target or k in protected:skipped['heldout_or_empty']+=1;continue
        if len(source.split())<4 or len(source.split())>300:skipped['length']+=1;continue
        # References are not infallible. Only conservative pairs qualify without
        # explicit user correction; user labels can correct names/recognition.
        if row['origin']=='wispr_reference' and polish.rejection_reason(source,target):skipped['reference_requires_review']+=1;continue
        if k in conflicts and row['origin']!='user_correction':skipped['conflicting_reference']+=1;continue
        current=groups.get(k)
        if current and current['target']!=target and row['origin']!='user_correction':skipped['conflicting_reference']+=1;conflicts.add(k);groups.pop(k,None);continue
        groups[k]={'source':source,'target':target,'origin':row['origin']}
    rows=[{'messages':[{'role':'system','content':polish.SYSTEM},{'role':'user','content':'<dictation>\n'+r['source']+'\n</dictation>'},{'role':'assistant','content':r['target']}]} for _,r in sorted(groups.items())]
    identity={'policy':hashlib.sha256(Path(polish.__file__).read_bytes()).hexdigest(),'pairs':list(groups.values()),'reserved_inputs':sorted(protected)}
    fingerprint=digest(identity);run=destination/fingerprint[:16];run.mkdir(parents=True,exist_ok=True,mode=0o700)
    partitions=split(rows) if len(rows)>=10 else {'train':[],'valid':[],'test':[]}
    for name,data in partitions.items():write(run/'data'/f'{name}.jsonl',''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in data))
    write(run/'meeting-feedback.json',json.dumps([r for r in feedback if r['task']!='dictation'],ensure_ascii=False,indent=2))
    write(run/'sources.json',json.dumps(list(groups.values()),ensure_ascii=False,indent=2))
    with sqlite3.connect('file:'+str(database.resolve())+'?mode=ro',uri=True) as c:
        c.row_factory=sqlite3.Row
        recent=[dict(r) for r in c.execute('SELECT id,raw,corrected,polished,edited FROM history ORDER BY id DESC LIMIT 50')]
        counts={'dictations':c.execute('SELECT count(*) FROM history').fetchone()[0],'meetings':c.execute('SELECT count(*) FROM meetings').fetchone()[0]}
    write(run/'recent.json',json.dumps(recent,ensure_ascii=False,indent=2))
    manifest={'fingerprint':fingerprint,'created':datetime.now(timezone.utc).isoformat(),'policy_sha256':identity['policy'],'reference_sha256':hashlib.sha256(references.read_bytes()).hexdigest(),'approved_feedback':len(feedback),'counts':counts,'qualifying_pairs':len(rows),'partitions':{k:len(v) for k,v in partitions.items()},'reserved_reference_inputs':len(protected),'skipped':dict(skipped),'origins':dict(Counter(r['origin'] for r in groups.values())),'status':'dataset_ready' if rows else 'waiting_for_labels','promotion':'Requires actual baseline/candidate evaluation and recorded review; never training loss alone.'}
    write(run/'manifest.json',json.dumps(manifest,indent=2));write(destination/'latest.json',json.dumps({'run':str(run),**manifest},indent=2))
    return run,manifest


def serving_policy(url):
    """The copyediting policy the live server is actually running, or None."""
    import urllib.request
    with urllib.request.urlopen(url,timeout=10) as response:
        return json.loads(response.read()).get('polish_policy_sha256')


def check_policy_drift(url,allow):
    """Refuse to prepare or train against a policy the server is not serving.

    This toolchain is a separate copy of the repository, so it can fall behind
    the serving policy silently -- and a dataset built from the old prompt, or a
    candidate trained against it, is measured against something nobody runs. The
    system prompt is part of every training row here (see `prepare`), so a stale
    policy is baked directly into the labels.
    """
    local=hashlib.sha256(Path(polish.__file__).read_bytes()).hexdigest()
    try:
        live=serving_policy(url)
    except Exception as error:  # noqa: BLE001
        if allow: print(json.dumps({'policy_drift':'unverified','error':str(error)}));return local,None
        raise SystemExit(f'Cannot reach {url} to confirm the serving policy ({error}). '
                         'Training against an unverified policy is refused; pass '
                         '--allow-policy-drift only if you have checked it by hand.')
    if live and live!=local and not allow:
        raise SystemExit(f'Policy drift: this toolchain has {local[:16]} but the server is '
                         f'serving {live[:16]}. Sync the toolchain to the serving policy '
                         'before preparing data, or pass --allow-policy-drift deliberately.')
    return local,live


def main():
    os.umask(0o077)
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--database',type=Path,required=True);p.add_argument('--references',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
    p.add_argument('--train',action='store_true');p.add_argument('--model',default='mlx-community/Qwen2.5-14B-Instruct-4bit');p.add_argument('--iterations',type=int,default=60)
    p.add_argument('--health',default=os.environ.get('VF_HEALTH_URL','http://127.0.0.1:8790/health'),
                   help='Server health endpoint used to confirm the serving copyediting policy')
    p.add_argument('--allow-policy-drift',action='store_true',dest='allow_drift',
                   help='Proceed even when the toolchain policy differs from the serving one')
    a=p.parse_args()
    local_policy,live_policy=check_policy_drift(a.health,a.allow_drift)
    run,manifest=prepare(a.database,a.references,a.out)
    manifest['serving_policy_sha256']=live_policy
    manifest['policy_matches_serving']=bool(live_policy) and live_policy==local_policy
    if a.train:
        if not 1<=a.iterations<=300:raise SystemExit('Use 1–300 iterations per bounded cycle')
        if manifest['qualifying_pairs']<30:raise SystemExit('At least 30 qualifying unique pairs are needed; retain the current model')
        adapter=run/('candidate-'+str(a.iterations)+'-response-v1');log=run/('training-'+str(a.iterations)+'-response-v1.log')
        if (adapter/'adapters.safetensors').exists():raise SystemExit('Candidate already exists; evaluate it instead of overwriting reviewed weights')
        with log.open('w') as output:
            subprocess.run([sys.executable,'-m','mlx_lm.lora','--model',a.model,'--train','--data',str(run/'data'),'--iters',str(a.iterations),'--batch-size','1','--num-layers','4','--max-seq-length','2048','--mask-prompt','--adapter-path',str(adapter),'--save-every',str(a.iterations),'--steps-per-report','10','--steps-per-eval',str(a.iterations),'--val-batches','5'],stdout=output,stderr=subprocess.STDOUT,check=True)
        manifest.update(status='candidate_trained_not_promoted',model=a.model,iterations=a.iterations,adapter=str(adapter),weights_sha256=hashlib.sha256((adapter/'adapters.safetensors').read_bytes()).hexdigest())
        write(run/'candidate.json',json.dumps(manifest,indent=2))
        write(a.out/'latest.json',json.dumps({'run':str(run),**manifest},indent=2))
    print(json.dumps({'run':str(run),**manifest}))

if __name__=='__main__':main()
