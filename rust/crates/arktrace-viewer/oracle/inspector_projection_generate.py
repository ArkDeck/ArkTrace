#!/usr/bin/env python3
"""Typed DTO input vectors only; expected inspector output comes from Swift."""
import json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[4]
OUT=ROOT/'rust/crates/arktrace-viewer/tests/fixtures/inspector-projection-inputs.json'
MAX=2**63-1;MIN=-2**63
def key(table,row):return dict(table=table,rowID=row)
def rng(start,end):return dict(startNs=start,endNs=end)
def main():
 cases=[]
 def add(kind,events,query=None,**extra):cases.append(dict(id=f'{len(cases):04}-{kind}',kind=kind,queryRange=query or rng(100,500),events=events,**extra))
 def identities(i):
  return [dict(processKey=None,threadKey=None,pid=None,tid=None,processName=None,threadName=None),dict(processKey=dict(ipid=MIN),threadKey=dict(itid=MAX),pid=0,tid=0,processName='',threadName=''),dict(processKey=dict(ipid=MAX),threadKey=dict(itid=MIN),pid=MIN,tid=MAX,processName='应用🧭',threadName='线程 e\u0301')][i]
 ranges=[rng(0,0),rng(150,150),rng(50,600),rng(MAX-1,MAX),rng(0,MAX)]
 for r in ranges:
  for opened in [False,True]:
   for i in range(3):
    for priority in [None,MIN,MAX,0,120]:
     row=len(cases);add('cpuSlice',[dict(key=key('sched_slice',[MIN,MAX,row][i]),range=r,cpu=[0,MIN,MAX][i],**identities(i),endState=[None,'','Running🧭'][i],priority=priority,isOpenEnded=opened)])
 for normalized in [None,'running','runnable','sleeping','blocked','stopped']:
  for i in range(3):
   for opened in [False,True]:
    identity=identities(i);identity['threadKey']=dict(itid=[0,MIN,MAX][i]);add('threadState',[dict(key=key('thread_state',len(cases)),range=ranges[i],**identity,state=['','vendor\u0000state🧭','D-NIO'][i],normalizedState=normalized,cpu=[None,MIN,MAX][i],isOpenEnded=opened)])
 for name in ['', '范围🧭', 'é', 'e\u0301', 'a\u0000b']:
  for category in [None,'','io🧭']:
   for opened in [False,True]:
    i=len(cases)%3;add('namedSlice',[dict(key=key('callstack',len(cases)),range=ranges[i],**identities(i),name=name,category=category,depth=None,parentEventKey=None,isAsync=False,isOpenEnded=opened)])
 for kind in [0,1]:
  for flag in [None,MIN,-1,0,1,2,3,MAX]:
   for i in range(3):
    for opened in [False,True]:
     ident=identities(i);add('frame',[dict(key=key('frame_slice',len(cases)),range=ranges[i],kind=kind,vsync=[MIN,0,MAX][i],processKey=ident['processKey'],threadKey=ident['threadKey'],pid=ident['pid'],processName=ident['processName'],flag=flag,isOpenEnded=opened)])
 for scope in ['cpu','process']:
  for i in range(3):
   ident=identities(i);series=dict(filterID=[0,MIN,MAX][i],name=['','cycles🧭','é e\u0301'][i],scope=scope,cpu=[None,MIN,MAX][i]if scope=='cpu'else None,processKey=ident['processKey']if scope=='process'else None,pid=ident['pid']if scope=='process'else None,processName=ident['processName'],unit=[None,'','单位\u0000🧭'][i])
   for timestamp,duration,query in [(0,0,rng(100,500)),(150,0,rng(100,500)),(50,600,rng(100,500)),(200,None,rng(100,500)),(600,None,rng(100,500)),(MAX-1,1,rng(0,MAX)),(MAX,None,rng(0,MAX)),(0,MAX,rng(0,MAX))]:
    sample=dict(key=key('measure'if scope=='cpu'else'process_measure',len(cases)),timestampNs=timestamp,value=[MIN,0,MAX][i],durationNs=duration);add('counter',[sample],query=query,series=series)
 # Repeated equal text proves string-table interning preserves semantics; nil
 # and empty fields remain distinct. Unique keys avoid host named-slice dedup.
 repeated=[dict(key=key('callstack',i),range=rng(i,i+1),**identities(2),name='共享🧭',category='共享🧭',depth=0,parentEventKey=None,isAsync=False,isOpenEnded=False)for i in range(32)]
 add('namedSlice',repeated,query=rng(0,100));add('densityBand',[],query=rng(0,100))
 OUT.write_text(json.dumps(dict(schemaVersion=1,cases=cases),ensure_ascii=False,indent=2)+'\n',encoding='utf-8');print(len(cases),'cases',sum(len(c['events'])if c['kind']!='densityBand'else 1 for c in cases),'output positions')
if __name__=='__main__':main()
