#!/usr/bin/env python3
"""Pinned isolated consumer and native Swift cache; no producer mutations."""
from pathlib import Path
import hashlib,json,platform,shutil,subprocess
ROOT=Path(__file__).resolve().parents[2];OWN=Path(__file__).resolve().parent
CARGO=ROOT.parent/'caches/parallel-counter-reveal-compat-cargo'
SWIFT=ROOT.parent/'caches/parallel-counter-reveal-compat-swiftpm'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
assert platform.system()=='Darwin' and platform.machine()=='arm64'
assert subprocess.check_output(['rustc','+1.99.0','--version'],text=True,encoding='utf-8').startswith('rustc 1.99.0 ')
assert sha(ROOT/'parallel-snapshot.json')=='e293efa4b8e1a64fe2e4a2b31f0968a5ada15878793261f87d2d758368288ea8'
manifest=json.loads((ROOT/'parallel-snapshot.json').read_text(encoding='utf-8'))
for r in manifest['files']:assert sha(ROOT/r['path'])==r['sha256'],r['path']
assert not CARGO.exists() and not SWIFT.exists()
CARGO.mkdir(mode=0o700);SWIFT.mkdir(mode=0o700)
seed=ROOT.parent/'caches/parallel-repository-inspector-parity-cargo/dependencies/registry'
shutil.copytree(seed,CARGO/'dependencies/registry')
subprocess.run(['git','init','--bare',str(CARGO/'source-index.git')],check=True,stdout=subprocess.DEVNULL)
workspace=CARGO/'workspace';workspace.mkdir()
for rel in ('rust','contracts'):shutil.copytree(ROOT/rel,workspace/rel)
package=workspace/OWN.relative_to(ROOT);shutil.copytree(OWN,package)
shutil.copyfile(ROOT/'rust/Cargo.lock',package/'Cargo.lock')
inherited=json.loads((OWN/'fixtures/inherited-evidence.json').read_text(encoding='utf-8'))
databases=[]
for r in inherited['databases']:
    if r['fixture'] not in ('minimal','native','merged'):continue
    folder=SWIFT/'databases'/r['fixture'];folder.mkdir(parents=True,mode=0o700)
    folder.chmod(0o700);source=Path(r['path']);assert sha(source)==r['sha256']
    target=folder/'fixture.sqlite';shutil.copyfile(source,target);target.chmod(0o400)
    assert sha(target)==r['sha256']
    databases.append(dict(fixture=r['fixture'],source=str(source),path=str(target),sha256=r['sha256'],byteCount=target.stat().st_size))
(OWN/'fixtures/database-copy-identities.json').write_text(json.dumps(databases,indent=2)+'\n',encoding='utf-8')
parser=ROOT.parent/'parallel-repository-inspector-parity-20261004/tools/parallel-repository-inspector-parity-20261004/fixtures/parser-identity.json'
shutil.copyfile(parser,OWN/'fixtures/parser-identity.json')
source=SWIFT/'oracle-source';source.mkdir()
for rel in ('Sources','Tests','scripts','ThirdParty','Fixtures'):
    shutil.copytree(ROOT/rel,source/rel,ignore=shutil.ignore_patterns('__pycache__','trace_streamer'))
for rel in ('LICENSE','THIRD_PARTY_NOTICES.md','.gitignore'):shutil.copyfile(ROOT/rel,source/rel)
text=(ROOT/'Package.swift').read_text(encoding='utf-8');needle='targets: [\n        .target(name: "ArkTraceCore"'
assert text.count(needle)==1
text=text.replace(needle,'targets: [\n        .testTarget(name: "CounterRevealCompatibilityOracleTests", dependencies: ["ArkTraceCore", "ArkTraceStore", "ArkTraceRendering", "ArkTraceRuntime", "ArkTraceAppSupport"]),\n        .target(name: "ArkTraceCore"')
(source/'Package.swift').write_text(text,encoding='utf-8')
controller=source/'Sources/ArkTraceAppSupport/TraceDocumentController.swift'
controller.write_text(controller.read_text(encoding='utf-8')+(OWN/'swift/ControllerAccess.swift').read_text(encoding='utf-8'),encoding='utf-8')
target=source/'Tests/CounterRevealCompatibilityOracleTests';target.mkdir()
shutil.copyfile(OWN/'swift/CounterRevealCompatibilityOracleTests.swift',target/'CounterRevealCompatibilityOracleTests.swift')
subprocess.run(['git','init',str(source)],check=True,stdout=subprocess.DEVNULL)
print(json.dumps(dict(baselineFilesVerified=len(manifest['files']),exclusiveCaches=[str(CARGO),str(SWIFT)],databasesCopied=len(databases))))
