#!/usr/bin/env python3
"""Real native library / generated records / Swift or C# admission smoke."""
import ctypes as C
from contextlib import nullcontext
import hashlib
import json
import os
import random
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from ffi_test_support import ABI, CONTRACT, K, ROOT, TYPES

def main():
    subprocess.run([sys.executable,str(ROOT/'scripts/generate_ffi_bindings.py'),'--check'],check=True)
    def cargo(*args):
        return subprocess.check_output([sys.executable,str(ROOT/'scripts/run-cargo.py'),*args],cwd=ROOT,text=True)
    cargo('build','-p','arktrace-ffi')
    target=Path(json.loads(cargo('metadata','--format-version','1','--no-deps'))['target_directory'])/'debug'
    name='arktrace_ffi.dll' if sys.platform=='win32' else 'libarktrace_ffi.dylib' if sys.platform=='darwin' else 'libarktrace_ffi.so'
    library=target/name;abi=ABI(library)
    layouts=json.loads((ROOT/'bindings/ffi-layouts.json').read_text())
    fields=0
    for r in layouts:
        typ=TYPES[r['name']];assert C.sizeof(typ)==r['size'] and C.alignment(typ)==r['alignment']
        for name,offset in r['offsets'].items():assert getattr(typ,name).offset==offset;fields+=1
    identity=abi.out('abi_identity','AbiIdentity');expected=hashlib.sha256((ROOT/'contracts/ffi-v1.json').read_bytes()).digest()
    assert bytes(identity.contract_digest)==expected and identity.abi_version==CONTRACT['abiVersion']
    assert identity.capabilities==(183 if sys.platform=='darwin' else 0)
    abi.call('abi_identity',None,C.sizeof(identity),expected=K['STATUS_INVALID_BUFFER'])
    abi.call('abi_identity',C.byref(identity),0,expected=K['STATUS_INVALID_BUFFER'])
    storage=(C.c_uint64*8)();bad=C.cast(C.byref(storage,1),C.POINTER(TYPES['AbiIdentity']))
    abi.call('abi_identity',bad,C.sizeof(identity),expected=K['STATUS_INVALID_BUFFER'])
    for name in ('engine_drain','engine_release','result_release','fixture_panic'):
        abi.call(name,2**64-1,expected=K['STATUS_INVALID_HANDLE'])
    request=C.c_uint64()
    abi.call('cache_request_submit',2**64-1,K['CACHE_INVENTORY'],1,C.byref(request),C.sizeof(request),expected=K['STATUS_INVALID_HANDLE'])
    # A nonzero stale engine is rejected by the common panic guard first.
    # Zero bypasses that lookup so these exercise scalar/buffer validation.
    for operation in (0,4,2**32-1):
        abi.call('cache_request_submit',0,operation,1,C.byref(request),C.sizeof(request),expected=K['STATUS_INVALID_INPUT'])
    abi.call('cache_request_submit',0,K['CACHE_INVENTORY'],0,C.byref(request),C.sizeof(request),expected=K['STATUS_INVALID_INPUT'])
    abi.call('cache_request_submit',0,K['CACHE_INVENTORY'],1,None,C.sizeof(request),expected=K['STATUS_INVALID_BUFFER'])
    # Dedicated sidecar transport keeps normal query bounds unchanged. All
    # rejected input ranges use actual live allocations, never invalid pointers.
    assert K['MAXIMUM_REQUEST_BYTES']==1048576 and K['MAXIMUM_VIEW_STATE_BYTES']==4194304
    abi.call('view_state_request_submit',2**64-1,0,K['VIEW_STATE_READ'],None,0,1,C.byref(request),C.sizeof(request),expected=K['STATUS_INVALID_HANDLE'])
    for operation in (0,6,2**32-1):
        abi.call('view_state_request_submit',0,0,operation,None,0,1,C.byref(request),C.sizeof(request),expected=K['STATUS_INVALID_INPUT'])
    payload=(C.c_uint8*1)(0)
    for operation in (K['VIEW_STATE_READ'],K['VIEW_STATE_REMOVE'],K['VIEW_STATE_BACKUP']):
        abi.call('view_state_request_submit',0,0,operation,payload,0,1,C.byref(request),C.sizeof(request),expected=K['STATUS_INVALID_BUFFER'])
        abi.call('view_state_request_submit',0,0,operation,None,1,1,C.byref(request),C.sizeof(request),expected=K['STATUS_INVALID_BUFFER'])
    for pointer,length in ((None,1),(payload,0)):
        abi.call('view_state_request_submit',0,0,K['VIEW_STATE_WRITE'],pointer,length,1,C.byref(request),C.sizeof(request),expected=K['STATUS_INVALID_BUFFER'])
    oversize=(C.c_uint8*(K['MAXIMUM_VIEW_STATE_BYTES']+1))()
    abi.call('view_state_request_submit',0,0,K['VIEW_STATE_WRITE'],oversize,len(oversize),1,C.byref(request),C.sizeof(request),expected=K['STATUS_INVALID_BUFFER'])
    # Bounded arbitrary bytes are valid allocations, never dangling pointers.
    for payload in (b'{}',b'null',b'[]',b'\xff',b'{"sql":"SELECT *"}'):
        abi.input('engine_create',payload,'u64',expected=K['STATUS_INVALID_INPUT'])
    randomizer=random.Random(0xA7F1)
    for _ in range(1000):
        payload=randomizer.randbytes(randomizer.randrange(1,512))
        abi.input('engine_create',payload,'u64',expected=K['STATUS_INVALID_INPUT'])
    # Every byte in the rejected oversize buffer is genuinely allocated.
    abi.input('engine_create',b'x'*(K['MAXIMUM_CONFIG_BYTES']+1),'u64',expected=K['STATUS_INVALID_BUFFER'])
    consumer={}
    retained=os.environ.get('ARKTRACE_FFI_CONSUMER_EVIDENCE_DIR')
    if retained:
        Path(retained).mkdir(mode=0o700)
    with (nullcontext(retained) if retained else tempfile.TemporaryDirectory(prefix='arktrace-ffi-consumer-')) as folder:
        base=Path(folder)
        if sys.platform=='darwin':
            assert subprocess.check_output(['xcodebuild','-version'],text=True).startswith('Xcode 27.')
            subprocess.run(['xcrun','clang','-x','c','-std=c11','-Wall','-Werror','-fsyntax-only','-I',str(ROOT/'bindings/c'),'-'],input='#include "arktrace_ffi.h"\n',text=True,check=True)
            executable=base/'swift-smoke'
            subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library','-warnings-as-errors','-module-cache-path',str(base/'modules'),'-target','arm64-apple-macos26.0','-I',str(ROOT/'bindings/c'),str(ROOT/'bindings/swift/Smoke.swift'),str(ROOT/'bindings/swift/GeneratedLayouts.swift'),str(target/'libarktrace_ffi.a'),'-framework','Security','-framework','CoreFoundation','-o',str(executable)],check=True)
            consumer=json.loads(subprocess.check_output([str(executable)],text=True))
        elif sys.platform=='win32':
            shutil.copytree(ROOT/'bindings/csharp',base/'csharp')
            subprocess.run(['dotnet','build',str(base/'csharp/Smoke/Smoke.csproj'),'--configuration','Release','--output',str(base/'out'),'--nologo','--verbosity','quiet'],check=True)
            consumer=json.loads(subprocess.check_output(['dotnet',str(base/'out/Smoke.dll'),str(library),str(ROOT/'bindings/ffi-layouts.json')],text=True))
            assert consumer['records']==len(layouts) and consumer['fields']==fields
        else:raise SystemExit('native macOS/Windows required for foreign consumer; no simulated PASS')
        if retained:
            files=[]
            for source in [library, target/'libarktrace_ffi.a', ROOT/'contracts/ffi-v1.json',
                           ROOT/'bindings/c/arktrace_ffi.h', ROOT/'bindings/c/module.modulemap',
                           ROOT/'bindings/swift/Smoke.swift', ROOT/'bindings/swift/GeneratedLayouts.swift']:
                if source.exists():
                    frozen=base/source.name
                    shutil.copyfile(source,frozen);frozen.chmod(0o400)
                    data=frozen.read_bytes();assert data==source.read_bytes()
                    files.append({'sourcePath':str(source),'frozenPath':str(frozen),'byteCount':len(data),'sha256':hashlib.sha256(data).hexdigest()})
            if sys.platform=='darwin':
                files.append({'frozenPath':str(executable),'byteCount':executable.stat().st_size,'sha256':hashlib.sha256(executable.read_bytes()).hexdigest()})
            (base/'manifest.json').write_text(json.dumps(files,indent=2)+'\n')
    assert consumer['abiVersion']==CONTRACT['abiVersion'] and consumer['nativeEngineAcceptance'] is False
    print(json.dumps({'abiVersion':CONTRACT['abiVersion'],'contractSHA256':expected.hex(),'records':len(layouts),'fields':fields,'exports':len(CONTRACT['functions']),'consumer':consumer,'nativeEngineAcceptance':False,'validAllocationFuzzCases':1000},sort_keys=True))
if __name__=='__main__':main()
