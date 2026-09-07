"""Explicit feedback, relevant personal examples and private quality diagnostics.

User corrections are labels. Ordinary model outputs and meeting transcripts are
observations, never automatically promoted to training targets.
"""
import hashlib
import json
import re
import sqlite3
from contextlib import contextmanager


@contextmanager
def connection(path):
    con=sqlite3.connect(path,timeout=10);con.row_factory=sqlite3.Row
    try:
        yield con
        con.commit()
    finally:con.close()


def initialize(path):
    with connection(path) as c:
        c.execute('''CREATE TABLE IF NOT EXISTS learning_feedback (
            task TEXT NOT NULL, record_id INTEGER NOT NULL, source TEXT NOT NULL,
            target TEXT NOT NULL, source_hash TEXT NOT NULL, origin TEXT NOT NULL,
            ts TEXT DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY(task,record_id))''')
        c.execute('''CREATE TABLE IF NOT EXISTS polish_events (
            history_id INTEGER PRIMARY KEY, status TEXT NOT NULL, rejection TEXT,
            recovery INTEGER NOT NULL, examples INTEGER NOT NULL, model TEXT,
            policy_hash TEXT, ts TEXT DEFAULT CURRENT_TIMESTAMP)''')


def save_feedback(path,task,record_id,source,target,expected=None):
    if not isinstance(task,str) or task not in {'dictation','meeting_notes','meeting_transcript'}: raise ValueError('Unknown feedback task')
    if not isinstance(record_id,int) or isinstance(record_id,bool) or record_id<1: raise ValueError('A valid recording ID is required')
    if not isinstance(target,str) or not target.strip() or len(target)>200000: raise ValueError('Correction must contain 1–200000 characters')
    with connection(path) as c:
        table='history' if task=='dictation' else 'meetings'
        row=c.execute('SELECT * FROM '+table+' WHERE id=?',(record_id,)).fetchone()
        if row is None: raise LookupError('Recording no longer exists')
        if task=='dictation':
            current=row['edited'] or row['polished'] or row['corrected'] or row['raw'] or ''
            source=row['corrected'] or row['raw'] or ''
        else:
            field='notes' if task=='meeting_notes' else 'transcript'
            previous=c.execute('SELECT target,source_hash FROM learning_feedback WHERE task=? AND record_id=?',(task,record_id)).fetchone()
            valid_previous = previous and previous['source_hash']==hashlib.sha256((row['transcript'] or '').encode()).hexdigest()
            current=previous['target'] if valid_previous else row[field] or ''
            # Notes use the transcript as source; transcript corrections also
            # preserve the original transcript as the training/evaluation input.
            source=row['transcript'] or ''
        if expected is not None and current!=expected:raise RuntimeError('This text changed since it was opened. Refresh before saving your correction.')
        if current==target.strip():return False
        c.execute('''INSERT INTO learning_feedback(task,record_id,source,target,source_hash,origin)
            VALUES(?,?,?,?,?,'user_correction') ON CONFLICT(task,record_id) DO UPDATE SET
            source=excluded.source,source_hash=excluded.source_hash,target=excluded.target,ts=CURRENT_TIMESTAMP''',(task,record_id,source,target.strip(),hashlib.sha256(source.encode()).hexdigest()))
        if task=='dictation':c.execute('UPDATE history SET edited=? WHERE id=?',(target.strip(),record_id))
    return True


