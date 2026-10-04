#!/usr/bin/env python3
"""Freeze the scoped action-catalog delivery, exact source/log hashes and limits."""
import ast,datetime,hashlib,json,re,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[4]
CRATE=ROOT/'rust/crates/arktrace-viewer'
EVIDENCE=ROOT.parent/'caches/parallel-action-catalog-cargo/frozen-evidence'
def info(p):
 data=p.read_bytes();return dict(path=str(p.relative_to(ROOT))if p.is_relative_to(ROOT)else str(p),byteCount=len(data),sha256=hashlib.sha256(data).hexdigest())
def utf8_audit():
 operations=[]
 for path in sorted((CRATE/'oracle').glob('action_catalog_*.py')):
  for call in ast.walk(ast.parse(path.read_text(encoding='utf-8'))):
   if not isinstance(call,ast.Call):continue
   name=call.func.attr if isinstance(call.func,ast.Attribute)else call.func.id if isinstance(call.func,ast.Name)else ''
   keywords={k.arg:k.value for k in call.keywords}
   if name in ['read_text','write_text','open']or ('text'in keywords and isinstance(keywords['text'],ast.Constant)and keywords['text'].value):
    encoding=keywords.get('encoding');assert isinstance(encoding,ast.Constant)and encoding.value=='utf-8',(path,call.lineno)
    operations.append(dict(path=str(path.relative_to(ROOT)),line=call.lineno,operation=name,encoding='utf-8'))
 return operations
