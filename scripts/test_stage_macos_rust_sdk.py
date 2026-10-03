#!/usr/bin/env python3
"""Native artifact receipt/staging regressions; no compiled or signed claims."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from stage_macos_rust_sdk import ROOT, stage, verified_receipt

class NativeStageTests(unittest.TestCase):
    def artifact(self):
        temporary=self.enterContext(tempfile.TemporaryDirectory(dir='/private/tmp'))
        base=Path(temporary);artifact=base/'artifact/CArkTrace.xcframework';slice=artifact/'macos-arm64';headers=slice/'Headers';headers.mkdir(parents=True)
        (slice/'libarktrace_ffi.a').write_bytes(b'test archive; not native acceptance')
        for name in ('arktrace_ffi.h','module.modulemap'):(headers/name).write_bytes((ROOT/'bindings/c'/name).read_bytes())
        (artifact/'Info.plist').write_bytes(plistlib.dumps({'AvailableLibraries':[{'LibraryIdentifier':'macos-arm64','LibraryPath':'libarktrace_ffi.a','HeadersPath':'Headers','SupportedPlatform':'macos','SupportedArchitectures':['arm64']}]}))
        receipt={'abiVersion':1,'contractSHA256':(ROOT/'contracts/ffi-v1.sha256').read_text().strip(),'developmentFixtures':True,'deploymentTarget':'26.0','rust':'rustc 1.99.0 test','xcode':'Xcode 27.0','library':{'sha256':hashlib.sha256((slice/'libarktrace_ffi.a').read_bytes()).hexdigest()},'files':[]}
        for p in sorted(artifact.rglob('*')):
            if p.is_file():receipt['files'].append({'relativePath':p.relative_to(artifact.parent).as_posix(),'byteCount':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()})
        (artifact.parent/'receipt.json').write_text(json.dumps(receipt))
        workspace=base/'workspace';workspace.mkdir()
        return artifact,workspace,receipt
    def test_reuse_preserves_archive_identity_and_callback_relative_path(self):
        artifact,workspace,_=self.artifact()
        relative=stage(artifact,workspace,True);self.assertFalse(Path(relative).is_absolute())
        archive=workspace/relative/'macos-arm64/libarktrace_ffi.a';before=archive.stat()
        self.assertEqual(stage(artifact,workspace,True),relative)
        self.assertEqual(archive.stat().st_ino,before.st_ino)
        self.assertEqual(archive.stat().st_mtime_ns,before.st_mtime_ns)
    def test_wrong_contract_fixture_pin_and_changed_bytes_fail_before_staging(self):
        artifact,workspace,receipt=self.artifact()
        with self.assertRaisesRegex(ValueError,'configuration'):stage(artifact,workspace,False)
        receipt['contractSHA256']='0'*64;(artifact.parent/'receipt.json').write_text(json.dumps(receipt))
        with self.assertRaisesRegex(ValueError,'digest'):stage(artifact,workspace,True)
        receipt['contractSHA256']=(ROOT/'contracts/ffi-v1.sha256').read_text().strip();(artifact.parent/'receipt.json').write_text(json.dumps(receipt))
        (artifact/'macos-arm64/libarktrace_ffi.a').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError,'bytes'):stage(artifact,workspace,True)
        self.assertFalse((workspace/'.arktrace-native').exists())
    def test_extra_members_links_and_receipt_escape_are_rejected(self):
        artifact,_,receipt=self.artifact();extra=artifact/'extra';extra.write_text('unexpected')
        with self.assertRaisesRegex(ValueError,'membership'):verified_receipt(artifact,True)
        extra.unlink();extra.symlink_to(artifact/'Info.plist')
        with self.assertRaisesRegex(ValueError,'links'):verified_receipt(artifact,True)
        extra.unlink();receipt['files'][0]['relativePath']='../escape';(artifact.parent/'receipt.json').write_text(json.dumps(receipt))
        with self.assertRaisesRegex(ValueError,'escapes'):verified_receipt(artifact,True)
    def test_stage_cache_link_is_rejected_and_corruption_not_reused(self):
        artifact,workspace,_=self.artifact();link=workspace/'.arktrace-native';link.symlink_to(artifact.parent,target_is_directory=True)
        with self.assertRaisesRegex(ValueError,'link'):stage(artifact,workspace,True)
        link.unlink();relative=stage(artifact,workspace,True)
        (workspace/relative/'macos-arm64/libarktrace_ffi.a').write_bytes(b'bad staged bytes')
        with self.assertRaisesRegex(ValueError,'bytes'):stage(artifact,workspace,True)
    def test_plist_cannot_redirect_a_pinned_slice_outside_artifact(self):
        artifact,_,receipt=self.artifact()
        for field in ('LibraryIdentifier','LibraryPath','HeadersPath'):
            info=plistlib.loads((artifact/'Info.plist').read_bytes())
            original=info['AvailableLibraries'][0][field]
            info['AvailableLibraries'][0][field]='../outside'
            (artifact/'Info.plist').write_bytes(plistlib.dumps(info))
            entry=next(x for x in receipt['files'] if x['relativePath'].endswith('/Info.plist'))
            data=(artifact/'Info.plist').read_bytes()
            entry.update(byteCount=len(data),sha256=hashlib.sha256(data).hexdigest())
            (artifact.parent/'receipt.json').write_text(json.dumps(receipt))
            with self.assertRaisesRegex(ValueError,'slice path escapes'):verified_receipt(artifact,True)
            info['AvailableLibraries'][0][field]=original
            (artifact/'Info.plist').write_bytes(plistlib.dumps(info))
if __name__=='__main__':unittest.main()
