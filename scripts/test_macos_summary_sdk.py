#!/usr/bin/env python3
"""Actual package-external SDK summary requests against frozen Swift facts.

This checks the native JSON response. The retained typed summary facade and
Core warning materialization remain separate acceptance work.
"""
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


def machine(facts):
    result = dict(facts)
    result.pop('warnings')
    result['dataQualityIssues'] = [dict(issue, message=None) for issue in result.pop('qualityIssues')]
    return result


def main():
    artifact = Path(os.environ['ARKTRACE_RUST_XCFRAMEWORK'])
    executable, receipt = consumer(artifact)
    executable = executable.parent / 'SummaryOwnership'
    assert sha(executable) == receipt['summaryExecutable']['sha256']
    subprocess.run(['python3', str(ROOT / 'scripts/run-cargo.py'), 'build', '-p',
                    'arktrace-platform', '--bin', 'arktrace-host-process'], cwd=ROOT, check=True)
    metadata = json.loads(subprocess.check_output(['python3', str(ROOT / 'scripts/run-cargo.py'),
        'metadata', '--format-version', '1', '--no-deps'], cwd=ROOT, text=True))
    helper = Path(metadata['target_directory']) / 'debug/arktrace-host-process'
    parser = ROOT / 'ThirdParty/TraceStreamer/macx/trace_streamer'
    manifest = json.loads((parser.parent / 'manifest.json').read_text(encoding='utf-8'))
    assert sha(parser) == manifest['binarySHA256']
    parser_identity = {key: manifest[key] for key in ('name', 'reportedVersion', 'binarySHA256',
        'upstreamRepository', 'upstreamRevision', 'architecture', 'adapterVersion', 'buildRecipeVersion')}
    golden_path = ROOT / 'rust/crates/arktrace-store/tests/fixtures/swift-summary-facts.json'
    golden = json.loads(golden_path.read_text(encoding='utf-8'))
    corpus = json.loads((ROOT / 'docs/migration-runs/AT-RUST-001-2026-10-02-small-oracle.json').read_text(encoding='utf-8'))['corpus']
    reports = []
    with tempfile.TemporaryDirectory(prefix='arktrace-summary-空 格-', dir='/private/tmp') as folder:
        base = Path(folder); tools = base / 'tools'; tools.mkdir(mode=0o700)
        for source, name in [(helper, 'helper'), (parser, 'parser')]:
            shutil.copyfile(source, tools / name); (tools / name).chmod(0o500)
        tool_pins = {name: sha(tools / name) for name in ('helper', 'parser')}
        for fixture in corpus:
            source = ROOT / fixture['path']
            records = [record for record in golden['records'] if 'facts' in record
                and record.get('request', {}).get('fixture') == source.stem]
            if not records:
                continue
            assert sha(source) == fixture['sha256']
            namespace = base / source.stem; namespace.mkdir(mode=0o700)
            vectors = [dict(id=record['id'], query={key: record['request'][key] for key in
                ('range', 'maximumRowsPerSection', 'maximumEventsPerSection')}) for record in records]
            input_path = base / (source.stem + '.json')
            input_path.write_text(json.dumps(dict(source=str(source), format=1, namespace=str(namespace),
                helper=str(tools / 'helper'), parser=str(tools / 'parser'), helperSHA256=tool_pins['helper'],
                parserIdentity=parser_identity, vectors=vectors), ensure_ascii=False), encoding='utf-8')
            process = subprocess.run([str(executable), str(input_path)], cwd=ROOT,
                capture_output=True, timeout=120)
            assert process.returncode == 0, (process.returncode, process.stderr.decode('utf-8', errors='replace'))
            assert not process.stderr
            assert str(base).encode() not in process.stdout
            actual = json.loads(process.stdout)
            assert actual['pastDurationCode'] == 'INVALID_ARGUMENT' and actual['pastDurationStage'] == 'request'
            assert actual['invalidLimitAdmission'] == 3
            assert actual['preCancelledOutcome'] == 'swiftCancellationError'
            assert actual['queryRejectedAfterClose']
            assert len(actual['responses']) == len(records)
            identities = set()
            for result, expected in zip(actual['responses'], records):
                assert result['id'] == expected['id']
                assert result['utf8'] == result['afterShutdownUTF8']
                envelope = json.loads(result['utf8'])
                assert envelope['formatVersion'] == 1 and envelope['session'] > 0 and envelope['request'] > 0
                identities.add(envelope['request'])
                assert envelope['body'] == machine(expected['facts']), result['id']
            assert len(identities) == len(records)
            assert not list(namespace.rglob('trace.db'))
            assert sha(source) == fixture['sha256']
            assert all(sha(tools / name) == digest for name, digest in tool_pins.items())
            reports.append(dict(source=fixture, output=actual, outputByteCount=len(process.stdout),
                outputSHA256=hashlib.sha256(process.stdout).hexdigest(), rawTraceUnchanged=True,
                ownedReadyDatabaseRemoved=True))
    assert len(reports) == 2 and sum(len(r['output']['responses']) for r in reports) == 4
    print(json.dumps(dict(nativeSummarySDK=True, typedSummaryFacade=False, fullSDKAcceptance=False,
        comparison='Independent original Swift frozen facts; explicit machine projection omits human prose only and preserves ordered quality, count, nulls and bounds',
        goldenSHA256=sha(golden_path), receipt=receipt, runtimeTools=tool_pins,
        parserIdentity=parser_identity, sources=reports), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
