#!/usr/bin/env python3
"""Owner registration and evidence-preserving retirement for stable Cargo caches.

Registration never moves a source mirror or target. Retirement requires an
ended owner, a free runner lock, an unchanged plan and a verified full archive.
"""
import argparse
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tarfile
import time
import uuid

STATE = '.arktrace-cargo-owner.json'
SOURCE_PATHS = ('rust', 'contracts', 'ThirdParty/TraceStreamer/macx/manifest.json')
EVIDENCE_KINDS = {'source', 'manifest', 'lockfile', 'dependencyRecord', 'binary', 'log'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def owner_id(value):
    require(isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}', value) is not None,
            'owner must be one stable identifier, without path separators')
    return value


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def is_link(path):
    if path.is_symlink() or getattr(path, 'is_junction', lambda: False)():
        return True
    try:
        return bool(getattr(path.lstat(), 'st_file_attributes', 0) & getattr(stat, 'FILE_ATTRIBUTE_REPARSE_POINT', 0))
    except FileNotFoundError:
        return False


def external_path(path):
    require(path.is_absolute(), 'absolute external path required')
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        # macOS system aliases are canonicalized; user-created links are not.
        require(not is_link(current) or current in {Path('/tmp'), Path('/var')}, 'external path contains a link')
    return path.resolve()


def within(path, boundary):
    """Reject linked ancestors before any operation inside an owned tree."""
    require(path.is_relative_to(boundary), 'path escapes owned root')
    current = boundary
    require(not is_link(current), 'owned root must not be a link')
    for part in path.relative_to(boundary).parts:
        require(part not in {'.', '..'}, 'path escapes owned root')
        current /= part
        require(not is_link(current), 'owned path contains a link')
    require(path.resolve().is_relative_to(boundary.resolve()), 'path escapes owned root')


def regular_file(path, boundary=None):
    require(stat.S_ISREG(path.lstat().st_mode) and not is_link(path), 'regular file required: ' + str(path))
    if boundary is not None:
        within(path, boundary)


def row(path, name):
    regular_file(path)
    stat = path.stat()
    return dict(path=name, byteCount=stat.st_size, allocatedBytes=getattr(stat, 'st_blocks', 0) * 512,
                sha256=digest(path))


def git_environment():
    # Each snapshot must use its own repository and index, even when invoked
    # from a shell that has selected a different worktree explicitly.
    return {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}


def source_paths(root):
    require(root.is_absolute() and root.is_dir() and not is_link(root), 'absolute source directory required')
    root = root.resolve()
    environment = git_environment()
    top = subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], cwd=root, env=environment).decode().strip()
    require(Path(top).resolve() == root, 'source root must be an independent git top-level')
    return subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard', '--',
                                   *SOURCE_PATHS], cwd=root, env=environment).split(b'\0')


def source_identity(root):
    raw_paths = source_paths(root)
    root = root.resolve()
    rows = []
    for raw in sorted(set(raw_paths)):
        if not raw:
            continue
        relative = Path(os.fsdecode(raw))
        require(not relative.is_absolute() and '..' not in relative.parts, 'source path escapes root')
        path = root / relative
        if not path.exists():
            continue
        regular_file(path, root)
        rows.append(dict(path=relative.as_posix(), byteCount=path.stat().st_size, sha256=digest(path)))
    require(any(item['path'] == 'rust/Cargo.lock' for item in rows), 'source identity requires Cargo.lock')
    encoded = json.dumps(rows, sort_keys=True, separators=(',', ':')).encode()
    return dict(sourceRoot=str(root), sourceSHA256=hashlib.sha256(encoded).hexdigest(), files=rows)


def cache_root(path):
    require(path.is_absolute() and not is_link(path), 'absolute regular cache directory required')
    resolved = external_path(path)
    require(resolved not in {Path(resolved.anchor), Path.home().resolve(), Path('/private/tmp'), Path('/tmp').resolve()},
            'cache root is too broad')
    require(not resolved.exists() or resolved.is_dir(), 'cache root must be a directory')
    return resolved


