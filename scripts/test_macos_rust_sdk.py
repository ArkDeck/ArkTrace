#!/usr/bin/env python3
"""Compile a package-external async SDK consumer and run fresh native parity."""
import ctypes as C
import select
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import re
from stage_macos_rust_sdk import verified_receipt
from test_macos_ffi_owner import compare, scene
from ffi_test_support import TYPES
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT/'rust/crates/arktrace-viewer/oracle'))
from build_native_viewport_oracle import build as build_oracle

def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def identity(path):return {'byteCount':Path(path).stat().st_size,'sha256':sha(path)}
def cargo(*args):return subprocess.check_output([sys.executable,str(ROOT/'scripts/run-cargo.py'),*args],cwd=ROOT,text=True)
def consumer(artifact):
    receipt,identity=verified_receipt(artifact,True)
    cache=Path(os.environ.get('ARKTRACE_RUST_SDK_CONSUMER_CACHE_ROOT','/private/tmp/arktrace-rust-sdk-consumer'))
    assert cache.is_absolute() and not cache.resolve().is_relative_to(ROOT)
    package=cache/'consumer';sources=package/'Sources/Consumer';sources.mkdir(parents=True,exist_ok=True)
    for p in (ROOT/'scripts/swift-sdk-conformance').glob('*.swift'):shutil.copyfile(p,sources/p.name)
    lifecycle_sources=package/'Sources/Lifecycle';lifecycle_sources.mkdir(parents=True,exist_ok=True)
    shutil.copyfile(ROOT/'scripts/swift-sdk-lifecycle/Lifecycle.swift',lifecycle_sources/'Lifecycle.swift')
    shutil.copyfile(ROOT/'scripts/swift-sdk-conformance/GeneratedRecords.swift',lifecycle_sources/'GeneratedRecords.swift')
    directory_sources=package/'Sources/DirectoryOwnership';directory_sources.mkdir(parents=True,exist_ok=True)
    shutil.copyfile(ROOT/'scripts/swift-sdk-directory/DirectoryOwnership.swift',directory_sources/'DirectoryOwnership.swift')
    summary_sources=package/'Sources/SummaryOwnership';summary_sources.mkdir(parents=True,exist_ok=True)
    shutil.copyfile(ROOT/'scripts/swift-sdk-summary/SummaryOwnership.swift',summary_sources/'SummaryOwnership.swift')
    sidecar_sources=package/'Sources/ViewState';sidecar_sources.mkdir(parents=True,exist_ok=True)
    shutil.copyfile(ROOT/'scripts/swift-sdk-view-state/ViewState.swift',sidecar_sources/'ViewState.swift')
    migration_sources=package/'Sources/ViewStateMigration';migration_sources.mkdir(parents=True,exist_ok=True)
    shutil.copyfile(ROOT/'scripts/swift-sdk-view-state-migration/Migration.swift',migration_sources/'Migration.swift')
    mirror=cache/'arktrace/workspace'
    env=os.environ.copy();env.update(ARKTRACE_SWIFTPM_CACHE_ROOT=str(cache/'arktrace'),ARKTRACE_RUST_XCFRAMEWORK=str(artifact),ARKTRACE_RUST_SDK_FIXTURES='1')
    log=cache/'sdk-build.log'
    with log.open('w') as output:
        subprocess.run(['sh','scripts/run-swiftpm.sh','build','--disable-sandbox','--config-path',str(cache/'configuration'),'--security-path',str(cache/'security'),'--target','ArkTraceRustRuntime','-Xswiftc','-warnings-as-errors'],cwd=ROOT,env=env,stdout=output,stderr=subprocess.STDOUT,check=True)
    assert not re.search(r'warning:|error:',log.read_text(encoding='utf-8')),log.read_text(encoding='utf-8')[-6000:]
    unit_log=cache/'sdk-unit-tests.log'
    with unit_log.open('w') as output:
        subprocess.run(['sh','scripts/run-swiftpm.sh','test','--disable-sandbox','--config-path',str(cache/'configuration'),'--security-path',str(cache/'security'),'--filter','ArkTraceRustRuntimeTests','-Xswiftc','-warnings-as-errors'],cwd=ROOT,env=env,stdout=output,stderr=subprocess.STDOUT,check=True)
    unit_output=unit_log.read_text(encoding='utf-8')
    unit_tests=re.findall(r"Test Case '.*ArkTraceRustRuntimeTests.*' passed",unit_output)
    assert len(unit_tests)==94 and not re.search(r'warning:|error:|Test Case .*skipped',unit_output),unit_output[-6000:]
    core_log=cache/'core-consumer-build.log'
    with core_log.open('w') as output:
        subprocess.run(['sh','scripts/run-swiftpm.sh','build','--product','ArkTraceRustCoreConformance','--disable-sandbox',
            '--config-path',str(cache/'configuration'),'--security-path',str(cache/'security'),'-Xswiftc','-warnings-as-errors'],
            cwd=ROOT,env=env,stdout=output,stderr=subprocess.STDOUT,check=True)
    assert not re.search(r'warning:|error:',core_log.read_text(encoding='utf-8'))
    relative='.arktrace-native/'+identity+'/CArkTrace.xcframework'
    env.update(ARKTRACE_RUST_XCFRAMEWORK=relative,CLANG_MODULE_CACHE_PATH=str(cache/'ModuleCache'),SWIFTPM_MODULECACHE_OVERRIDE=str(cache/'ModuleCache'))
    # Consume the complete actual root package, never a copied SDK source target.
    (package/'Package.swift').write_text('''// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "ArkTraceSDKConsumer", platforms: [.macOS(.v26)], dependencies: [.package(name: "ArkTrace", path: %s)], targets: [
 .executableTarget(name: "Consumer", dependencies: [.product(name: "ArkTraceRustRuntime", package: "ArkTrace"), .product(name: "ArkTraceCore", package: "ArkTrace")], swiftSettings: [.strictMemorySafety()]),
 .executableTarget(name: "Lifecycle", dependencies: [.product(name: "ArkTraceRustRuntime", package: "ArkTrace"), .product(name: "ArkTraceCore", package: "ArkTrace")], swiftSettings: [.strictMemorySafety()]),
 .executableTarget(name: "DirectoryOwnership", dependencies: [.product(name: "ArkTraceRustRuntime", package: "ArkTrace"), .product(name: "ArkTraceCore", package: "ArkTrace")], swiftSettings: [.strictMemorySafety(), .unsafeFlags(["-parse-as-library"])]),
 .executableTarget(name: "SummaryOwnership", dependencies: [.product(name: "ArkTraceRustRuntime", package: "ArkTrace"), .product(name: "ArkTraceCore", package: "ArkTrace")], swiftSettings: [.strictMemorySafety(), .unsafeFlags(["-parse-as-library"])]),
 .executableTarget(name: "ViewState", dependencies: [.product(name: "ArkTraceRustRuntime", package: "ArkTrace"), .product(name: "ArkTraceCore", package: "ArkTrace")], swiftSettings: [.strictMemorySafety(), .unsafeFlags(["-parse-as-library"])]),
 .executableTarget(name: "ViewStateMigration", dependencies: [.product(name: "ArkTraceRustRuntime", package: "ArkTrace"), .product(name: "ArkTraceCore", package: "ArkTrace")], swiftSettings: [.strictMemorySafety(), .unsafeFlags(["-parse-as-library"])])
], swiftLanguageModes: [.v6])
''' % json.dumps(str(mirror)))
    invocation=['swift','build','--package-path',str(package),'--scratch-path',str(cache/'build'),'--cache-path',str(cache/'dependencies'),'--disable-sandbox','--config-path',str(cache/'configuration'),'--security-path',str(cache/'security'),'-Xswiftc','-warnings-as-errors']
    with (cache/'consumer-build.log').open('w') as output:
        subprocess.run(invocation,env=env,stdout=output,stderr=subprocess.STDOUT,check=True)
    assert not re.search(r'warning:|error:',(cache/'consumer-build.log').read_text(encoding='utf-8'))
    rejected=[]
    for case in sorted((ROOT/'scripts/swift-sdk-conformance').glob('*.invalid')):
        invalid=sources/'Invalid.swift';invalid.write_bytes(case.read_bytes())
        try:
            with (cache/(case.name+'.log')).open('w') as output:
                failed=subprocess.run(invocation,env=env,stdout=output,stderr=subprocess.STDOUT)
            diagnostic=(cache/(case.name+'.log')).read_text(encoding='utf-8')
            assert failed.returncode!=0 and (('lifetime-dependent' in diagnostic and 'escapes its scope' in diagnostic) or ('Span' in diagnostic and 'Escapable' in diagnostic)),diagnostic[-6000:]
            rejected.append({'case':case.name,'exitCode':failed.returncode,'logSHA256':sha(cache/(case.name+'.log'))})
        finally:invalid.unlink()
    executable=cache/'build/out/Products/Debug/Consumer'
    lifecycle=cache/'build/out/Products/Debug/Lifecycle'
    directory=cache/'build/out/Products/Debug/DirectoryOwnership'
    summary=cache/'build/out/Products/Debug/SummaryOwnership'
    core=cache/'arktrace/build/out/Products/Debug/ArkTraceRustCoreConformance'
    sidecar=cache/'build/out/Products/Debug/ViewState'
    migration=cache/'build/out/Products/Debug/ViewStateMigration'
    return executable,{'artifactIdentity':identity,'artifactReceipt':receipt,'consumerExecutable':{'byteCount':executable.stat().st_size,'sha256':sha(executable)},'lifecycleExecutable':{'byteCount':lifecycle.stat().st_size,'sha256':sha(lifecycle)},'directoryExecutable':{'byteCount':directory.stat().st_size,'sha256':sha(directory)},'summaryExecutable':{'byteCount':summary.stat().st_size,'sha256':sha(summary)},'coreExecutable':{'byteCount':core.stat().st_size,'sha256':sha(core)},'viewStateExecutable':{'byteCount':sidecar.stat().st_size,'sha256':sha(sidecar)},'viewStateMigrationExecutable':{'byteCount':migration.stat().st_size,'sha256':sha(migration)},'coreConsumerBuildLogSHA256':sha(core_log),'sdkBuildLogSHA256':sha(log),'consumerBuildLogSHA256':sha(cache/'consumer-build.log'),'sdkUnitTests':{'passed':len(unit_tests),'failed':0,'skipped':0,'logSHA256':sha(unit_log)},'borrowCompileRejections':rejected}

