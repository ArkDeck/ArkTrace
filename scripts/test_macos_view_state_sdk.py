#!/usr/bin/env python3
"""Fresh package-external Swift sidecar consumption; no hidden producer.

Supply the completed SDK build receipt, its executable and fixed native tools.
All original inputs, protocol events and failures remain in evidence-dir.
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
from stage_macos_rust_sdk import ROOT, verified_receipt


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    for name in ('executable', 'sdk-receipt', 'artifact', 'helper', 'parser', 'source', 'evidence-dir'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    assert sys.platform == 'darwin' and os.uname().machine == 'arm64'
    receipt, artifact_identity = verified_receipt(args.artifact.resolve(), True)
    producer = json.loads(args.sdk_receipt.read_text())['receipt']
    assert producer['artifactIdentity'] == artifact_identity
    expected = producer['viewStateExecutable']
    assert expected == dict(byteCount=args.executable.stat().st_size, sha256=sha(args.executable))
    assert producer['sdkUnitTests']['passed'] == 87 and producer['sdkUnitTests']['failed'] == 0
    base = args.evidence_dir.resolve()
    base.mkdir(mode=0o700)
    tools = base / 'tools'
    tools.mkdir(mode=0o700)
    inputs = []
    for source, destination, mode in [(args.executable, tools / 'consumer', 0o500),
                                     (args.helper, tools / 'helper', 0o500),
                                     (args.parser, tools / 'parser', 0o500),
                                     (args.source, base / 'source.htrace', 0o400),
                                     (args.sdk_receipt, base / 'sdk-build-receipt.json', 0o400)]:
        shutil.copyfile(source, destination)
        destination.chmod(mode)
        assert sha(source) == sha(destination)
        inputs.append(dict(sourcePath=str(source.resolve()), frozenPath=str(destination),
                           sha256=sha(destination), bytes=destination.stat().st_size, mode=oct(mode)))
    (base / 'input-manifest.json').write_text(json.dumps(inputs, indent=2) + '\n')
    (base / 'artifact-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    manifest = json.loads((ROOT / 'ThirdParty/TraceStreamer/macx/manifest.json').read_text())
    assert sha(tools / 'parser') == manifest['binarySHA256']
    parser_identity = {k: manifest[k] for k in ('name', 'reportedVersion', 'binarySHA256', 'upstreamRepository',
                      'upstreamRevision', 'architecture', 'adapterVersion', 'buildRecipeVersion')}
    namespace, cache = base / 'namespace', base / 'cache'
    namespace.mkdir(mode=0o700)
    (base / 'namespace-ephemeral').mkdir(mode=0o700)
    cache.mkdir(mode=0o700)
    source_sha = sha(base / 'source.htrace')
    configuration = dict(source=str(base / 'source.htrace'), traceSHA256=source_sha,
        namespace=str(namespace), cacheDirectory=str(cache), helper=str(tools / 'helper'), parser=str(tools / 'parser'),
        helperSHA256=sha(tools / 'helper'), parserIdentity=parser_identity)
    config_path = base / 'input.json'
    config_path.write_text(json.dumps(configuration, indent=2) + '\n')
    events = []
    lock = None
    database = None
    with (base / 'consumer.stderr').open('wb') as errors:
        process = subprocess.Popen([str(tools / 'consumer'), str(config_path)], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=errors, text=True)
        def receive(phase):
            assert select.select([process.stdout], [], [], 60)[0], ('protocol timed out', phase)
            raw = process.stdout.readline()
            with (base / 'events.jsonl').open('a') as log:
                log.write(raw)
            assert raw, (phase, process.poll(), (base / 'consumer.stderr').read_text())
            value = json.loads(raw)
            assert value['phase'] == phase, value
            events.append(value)
            return value
        def resume():
            process.stdin.write('\n')
            process.stdin.flush()
        try:
            ready = receive('ready')
            directory = cache / source_sha / ready['parserKey']
            database = directory / 'trace.sqlite'
            database_sha = sha(database)
            sidecar = directory / 'view-state.json'
            assert not sidecar.exists()
            resume()
            receive('small-complete')
            raw = sidecar.read_bytes()
            (base / 'small-original.json').write_bytes(raw)
            small = json.loads(raw)
            assert small['flags'][0]['id'] == -(2**63) and small['flags'][0]['timestampNs'] == 2**63 - 1
            assert small['flags'][1]['timestampNs'] == -(2**63)
            assert len(small['marks']) == 1 and small['marks'][0]['isPersistent']
            assert small['favoriteTrackIDs'] == ['cpu:0', 'missing\0🦀', 'cpu:0', '']
            assert small['traceSHA256'] == source_sha
            resume()
            receive('exact-byte-cap')
            assert sidecar.stat().st_size == 4 * 1024 * 1024
            exact = json.loads(sidecar.read_bytes())
            assert len(exact['favoriteTrackIDs']) == 1024
            (base / 'exact-original.json').write_bytes(sidecar.read_bytes())
            resume()
            receive('prepare-lock')
            assert not sidecar.exists()
            lock_key = hashlib.sha256((source_sha + ':' + ready['parserKey']).encode()).hexdigest()
            lock = (cache / '.locks' / (lock_key + '.lock')).open('r+b')
            fcntl.flock(lock, fcntl.LOCK_EX)
            resume()
            held = receive('lock-complete')
            assert int(held['queuedInputBytes']) > 1024 * 1024 and held['refunded'] == 'true'
            assert not sidecar.exists()
            fcntl.flock(lock, fcntl.LOCK_UN)
            lock.close()
            lock = None
            resume()
            receive('prepare-future')
            future = b'{"formatVersion":999,"traceSHA256":"future-original","opaque":"preserve me"}\n'
            sidecar.write_bytes(future)
            sidecar.chmod(0o600)
            resume()
            preserved = receive('future-complete')
            assert preserved['write'] == preserved['remove'] == 'preserved'
            assert sidecar.read_bytes() == future
            (base / 'future-original.json').write_bytes(future)
            # Restore this test's own valid format-1 bytes before asking for
            # empty-document removal. Future data is never overwritten by SDK.
            sidecar.write_bytes(raw)
            resume()
            final = receive('complete')
            assert final['afterEngineFacets'] == final['closedRejected'] == 'true'
            assert final['finalColdOwners'] == final['finalColdBytes'] == final['finalInputBytes'] == '0'
            assert int(final['uiTicks']) > 10
            process.wait(timeout=60)
            assert process.returncode == 0, (base / 'consumer.stderr').read_text()
            assert not sidecar.exists() and sha(database) == database_sha
            assert sha(base / 'source.htrace') == source_sha
            assert not list((base / 'namespace-ephemeral').rglob('trace.db'))
            report = dict(contractSHA256=receipt['contractSHA256'], artifactIdentity=artifact_identity,
                sourceSHA256=source_sha, databaseSHA256=database_sha, events=events,
                originalFuturePreserved=True, rawSourceUnchanged=True, databaseUnchanged=True,
                processExitCode=process.returncode, stderrSHA256=sha(base / 'consumer.stderr'))
            (base / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
            print(json.dumps(report, indent=2))
        finally:
            if lock is not None:
                fcntl.flock(lock, fcntl.LOCK_UN)
                lock.close()
            if process.poll() is None:
                process.kill()
                process.wait()
            (base / 'process-exit.json').write_text(json.dumps(dict(exitCode=process.returncode,
                stderrSHA256=sha(base / 'consumer.stderr')), indent=2) + '\n')


if __name__ == '__main__':
    main()
