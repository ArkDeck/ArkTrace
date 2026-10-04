#!/usr/bin/env python3
"""Audit the correction and freeze its report without modifying prior evidence."""
from pathlib import Path
import json,hashlib,shutil,datetime,re
ROOT=Path(__file__).resolve().parents[4]
def info(p):
 b=p.read_bytes();return {'path':str(p.relative_to(ROOT))if p.is_relative_to(ROOT)else str(p),'byteCount':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def main():
 r=ROOT;ev=r.parent/'caches/parallel-annotations-review-fix-cargo/frozen-evidence';m=r/'parallel-snapshot.json';base=json.loads(m.read_text(encoding='utf-8'))
 changed=[f['path']for f in base['files']if info(r/f['path'])['sha256']!=f['sha256']]
 assert set(changed)=={'rust/crates/arktrace-viewer/src/annotations.rs','rust/crates/arktrace-viewer/tests/annotation_oracle.rs','rust/crates/arktrace-viewer/tests/annotation_regressions.rs'},changed
 commands=json.loads((ev/'command-results.json').read_text(encoding='utf-8'));assert len(commands)==5 and all(c['exitCode']==0 for c in commands)
 old=json.loads((r/'docs/migration-runs/AT-RUST-011-parallel-annotations-2026-10-04.json').read_text(encoding='utf-8'));inherited=[]
 for c in old['verification']:
  if c['name']in ['swiftOracle','swiftRegressions']:
   src=Path(c['log']['path']);assert info(src)['sha256']==c['log']['sha256'];dst=ev/src.name;shutil.copyfile(src,dst);inherited.append({'name':c['name'],'executedInOriginalFrozenDelivery':True,'source':c['log'],'frozenCopy':info(dst),'exitCode':c['exitCode'],'passed':c['passed']})
 receipt=r/'rust/crates/arktrace-viewer/tests/fixtures/annotation-swift-receipt.json';j=json.loads(receipt.read_text(encoding='utf-8'))
 for f in j['sourceDigests']:
  p=r/f['path']if not Path(f['path']).is_absolute()else Path(f['path']);assert info(p)['sha256']==f['sha256'],f
 fixture=[info(p)for p in sorted((r/'rust/crates/arktrace-viewer/tests/fixtures').glob('annotation-*.json'))]
 new=[r/'rust/crates/arktrace-viewer/tests/annotation_projection_budget.rs',*sorted((r/'rust/crates/arktrace-viewer/oracle').glob('annotation_projection*.py'))]
 log=(ev/'annotation-projection-test.log').read_text(encoding='utf-8');passed=sum(map(int,re.findall(r'test result: ok\. (\d+) passed',log)))
 report={'schemaVersion':1,'task':'AT-RUST-011 annotation persistence projection review correction','status':'correctionVerified; productionIntegrationPending','createdAtUtc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'snapshot':{'manifest':info(m),'baselineFiles':858,'unchangedBaselineFiles':855,'modifiedBaselineFiles':changed,'originalDeliveriesWritten':False,'mainCheckoutWritten':False,'actionCatalogSnapshotWritten':False},'changedFiles':[info(r/p)for p in changed],'ownedNewSourceFiles':[info(p)for p in new],'commands':commands,'actualCommandRecord':info(ev/'command-results.json'),'results':{'rustViewerTestsPassed':passed-3,'compileFailDocTestsPassed':3,'newRuntimeRegressionTests':4,'oracleStatesCompared':748,'oracleCases':74,'oracleActions':674,'fmtPassed':True,'strictAllTargetClippyPassed':True,'workspaceVerifierPassed':True,'swiftExecutedAgain':False},'inheritedActualSwiftEvidence':inherited,'unchangedSwiftFixtures':fixture,'swiftReceipt':info(receipt),'apiChange':{'privateFields':['api_version','flags','marks'],'readOnlyAccessors':['api_version() -> u32','flags() -> &[AnnotationFlag]','marks() -> &[AnnotationMark]'],'retainedBytes':'Computed from current struct, Vec and label capacities; no creation-time cache. Clone reports its own capacities. serde preserves apiVersion/flags/marks/retainedBytes field names and measures current capacity.','sdk':'Generate fixed-width wire fields and bounded UTF-8 slices from read-only accessors. No Rust Vec/String/reference ABI. SDK integration stays with coordinator.'},'limitations':['One state/projection value remains individually bounded. Host must budget the simultaneous sum of live state, transactional temporary, every projection/clone, encoding and borrowed sorted arrays; allocator headers are excluded. No claim of a combined 8MiB owner cap.','No Swift production source change: original actual Swift oracle source/input/output digests checked unchanged, success logs copied read-only; current Rust compares all 748 states. This is inherited actual Swift evidence, not a new Swift run.','No App/SDK/FFI/disk/native GUI/Windows integration or AT-RUST-011 acceptance performed. Original source/projection algorithms and valid Swift data output stay unchanged.','Original Swift logs include sandbox_extension_issue_file messages already recorded in the original receipt; pass exit codes do not prove native entitlement behavior.']}
 prefix=r/'docs/migration-runs/AT-RUST-011-annotation-projection-fix-2026-10-04';jp=prefix.with_suffix('.json');mp=prefix.with_suffix('.md');sp=prefix.with_suffix('.sha256')
 jp.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
 mp.write_text(f'''# AT-RUST-011 annotation projection review correction — 2026-10-04

独立派生 snapshot：`{r.name}`；manifest SHA-256 `{info(m)['sha256']}`。858 baseline 中855文件未变，修改仅 annotations.rs 与两份专属 annotation tests；lib、manifest、lock、原交付和 action catalog 均未写入。

## 修复

`AnnotationPersistence` 的 `api_version/flags/marks` 变为私有，包外读 `api_version()`、`flags()`、`marks()`；不返回可变 Vec/String。`retained_bytes()` 按当前 struct、Vec capacity、String capacity 计算，包含保留 mark 子集未使用的 record slots。Clone 不复制容量缓存，序列化保留四个原字段名并输出当前计量。纯 projection 数据和顺序未变。

## 验证

Rust viewer {passed-3} tests + 3 compile-fail doctests passed；4新增回归覆盖filtered-mark spare slots、clone当前容量与序列化、owner替换后projection独立、host同时预算提案。格式、all-targets `-D warnings` clippy、8-crate/35-license workspace verifier通过。实际命令、exit、日志hash见同名JSON。

原Swift 74 cases / 674 actions / 748 states fixture与源码receipts逐项hash一致，原实际Swift成功日志只读复制到本任务缓存；当前Rust重新逐字段比较全部748状态。本次未重跑Swift，不能把继承证据称为新运行。原Swift安全作用域环境消息仍属原报告限制。

## 集成边界

SDK生成方从只读accessors转fixed-width记录与bounded UTF-8。8MiB是每份state/projection上限；host必须合计live state、transaction临时副本、每份projection/clone、encoding和借用排序数组，并在取消/完成后释放。allocator headers不计入。没有App/SDK/FFI/disk/GUI/Windows接通或AT-RUST-011正式验收。
''',encoding='utf-8')
 paths=[r/p for p in changed]+new+[mp,jp];sp.write_text(''.join(f"{info(p)['sha256']}  {p.relative_to(r)}\n"for p in paths),encoding='utf-8')
 print({'changed':changed,'runtimeTests':passed-3,'docTests':3,'report':str(mp),'reportSHA256':info(jp)['sha256']})
if __name__=='__main__':main()
