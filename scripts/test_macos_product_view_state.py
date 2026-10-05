#!/usr/bin/env python3
"""Run a finished native controller consumer against a real fixed parser.

The producer has already ended; this harness performs no builds. An external
key lock exercises the actual controller writer's bounded close and error path.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import time
from stage_macos_rust_sdk import ROOT, verified_receipt


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    for name in ('executable', 'sdk-receipt', 'artifact', 'helper', 'parser', 'source', 'evidence-dir'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    assert sys.platform == 'darwin' and os.uname().machine == 'arm64'
    artifact_receipt, artifact_id = verified_receipt(args.artifact.resolve(), True)
    producer = json.loads(args.sdk_receipt.read_text())['receipt']
    assert producer['artifactIdentity'] == artifact_id
    assert producer['coreExecutable'] == dict(byteCount=args.executable.stat().st_size, sha256=sha(args.executable))
    assert all(producer['sdkUnitTests'][key] == value for key, value in dict(passed=87, failed=0, skipped=0).items())
    base = args.evidence_dir.resolve()
    assert not base.exists()
    base.mkdir(mode=0o700)
    tools = base / 'tools'; tools.mkdir(mode=0o700)
    inputs = []
    for original, destination, mode in [
            (args.executable, tools / 'consumer', 0o500), (args.helper, tools / 'helper', 0o500),
            (args.parser, tools / 'parser', 0o500), (args.source, base / 'source.htrace', 0o400),
            (args.sdk_receipt, base / 'sdk-build-receipt.json', 0o400),
            (ROOT / 'ThirdParty/TraceStreamer/macx/manifest.json', tools / 'source-manifest.json', 0o400)]:
        shutil.copyfile(original, destination); destination.chmod(mode)
        assert sha(original) == sha(destination)
        inputs.append(dict(sourcePath=str(original.resolve()), frozenPath=str(destination),
                           sha256=sha(destination), byteCount=destination.stat().st_size))
    (base / 'inputs.json').write_text(json.dumps(inputs, indent=2) + '\n')
    (base / 'artifact-receipt.json').write_text(json.dumps(artifact_receipt, indent=2) + '\n')
    manifest = json.loads((tools / 'source-manifest.json').read_text())
    assert sha(tools / 'parser') == manifest['binarySHA256']
    identity = {k: manifest[k] for k in ('name', 'reportedVersion', 'binarySHA256', 'upstreamRepository',
                'upstreamRevision', 'architecture', 'adapterVersion', 'buildRecipeVersion')}
    configuration = dict(source=str(base / 'source.htrace'), format=1, namespace=str(base / 'namespace'),
        cacheDirectory=str(base / 'cache'), helper=str(tools / 'helper'), parser=str(tools / 'parser'),
        helperSHA256=sha(tools / 'helper'), parserIdentity=identity, manifest=str(tools / 'source-manifest.json'),
        productRuntime=True, productViewStateLockProbe=True, vectors=[])
    input_path = base / 'input.json'; input_path.write_text(json.dumps(configuration, indent=2) + '\n')
    events, lock = [], None
    with (base / 'consumer.stderr').open('wb') as errors:
        process = subprocess.Popen([str(tools / 'consumer'), str(input_path)], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=errors, text=True)
        def receive():
            assert select.select([process.stdout], [], [], 60)[0], 'controller protocol timed out'
            raw = process.stdout.readline()
            with (base / 'events.jsonl').open('a') as output: output.write(raw)
            assert raw, (process.poll(), (base / 'consumer.stderr').read_text())
            value = json.loads(raw); events.append(value); return value
        def resume():
            process.stdin.write('\n'); process.stdin.flush()
        try:
            ready = receive(); assert ready['phase'] == 'controller-lock-ready'
            cache = base / 'product-runtime/native/traces'
            trace_sha = sha(base / 'source.htrace')
            entry = cache / trace_sha / ready['parserKey']
            database, sidecar = entry / 'trace.sqlite', entry / 'view-state.json'
            database_sha, sidecar_before = sha(database), sidecar.read_bytes()
            lock_key = hashlib.sha256((trace_sha + ':' + ready['parserKey']).encode()).hexdigest()
            lock = (cache / '.locks' / (lock_key + '.lock')).open('r+b')
            fcntl.flock(lock, fcntl.LOCK_EX)
            start = time.monotonic(); resume()
            bounded = receive()
            assert bounded['phase'] == 'controller-lock-complete' and time.monotonic() - start < 5
            assert bounded['closeBounded'] == bounded['saveTimeoutVisible'] == 'true' and int(bounded['uiTicks']) > 5
            assert sidecar.read_bytes() == sidecar_before and sha(database) == database_sha
            (base / 'lock-original-sidecar.json').write_bytes(sidecar_before)
            fcntl.flock(lock, fcntl.LOCK_UN); lock.close(); lock = None
            resume(); final = receive()
            assert all(value for key, value in final.items() if key not in ('appCutover', 'fullCacheAcceptance'))
            process.wait(timeout=60)
            assert process.returncode == 0 and not (base / 'consumer.stderr').read_bytes()
            assert sha(base / 'source.htrace') == trace_sha
            assert not list((base / 'product-runtime/native/staging/.actors').glob('owner-*'))
            extreme = json.loads((base / 'product-extreme-view-state.json').read_text())
            assert extreme['flags'][0]['id'] == extreme['flags'][0]['timestampNs'] == 2**63 - 1
            assert extreme['flags'][0]['colorIndex'] == 2 and extreme['flags'][1]['timestampNs'] == -(2**63)
            assert extreme['marks'][0]['id'] == -(2**63)
            assert extreme['favoriteTrackIDs'][0] == extreme['favoriteTrackIDs'][2] == 'missing\0🦀'
            assert json.loads((base / 'product-future-view-state.json').read_text())['formatVersion'] == 999
            report = dict(artifactIdentity=artifact_id, contractSHA256=artifact_receipt['contractSHA256'],
                sourceSHA256=trace_sha, databaseSHA256BeforeLock=database_sha, events=events,
                rawTraceUnchanged=True, lockTimeoutPreservedOriginalSidecar=True, processExitCode=process.returncode,
                appCutover=False, fullMacOSAcceptance=False)
            (base / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
            print(json.dumps(report, indent=2))
        finally:
            if lock is not None:
                fcntl.flock(lock, fcntl.LOCK_UN); lock.close()
            if process.poll() is None: process.kill(); process.wait()
            (base / 'process-exit.json').write_text(json.dumps(dict(exitCode=process.returncode,
                stderrSHA256=sha(base / 'consumer.stderr')), indent=2) + '\n')


if __name__ == '__main__':
    main()
