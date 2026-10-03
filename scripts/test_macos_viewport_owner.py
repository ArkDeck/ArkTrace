#!/usr/bin/env python3
"""Actual parser/Store/Swift viewport parity and async generation ownership.

Retains full Swift snapshots/inspectors and complete Rust UTF-8 responses.
The compared projection excludes labels/inspector prose/palette/jank fields
which are explicitly pending. This does not certify an SDK or App cutover.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from test_macos_parser_process import ROOT, cargo, digest

sys.path.insert(0,str(ROOT/'rust/crates/arktrace-viewer/oracle'))
from build_native_viewport_oracle import build

def main():
    if sys.platform != 'darwin' or os.uname().machine != 'arm64':
        raise SystemExit('native macOS arm64 required; no simulated PASS')
    swift, swift_receipt = build()
    paths = [ROOT/'rust/Cargo.toml',ROOT/'rust/Cargo.lock',ROOT/'rust/rust-toolchain.toml',
        ROOT/'scripts/run-cargo.py',ROOT/'scripts/test_macos_parser_process.py',Path(__file__),
        ROOT/'docs/migration-runs/AT-RUST-001-2026-10-02-small-oracle.json',
        ROOT/'ThirdParty/TraceStreamer/macx/manifest.json']
    paths += sorted((ROOT/'rust/crates').rglob('Cargo.toml')) + sorted((ROOT/'rust/crates').rglob('*.rs'))
    pins = [{'path':p.relative_to(ROOT).as_posix(),'byteCount':p.stat().st_size,'sha256':digest(p)} for p in paths]
    oracle = json.loads((ROOT/'docs/migration-runs/AT-RUST-001-2026-10-02-small-oracle.json').read_text())
    parser = ROOT/'ThirdParty/TraceStreamer/macx/trace_streamer'
    manifest = json.loads(parser.with_name('manifest.json').read_text())
    assert digest(parser) == manifest['binarySHA256'] == oracle['parser']['binarySHA256']
    for fixture in oracle['corpus']: assert digest(ROOT/fixture['path']) == fixture['sha256']
    identity = {k:manifest[k] for k in ('name','reportedVersion','binarySHA256','upstreamRepository',
        'upstreamRevision','architecture','adapterVersion','buildRecipeVersion')}
    cargo('build','-p','arktrace-platform','--bin','arktrace-host-process')
    target = Path(json.loads(cargo('metadata','--format-version','1','--no-deps'))['target_directory'])
    base = Path(tempfile.mkdtemp(prefix='arktrace-viewport-空 格-',dir='/private/tmp')).resolve()
    try:
        tools = base/'tools';tools.mkdir(mode=0o700)
        for source,name in [(target/'debug/arktrace-host-process','host-process'),(parser,'trace-streamer')]:
            shutil.copyfile(source,tools/name);(tools/name).chmod(0o500)
        helper_pin=digest(tools/'host-process')
        run=subprocess.run([sys.executable,str(ROOT/'scripts/run-cargo.py'),'run','-p','arktrace-engine',
            '--features','process-fixtures','--example','macos_viewport_probe','--',str(base),str(ROOT/'Fixtures/traces'),
            json.dumps(identity),helper_pin,str(swift)],cwd=ROOT,capture_output=True,timeout=240)
        sys.stderr.buffer.write(run.stderr);run.check_returncode()
        report=json.loads(run.stdout)
        assert report['sdkAcceptance'] is False and report['persistentCacheAcceptance'] is False
        assert report['independentSwiftNativeProjectionParity'] is True and len(report['sources'])==3
        for source in report['sources']:
            assert all(source[k] for k in ('fullViewportBlockingAsyncParity','independentSwiftNativeProjectionParity',
                'gatedLatestGenerationWins','genericQuerySurvivesSupersession','staleCompletedHandleRejected',
                'resultSurvivesReleaseCloseDrain','rawBytesUnchanged','ownedScopesRemoved'))
            assert source['descriptorsBefore']==source['descriptorsAfter']
            assert len(source['responses'])==25
            original=json.loads(source['swiftResponseUtf8'])
            assert original==[r['swift'] for r in source['responses']]
            positive_viewports=positive_resolutions=0
            for response in source['responses']:
                assert response['fullRustBlockingAsyncBytesEqual'] and response['swiftSemanticProjectionEqual']
                encoded=response['responseUtf8'].encode();document=json.loads(encoded)
                assert set(document)=={'formatVersion','session','request','body'} and document['formatVersion']==1
                body=document['body']
                if 'request' in response['input']:
                    count=sum(len(t['primitives']) for t in body['snapshot']['tracks'])
                    assert count<=response['input']['request']['maximumPrimitives']
                    positive_viewports+=count>0
                else: positive_resolutions+=body is not None
                response['responseDigest']={'byteCount':len(encoded),'sha256':hashlib.sha256(encoded).hexdigest()}
            assert positive_viewports>0 and positive_resolutions>0
            source['positiveViewportCases']=positive_viewports;source['positiveResolutionCases']=positive_resolutions
        for fixture in oracle['corpus']: assert digest(ROOT/fixture['path'])==fixture['sha256']
        assert digest(parser)==manifest['binarySHA256']
        retained=Path(tempfile.mkdtemp(prefix='arktrace-viewport-artifacts-',dir='/private/tmp')).resolve()
        artifacts=[]
        for binary,name in [(tools/'host-process','host-process'),(target/'debug/examples/macos_viewport_probe','viewport-probe'),(swift,'swift-native-viewport-oracle')]:
            destination=retained/name;pin=digest(binary);shutil.copyfile(binary,destination);destination.chmod(0o500)
            assert digest(destination)==pin
            artifacts.append({'path':str(destination),'sha256':pin,'byteCount':destination.stat().st_size})
        assert artifacts[0]['sha256']==helper_pin and artifacts[2]['sha256']==swift_receipt['executable']['sha256']
        for pin in pins+swift_receipt['sourceDigests']:
            path=ROOT/pin['path'];assert path.stat().st_size==pin['byteCount'] and digest(path)==pin['sha256']
        toolchain={name:subprocess.check_output(command,cwd=ROOT,text=True).strip() for name,command in [
            ('rustc',['rustc','--version','--verbose']),('cargo',['cargo','--version','--verbose']),
            ('xcode',['xcodebuild','-version']),('swift',['swift','--version']),('os',['sw_vers'])]}
        shutil.rmtree(base)
        print(json.dumps({'nativeRuntime':report,'parser':identity,'corpus':oracle['corpus'],'sourceDigests':pins,'swiftOracle':swift_receipt,
            'retainedExactRunArtifacts':artifacts,'toolchain':toolchain,'ownedHarnessRootRemoved':True},ensure_ascii=False,indent=2))
    except BaseException:
        print(f'Preserved failed viewport harness: {base}',file=sys.stderr);raise

if __name__=='__main__':main()
