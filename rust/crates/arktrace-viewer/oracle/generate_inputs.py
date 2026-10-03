#!/usr/bin/env python3
"""Deterministic synthetic inputs; expected results are produced only by Swift."""
import copy
import json
from pathlib import Path
import random

CRATE=Path(__file__).resolve().parent.parent
MAX=(1<<63)-1

def rg(a,b): return dict(startNs=a,endNs=b)
def source(kind="cpu",identity=0):
    if kind=="cpu": return dict(cpu={"_0":identity})
    if kind=="named": return dict(namedSlice={"_0":dict(itid=identity)})
    if kind=="frame": return dict(frame={"processKey":dict(ipid=identity)})
    if kind=="counter": return dict(processCounter=dict(filterID=identity,processKey=dict(ipid=1)))
    return dict(threadState={"_0":dict(itid=identity)})
def descriptor(kind="cpu",identity=0,collapsed=False,nested=True): return dict(source=source(kind,identity),isCollapsed=collapsed,showsNestedDepth=nested)
def viewport(start=0,end=1000,width=200,height=80,offset=0,generation=1): return dict(range=rg(start,end),widthPoints=width,heightPoints=height,verticalOffsetPoints=offset,generation=generation)
def detail(row,a,b,depth=0,style="running",table="sched_slice",opened=False):
    return dict(kind="detail",detail=dict(eventKey=dict(table=table,rowID=row),range=rg(a,b),depth=depth,style=style,isOpenEnded=opened))
def density(a,b,count=1): return dict(kind="density",bucket=dict(range=rg(a,b),eventCount=count))
def track(primitives,rows=1,y=0,height=None,kind="cpu",identity=0):
    return dict(descriptor=descriptor(kind,identity),y=y,height=6+22*rows if height is None else height,depthRowCount=rows,primitives=primitives)
