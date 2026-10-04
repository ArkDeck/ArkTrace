#!/usr/bin/env python3
"""Call actual private loader using a cache-only wrapper and assigned typed DTOs."""
import hashlib,json,os,shutil,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[4];CRATE=ROOT/'rust/crates/arktrace-viewer'
CACHE=Path(os.environ.get('ARKTRACE_SWIFTPM_CACHE_ROOT',ROOT.parent/'caches/parallel-inspector-projection-swiftpm'))
def main():
 if not CACHE.is_absolute()or CACHE.resolve().is_relative_to(ROOT):raise SystemExit('cache must be absolute outside snapshot')
 source=CACHE/'oracle-source';source.mkdir(parents=True,exist_ok=True)
 xcode=subprocess.check_output(['xcodebuild','-version'],text=True,encoding='utf-8');swift=subprocess.check_output(['swift','--version'],text=True,encoding='utf-8')
 if xcode.splitlines()[0]!='Xcode 27.0'or 'Apple Swift version 6.4 'not in swift:raise SystemExit('Xcode27.0/Swift6.4 required')
 for directory in ['Sources/ArkTraceCore','Sources/ArkTraceRendering','Tests/ArkTraceRenderingTests','scripts']:shutil.copytree(ROOT/directory,source/directory,dirs_exist_ok=True,ignore=shutil.ignore_patterns('__pycache__'))
 tests=['Tests/ArkTraceCoreTests/TraceEventModelContractTests.swift','Tests/ArkTraceCoreTests/TraceTimeTests.swift']
 for relative in tests:p=source/relative;p.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/relative,p)
 package=source/'Package.swift';package.write_text('''// swift-tools-version: 6.3
import PackageDescription
let package=Package(name:"ArkTrace",platforms:[.macOS(.v26)],targets:[
.target(name:"ArkTraceCore",swiftSettings:[.strictMemorySafety()]),
.target(name:"ArkTraceRendering",dependencies:["ArkTraceCore"],swiftSettings:[.strictMemorySafety()]),
.testTarget(name:"ArkTraceCoreTests",dependencies:["ArkTraceCore"]),
.testTarget(name:"ArkTraceRenderingTests",dependencies:["ArkTraceRendering"])
],swiftLanguageModes:[.v6])
''',encoding='utf-8')
 loader=source/'Sources/ArkTraceRendering/TimelineSnapshotLoader.swift';loader.write_bytes(loader.read_bytes()+b'\n'+(CRATE/'oracle/inspector_projection_access.swift').read_bytes())
 harness=source/'Tests/ArkTraceRenderingTests/InspectorProjectionOracleTests.swift';shutil.copyfile(CRATE/'oracle/inspector_projection_harness.swift',harness)
 subprocess.run(['git','init','--quiet'],cwd=source,check=True)
 inp=CRATE/'tests/fixtures/inspector-projection-inputs.json';out=CRATE/'tests/fixtures/inspector-projection-swift.json';env=os.environ.copy();env.update(ARKTRACE_SWIFTPM_CACHE_ROOT=str(CACHE),ARKTRACE_INSPECTOR_PROJECTION_INPUT=str(inp),ARKTRACE_INSPECTOR_PROJECTION_OUTPUT=str(out))
 regressions='--regressions'in sys.argv
 selected='TraceEventModelContractTests|TraceTimeTests|TimelineFrameLaneTests|TimelineRenderingTests.testCounterDetailUsesPositiveAndOpenEndedDurations|TimelineRenderingTests.testInstantDetailRetainsDomainRangeButDrawsAtLeastOnePhysicalPixel|TimelineRenderingTests.testGeometryAndHitTestingUseSameFrameAndDensityCarriesNoEventKey'if regressions else'InspectorProjectionOracleTests.testActualLoaderInspectorFacts'
 log=CACHE/('inspector-projection-swift-regressions.log'if regressions else'inspector-projection-swift-oracle.log')
 with log.open('w',encoding='utf-8')as f:code=subprocess.run(['sh','scripts/run-swiftpm.sh','test','--disable-sandbox','--config-path',str(CACHE/'configuration'),'--security-path',str(CACHE/'security'),'--filter',selected],cwd=source,env=env,stdout=f,stderr=subprocess.STDOUT).returncode
 print('Swift exit:',code,'log:',log)
 if code:print(log.read_text(encoding='utf-8')[-8000:]);return code
 if regressions:print(log.read_text(encoding='utf-8')[-1600:]);return 0
 def digest(p):
  data=p.read_bytes();return {'path':str(p.relative_to(ROOT))if p.is_relative_to(ROOT)else str(p),'byteCount':len(data),'sha256':hashlib.sha256(data).hexdigest()}
 paths=list((ROOT/'Sources/ArkTraceCore').rglob('*.swift'))+list((ROOT/'Sources/ArkTraceRendering').rglob('*.swift'))+list((ROOT/'Tests/ArkTraceRenderingTests').rglob('*.swift'))+[ROOT/p for p in tests]+list((CRATE/'oracle').glob('inspector_projection_*'))+[inp,out]
 result=json.loads(out.read_text(encoding='utf-8'));receipt={'oracle':'Actual TimelineSnapshotLoader.detailPrimitives/counterPrimitives through private-call wrapper; assigned real typed DTO pages; read every Inspector field and computed isInstant','xcode':xcode.strip(),'swift':swift.strip(),'cases':len(result['cases']),'positions':sum(len(c['facts'])for c in result['cases']),'sourceDigests':[digest(p)for p in sorted(paths)],'cacheOnlyAugmentedSources':[digest(loader),digest(harness),digest(package)],'copiedInspectorConstructorAlgorithms':False,'repositoryNormalizationProven':False,'nativeUIFormatterOrSDKProof':False}
 (CRATE/'tests/fixtures/inspector-projection-swift-receipt.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n',encoding='utf-8');print(receipt['cases'],'cases',receipt['positions'],'positions');return 0
if __name__=='__main__':sys.exit(main())
