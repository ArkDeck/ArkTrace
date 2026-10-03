#!/usr/bin/env python3
"""Actual SQLiteTraceRepository + Swift loader scope, before/after migration.

SQL and cases are retained controlled evidence. No real parser acceptance.
"""
import hashlib,json,os,shutil,sqlite3,subprocess,sys,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[4]
CRATE=ROOT/'rust/crates/arktrace-viewer'
CACHE=Path(os.environ.get('ARKTRACE_SCOPE_ORACLE_CACHE_ROOT','/private/tmp/arktrace-viewer-scope-swiftpm'))
COUNTERS='--counters' in sys.argv
INPUT=CRATE/f'tests/fixtures/scoped-{"counters" if COUNTERS else "slices"}-inputs.json'
STEM='swift-scoped-counters' if COUNTERS else 'swift-scoped-slices-before' if '--before' in sys.argv else 'swift-scoped-slices'
OUTPUT=CRATE/f'tests/fixtures/{STEM}.json'
def digest(p):
 d=p.read_bytes();return {'path':p.relative_to(ROOT).as_posix(),'sha256':hashlib.sha256(d).hexdigest(),'byteCount':len(d)}
def main():
 if COUNTERS and '--before' in sys.argv: raise SystemExit('counter historical run was not recorded')
 if '--before' in sys.argv and OUTPUT.exists(): raise SystemExit('historical before oracle already exists; refusing overwrite')
 if not CACHE.is_absolute() or CACHE.resolve().is_relative_to(ROOT): raise SystemExit('cache must be outside source')
 xcode=subprocess.check_output(['xcodebuild','-version'],text=True).strip();assert xcode.startswith('Xcode 27.')
 source=CACHE/'oracle-source';source.mkdir(parents=True,exist_ok=True)
 for name in ['ArkTraceCore','ArkTraceStore','ArkTraceRendering']:
  dest=source/'Sources'/name
  if dest.exists():shutil.rmtree(dest)
  shutil.copytree(ROOT/'Sources'/name,dest)
 shutil.copytree(ROOT/'scripts',source/'scripts',dirs_exist_ok=True)
 harness=CRATE/'oracle/ScopedSliceOracle.swift';dest=source/'Sources/ScopedSliceOracle';dest.mkdir(parents=True,exist_ok=True);shutil.copyfile(harness,dest/harness.name)
 (source/'Package.swift').write_text('''// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "ArkTrace", platforms: [.macOS(.v26)], targets: [
 .target(name: "ArkTraceCore", swiftSettings: [.strictMemorySafety()]),
 .target(name: "ArkTraceStore", dependencies: ["ArkTraceCore"], swiftSettings: [.strictMemorySafety()]),
 .target(name: "ArkTraceRendering", dependencies: ["ArkTraceCore"], swiftSettings: [.strictMemorySafety()]),
 .executableTarget(name: "ScopedSliceOracle", dependencies: ["ArkTraceCore", "ArkTraceStore", "ArkTraceRendering"])
], swiftLanguageModes: [.v6])
''')
 subprocess.run(['git','init','--quiet'],cwd=source,check=True)
 env=os.environ.copy();env['ARKTRACE_SWIFTPM_CACHE_ROOT']=str(CACHE)
 log=CACHE/f'{STEM}-build.log'
 with log.open('w') as f:
  run=subprocess.run(['sh','scripts/run-swiftpm.sh','build','--disable-sandbox','--config-path',str(CACHE/'configuration'),'--security-path',str(CACHE/'security'),'--product','ScopedSliceOracle'],cwd=source,env=env,stdout=f,stderr=subprocess.STDOUT)
 if run.returncode: print(log.read_text()[-10000:]);run.check_returncode()
 assert 'warning:' not in log.read_text()
 executable=CACHE/'build/out/Products/Debug/ScopedSliceOracle'
 inputs=json.loads(INPUT.read_text());manifest=json.loads((ROOT/'ThirdParty/TraceStreamer/macx/manifest.json').read_text())
 parser={k:manifest[k] for k in ['name','reportedVersion','binarySHA256','upstreamRepository','upstreamRevision','architecture','adapterVersion','buildRecipeVersion']}
 with tempfile.TemporaryDirectory(prefix='arktrace-scoped-slices-',dir='/private/tmp') as tmp:
  db=Path(tmp)/'controlled.sqlite';conn=sqlite3.connect(db);conn.executescript(inputs['sql']);conn.commit();conn.close();db.chmod(0o400)
  before=hashlib.sha256(db.read_bytes()).hexdigest()
  run=subprocess.run([str(executable),str(db),json.dumps(parser),json.dumps(inputs['cases'])],capture_output=True,text=True,timeout=60)
  if run.returncode: print(run.stderr[-12000:],file=sys.stderr);print(run.stdout[-12000:],file=sys.stderr);run.check_returncode()
  assert not run.stderr and len(run.stdout.encode())<1024*1024
  records=json.loads(run.stdout);assert [x['name'] for x in records]==[x['name'] for x in inputs['cases']]
  assert hashlib.sha256(db.read_bytes()).hexdigest()==before
  database={'byteCount':db.stat().st_size,'sha256':before,'bytesUnchanged':True}
 OUTPUT.write_text(json.dumps(records,ensure_ascii=False,indent=2)+'\n')
 paths=[harness,Path(__file__),INPUT,OUTPUT]
 for name in ['ArkTraceCore','ArkTraceStore','ArkTraceRendering']:paths+=sorted((ROOT/'Sources'/name).rglob('*.swift'))
 receipt={'oracle':'actual Swift SQLiteTraceRepository + TimelineSnapshotLoader','scope':'controlled SQL; full typed page/snapshot; not parser or SDK/App acceptance','vectors':len(records),'xcode':xcode,'swift':subprocess.check_output(['swift','--version'],text=True).strip(),'executableSHA256':hashlib.sha256(executable.read_bytes()).hexdigest(),'database':database,'sourceDigests':[digest(p) for p in paths]}
 retained=CACHE/f'{STEM}-{receipt["executableSHA256"]}.executable'
 if not retained.exists(): shutil.copyfile(executable,retained);retained.chmod(0o500)
 assert hashlib.sha256(retained.read_bytes()).hexdigest()==receipt['executableSHA256']
 receipt['retainedExactRunArtifact']={'path':str(retained),'sha256':receipt['executableSHA256'],'byteCount':retained.stat().st_size}
 (CRATE/f'tests/fixtures/{STEM}-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
 print(f'Actual Swift scoped repository: {len(records)} cases; {STEM}; database unchanged')
if __name__=='__main__':main()