def sync_directory(directory):
    # Directory flush is required before the archive becomes the only copy.
    # Windows support is deliberately unqualified until tested natively.
    require(os.name != 'nt', 'directory durability for retirement is not qualified on Windows')
    descriptor = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def atomic_json(path, value, durable=False):
    require(not is_link(path), 'metadata must not be a link')
    candidate = path.with_name(path.name + '.tmp-' + uuid.uuid4().hex)
    with candidate.open('x') as stream:
        json.dump(value, stream, indent=2); stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
    candidate.chmod(0o600)
    os.replace(candidate, path)
    if durable:
        sync_directory(path.parent)


def load_state(cache, owner):
    owner_id(owner)
    path = cache / STATE
    regular_file(path, cache)
    require(path.stat().st_size <= 1024 * 1024, 'owner record too large')
    state = json.loads(path.read_text())
    require(state['formatVersion'] == 1 and state['owner'] == owner and state['cacheRoot'] == str(cache.resolve()),
            'cache belongs to another owner or root')
    return state


def save_state(cache, state):
    atomic_json(cache / STATE, state)


@contextlib.contextmanager
def runner_lock(cache, wait=False, create=False):
    path = cache / 'runner.lock'
    within(path, cache)
    require(create or path.exists(), 'registered runner lock is missing')
    if path.exists():
        regular_file(path, cache)
    with path.open('a+b') as lock:
        deadline = time.monotonic() + (120 if wait else 0)
        while True:
            try:
                if os.name == 'nt':
                    import msvcrt
                    if path.stat().st_size == 0:
                        lock.write(b'\0'); lock.flush()
                    lock.seek(0); msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                require(wait and time.monotonic() < deadline, 'runner lock is active')
                time.sleep(0.1)
        try:
            yield
        finally:
            if os.name == 'nt':
                lock.seek(0); msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(lock, fcntl.LOCK_UN)


def tree_rows(root):
    require(not is_link(root), 'owned tree must not be a link')
    if not root.exists():
        return []
    require(root.is_dir(), 'owned tree must be a regular directory')
    rows = []
    for path in sorted(root.rglob('*')):
        within(path, root)
        if path.is_dir():
            require(path.resolve().is_relative_to(root.resolve()), 'directory escapes root')
        else:
            regular_file(path, root)
            rows.append(row(path, path.relative_to(root).as_posix()))
    return rows


def register(cache, owner, source_root, adopt_existing=False):
    cache = cache_root(cache); owner_id(owner)
    identity = source_identity(source_root)
    require(not cache.is_relative_to(source_root.resolve()) and not source_root.resolve().is_relative_to(cache),
            'cache and source root must be disjoint')
    cache.mkdir(parents=True, exist_ok=True)
    with runner_lock(cache, create=True):
        if (cache / STATE).exists():
            state = load_state(cache, owner)
            require(state['sourceRoot'] == identity['sourceRoot'], 'registered source root differs')
            return state
        existing = [path for path in cache.iterdir() if path.name != 'runner.lock']
        require(not existing or adopt_existing, 'existing cache requires explicit adopt-existing')
        tree_rows(cache / 'workspace'); tree_rows(cache / 'target')
        state = dict(formatVersion=1, owner=owner, cacheRoot=str(cache), sourceRoot=identity['sourceRoot'],
            registeredSourceSHA256=identity['sourceSHA256'], lifecycle='active', epoch=uuid.uuid4().hex,
            adoptedExisting=bool(existing))
        save_state(cache, state)
        return state


def rebind(cache, owner, source_root, expected_sha):
    """Explicitly switch one owner's source snapshot without moving its cache."""
    cache = cache_root(cache)
    identity = source_identity(source_root)
    require(identity['sourceSHA256'] == expected_sha, 'source rebind identity mismatch')
    require(not cache.is_relative_to(source_root.resolve()) and not source_root.resolve().is_relative_to(cache),
            'cache and source root must be disjoint')
    with runner_lock(cache):
        state = load_state(cache, owner)
        require(state['lifecycle'] == 'active', 'source rebind requires an active owner')
        state.update(sourceRoot=identity['sourceRoot'], registeredSourceSHA256=identity['sourceSHA256'], epoch=uuid.uuid4().hex)
        save_state(cache, state)
        return state


