#!/usr/bin/env python3
"""Native public BACKUP conformance using explicit, already-produced binaries.

Adapted from the reviewed A7/N7/A8/N8 probes. Each invocation creates a new
private fixture; failures and original outputs remain available for inspection.
No hidden Cargo build, Ready copying, budget changes, or production hooks.
"""
import argparse
import ctypes as C
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import threading
import time

from ffi_test_support import ABI, K, ROOT
from rollback_conformance import report_checks as checks


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def facts(path):
    path = Path(path)
    if not path.exists() and not path.is_symlink():
        return []
    members = [path]
    if path.is_dir() and not path.is_symlink():
        members += sorted(path.rglob('*'))
    rows = []
    for item in members:
        s = item.lstat()
        row = dict(path=str(item.relative_to(path)), mode=stat.S_IMODE(s.st_mode),
                   device=s.st_dev, inode=s.st_ino, mtimeNs=s.st_mtime_ns, ctimeNs=s.st_ctime_ns)
        if item.is_symlink():
            row['link'] = os.readlink(item)
        elif item.is_file():
            row.update(byteCount=s.st_size, sha256=sha(item))
        rows.append(row)
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('library', 'helper', 'parser', 'source', 'evidence-dir'):
        parser.add_argument('--' + name, required=True, type=Path)
    args = parser.parse_args()
    assert sys.platform == 'darwin' and os.uname().machine == 'arm64'
    base = args.evidence_dir.resolve()
    base.mkdir(mode=0o700)  # Never reuse a failed attempt or its cache.
    tools = base / 'tools'
    tools.mkdir(mode=0o700)
    pins = []
    for original, target, mode in [(args.library, tools / 'library.dylib', 0o500),
                                   (args.helper, tools / 'helper', 0o500),
                                   (args.parser, tools / 'parser', 0o500),
                                   (args.source, base / 'source.htrace', 0o400)]:
        shutil.copyfile(original, target)
        target.chmod(mode)
        assert sha(original) == sha(target)
        pins.append(dict(original=str(original.resolve()), copied=str(target), sha256=sha(target)))
    (base / 'inputs.json').write_text(json.dumps(pins, indent=2) + '\n')
    abi = ABI(tools / 'library.dylib')
    identity = abi.out('abi_identity', 'AbiIdentity')
    contract = sha(ROOT / 'contracts/ffi-v1.json')
    assert identity.abi_version == 1 and identity.capabilities == 191
    assert bytes(identity.contract_digest).hex() == contract
    manifest = json.loads((ROOT / 'ThirdParty/TraceStreamer/macx/manifest.json').read_text())
    assert sha(tools / 'parser') == manifest['binarySHA256']
    parser_identity = {k: manifest[k] for k in ('name', 'reportedVersion', 'binarySHA256',
        'upstreamRepository', 'upstreamRevision', 'architecture', 'adapterVersion', 'buildRecipeVersion')}
    trace = sha(base / 'source.htrace')
    cache = base / 'traces'
    cache.mkdir(mode=0o700)
    events, engines, protections = [], [], []
    event_lock = threading.Lock()

    def event(name, **value):
        with event_lock:
            row = dict(name=name, monotonicNs=time.monotonic_ns(), **value)
            events.append(row)
            with (base / 'events.jsonl').open('a') as stream:
                stream.write(json.dumps(row, ensure_ascii=False) + '\n')

    class Engine:
        def __init__(self, label, backup):
            self.session, self.requests, self.owners = None, set(), set()
            self.label, self.backup = label, backup
            namespace = base / ('namespace-' + label)
            namespace.mkdir(mode=0o700)
            config = dict(abiVersion=1, contractDigest=contract, cachePolicy='contentAddressed',
                cacheDirectory=str(cache), namespace=str(namespace), helper=str(tools / 'helper'),
                parser=str(tools / 'parser'), helperSHA256=sha(tools / 'helper'), parserIdentity=parser_identity,
                viewStateBackup=dict(backupDirectory=str(backup)),
                limits=dict(workers=1, queuePerWorker=8))
            (base / (label + '-config.json')).write_text(json.dumps(config, indent=2) + '\n')
            self.handle = abi.input('engine_create_fixture', config, 'u64').value
            engines.append(self)

        def acquire(self, request, name, retain=False, backup=False):
            status = abi.wait(self.handle, request)
            view = abi.out('result_acquire', 'ResultView', self.handle, request)
            self.owners.add(view.owner)
            raw = C.string_at(view.data, view.length)
            (base / (name + '.json')).write_bytes(raw)
            value = json.loads(raw)
            assert value['formatVersion'] == 1 and value['request'] == request
            assert value['session'] == status.session
            assert view.kind == (K['RESULT_SUCCESS'] if status.state == K['REQUEST_SUCCEEDED'] else K['RESULT_FAILURE'])
            event(name, engine=self.handle, session=status.session, request=request,
                  state=status.state, code=status.code, stage=status.stage, resultSHA256=hashlib.sha256(raw).hexdigest())
            if backup and status.state == K['REQUEST_SUCCEEDED']:
                checks.validate_envelope(raw, checks.Identity(self.handle, self.session, request), self.handle, trace, key['parserKey'])
            if status.state == K['REQUEST_FAILED']:
                assert all(path not in raw for path in [str(base).encode(), b'/Users/', b'/private/'])
            abi.call('request_release', self.handle, request)
            self.requests.remove(request)
            if not retain:
                abi.call('result_release', view.owner)
                self.owners.remove(view.owner)
            return value['body'], status, view, raw

        def submit(self, operation, payload=None, expected=0):
            buffer = None if payload is None else (C.c_uint8 * len(payload)).from_buffer_copy(payload)
            request = abi.out('view_state_request_submit', 'u64', self.handle, self.session,
                operation, buffer, 0 if payload is None else len(payload), 60_000, expected=expected).value
            if expected == 0:
                self.requests.add(request)
            if buffer is not None:
                C.memset(buffer, 0, len(payload))
            return request

        def request(self, operation, name, payload=None, backup=False):
            return self.acquire(self.submit(operation, payload), name, backup=backup)

        def open(self, expected_hit):
            data = str(base / 'source.htrace').encode()
            buffer = (C.c_uint8 * len(data)).from_buffer_copy(data)
            ticket = abi.out('session_open', 'OpenTicket', self.handle, buffer, len(data), 1, 60_000)
            C.memset(buffer, 0, len(data))
            self.session = ticket.session
            self.requests.add(ticket.request)
            body, status, _, _ = self.acquire(ticket.request, self.label + '-open')
            assert status.state == K['REQUEST_SUCCEEDED'] and body['cacheHit'] is expected_hit
            assert body['metadata']['traceSHA256'] == trace
            return body['metadata']['cacheKey']

        def close_session(self):
            if self.session is None:
                return
            abi.call('session_close', self.handle, self.session)
            deadline = time.monotonic() + 10
            while True:
                state = abi.out('session_poll', 'SessionStatus', self.handle, self.session)
                if state.resources_closed:
                    assert state.state == K['SESSION_CLOSED'] and not state.failure_present
                    break
                assert time.monotonic() < deadline
                time.sleep(.001)
            abi.call('session_release', self.handle, self.session)
            self.session = None

        def counters(self):
            deadline = time.monotonic() + 10
            while True:
                result = dict(resultBytes=abi.out('engine_retained_result_bytes', 'u64', self.handle).value,
                    inputBytes=abi.out('engine_retained_view_state_input_bytes', 'u64', self.handle).value)
                if not any(result.values()):
                    event(self.label + '-zero-public-budgets', **result)
                    return result
                assert time.monotonic() < deadline, result
                time.sleep(.001)

        def close(self):
            if not self.handle:
                return
            for request in self.requests:
                abi.call('request_cancel', self.handle, request)
            self.close_session()
            abi.drain(self.handle)
            for request in self.requests:
                abi.call('request_release', self.handle, request)
            self.requests.clear()
            for owner in self.owners:
                abi.call('result_release', owner)
            self.owners.clear()
            self.counters()
            abi.call('engine_release', self.handle)
            self.handle = None

    def protect(path):
        protections.append((path, facts(path)))

    def check_protected():
        for path, before in protections:
            assert facts(path) == before, str(path)

    def bundle(report, document, backup):
        receipt = report['receipt']
        checks.validate_receipt(receipt, trace, key['parserKey'])
        directory = backup / 'rollback' / receipt['backupIdentifier']
        assert stat.S_IMODE(directory.stat().st_mode) == 0o700
        assert sorted(p.name for p in directory.iterdir()) == ['receipt.json', 'view-state.json']
        assert all(stat.S_IMODE(p.stat().st_mode) == 0o400 for p in directory.iterdir())
        assert json.loads((directory / 'receipt.json').read_bytes()) == receipt
        checks.verify_document((directory / 'view-state.json').read_bytes(), receipt, document)
        return directory

    failure = None
    completed = []
    key = None
    try:
        first = Engine('first', base / 'backup')
        key = first.open(False)
        ready = cache / trace / key['parserKey']
        protect(base / 'source.htrace')
        protect(ready / 'trace.sqlite')
        body, status, _, _ = first.request(K['VIEW_STATE_BACKUP'], 'missing-backup', backup=True)
        assert status.state == K['REQUEST_SUCCEEDED'] and body == dict(status='missing', receipt=None)
        document = dict(formatVersion=1, traceSHA256=trace,
            flags=[dict(id=-7, timestampNs=2**63-1, label='中文 🦀 e\u0301\0', colorIndex=-2)],
            marks=[dict(id=9, range=dict(startNs=0, endNs=1), label='kept', colorIndex=2, isPersistent=True),
                   dict(id=9, range=dict(startNs=1, endNs=2), label='transient', colorIndex=1, isPersistent=False)],
            favoriteTrackIDs=None)
        expected = {**document, 'marks': document['marks'][:1]}
        payload = json.dumps(document, ensure_ascii=False, separators=(',', ':')).encode()
        assert first.request(K['VIEW_STATE_WRITE'], 'write-nil', payload)[0] == 'saved'
        report, status, _, _ = first.request(K['VIEW_STATE_BACKUP'], 'first-backup', backup=True)
        assert status.state == K['REQUEST_SUCCEEDED'] and report['status'] == 'backedUp'
        baseline = bundle(report, expected, first.backup)
        protect(baseline)
        retry, _, _, _ = first.request(K['VIEW_STATE_BACKUP'], 'retry-backup', backup=True)
        assert retry == dict(status='alreadyBackedUp', receipt=report['receipt'])
        completed.append('closed-receipt-nil-original-values-idempotent')

        lock_name = hashlib.sha256((trace + ':' + key['parserKey']).encode()).hexdigest() + '.lock'
        with (cache / '.locks' / lock_name).open('rb') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            blocker = first.submit(K['VIEW_STATE_READ'])
            deadline = time.monotonic() + 10
            while abi.out('request_poll', 'PollStatus', first.handle, blocker).state != K['REQUEST_RUNNING']:
                assert time.monotonic() < deadline
                time.sleep(.001)
            pending = first.submit(K['VIEW_STATE_BACKUP'])
            assert abi.out('engine_retained_view_state_input_bytes', 'u64', first.handle).value == K['MAXIMUM_RETAINED_VIEW_STATE_INPUT_BYTES']
            first.submit(K['VIEW_STATE_BACKUP'], expected=K['STATUS_CAPACITY'])
            first.submit(K['VIEW_STATE_WRITE'], b'0', expected=K['STATUS_CAPACITY'])
            abi.call('request_cancel', first.handle, pending)
            fcntl.flock(lock, fcntl.LOCK_UN)
        first.acquire(blocker, 'budget-blocker')
        cancelled, state, _, _ = first.acquire(pending, 'queued-backup-cancelled')
        assert state.state == K['REQUEST_FAILED'] and cancelled['code'] == 'CANCELLED'
        first.counters()
        check_protected()
        completed.append('queued-cancel-full-logical-reservation-capacity-refund')

        # Retain actual native result bytes after Session close and Engine drain.
        body, _, retained, original = first.acquire(first.submit(K['VIEW_STATE_BACKUP']), 'retained-backup', retain=True, backup=True)
        first.close_session()
        abi.drain(first.handle)
        assert C.string_at(abi.out('result_view', 'ResultView', retained.owner).data, len(original)) == original
        abi.call('result_release', retained.owner)
        first.owners.remove(retained.owner)
        first.close()
        completed.append('result-readable-after-session-close-and-engine-drain')

        # Each target is exclusively this invocation's private fixture. Never
        # rewrite a bundle after its native admission attempt.
        cases = ['extra', 'foreign-receipt', 'missing-receipt', 'corrupt-payload', 'corrupt-receipt',
                 'bundle-link', 'payload-link', 'writable-payload', 'nonprivate-bundle', 'nonprivate-root']
        sentinel = base / 'sentinel'
        shutil.copytree(baseline, sentinel)
        sentinel.chmod(0o700)
        for file in sentinel.iterdir():
            file.chmod(0o400)
        protect(sentinel)
        for case in cases:
            backup = base / ('backup-' + case)
            destination = backup / 'rollback' / baseline.name
            destination.parent.mkdir(parents=True, mode=0o700)
            backup.chmod(0o700)
            if case == 'bundle-link':
                destination.symlink_to(sentinel, target_is_directory=True)
            else:
                shutil.copytree(baseline, destination)
                destination.chmod(0o700)
                for file in destination.iterdir():
                    file.chmod(0o400)
                target = None
                if case == 'extra':
                    (destination / 'foreign').write_bytes(b'keep')
                elif case == 'missing-receipt':
                    (destination / 'receipt.json').unlink()
                elif case in ['foreign-receipt', 'corrupt-receipt', 'corrupt-payload']:
                    target = destination / ('view-state.json' if case == 'corrupt-payload' else 'receipt.json')
                    data = b'{' if case != 'foreign-receipt' else json.dumps({**report['receipt'], 'traceSHA256': '0' * 64}).encode()
                    target.chmod(0o600)
                    target.write_bytes(data)
                    target.chmod(0o400)
                elif case == 'payload-link':
                    (destination / 'view-state.json').unlink()
                    (destination / 'view-state.json').symlink_to(sentinel / 'view-state.json')
                elif case == 'writable-payload':
                    (destination / 'view-state.json').chmod(0o600)
                elif case == 'nonprivate-bundle':
                    destination.chmod(0o755)
                elif case == 'nonprivate-root':
                    backup.chmod(0o755)
            unknown = destination.parent / '.staging' / 'unknown'
            unknown.mkdir(parents=True, mode=0o700)
            unknown.parent.chmod(0o700)
            (unknown / 'sentinel').write_bytes(b'keep unknown staging')
            protect(destination)
            protect(unknown)
            engine = Engine(case, backup)
            assert engine.open(True) == key
            error, state, _, _ = engine.request(K['VIEW_STATE_BACKUP'], case + '-failure')
            assert state.state == K['REQUEST_FAILED']
            assert error['code'] == 'QUERY_FAILED' and error['stage'] == 'querying' and error['details'] == {}
            check_protected()
            engine.close()
        completed.append('ten-foreign-incomplete-linked-writable-targets-preserved')

        replacement = Engine('held-root', base / 'backup-held-root')
        assert replacement.open(True) == key
        original_report, state, _, _ = replacement.request(K['VIEW_STATE_BACKUP'], 'held-root-first-backup', backup=True)
        assert state.state == K['REQUEST_SUCCEEDED'] and original_report['status'] == 'backedUp'
        bundle(original_report, expected, replacement.backup)
        moved = base / 'moved-held-root'
        replacement.backup.rename(moved)
        replacement.backup.mkdir(mode=0o700)
        (replacement.backup / 'foreign-sentinel').write_bytes(b'preserve replacement root')
        protect(moved)
        protect(replacement.backup)
        error, state, _, _ = replacement.request(K['VIEW_STATE_BACKUP'], 'held-root-replacement-failure')
        assert state.state == K['REQUEST_FAILED']
        assert error['code'] == 'QUERY_FAILED' and error['stage'] == 'querying' and error['details'] == {}
        check_protected()
        replacement.close()
        completed.append('held-root-replacement-rejected-original-and-foreign-root-preserved')

        second = Engine('second', base / 'backup')
        assert second.open(True) == key
        # Independent engines submit the same newly saved document. Request
        # overlap is possible; this does not prove an internal critical-section race.
        third = Engine('third', base / 'backup')
        assert third.open(True) == key
        for number in range(3):
            concurrent = {**expected, 'favoriteTrackIDs': ['cpu:0', 'cpu:0', 'e\u0301'],
                'flags': [{**expected['flags'][0], 'label': str(number) + '中文 🦀' + 'x' * 3072} for _ in range(384)]}
            encoded = json.dumps(concurrent, ensure_ascii=False, separators=(',', ':')).encode()
            assert second.request(K['VIEW_STATE_WRITE'], 'concurrent-write-' + str(number), encoded)[0] == 'saved'
            barrier = threading.Barrier(2)
            results, errors = [], []
            def export(engine):
                try:
                    barrier.wait(timeout=10)
                    value = engine.request(K['VIEW_STATE_BACKUP'], engine.label + '-concurrent-' + str(number), backup=True)
                    results.append(value)
                except BaseException as error:
                    errors.append(error)
            workers = [threading.Thread(target=export, args=(engine,)) for engine in [second, third]]
            for worker in workers:
                worker.start()
            for worker in workers:
                worker.join(timeout=70)
            assert not errors and all(not worker.is_alive() for worker in workers), errors
            assert sorted(value[0]['status'] for value in results) == ['alreadyBackedUp', 'backedUp']
            assert results[0][0]['receipt'] == results[1][0]['receipt']
            protect(bundle(results[0][0], concurrent, second.backup))
            second.counters()
            third.counters()
            check_protected()
        completed.append('three-independent-engine-idempotent-publication-rounds')
        third.close()

        def purge(engine, label):
            request = abi.out('cache_request_submit', 'u64', engine.handle, K['CACHE_PURGE_UNUSED'], 60_000).value
            engine.requests.add(request)
            body, state, _, _ = engine.acquire(request, label)
            assert state.state == K['REQUEST_SUCCEEDED']
            return body
        active = purge(second, 'active-purge')
        assert active['removedEntryCount'] == 0 and active['skippedActiveEntryCount'] == 1
        check_protected()
        second.close_session()
        closed = purge(second, 'closed-purge')
        assert closed['removedEntryCount'] == 1 and closed['skippedActiveEntryCount'] == 0
        assert not ready.exists()
        # Ready removal is requested by this private test; rollback files remain.
        protections[:] = [(path, value) for path, value in protections if path != ready / 'trace.sqlite']
        check_protected()
        second.close()
        fourth = Engine('fourth', base / 'backup')
        assert fourth.open(False) == key
        assert fourth.request(K['VIEW_STATE_READ'], 'post-purge-read')[0] == dict(status='missing')
        check_protected()
        fourth.close()
        completed.append('active-purge-skips-closed-purge-removes-backups-survive-reparse-no-auto-restore')
    except BaseException as error:
        failure = dict(type=type(error).__name__, message=str(error))
        raise
    finally:
        cleanup = []
        for engine in engines:
            try:
                engine.close()
            except BaseException as error:
                cleanup.append(dict(engine=engine.label, error=str(error)))
        report = dict(passed=failure is None and not cleanup, completed=completed, failure=failure,
            cleanupFailures=cleanup, contractSHA256=contract, logicalReservationBytes=K['MAXIMUM_RETAINED_VIEW_STATE_INPUT_BYTES'],
            RSSMeasured=False, publicationCriticalSectionRaceProven=False, defaultAppOrFullMacOSAcceptance=False,
            inputPins=pins, executionSourceSHA256=sha(__file__))
        (base / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps(report, ensure_ascii=False))
        if cleanup and failure is None:
            raise RuntimeError(cleanup)


if __name__ == '__main__':
    main()
