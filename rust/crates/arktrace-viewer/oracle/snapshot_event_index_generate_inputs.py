#!/usr/bin/env python3
"""Inputs only. Expected first positions come exclusively from actual Swift."""
from pathlib import Path
import json, random
root=Path(__file__).resolve().parents[4]
tables=['sched_slice','thread_state','callstack','measure','process_measure','frame_slice']
rows=[-(2**63),-19,-1,0,1,19,2**63-1]
def key(t,r): return {'table':t,'rowID':r}
def d(t,r,has=True): return {'kind':'detail','eventKey':key(t,r),'hasInspector':has}
def den(): return {'kind':'density'}
cases=[]
def add(name,tracks,queries,present=True,generation=7):
 cases.append(dict(id=name,snapshotPresent=present,generation=generation,tracks=tracks,queries=queries))
add('nil-snapshot',[],[None,key(tables[0],0)],False)
add('empty-snapshot',[],[None,key(tables[0],0)])
add('empty-tracks',[[],[],[]],[None,key(tables[0],0)])
add('density-only',[[den(),den()],[den()]],[None]+[key(t,0) for t in tables])
for t in tables:
 for r in rows:
  add(f'first-nil-{t}-{r}',[[den(),d(t,r,False),d(t,r)],[],[d(t,r)]],[key(t,r),None,key(t,r+1 if r<2**63-1 else r-1)])
add('all-tables-same-signed-row',[[d(t,-1) for t in reversed(tables)]],[key(t,-1) for t in tables])
add('original-track-order',[[den(),d(tables[2],12)],[d(tables[2],12,False)]],[key(tables[2],12)])
add('replacement-A',[[d(tables[0],1,False),d(tables[1],1)]],[key(tables[0],1),key(tables[1],1)])
add('replacement-B-same-generation',[[den(),d(tables[0],1)],[d(tables[1],1,False)]],[key(tables[0],1),key(tables[1],1)])
add('replacement-C-nil',[],[key(tables[0],1),key(tables[1],1)],False)
add('replacement-D-new-generation',[[d(tables[0],1)]],[key(tables[0],1)],generation=8)
rng=random.Random(1101320261004)
for n in range(240):
 tracks=[]
 for ti in range(rng.randrange(0,13)):
  track=[]
  for pi in range(rng.randrange(0,48)):
   track.append(den() if rng.randrange(4)==0 else d(rng.choice(tables),rng.choice(rows),bool(rng.randrange(3))))
  tracks.append(track)
 queries=[None]+[key(t,r) for t in tables for r in rows]+[key(t,1234567) for t in tables]
 rng.shuffle(queries)
 add(f'deterministic-{n:03}',tracks,queries,generation=n%3)
add('maximum-primitive-density-position',[[den() for _ in range(19999)]+[d(tables[5],-(2**63))]],[key(tables[5],-(2**63)),None])
add('maximum-track-position',[[] for _ in range(9999)]+[[den(),d(tables[4],2**63-1)]],[key(tables[4],2**63-1)])
add('maximum-detail-reverse-signed-order',[[d(tables[2],r, r%3!=0) for r in range(9999,-10001,-1)]],[key(tables[2],r) for r in [-10001,-10000,-1,0,1,9999,10000]])
p=root/'rust/crates/arktrace-viewer/tests/fixtures/snapshot-event-index-inputs.json'
p.write_text(json.dumps({'schemaVersion':1,'cases':cases},indent=2)+'\n',encoding='utf-8')
print(json.dumps({'cases':len(cases),'queries':sum(len(c['queries']) for c in cases),'primitiveFacts':sum(len(t) for c in cases for t in c['tracks'])}))