def transition(cache, owner, lifecycle):
    cache = cache_root(cache)
    with runner_lock(cache):
        state = load_state(cache, owner)
        require(lifecycle in {'active', 'ended'}, 'invalid lifecycle')
        require(state['lifecycle'] != 'retirementFailed', 'failed retirement requires manual recovery from its verified archive')
        state.update(lifecycle=lifecycle, epoch=uuid.uuid4().hex)
        save_state(cache, state)
        return state


def plan(cache, owner):
    cache = cache_root(cache)
    with runner_lock(cache):
        state = load_state(cache, owner)
        target = tree_rows(cache / 'target')
        source = tree_rows(cache / 'workspace')
        return dict(formatVersion=1, owner=owner, cacheRoot=str(cache), epoch=state['epoch'],
            lifecycle=state['lifecycle'], target=target, workspace=source,
            targetAllocatedBytes=sum(item['allocatedBytes'] for item in target),
            targetLogicalBytes=sum(item['byteCount'] for item in target), freeBytes=shutil.disk_usage(cache).free)


def validate_plan(cache, owner, expected):
    state = load_state(cache, owner)
    require(state['lifecycle'] == 'ended', 'owner must be explicitly ended before archive or retirement')
    require(expected['formatVersion'] == 1 and expected['owner'] == owner and expected['cacheRoot'] == str(cache)
            and expected['epoch'] == state['epoch'] and expected['lifecycle'] == 'ended', 'plan is stale or belongs to another owner')
    require(expected['target'] == tree_rows(cache / 'target') and expected['workspace'] == tree_rows(cache / 'workspace'),
            'target or source changed since plan')
    return state


def evidence_specification(specification, owner):
    require(specification['formatVersion'] == 1 and specification['producerEnded'] is True and specification['owner'] == owner,
            'completed producer evidence for this owner required')
    files = specification['files']
    require(isinstance(files, list) and len(files) <= 100000, 'bounded evidence file list required')
    require({item['kind'] for item in files} >= EVIDENCE_KINDS, 'source/manifest/lockfile/dependencyRecord/binary/log evidence required')
    require(len({item['path'] for item in files}) == len(files), 'evidence paths must be unique')
    for item in files:
        require(Path(item['path']).is_absolute() and item['kind'] in EVIDENCE_KINDS, 'absolute typed evidence required')
        require(re.fullmatch('[0-9a-f]{64}', item['sha256']) is not None and type(item['byteCount']) is int and item['byteCount'] >= 0,
                'evidence identity pin required')
    return files


def evidence_rows(path, owner):
    regular_file(path)
    require(path.stat().st_size <= 16 * 1024 * 1024, 'evidence manifest too large')
    specification = json.loads(path.read_text())
    files = evidence_specification(specification, owner)
    records = []
    for index, item in enumerate(files):
        original = Path(item['path'])
        require(original.is_absolute(), 'evidence paths must be absolute')
        regular_file(original)
        actual = row(original, 'evidence/' + str(index))
        require(actual['sha256'] == item['sha256'] and actual['byteCount'] == item['byteCount'], 'evidence identity mismatch')
        records.append(actual | dict(originalPath=str(original), kind=item['kind']))
    return records


def archive_directory(directory, cache, fresh=False):
    require(directory.is_absolute() and not is_link(directory), 'absolute regular archive directory required')
    directory = external_path(directory)
    require(not directory.is_relative_to(cache) and '.build' not in directory.parts and 'target' not in directory.parts,
            'archive must be outside compilation directories and this cache')
    if fresh:
        require(not directory.exists(), 'fresh archive directory required')
    else:
        require(directory.is_dir(), 'archive directory is missing')
    return directory


def identity_rows(rows):
    return {item['path']: (item['byteCount'], item['sha256']) for item in rows}


