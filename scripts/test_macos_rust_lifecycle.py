#!/usr/bin/env python3
"""Actual package-external SDK parse/query/cancel/close pressure gate.

Reduced --cycles runs are development feedback, never the 1,000-cycle gate.
RSS allowances are frozen here before execution; they are not product SLOs.
"""
import argparse
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tempfile
import time
from test_macos_rust_sdk import ROOT, cargo, consumer, identity, sha


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--cycles', type=int, default=1000, choices=range(1, 1001))
    args = parser.parse_args()
    artifact = Path(os.environ['ARKTRACE_RUST_XCFRAMEWORK'])
    executable, receipt = consumer(artifact)
    executable = executable.with_name('Lifecycle')
    assert identity(executable) == receipt['lifecycleExecutable']
    cargo('build', '-p', 'arktrace-platform', '--bin', 'arktrace-host-process')
    target = Path(json.loads(cargo('metadata', '--format-version', '1', '--no-deps'))['target_directory']) / 'debug'
    manifest = json.loads((ROOT / 'ThirdParty/TraceStreamer/macx/manifest.json').read_text())
    trace_parser = ROOT / 'ThirdParty/TraceStreamer/macx/trace_streamer'
    assert sha(trace_parser) == manifest['binarySHA256']
    parser_identity = {k: manifest[k] for k in ('name', 'reportedVersion', 'binarySHA256', 'upstreamRepository', 'upstreamRevision', 'architecture', 'adapterVersion', 'buildRecipeVersion')}
    corpus = json.loads((ROOT / 'docs/migration-runs/AT-RUST-001-2026-10-02-small-oracle.json').read_text())['corpus']
    fixture = next(x for x in corpus if Path(x['path']).name == 'zlib.htrace')
    source = ROOT / fixture['path']
    assert sha(source) == fixture['sha256']
    checkpoints = []
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix='arktrace-lifecycle-空 格-', dir='/private/tmp') as directory:
        base = Path(directory); tools = base / 'tools'; tools.mkdir(mode=0o700)
        for path, name in [(target / 'arktrace-host-process', 'helper'), (trace_parser, 'parser')]:
            shutil.copyfile(path, tools / name); (tools / name).chmod(0o500)
        runtime_artifacts = {name: identity(tools / name) for name in ('helper', 'parser')}
        namespace = base / 'namespace'; namespace.mkdir(mode=0o700)
        input_path = base / 'input.json'
        input_path.write_text(json.dumps({'source': str(source), 'namespace': str(namespace), 'helper': str(tools / 'helper'), 'parser': str(tools / 'parser'), 'helperSHA256': sha(tools / 'helper'), 'parserIdentity': parser_identity, 'cycles': args.cycles}))
        stderr = base / 'lifecycle.log'
        with stderr.open('w') as errors:
            process = subprocess.Popen([str(executable), str(input_path)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors, text=True)
            baseline_members = None
            try:
                while True:
                    assert select.select([process.stdout], [], [], 600)[0], 'native lifecycle checkpoint timed out'
                    line = process.stdout.readline()
                    assert line, (process.poll(), stderr.read_text())
                    message = json.loads(line)
                    if message['phase'] == 'finished':
                        summary = message; break
                    assert message['phase'] == 'checkpoint'
                    assert message['retainedBytes'] == message['sessionCount'] == message['requestCount'] == 0
                    assert message['resources']['childCount'] == 0
                    members = sorted(p.relative_to(namespace).as_posix() for p in namespace.rglob('*'))
                    assert not list(namespace.rglob('trace.db'))
                    if baseline_members is None:
                        baseline_members = members
                        baseline_fd = message['resources']['fdCount']
                    assert members == baseline_members, members
                    assert message['resources']['fdCount'] == baseline_fd
                    assert sha(source) == fixture['sha256']
                    message.update(namespaceMembers=members, rawSHA256Unchanged=True, noReadyDatabase=True)
                    checkpoints.append(message)
                    print(f"native lifecycle: {message['completedCycles']}/{args.cycles}; FD={baseline_fd}; RSS={message['resources']['residentBytes']}; retained=0", file=sys.stderr, flush=True)
                    process.stdin.write('\n'); process.stdin.flush()
                process.stdin.close(); process.wait(timeout=60)
                assert process.returncode == 0, stderr.read_text()
                assert not process.stdout.read().strip() and not stderr.read_text().strip(), stderr.read_text()
            finally:
                if process.poll() is None:
                    process.kill(); process.wait()
        assert summary['completedCycles'] == args.cycles
        for field in ('fullyParsedOpens', 'cancelledAdmittedOpens', 'rawQueries', 'nativeSnapshots'):
            assert summary[field] == args.cycles
        assert summary['primitiveReads'] > args.cycles and summary['retainedAfterFinalOwner'] == 0
        assert summary['final']['fdCount'] == baseline_fd and summary['final']['childCount'] == 0
        assert summary['maximumCheckpointRSS'] <= summary['baseline']['residentBytes'] + 32 * 1024 * 1024
        steady = [x['resources']['residentBytes'] for x in checkpoints if x['completedCycles'] >= args.cycles // 2 and x['completedCycles'] > 0]
        assert max(steady) <= steady[0] + 8 * 1024 * 1024
        assert summary['uiTicks'] > 0 and sha(source) == fixture['sha256']
        assert not list(namespace.rglob('trace.db'))
    print(json.dumps({'nativeMacOSSDKLifecycle': True, 'thousandCycleGate': args.cycles == 1000, 'fullSDKAcceptance': False, 'elapsedSeconds': time.monotonic() - started, 'receipt': receipt, 'runtimeArtifacts': runtime_artifacts, 'parserIdentity': parser_identity, 'fixture': fixture, 'frozenRSSAllowances': {'aboveWarmedBaselineBytes': 32 * 1024 * 1024, 'lateHalfGrowthBytes': 8 * 1024 * 1024}, 'checkpoints': checkpoints, 'summary': summary, 'rawSHA256Unchanged': True, 'ownedReadyScopesRemoved': True}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
