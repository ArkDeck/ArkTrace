#!/usr/bin/env python3
"""Build an immutable local XCFramework from the pinned Rust static library.

This explicit development override is not a published binaryTarget URL and
never modifies an existing artifact with the same library identity.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
from stage_macos_rust_sdk import verified_receipt
ROOT = Path(__file__).resolve().parent.parent

def pin(p):
    b=p.read_bytes();return {'path':str(p),'byteCount':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def build(fixture=False):
    assert sys.platform=='darwin' and os.uname().machine=='arm64'
    xcode=subprocess.check_output(['xcodebuild','-version'],text=True).strip();assert xcode.startswith('Xcode 27.')
    subprocess.run([sys.executable,str(ROOT/'scripts/generate_ffi_bindings.py'),'--check'],check=True,stdout=sys.stderr)
    command=[sys.executable,str(ROOT/'scripts/run-cargo.py'),'build','-p','arktrace-ffi','--release']
    if fixture:command+=['--features','process-fixtures']
    with tempfile.TemporaryDirectory(prefix='sdk-staticlib-',dir='/private/tmp') as capture_folder:
        captured=Path(capture_folder)/'libarktrace_ffi.a'
        environment=os.environ.copy();environment['ARKTRACE_CARGO_CAPTURE_STATICLIB']=str(captured)
        subprocess.run(command,cwd=ROOT,env=environment,check=True,stdout=sys.stderr)
        library_bytes=captured.read_bytes()
        identity={'byteCount':len(library_bytes),'sha256':hashlib.sha256(library_bytes).hexdigest()}
    cache=Path(os.environ.get('ARKTRACE_RUST_SDK_CACHE_ROOT','/private/tmp/arktrace-rust-sdk-artifacts'))
    assert cache.is_absolute() and not cache.is_symlink() and not cache.resolve().is_relative_to(ROOT)
    cache=cache.resolve()
    cache.mkdir(parents=True,exist_ok=True)
    destination=cache/identity['sha256'];artifact=destination/'CArkTrace.xcframework'
    digest=(ROOT/'contracts/ffi-v1.sha256').read_text().strip()
    expected_headers=[pin(ROOT/'bindings/c'/n) for n in ['arktrace_ffi.h','module.modulemap']]
    if destination.exists():
        receipt,_=verified_receipt(artifact,fixture)
        assert receipt['library']==identity
        return artifact,receipt
    with tempfile.TemporaryDirectory(prefix='sdk-build-',dir=cache) as folder:
        base=Path(folder);headers=base/'headers';headers.mkdir()
        for n in ['arktrace_ffi.h','module.modulemap']:shutil.copyfile(ROOT/'bindings/c'/n,headers/n)
        copied=base/'libarktrace_ffi.a';copied.write_bytes(library_bytes);assert pin(copied)['sha256']==identity['sha256']
        subprocess.run(['xcodebuild','-create-xcframework','-library',str(copied),'-headers',str(headers),'-output',str(base/'CArkTrace.xcframework')],check=True,stdout=sys.stderr)
        info=plistlib.loads((base/'CArkTrace.xcframework/Info.plist').read_bytes())
        assert len(info['AvailableLibraries'])==1 and info['AvailableLibraries'][0]['SupportedArchitectures']==['arm64']
        assert info['AvailableLibraries'][0]['SupportedPlatform']=='macos'
        receipt={'abiVersion':1,'contractSHA256':digest,'developmentFixtures':fixture,'deploymentTarget':'26.0','xcode':xcode,'rust':subprocess.check_output(['rustc','+1.99.0','--version'],text=True).strip(),'library':identity,'headers':expected_headers,'files':[],'releaseAcceptance':False}
        for p in sorted((base/'CArkTrace.xcframework').rglob('*')):
            if p.is_file():receipt['files'].append({'byteCount':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'relativePath':p.relative_to(base).as_posix()})
        (base/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
        destination.mkdir(mode=0o700)
        shutil.move(str(base/'CArkTrace.xcframework'),artifact);shutil.copyfile(base/'receipt.json',destination/'receipt.json')
    return artifact,receipt
if __name__=='__main__':
    artifact,receipt=build('--fixtures' in sys.argv)
    print(json.dumps({'xcframework':str(artifact),'receipt':receipt},indent=2))
