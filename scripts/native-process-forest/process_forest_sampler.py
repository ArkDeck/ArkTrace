#!/usr/bin/env python3
"""Version 1, macOS read-only polling of identified process owners.

The sampler never launches, signals, attaches, queries argv/env, or reads target
files. Polling is incomplete. RSS peaks are lower bounds for identified live
processes with available fields, never complete forests, cancellation, or p95.
"""
import argparse
import ctypes
import errno
import json
import math
import os
from pathlib import Path
import re
import sys
import time

SCHEMA=1
RECORD_LIMIT=65536
OUTPUT_LIMIT=16777216
STATUS={0:'known',1:'not_found',2:'permission_denied',3:'unavailable',4:'identity_race',5:'not_live'}

class Failure(Exception):
    def __init__(self,code):self.code=code

def clock_check(previous,current):
    if not isinstance(current,int) or current<0 or current<previous:raise Failure('monotonic_clock_regression')
    return current

def identity(row):
    if row.get('infoStatus')!='known':return None
    p=row.get('pid');sec=row.get('startSec');usec=row.get('startUsec')
    if not all(isinstance(x,int) and not isinstance(x,bool) for x in (p,sec,usec)) or p<=0 or sec<=0 or not 0<=usec<1000000:raise Failure('malformed_identity')
    return (p,sec,usec)

def identity_object(value):
    return {'pid':value[0],'startTime':{'seconds':value[1],'microseconds':value[2]}}

class NativeRow(ctypes.Structure):
    _fields_=[(n,ctypes.c_int32) for n in ('pid','ppid','pgid','state')]+[(n,ctypes.c_uint64) for n in ('start_sec','start_usec','rss_bytes')]+[(n,ctypes.c_int32) for n in ('info_status','rss_status','info_errno','rss_errno')]

