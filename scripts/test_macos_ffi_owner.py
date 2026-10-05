#!/usr/bin/env python3
"""Real fixed parser, native C ABI owner lifetime and fresh Swift parity.

Historical vectors supply input only; all native results are freshly queried.
This gate does not claim an async Swift SDK, App cutover or release package.
"""
import ctypes as C
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import time
from ffi_test_support import ABI, CONTRACT, K, ROOT, TYPES
sys.path.insert(0,str(ROOT/'rust/crates/arktrace-viewer/oracle'))
from build_native_viewport_oracle import build

def digest(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def compare(a,b,path='root'):
    if isinstance(a,dict):
        assert isinstance(b,dict) and set(a)==set(b),(path,'fields',set(a),set(b))
        for k in a:compare(a[k],b[k],path+'.'+k)
    elif isinstance(a,list):
        assert isinstance(b,list) and len(a)==len(b),(path,'length')
        for i,(x,y) in enumerate(zip(a,b)):compare(x,y,f'{path}[{i}]')
    elif isinstance(a,float) or isinstance(b,float):assert struct.pack('d',a)==struct.pack('d',b),(path,a,b)
    else:assert a==b,(path,a,b)
def record(r):return {name:getattr(r,name) for name,_ in r._fields_}
def scene(view):
    strings=C.string_at(view.strings,view.string_bytes)
    def text(offset,length):
        assert offset+length<=len(strings);return strings[offset:offset+length].decode('utf8')
    tracks=[];primitives=[]
    tables={K['TABLE_'+n.upper()]:n for n in ('sched_slice','thread_state','callstack','measure','process_measure','frame_slice')}
    styles={K['STYLE_'+n.upper()]:n for n in ('accent','running','runnable','sleeping','blocked','counter')}
    for i in range(view.track_count):
        t=view.tracks[i];assert t.reserved==0 and t.primitive_start+t.primitive_count<=view.primitive_count
        owner=bool(t.flags & K['TRACK_OWNER'])
        sources={K['SOURCE_CPU']:{'cpu':{'_0':t.source_value}},K['SOURCE_THREAD_STATE']:{'threadState':{'_0':{'itid':t.source_value}}},K['SOURCE_NAMED_SLICE']:{'namedSlice':{'_0':{'itid':t.source_value}} if owner else {}},K['SOURCE_CPU_COUNTER']:{'cpuCounter':{'filterID':t.filter_id,**({'cpu':t.owner_value} if owner else {})}},K['SOURCE_PROCESS_COUNTER']:{'processCounter':{'filterID':t.filter_id,**({'processKey':{'ipid':t.owner_value}} if owner else {})}},K['SOURCE_FRAME']:{'frame':{'processKey':{'ipid':t.owner_value}} if owner else {}}}
        ps=[]
        for j in range(t.primitive_start,t.primitive_start+t.primitive_count):
            p=view.primitives[j];assert p.track_index==i and p.reserved==0 and p.reserved_header==0
            rg={'startNs':p.start_ns,'endNs':p.end_ns}
            if p.kind==K['PRIMITIVE_DETAIL']:
                value={'kind':'detail','detail':{'eventKey':{'table':tables[p.event_table],'rowID':p.row_id},'range':rg,'depth':p.depth,'style':styles[p.style],'isOpenEnded':bool(p.flags & K['FLAG_OPEN_ENDED'])}}
            else:
                assert p.kind==K['PRIMITIVE_DENSITY'];bucket={'range':rg,'eventCount':p.event_count}
                if p.flags & K['FLAG_OCCUPANCY']:bucket['occupiedNs']=p.occupied_ns
                if p.flags & K['FLAG_UTILIZATION']:bucket['utilization']=p.utilization
                if p.dominant_kind:
                    ds={K['DOMINANT_IDENTITY']:('processOrThread',p.dominant_value),K['DOMINANT_JANK']:('jank',p.dominant_value),K['DOMINANT_NAME']:('name',text(p.text_offset,p.text_length)),K['DOMINANT_THREAD_STATE']:('threadState',text(p.text_offset,p.text_length))}
                    name,val=ds[p.dominant_kind];bucket['dominant']={name:{'_0':val}}
                value={'kind':'density','bucket':bucket}
            ps.append({'input':value,'visible':bool(p.flags & K['FLAG_VISIBLE']),'frame':{n:getattr(p,n) for n in ('x','y','width','height')} if p.flags & K['FLAG_FRAME'] else None})
            primitives.append(record(p))
        tracks.append({'descriptor':{'source':sources[t.source_kind],'isCollapsed':bool(t.flags & K['TRACK_COLLAPSED']),'showsNestedDepth':bool(t.flags & K['TRACK_NESTED'])},'y':t.y,'height':t.height,'depthRowCount':t.depth_rows,'primitives':ps})
        assert text(t.id_offset,t.id_length)
    categories={K['QUALITY_'+n.upper()]:camel for n,camel in [('probe_truncated','probeTruncated'),('invalid_value','invalidValue'),('clamped_value','clampedValue'),('dropped_value','droppedValue'),('referential_integrity','referentialIntegrity'),('unavailable_value','unavailableValue')]}
    quality=[]
    for i in range(view.quality_count):
        q=view.quality[i];quality.append({'category':categories[q.category],'scope':text(q.scope_offset,q.scope_length) if q.flags & K['QUALITY_SCOPE'] else None,'count':q.count if q.flags & K['QUALITY_COUNT'] else None,'message':None})
    vp=view.viewport
    projected={'viewport':{'range':{'startNs':vp.start_ns,'endNs':vp.end_ns},'nsPerPoint':vp.ns_per_point,'widthPoints':vp.width_points,'heightPoints':vp.height_points,'verticalOffsetPoints':vp.vertical_offset_points,'generation':vp.generation},'sourceGeneration':vp.source_generation,'backingScale':vp.backing_scale,'tracks':tracks,'dataQuality':{'status':'ok' if view.quality_status==K['QUALITY_STATUS_OK'] else 'warnings','warnings':quality}}
    assert view.format_version==CONTRACT['snapshotFormatVersion']==2 and view.reserved==0
    assert view.quality_status in (K['QUALITY_STATUS_OK'],K['QUALITY_STATUS_WARNINGS'])
    return projected,{'viewport':record(vp),'tracks':[record(view.tracks[i]) for i in range(view.track_count)],'primitives':primitives,'quality':[record(view.quality[i]) for i in range(view.quality_count)],'stringsUtf8':strings.decode(),'retainedBytes':view.retained_bytes,'qualityStatus':view.quality_status}

def main():
    assert sys.platform=='darwin' and os.uname().machine=='arm64','native macOS arm64 required'
    swift,swift_receipt=build()
    def cargo(*args):return subprocess.check_output([sys.executable,str(ROOT/'scripts/run-cargo.py'),*args],cwd=ROOT,text=True)
    cargo('build','-p','arktrace-platform','--bin','arktrace-host-process')
    cargo('build','-p','arktrace-ffi','--features','process-fixtures')
    target=Path(json.loads(cargo('metadata','--format-version','1','--no-deps'))['target_directory'])/'debug'
    retained=Path(tempfile.mkdtemp(prefix='arktrace-ffi-artifacts-',dir='/private/tmp'))
    artifacts=[]
    for source,name in [(target/'libarktrace_ffi.dylib','libarktrace_ffi.dylib'),(target/'arktrace-host-process','host-process'),(swift,'swift-native-viewport-oracle')]:
        pin=digest(source);destination=retained/name;shutil.copyfile(source,destination);destination.chmod(0o500)
        assert digest(destination)==pin
        artifacts.append({'path':str(destination),'sha256':pin,'byteCount':destination.stat().st_size})
    abi=ABI(retained/'libarktrace_ffi.dylib')
    identity=abi.out('abi_identity','AbiIdentity');assert identity.capabilities==sum(K[k] for k in ('CAP_MACOS_ENGINE','CAP_COLD_JSON','CAP_VIEWPORT_RECORDS','CAP_CACHE_MAINTENANCE','CAP_VIEW_STATE','CAP_VIEW_STATE_BACKUP','CAP_SNAPSHOT_HIT','CAP_DEVELOPMENT_FIXTURES'))
    manifest=json.loads((ROOT/'ThirdParty/TraceStreamer/macx/manifest.json').read_text())
    parser=ROOT/'ThirdParty/TraceStreamer/macx/trace_streamer';assert digest(parser)==manifest['binarySHA256']
    parser_identity={k:manifest[k] for k in ('name','reportedVersion','binarySHA256','upstreamRepository','upstreamRevision','architecture','adapterVersion','buildRecipeVersion')}
    corpus=json.loads((ROOT/'docs/migration-runs/AT-RUST-001-2026-10-02-small-oracle.json').read_text())['corpus']
    vectors_source=ROOT/'docs/migration-runs/AT-RUST-011-2026-10-04-viewport-owner.json'
    previous=json.loads(vectors_source.read_text())['nativeRuntime']['sources']
    results=[]
    with tempfile.TemporaryDirectory(prefix='arktrace-ffi-空 格-',dir='/private/tmp') as directory:
        base=Path(directory);tools=base/'tools';tools.mkdir(mode=0o700)
        for source,name in [(target/'arktrace-host-process','helper'),(parser,'parser')]:shutil.copyfile(source,tools/name);(tools/name).chmod(0o500)
        def config(name):
            namespace=base/name;namespace.mkdir(mode=0o700)
            return {'abiVersion':CONTRACT['abiVersion'],'contractDigest':bytes(identity.contract_digest).hex(),'cachePolicy':'ephemeral','namespace':str(namespace),'helper':str(tools/'helper'),'parser':str(tools/'parser'),'helperSHA256':digest(tools/'helper'),'parserIdentity':parser_identity}
        def create(c):return abi.input('engine_create_fixture',c,'u64').value
        invalid=config('invalid')
        for change,code in [({'abiVersion':CONTRACT['abiVersion']+1},'STATUS_ABI_MISMATCH'),({'contractDigest':'0'*64},'STATUS_ABI_MISMATCH'),({'cachePolicy':'persistent'},'STATUS_UNSUPPORTED_OPERATION'),({'sql':'SELECT 1'},'STATUS_INVALID_INPUT')]:
            abi.input('engine_create_fixture',{**invalid,**change},'u64',expected=K[code])
        abi.input('engine_create',invalid,'u64',expected=K['STATUS_INVALID_INPUT'])
        for index,(fixture,historical) in enumerate(zip(corpus,previous)):
            source=ROOT/fixture['path'];assert digest(source)==fixture['sha256'] and source.name==historical['fixture']
            before=len(os.listdir('/dev/fd'));c=config(f'runtime-{index}');engine=create(c)
            data=str(source).encode();array=(C.c_uint8*len(data)).from_buffer_copy(data)
            ticket=abi.out('session_open','OpenTicket',engine,array,len(data),2 if source.suffix=='.systrace' else 1,60_000)
            # The worker must not retain the caller source buffer.
            C.memset(array,0,len(data));del array
            open_view,open_bytes=abi.result(engine,ticket.request)
            opened=json.loads(open_bytes);assert opened['body']['inspection']==historical['inspection']
            foreign=create(config(f'foreign-{index}'))
            abi.out('request_poll','PollStatus',foreign,ticket.request,expected=K['STATUS_INVALID_HANDLE'])
            abi.call('session_close',foreign,ticket.session,expected=K['STATUS_INVALID_HANDLE'])
            abi.call('result_release',engine,expected=K['STATUS_INVALID_HANDLE'])
            abi.call('engine_release',open_view.owner,expected=K['STATUS_INVALID_HANDLE'])
            abi.drain(foreign);abi.call('engine_release',foreign)
            abi.call('request_release',engine,ticket.request)
            abi.out('request_poll','PollStatus',engine,ticket.request,expected=K['STATUS_INVALID_HANDLE'])
            vectors=[r['input'] for r in historical['responses']]
            databases=list(Path(c['namespace']).rglob('trace.db'));assert len(databases)==1
            swift_run=subprocess.run([str(swift),str(databases[0]),json.dumps(parser_identity),json.dumps({'sha256':fixture['sha256'],'byteCount':source.stat().st_size}),json.dumps(vectors)],capture_output=True,check=True)
            assert not swift_run.stderr
            swift_records=json.loads(swift_run.stdout)
            responses=[];owners=[open_view.owner];held=[];old_request=None
            for vector,expected in zip(vectors,swift_records):
                operation={'operation':'viewport','query':{'request':vector['request'],'backingScale':vector['backingScale'],'clock':'hostContinuousEpochV1','deadline':None}} if 'request' in vector else {'operation':'resolveDensity','query':vector['resolution']}
                request=abi.submit(engine,ticket.session,operation);view,encoded=abi.result(engine,request)
                document=json.loads(encoded);assert document['formatVersion']==1 and view.kind==K['RESULT_SUCCESS']
                record_result={'input':vector,'responseUtf8':encoded.decode(),'swift':expected}
                if 'request' in vector:
                    snap=abi.out('snapshot_acquire','SnapshotView',engine,request);projection,raw=scene(snap)
                    compare(projection,document['body']['snapshot']);compare(projection,expected['projected'])
                    held.append((snap,projection));owners.append(snap.owner);record_result['records']=raw
                    if old_request is not None:
                        abi.out('result_acquire','ResultView',engine,old_request,expected=K['STATUS_CANCELLED'])
                        abi.call('request_release',engine,old_request);old_request=None
                    if vector['name']=='detail':old_request=request
                else:
                    d=document['body'];actual=None if d is None else {k:d[k] for k in ('eventKey','range','isOpenEnded')}
                    compare(actual,expected['selected'])
                owners.append(view.owner);responses.append(record_result)
                if request!=old_request:abi.call('request_release',engine,request)
            clone=abi.out('result_clone','u64',owners[-1]).value;owners.append(clone)
            assert abi.out('engine_retained_result_bytes','u64',engine).value>0
            abi.call('session_close',engine,ticket.session)
            deadline=time.monotonic()+60
            while True:
                status=abi.out('session_poll','SessionStatus',engine,ticket.session)
                if status.resources_closed:break
                assert time.monotonic()<deadline;time.sleep(.001)
            assert status.failure_present==0
            abi.call('session_release',engine,ticket.session)
            abi.out('session_poll','SessionStatus',engine,ticket.session,expected=K['STATUS_INVALID_HANDLE'])
            abi.drain(engine)
            for snap,projection in held:
                again=abi.out('snapshot_view','SnapshotView',snap.owner);compare(scene(again)[0],projection)
            again=abi.out('result_view','ResultView',open_view.owner);assert C.string_at(again.data,again.length)==open_bytes
            retained=abi.out('engine_retained_result_bytes','u64',engine).value
            # Clone and independent snapshot owners remain charged after drain.
            for owner in owners[:-1]:abi.call('result_release',owner)
            assert abi.out('engine_retained_result_bytes','u64',engine).value>0
            if index==0:
                abi.call('result_release',clone);assert abi.out('engine_retained_result_bytes','u64',engine).value==0
                abi.call('engine_release',engine)
            else:
                abi.call('engine_release',engine)
                again=abi.out('result_view','ResultView',clone);assert C.string_at(again.data,again.length).decode()==responses[-1]['responseUtf8']
                abi.call('result_release',clone)
            abi.call('result_release',clone,expected=K['STATUS_INVALID_HANDLE'])
            abi.call('engine_release',engine,expected=K['STATUS_INVALID_HANDLE'])
            after=len(os.listdir('/dev/fd'));assert before==after,(before,after)
            assert not list(Path(c['namespace']).rglob('trace.db')) and digest(source)==fixture['sha256']
            results.append({'fixture':source.name,'responses':responses,'freshSwiftResponseUtf8':swift_run.stdout.decode(),'descriptorsBefore':before,'descriptorsAfter':after,'retainedBytesAfterDrain':retained,'inputCopiedBeforeReturn':True,'foreignEngineHandlesRejected':True,'wrongHandleDomainRejected':True,'staleGenerationRejected':True,'resultAndSnapshotSurviveCloseDrain':True,'clonedResultSurvivesEngineRelease':index!=0,'lastOwnerRefundObserved':index==0,'rawBytesUnchanged':True,'ownedScopesRemoved':True})
        poisoned=create(config('panic'));healthy=create(config('healthy'))
        abi.call('fixture_panic',poisoned,expected=K['STATUS_INTERNAL'])
        p=source.as_posix().encode();buf=(C.c_uint8*len(p)).from_buffer_copy(p)
        abi.out('session_open','OpenTicket',poisoned,buf,len(p),1,60_000,expected=K['STATUS_POISONED'])
        abi.drain(poisoned);abi.call('engine_release',poisoned)
        assert abi.out('engine_drain_status','u32',healthy).value==K['DRAIN_RUNNING']
        # A failed open publishes a closed, path-free owned error result.
        missing=str(base/'private-missing.htrace').encode();buf=(C.c_uint8*len(missing)).from_buffer_copy(missing)
        ticket=abi.out('session_open','OpenTicket',healthy,buf,len(missing),1,60_000)
        failure=abi.wait(healthy,ticket.request);assert failure.state==K['REQUEST_FAILED'] and failure.failure_present==1
        failed=abi.out('result_acquire','ResultView',healthy,ticket.request);payload=C.string_at(failed.data,failed.length)
        assert failed.kind==K['RESULT_FAILURE'] and str(base).encode() not in payload
        abi.call('result_release',failed.owner);abi.call('request_release',healthy,ticket.request)
        abi.drain(healthy);assert abi.out('engine_retained_result_bytes','u64',healthy).value==0;abi.call('engine_release',healthy)
        report={'abiVersion':CONTRACT['abiVersion'],'contractSHA256':bytes(identity.contract_digest).hex(),'nativeMacOSCABI':True,'swiftSDKAcceptance':False,'windowsEngineAcceptance':False,'panicCaughtAndEngineDrained':True,'otherEngineSurvivesPanic':True,'pathFreeOwnedFailure':payload.decode(),'sources':results,'swiftOracle':swift_receipt,'inputVectorsSource':{'path':str(vectors_source.relative_to(ROOT)),'sha256':digest(vectors_source)},'parser':parser_identity,'retainedExactRunArtifacts':artifacts}
    print(json.dumps(report,ensure_ascii=False,indent=2))
if __name__=='__main__':main()
