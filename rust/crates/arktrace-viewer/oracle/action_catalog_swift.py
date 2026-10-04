#!/usr/bin/env python3
"""Execute actual frozen Swift catalog/keyDown; augment only cache copies."""
import os,sys,json,hashlib,shutil,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[4];CRATE=ROOT/'rust/crates/arktrace-viewer'
CACHE=Path(os.environ.get('ARKTRACE_SWIFTPM_CACHE_ROOT',ROOT.parent/'caches/parallel-action-catalog-swiftpm'))
def main():
 if not CACHE.is_absolute()or CACHE.resolve().is_relative_to(ROOT):raise SystemExit('cache must be absolute outside snapshot')
 source=CACHE/'oracle-source';source.mkdir(parents=True,exist_ok=True)
 xcode=subprocess.check_output(['xcodebuild','-version'],text=True,encoding='utf-8');swift=subprocess.check_output(['swift','--version'],text=True,encoding='utf-8')
 if xcode.splitlines()[0]!='Xcode 27.0'or 'Apple Swift version 6.4 'not in swift:raise SystemExit('Xcode 27.0 / Swift 6.4 required')
 targets=['ArkTraceCore','ArkTraceParser','ArkTraceStore','ArkTraceRuntime','ArkTraceAnalysis','ArkTraceRendering','ArkTraceAppSupport']
 for target in targets:shutil.copytree(ROOT/'Sources'/target,source/'Sources'/target,dirs_exist_ok=True)
 shutil.copytree(ROOT/'scripts',source/'scripts',dirs_exist_ok=True,ignore=shutil.ignore_patterns('__pycache__'))
 shutil.copytree(ROOT/'Apps/ArkTraceApp',source/'Apps/ArkTraceApp',dirs_exist_ok=True)
 for name in ['README.md','README.zh-CN.md']:shutil.copyfile(ROOT/name,source/name)
 testpaths=['Tests/ArkTraceAppSupportTests/ShortcutCatalogTests.swift','Tests/ArkTraceAppSupportTests/AppSource.swift','Tests/ArkTraceRenderingTests/TimelineNavigationKeyTests.swift','Tests/ArkTraceRenderingTests/TimelineAnnotationKeyTests.swift','Tests/ArkTraceRenderingTests/TimelineRenderingTests.swift']
 for relative in testpaths:p=source/relative;p.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/relative,p)
 dependencies={'ArkTraceCore':[],'ArkTraceParser':['ArkTraceCore'],'ArkTraceStore':['ArkTraceCore'],'ArkTraceRuntime':['ArkTraceCore','ArkTraceParser','ArkTraceStore'],'ArkTraceAnalysis':['ArkTraceCore'],'ArkTraceRendering':['ArkTraceCore'],'ArkTraceAppSupport':['ArkTraceCore','ArkTraceParser','ArkTraceRuntime','ArkTraceAnalysis','ArkTraceRendering']}
 text='// swift-tools-version: 6.3\nimport PackageDescription\nlet package=Package(name:"ArkTrace",platforms:[.macOS(.v26)],targets:[\n'
 for target in targets:text+=f'.target(name:"{target}",dependencies:{json.dumps(dependencies[target])},swiftSettings:[.strictMemorySafety()]),\n'
 text+=''' .testTarget(name:"ArkTraceAppSupportTests",dependencies:["ArkTraceAppSupport","ArkTraceCore"]),
 .testTarget(name:"ArkTraceRenderingTests",dependencies:["ArkTraceRendering"])
],swiftLanguageModes:[.v6])\n''';(source/'Package.swift').write_text(text,encoding='utf-8')
 view=source/'Sources/ArkTraceRendering/TimelineNSView.swift';original=view.read_text(encoding='utf-8');entry='    package func performKeyboardCommand(_ command: TimelineKeyboardCommand) -> Bool {\n';assert original.count(entry)==1
 original=original.replace(entry,entry+'        if ActionCatalogOracleProbe.enabled { ActionCatalogOracleProbe.commands.append(String(describing: command)) }\n',1)
 view.write_text(original+'\n'+(CRATE/'oracle/action_catalog_access.swift').read_text(encoding='utf-8'),encoding='utf-8')
 test=source/'Tests/ArkTraceRenderingTests/TimelineNavigationKeyTests.swift';test.write_bytes(test.read_bytes()+b'\n'+(CRATE/'oracle/action_catalog_harness.swift').read_bytes())
 display=source/'Tests/ArkTraceAppSupportTests/ActionCatalogDisplayOracleTests.swift';shutil.copyfile(CRATE/'oracle/action_catalog_display_harness.swift',display)
 subprocess.run(['git','init','--quiet'],cwd=source,check=True)
 inp=CRATE/'tests/fixtures/action-catalog-inputs.json';keyboard=CRATE/'tests/fixtures/action-catalog-keyboard-swift.json';catalog=CRATE/'tests/fixtures/action-catalog-display-swift.json'
 env=os.environ.copy();env.update(ARKTRACE_SWIFTPM_CACHE_ROOT=str(CACHE),ARKTRACE_ACTION_CATALOG_INPUT=str(inp),ARKTRACE_ACTION_CATALOG_KEYBOARD_OUTPUT=str(keyboard),ARKTRACE_ACTION_CATALOG_DISPLAY_OUTPUT=str(catalog))
 regressions='--regressions'in sys.argv
 selected='ShortcutCatalogTests|TimelineNavigationKeyTests.test(?!Actual)|TimelineAnnotationKeyTests|TimelineRenderingTests.testTimelineKeyboardAndVoiceOverContractUsesBoundedRealEvents|TimelineRenderingTests.testAccessibilityActionsExposeOnlyCommandsThatCanChangeState'if regressions else'ActionCatalogDisplayOracleTests|TimelineNavigationKeyTests.testActualActionCatalogKeyboardOracle'
 log=CACHE/('action-catalog-swift-regressions.log'if regressions else'action-catalog-swift-oracle.log')
 with log.open('w',encoding='utf-8')as f:code=subprocess.run(['sh','scripts/run-swiftpm.sh','test','--disable-sandbox','--config-path',str(CACHE/'configuration'),'--security-path',str(CACHE/'security'),'--filter',selected],cwd=source,env=env,stdout=f,stderr=subprocess.STDOUT).returncode
 print('Swift exit code:',code,'log:',log)
 if code:print(log.read_text(encoding='utf-8')[-9000:]);return code
 if regressions:print(log.read_text(encoding='utf-8')[-1700:]);return 0
 def digest(p):
  data=p.read_bytes();return {'path':str(p.relative_to(ROOT))if p.is_relative_to(ROOT)else str(p),'byteCount':len(data),'sha256':hashlib.sha256(data).hexdigest()}
 paths=[p for target in targets for p in(ROOT/'Sources'/target).rglob('*.swift')]+[ROOT/p for p in testpaths]+list((ROOT/'Apps/ArkTraceApp').rglob('*.swift'))+[ROOT/'README.md',ROOT/'README.zh-CN.md',*list((CRATE/'oracle').glob('action_catalog_*')),inp,keyboard,catalog]
 result=json.loads(keyboard.read_text(encoding='utf-8'));sections=json.loads(catalog.read_text(encoding='utf-8'))['sections']
 receipt={'oracle':'Actual Swift TraceShortcutCatalog, real NSEvent + TimelineNSView.keyDown, actual next-responder forwarding, command entry recording then original handler execution','xcode':xcode.strip(),'swift':swift.strip(),'nativeKeyCases':len(result['cases']),'directCommandCases':len(result['directCommands']),'catalogSections':len(sections),'catalogRows':sum(len(s['entries'])for s in sections),'sourceDigests':[digest(p)for p in sorted(paths)],'cacheOnlyAugmentedSources':[digest(view),digest(test),digest(display),digest(source/'Package.swift')],'copiedExpectedRoutingAlgorithms':False,'scopeFocusTextIMEProof':False,'searchResultsNativeKeyProof':False}
 (CRATE/'tests/fixtures/action-catalog-swift-receipt.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n',encoding='utf-8');print(receipt['nativeKeyCases'],'native inputs',receipt['directCommandCases'],'direct commands',receipt['catalogRows'],'catalog rows');return 0
if __name__=='__main__':sys.exit(main())
