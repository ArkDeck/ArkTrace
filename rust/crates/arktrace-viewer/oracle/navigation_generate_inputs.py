#!/usr/bin/env python3
"""Synthetic bounded facts; outputs are obtained by executing Swift, never here."""
import json
from pathlib import Path

CRATE = Path(__file__).resolve().parents[1]

def thread(key, owner=None, tid=7, name="worker", process_name=None, pid=None):
    return dict(key=key, processKey=owner, tid=tid, pid=pid, name=name,
                processName=process_name, startNs=None, endNs=None, isMainThread=None)

def counter(key, scope="process", owner=None, cpu=None, name="count", unit=None, process_name=None, pid=None):
    item = dict(filterID=key, name=name, scope=scope)
    for k,v in dict(processKey=None if owner is None else dict(ipid=owner), cpu=cpu,
                    unit=unit, processName=process_name, pid=pid).items():
        if v is not None: item[k] = v
    return item

def facts(threads=(), counters=(), samples=(), frames=(), duration=1000, enabled=True, truncated=False):
    return dict(durationNs=duration, capabilities=dict(cpuScheduling=enabled, threadStates=enabled,
                namedSlices=enabled, cpuCounters=enabled, processCounters=enabled), threads=list(threads),
                threadsTruncated=truncated, cpuSamples=list(samples), cpuTruncated=truncated,
                counters=list(counters), countersTruncated=truncated,
                frameProcessKeys=[dict(ipid=p) for p in frames])

def sample(cpu, owner=None): return dict(cpu=cpu, processKey=None if owner is None else dict(ipid=owner))
def result(kind, title, owner=None, thread_key=None, event=None, time=None):
    r = dict(kind=kind,title=title)
    for k,v in dict(processKey=None if owner is None else dict(ipid=owner),
                    threadKey=None if thread_key is None else dict(itid=thread_key), eventKey=event,range=time).items():
        if v is not None: r[k]=v
    return r
def action(kind, **kwargs): return dict(kind=kind, **kwargs)

