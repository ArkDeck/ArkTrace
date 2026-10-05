#!/usr/bin/env python3
"""Run the ended package-external typed migration consumer on native macOS.

The consumer is built separately against the new immutable SDK artifact. All
fixtures, stdout/stderr, original facts and raw backups stay in evidence. No
historical Swift writer or Engine-only result substitutes for this transport.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from test_macos_legacy_view_state import facts
from stage_macos_rust_sdk import verified_receipt

ROOT = Path(__file__).resolve().parent.parent

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def main():
    parser = argparse.ArgumentParser()
    for name in ('executable', 'consumer-receipt', 'artifact', 'helper', 'parser', 'source', 'old-metadata', 'old-database', 'old-sidecar', 'evidence-dir'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    assert sys.platform == 'darwin' and os.uname().machine == 'arm64'
    receipt = json.loads(args.consumer_receipt.read_text())
    assert receipt['exitCode'] == 0 and receipt['finishedAtUnix']
    product = json.loads(args.consumer_receipt.with_name(args.consumer_receipt.name.replace('.receipt.json', '.stdout')).read_text())
    assert product['receipt']['viewStateMigrationExecutable']['sha256'] == sha(args.executable)
    artifact, artifact_identity = verified_receipt(args.artifact, True)
    assert product['receipt']['artifactIdentity'] == artifact_identity
    assert artifact['contractSHA256'] == sha(ROOT / 'contracts/ffi-v1.json')
    base = args.evidence_dir.resolve(); assert not base.exists(); base.mkdir(mode=0o700)
    tools = base / 'tools'; tools.mkdir(mode=0o700)
    inputs = []
    for source, destination, mode in [(args.executable, tools / 'consumer', 0o500), (args.helper, tools / 'helper', 0o500),
        (args.parser, tools / 'parser', 0o500), (args.source, base / 'source.htrace', 0o400),
        (args.old_metadata, base / 'old-metadata.json', 0o400), (args.old_database, base / 'old-database.sqlite', 0o400),
        (args.old_sidecar, base / 'old-view-state.json', 0o400), (args.consumer_receipt, base / 'consumer-build-receipt.json', 0o400)]:
        assert source.is_file() and not source.is_symlink()
        shutil.copyfile(source, destination); destination.chmod(mode); assert sha(source) == sha(destination)
        inputs.append(dict(sourcePath=str(source.resolve()), frozenPath=str(destination), byteCount=destination.stat().st_size, sha256=sha(destination)))
    (base / 'inputs.json').write_text(json.dumps(inputs, indent=2) + '\n')
    metadata_bytes = (base / 'old-metadata.json').read_bytes(); metadata = json.loads(metadata_bytes)
    sidecar_bytes = (base / 'old-view-state.json').read_bytes(); sidecar = json.loads(sidecar_bytes)
    manifest = json.loads((ROOT / 'ThirdParty/TraceStreamer/macx/manifest.json').read_text())
    identity = {k: manifest[k] for k in ('name', 'reportedVersion', 'binarySHA256', 'upstreamRepository', 'upstreamRevision', 'architecture', 'adapterVersion', 'buildRecipeVersion')}
    assert sha(tools / 'parser') == identity['binarySHA256']
    trace = sha(base / 'source.htrace'); parser_key = metadata['cacheKey']['parserKey']
    assert trace == metadata['traceSHA256'] == metadata['sourceSHA256'] == sidecar['traceSHA256']
    assert metadata['parser'] == identity and metadata['sourceByteCount'] == (base / 'source.htrace').stat().st_size
    events = []

    def source_entry(case, parser_key, raw=sidecar_bytes, meta=metadata_bytes):
        legacy = case / 'legacy'; legacy.mkdir(mode=0o700, exist_ok=True)
        for name in ('.locks', '.leases', trace): (legacy / name).mkdir(mode=0o700, exist_ok=True)
        entry = legacy / trace / parser_key; entry.mkdir(mode=0o700)
        for name, data in [('metadata.json', meta), ('view-state.json', raw)]:
            (entry / name).write_bytes(data); (entry / name).chmod(0o600)
        shutil.copyfile(base / 'old-database.sqlite', entry / 'database.sqlite'); (entry / 'database.sqlite').chmod(0o400)
        lock = hashlib.sha256((trace + ':' + parser_key).encode()).hexdigest()
        for root, suffix in [('.locks', '.lock'), ('.leases', '.lease')]: (legacy / root / (lock + suffix)).touch(mode=0o600)
        return entry

    def create(name, legacy=True, raw=sidecar_bytes):
        case = base / name; case.mkdir(mode=0o700)
        for name in ('native', 'staging'): (case / name).mkdir(mode=0o700)
        if legacy: source_entry(case, parser_key, raw)
        return case

    def run(case, name, selection=None, configured=True, ephemeral=False, failure=False, initial=None, cancel=False):
        before = facts(case / 'legacy') if (case / 'legacy').exists() else None
        value = dict(source=str(base / 'source.htrace'), namespace=str(case / 'staging'), cacheDirectory=str(case / 'native'),
            helper=str(tools / 'helper'), parser=str(tools / 'parser'), helperSHA256=sha(tools / 'helper'), parserIdentity=identity,
            legacyCacheDirectory=str(case / 'legacy') if configured else None, backupDirectory=str(case / 'backup') if configured else None,
            selection=selection, ephemeral=ephemeral, migrationFailureExpected=failure, initialDocument=initial, cancelWhileBlocked=cancel)
        config = case / (name + '.input.json'); config.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
        process = subprocess.run([str(tools / 'consumer'), str(config)], capture_output=True, timeout=120)
        (case / (name + '.stdout')).write_bytes(process.stdout); (case / (name + '.stderr')).write_bytes(process.stderr)
        result = dict(case=case.name, name=name, exitCode=process.returncode, stdoutSHA256=sha(case / (name + '.stdout')), stderrSHA256=sha(case / (name + '.stderr')))
        events.append(result); (base / 'events.json').write_text(json.dumps(events, indent=2) + '\n')
        assert process.returncode == 0, process.stderr.decode(errors='replace')
        output = json.loads(process.stdout)
        assert output['resourcesClosed'] and output['nativeResultBytesAfterClose'] == 0 and output['retainedReportReadableAfterShutdown']
        assert sha(base / 'source.htrace') == trace and str(case) not in process.stdout.decode()
        if before is not None: assert before == facts(case / 'legacy')
        else: assert not (case / 'legacy').exists()
        result.update(status=output.get('report', {}).get('status'), legacyUnchanged=True, rawTraceUnchanged=True, resourcesClosed=True)
        if before is not None: (case / (name + '.legacy-facts.json')).write_text(json.dumps(before, indent=2) + '\n')
        (base / 'events.json').write_text(json.dumps(events, indent=2) + '\n')
        return output

    case = create('normal'); first = run(case, 'cold')
    assert not first['cacheHit'] and first['report']['status'] == 'imported' and first['viewStateStatus'] == 'restored'
    assert first['flags'] == sidecar['flags']
    expected_marks = [dict(id=v['id'], startNs=v['range']['startNs'], endNs=v['range']['endNs'], label=v['label'], colorIndex=v['colorIndex'], isPersistent=True) for v in sidecar['marks'] if v['isPersistent']]
    assert first['marks'] == expected_marks and first.get('favorites') == sidecar.get('favoriteTrackIDs')
    descriptor = first['report']['candidates'][0]
    assert descriptor['exactParserIdentity'] and descriptor['flagCount'] == len(sidecar['flags']) and descriptor['persistentMarkCount'] == len(expected_marks)
    objects = case / 'backup/objects'
    assert (objects / (sha(base / 'old-metadata.json') + '.bytes')).read_bytes() == metadata_bytes
    assert (objects / (sha(base / 'old-view-state.json') + '.bytes')).read_bytes() == sidecar_bytes
    assert run(case, 'warm')['report']['status'] == 'alreadyCompleted'
    # IO failure is nonfatal to Ready and still restores existing native state.
    native_state = case / 'native' / trace / parser_key / 'view-state.json'
    native_before = native_state.read_bytes()
    (case / 'backup').chmod(0o755)
    try:
        failed = run(case, 'nonprivate-backup', failure=True)
        assert failed['failureCode'] and failed['viewStateStatus'] == 'restored' and failed['flags'] == sidecar['flags']
        assert native_state.read_bytes() == native_before
    finally: (case / 'backup').chmod(0o700)
    (case / 'native' / trace / parser_key / 'view-state.json').unlink()
    assert run(case, 'cleared')['viewStateStatus'] == 'missing'
    run(case, 'no-profile', configured=False)
    case = create('missing-legacy', legacy=False); assert run(case, 'missing')['report']['status'] == 'missing'
    assert not (case / 'backup').exists()
    case = create('ephemeral', legacy=False); assert run(case, 'ephemeral', configured=False, ephemeral=True)['report']['status'] == 'sessionScoped'
    case = create('future', raw=b'{"formatVersion":999,"private":"keep raw"}')
    future = run(case, 'future'); assert future['report']['status'] == 'preservedSource' and future['viewStateStatus'] == 'missing'
    assert future['report']['sources'][0]['sourceFormatVersion'] == 999 and future['report']['sources'][0]['backedUp']
    case = create('conflict')
    other = json.loads(metadata_bytes); other['parser']['binarySHA256'] = 'f' * 64
    material = b'ArkTrace.Cache.ParserKey.v1'
    for field in [other['parser']['binarySHA256'], other['parser']['upstreamRevision'], other['schemaAdapterVersion'], str(other['indexSchemaVersion'])]:
        data = field.encode(); material += len(data).to_bytes(8, 'big') + data
    other_key = hashlib.sha256(material).hexdigest()
    other['cacheKey']['parserKey'] = other_key
    other['cacheKey']['parserBinarySHA256'] = other['parser']['binarySHA256']
    second = dict(sidecar); second['flags'] = [dict(sidecar['flags'][0], label='second parser 🦀')]
    source_entry(case, other_key, json.dumps(second, ensure_ascii=False).encode(), json.dumps(other).encode())
    conflict = run(case, 'conflict'); assert conflict['report']['status'] == 'conflict' and len(conflict['report']['candidates']) == 2 and conflict['viewStateStatus'] == 'missing'
    invalid = run(case, 'invalid-selection', selection='0'*64)
    assert invalid['report']['status'] == 'invalidSelection' and invalid['viewStateStatus'] == 'missing'
    selected = next(v['snapshotIdentifier'] for v in conflict['report']['candidates'] if not v['exactParserIdentity'])
    chosen = run(case, 'selected', selection=selected)
    assert chosen['report']['status'] == 'imported' and chosen['flags'] == second['flags']
    assert chosen['report']['unmatchedFavoriteTrackIDs'] == second.get('favoriteTrackIDs', []) and chosen.get('favorites') is None
    assert run(case, 'completed-other-selection', selection=descriptor['snapshotIdentifier'])['report']['status'] == 'alreadyCompleted'
    case = create('destination-kept')
    changed = dict(sidecar['flags'][0], label='new native annotation 🦀')
    document = dict(traceSHA256=trace, flags=[changed], marks=[], favoriteTrackIDs=['cpu:0', 'cpu:0', 'missing\0🦀'])
    kept = run(case, 'kept', initial=document)
    assert kept['report']['status'] == 'destinationKept' and kept['flags'] == [changed] and kept['favorites'] == document['favoriteTrackIDs']
    assert run(case, 'kept-again')['report']['status'] == 'alreadyCompleted'
    case = create('sdk-blocked-cancel')
    lock_name = hashlib.sha256((trace + ':' + parser_key).encode()).hexdigest() + '.lock'
    with (case / 'legacy/.locks' / lock_name).open('rb') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        cancelled = run(case, 'cancelled', cancel=True)
        assert cancelled['failureCode'] == 'CANCELLED' and cancelled['viewStateStatus'] == 'missing'
        assert not list((case / 'backup/records').glob('*.intent.json'))
        fcntl.flock(lock, fcntl.LOCK_UN)
    assert run(case, 'after-cancel')['report']['status'] == 'imported'
    print(json.dumps(dict(nativeMacOSTypedMigrationTransport=True, appMigrationAcceptance=False, freshSwiftWriter=False,
        contractSHA256=artifact['contractSHA256'], sdkArtifactIdentity=artifact_identity, cases=events), ensure_ascii=False, indent=2))

if __name__ == '__main__': main()