def projection(records):
    def array(name, values):
        result=(TYPES[name]*len(values))()
        for i,fields in enumerate(values):
            for key,value in fields.items():setattr(result[i],key,value)
        return result
    tracks=array('TrackRecord',records['tracks']);primitives=array('PrimitiveRecord',records['primitives']);quality=array('QualityRecord',records['quality'])
    encoded=records['stringsUtf8'].encode('utf8');strings=(C.c_uint8*len(encoded)).from_buffer_copy(encoded)
    view=TYPES['SnapshotView']();view.owner=1;view.format_version=1
    for key,value in records['viewport'].items():setattr(view.viewport,key,value)
    view.tracks=tracks;view.track_count=len(tracks);view.primitives=primitives;view.primitive_count=len(primitives)
    view.quality=quality;view.quality_count=len(quality);view.strings=strings;view.string_bytes=len(encoded)
    view.retained_bytes=records['retainedBytes'];view.quality_status=records['qualityStatus']
    return scene(view)[0]

def main():
    artifact=Path(os.environ['ARKTRACE_RUST_XCFRAMEWORK'])
    executable,receipt=consumer(artifact)
    if '--build-only' in sys.argv:
        print(json.dumps({'executable':str(executable),'receipt':receipt},indent=2));return
    # The independent legacy oracle has no binary target and must not opt in
    # to the SDK development override inherited by this harness.
    native_override=os.environ.pop('ARKTRACE_RUST_XCFRAMEWORK')
    try:swift,swift_receipt=build_oracle()
    finally:os.environ['ARKTRACE_RUST_XCFRAMEWORK']=native_override
    cargo('build','-p','arktrace-platform','--bin','arktrace-host-process')
    target=Path(json.loads(cargo('metadata','--format-version','1','--no-deps'))['target_directory'])/'debug'
    manifest=json.loads((ROOT/'ThirdParty/TraceStreamer/macx/manifest.json').read_text())
    parser=ROOT/'ThirdParty/TraceStreamer/macx/trace_streamer';assert sha(parser)==manifest['binarySHA256']
    parser_identity={k:manifest[k] for k in ('name','reportedVersion','binarySHA256','upstreamRepository','upstreamRevision','architecture','adapterVersion','buildRecipeVersion')}
    corpus=json.loads((ROOT/'docs/migration-runs/AT-RUST-001-2026-10-02-small-oracle.json').read_text())['corpus']
    vectors=json.loads((ROOT/'docs/migration-runs/AT-RUST-011-2026-10-04-viewport-owner.json').read_text())['nativeRuntime']['sources']
    reports=[]
    with tempfile.TemporaryDirectory(prefix='arktrace-sdk-空 格-',dir='/private/tmp') as folder:
        base=Path(folder);tools=base/'tools';tools.mkdir(mode=0o700)
        for source,name in [(target/'arktrace-host-process','helper'),(parser,'parser')]:shutil.copyfile(source,tools/name);(tools/name).chmod(0o500)
        runtime_artifacts={'helper':identity(tools/'helper'),'parser':identity(tools/'parser'),'parserIdentity':parser_identity}
        for i,(fixture,historical) in enumerate(zip(corpus,vectors)):
            source=ROOT/fixture['path'];assert sha(source)==fixture['sha256']
            namespace=base/f'engine-{i}';namespace.mkdir(mode=0o700)
            inputs=[r['input'] for r in historical['responses']]
            input_path=base/'input.json';input_path.write_text(json.dumps({'source':str(source),'format':2 if source.suffix=='.systrace' else 1,'namespace':str(namespace),'helper':str(tools/'helper'),'parser':str(tools/'parser'),'helperSHA256':sha(tools/'helper'),'parserIdentity':parser_identity,'vectors':inputs}))
            stderr=base/f'consumer-{i}.log'
            with stderr.open('w') as error_output:
                process=subprocess.Popen([str(executable),str(input_path)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=error_output,text=True)
                try:
                    assert select.select([process.stdout],[],[],60)[0], 'SDK open timed out'
                    ready=process.stdout.readline();assert ready and json.loads(ready)=={'phase':'ready'},(ready,stderr.read_text())
                    databases=list(namespace.rglob('trace.db'));assert len(databases)==1
                    oracle=subprocess.run([str(swift),str(databases[0]),json.dumps(parser_identity),json.dumps({'sha256':fixture['sha256'],'byteCount':source.stat().st_size}),json.dumps(inputs)],capture_output=True,check=True)
                    assert not oracle.stderr
                    fresh=json.loads(oracle.stdout)
                    stdout,_=process.communicate('\n',timeout=120);assert process.returncode==0,(process.returncode,stderr.read_text())
                finally:
                    if process.poll() is None:process.kill();process.wait()
            report=json.loads(stdout)
            assert report['opening']['inspection']==historical['inspection']
            typed=report['typedOpening']
            assert json.loads(typed['bodyUTF8'])==report['opening']
            assert typed['bodyUTF8']==typed['afterShutdownBodyUTF8']
            assert typed['identity']['engine']>0 and typed['identity']['session']>0
            assert typed['retainedBytes']>0
            assert (typed['afterOnlyParserFacetOwners'],typed['afterOnlyTextOwners'],typed['finalBytes'],typed['finalOwners'])==(1,1,0,0)
            for response,expected in zip(report['responses'],fresh):
                body=json.loads(response['responseUtf8'])['body']
                if 'request' in response['input']:
                    compare(body['snapshot'],expected['projected'])
                    assert response['records'] is not None
                    compare(projection(response['records']),body['snapshot'])
                    compare(projection(response['records']),expected['projected'])
                    assert response['records']['viewport']['generation']==expected['projected']['viewport']['generation']
                    assert len(response['records']['tracks'])==len(expected['projected']['tracks'])
                    assert len(response['records']['primitives'])==sum(len(t['primitives']) for t in expected['projected']['tracks'])
                else:
                    selected=None if body is None else {k:body[k] for k in ('eventKey','range','isOpenEnded')}
                    compare(selected,expected['selected'])
            assert not list(namespace.rglob('trace.db')) and sha(source)==fixture['sha256']
            reports.append({'fixture':source.name,'freshSwiftResponseUtf8':oracle.stdout.decode(),'sdk':report,'ownedScopeRemoved':True,'rawSHA256Unchanged':True})
        # Deliberately replace one owned derived file in a separate process.
        # Its actual native close must retain the failure and preserve the
        # foreign replacement; this is a negative gate, not cleanup success.
        fixture=corpus[0];source=ROOT/fixture['path']
        namespace=base/'cleanup-failure';namespace.mkdir(mode=0o700)
        input_path.write_text(json.dumps({'source':str(source),'format':1,'namespace':str(namespace),'helper':str(tools/'helper'),'parser':str(tools/'parser'),'helperSHA256':sha(tools/'helper'),'parserIdentity':parser_identity,'vectors':[],'mode':'arc-cleanup-failure'}))
        with (base/'cleanup-failure.log').open('w') as error_output:
            process=subprocess.Popen([str(executable),str(input_path)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=error_output,text=True)
            try:
                assert select.select([process.stdout],[],[],60)[0]
                assert json.loads(process.stdout.readline())=={'phase':'ready'}
                databases=list(namespace.rglob('trace.db'));assert len(databases)==1
                database=databases[0];original_sha=sha(database)
                owned_directory=database.parent
                escaped=base/'escaped-derived-owner';owned_directory.rename(escaped)
                original=escaped/'trace.db'
                owned_directory.mkdir(mode=0o700)
                database.write_bytes(b'foreign replacement must survive cleanup');database.chmod(0o400)
                stdout,_=process.communicate('\n',timeout=120)
                assert process.returncode==0,(process.returncode,(base/'cleanup-failure.log').read_text())
                cleanup_failure=json.loads(stdout)
                assert cleanup_failure['reason']=='sessionCleanupFailed' and cleanup_failure['arcFallbackFailureObservable']=='true'
                assert database.read_bytes()==b'foreign replacement must survive cleanup' and sha(original)==original_sha
                assert str(base) not in stdout and sha(source)==fixture['sha256']
                cleanup_failure.update(foreignReplacementPreserved=True,originalDerivedBytesPreserved=True,rawSHA256Unchanged=True,unresolvedOwnedResidueExpected=True)
            finally:
                if process.poll() is None:process.kill();process.wait()
    print(json.dumps({'nativeMacOSSwiftSDK':True,'fullSDKAcceptance':False,'contractSHA256':(ROOT/'contracts/ffi-v1.sha256').read_text().strip(),'receipt':receipt,'runtimeArtifacts':runtime_artifacts,'swiftOracle':swift_receipt,'sources':reports,'cleanupFailure':cleanup_failure},ensure_ascii=False,indent=2))
if __name__=='__main__':main()
