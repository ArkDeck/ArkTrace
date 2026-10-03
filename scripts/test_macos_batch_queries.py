#!/usr/bin/env python3
"""Actual Ready batch parity with Swift concurrent clones and bounded Rust workers.

Checks complete seven-family pages, failure/drain/FD stability and owned cleanup.
Development parser evidence only; not SDK/App cutover or release acceptance.
"""
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

from test_macos_parser_process import ROOT, cargo, digest


def main():
    assert sys.platform == 'darwin' and os.uname().machine == 'arm64'
    paths = [ROOT/'rust/Cargo.toml', ROOT/'rust/Cargo.lock', ROOT/'rust/rust-toolchain.toml',
        ROOT/'scripts/run-cargo.py', ROOT/'scripts/test_macos_parser_process.py', Path(__file__)]
    paths += sorted((ROOT/'rust/crates').rglob('Cargo.toml'))
    paths += sorted((ROOT/'rust/crates').rglob('*.rs'))
    source_pins = [{'path':p.relative_to(ROOT).as_posix(),'byteCount':p.stat().st_size,
        'sha256':digest(p)} for p in paths]
    receipt = json.loads(Path('/private/tmp/arktrace-batch-swiftpm/oracle-receipt.json').read_text(encoding='utf-8'))
    swift = Path(receipt['executablePath'])
    assert digest(swift) == receipt['executableSHA256']
    for source in receipt['sourceDigests']:
        path = ROOT / source['path']
        assert path.stat().st_size == source['byteCount'] and digest(path) == source['sha256']
    oracle = json.loads((ROOT / 'docs/migration-runs/AT-RUST-001-2026-10-02-small-oracle.json').read_text(encoding='utf-8'))
    parser = ROOT / 'ThirdParty/TraceStreamer/macx/trace_streamer'
    manifest = json.loads(parser.with_name('manifest.json').read_text(encoding='utf-8'))
    assert digest(parser) == manifest['binarySHA256'] == oracle['parser']['binarySHA256']
    for fixture in oracle['corpus']:
        assert digest(ROOT / fixture['path']) == fixture['sha256']
    identity = {k: manifest[k] for k in ('name','reportedVersion','binarySHA256','upstreamRepository',
        'upstreamRevision','architecture','adapterVersion','buildRecipeVersion')}
    cargo('build','-p','arktrace-platform','--bin','arktrace-host-process')
    target = Path(json.loads(cargo('metadata','--format-version','1','--no-deps'))['target_directory'])
    base = Path(tempfile.mkdtemp(prefix='arktrace-batch-空 格-',dir='/private/tmp')).resolve()
    try:
        tools = base / 'tools'
        tools.mkdir(mode=0o700)
        for source,name in [(target/'debug/arktrace-host-process','host-process'),(parser,'trace-streamer')]:
            shutil.copyfile(source,tools/name)
            (tools/name).chmod(0o500)
        helper_pin = digest(tools/'host-process')
        report = json.loads(cargo('run','-p','arktrace-engine','--example','macos_batch_probe','--',
            str(base),str(ROOT/'Fixtures/traces'),json.dumps(identity),helper_pin,str(swift)))
        assert len(report['results']) == 36 and len(report['negativeCases']) == 21
        assert all(r['parity'] == 'T0' and r['descriptorsUnchanged'] for r in report['results'])
        assert all(r['nextRequestUnchanged'] and r['descriptorsUnchanged'] for r in report['negativeCases'])
        assert all(s['rawBytesUnchanged'] and s['explicitCloseRemovedReadyOwnersAndLeases']
            and s['positiveBatches'] == 8 and 1 <= s['peakActiveQueries'] <= 3 for s in report['sources'])
        for fixture in oracle['corpus']:
            assert digest(ROOT/fixture['path']) == fixture['sha256']
        assert digest(parser) == manifest['binarySHA256'] and digest(swift) == receipt['executableSHA256']
        retained = Path(tempfile.mkdtemp(prefix='arktrace-batch-artifacts-',dir='/private/tmp')).resolve()
        artifacts = []
        for source,name in [(tools/'host-process','host-process'),(target/'debug/examples/macos_batch_probe','batch-probe'),
            (swift,'swift-batch-oracle')]:
            pin = digest(source)
            destination = retained/name
            shutil.copyfile(source,destination)
            destination.chmod(0o500)
            assert digest(destination) == pin
            artifacts.append({'path':str(destination),'sha256':pin,'byteCount':destination.stat().st_size})
        assert artifacts[0]['sha256'] == helper_pin and artifacts[2]['sha256'] == receipt['executableSHA256']
        for pin in source_pins:
            path = ROOT/pin['path']
            assert path.stat().st_size == pin['byteCount'] and digest(path) == pin['sha256']
        shutil.rmtree(base)
        print(json.dumps({'nativeBatch':report,'swiftOracleReceipt':receipt,'parser':identity,
            'rustSourceDigests':source_pins,'retainedExactRunArtifacts':artifacts,
            'ownedHarnessRootRemoved':True},ensure_ascii=False,indent=2))
    except BaseException:
        print(f'Preserved failed batch harness: {base}',file=sys.stderr)
        raise


if __name__ == '__main__':
    main()