def point(x,y): return dict(x=x,y=y)
def geometry(name,v=None,tracks=None):
    v=v or viewport();a=v['range']['startNs'];b=v['range']['endNs'];w=v['widthPoints'];mid=a+(b-a)//2
    return dict(name=name,viewport=v,tracks=tracks or [],backingScale=2,times=[-1,a,mid,b,MAX],xs=[-1,0,w/3,w/2,w,w+1],
        points=[point(-0.5,26),point(0,22),point(w/2,26),point(w/2,49),point(w,26),point(w+0.5,26)],
        pans=[dict(points=p,bounds=rg(0,MAX)) for p in [0,0.125,-0.125,1e200,-1e200]],
        zooms=[dict(anchorNs=mid,scale=s,bounds=rg(0,MAX)) for s in [0.01,0.5,1,2,100]],
        selections=[dict(range=rg(a+(b-a)//4,a+(b-a)*3//4),points=[point(w/4,21),point(w/4,22),point(w/2,30),point(w*3/4,30)])],resolutionTimeNs=mid)

def plans():
    def plan(name,count=4,kind="cpu",preference="automatic",budget=None,pixel=800,height=120,offset=0,counts=None,depths=None,nested=True):
        tracks=[descriptor(kind,i,nested=nested) for i in range(count)]
        return dict(name=name,request=dict(viewport=viewport(end=1000000,width=pixel/2,height=height,offset=offset),tracks=tracks,
            pixelWidth=pixel,generation=1,preference=preference,maximumPrimitives=budget,focusedEventKey=None),
            eventCounts=counts or [1000000]*count,detailDepths=depths or [[] for _ in range(count)],truncated=[False]*count)
    vectors=[plan('visible-overscan-100-lanes',100,budget=2000,height=280,offset=1120),
        plan('explicit-detail-queries-all-expanded',60,preference='detail',budget=2000,height=28),
        plan('density-prefetch-batches-65',65,kind='counter',preference='density',budget=260,height=2000,pixel=100),
        plan('fair-zero-global-3-over-4-lanes',4,preference='density',budget=3,pixel=100),
        plan('no-queried-lanes',8,height=100,offset=1000000),
        plan('default-budget-clips-explicit',2,budget=20000,pixel=1),
        plan('named-detail-depth-overflow',2,kind='named',preference='detail',budget=20,depths=[[0,1,31,32,99],[4,7]]),
        plan('named-flattening',2,kind='named',preference='detail',budget=20,depths=[[0,1,31,32,99],[4,7]],nested=False),
        plan('automatic-estimate-equals-fair-budget',2,kind='named',budget=8,counts=[4,4],depths=[[2],[3]]),
        plan('automatic-estimate-over-budget',2,kind='named',budget=8,counts=[5,4],depths=[[2],[3]]),
        plan('unused-fair-share-does-not-expand-final-lane',2,kind='named',budget=10,counts=[0,6],depths=[[],[0,1,2]]),
        plan('frame-placeholder-vs-queried-empty-rows',20,kind='frame',budget=500,height=80,offset=300)]
    vectors[0]['request']['tracks'][0]['isCollapsed']=True
    t=copy.deepcopy(vectors[6]);t['name']='named-page-truncation-and-depth-facts';t['truncated']=[True,True];t['sourceIssues']=[dict(category='probeTruncated',scope='callstack.depth',count=2,message='shared source diagnostic')];vectors.append(t)
    return vectors

def main():
    vectors=[geometry('empty-supported'),geometry('style-z-order-and-later-same-pixel',tracks=[track([
        detail(1,250,251),detail(2,250,250,style='accent'),detail(3,250,251,style='accent'),detail(4,250,500,style='blocked')])])]
    vectors[-1]['points']=[point(50,26),point(50.2,26),point(51,26),point(49,26),point(51.5,26),point(50,48),point(50,49)]
    vectors.append(geometry('inclusive-visibility-and-old-range-slivers',v=viewport(100,200),tracks=[track([
        detail(1,0,50),detail(2,50,100),detail(3,100,100),detail(4,200,200),detail(5,200,250),detail(6,201,300)])]))
    vectors.append(geometry('density-whole-track-and-adjacent-boundary',tracks=[track([density(0,500,1),density(500,1000,1000)])]))
    vectors[-1]['points']=[point(x,y) for x,y in [(0,22),(100,22),(100,49),(100,50),(199.5,49),(200,25),(201,25),(-1,25)]]
    vectors.append(geometry('depth-overflow-clamps-last-row',tracks=[track([detail(1,0,1000,99),detail(2,500,500,-1)],rows=32)]))
    vectors[-1]['points']=[point(100,25),point(100,706),point(100,729),point(100,732)]
    vectors.append(geometry('reserved-row-geometry-custom-stride',tracks=[track([detail(1,0,1000,0),detail(2,0,1000,1)],rows=2,height=40)]))
    vectors.append(geometry('near-max-local-integer-subtraction',v=viewport(MAX-1000,MAX),tracks=[track([detail(1,MAX-900,MAX-800),detail(2,MAX-501,MAX-501,opened=True),density(MAX-700,MAX,2)])]))
    vectors.append(geometry('full-int64-range-floor-inverse',v=viewport(0,MAX,width=101),tracks=[track([detail(1,0,MAX,opened=True)])]))
    vectors.append(geometry('one-nanosecond-viewport',v=viewport(100,101,width=0.25,height=1),tracks=[track([detail(1,100,100),detail(2,100,101,opened=True)])]))
    vectors.append(geometry('high-dpi-minimum-width',tracks=[track([detail(1,500,500),detail(2,500,500,opened=True)])]));vectors[-1]['backingScale']=4
    vectors.append(geometry('subunit-dpi-is-clamped-to-one',tracks=[track([detail(1,500,500)])]));vectors[-1]['backingScale']=0.5
    vectors.append(geometry('multiple-tracks-layout-and-y-boundaries',tracks=[track([detail(1,0,1000)],y=0),track([detail(2,0,1000,style='accent')],y=28,identity=1)]))
    vectors[-1]['points']=[point(100,y) for y in [21.999,22,25,47,49.999,50,53,75,78]]
    narrow=geometry('selection-closed-midpoint-and-outward-targets')
    narrow['selections']=[dict(range=rg(500,510),points=[point(x,30) for x in [77,77.5,78,101,101.5,102,125,125.5,126]]),
        dict(range=rg(100,220),points=[point(x,30) for x in [8,20,32,44,56]])];vectors.append(narrow)
    seed=random.Random(11011)
    for i in range(12):
        start=seed.randrange(0,10**15);end=start+seed.randrange(1,100000);width=seed.choice([0.25,99.5,350,2048.125]);rows=seed.randrange(1,33)
        primitives=[]
        for r in range(40):
            a=seed.randrange(start,max(start+1,end));b=seed.randrange(a,end+1)
            primitives.append(detail(r+1,a,b,seed.randrange(-3,100),seed.choice(['running','runnable','blocked','sleeping','counter','accent']),opened=r%11==0))
        g=geometry(f'seed-11011-{i}',v=viewport(start,end,width),tracks=[track(primitives,rows=rows)])
        g['points']=[point(seed.random()*width,25+seed.randrange(rows)*22) for _ in range(15)];vectors.append(g)
    (CRATE/'tests/fixtures/geometry-inputs.json').write_text(json.dumps(vectors,indent=2)+'\n')
    (CRATE/'tests/fixtures/plan-inputs.json').write_text(json.dumps(plans(),indent=2)+'\n')
    print(f'Generated {len(vectors)} geometry and {len(plans())} loader inputs, no expected formulas')

if __name__=='__main__':main()