def relevant_examples(path,text,limit=2):
    """Only explicit dictation edits; examples guide generation, never bypass checks.

    No held-out Wispr reference is loaded into runtime personalization.
    """
    tokens=lambda s:set(re.findall(r"[^\W_]+",s.casefold()))-set('the a an and or i you we it is are to of in that this for so'.split())
    query=tokens(text)
    if len(query)<3:return []
    with connection(path) as c:
        rows=c.execute('''SELECT f.source,f.target FROM learning_feedback f JOIN history h ON h.id=f.record_id
            WHERE f.task='dictation' AND f.origin='user_correction' ORDER BY f.ts DESC LIMIT 200''').fetchall()
    scored=[]
    for row in rows:
        if len(row['source'])>1200 or len(row['target'])>1200:continue
        terms=tokens(row['source']);intersection=query&terms
        if len(intersection)<3:continue
        # Containment in the EXAMPLE, not overlap with the union. Scoring against
        # the union made the denominator grow with the dictation, so the longer
        # you spoke the lower every score: a 250-word dictation could not reach
        # the old 0.25 floor against any short correction, and every polish call
        # in production logged examples=0. Long dictations are exactly where a
        # saved correction helps most. The minimum intersection above still keeps
        # a short unrelated example from qualifying on a few common words.
        score=len(intersection)/max(1,len(terms))
        if score>=0.5:scored.append((score,{'before':row['source'],'after':row['target']}))
    scored.sort(key=lambda item:item[0],reverse=True)
    return [item[1] for item in scored[:limit]]


def record_event(path,history_id,diagnostic,model,policy_hash):
    with connection(path) as c:
        c.execute('INSERT OR REPLACE INTO polish_events(history_id,status,rejection,recovery,examples,model,policy_hash) VALUES(?,?,?,?,?,?,?)',
                  (history_id,diagnostic['status'],diagnostic.get('rejection'),int(diagnostic.get('recovery',False)),diagnostic.get('examples',0),model,policy_hash))


def status(path):
    with connection(path) as c:
        records=c.execute('SELECT count(*) n,sum(CASE WHEN edited IS NOT NULL AND edited != "" THEN 1 ELSE 0 END) corrections FROM history').fetchone()
        feedback={r['task']:r['n'] for r in c.execute('SELECT task,count(*) n FROM learning_feedback GROUP BY task')}
        events={r['status']:r['n'] for r in c.execute('''SELECT status,count(*) n FROM
            (SELECT e.status FROM polish_events e JOIN history h ON h.id=e.history_id ORDER BY history_id DESC LIMIT 100) GROUP BY status''')}
        return {'dictations':records['n'],'corrections':records['corrections'] or 0,'feedback':feedback,'recent_polishing':events,
                'personalization':'Relevant saved corrections are used by the active dictation model.',
                'training':'Measured candidate training; stored recordings alone are not training labels.'}


def dataset(path):
    with connection(path) as c:
        rows=c.execute('''SELECT f.* FROM learning_feedback f WHERE
            (f.task='dictation' AND EXISTS(SELECT 1 FROM history h WHERE h.id=f.record_id)) OR
            (f.task!='dictation' AND EXISTS(SELECT 1 FROM meetings m WHERE m.id=f.record_id))
            ORDER BY f.task,f.record_id''').fetchall()
        # Existing correction-channel records from before this migration remain usable.
        legacy=c.execute('''SELECT id,corrected,raw,edited FROM history WHERE edited IS NOT NULL AND edited!=''
            AND NOT EXISTS(SELECT 1 FROM learning_feedback f WHERE f.task='dictation' AND f.record_id=history.id)''').fetchall()
        result=[]
        for row in rows:
            if row['task']!='dictation':
                current=c.execute('SELECT transcript FROM meetings WHERE id=?',(row['record_id'],)).fetchone()
                if hashlib.sha256((current['transcript'] or '').encode()).hexdigest()!=row['source_hash']:continue
            result.append(dict(row))
        result += [{'task':'dictation','record_id':r['id'],'source':r['corrected'] or r['raw'],'target':r['edited'],'origin':'user_correction'} for r in legacy]
        return result


def meeting_view(path,row):
    value=dict(row)
    with connection(path) as c:
        rows=c.execute("SELECT task,target,source_hash FROM learning_feedback WHERE record_id=? AND task!='dictation'",(row['id'],)).fetchall()
    original_hash=hashlib.sha256((row['transcript'] or '').encode()).hexdigest()
    for feedback in rows:
        if feedback['source_hash']==original_hash:
            value['notes' if feedback['task']=='meeting_notes' else 'transcript']=feedback['target']
    return value
