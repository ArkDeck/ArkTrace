#!/usr/bin/env python3
"""Actual Swift Controller. Only cache source gets access/logging seams."""
import difflib, hashlib, json, os, shutil, subprocess, sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[4]; CRATE=ROOT/'rust/crates/arktrace-viewer'
cache=Path(os.environ['ARKTRACE_SWIFTPM_CACHE_ROOT']).resolve()
assert cache.is_absolute() and not cache.is_relative_to(ROOT)
source=cache/'snapshot-event-index-oracle-source'; source.mkdir(parents=True,exist_ok=True)
for directory in ('Sources','Tests','scripts','ThirdParty','Fixtures','Apps'):
 shutil.copytree(ROOT/directory,source/directory,dirs_exist_ok=True,ignore=shutil.ignore_patterns('__pycache__','trace_streamer'))
for path in ROOT.iterdir():
 if path.is_file() and not path.is_symlink(): shutil.copyfile(path,source/path.name)
controller='Sources/ArkTraceAppSupport/TraceDocumentController.swift'
original=(ROOT/controller).read_text(encoding='utf-8')
property_line='    public private(set) var snapshot: TimelineSnapshot?'
assert original.count(property_line)==1
patched=original.replace(property_line,property_line+'\n    package var snapshotEventIndexOraclePosition: [Int]?')
old="""    private func inspector(for key: EventKey) -> TraceEventInspector? {
        for track in snapshot?.tracks ?? [] {
            for primitive in track.primitives {
                if case .detail(let detail) = primitive, detail.eventKey == key {
                    return detail.inspector
                }
            }
        }
        return nil
    }"""
new="""    private func inspector(for key: EventKey) -> TraceEventInspector? {
        snapshotEventIndexOraclePosition = nil
        for (trackIndex, track) in (snapshot?.tracks ?? []).enumerated() {
            for (primitiveIndex, primitive) in track.primitives.enumerated() {
                if case .detail(let detail) = primitive, detail.eventKey == key {
                    snapshotEventIndexOraclePosition = [trackIndex, primitiveIndex]
                    return detail.inspector
                }
            }
        }
        return nil
    }"""
assert patched.count(old)==1
patched=patched.replace(old,new)
seam=CRATE/'oracle/snapshot_event_index_controller_seam.swift'
patched+='\n'+seam.read_text(encoding='utf-8')
(source/controller).write_text(patched,encoding='utf-8')
(CRATE/'oracle/snapshot_event_index_swift_logging.patch').write_text(''.join(difflib.unified_diff(original.splitlines(True),patched.splitlines(True),fromfile=controller,tofile='cache-only/'+controller)),encoding='utf-8')
harness=CRATE/'oracle/snapshot_event_index_harness.swift'
shutil.copyfile(harness,source/'Tests/ArkTraceAppSupportTests/SnapshotEventIndexCanonicalOracleTests.swift')
env=os.environ.copy(); env.pop('GIT_DIR',None); env.pop('GIT_WORK_TREE',None)
subprocess.run(['git','init','--quiet'],cwd=source,env=env,check=True)
inputs=CRATE/'tests/fixtures/snapshot-event-index-inputs.json'; output=CRATE/'tests/fixtures/snapshot-event-index-swift-oracle.json'
env.update(ARKTRACE_SNAPSHOT_EVENT_INDEX_INPUT=str(inputs),ARKTRACE_SNAPSHOT_EVENT_INDEX_OUTPUT=str(output))
filter_name='SnapshotEventIndexCanonicalOracleTests' if len(sys.argv)<2 else sys.argv[1]
label='canonical' if filter_name=='SnapshotEventIndexCanonicalOracleTests' else 'regressions'
cmd=['sh','scripts/run-swiftpm.sh','test','--disable-sandbox','--config-path',str(cache/'configuration'),'--security-path',str(cache/'security'),'--filter',filter_name]
log=CRATE/f'tests/fixtures/snapshot-event-index-swift-{label}.log'
with log.open('w',encoding='utf-8') as out: run=subprocess.run(cmd,cwd=source,env=env,stdout=out,stderr=subprocess.STDOUT)
def receipt(p):
 data=p.read_bytes(); return dict(path=str(p),sha256=hashlib.sha256(data).hexdigest(),byteCount=len(data))
result=dict(command=cmd,cwd=str(source),exitCode=run.returncode,canonicalSource=receipt(ROOT/controller),patchedSource=receipt(source/controller),loggingPatch=receipt(CRATE/'oracle/snapshot_event_index_swift_logging.patch'),seam=receipt(seam),harness=receipt(harness),input=receipt(inputs),log=receipt(log),sourcePins=[receipt(ROOT/p) for p in ('Sources/ArkTraceCore/Model/TraceIdentity.swift','Sources/ArkTraceCore/Model/TraceViewerModels.swift','Sources/ArkTraceRendering/TimelineModels.swift')],note='Original Controller.inspector equality/return, hoverEvent and selectEvent execute. Enumerated loops and matched-position assignment record the existing first-return branch, including nil Inspector. No copied scan generates expected output. Cache injection only; production source unchanged.')
if run.returncode==0 and output.exists(): result['output']=receipt(output)
(CRATE/f'tests/fixtures/snapshot-event-index-swift-{label}-receipt.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
print(json.dumps(dict(exitCode=run.returncode,log=str(log))))
if run.returncode: print(log.read_text(encoding='utf-8')[-6500:])
sys.exit(run.returncode)
