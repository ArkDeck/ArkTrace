#!/usr/bin/env python3
"""Cache retirement must preserve a complete, durable and owner-bound archive."""
import copy
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import cargo_cache as cache


class CargoCacheTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.source = self.base / 'source'
        (self.source / 'rust/crates/example/src').mkdir(parents=True)
        (self.source / 'rust/Cargo.lock').write_text('version = 4\n')
        (self.source / 'rust/Cargo.toml').write_text('[workspace]\n')
        (self.source / 'rust/crates/example/src/lib.rs').write_text('pub fn original() {}\n')
        subprocess.run(['git', 'init', '-q', str(self.source)], check=True, env=cache.git_environment())
        subprocess.run(['git', 'add', '.'], cwd=self.source, check=True, env=cache.git_environment())
        self.root = self.base / 'cache'
        (self.root / 'workspace/rust').mkdir(parents=True)
        (self.root / 'workspace/rust/Cargo.lock').write_text('version = 4\n')
        (self.root / 'target/debug').mkdir(parents=True)
        (self.root / 'target/debug/product').write_bytes(b'actual product\0')
        (self.root / 'target/debug/product.d').write_text('actual dependency record')
        self.owner = 'owner-1'
        self.original_inodes = {p: p.stat().st_ino for p in [self.root / 'workspace', self.root / 'target', self.root / 'target/debug/product']}
        self.state = cache.register(self.root, self.owner, self.source, adopt_existing=True)
        self.original_inodes[self.root / 'runner.lock'] = (self.root / 'runner.lock').stat().st_ino
        self.evidence = self.base / 'evidence.json'
        files = []
        for kind in sorted(cache.EVIDENCE_KINDS):
            path = self.base / ('completed-' + kind)
            path.write_bytes(('preserved ' + kind).encode())
            files.append(dict(path=str(path), kind=kind, byteCount=path.stat().st_size, sha256=cache.digest(path)))
        self.evidence.write_text(json.dumps(dict(formatVersion=1, producerEnded=True, owner=self.owner, files=files)))
        self.destination = self.base / 'saved-evidence'

    def ended_plan(self):
        cache.transition(self.root, self.owner, 'ended')
        return cache.plan(self.root, self.owner)

    def assert_untouched(self):
        for path, inode in self.original_inodes.items():
            self.assertTrue(path.exists())
            self.assertEqual(path.stat().st_ino, inode)
        self.assertEqual((self.root / 'target/debug/product').read_bytes(), b'actual product\0')

    def make_archive(self):
        plan = self.ended_plan()
        return cache.archive(self.root, self.owner, plan, self.evidence, self.destination)

    def rewrite_archive(self, transform):
        # A self-consistent tar + receipt is still insufficient without its plan.
        with tarfile.open(self.destination / 'payload.tar.gz', 'r:gz') as saved:
            data = [(member.name, saved.extractfile(member).read()) for member in saved.getmembers()]
        receipt = json.loads((self.destination / 'archive.json').read_text())
        data, receipt = transform(data, receipt)
        with tarfile.open(self.destination / 'payload.tar.gz', 'w:gz') as saved:
            for name, contents in data:
                member = tarfile.TarInfo(name); member.size = len(contents)
                saved.addfile(member, io.BytesIO(contents))
        receipt['archiveSHA256'] = cache.digest(self.destination / 'payload.tar.gz')
        (self.destination / 'archive.json').write_text(json.dumps(receipt))

    def test_registration_is_in_place_and_foreign_owner_is_rejected(self):
        self.assertEqual(cache.register(self.root, self.owner, self.source), self.state)
        self.assert_untouched()
        with self.assertRaisesRegex(ValueError, 'another owner'):
            cache.register(self.root, 'foreign', self.source, True)
        self.assert_untouched()

    def test_existing_unregistered_cache_requires_explicit_adoption(self):
        other = self.base / 'unregistered'
        other.mkdir(); (other / 'output').write_text('keep')
        with self.assertRaisesRegex(ValueError, 'adopt-existing'):
            cache.register(other, self.owner, self.source)
        self.assertEqual((other / 'output').read_text(), 'keep')

    def test_git_root_and_index_environment_cannot_redirect_source_identity(self):
        actual = cache.source_identity(self.source)
        with patch.dict(os.environ, {'GIT_DIR': '/absent', 'GIT_WORK_TREE': '/foreign', 'GIT_INDEX_FILE': '/absent'}):
            self.assertEqual(cache.source_identity(self.source), actual)
        with self.assertRaisesRegex(ValueError, 'independent git top-level'):
            cache.source_identity(self.source / 'rust')

    def test_source_rebind_preserves_target_and_invalidates_old_plan(self):
        other = self.base / 'next-source'
        subprocess.run(['git', 'clone', '-q', '--no-local', str(self.source), str(other)], check=True, env=cache.git_environment(), stderr=subprocess.DEVNULL)
        # The fixture has no commit: copy just the actual owned files, keeping
        # the second repository's independently created Git index.
        import shutil
        shutil.copytree(self.source / 'rust', other / 'rust')
        subprocess.run(['git', 'add', '.'], cwd=other, check=True, env=cache.git_environment())
        old = cache.plan(self.root, self.owner)
        identity = cache.source_identity(other)
        self.assertEqual(identity['sourceSHA256'], self.state['registeredSourceSHA256'])
        new = cache.rebind(self.root, self.owner, other, identity['sourceSHA256'])
        self.assertNotEqual(new['epoch'], old['epoch'])
        self.assertEqual(new['sourceRoot'], str(other))
        self.assert_untouched()
        cache.transition(self.root, self.owner, 'ended')
        with self.assertRaisesRegex(ValueError, 'stale'):
            cache.validate_plan(self.root, self.owner, old)

    def test_active_or_locked_owner_cannot_archive_or_end(self):
        with self.assertRaisesRegex(ValueError, 'explicitly ended'):
            cache.archive(self.root, self.owner, cache.plan(self.root, self.owner), self.evidence, self.destination)
        with cache.runner_lock(self.root):
            for operation in [lambda: cache.plan(self.root, self.owner), lambda: cache.transition(self.root, self.owner, 'ended')]:
                with self.assertRaisesRegex(ValueError, 'lock is active'):
                    operation()
        self.assert_untouched()

    def test_plan_detects_changed_source_or_product(self):
        plan = self.ended_plan()
        (self.root / 'target/debug/product').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'changed since plan'):
            cache.archive(self.root, self.owner, plan, self.evidence, self.destination)
        self.assertFalse(self.destination.exists())

    def test_evidence_requires_complete_kinds_matching_pins_and_owner(self):
        original = json.loads(self.evidence.read_text())
        for mutation in [lambda x: x.update(owner='foreign'), lambda x: x.update(producerEnded=False),
                         lambda x: x['files'].pop(), lambda x: x['files'][0].update(sha256='0' * 64),
                         lambda x: x['files'].append(x['files'][0])]:
            invalid = copy.deepcopy(original); mutation(invalid); self.evidence.write_text(json.dumps(invalid))
            with self.assertRaises(ValueError):
                cache.archive(self.root, self.owner, self.ended_plan(), self.evidence, self.destination)
            self.assertFalse(self.destination.exists())
            self.assert_untouched()

    def test_linked_target_or_mirror_is_rejected(self):
        outside = self.base / 'outside'; outside.mkdir(); (outside / 'keep').write_text('keep')
        for root in [self.root / 'target', self.root / 'workspace']:
            link = root / 'escape'; link.symlink_to(outside, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, 'link'):
                cache.plan(self.root, self.owner)
            link.unlink()
        self.assertEqual((outside / 'keep').read_text(), 'keep')

    def test_missing_archive_cannot_retire(self):
        self.ended_plan()
        with self.assertRaisesRegex(ValueError, 'missing'):
            cache.retire(self.root, self.owner, self.destination)
        self.assert_untouched()

    def test_cache_and_archive_parent_links_are_rejected(self):
        outside = self.base / 'outside'; outside.mkdir()
        alias = self.base / 'alias'; alias.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'link'):
            cache.register(alias / 'cache', self.owner, self.source)
        with self.assertRaisesRegex(ValueError, 'link'):
            cache.archive(self.root, self.owner, self.ended_plan(), self.evidence, alias / 'archive')
        self.assertEqual(list(outside.iterdir()), [])
        self.assert_untouched()

    @unittest.skipIf(os.name == 'nt', 'directory durability awaits native Windows qualification')
    def test_complete_archive_readback_precedes_retirement(self):
        receipt = self.make_archive()
        self.assertEqual(cache.verify_archive(self.destination), receipt)
        self.assert_untouched()
        result = cache.retire(self.root, self.owner, self.destination)
        self.assertFalse((self.root / 'target').exists())
        self.assertTrue((self.root / 'workspace/rust/Cargo.lock').exists())
        self.assertEqual(result['archiveSHA256'], receipt['archiveSHA256'])
        self.assertEqual(cache.load_state(self.root, self.owner)['lifecycle'], 'retired')
        self.assertEqual(cache.verify_archive(self.destination), receipt)

    @unittest.skipIf(os.name == 'nt', 'directory durability awaits native Windows qualification')
    def test_truncated_but_self_consistent_archive_cannot_retire(self):
        self.make_archive()
        def remove(data, receipt):
            name = 'target/debug/product'
            return [(n, d) for n, d in data if n != name], receipt | dict(members=[r for r in receipt['members'] if r['path'] != name])
        self.rewrite_archive(remove)
        with self.assertRaisesRegex(ValueError, 'full target plan'):
            cache.retire(self.root, self.owner, self.destination)
        self.assert_untouched()

    @unittest.skipIf(os.name == 'nt', 'directory durability awaits native Windows qualification')
    def test_missing_evidence_from_self_consistent_archive_cannot_retire(self):
        self.make_archive()
        def remove(data, receipt):
            name = 'evidence/0'
            return [(n, d) for n, d in data if n != name], receipt | dict(members=[r for r in receipt['members'] if r['path'] != name])
        self.rewrite_archive(remove)
        with self.assertRaisesRegex(ValueError, 'evidence manifest membership'):
            cache.retire(self.root, self.owner, self.destination)
        self.assert_untouched()

    @unittest.skipIf(os.name == 'nt', 'directory durability awaits native Windows qualification')
    def test_corrupt_payload_and_compilation_directory_archive_are_rejected(self):
        self.make_archive()
        with (self.destination / 'payload.tar.gz').open('ab') as stream:
            stream.write(b'corruption')
        with self.assertRaisesRegex(ValueError, 'archive digest mismatch'):
            cache.retire(self.root, self.owner, self.destination)
        with self.assertRaisesRegex(ValueError, 'outside compilation'):
            cache.retire(self.root, self.owner, self.base / 'target/archive')
        self.assert_untouched()

    def test_directory_flush_failure_preserves_target(self):
        with patch.object(cache, 'sync_directory', side_effect=OSError('flush failed')):
            with self.assertRaisesRegex(OSError, 'flush failed'):
                self.make_archive()
        self.assert_untouched()

    @unittest.skipIf(os.name == 'nt', 'directory durability awaits native Windows qualification')
    def test_partial_retirement_failure_records_recoverable_residue(self):
        self.make_archive()
        with patch.object(cache.shutil, 'rmtree', side_effect=OSError('cannot unlink')):
            with self.assertRaisesRegex(OSError, 'cannot unlink'):
                cache.retire(self.root, self.owner, self.destination)
        state = cache.load_state(self.root, self.owner)
        self.assertEqual(state['lifecycle'], 'retirementFailed')
        self.assertTrue((Path(state['residuePath']) / 'debug/product').exists())
        self.assertEqual(cache.verify_archive(self.destination)['owner'], self.owner)
        with self.assertRaisesRegex(ValueError, 'manual recovery'):
            cache.transition(self.root, self.owner, 'active')


if __name__ == '__main__':
    unittest.main()
