#!/usr/bin/env python3
"""Actual fixed-parser sidecar ABI; caller supplies freshly frozen binaries.

No Cargo producer is hidden in this harness. Evidence and original bytes stay
in the requested private directory, including on failure. Development fixture
identity is explicit; this does not attest a default App or release package.
"""
import argparse
import ctypes as C
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import time
from ffi_test_support import ABI, K, ROOT


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    for name in ('library', 'helper', 'parser', 'source', 'evidence-dir'):
        parser.add_argument('--' + name, required=True, type=Path)
    args = parser.parse_args()
    assert sys.platform == 'darwin' and os.uname().machine == 'arm64'
    base = args.evidence_dir.resolve()
    base.mkdir(mode=0o700)
    tools = base / 'tools'
    tools.mkdir(mode=0o700)
    inputs = []
    for source, destination, mode in [(args.library, tools / 'library.dylib', 0o500),
                                      (args.helper, tools / 'helper', 0o500),
                                      (args.parser, tools / 'parser', 0o500),
                                      (args.source, base / 'source.htrace', 0o400)]:
        shutil.copyfile(source, destination)
        destination.chmod(mode)
        assert sha(source) == sha(destination)
        inputs.append(dict(sourcePath=str(source.resolve()), frozenPath=str(destination),
                           sha256=sha(destination), bytes=destination.stat().st_size, mode=oct(mode)))
    (base / 'input-manifest.json').write_text(json.dumps(inputs, indent=2) + '\n')
    abi = ABI(tools / 'library.dylib')
    identity = abi.out('abi_identity', 'AbiIdentity')
    assert identity.capabilities == 127  # native capabilities plus explicit fixtures
    assert bytes(identity.contract_digest).hex() == sha(ROOT / 'contracts/ffi-v1.json')
    manifest = json.loads((ROOT / 'ThirdParty/TraceStreamer/macx/manifest.json').read_text())
    assert sha(tools / 'parser') == manifest['binarySHA256']
    parser_identity = {k: manifest[k] for k in ('name', 'reportedVersion', 'binarySHA256',
                      'upstreamRepository', 'upstreamRevision', 'architecture', 'adapterVersion', 'buildRecipeVersion')}
    source_hash = sha(base / 'source.htrace')
    events, engines, held_owners = [], [], []

    def event(name, **facts):
        row = dict(name=name, **facts)
        events.append(row)
        with (base / 'events.jsonl').open('a') as out:
            out.write(json.dumps(row, ensure_ascii=False) + '\n')

    def create(name, cached=True):
        namespace = base / name
        namespace.mkdir(mode=0o700)
        cache = base / 'cache'
        if cached:
            cache.mkdir(mode=0o700, exist_ok=True)
        config = dict(abiVersion=1, contractDigest=bytes(identity.contract_digest).hex(),
                      cachePolicy='contentAddressed' if cached else 'ephemeral', namespace=str(namespace),
                      helper=str(tools / 'helper'), parser=str(tools / 'parser'), helperSHA256=sha(tools / 'helper'),
                      parserIdentity=parser_identity, limits=dict(workers=1, queuePerWorker=8))
        if cached:
            config['cacheDirectory'] = str(cache)
        engine = abi.input('engine_create_fixture', config, 'u64').value
        engines.append(engine)
        return engine

    def result(engine, request, name, retain=False):
        view, raw = abi.result(engine, request)
        (base / (name + '.json')).write_bytes(raw)
        envelope = json.loads(raw)
        assert envelope['formatVersion'] == 1 and envelope['request'] == request
        abi.call('request_release', engine, request)
        if not retain:
            abi.call('result_release', view.owner)
        return envelope, view, raw

    def open_session(engine, name):
        data = str(base / 'source.htrace').encode()
        array = (C.c_uint8 * len(data)).from_buffer_copy(data)
        ticket = abi.out('session_open', 'OpenTicket', engine, array, len(data), 1, 60_000)
        C.memset(array, 0, len(data))
        value, _, _ = result(engine, ticket.request, name)
        assert value['session'] == ticket.session and value['body']['metadata']['traceSHA256'] == source_hash
        event(name, session=ticket.session, cacheHit=value['body']['cacheHit'])
        return ticket.session, value['body']

    def submit(engine, session, operation, payload=None, expected=0, timeout=60_000):
        array = None if payload is None else (C.c_uint8 * len(payload)).from_buffer_copy(payload)
        handle = abi.out('view_state_request_submit', 'u64', engine, session, operation,
                         array, 0 if payload is None else len(payload), timeout, expected=expected).value
        if array is not None:
            C.memset(array, 0, len(payload))
        return handle

    def read(engine, session, name, retain=False):
        value, view, raw = result(engine, submit(engine, session, K['VIEW_STATE_READ']), name, retain)
        assert value['session'] == session
        return value['body'], view, raw

    def write(engine, session, document, name):
        raw = json.dumps(document, ensure_ascii=False, separators=(',', ':')).encode()
        (base / (name + '-input.json')).write_bytes(raw)
        value, _, _ = result(engine, submit(engine, session, K['VIEW_STATE_WRITE'], raw), name)
        assert value['session'] == session
        return value['body'], len(raw)

    def wait_zero(engine):
        deadline = time.monotonic() + 10
        while abi.out('engine_retained_view_state_input_bytes', 'u64', engine).value:
            assert time.monotonic() < deadline
            time.sleep(.001)

    def failed(engine, request, name):
        status = abi.wait(engine, request)
        assert status.state == K['REQUEST_FAILED']
        view = abi.out('result_acquire', 'ResultView', engine, request)
        assert view.kind == K['RESULT_FAILURE']
        raw = C.string_at(view.data, view.length)
        (base / (name + '.json')).write_bytes(raw)
        value = json.loads(raw)
        assert value['request'] == request
        abi.call('result_release', view.owner)
        abi.call('request_release', engine, request)
        return value['body']

    def close(engine, session):
        abi.call('session_close', engine, session)
        deadline = time.monotonic() + 10
        while True:
            status = abi.out('session_poll', 'SessionStatus', engine, session)
            if status.resources_closed:
                assert status.state == K['SESSION_CLOSED'] and not status.failure_present
                break
            assert time.monotonic() < deadline
            time.sleep(.001)
        abi.call('session_release', engine, session)

    try:
        engine = create('native')
        session, opened = open_session(engine, 'cold-open')
        second, warm = open_session(engine, 'second-open')
        assert not opened['cacheHit'] and warm['cacheHit']
        metadata = opened['metadata']
        key = metadata['cacheKey']
        ready = base / 'cache' / key['traceSHA256'] / key['parserKey']
        database = ready / 'trace.sqlite'
        assert database.exists(), list(ready.iterdir())
        database_hash = sha(database)
        assert read(engine, session, 'missing')[0] == dict(status='missing')
        document = dict(formatVersion=1, traceSHA256=source_hash,
                        flags=[dict(id=-2**63, timestampNs=2**63-1, label='保存\0🦀e\u0301', colorIndex=-2**63)],
                        marks=[dict(id=2**63-1, range=dict(startNs=0, endNs=0), label='kept', colorIndex=-1, isPersistent=True),
                               dict(id=-2, range=dict(startNs=1, endNs=2), label='transient', colorIndex=0, isPersistent=False)],
                        favoriteTrackIDs=['cpu:0', 'cpu:0', '线程 🦀'])
        saved, _ = write(engine, session, document, 'save')
        assert saved == 'saved'
        expected = {**document, 'marks': document['marks'][:1]}
        assert read(engine, second, 'dual-session-restore')[0] == dict(status='restored', document=expected)
        large = {**expected, 'favoriteTrackIDs': ['x' * 4096] * 512}
        saved, raw_count = write(engine, session, large, 'larger-than-query-cap-save')
        assert saved == 'saved' and K['MAXIMUM_REQUEST_BYTES'] < raw_count <= K['MAXIMUM_VIEW_STATE_BYTES']
        body, retained, retained_raw = read(engine, session, 'large-restore', retain=True)
        assert body == dict(status='restored', document=large)
        clone = abi.out('result_clone', 'u64', retained.owner).value
        held_owners.append(clone)
        abi.call('result_release', retained.owner)
        assert C.string_at(abi.out('result_view', 'ResultView', clone).data, len(retained_raw)) == retained_raw
        event('large-original-transport', inputBytes=raw_count, normalQueryCap=K['MAXIMUM_REQUEST_BYTES'])
        wait_zero(engine)
        sidecar = ready / 'view-state.json'
        original = sidecar.read_bytes()
        for index, invalid in enumerate([b'{', b'\xff', b'null', b'{"formatVersion":1,"formatVersion":1}',
                                        json.dumps({**expected, 'traceSHA256': 'b' * 64}).encode(),
                                        json.dumps({**expected, 'path': 'foreign'}).encode(),
                                        json.dumps({**expected, 'favoriteTrackIDs': ['x'] * 4097}).encode()]):
            error = failed(engine, submit(engine, session, K['VIEW_STATE_WRITE'], invalid), f'invalid-{index}')
            assert error['code'] == 'INVALID_ARGUMENT' and error['stage'] == 'request'
            assert sidecar.read_bytes() == original
        event('invalid-original-preserved', cases=7, beforeSHA256=hashlib.sha256(original).hexdigest())
        close(engine, second)
        close(engine, session)
        session, reopened = open_session(engine, 'reopened')
        assert reopened['cacheHit'] and read(engine, session, 'reopened-restore')[0] == dict(status='restored', document=large)
        removed, _, _ = result(engine, submit(engine, session, K['VIEW_STATE_REMOVE']), 'explicit-remove')
        assert removed['body'] == 'removed' and not sidecar.exists()

        # Actual same-key lock contention keeps the owner worker occupied while
        # four exact-cap documents occupy the input quota. Caller buffers are
        # zeroed immediately after admission; cancellation drains copied inputs.
        key_lock = base / 'cache/.locks' / (hashlib.sha256((key['traceSHA256'] + ':' + key['parserKey']).encode()).hexdigest() + '.lock')
        assert key_lock.exists(), list((base / 'cache/.locks').iterdir())
        with key_lock.open('rb') as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            blocker = submit(engine, session, K['VIEW_STATE_READ'])
            deadline = time.monotonic() + 10
            while abi.out('request_poll', 'PollStatus', engine, blocker).state != K['REQUEST_RUNNING']:
                assert time.monotonic() < deadline
                time.sleep(.001)
            small = json.dumps(expected, ensure_ascii=False, separators=(',', ':')).encode()
            exact = small + b' ' * (K['MAXIMUM_VIEW_STATE_BYTES'] - len(small))
            pending = [submit(engine, session, K['VIEW_STATE_WRITE'], exact) for _ in range(4)]
            assert abi.out('engine_retained_view_state_input_bytes', 'u64', engine).value == K['MAXIMUM_RETAINED_VIEW_STATE_INPUT_BYTES']
            submit(engine, session, K['VIEW_STATE_WRITE'], b'0', expected=K['STATUS_CAPACITY'])
            for request in pending:
                abi.call('request_cancel', engine, request)
            fcntl.flock(held, fcntl.LOCK_UN)
        assert result(engine, blocker, 'lock-blocker')[0]['body'] == dict(status='missing')
        for index, request in enumerate(pending):
            assert failed(engine, request, f'queued-cancel-{index}')['code'] == 'CANCELLED'
        wait_zero(engine)
        assert not sidecar.exists()
        event('actual-input-quota-cancellation', admitted=4, bytes=K['MAXIMUM_RETAINED_VIEW_STATE_INPUT_BYTES'], refused=1, refunded=0)
        # Exact byte cap accepts original whitespace without shrinking policy.
        value, _, _ = result(engine, submit(engine, session, K['VIEW_STATE_WRITE'], exact), 'exact-cap-save')
        assert value['body'] == 'saved'
        assert read(engine, session, 'exact-cap-restore')[0] == dict(status='restored', document=expected)
        empty = dict(formatVersion=1, traceSHA256=source_hash, flags=[], marks=[], favoriteTrackIDs=[])
        assert write(engine, session, empty, 'empty-remove')[0] == 'removed'
        future = b'{"formatVersion":999,"foreign":"keep-original"}'
        sidecar.write_bytes(future)
        sidecar.chmod(0o600)
        assert read(engine, session, 'future-read')[0] == dict(status='preserved')
        assert write(engine, session, expected, 'future-save')[0] == 'preserved'
        assert result(engine, submit(engine, session, K['VIEW_STATE_REMOVE']), 'future-remove')[0]['body'] == 'preserved'
        assert sidecar.read_bytes() == future
        event('future-original-preserved', sha256=sha(sidecar), write='preserved', remove='preserved')
        assert sha(database) == database_hash and sha(base / 'source.htrace') == source_hash
        close(engine, session)

        ephemeral = create('ephemeral', cached=False)
        scoped, _ = open_session(ephemeral, 'ephemeral-open')
        assert read(ephemeral, scoped, 'ephemeral-read')[0] == dict(status='sessionScoped')
        assert write(ephemeral, scoped, expected, 'ephemeral-write')[0] == 'sessionScoped'
        assert result(ephemeral, submit(ephemeral, scoped, K['VIEW_STATE_REMOVE']), 'ephemeral-remove')[0]['body'] == 'sessionScoped'
        close(ephemeral, scoped)
        abi.drain(ephemeral)
        wait_zero(ephemeral)
        abi.call('engine_release', ephemeral)
        engines.remove(ephemeral)

        # A genuine drain while a worker waits for key EX cancels its input and
        # drops pending commands before the engine reports resources drained.
        session, _ = open_session(engine, 'drain-open')
        with key_lock.open('rb') as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            blocker = submit(engine, session, K['VIEW_STATE_READ'])
            pending = submit(engine, session, K['VIEW_STATE_WRITE'], exact)
            abi.call('engine_drain', engine)
            fcntl.flock(held, fcntl.LOCK_UN)
        abi.drain(engine)
        for request, name in [(blocker, 'drain-blocker'), (pending, 'drain-pending')]:
            assert failed(engine, request, name)['code'] == 'CANCELLED'
        assert abi.out('engine_retained_view_state_input_bytes', 'u64', engine).value == 0
        abi.call('session_release', engine, session)
        abi.call('engine_release', engine)
        engines.remove(engine)
        retained_view = abi.out('result_view', 'ResultView', clone)
        assert retained_view.kind == K['RESULT_SUCCESS'] and retained_view.length == len(retained_raw)
        assert C.string_at(retained_view.data, retained_view.length) == retained_raw
        abi.call('result_release', clone)
        held_owners.remove(clone)
        event('result-owner-survives-request-session-and-engine-release', bytes=len(retained_raw), retainedBytes=retained_view.retained_bytes)
        poisoned = create('poisoned')
        scoped, _ = open_session(poisoned, 'poisoned-open')
        with key_lock.open('rb') as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            blocker = submit(poisoned, scoped, K['VIEW_STATE_READ'])
            pending = submit(poisoned, scoped, K['VIEW_STATE_WRITE'], exact)
            abi.call('fixture_panic', poisoned, expected=K['STATUS_INTERNAL'])
            submit(poisoned, scoped, K['VIEW_STATE_WRITE'], exact, expected=K['STATUS_POISONED'])
            fcntl.flock(held, fcntl.LOCK_UN)
        abi.drain(poisoned)
        for request, name in [(blocker, 'poisoned-blocker'), (pending, 'poisoned-pending')]:
            assert failed(poisoned, request, name)['code'] == 'CANCELLED'
        assert abi.out('engine_retained_view_state_input_bytes', 'u64', poisoned).value == 0
        assert sidecar.read_bytes() == future
        abi.call('session_release', poisoned, scoped)
        abi.call('engine_release', poisoned)
        engines.remove(poisoned)
        event('panic-containment-refunds-input', refusedAfterPoison=True, remainingInputBytes=0)
        report = dict(contractSHA256=bytes(identity.contract_digest).hex(), capabilities=identity.capabilities,
                      sourceSHA256=source_hash, databaseSHA256=database_hash, events=events,
                      inputBudgetRefunded=True, nativeEngineAcceptance=False, defaultAppAcceptance=False)
        (base / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    finally:
        for owner in held_owners:
            abi.call('result_release', owner)
        for engine in engines:
            abi.drain(engine)
            abi.call('engine_release', engine)


if __name__ == '__main__':
    main()
