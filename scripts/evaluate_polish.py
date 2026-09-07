"""Reproducible private replay of the actual copyediting model and policy."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import time


def run(args):
    os.environ.setdefault('HF_HUB_OFFLINE','1')
    from mlx_lm import load, generate
    spec=importlib.util.spec_from_file_location('copyediting_policy',args.module)
    policy=importlib.util.module_from_spec(spec);spec.loader.exec_module(policy)
    model,tok=load(args.model,adapter_path=str(args.adapter) if args.adapter else None)
    generated=[]
    def edit(system,text):
        prompt=tok.apply_chat_template([{'role':'system','content':system},{'role':'user','content':'<dictation>\n'+text+'\n</dictation>'}],add_generation_prompt=True)
        result=generate(model,tok,prompt=prompt,max_tokens=max(400,int(len(text.split())*1.8)+200),verbose=False).replace('<dictation>','').replace('</dictation>','').strip()
        generated.append(result)
        return result
    if args.sqlite:
        # Real dictations, read-only. Sourcing from `history` also keeps the
        # model's own warm-up and keep-alive calls out of the sample: those run
        # through polishing and emit log lines, but never create a history row,
        # and counting them once diluted a 24% rejection rate down to 7%.
        import sqlite3
        with sqlite3.connect('file:'+str(args.sqlite.resolve())+'?mode=ro',uri=True) as connection:
            connection.row_factory=sqlite3.Row
            rows=[dict(r) for r in connection.execute(
                'SELECT id,raw,corrected,polished,edited FROM history '
                'WHERE length(trim(coalesce(corrected,raw,"")))>0 ORDER BY id DESC LIMIT ?',(args.pool,))]
        rows=[r for r in rows if len((r['corrected'] or r['raw'] or '').split())>=args.min_words]
    else:
        rows=json.loads(args.input.read_text())
        if isinstance(rows,dict):rows=rows['rows']
    if args.partition: rows=[r for r in rows if r.get('partition')==args.partition]
    # Stable sampling is independent of output/quality; never select winners.
    if args.limit:rows=sorted(rows,key=lambda r:hashlib.sha256(str(r.get('id',r.get('transcriptEntityId'))).encode()).hexdigest())[:args.limit]
    args.out.parent.mkdir(parents=True,exist_ok=True)
    # Hash the ids AND the input text. Ids alone identify the wrong thing: the
    # same dictation can be retranscribed later, so two arms could carry matching
    # corpus hashes while having scored different words.
    corpus=hashlib.sha256(json.dumps([[r.get('id'),r.get('corrected') or r.get('raw') or ''] for r in rows],
                                     sort_keys=True,ensure_ascii=False).encode()).hexdigest() if args.sqlite else hashlib.sha256(args.input.read_bytes()).hexdigest()
    meta={'model':args.model,'adapter':str(args.adapter) if args.adapter else None,'adapter_sha256':hashlib.sha256((args.adapter/'adapters.safetensors').read_bytes()).hexdigest() if args.adapter else None,'policy_sha256':hashlib.sha256(args.module.read_bytes()).hexdigest(),'corpus_sha256':corpus,'partition':args.partition,'cases':len(rows),'started':time.time()}
    args.out.with_suffix('.manifest.json').write_text(json.dumps(meta,indent=2))
    with args.out.open('w') as target:
        os.chmod(args.out,0o600)
        for r in rows:
            src=r.get('corrected',r.get('asrText',r.get('input','')))
            generated.clear()
            started=time.monotonic();result,diagnostics=policy.copyedit(src,edit)
            item={'id':r.get('id',r.get('transcriptEntityId')),'input':src,'output':result,'reference':r.get('formattedText',r.get('polished')),'attempts':list(generated),'seconds':round(time.monotonic()-started,3),**diagnostics}
            target.write(json.dumps(item,ensure_ascii=False)+'\n');target.flush();print(item['id'],item['status'],item['rejection'],flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--module',type=Path,required=True);p.add_argument('--model',default='mlx-community/Qwen2.5-14B-Instruct-4bit');p.add_argument('--adapter',type=Path)
    p.add_argument('--input',type=Path);p.add_argument('--sqlite',type=Path,help='Read the corpus from a history database instead of --input')
    p.add_argument('--pool',type=int,default=200,help='Most recent dictations to draw the sample from (--sqlite)')
    p.add_argument('--min-words',type=int,default=20,dest='min_words',help='Skip dictations shorter than this (--sqlite)')
    p.add_argument('--out',type=Path,required=True);p.add_argument('--partition');p.add_argument('--limit',type=int)
    if not (p.parse_known_args()[0].input or p.parse_known_args()[0].sqlite): p.error('pass --input or --sqlite')
    run(p.parse_args())
