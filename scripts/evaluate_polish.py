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
    rows=json.loads(args.input.read_text())
    if isinstance(rows,dict):rows=rows['rows']
    if args.partition: rows=[r for r in rows if r.get('partition')==args.partition]
    # Stable sampling is independent of output/quality; never select winners.
    if args.limit:rows=sorted(rows,key=lambda r:hashlib.sha256(str(r.get('id',r.get('transcriptEntityId'))).encode()).hexdigest())[:args.limit]
    args.out.parent.mkdir(parents=True,exist_ok=True)
    meta={'model':args.model,'adapter':str(args.adapter) if args.adapter else None,'adapter_sha256':hashlib.sha256((args.adapter/'adapters.safetensors').read_bytes()).hexdigest() if args.adapter else None,'policy_sha256':hashlib.sha256(args.module.read_bytes()).hexdigest(),'corpus_sha256':hashlib.sha256(args.input.read_bytes()).hexdigest(),'partition':args.partition,'cases':len(rows),'started':time.time()}
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
    p.add_argument('--input',type=Path,required=True);p.add_argument('--out',type=Path,required=True);p.add_argument('--partition');p.add_argument('--limit',type=int)
    run(p.parse_args())
