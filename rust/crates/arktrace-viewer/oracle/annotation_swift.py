#!/usr/bin/env python3
"""Execute frozen Swift sources; mutate cache copies only for access/probes."""
import os,sys,json,hashlib,shutil,subprocess,re
from pathlib import Path
ROOT=Path(__file__).resolve().parents[4];CRATE=ROOT/'rust/crates/arktrace-viewer'
CACHE=Path(os.environ.get('ARKTRACE_SWIFTPM_CACHE_ROOT',ROOT.parent/'caches/parallel-annotations-swiftpm'))
def main():
 if not CACHE.is_absolute()or CACHE.resolve().is_relative_to(ROOT):raise SystemExit('cache must be absolute outside snapshot')
 source=CACHE/'oracle-source';source.mkdir(parents=True,exist_ok=True)
 xcode=subprocess.check_output(['xcodebuild','-version'],text=True, encoding='utf-8');swift=subprocess.check_output(['swift','--version'],text=True, encoding='utf-8')
 if xcode.splitlines()[0]!='Xcode 27.0'or 'Apple Swift version 6.4 'not in swift:raise SystemExit('Xcode 27.0 / Swift 6.4 required')
 targets=['ArkTraceCore','ArkTraceParser','ArkTraceStore','ArkTraceRuntime','ArkTraceAnalysis','ArkTraceRendering','ArkTraceAppSupport']
 for target in targets:shutil.copytree(ROOT/'Sources'/target,source/'Sources'/target,dirs_exist_ok=True)
 shutil.copytree(ROOT/'scripts',source/'scripts',dirs_exist_ok=True,ignore=shutil.ignore_patterns('__pycache__'))
 testpaths=['Tests/ArkTraceAppSupportTests/TraceDocumentControllerTests.swift','Tests/ArkTraceAppSupportTests/TraceViewStateStoreTests.swift','Tests/ArkTraceRenderingTests/TimelineAnnotationKeyTests.swift','Tests/ArkTraceRenderingTests/TimelineFlagSelectionTests.swift']
 for relative in testpaths:p=source/relative;p.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/relative,p)
 dependencies={'ArkTraceCore':[],'ArkTraceParser':['ArkTraceCore'],'ArkTraceStore':['ArkTraceCore'],'ArkTraceRuntime':['ArkTraceCore','ArkTraceParser','ArkTraceStore'],'ArkTraceAnalysis':['ArkTraceCore'],'ArkTraceRendering':['ArkTraceCore'],'ArkTraceAppSupport':['ArkTraceCore','ArkTraceParser','ArkTraceRuntime','ArkTraceAnalysis','ArkTraceRendering']}
 text='// swift-tools-version: 6.3\nimport PackageDescription\nlet package=Package(name:"ArkTrace",platforms:[.macOS(.v26)],targets:[\n'
 for target in targets:text+=f'.target(name:"{target}",dependencies:{json.dumps(dependencies[target])},swiftSettings:[.strictMemorySafety()]),\n'
 text+=''' .testTarget(name:"ArkTraceAppSupportTests",dependencies:["ArkTraceAppSupport","ArkTraceCore","ArkTraceRuntime","ArkTraceRendering","ArkTraceAnalysis"]),
 .testTarget(name:"ArkTraceRenderingTests",dependencies:["ArkTraceRendering"])
],swiftLanguageModes:[.v6])\n''';(source/'Package.swift').write_text(text, encoding='utf-8')
 controller=source/'Sources/ArkTraceAppSupport/TraceDocumentController.swift';original=controller.read_text(encoding='utf-8')
 persist='    private func persistViewState() {\n';reveal='    private func revealRange(_ eventRange: TraceTimeRange) {\n';assert original.count(persist)==1 and original.count(reveal)==1
 original=original.replace(persist,persist+'        if AnnotationOracleProbe.enabled { AnnotationOracleProbe.persistCount += 1 }\n',1)
 original=original.replace(reveal,reveal+'        if AnnotationOracleProbe.enabled { AnnotationOracleProbe.reveals.append(eventRange); return }\n',1)
 access=(CRATE/'oracle/annotation_access.swift').read_text(encoding='utf-8')
 ui=ROOT/'Apps/ArkTraceApp/Viewer/TraceTimelinePane.swift';body=re.search(r'rename: \{ label in\n(.*?)\n\s*\},',ui.read_text(encoding='utf-8'),re.S).group(1)
 assert 'guard selection.sessionID == controller.annotationSessionID else { return }'in body and 'controller.updateFlag(id: flag.id, label: label)'in body
 access=access.replace('        // ANNOTATION_DEFERRED_RENAME_BODY',body)
 controller.write_text(original+'\n'+access, encoding='utf-8')
 test=source/'Tests/ArkTraceAppSupportTests/TraceDocumentControllerTests.swift';test.write_bytes(test.read_bytes()+b'\n'+(CRATE/'oracle/annotation_harness.swift').read_bytes())
 subprocess.run(['git','init','--quiet'],cwd=source,check=True)
 inp=CRATE/'tests/fixtures/annotation-inputs.json';out=CRATE/'tests/fixtures/annotation-swift-oracle.json';env=os.environ.copy();env.update(ARKTRACE_SWIFTPM_CACHE_ROOT=str(CACHE),ARKTRACE_ANNOTATION_INPUT=str(inp),ARKTRACE_ANNOTATION_OUTPUT=str(out))
 regressions='--regressions'in sys.argv
 selected='TraceViewStateStoreTests|TimelineAnnotationKeyTests|TimelineAnnotationRenderTests|TimelineFlagSelectionTests|TraceDocumentControllerTests.testAnnotationLifecycleAndSessionReplacement'if regressions else'TraceDocumentControllerTests.testActualAnnotationOracle'
 log=CACHE/('annotation-swift-regressions.log'if regressions else'annotation-swift-oracle.log')
 with log.open('w', encoding='utf-8')as f:code=subprocess.run(['sh','scripts/run-swiftpm.sh','test','--disable-sandbox','--config-path',str(CACHE/'configuration'),'--security-path',str(CACHE/'security'),'--filter',selected],cwd=source,env=env,stdout=f,stderr=subprocess.STDOUT).returncode
 print('Swift exit code:',code,'log:',log)
 if code:print(log.read_text(encoding='utf-8')[-10000:]);return code
 if regressions:print(log.read_text(encoding='utf-8')[-1700:]);return 0
 def digest(p):
  data=p.read_bytes();return {'path':str(p.relative_to(ROOT))if p.is_relative_to(ROOT)else str(p),'byteCount':len(data),'sha256':hashlib.sha256(data).hexdigest()}
 paths=[p for target in targets for p in(ROOT/'Sources'/target).rglob('*.swift')]+[ROOT/p for p in testpaths]+[ui,ROOT/'Apps/ArkTraceApp/Inspector/AnnotationInspectorView.swift',CRATE/'oracle/annotation_access.swift',CRATE/'oracle/annotation_harness.swift',CRATE/'oracle/annotation_swift.py',inp,out]
 result=json.loads(out.read_text(encoding='utf-8'));receipt={'oracle':'actual TimelineAnnotations, TraceDocumentController and TraceViewStateStore; reveal interception only before generic revealRange','xcode':xcode.strip(),'swift':swift.strip(),'cases':len(result['cases']),'states':sum(len(c['states'])for c in result['cases']),'actions':sum(len(c['states'])-1 for c in result['cases']),'sourceDigests':[digest(p)for p in sorted(paths)],'cacheOnlyAugmentedSources':[digest(controller),digest(test),digest(source/'Package.swift')],'deferredRenameCompiledOriginalBlock':{'source':str(ui.relative_to(ROOT)),'utf8':body,'sha256':hashlib.sha256(body.encode()).hexdigest()},'copiedExpectedStateAlgorithms':False}
 (CRATE/'tests/fixtures/annotation-swift-receipt.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n', encoding='utf-8');print(receipt['cases'],'cases',receipt['actions'],'actions',receipt['states'],'states')
 return 0
if __name__=='__main__':sys.exit(main())
