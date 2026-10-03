#!/usr/bin/env python3
"""Real pinned-parser async Engine lifecycle; development evidence, no SDK/App gate.

No synthetic repository or parser success. Retains exact executable identities,
full typed-body comparisons and source pins. Failure preserves the owned harness.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from test_macos_parser_process import ROOT, cargo, digest


def main():
    if sys.platform != 'darwin' or os.uname().machine != 'arm64':
        raise SystemExit('native macOS arm64 required; no simulated PASS')
    paths = [ROOT/'rust/Cargo.toml', ROOT/'rust/Cargo.lock', ROOT/'rust/rust-toolchain.toml',
        ROOT/'scripts/run-cargo.py', ROOT/'scripts/test_macos_parser_process.py', Path(__file__)]
    paths += sorted((ROOT/'rust/crates').rglob('Cargo.toml'))
    paths += sorted((ROOT/'rust/crates').rglob('*.rs'))
    pins = [{'path':p.relative_to(ROOT).as_posix(),'byteCount':p.stat().st_size,'sha256':digest(p)} for p in paths]
    oracle = json.loads((ROOT/'docs/migration-runs/AT-RUST-001-2026-10-02-small-oracle.json').read_text())
    parser = ROOT/'ThirdParty/TraceStreamer/macx/trace_streamer'
    manifest = json.loads(parser.with_name('manifest.json').read_text())
    assert digest(parser) == manifest['binarySHA256'] == oracle['parser']['binarySHA256']
    for fixture in oracle['corpus']:
        assert digest(ROOT/fixture['path']) == fixture['sha256']
    identity = {k:manifest[k] for k in ('name','reportedVersion','binarySHA256','upstreamRepository',
        'upstreamRevision','architecture','adapterVersion','buildRecipeVersion')}
    cargo('build','-p','arktrace-platform','--bin','arktrace-host-process')
    target = Path(json.loads(cargo('metadata','--format-version','1','--no-deps'))['target_directory'])
    base = Path(tempfile.mkdtemp(prefix='arktrace-runtime-空 格-',dir='/private/tmp')).resolve()
    try:
        tools = base/'tools'
        tools.mkdir(mode=0o700)
        for source,name in [(target/'debug/arktrace-host-process','host-process'),(parser,'trace-streamer')]:
            shutil.copyfile(source,tools/name)
            (tools/name).chmod(0o500)
        helper_pin = digest(tools/'host-process')
        run = subprocess.run([sys.executable,str(ROOT/'scripts/run-cargo.py'),'run','-p','arktrace-engine',
            '--features','process-fixtures','--example','macos_runtime_probe','--',str(base),str(ROOT/'Fixtures/traces'),
            json.dumps(identity),helper_pin],cwd=ROOT,capture_output=True,timeout=180)
        sys.stderr.buffer.write(run.stderr)
        run.check_returncode()
        report = json.loads(run.stdout)
        assert report['sdkAcceptance'] is False and report['persistentCacheAcceptance'] is False
        assert len(report['sources']) == 3 and len(report['negativeCases']) == 12
        assert all(s['fullBatchSearchAnalysisParity'] and s['isolatedSessions']
            and s['resultSurvivesReleaseCloseDrain'] and s['rawBytesUnchanged']
            and s['ownedScopesRemoved'] and s['descriptorsBefore'] == s['descriptorsAfter'] for s in report['sources'])
        assert all(c['passed'] for c in report['negativeCases'])
        for source in report['sources']:
            source['responseDigests'] = {}
            for kind,encoded in source['responsesUtf8'].items():
                data = encoded.encode('utf-8')
                document = json.loads(encoded)
                assert document['formatVersion'] == 1 and isinstance(document['session'],int) and isinstance(document['request'],int)
                import hashlib
                source['responseDigests'][kind] = {'byteCount':len(data),'sha256':hashlib.sha256(data).hexdigest()}
        for fixture in oracle['corpus']:
            assert digest(ROOT/fixture['path']) == fixture['sha256']
        assert digest(parser) == manifest['binarySHA256']
        retained = Path(tempfile.mkdtemp(prefix='arktrace-runtime-artifacts-',dir='/private/tmp')).resolve()
        artifacts = []
        for source,name in [(tools/'host-process','host-process'),(target/'debug/examples/macos_runtime_probe','runtime-probe')]:
            destination = retained/name
            pin = digest(source)
            shutil.copyfile(source,destination)
            destination.chmod(0o500)
            assert digest(destination) == pin
            artifacts.append({'path':str(destination),'sha256':pin,'byteCount':destination.stat().st_size})
        assert artifacts[0]['sha256'] == helper_pin
        for pin in pins:
            path = ROOT/pin['path']
            assert path.stat().st_size == pin['byteCount'] and digest(path) == pin['sha256']
        toolchain = {}
        for name,command in [('rustc',['rustc','--version','--verbose']),('cargo',['cargo','--version','--verbose']),
            ('xcode',['xcodebuild','-version']),('swift',['swift','--version']),('os',['sw_vers'])]:
            toolchain[name] = subprocess.check_output(command,cwd=ROOT,text=True).strip()
        shutil.rmtree(base)
        print(json.dumps({'nativeRuntime':report,'parser':identity,'sourceDigests':pins,
            'retainedExactRunArtifacts':artifacts,'toolchain':toolchain,'ownedHarnessRootRemoved':True},ensure_ascii=False,indent=2))
    except BaseException:
        print(f'Preserved failed runtime harness: {base}',file=sys.stderr)
        raise


if __name__ == '__main__':
    main()