class Native:
    def __init__(self):
        if sys.platform!='darwin':raise Failure('unsupported_platform')
        try:self.lib=ctypes.CDLL(str(Path(__file__).resolve().with_name('proc_bridge.dylib')),use_errno=True)
        except OSError:raise Failure('backend_unavailable') from None
        for name in ('pf_identity','pf_observe'):
            f=getattr(self.lib,name);f.argtypes=[ctypes.c_int,ctypes.POINTER(NativeRow)];f.restype=ctypes.c_int
        self.lib.pf_list.argtypes=[ctypes.POINTER(ctypes.c_int32),ctypes.c_int];self.lib.pf_list.restype=ctypes.c_int
        self.lib.pf_abi_fact.argtypes=[ctypes.c_int];self.lib.pf_abi_fact.restype=ctypes.c_uint64
        values=[int(self.lib.pf_abi_fact(i)) for i in range(11)]
        if values[0]!=1 or values[1]!=ctypes.sizeof(NativeRow):raise Failure('backend_abi_mismatch')
        self.facts=dict(zip(('bridgeVersion','rowBytes','bsdInfoBytes','taskInfoBytes','startSecondsOffset','startMicrosecondsOffset','residentBytesOffset','bsdInfoFlavor','taskInfoFlavor','allPIDsFlavor','zombieState'),values))
        self.calls=0;self.call_ceiling=None
    def read(self,pid,rss=False):
        row=NativeRow();begin=time.monotonic_ns();cost=3 if rss else 1
        if self.call_ceiling is not None and self.calls+cost>self.call_ceiling:raise Failure('proc_query_budget_exceeded')
        self.calls+=cost
        (self.lib.pf_observe if rss else self.lib.pf_identity)(pid,ctypes.byref(row));end=time.monotonic_ns();clock_check(begin,end)
        info=STATUS.get(row.info_status);status=STATUS.get(row.rss_status)
        if info is None or status is None:raise Failure('malformed_backend_status')
        result=dict(pid=int(row.pid),ppid=int(row.ppid),pgid=int(row.pgid),state=int(row.state),startSec=int(row.start_sec),startUsec=int(row.start_usec),infoStatus=info,rssStatus=status,rssBytes=int(row.rss_bytes) if status=='known' else None,infoErrno=int(row.info_errno),rssErrno=int(row.rss_errno),observationBeginNs=begin,observationEndNs=end)
        if info=='known':identity(result)
        return result
    def list(self,capacity):
        buffer=(ctypes.c_int32*capacity)()
        if self.call_ceiling is not None and self.calls+1>self.call_ceiling:raise Failure('proc_query_budget_exceeded')
        self.calls+=1;ctypes.set_errno(0)
        size=int(self.lib.pf_list(buffer,capacity));error=ctypes.get_errno()
        if size<0:return [],['pid_enumeration_unavailable'],error
        if size>capacity*4 or size%4:raise Failure('malformed_pid_enumeration')
        return sorted(set(int(buffer[i]) for i in range(size//4) if buffer[i]>0)),(['pid_enumeration_may_be_truncated'] if size==capacity*4 else []),error

class Writer:
    def __init__(self,path,limit):
        self.limit=limit;self.used=0;self.records=0;self.closed=False
        try:self.file=open(path,'xb',buffering=0);os.chmod(path,0o600)
        except OSError:raise Failure('output_unavailable') from None
    def emit(self,record,terminal=False):
        try:data=(json.dumps(dict(schemaVersion=SCHEMA,**record),sort_keys=True,separators=(',',':'),allow_nan=False)+'\n').encode('utf-8')
        except (TypeError,ValueError):raise Failure('malformed_record') from None
        if len(data)>RECORD_LIMIT:raise Failure('record_budget_exceeded')
        ceiling=self.limit if terminal else self.limit-RECORD_LIMIT
        if self.used+len(data)>ceiling:raise Failure('output_budget_exceeded')
        try:
            n=self.file.write(data)
            if n!=len(data):raise Failure('output_write_failed')
        except OSError:raise Failure('output_write_failed') from None
        self.used+=len(data);self.records+=1
    def close(self):
        if not self.closed:self.file.close();self.closed=True

class Tracker:
    def __init__(self,root,maximum,zombie=5):
        self.root=root;self.maximum=maximum;self.zombie=zombie
        self.tracked={root[0]:dict(owner=root,initialParent=None,firstObservedNs=None,lastLiveBeginNs=None,ended=False,lastParent=None)}
    def discover(self,scan,backend,now):
        events=[];pending=sorted(scan)
        for _ in range(self.maximum):
            added=False
            for pid in pending:
                if pid in self.tracked:continue
                row=scan[pid];parent=self.tracked.get(row['ppid'])
                if parent is None:continue
                candidate=identity(row);expected=parent['owner']
                parentScan=scan.get(row['ppid'])
                if candidate is None or parentScan is None or identity(parentScan)!=expected:continue
                a=backend.read(row['ppid']);b=backend.read(pid)
                if identity(a)!=expected or identity(b)!=candidate or b['ppid']!=row['ppid']:
                    events.append(dict(type='relation_rejected',reason='parent_identity_or_relation_race',pid=pid));continue
                if len(self.tracked)>=self.maximum:raise Failure('process_budget_exceeded')
                self.tracked[pid]=dict(owner=candidate,initialParent=expected,firstObservedNs=now,lastLiveBeginNs=None,ended=False,lastParent=b['ppid'])
                events.append(dict(type='identified',owner=identity_object(candidate),parentOwner=identity_object(expected)));added=True
            if not added:break
        return events
    def observe(self,row):
        t=self.tracked[row['pid']];expected=t['owner'];got=identity(row);events=[]
        status=row['infoStatus'];live=None;rss=None
        if got is not None and got!=expected:
            status='pid_reuse_rejected';live=False
        elif got==expected:
            live=row['state']!=self.zombie
            if t['lastParent'] is not None and row['ppid']!=t['lastParent']:
                events.append(dict(type='reparented',owner=identity_object(expected),oldParentPID=t['lastParent'],newParentPID=row['ppid'],identityRetained=True))
            t['lastParent']=row['ppid']
            if live:
                if t['ended']:events.append(dict(type='reappearance',owner=identity_object(expected),priorTerminationObservationUncertain=True))
                t['ended']=False;t['lastLiveBeginNs']=row['observationBeginNs']
                rss=row['rssBytes'] if row['rssStatus']=='known' else None
            else:status='zombie_observed'
        elif status=='not_found':live=False
        if live is False and not t['ended']:
            events.append(dict(type='termination_observation',owner=identity_object(expected),reason=status,lowerMonotonicNs=t['lastLiveBeginNs'],upperMonotonicNs=row['observationEndNs'],exitCode=None,waitReaped=False,causeKnown=False))
            t['ended']=True
        item=dict(owner=identity_object(expected),parentPID=row['ppid'] if got==expected else None,processGroupID=row['pgid'] if got==expected else None,kernelState=row['state'] if got==expected else None,identityStatus=status,isLive=live,residentBytes=rss,rssStatus=row['rssStatus'],observationIntervalNs=[row['observationBeginNs'],row['observationEndNs']],trackedAfterReparent=got==expected and t['initialParent'] is not None and row['ppid']!=t['initialParent'][0])
        return item,events

def parse_markers(values,kind):
    if len(values)>16:raise Failure('marker_budget_exceeded')
    result=[]
    for value in values:
        try:label,stamp=value.rsplit(':',1);stamp=int(stamp)
        except (ValueError,AttributeError):raise Failure('invalid_marker') from None
        if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_.-]{0,31}',label) or not 0<=stamp<2**63:raise Failure('invalid_marker')
        result.append(dict(kind=kind,identifier=label,monotonicNs=stamp,source='caller_supplied_not_observed'))
    return result

class Parser(argparse.ArgumentParser):
    def error(self,message):raise Failure('invalid_arguments')

def arguments(argv):
    p=Parser(description='Read-only bounded macOS process-owner polling; output never proves a complete forest.')
    p.add_argument('--root-pid',type=int,required=True);p.add_argument('--expect-root-start',required=True,metavar='SECONDS:MICROSECONDS')
    p.add_argument('--duration-ms',type=int,required=True);p.add_argument('--interval-ms',type=int,required=True)
    p.add_argument('--max-processes',type=int,default=256);p.add_argument('--max-samples',type=int,default=10000)
    p.add_argument('--max-output-bytes',type=int,default=OUTPUT_LIMIT);p.add_argument('--list-capacity',type=int,default=8192)
    p.add_argument('--output',required=True);p.add_argument('--stage-marker',action='append',default=[]);p.add_argument('--cancel-marker',action='append',default=[])
    a=p.parse_args(argv)
    if not 0<a.root_pid<2**31 or not 100<=a.duration_ms<=300000 or not 10<=a.interval_ms<=10000 or not 1<=a.max_processes<=256 or not 1<=a.max_samples<=10000 or not 131072<=a.max_output_bytes<=OUTPUT_LIMIT or not 1<=a.list_capacity<=8192:raise Failure('invalid_limits')
    if math.ceil(a.duration_ms/a.interval_ms)>a.max_samples:raise Failure('sample_budget_inconsistent')
    try:sec,usec=map(int,a.expect_root_start.split(':'))
    except ValueError:raise Failure('invalid_root_start') from None
    if sec<=0 or not 0<=usec<1000000:raise Failure('invalid_root_start')
    a.expected=(a.root_pid,sec,usec);a.markers=sorted(parse_markers(a.stage_marker,'stage')+parse_markers(a.cancel_marker,'cancel'),key=lambda x:(x['monotonicNs'],x['kind'],x['identifier']))
    if len(a.markers)>16:raise Failure('marker_budget_exceeded')
    return a

def run(a,backend,writer):
    begin=time.monotonic_ns();end=begin+a.duration_ms*1000000;last=begin;peak=None;count=0
    root=backend.read(a.root_pid)
    if identity(root)!=a.expected:raise Failure('root_identity_mismatch_or_unavailable')
    tracker=Tracker(a.expected,a.max_processes,backend.facts['zombieState']);tracker.tracked[a.root_pid]['firstObservedNs']=begin
    writer.emit(dict(type='header',status='partial',rootOwner=identity_object(a.expected),configuration=dict(durationMs=a.duration_ms,intervalMs=a.interval_ms,maxProcesses=a.max_processes,maxSamples=a.max_samples,listCapacity=a.list_capacity,maxOutputBytes=a.max_output_bytes,recordLimitBytes=RECORD_LIMIT),api=backend.facts,scope='identified_live_set_only',pollingComplete=False,transientMissesKnown=False,RSSUnit='bytes',peakSemantics='sampled_lower_bound',stageMarkerStatus='supplied' if any(x['kind']=='stage' for x in a.markers) else 'missing',cancelMarkerStatus='supplied' if any(x['kind']=='cancel' for x in a.markers) else 'missing',samplerStartMonotonicNs=begin))
    for m in a.markers:writer.emit(dict(type='marker',**m,temporalPosition='before_sampler_start' if m['monotonicNs']<begin else 'within_configured_window' if m['monotonicNs']<=end else 'after_configured_window',verifiedActualProductEvent=False))
    while True:
        sampleBegin=time.monotonic_ns();last=clock_check(last,sampleBegin)
        if sampleBegin>=end:break
        if count>=a.max_samples:raise Failure('sample_budget_exceeded')
        callStart=backend.calls;backend.call_ceiling=callStart+1+a.list_capacity+5*a.max_processes
        pids,reasons,listError=backend.list(a.list_capacity);scan={};unavailable=0
        for pid in pids:
            row=backend.read(pid)
            if identity(row) is not None:scan[pid]=row
            else:unavailable+=1
        events=tracker.discover(scan,backend,sampleBegin);rows=[]
        for pid in sorted(tracker.tracked):
            row=backend.read(pid,True);item,new=tracker.observe(row);rows.append(item);events+=new
        sampleEnd=time.monotonic_ns();last=clock_check(last,sampleEnd)
        if sampleEnd>end:raise Failure('duration_deadline_exceeded')
        if backend.calls-callStart>1+a.list_capacity+5*a.max_processes:raise Failure('proc_query_budget_exceeded')
        rss=[x['residentBytes'] for x in rows if x['isLive'] is True and x['residentBytes'] is not None]
        unknown=sum(x['isLive'] is None or x['isLive'] is True and x['residentBytes'] is None for x in rows)
        subtotal=sum(rss) if rss or not unknown else None
        if subtotal is not None:peak=max(peak or 0,subtotal)
        partial=['polling_not_complete','unobserved_transients_possible']+reasons
        if unavailable:partial.append('candidate_identity_fields_unavailable')
        if unknown:partial.append('tracked_live_or_RSS_fields_unavailable')
        writer.emit(dict(type='sample',sampleIndex=count,status='partial',partialReasons=sorted(set(partial)),intervalMonotonicNs=[sampleBegin,sampleEnd],visiblePIDCount=len(pids),candidateIdentityUnavailableCount=unavailable,listErrno=listError,trackedCount=len(rows),identifiedKnownLiveCount=sum(x['isLive'] is True for x in rows),knownLiveRSSProcessCount=len(rss),unknownTrackedCount=unknown,identifiedKnownLiveRSSBytes=subtotal,sampledIdentifiedRSSPeakBytes=peak,procQueriesAccountedUpper=backend.calls-callStart))
        for offset in range(0,len(rows),16):writer.emit(dict(type='process_rows',sampleIndex=count,offset=offset,rows=rows[offset:offset+16]))
        for event in sorted(events,key=lambda x:(x['type'],json.dumps(x,sort_keys=True))):writer.emit(dict(sampleIndex=count,**event))
        count+=1;wake=min(end,begin+count*a.interval_ms*1000000);delay=wake-time.monotonic_ns()
        if delay>0:time.sleep(delay/1e9)
    actualEnd=time.monotonic_ns();clock_check(last,actualEnd)
    summary=dict(type='summary',status='partial',samplingCompleted=True,samples=count,trackedCount=len(tracker.tracked),sampledIdentifiedRSSPeakBytes=peak,peakSemantics='lower_bound_for_identified_live_RSS_only',intervalMonotonicNs=[begin,actualEnd],pollingComplete=False,transientMissesKnown=False,actualProductPerformanceAcceptance=False,actualProductCancelTimingVerified=False,outputBytesBeforeSummary=writer.used,outputRecordsBeforeSummary=writer.records,outputCloseOccursAfterSummary=True,stdioClosureClaimed=False)
    writer.emit(summary,True);return summary

def main(argv=None):
    writer=None
    try:
        a=arguments(sys.argv[1:] if argv is None else argv);backend=Native();writer=Writer(a.output,a.max_output_bytes);summary=run(a,backend,writer)
        print(json.dumps(dict(schemaVersion=SCHEMA,status='partial',samplingCompleted=True,samples=summary['samples'],outputBytes=writer.used,productAcceptance=False),sort_keys=True));return 0
    except Failure as e:
        result=dict(type='error',status='failed',code=e.code,productAcceptance=False)
        if writer:
            try:writer.emit(result,True)
            except Failure:pass
        print(json.dumps(dict(schemaVersion=SCHEMA,**result),sort_keys=True),file=sys.stderr);return 2
    except KeyboardInterrupt:
        print(json.dumps(dict(schemaVersion=SCHEMA,type='error',status='failed',code='sampler_interrupted',productAcceptance=False)),file=sys.stderr);return 2
    finally:
        if writer:writer.close()

if __name__=='__main__':sys.exit(main())
