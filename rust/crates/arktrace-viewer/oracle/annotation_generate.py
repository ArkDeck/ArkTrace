#!/usr/bin/env python3
"""Deterministic inputs only; expected results come from actual Swift code."""
import json,random
from pathlib import Path
ROOT=Path(__file__).resolve().parents[4]
P=ROOT/'rust/crates/arktrace-viewer/tests/fixtures/annotation-inputs.json'
def rng(a,b):return {'startNs':a,'endNs':b}
def flag(i,t,label=None,color=0):return {'id':i,'timestampNs':t,'label':f'f{i}'if label is None else label,'colorIndex':color}
def mark(i,a,b,p=True,label=None,color=0):return {'id':i,'range':rng(a,b),'label':f'm{i}'if label is None else label,'colorIndex':color,'isPersistent':p}
def step(action,**kw):return {'action':action,**kw}
def command(name,vp=None,selection=None,event=None):return step('command',command=name,viewportRange=vp,selectedRange=selection,selectedEventRange=event)
def case(name,flags=None,marks=None,steps=None,duration=1000,anchors=None):return {'name':name,'durationNs':duration,'flags':flags or [],'marks':marks or [],'anchors':anchors or [-1,0,50,100,200,400,500,800,1000,2000],'steps':steps or []}
def main():
 cases=[]
 cases.append(case('lifecycle',steps=[
  step('addFlag',timestampNs=800),step('addFlag',timestampNs=200),step('addFlag',timestampNs=-9223372036854775808),step('addFlag',timestampNs=9223372036854775807,label=''),
  step('updateFlag',id=2,label='hotspot',colorIndex=-9223372036854775808),step('updateFlag',id=999,label='missing'),step('updateFlag',id=1),step('cycleFlagColor',id=2),
  step('addMark',isPersistent=True),step('addMark',isPersistent=False,selectedRange=rng(100,400)),step('addMark',isPersistent=False,selectedRange=rng(500,900)),
  step('addMark',isPersistent=True,selectedRange=rng(500,900)),step('addMark',isPersistent=True,selectedRange=rng(1000,1400)),step('updateMark',id=7,label='kept',colorIndex=-5),
  step('removeMark',id=6),step('removeFlag',id=2),step('removeFlag',id=999),step('removeMark',id=999),step('replaceSession'),step('addFlag',timestampNs=200),
  step('deferredRenameFlag',id=1,label='old session',capturedSessionID=1),step('deferredRenameFlag',id=1,label='current session',capturedSessionID=2),
  step('closeSession'),step('addFlag',timestampNs=5),command('createPersistent',None,rng(0,10)),step('addMark',isPersistent=False,selectedRange=rng(0,10))]))
 for selection in [None,rng(100,100),rng(100,300)]:
  for event in [None,rng(500,500),rng(500,700)]:
   for persistent in [False,True]:
    cases.append(case(f'selection-{selection}-{event}-{persistent}',steps=[step('addMark',isPersistent=persistent,selectedRange=selection,selectedEventRange=event,label=''),command('createPersistent',rng(0,800),selection,event),command('createTransient',None,selection,event)]))
 cases.append(case('duplicate-restored-ids',flags=[flag(7,400,'first'),flag(7,400,'second'),flag(-2,-5),flag(2,400),flag(8,200)],marks=[mark(7,100,200,False),mark(7,100,200,True),mark(-8,100,100)],steps=[step('updateFlag',id=7,label='edited'),step('updateMark',id=7,colorIndex=-8),step('removeFlag',id=7),step('removeMark',id=7),step('addFlag',timestampNs=33),step('addMark',isPersistent=True,selectedRange=rng(12,15))]))
 cases.append(case('negative-restored-id-cursor',flags=[flag(-7,30)],marks=[mark(-2,40,50)],steps=[step('addFlag',timestampNs=80),step('addMark',isPersistent=True,selectedRange=rng(4,7))]))
 cases.append(case('near-max-id-restored',flags=[flag(9223372036854775806,500)],steps=[step('updateFlag',id=9223372036854775806,label='near max'),command('nextFlag',rng(0,800))]))
 cases.append(case('near-max-time',duration=9223372036854775807,flags=[flag(1,9223372036854775806)],marks=[mark(2,9223372036854775800,9223372036854775807)],anchors=[0,9223372036854775800,9223372036854775806,9223372036854775807],steps=[command(c,rng(9223372036854775700,9223372036854775807))for c in ['nextFlag','previousFlag','nextMark','previousMark','nearest']]))
 for vp in [None,rng(300,500),rng(350,450),rng(0,100),rng(800,1000)]:
  cases.append(case(f'navigation-{vp}',flags=[flag(3,500),flag(5,300),flag(2,300),flag(1,400)],marks=[mark(8,700,800),mark(9,100,200,False),mark(2,100,150),mark(4,400,400)],steps=[command(c,vp,rng(5,30))for c in ['nextFlag','previousFlag','nextMark','previousMark','nearest','createPersistent','createTransient']]))
 for flags in [[],[flag(2,300)],[flag(1,500)],[flag(9,300),flag(2,500)],[flag(3,500),flag(1,300)]]:
  cases.append(case(f'nearest-tie-boundary-{flags}',flags=flags,steps=[command('nearest',vp)for vp in [rng(350,450),rng(300,500),rng(400,500),rng(300,400)]]))
 for text in ['', ' ', 'é', 'e\u0301', '😀👩🏽\u200d💻', '汉字／١２', 'x'*4096]:
  cases.append(case(f'labels-{len(text)}-{text[:4]}',steps=[step('addFlag',timestampNs=10,label=text),step('addMark',isPersistent=False,selectedRange=rng(3,5),label=text),step('updateFlag',id=1,label=text,colorIndex=9223372036854775807),step('updateMark',id=2,label=text,colorIndex=-9223372036854775808),step('cycleMarkColor',id=2)]))
 cases.append(case('closed-direct-mark-vs-command',duration=None,steps=[step('addFlag',timestampNs=5),step('addMark',isPersistent=True,selectedEventRange=rng(2,4)),command('createTransient',None,rng(3,7)),step('removeFlag',id=888)]))
 cases.append(case('cancel-retains-annotations-and-invalidates-editor',flags=[flag(1,20)],marks=[mark(2,40,50)],steps=[step('cancelSession'),step('deferredRenameFlag',id=1,label='stale',capturedSessionID=1),step('deferredRenameFlag',id=1,label='fresh',capturedSessionID=2),step('addFlag',timestampNs=25),command('nextFlag',rng(0,50))]))
 randomizer=random.Random(1102411)
 for i in range(32):
  flags=[flag(j+1,randomizer.randrange(0,1001),color=randomizer.randrange(-8,12))for j in range(randomizer.randrange(0,18))]
  marks=[mark(30+j,randomizer.randrange(0,401),randomizer.randrange(402,1001),randomizer.choice([False,True]))for j in range(randomizer.randrange(0,8))]
  steps=[]
  for _ in range(12):
   c=randomizer.choice(['nextFlag','previousFlag','nextMark','previousMark','nearest','createPersistent','createTransient'])
   start=randomizer.randrange(0,800);steps.append(command(c,rng(start,start+randomizer.randrange(1,201)),rng(100,200)))
  steps.extend([step('addFlag',timestampNs=randomizer.randrange(-100,1300)),step('removeFlag',id=1),step('updateMark',id=30,label='random renamed')])
  cases.append(case(f'random-{i}',flags=flags,marks=marks,steps=steps))
 P.parent.mkdir(parents=True,exist_ok=True);P.write_text(json.dumps({'cases':cases},ensure_ascii=False,indent=2)+'\n', encoding='utf-8');print(len(cases),'cases',sum(len(c['steps'])for c in cases),'actions')
if __name__=='__main__':main()
