#!/usr/bin/env python3
"""Exercise an ended native migration probe with a real fixed parser.

The legacy metadata/database and format-1 Swift sidecar are byte-preserved
inputs. Mutated conflict/future cases are explicit fixtures. No build occurs
here; SIGKILL cases exercise the native intent/sidecar publication boundaries.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def facts(path):
    result = []
    for child in [path, *sorted(path.rglob('*'))]:
        stat = child.lstat()
        assert not child.is_symlink()
        result.append(dict(path=str(child.relative_to(path)), mode=stat.st_mode, inode=stat.st_ino,
            device=stat.st_dev, byteCount=stat.st_size, mtimeNs=stat.st_mtime_ns,
            ctimeNs=stat.st_ctime_ns, sha256=sha(child) if child.is_file() else None))
    return result


def main():
    parser = argparse.ArgumentParser()
    for name in ('executable', 'build-receipt', 'helper', 'parser', 'source', 'old-metadata', 'old-database', 'old-sidecar', 'evidence-dir'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    assert sys.platform == 'darwin' and os.uname().machine == 'arm64'
    producer = json.loads(args.build_receipt.read_text())
    assert producer['exitCode'] == 0 and producer['finishedAtUnix']
    assert producer['argv'] == ['python3', 'scripts/run-cargo.py', 'build', '-p', 'arktrace-engine', '--example',
        'macos_legacy_view_state_probe', '--features', 'process-fixtures']
    base = args.evidence_dir.resolve()
    assert not base.exists()
    base.mkdir(mode=0o700)
    tools = base / 'tools'; tools.mkdir(mode=0o700)
    inputs = []
    for original, destination, mode in [
        (args.executable, tools / 'probe', 0o500), (args.helper, tools / 'helper', 0o500),
        (args.parser, tools / 'parser', 0o500), (args.source, base / 'source.htrace', 0o400),
        (args.old_metadata, base / 'old-metadata.json', 0o400), (args.old_database, base / 'old-database.sqlite', 0o400),
        (args.old_sidecar, base / 'old-view-state.json', 0o400), (args.build_receipt, base / 'build-receipt.json', 0o400),
        (ROOT / 'ThirdParty/TraceStreamer/macx/manifest.json', tools / 'source-manifest.json', 0o400)]:
        assert original.is_file() and not original.is_symlink()
        shutil.copyfile(original, destination); destination.chmod(mode)
        assert sha(original) == sha(destination)
        inputs.append(dict(sourcePath=str(original.resolve()), frozenPath=str(destination), byteCount=destination.stat().st_size, sha256=sha(destination)))
    (base / 'inputs.json').write_text(json.dumps(inputs, indent=2) + '\n')
    manifest = json.loads((tools / 'source-manifest.json').read_text())
    assert sha(tools / 'parser') == manifest['binarySHA256']
    identity = {k: manifest[k] for k in ('name', 'reportedVersion', 'binarySHA256', 'upstreamRepository',
        'upstreamRevision', 'architecture', 'adapterVersion', 'buildRecipeVersion')}
    identity_path = tools / 'identity.json'; identity_path.write_text(json.dumps(identity, indent=2) + '\n'); identity_path.chmod(0o400)
    metadata_bytes = (base / 'old-metadata.json').read_bytes()
    metadata = json.loads(metadata_bytes); original_sidecar = (base / 'old-view-state.json').read_bytes()
    sidecar = json.loads(original_sidecar)
    trace_sha = sha(base / 'source.htrace'); parser_key = metadata['cacheKey']['parserKey']
    assert metadata['sourceSHA256'] == metadata['traceSHA256'] == trace_sha == sidecar['traceSHA256']
    assert metadata['sourceByteCount'] == (base / 'source.htrace').stat().st_size
    assert metadata['databaseByteCount'] == (base / 'old-database.sqlite').stat().st_size
    assert metadata['parser'] == identity
    reports = []

    def create(name, raw=original_sidecar):
        case = base / name; case.mkdir(mode=0o700)
        legacy = case / 'legacy'; legacy.mkdir(mode=0o700)
        for part in ('.locks', '.leases', trace_sha): (legacy / part).mkdir(mode=0o700)
        entry = legacy / trace_sha / parser_key; entry.mkdir(mode=0o700)
        for name, data in [('metadata.json', metadata_bytes), ('view-state.json', raw)]:
            (entry / name).write_bytes(data); (entry / name).chmod(0o600)
        shutil.copyfile(base / 'old-database.sqlite', entry / 'database.sqlite'); (entry / 'database.sqlite').chmod(0o400)
        lock_key = hashlib.sha256((trace_sha + ':' + parser_key).encode()).hexdigest()
        for parent, suffix in [('.locks', 'lock'), ('.leases', 'lease')]:
            path = legacy / parent / (lock_key + '.' + suffix); path.touch(mode=0o600)
        return case

    def command(case, selection='-', point=0):
        return [str(tools / 'probe'), str(case), str(base / 'source.htrace'), str(identity_path),
            sha(tools / 'helper'), 'htrace', str(tools), selection, str(point)]

    def run(case, label, selection='-'):
        before = facts(case / 'legacy')
        output = subprocess.run(command(case, selection), capture_output=True, timeout=60)
        (case / (label + '.stdout')).write_bytes(output.stdout); (case / (label + '.stderr')).write_bytes(output.stderr)
        assert output.returncode == 0, output.stderr.decode(errors='replace')
        value = json.loads(output.stdout)
        assert value['rawTraceUnchanged'] and value['resourcesClosed'] and sha(base / 'source.htrace') == trace_sha
        assert facts(case / 'legacy') == before
        (case / (label + '.legacy-facts.json')).write_text(json.dumps(before, indent=2) + '\n')
        reports.append(dict(case=case.name, label=label, status=value['report']['status'], cacheHit=value['cacheHit'],
            stdoutSHA256=sha(case / (label + '.stdout')), stderrSHA256=sha(case / (label + '.stderr')),
            legacyUnchanged=True, rawTraceUnchanged=True, resourcesClosed=True))
        return value

    case = create('normal')
    first = run(case, 'cold'); assert not first['cacheHit'] and first['report']['status'] == 'imported'
    assert first['viewState']['status'] == 'restored'
    expected = dict(sidecar); expected['marks'] = [mark for mark in sidecar['marks'] if mark['isPersistent']]
    assert first['viewState']['document'] == expected
    assert run(case, 'warm')['report']['status'] == 'alreadyCompleted'
    entry = case / 'native' / trace_sha / parser_key
    (entry / 'view-state.json').unlink()
    cleared = run(case, 'cleared'); assert cleared['report']['status'] == 'alreadyCompleted' and cleared['viewState']['status'] == 'missing'

    for point in (1, 2):
        case = create('sigkill-' + str(point)); before = facts(case / 'legacy')
        with (case / 'interrupted.stdout').open('wb') as stdout, (case / 'interrupted.stderr').open('wb') as stderr:
            process = subprocess.Popen(command(case, point=point), stdout=stdout, stderr=stderr)
            try:
                marker = case / 'migration-backup' / ('development-window-' + str(process.pid) + '.json')
                deadline = time.monotonic() + 60
                while not marker.is_file():
                    assert process.poll() is None
                    assert time.monotonic() < deadline
                    time.sleep(0.025)
                assert json.loads(marker.read_text()) == dict(point=point, pid=process.pid)
                process.send_signal(signal.SIGKILL); process.wait(timeout=10); assert process.returncode == -signal.SIGKILL
                assert facts(case / 'legacy') == before
                assert not list((case / 'migration-backup/records').glob('*.completed.json'))
                record = dict(point=point, pid=process.pid, exitCode=process.returncode, legacyUnchanged=True)
                (case / 'interruption.json').write_text(json.dumps(record, indent=2) + '\n')
                # The real consumer reopens Ready and resumes the original
                # immutable intent. At point 2 it must not rewrite the sidecar.
                state = case / 'native' / trace_sha / parser_key / 'view-state.json'
                state_before = (state.stat().st_ino, state.stat().st_mtime_ns, sha(state)) if point == 2 else None
                assert point == 2 or not state.exists()
                resumed = run(case, 'resumed'); assert resumed['cacheHit'] and resumed['report']['status'] == 'imported'
                assert resumed['viewState']['document'] == expected
                if state_before: assert (state.stat().st_ino, state.stat().st_mtime_ns, sha(state)) == state_before
                assert run(case, 'resumed-again')['report']['status'] == 'alreadyCompleted'
            finally:
                if process.poll() is None: process.kill(); process.wait(timeout=10)

    case = create('future', b'{"formatVersion":999,"private":"keep raw"}')
    future = run(case, 'future'); assert future['report']['status'] == 'preservedSource'
    candidate = future['report']['sources'][0]; assert candidate['backedUp'] and candidate['sourceFormatVersion'] == 999
    assert (case / 'migration-backup/objects' / (candidate['sidecarSHA256'] + '.bytes')).read_bytes() == b'{"formatVersion":999,"private":"keep raw"}'
    assert future['viewState']['status'] == 'missing'
    result = dict(formatVersion=1, nativeHost='macOS arm64', sourceSHA256=trace_sha,
        parserSHA256=sha(tools / 'parser'), helperSHA256=sha(tools / 'helper'), probeSHA256=sha(tools / 'probe'),
        legacyMetadataSHA256=sha(base / 'old-metadata.json'), legacyDatabaseSHA256=sha(base / 'old-database.sqlite'),
        legacySidecarSHA256=sha(base / 'old-view-state.json'), cases=reports, actualSIGKILLWindows=[1, 2],
        legacyInputs='ended Swift cache metadata/database and committed actual Swift format-1 sidecar fixture',
        appAdapterConnected=False, windowsNativeAcceptance=False, fullMacOSAcceptance=False)
    (base / 'report.json').write_text(json.dumps(result, indent=2) + '\n'); print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