def main():
 manifest=ROOT/'parallel-snapshot.json';baseline=json.loads(manifest.read_text(encoding='utf-8'));assert len(baseline['files'])==870
 expected_manifest='14cceffe02599e4bb855a06b889b818b02aff47b4b4bec7a4f2cf7b35a7f0ccc';assert info(manifest)['sha256']==expected_manifest
 original={item['path']:item['sha256']for item in baseline['files']}
 changed=[path for path,digest in original.items()if info(ROOT/path)['sha256']!=digest];assert changed==['rust/crates/arktrace-viewer/src/lib.rs'],changed
 append=b'\nmod action_catalog;\npub use action_catalog::*;\n';lib=ROOT/changed[0];assert lib.read_bytes().endswith(append);assert hashlib.sha256(lib.read_bytes()[:-len(append)]).hexdigest()==original[changed[0]]
 paths=[p for p in ROOT.rglob('*')if p.is_file()and str(p.relative_to(ROOT))not in original and p!=manifest]
 prefixes=['rust/crates/arktrace-viewer/oracle/action_catalog_','rust/crates/arktrace-viewer/tests/action_catalog_','rust/crates/arktrace-viewer/tests/fixtures/action-catalog-','docs/migration-runs/AT-RUST-013-parallel-action-catalog-2026-10-04.']
 for path in paths:
  rel=str(path.relative_to(ROOT));assert rel=='rust/crates/arktrace-viewer/src/action_catalog.rs'or any(rel.startswith(prefix)for prefix in prefixes),rel
 records=json.loads((EVIDENCE/'command-results.json').read_text(encoding='utf-8'));latest={c['name']:c for c in records}
 assert set(latest)=={'swiftOracle','swiftRegressions','fmt','test','clippy','verify'}and all(c['exitCode']==0 for c in latest.values())
 for record in records:
  for field in ['log','actualLog']:
   if field in record:assert info(Path(record[field]['path']))['sha256']==record[field]['sha256']
 receipt_path=CRATE/'tests/fixtures/action-catalog-swift-receipt.json';receipt=json.loads(receipt_path.read_text(encoding='utf-8'))
 for file in receipt['sourceDigests']+receipt['cacheOnlyAugmentedSources']:
  path=Path(file['path']);path=path if path.is_absolute()else ROOT/path;assert info(path)['sha256']==file['sha256'],file
 rust_log=Path(latest['test']['log']['path']).read_text(encoding='utf-8');total_tests=sum(map(int,re.findall(r'test result: ok\. (\d+) passed',rust_log)));doc_tests=sum(map(int,re.findall(r'test result: ok\. (\d+) passed',rust_log.split('Doc-tests arktrace_viewer')[-1])));rust_tests=total_tests-doc_tests
 swift_oracle=Path(latest['swiftOracle']['actualLog']['path']).read_text(encoding='utf-8');swift_tests=Path(latest['swiftRegressions']['actualLog']['path']).read_text(encoding='utf-8')
 def actual_passes(log):return len(re.findall(r"Test Case .* passed \(",log))
 assert actual_passes(swift_oracle)==2 and actual_passes(swift_tests)==19
 assert not re.search(r'warning:|error:',rust_log+swift_oracle+swift_tests)
 audit=dict(encoding='utf-8',operations=utf8_audit(),nativeWindowsExecution=False,baselineScriptsChanged=False)
 audit_path=EVIDENCE/'action-catalog-utf8-audit.json';audit_path.write_text(json.dumps(audit,indent=2)+'\n',encoding='utf-8')
 data=json.loads((CRATE/'tests/fixtures/action-catalog-keyboard-swift.json').read_text(encoding='utf-8'))
 result_counts={key:sum(bool(c[key])for c in data['cases'])for key in ['commands','annotations','forwarded','keyboardFocusVisible']}
 prefix=ROOT/'docs/migration-runs/AT-RUST-013-parallel-action-catalog-2026-10-04';jp=prefix.with_suffix('.json');mp=prefix.with_suffix('.md');sp=prefix.with_suffix('.sha256')
 owned_source=[info(p)for p in sorted(paths)if not p.is_relative_to(ROOT/'docs/migration-runs')]
 report=dict(schemaVersion=1,task='AT-RUST-013 delivery 5 shared semantic action/shortcut catalog',status='pureCatalogAndTimelineRouterVerified; productionIntegrationPending',createdAtUtc=datetime.datetime.now(datetime.timezone.utc).isoformat(),snapshot=dict(directory=str(ROOT),commit=baseline['sourceCommit'],manifest=info(manifest),baselineFiles=870,unchangedBaselineFiles=869,modifiedBaselineFiles=changed,all870OriginalBytesAccounted=True,mainCheckoutWritten=False,previousDeliveriesWritten=False),ownedNewSourceFiles=owned_source,existingFileApplication=dict(path=changed[0],appendUtf8=append.decode('utf-8'),replaceWholeFile=False),cacheIsolation=dict(cargo=str(EVIDENCE.parent),swiftpm=str(ROOT.parent/'caches/parallel-action-catalog-swiftpm'),registrySeedReadOnly=str(ROOT.parent/'caches/parallel-presentation-cargo/dependencies/registry'),otherCachesWritten=False),api=dict(version=1,semanticActions=29,domains=['timelineKeyboard','timelineAnnotation','pointer','searchResults'],sections=3,entries=19,catalogRecordAccess='Private fields with read-only accessors, no Deserialize/custom constructors or caller-provided text; fixed canonical catalog only.',numericIDs='Closed versioned u32 discriminants; new IDs, not pre-existing Swift numeric facts. Swift legacy English-title/key-markup IDs preserved separately. Rust layouts are not ABI.',input='Closed normalized key enum, four modifier booleans, typed scope and text_input_active; no raw NSEvent/virtual key/layout/UTF-8 event input.',router='Constant-work zero-allocation resolve_mac_shortcut(version,input,check). Dispatch selects an existing handler; eligibility, viewport/navigation, annotation state and focus restoration remain separate.',output='Dispatch(action ID) or Forward(reason) plus show_keyboard_focus intent. No menu invocation is synthesized.',budgets=dict(maximumMarkdownTableBytes=16384,catalogRows=19,recordIDs=29,routerCheckpoints=2,tableCheckpoints='entry, each row, end'),errors=['UnsupportedVersion','UnknownAction','OutputBudgetExceeded','Cancelled','DeadlineReached']),oracle=dict(receipt=info(receipt_path),productionSourceDigestsVerified=True,nativeKeyCases=664,directCommandCases=14,catalogRows=19,bilingualTables=6,outcomeCounts=result_counts,source='Real TraceShortcutCatalog methods and TimelineNSView.keyDown called with actual NSEvent; real nextResponder records forwarding; one cache-only command-entry probe then unmodified handler executes.',copiedExpectedRoutingAlgorithms=False,exactRecursiveComparison=True,scopeTextIMEFocusNativeEvidence=False,searchResultsNativeKeyboardEvidence=False),toolchains=dict(rust='exact 1.99.0 / edition 2024, runner --locked --offline',xcode=receipt['xcode'],swift=receipt['swift'],swiftPackage='cache-only minimal package, macOS26 / Swift language mode6; original seven production source targets; App source contracts copied but App not built'),verification=records,actualCommandRecord=info(EVIDENCE/'command-results.json'),resultSummary=dict(rustViewerTestsPassed=rust_tests,compileFailDocTestsPassed=doc_tests,newRustTests=11,swiftOracleTestsPassed=2,swiftExistingTestsPassed=19,swiftRenderingTestsPassed=13,swiftAppSupportTestsPassed=6,rustWorkspaceCrates=8,frozenThirdPartyLicenseExpressions=35,finalCompilerWarnings=0,rustIgnoredTests=0,appBuildExecuted=False,nativeGuiAcceptanceExecuted=False),utf8Portability=dict(audit=info(audit_path),explicitTextEncoding='utf-8',ownedPythonScripts=len(list((CRATE/'oracle').glob('action_catalog_*.py'))),textOperations=len(audit['operations']),nativeWindowsExecution=False),integrationProposal=dict(sdk='Generate stable fixed-width version/action/domain/section/entry/key/scope/route discriminants and bounded UTF-8 offset-length catalog records. Do not expose Rust enum/Vec/String/reference layout. New action IDs map by domain to the existing keyboard/annotation modules; keep transient/persistent creation as separate IDs.',macAdapter='Before routing, determine responder/focus scope and mark text field, editor, marked-text or IME ownership as text_input_active. Normalize physical keyCode 123/124/125/126 first; otherwise lower the complete charactersIgnoringModifiers string and recognize one key token. Preserve raw native event solely in the host for Forward. Ignore capsLock/function/numericPad/help for four modifier flags.',precedence='After native scope guard, horizontal/vertical physical arrows precede Command/Control guards, matching current Swift. Option switches horizontal arrows to pan. Command letters forward; Control comma/period/brackets are annotations; bare brackets alias zoomSelection; M remains annotation with optional Shift even with Control/Option.',helpReadme='Main replaces the current Swift catalog consumer with generated shared records. Preserve section/row order, original legacy IDs, keysEnglish display form, localized gesture cells, exact six markdown tables and no trailing newline. Re-run ShortcutCatalogTests and update both READMEs only if intentionally changed; this snapshot modifies neither.',searchPointer='Catalog semantic/display metadata only. Search-results scope returns Forward(SearchResultsHost); native SwiftUI onKeyPress/Button owns result stepping/activation/focus. Pointer gestures retain existing Cocoa translation and algorithms. Wire those hosts to semantic IDs after native evidence, without synthesizing a Windows keymap.',validation='On main run generated wire/ABI/version and SDK gates, the 664 native inputs against actual adapter output, scope/text/IME/menu/window focus tests, actual search keyboard activation, pointer normalization, accessibility and App build/native medium-trace GUI evidence. Pure tests are not AT-RUST-013 macOS acceptance.'),limitations=['Pure catalog and normalized macOS timeline-key router only; no Store/Engine/SDK/FFI/App/CLI/README/manifest/lock production integration. AT-RUST-013 and macOS GUI acceptance remain incomplete.','Native layout conversion, nil characters, text/IME/focus ownership and window menu behavior require host evidence. Raw inputs cover letters/uppercase, aliases, unknown/empty/multi-character/non-ASCII keys, four physical arrows with conflicting text, all16modifier combinations and extra modifier/repeat variants.','Search/pointer domains provide semantic/display data only; native result focus/Return/Button key handling and pointer delta/gesture dispatch are not claimed equivalent by this module. SearchResultsHost preserves those host paths.','Actual direct command performed booleans are native-state evidence, not a shared command eligibility implementation. Accessibility still invokes the existing command boundary.','New u32 IDs and typed safety guards are v1 contract decisions. Current Swift IDs are strings and duplicate up/down rows across timeline/search; retain legacy values separately.','Help currently uses the English stripped keys/action/title fields. Bilingual markdown methods are compared exactly; this delivery does not introduce a localized Help UI or Windows bindings.','Swift harness runs bounded synthesized events and source contracts, not an App build, live menu acceptance, focus/IME field test, real medium trace, device, release or Windows native acceptance.','The static table formatter allocates <=16KiB per returned table. Host must budget SDK encoded catalog/display copies; cancellation/deadline callback is owner-supplied, no clock or IO.'])
 jp.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
 mp.write_text(f'''# AT-RUST-013 parallel action catalog — 2026-10-04

本交付实现共享语义目录和macOS timeline纯路由，待main接SDK/FFI/App；没有完成AT-RUST-013或macOS验收。

## 内容和边界

870-file snapshot `{baseline['sourceCommit']}`，manifest SHA-256 `{info(manifest)['sha256']}`。869 baseline未变；lib仅追加两行mod/export（含前导空行），不得整文件覆盖main。新增源码/测试/fixture/报告均在owned范围。原两个交付、标注review-fix和其它缓存未写入。

29个v1闭集action ID、4个domain、3个section、19个row；旧Swift title/key-markup identity单独保留。Typed input仅normalized key、四个modifier bool、scope、text/IME ownership。constant-work零分配router返回Dispatch或Forward加focus-visible intent，不计算已有handler能否成功。Markdown每表<=16KiB，逐row取消检查，精确保留中文和末尾无换行。

当前Swift physical arrow分支在Command/Control guard之前，Option只改水平箭头为pan；Command字母forward，Ctrl标注cluster和裸方括号selection别名保留。TextInput/IME guard是新共享安全契约，native判断由host提供，不能以纯guard单测声称原生focus等价。SearchResults返回Forward(SearchResultsHost)，其语义/display目录已共享；SwiftUI结果步进/Return焦点和pointer gesture仍由native adapter接通。

## 实际验证

真实Swift目录生成19行、6张双语表；真实NSEvent/keyDown执行664输入，nextResponder实际观察forward，14个直接command调用记录入口并继续执行原handler。只有一行cache-only命令入口probe，无expected routing algorithm副本。Rust逐字段比较这些输出。

Rust viewer {rust_tests} tests（11新增）+ {doc_tests}个compile-fail目录immutability doctest；Swift oracle 2 tests与既有19 tests（Rendering13 + ShortcutCatalog6）；fmt、all-targets strict clippy、8-crate/35-license workspace verifier通过。最终compiler warning/error为0。命令、exit、时间、日志和source/input/output hash在同名JSON，独立cache保存冻结日志。Owned Python {len(list((CRATE/'oracle').glob('action_catalog_*.py')))}份/{len(audit['operations'])}个text access全部显式UTF-8，非ASCII内容按源码实际bytes生成。

## main接线提案

SDK生成versioned fixed-width action/domain/section/row/key/scope/route字段与bounded UTF-8 offset-length，不导出Rust布局。Host在路由前确定first-responder、text field、marked-text/IME ownership；先识别physical arrows，再lowercase整个charactersIgnoringModifiers，unknown/nil/multichar归Unknown；Forward传回原native event。Dispatch按domain连接已有keyboard/annotation handler，保留state eligibility和accessibility command入口。

Help/README改为generated records消费时保留顺序、legacy IDs、English display keys、localized gesture cells与六张表，继续跑两语言README/Help契约。本snapshot未改README。Search/pointer native行为和Windows键位不凭目录推断。

接线后还需SDK/ABI/API gates、实际adapter同664输入比较、text/IME/menu/window focus、search activation、pointer normalization、accessibility、App build及real medium trace GUI证据。当前合成事件/source-contract测试不替代这些验收。
''',encoding='utf-8')
 all_owned=[p for p in sorted(paths)if not p.is_relative_to(ROOT/'docs/migration-runs')]+[mp,jp]
 sp.write_text(''.join(f"{info(p)['sha256']}  {p.relative_to(ROOT)}\n"for p in all_owned),encoding='utf-8')
 print(dict(rustTests=rust_tests,swiftTests=21,newSourceFiles=len(owned_source),report=str(mp),jsonSHA256=info(jp)['sha256']))
if __name__=='__main__':main()
