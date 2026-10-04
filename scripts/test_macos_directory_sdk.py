#!/usr/bin/env python3
"""Run the actual package-external typed directory owner on three real traces."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from test_macos_rust_sdk import ROOT, consumer


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def pin(path):
    path = Path(path)
    return dict(byteCount=path.stat().st_size, sha256=sha(path))


def main():
    artifact = Path(os.environ['ARKTRACE_RUST_XCFRAMEWORK'])
    executable, receipt = consumer(artifact)
    executable = executable.parent / 'DirectoryOwnership'
    assert pin(executable) == receipt['directoryExecutable']
    subprocess.run(['python3', str(ROOT / 'scripts/run-cargo.py'), 'build', '-p', 'arktrace-platform',
                    '--bin', 'arktrace-host-process'], cwd=ROOT, check=True)
    metadata = subprocess.check_output(['python3', str(ROOT / 'scripts/run-cargo.py'), 'metadata',
                                        '--format-version', '1', '--no-deps'], cwd=ROOT, text=True)
    helper = Path(json.loads(metadata)['target_directory']) / 'debug/arktrace-host-process'
    parser = ROOT / 'ThirdParty/TraceStreamer/macx/trace_streamer'
    manifest = json.loads((parser.parent / 'manifest.json').read_text(encoding='utf-8'))
    assert sha(parser) == manifest['binarySHA256']
    parser_identity = {key: manifest[key] for key in ('name', 'reportedVersion', 'binarySHA256',
        'upstreamRepository', 'upstreamRevision', 'architecture', 'adapterVersion', 'buildRecipeVersion')}
    corpus = json.loads((ROOT / 'docs/migration-runs/AT-RUST-001-2026-10-02-small-oracle.json').read_text(encoding='utf-8'))['corpus']
    reports = []
    with tempfile.TemporaryDirectory(prefix='arktrace-directory-空 格-', dir='/private/tmp') as folder:
        base = Path(folder)
        tools = base / 'tools'; tools.mkdir(mode=0o700)
        for source, name in [(helper, 'helper'), (parser, 'parser')]:
            shutil.copyfile(source, tools / name)
            (tools / name).chmod(0o500)
        tool_pins = {name: pin(tools / name) for name in ('helper', 'parser')}
        for index, fixture in enumerate(corpus):
            source = ROOT / fixture['path']; assert sha(source) == fixture['sha256']
            namespace = base / f'engine-{index}'; namespace.mkdir(mode=0o700)
            other_namespace = base / f'other-engine-{index}'; other_namespace.mkdir(mode=0o700)
            request = dict(source=str(source), format=2 if source.suffix == '.systrace' else 1,
                namespace=str(namespace), otherNamespace=str(other_namespace), helper=str(tools / 'helper'), parser=str(tools / 'parser'),
                helperSHA256=tool_pins['helper']['sha256'], parserIdentity=parser_identity)
            input_path = base / f'input-{index}.json'
            input_path.write_text(json.dumps(request, ensure_ascii=False), encoding='utf-8')
            process = subprocess.run([str(executable), str(input_path)], cwd=ROOT, capture_output=True, timeout=120)
            assert process.returncode == 0, (process.returncode, process.stderr.decode('utf-8', errors='replace'))
            assert not process.stderr, process.stderr.decode('utf-8', errors='replace')
            actual = json.loads(process.stdout)
            assert len(actual['processPages']) == len(actual['threadPages']) == 3
            assert actual['heldStorageOwners'] == 6 and actual['heldStorageBytes'] > 0
            assert actual['heldBytesAfterEngineRelease'] > 0
            assert all(actual[key] == 0 for key in ('finalStorageBytes', 'finalStorageOwners',
                'finalStagingBytes', 'finalStagingOwners', 'nativeBytesBeforeShutdown'))
            assert all(actual[key] is True for key in ('pagesSurviveEngineRelease',
                'preCancelledTypedQuery', 'typedQueryRejectedAfterClose',
                'distinctSessionIdentityProven', 'retainedOwnerCapAndRecoveryProven', 'nativeQueryUsableAtSDKOwnerCap',
                'distinctEngineIdentityProven'))
            assert actual['uiTicks'] > 0
            assert not list(namespace.rglob('trace.db')), 'owned Ready database survived close'
            assert not list(other_namespace.rglob('trace.db')), 'other Engine Ready database survived close'
            assert sha(source) == fixture['sha256']
            assert all(pin(tools / name) == expected for name, expected in tool_pins.items())
            reports.append(dict(source=dict(path=fixture['path'], **pin(source)), output=actual,
                                outputByteCount=len(process.stdout), outputSHA256=hashlib.sha256(process.stdout).hexdigest(),
                                rawTraceUnchanged=True, ownedReadyDatabaseRemoved=True))
    assert any(report['output']['copiedRecordsSurviveEngineRelease'] for report in reports)
    assert any(report['output']['extractedTextSurvivesFinalPageDrop'] for report in reports)
    print(json.dumps(dict(nativeTypedDirectorySDK=True, fullSDKAcceptance=False,
        comparisons='typed SDK versus separate raw native query, not an independent Swift repository oracle',
        receipt=receipt, runtimeTools=tool_pins, parserIdentity=parser_identity, sources=reports), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
