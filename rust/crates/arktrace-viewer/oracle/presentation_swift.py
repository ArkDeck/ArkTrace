#!/usr/bin/env python3
"""Actual Swift canonical results; augment only independent cache copies."""
import os,sys,subprocess,shutil,hashlib,json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[4];CRATE=ROOT/'rust/crates/arktrace-viewer'
CACHE=Path(os.environ.get('ARKTRACE_SWIFTPM_CACHE_ROOT',ROOT.parent/'caches/parallel-presentation-swiftpm'))
def main():
 if not CACHE.is_absolute()or CACHE.resolve().is_relative_to(ROOT):raise SystemExit('cache must be outside snapshot')
 source=CACHE/'oracle-source';source.mkdir(parents=True,exist_ok=True)
 xcode=subprocess.check_output(['xcodebuild','-version'],text=True);swift=subprocess.check_output(['swift','--version'],text=True)
 if xcode.splitlines()[0]!='Xcode 27.0' or 'Apple Swift version 6.4 'not in swift:raise SystemExit('Xcode27.0/Swift6.4 required')
 for directory in ['Sources/ArkTraceCore','Sources/ArkTraceRendering','Tests/ArkTraceRenderingTests','scripts']:shutil.copytree(ROOT/directory,source/directory,dirs_exist_ok=True)
 (source/'Package.swift').write_text('''// swift-tools-version: 6.3
import PackageDescription
let package=Package(name:"ArkTrace",platforms:[.macOS(.v26)],targets:[
.target(name:"ArkTraceCore",swiftSettings:[.strictMemorySafety()]),
.target(name:"ArkTraceRendering",dependencies:["ArkTraceCore"],swiftSettings:[.strictMemorySafety()]),
.testTarget(name:"ArkTraceRenderingTests",dependencies:["ArkTraceRendering"])
],swiftLanguageModes:[.v6])
''')
 test=source/'Tests/ArkTraceRenderingTests/TimelineRenderingTests.swift'
 for harness in ['OracleHarness.swift','DetailOracleHarness.swift','presentation_harness.swift']:test.write_bytes(test.read_bytes()+b'\n'+(CRATE/'oracle'/harness).read_bytes())
 for target,harness in [('TimelineNSView.swift','presentation_renderer_access.swift'),('TimelineColorPalette.swift','presentation_palette_access.swift')]:
  p=source/'Sources/ArkTraceRendering'/target;p.write_bytes(p.read_bytes()+b'\n'+(CRATE/'oracle'/harness).read_bytes())
 # Existing detail harness refers to this accessor; no mapping copied.
 p=source/'Sources/ArkTraceRendering/TimelineNSView.swift';p.write_text(p.read_text()+'\nextension TimelineNSView { package static func detailOracleStyleName(_ category:String?) -> String { presentationStyle(category) } }\n')
 subprocess.run(['git','init','--quiet'],cwd=source,check=True)
 inp=CRATE/'tests/fixtures/presentation-inputs.json';out=CRATE/'tests/fixtures/presentation-swift-oracle.json'
 env=os.environ.copy();env.update(ARKTRACE_SWIFTPM_CACHE_ROOT=str(CACHE),ARKTRACE_PRESENTATION_INPUT=str(inp),ARKTRACE_PRESENTATION_OUTPUT=str(out))
 selected='TimelineRenderingTests.testActualPresentationOracle'
 if '--regressions'in sys.argv:selected='TimelinePaletteTests|TimelineFrameLaneTests|TimelineRenderingTests.test(Density.*|.*CpuSliceLabel.*|.*CPU.*Label.*|.*Color.*|.*Foreground.*)'
 log=CACHE/('presentation-swift-regressions.log' if '--regressions'in sys.argv else 'presentation-swift-oracle.log')
 with log.open('w')as f:r=subprocess.run(['sh','scripts/run-swiftpm.sh','test','--disable-sandbox','--config-path',str(CACHE/'configuration'),'--security-path',str(CACHE/'security'),'--filter',selected],cwd=source,env=env,stdout=f,stderr=subprocess.STDOUT)
 print('Swift:',r.returncode,log)
 if r.returncode:print(log.read_text()[-8000:]);return r.returncode
 if '--regressions'in sys.argv:print(log.read_text()[-1600:]);return 0
 def digest(p,relative=True):
  data=p.read_bytes();return {'path':str(p.relative_to(ROOT))if relative else str(p),'sha256':hashlib.sha256(data).hexdigest(),'byteCount':len(data)}
 paths=list((ROOT/'Sources/ArkTraceCore').rglob('*.swift'))+list((ROOT/'Sources/ArkTraceRendering').glob('*.swift'))+[ROOT/'Tests/ArkTraceRenderingTests/TimelineRenderingTests.swift']+[CRATE/'oracle'/n for n in ['OracleHarness.swift','DetailOracleHarness.swift','presentation_harness.swift','presentation_renderer_access.swift','presentation_palette_access.swift','presentation_swift.py']]+[inp,out]
 result=json.loads(out.read_text());receipt={'oracle':'actual TimelinePalette, DetailPalette, DensityPalette, SnapshotLoader and NSView private drawDensityOverlay cache','xcode':xcode.strip(),'swift':swift.strip(),'counts':{k:len(result[k])for k in ['palette','genericDetails','dto']},'sourceDigests':[digest(p)for p in sorted(paths)],'cacheOnlyAugmentedSources':[digest(p,False)for p in [test,source/'Sources/ArkTraceRendering/TimelineNSView.swift',source/'Sources/ArkTraceRendering/TimelineColorPalette.swift']],'copiedAlgorithms':False}
 (CRATE/'tests/fixtures/presentation-swift-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(receipt['counts'])
 return 0
if __name__=='__main__':sys.exit(main())
