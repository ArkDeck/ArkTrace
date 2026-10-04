#!/usr/bin/env python3
"""Deterministic inputs only. Actual Swift generates every expected result."""
import json,copy,random
from pathlib import Path
ROOT=Path(__file__).resolve().parents[4];OUT=ROOT/'rust/crates/arktrace-viewer/tests/fixtures'
MAX=(1<<63)-1;MIN=-(1<<63)
def main():
 cases=[]
 texts=['','0','123456789','fn42','fn43','ipc::42','é','e\u0301','emoji 🚀 slice','𠮷🧑🏽\u200d💻','ArkTrace 时间线','٠١٢３４５','𝟘x42','a'*64,'9'*4096,'x'*4096]
 random.seed(11024)
 texts += [''.join(random.choice('abcXYZ01239é🚀汉字')for _ in range(random.randrange(1,90)))for i in range(40)]
 for i,text in enumerate(texts):
  for depth,modulus in [(0,20),(-42,20),(MAX,MAX),(31,7),(1,0),(3,-1)]:cases.append(dict(kind='hash',name=f'hash-{i}-{depth}-{modulus}',text=text,depth=depth,modulus=modulus))
 for identity in [MIN,-1234,-1,0,1,2,10,42,99,1234,MAX]:cases.append(dict(kind='identity',name=f'identity-{identity}',identity=identity))
 raws=['D-NIO','DK-NIO','D-IO','DK-IO','D','DK','R','R+','R-B','I','Running','S','T','READY','RUNNABLE','SLEEPING','BLOCKED','UNINTERRUPTIBLE','unknown','running','🚀',None,'']
 for raw in raws:
  for norm in [None,'running','runnable','sleeping','blocked','stopped']:cases.append(dict(kind='state',name=f'state-{raw}-{norm}',raw=raw,normalized=norm))
 for tag in [MIN,-1,0,1,2,3,4,7,MAX]:cases.append(dict(kind='jank',name=f'jank-{tag}',tag=tag))
 for index in [MIN,-20,-7,-6,-1,0,1,5,6,7,20,MAX]:cases.append(dict(kind='annotation',name=f'annotation-{index}',index=index))
 for index,value in enumerate([0,0xffffff,0x817e76,0x636363,0x646464,0xd85d72]):
  for alpha in [-10,0,0.125,0.32,1,2]:cases.append(dict(kind='rgba',name=f'rgba-{index}-{alpha}',red=value>>16,green=value>>8&255,blue=value&255,alpha=alpha))
 for value in [MIN,-1,*range(0,260),1000,MAX]:cases.append(dict(kind='density',name=f'density-{value}',count=value))
 for key in ['cpu:0','cpu:1','thread-state:4','thread-state:9','named-slice:unattributed','frame:all','process-counter:42:99','é','e\u0301','轨道🚀']:
  cases.append(dict(kind='track',name='track-'+key,text=key))

 sources=[dict(cpu={'_0':0}),dict(threadState={'_0':dict(itid=MAX)}),dict(namedSlice={'_0':dict(itid=MIN)}),dict(cpuCounter=dict(filterID=MAX,cpu=MIN)),dict(processCounter=dict(filterID=MIN,processKey=dict(ipid=MAX))),dict(frame={})]
 dominants=[None]+[dict(processOrThread={'_0':i})for i in [MIN,-1,0,1,42,MAX]]+[dict(name={'_0':n})for n in ['', 'fn42','fn43','é','e\u0301','🚀42']]+[dict(threadState={'_0':n})for n in raws if n is not None]+[dict(jank={'_0':tag})for tag in [MIN,-1,0,1,2,3,MAX]]
 for i,source in enumerate(sources):
  for j,dominant in enumerate(dominants):cases.append(dict(kind='densityColor',name=f'density-color-{i}-{j}',source=source,dominant=dominant))
 generic=[]
 for kind in [None,'cpuSlice','threadState','namedSlice','counter','frame']:
  for i in range(6):generic.append(dict(name=f'generic-{kind}-{i}',inspectorKind=kind,label=[None,'','fn42','Running','D-NIO','🚀42'][i],category=[None,'cpu','running','blocked','other','counter'][i],inspectorName=[None,'','fn43',None,'é',None][i],state=[None,'','S','DK-NIO','unknown',None][i],pid=[None,0,-1,MAX,42,MIN][i],tid=[None,99,-2,1,MIN,MAX][i],jankTag=[0,1,3,2,-1,MAX][i]))
 generic.append(dict(name='inspector-empty-name-blocks-label-fallback',inspectorKind='namedSlice',label='fn42',category=None,inspectorName='',state=None,pid=None,tid=None,jankTag=0))
 generic.append(dict(name='no-inspector-name-and-state-are-ignored',inspectorKind=None,label='fn42',category='other',inspectorName='fn43',state='Running',pid=42,tid=99,jankTag=3))
 # Existing fixed actual-DTO inputs are reused as input data, never their results.
 dto=json.loads((OUT/'detail-inputs.json').read_text()) if (OUT/'detail-inputs.json').exists() else json.loads((OUT/'detail-dto-inputs.json').read_text())

 original_cpu=dto[0]
 for i,pid in enumerate([None,0,-1,1,MIN,MAX]):
  for j,tid in enumerate([None,0,-1,7,MIN,MAX]):
   v=copy.deepcopy(original_cpu);v['name']=f'cpu-pid-tid-label-{i}-{j}';v['cpu']=v['cpu'][:1];e=v['cpu'][0]
   e.update(pid=pid,tid=tid,processKey=dict(ipid=MIN),threadKey=dict(itid=MAX),processName=[None,'','proc','🚀','é','e\u0301'][i],threadName=[None,'','线程','worker','fn42',' '][j]);dto.append(v)
 original_frame=dto[6]
 for kind in [0,1]:
  for flag in [None,MIN,-1,0,1,2,3,4,MAX]:
   v=copy.deepcopy(original_frame);v['name']=f'frame-kind-vsync-flag-{kind}-{flag}';v['frames']=v['frames'][:1];v['frames'][0].update(kind=kind,vsync=MIN if kind==0 else MAX,flag=flag);dto.append(v)
 (OUT/'presentation-inputs.json').write_text(json.dumps(dict(palette=cases,genericDetails=generic,dto=dto),ensure_ascii=False,indent=2)+'\n')
 print('Input cases:',len(cases),'palette,',len(generic),'generic,',len(dto),'DTO')
if __name__=='__main__':main()