def verify_archive(directory):
    regular_file(directory / 'archive.json', directory)
    receipt = json.loads((directory / 'archive.json').read_text())
    require(receipt['formatVersion'] == 1 and receipt['directoryDurability'] == 'fsync', 'durable archive receipt required')
    plan = receipt['plan']
    require(plan['formatVersion'] == 1 and plan['lifecycle'] == 'ended' and
            all(receipt[key] == plan[key] for key in ('owner', 'cacheRoot', 'epoch')), 'archive plan binding mismatch')
    records = receipt['members']
    require(len(identity_rows(records)) == len(records), 'archive member paths must be unique')
    for prefix in ('workspace', 'target'):
        required = identity_rows([item | dict(path=prefix + '/' + item['path']) for item in plan[prefix]])
        require(len(required) == len(plan[prefix]), 'plan paths must be unique')
        actual = identity_rows([item for item in records if item['path'].startswith(prefix + '/')])
        require(required == actual, 'archive does not cover the full ' + prefix + ' plan')
    archive = directory / 'payload.tar.gz'
    regular_file(archive, directory)
    require(digest(archive) == receipt['archiveSHA256'], 'archive digest mismatch')
    with tarfile.open(archive, 'r:gz') as saved:
        members = saved.getmembers()
        require(len(members) == len(records), 'archive membership mismatch')
        metadata = {}
        for record, member in zip(records, members):
            require(member.isfile() and member.name == record['path'], 'archive member is not a regular pinned file')
            require(not Path(member.name).is_absolute() and '..' not in Path(member.name).parts, 'archive path escapes')
            require(member.size == record['byteCount'], 'archive member size mismatch')
            stream = saved.extractfile(member)
            h = hashlib.sha256()
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                h.update(chunk)
            require(h.hexdigest() == record['sha256'], 'archive member identity mismatch')
            if member.name in {'owner.json', 'evidence-manifest.json'}:
                require(member.size <= 16 * 1024 * 1024, 'archive metadata too large')
                metadata[member.name] = json.load(saved.extractfile(member))
        require(set(metadata) == {'owner.json', 'evidence-manifest.json'}, 'archive owner/evidence manifest missing')
        state = metadata['owner.json']
        require(state['formatVersion'] == 1 and state['lifecycle'] == 'ended' and
                all(state[key] == plan[key] for key in ('owner', 'cacheRoot', 'epoch')), 'archived owner binding mismatch')
        specification = evidence_specification(metadata['evidence-manifest.json'], receipt['owner'])
        required = {'evidence/' + str(i): (item['byteCount'], item['sha256']) for i, item in enumerate(specification)}
        actual = identity_rows([item for item in records if item['path'].startswith('evidence/')])
        require(required == actual, 'archive evidence manifest membership mismatch')
        allowed = set(required) | {'owner.json', 'evidence-manifest.json'}
        allowed |= {'workspace/' + item['path'] for item in plan['workspace']} | {'target/' + item['path'] for item in plan['target']}
        require({item['path'] for item in records} == allowed, 'archive has unexpected members')
    return receipt


def archive(cache, owner, expected, evidence_manifest, destination):
    cache = cache_root(cache)
    destination = archive_directory(destination, cache, fresh=True)
    with runner_lock(cache):
        state = validate_plan(cache, owner, expected)
        evidence = evidence_rows(evidence_manifest, owner)
        members = [(cache / 'workspace' / item['path'], item | dict(path='workspace/' + item['path'])) for item in expected['workspace']]
        members += [(cache / 'target' / item['path'], item | dict(path='target/' + item['path'])) for item in expected['target']]
        members += [(Path(item['originalPath']), item) for item in evidence]
        members += [(cache / STATE, row(cache / STATE, 'owner.json')), (evidence_manifest, row(evidence_manifest, 'evidence-manifest.json'))]
        destination.mkdir(parents=True, mode=0o700)
        with tarfile.open(destination / 'payload.tar.gz', 'w:gz', compresslevel=3) as saved:
            for original, record in members:
                data = original.read_bytes()
                require(len(data) == record['byteCount'] and hashlib.sha256(data).hexdigest() == record['sha256'], 'input changed during archive')
                member = tarfile.TarInfo(record['path']); member.size = len(data); member.mode = original.stat().st_mode & 0o777
                saved.addfile(member, io.BytesIO(data))
        receipt = dict(formatVersion=1, owner=owner, cacheRoot=str(cache), epoch=state['epoch'],
            plan=expected, members=[item for _, item in members], archiveSHA256=digest(destination / 'payload.tar.gz'),
            directoryDurability='fsync')
        with (destination / 'payload.tar.gz').open('rb') as stream:
            os.fsync(stream.fileno())
        atomic_json(destination / 'archive.json', receipt, durable=True)
        sync_directory(destination.parent)
        verified = verify_archive(destination)
        require(verified == receipt, 'archive readback mismatch')
        return receipt