def main():
    key = dict(table="callstack",rowID=9223372036854775806)
    queries = ["", " \n\t", "renderer", "  Renderer  ", "[42]", "42", "worker",
               "CPUs", "cpu COUNTERS", "unattributed", "StraSSE", "é", "e\u0301",
               "e", "s", "İ", "i", "Σ", "ffi", "f", "👩", "👩‍💻", "\u200bRenderer\u200b"]
    mixed = facts([thread(100,1,8,"worker","Renderer",42),thread(101,1,7,"","Renderer",42),
                   thread(200,2,7,"worker","Renderer",42),thread(201,2,7,None,"Renderer",42),
                   thread(999,None,3,None,None,None)],
                  [counter(22,owner=1,name="cycles",unit="ns"),counter(3,owner=1),
                   counter(3,owner=1,name="ignored duplicate"),counter(8,scope="cpu",cpu=0),
                   counter(1,scope="cpu"),counter(0),counter(4,owner=77,process_name="",pid=42)],
                  [sample(9,2),sample(0,2),sample(9,1),sample(1,None)], [1,2,88],truncated=True)
    actions = [action("toggleTrackDepth",id="named-slice:100"),action("toggleTrack",id="named-slice:100"),
               action("toggleFavorite",id="named-slice:100"),action("toggleFavorite",id="missing"),
               action("toggleFavorite",id="thread-state:200"),action("moveFavorite",source=2,destination=0),
               action("moveFavorite",source=0,destination=3),action("moveFavorite",source=-1,destination=1),
               action("toggleFavorite",id="missing"),action("toggleFavorite",id="named-slice:100"),
               action("setSearchResults",items=[result("process","Renderer",owner=2),result("thread","not in directory",thread_key=888),
               result("slice","work",thread_key=100,event=key,time=dict(startNs=200,endNs=200)),
               result("slice","unowned",event=dict(table="callstack",rowID=3),time=dict(startNs=950,endNs=1000))]),
               action("selectSearchResult",index=-1),action("activateSearchResult"),action("stepSearchResult",delta=0),
               action("stepSearchResult",delta=1),action("stepSearchResult",delta=1),action("stepSearchResult",delta=1),
               action("activateSearchResult"),action("stepSearchResult",delta=1),action("stepSearchResult",delta=1),
               action("stepSearchResult",delta=-3),action("selectSearchResult",index=50),
               action("revealSliceAggregate",name="aggregate",firstThreadKey=dict(itid=999),firstEventKey=key,firstRange=dict(startNs=0,endNs=50)),
               action("revealSearchResult",result=result("process","no owner")),
               action("revealSearchResult",result=result("thread","no thread")),
               action("revealRange",range=dict(startNs=1000,endNs=1000)),
               action("revealTrackGroup",id="process:1"),action("revealTrackGroup",id="does not exist")]
    search_set = next(a for a in actions if a["kind"] == "setSearchResults")
    search_set["truncated"] = False
    actions += [action("setSearchResults",items=search_set["items"],truncated=False),action("selectSearchResult",index=2),action("setSearchResults",items=search_set["items"],truncated=False),action("setSearchResults",items=search_set["items"],truncated=True)]
    many = facts([thread(i+1000,i,7,"worker",f"P{i}",7) for i in range(12)],
                 [counter(i,scope="cpu",cpu=i) for i in range(19,-1,-1)],
                 [sample(i) for i in range(20)])
    favorite_actions = [action("toggleFavorite",id=f"thread-state:{1000+i}") for i in range(12)]
    favorite_actions += [action("toggleFavorite",id="named-slice:1000"),action("moveFavorite",source=11,destination=0),
                        action("toggleFavorite",id="thread-state:1000"),action("toggleFavorite",id="named-slice:1000"),
                        action("toggleTrackDepth",id="named-slice:1008"),action("revealTrackGroup",id="process:8"),
                        action("revealTrackGroup",id="process:8")]
    unicode = facts([thread(1,1,1,"","Straße",1),thread(2,2,1,"worker","É",2),
                     thread(3,3,1,"worker","İ",3),thread(4,4,1,"worker","Σςσ",4),
                     thread(5,5,1,"worker","ﬃ",5),thread(6,6,1,"worker","👩‍💻",6)])
    cases = [dict(name="mixed-reused-identity-and-actions",facts=mixed,actions=actions,filters=queries),
             dict(name="process-cpu-and-counter-caps",facts=many,actions=favorite_actions,filters=queries),
             dict(name="unicode-visible-title-filter",facts=unicode,actions=[],filters=queries),
             dict(name="empty-positive-duration",facts=facts(),actions=[action("revealSearchResult",result=result("slice","unowned"))],filters=queries),
             dict(name="empty-zero-duration",facts=facts(duration=0),actions=[],filters=queries),
             dict(name="all-unsupported",facts=facts(enabled=False),actions=[action("revealSearchResult",result=result("thread","unknown",thread_key=88))],filters=queries),
             dict(name="missing-process-group-admission",facts=facts([thread(11,5,3,None,"owner",99)],enabled=False),actions=[action("admitTrack",track=dict(title="admitted",descriptor=dict(source={"namedSlice":{"_0":{"itid":11}}},isCollapsed=False,showsNestedDepth=False)))],filters=queries),
             dict(name="large-int64-valid-padding",facts=facts(duration=9223372036854775807),actions=[action("revealRange",range=dict(startNs=9223372036854775797,endNs=9223372036854775807))],filters=[])]
    (CRATE / "tests/fixtures/navigation-inputs.json").write_text(json.dumps(cases,ensure_ascii=False,indent=2)+"\n")
    def event(table, row_id, time, open_ended=False): return dict(key=dict(table=table,rowID=row_id),range=dict(startNs=time,endNs=time),isOpenEnded=open_ended)
    lanes = [dict(trackID="cpu:0",events=[event("sched_slice",99,100,True),event("callstack",80,100),event("frame_slice",1,100)]),dict(trackID="cpu:1",events=[]),dict(trackID="cpu:2",events=[event("thread_state",40,90),event("callstack",80,100),event("callstack",5,110)])]
    rendering = []
    for name, focus, selected in [("none",None,None),("focused",dict(trackID="cpu:0",key=dict(table="frame_slice",rowID=1)),None),("selected",None,dict(table="sched_slice",rowID=99)),("duplicate-key-hint",dict(trackID="cpu:2",key=dict(table="callstack",rowID=80)),None),("unknown-key",dict(trackID="cpu:2",key=dict(table="callstack",rowID=999)),None)]:
        for command in ["event","track"]:
            for delta in [-3,-1,0,1,3]:
                rendering.append(dict(name=f"{name}-{command}-{delta}",lanes=lanes,focused=focus,selected=selected,viewport=dict(startNs=0,endNs=1000),command=command,delta=delta))
    for command in ["event","track"]: rendering.append(dict(name=f"empty-{command}",lanes=[],focused=None,selected=None,viewport=dict(startNs=0,endNs=1000),command=command,delta=1))
    for uses_pointer in [False,True]:
        for selection in [None,dict(startNs=200,endNs=300)]:
            for pointer in [None,80,400]:
                rendering.append(dict(name=f"anchor-{uses_pointer}-{selection}-{pointer}",lanes=lanes,focused=dict(trackID="cpu:0",key=dict(table="sched_slice",rowID=99)),selected=None,viewport=dict(startNs=0,endNs=1000),command="anchor",delta=0,usesPointer=uses_pointer,selection=selection,pointerX=pointer))
    (CRATE / "tests/fixtures/navigation-rendering-inputs.json").write_text(json.dumps(rendering,indent=2)+"\n")
    restored_ids = ["unknown","thread-state:1008","cpu:0","thread-state:1008"]
    restore_cases = [dict(name="restore-known-unknown-and-duplicate",facts=many,ids=restored_ids),dict(name="restore-more-than-twelve",facts=many,ids=[f"thread-state:{1000+i}" for i in range(12)]+["cpu:0"]),dict(name="restore-directory-removed-identity",facts=facts([thread(1001,1,7,"renamed","reused",7)]),ids=["thread-state:1000","thread-state:1001"])]
    (CRATE / "tests/fixtures/navigation-restore-inputs.json").write_text(json.dumps(restore_cases,ensure_ascii=False,indent=2)+"\n")

if __name__ == "__main__": main()
