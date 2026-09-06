#!/usr/bin/env python3
"""Compare unchanged and focused polish prompts on synthetic text, no ASR/audio.

Uses one isolated model process and the guard in the selected source checkout. Never starts
an HTTP service, writes live history or modifies production model/configuration.
"""
import argparse, hashlib, importlib.util, json, os, re, sys, tempfile, time
from pathlib import Path


def assess(case, text):
    missing = [x for x in case['required'] if x.casefold() not in text.casefold()]
    forbidden = [x for x in case['forbidden'] if re.search(r'(?<!\w)' + re.escape(x) + r'(?!\w)', text, re.I)]
    fmt = case.get('format')
    structured = True
    if fmt and fmt.startswith('list'):
        structured = len(re.findall(r'^\s*\d+[.)]\s+', text, re.M)) == int(fmt[4:])
    if fmt == 'paragraph': structured = '\n\n' in text
    tokens = lambda value: re.findall(r"[^\W_]+(?:['_-][^\W_]+)*", re.sub(r'^\s*\d+[.)]\s+', '', value, flags=re.M).casefold(), re.UNICODE)
    return {'missing':missing,'forbidden':forbidden,'format_pass':structured,'reference_tokens_match':tokens(case['reference'])==tokens(text),'invariants_pass':not missing and not forbidden}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server',type=Path,required=True)
    parser.add_argument('--cases',type=Path,required=True)
    parser.add_argument('--focused-prompt',type=Path,required=True)
    parser.add_argument('--model',required=True)
    parser.add_argument('--adapter',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--variant',choices=['baseline','focused'],action='append')
    parser.add_argument('--label',default='focused')
    args=parser.parse_args();cases=json.loads(args.cases.read_text())
    with tempfile.TemporaryDirectory(prefix='polish-data-') as scratch:
        os.environ.update(VF_DB_PATH=scratch+'/history.sqlite',VF_VOCAB_PATH=scratch+'/vocab.json',VF_SPOOL_DIR=scratch+'/spool')
        sys.path.insert(0,str(args.server.parent))
        spec=importlib.util.spec_from_file_location('quality_server',args.server);server=importlib.util.module_from_spec(spec);spec.loader.exec_module(server)
        from mlx_lm import load
        server._model,server._tok=load(args.model,adapter_path=str(args.adapter));server._prompt_model=None;server._polish_distilled=True
        baseline=server.POLISH_SYS;generator=server.generate
        report={'model':args.model,'adapter_sha256':hashlib.sha256((args.adapter/'adapters.safetensors').read_bytes()).hexdigest(),'server_sha256':hashlib.sha256(args.server.read_bytes()).hexdigest(),'corpus_sha256':hashlib.sha256(args.cases.read_bytes()).hexdigest(),'guard_sha256':hashlib.sha256((args.server.parent/'polish_guard.py').read_bytes()).hexdigest() if (args.server.parent/'polish_guard.py').exists() else None,'synthetic_text_only':True,'requires_semantic_review':True,'rows':[]}
        server._polish('Hello.') # graph warmup excluded
        for variant,prompt in [('baseline',baseline),('focused',args.focused_prompt.read_text())]:
            if args.variant and variant not in args.variant: continue
            server.POLISH_SYS=prompt
            for case in cases:
                raw=[]
                def capture(*a,**kw):
                    value=generator(*a,**kw);raw.append(value);return value
                server.generate=capture
                start=time.monotonic();text=server._polish(case['input']);elapsed=time.monotonic()-start
                report['rows'].append({'variant':args.label if variant=='focused' else variant,'id':case['id'],'input':case['input'],'output':text,'raw_output':raw[-1] if raw else '', 'guard_fallback':bool(raw) and server._polish_failed(case['input'],raw[-1].replace('<<<BEGIN>>>','').replace('<<<END>>>','').strip()),'seconds':elapsed,'prompt_sha256':hashlib.sha256(prompt.encode()).hexdigest(),**assess(case,text)})
                args.out.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
                print(variant,case['id'],round(elapsed,3),flush=True)
        for ident in ['two_questions','number_correction','instruction','arabic_english']:
            
            if not any(x['id']==ident for x in cases): continue
            case=next(x for x in cases if x['id']==ident);raw=[];start=time.monotonic();text=server._polish(case['input'])
            report['rows'].append({'variant':(args.label if variant=='focused' else variant)+'_repeat','id':ident,'input':case['input'],'output':text,'seconds':time.monotonic()-start,**assess(case,text)})
            args.out.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
        print('COMPLETE',len(report['rows']),'synthetic model evaluations',flush=True)
if __name__=='__main__':main()