def retire(cache, owner, directory):
    cache = cache_root(cache)
    directory = archive_directory(directory, cache)
    with runner_lock(cache):
        receipt = verify_archive(directory)
        state = validate_plan(cache, owner, receipt['plan'])
        require(receipt['owner'] == owner and receipt['cacheRoot'] == str(cache) and receipt['epoch'] == state['epoch'],
                'archive belongs to another owner or epoch')
        # Re-flush the verified durable files immediately before removing data.
        for name in ('payload.tar.gz', 'archive.json'):
            with (directory / name).open('rb') as stream:
                os.fsync(stream.fileno())
        sync_directory(directory); sync_directory(directory.parent)
        free_before = shutil.disk_usage(cache).free
        target = cache / 'target'
        if target.exists():
            retiring = cache / ('.retiring-target-' + uuid.uuid4().hex)
            target.rename(retiring)
            try:
                shutil.rmtree(retiring)
            except OSError:
                state.update(lifecycle='retirementFailed', epoch=uuid.uuid4().hex, residuePath=str(retiring), archiveRoot=str(directory))
                save_state(cache, state)
                raise
        state.update(lifecycle='retired', epoch=uuid.uuid4().hex)
        save_state(cache, state)
        result = dict(owner=owner, cacheRoot=str(cache), archiveSHA256=receipt['archiveSHA256'],
            retiredTargetAllocatedBytes=receipt['plan']['targetAllocatedBytes'],
            freeBytesBefore=free_before, freeBytesAfter=shutil.disk_usage(cache).free)
        atomic_json(directory / 'retirement.json', result, durable=True)
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest='command', required=True)
    identity = subcommands.add_parser('source-identity'); identity.add_argument('--source-root', type=Path, required=True)
    for command in ('register', 'rebind', 'activate', 'end', 'plan', 'archive', 'retire'):
        options = subcommands.add_parser(command)
        options.add_argument('--cache-root', type=Path, required=True); options.add_argument('--owner', required=True)
        if command == 'register':
            options.add_argument('--source-root', type=Path, required=True); options.add_argument('--adopt-existing', action='store_true')
        if command == 'rebind':
            options.add_argument('--source-root', type=Path, required=True); options.add_argument('--source-sha256', required=True)
        if command == 'plan':
            options.add_argument('--output', type=Path)
        if command == 'archive':
            options.add_argument('--plan', type=Path, required=True); options.add_argument('--evidence-manifest', type=Path, required=True)
            options.add_argument('--archive-dir', type=Path, required=True)
        if command == 'retire':
            options.add_argument('--archive-dir', type=Path, required=True)
    args = parser.parse_args()
    if args.command == 'source-identity': result = source_identity(args.source_root)
    elif args.command == 'register': result = register(args.cache_root, args.owner, args.source_root, args.adopt_existing)
    elif args.command == 'rebind': result = rebind(args.cache_root, args.owner, args.source_root, args.source_sha256)
    elif args.command in {'activate', 'end'}: result = transition(args.cache_root, args.owner, 'active' if args.command == 'activate' else 'ended')
    elif args.command == 'plan': result = plan(args.cache_root, args.owner)
    elif args.command == 'archive': result = archive(args.cache_root, args.owner, json.loads(args.plan.read_text()), args.evidence_manifest, args.archive_dir)
    else: result = retire(args.cache_root, args.owner, args.archive_dir)
    encoded = json.dumps(result, indent=2) + '\n'
    if args.command == 'plan' and args.output:
        require(not args.output.exists(), 'plan output must be fresh'); args.output.write_text(encoded)
    print(encoded, end='')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError, tarfile.TarError) as error:
        raise SystemExit('cargo-cache: ' + str(error)) from error
