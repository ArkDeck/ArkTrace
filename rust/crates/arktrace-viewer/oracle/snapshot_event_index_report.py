#!/usr/bin/env python3
"""Audit exact isolated ownership and write final evidence with UTF-8 text."""
from pathlib import Path
from datetime import datetime, timezone
from collections import Counter
import hashlib, json, re, subprocess
ROOT=Path(__file__).resolve().parents[4]
CRATE=ROOT/'rust/crates/arktrace-viewer'; F=CRATE/'tests/fixtures'; V=F/'snapshot-event-index-verification'
STEM='docs/migration-runs/AT-RUST-011-parallel-snapshot-event-index-2026-10-04'
def h(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def receipt(p):return dict(path=str(p.relative_to(ROOT)),sha256=h(p),byteCount=p.stat().st_size)
manifest=ROOT/'parallel-snapshot.json'; baseline=json.loads(manifest.read_text(encoding='utf-8')); baseline_paths={x['path']:x for x in baseline['files']}
assert h(manifest)=='ed5f6be369f88393330220538e4aa52dcbedb971afa5a3b0b0921ec8a72a9a2c'
changed=[]
for rel,f in baseline_paths.items():
 p=ROOT/rel; assert p.is_file(),rel
 if h(p)!=f['sha256']: changed.append(rel)
assert changed==['rust/crates/arktrace-viewer/src/lib.rs'],changed
new_lib=(ROOT/changed[0]).read_text(encoding='utf-8')
assert hashlib.sha256(new_lib.replace('mod snapshot_event_index;\n','').replace('pub use snapshot_event_index::*;\n','').encode('utf-8')).hexdigest()==baseline_paths[changed[0]]['sha256']
def allowed(rel):
 return (rel=='rust/crates/arktrace-viewer/src/lib.rs' or rel.startswith('rust/crates/arktrace-viewer/src/snapshot_event_index') or rel.startswith('rust/crates/arktrace-viewer/tests/snapshot_event_index_') or rel.startswith('rust/crates/arktrace-viewer/oracle/snapshot_event_index_') or rel.startswith('rust/crates/arktrace-viewer/tests/fixtures/snapshot-event-index-') or rel in [STEM+s for s in ('.md','.json','.sha256')])
new_paths=[]
for p in ROOT.rglob('*'):
 if not p.is_file(): continue
 rel=str(p.relative_to(ROOT))
 if rel in baseline_paths or rel=='parallel-snapshot.json':continue
 assert allowed(rel),rel
 new_paths.append(rel)
owned=sorted(set(changed+new_paths+[STEM+s for s in ('.md','.json','.sha256')]+[str((V/name).relative_to(ROOT)) for name in ('ci-plan.log','ci-plan-receipt.json')]))
# Planner consumes the complete proposed import, not the outer ignored .build path.
plan_cmd=['sh','scripts/ci_plan.sh']; diff=''.join(x+'\n' for x in owned)
run=subprocess.run(plan_cmd,cwd=ROOT,input=diff,text=True,encoding='utf-8',capture_output=True)
assert run.returncode==0
plan_log=V/'ci-plan.log';plan_log.write_text(run.stdout+run.stderr,encoding='utf-8')
plan_receipt=V/'ci-plan-receipt.json';plan_receipt.write_text(json.dumps(dict(command=plan_cmd,exitCode=run.returncode,inputPaths=owned,note='Owned proposed import paths. Complete CI lanes remain owner/native-runner work; no production commit made.',log=receipt(plan_log)),indent=2)+'\n',encoding='utf-8')
# Adding planner evidence stays in rust/* and does not change selected lanes.
owned=sorted(set(owned+[str(plan_log.relative_to(ROOT)),str(plan_receipt.relative_to(ROOT))]))
inputs=json.loads((F/'snapshot-event-index-inputs.json').read_text(encoding='utf-8'))
output=json.loads((F/'snapshot-event-index-swift-oracle.json').read_text(encoding='utf-8'))
checks=json.loads((V/'receipt.json').read_text(encoding='utf-8'));assert all(c['exitCode']==0 for c in checks)
feature_check=json.loads((V/'ci-feature-clippy-receipt.json').read_text(encoding='utf-8'));assert feature_check['exitCode']==0
canonical=json.loads((F/'snapshot-event-index-swift-canonical-receipt.json').read_text(encoding='utf-8'));regressions=json.loads((F/'snapshot-event-index-swift-regressions-receipt.json').read_text(encoding='utf-8'));assert canonical['exitCode']==regressions['exitCode']==0
rust_log=(V/'viewer-tests.log').read_text(encoding='utf-8');summaries=re.findall(r'test result: ok\. (\d+) passed; (\d+) failed; (\d+) ignored',rust_log)
totals=[sum(int(x[i]) for x in summaries) for i in range(3)];assert totals==[110,0,0],totals
counts=Counter(x['lookup']['kind'] for x in output['rows']);nil_matches=sum(x['lookup'].get('location',{}).get('hasInspector')==False for x in output['rows'])
assert len(output['rows'])==sum(len(c['queries']) for c in inputs['cases'])==11923
swift_audit={}
for label in ('canonical','regressions'):
 s=(F/f'snapshot-event-index-swift-{label}.log').read_text(encoding='utf-8')
 swift_audit[label]=dict(compilerWarnings=s.count('warning:'),runtimeSkips=len(re.findall(r"' skipped ",s)),sandboxExtensionDiagnostics=s.count('sandbox_extension_issue_file failed'))
md=f"""AT-RUST-011/013 独立 snapshot EventKey lookup index 原型已验证，尚未接入生产 owner/SDK/App。基线是 `{baseline['sourceCommit']}` 的 922 文件 immutable git archive；main 未提交 annotation 改动未包含在本快照。旧 navigation、Unicode、预算交付保持冻结。

本次可导入的是新 `snapshot_event_index.rs`、两组 Rust 测试及独立 canonical/evidence，既有 `lib.rs` 仅增加 module 与 pub-use 两行。根 Cargo manifests/lock、旧 Viewer 模块、Contract、Store、Engine、SDK、FFI、App 和 CI 均未修改。完整 owned paths、文件 hash、命令与退出码见同名 JSON；校验入口为 `shasum -a 256 -c {STEM}.sha256`。校验清单包含 JSON 自身，避免循环 hash。

索引借用 bounded track/primitive facts，保留原始 track→primitive 顺序位置；每个 detail 提供真实 EventKey 与 inspector 是否存在，density 使用不允许字段的 variant。身份是六种物理 table 与 signed Int64 rowID，不校验正数、不从 Inspector/pid/tid/frame 推断。私有 Vec 按完整 key 和原始位置进行可取消的原地 heapsort，然后原地去重；因此首条 inspector 为 nil 仍返回 Matched(hasInspector=false) 并阻挡后续重复。nil key、空 snapshot 或缺失 key 返回 NoMatch。查找用二分，索引不构造、复制或保留 Inspector。

实际 Swift canonical 使用本基线的 `TraceDocumentController.inspector(for:)`、公开 `hoverEvent` 和 `selectEvent`。cache-only 源码镜像仅注入 snapshot、开放访问、为原循环添加 enumerated 索引及首匹配位置日志；原 detail/EventKey 判定、首个 return、hover/select 方法未被替换。预期位置来自这个原始匹配分支，未在 oracle 中复制扫描算法。最小真实 Inspector 只用 name 保存位置标记；完整 Inspector fields projection 属于另一个任务。source、patched source、seam、logging patch、harness、输入、输出与执行 log 的 SHA-256 均保留在 Swift receipt。

295 个 snapshot、73,704 条 primitive facts、11,923 次查询逐项比较 Rust 和实际 Swift；直接 Inspector、hover、select 三条路径一致。结果为 {counts['matched']:,} Matched（其中 {nil_matches:,} 为 nil inspector）和 {counts['noMatch']:,} NoMatch。输入包含 nil snapshot/key、空 track、density-only、跨 track 重复、六表同 row、Int64.min/max/负数、同 generation 的替换、10,000 track 与 20,000 primitive 边界、逆序详情和固定种子的顺序组合。

宿主必须将 index 与同一个不可变 snapshot 成对拥有。`SnapshotEventIndexIdentity` 包含 sessionID、generation、snapshotRevision；每次 snapshot 替换（包括同 viewport generation 的 loading/loaded、nil 替换）都需要不重用的 revision，不能使用指针地址或 wrap/reuse token。lookup 即使 key 为 nil 也拒绝三者任一不匹配。旧 index 仍能以自己的旧 token 查询旧位置，所以调用方必须传 CURRENT token，并在任何 await/state transition 后及解引用/发布前重新核对 owner 当前身份，持有对应旧/新 snapshot，检查返回位置边界。该核对不是用 index token 授权旧 snapshot 发布。token 发放、snapshot/index 原子替换和异步 admission 留给主线 owner；本原型没有改变既有 publication gate。

构建上限为 10,000 track / 20,000 primitive（包括 density），计数预检在 index 分配前执行；自定义 retained budget 范围为 1..1,048,576 bytes。实际 retained 计算为 `size_of(index) + Vec.capacity × size_of(entry)`，去重不 shrink，所以重复 key 的 spare allocation 仍收费。arm64 实测 inline=72、entry=32、input fact=24、borrowed track slice=16 bytes；空索引 72、单 detail 104、20,000 重复 detail 去重成 1 条仍为 640,072 bytes。原地 heapsort/dedup 没有 heap scratch，局部变量为固定大小；checkpoint 至多每 64 个扫描/sort 工作单元，二分每次探测检查并在成功返回前再检查。

借用输入的逻辑 fixed-size payload 最大为 20,000×24 + 10,000×16 = 640,000 bytes，但其 Vec spare capacity、外层 headers、actual immutable snapshot/Inspector/string pools 都是宿主所有权，API 无法从 slice 得知或限制这些 allocation。1MiB 是单个 index 预算，不是整个 snapshot 的内存上限。host 峰值需合计 snapshot + 输入 parent 的实际 capacity + old/new index retained；按本 arm64 最大 logical input 和两个 index 估算仅这些固定记录已达 1,920,144 bytes，再加实际 snapshot、容器与 allocator/RSS overhead。该算式不构成整机内存或性能通过。

Rust 的 11 项新回归覆盖 first-nil、表/行身份、density 多余字段拒绝、空/max/+1 输入、重复 capacity、budget failure/recovery、旧 session/generation/revision、u64 extremes、逆序 heapsort、每个 build/lookup checkpoint 的 cancellation/deadline all-or-error 与后续恢复；另 1 项实际 Swift oracle replay。完整 Viewer 110 项测试通过，无失败/ignored；fmt、workspace all-targets strict clippy（另含 CI all-features）、workspace 35 个 frozen third-party license identity、TraceStreamer/product license gate 全部退出 0。Swift 1 项 canonical 和 5 项既有 Inspector/density/search/observation 回归通过，无 compiler warning 或 runtime skip。回归日志包含 17 条 sandbox_extension_issue_file 诊断，测试仍通过，记录保留。

修正前的失败证据也保留：首次 clippy 的 usize 类型推断失败、Swift 镜像缺 Apps 源目录（4 项 Controller 测试已通过、1 项 source contract 失败），以及第二轮新 density unknown-fields 回归失败。已分别补类型、补 cache-only Apps 拷贝、将 density 改为空 struct variant；最终测试没有放宽断言或跳过。

建议主线 adapter 从实际 primitive 提供 exact detail key / inspector-presence 与 density slots，保留所有 slot 顺序，避免从几何 visibility/hit 树推断。现有 Rust PrimitiveInput 没有 inspector flag，本任务不修改它；host facts projection 与 aggregate ownership 要在 owner/SDK 任务实现。返回位置由同一 immutable snapshot 的宿主读取真实 Inspector。构建失败不得携带 partial index；宿主可保留仍有效的旧 snapshot/index 或对新 snapshot 采用另行授权的 fallback，但不能把旧 index 应用于已替换 snapshot。该建议未新增 wire command、FFI、SDK、App 接线或生产行为。

本机为 macOS 27.0 arm64 / Xcode 27.0 / Swift 6.4 / Rust 1.99.0，deployment baseline 没有降低。完整 owned diff 的 CI planner 选择 Rust macOS 和 Rust Windows 两条车道；此次完成上述局部 gate，未运行完整 workspace all-features test/build/smoke、SDK consumer gate 或 native Windows，未提交/推送。该原型不声称 AT-RUST-011/013 完成、native GUI performance、App integration、macOS 26 runtime 或 Windows 验收通过。
"""
md_path=ROOT/(STEM+'.md');md_path.parent.mkdir(parents=True,exist_ok=True);md_path.write_text(md,encoding='utf-8')
report=dict(schemaVersion=1,status='verified-isolated-prototype-not-production-integrated',createdAtUtc=datetime.now(timezone.utc).isoformat(),task='AT-RUST-011/013 snapshot first-detail EventKey index',baseline=dict(sourceCommit=baseline['sourceCommit'],manifest=receipt(manifest),fileCount=len(baseline_paths),baselineChangedPaths=changed,otherBaselineFilesUnchanged=len(baseline_paths)-1),ownedPaths=owned,ownedFileReceipts=[receipt(ROOT/x) for x in owned if x not in (STEM+'.json',STEM+'.sha256')],canonical=dict(snapshotCount=295,primitiveFacts=73704,queryCount=11923,matched=counts['matched'],nilInspectorMatched=nil_matches,noMatch=counts['noMatch'],paths=['private inspector','public hoverEvent','public selectEvent'],receipt=canonical,regressionsReceipt=regressions),rust=dict(passed=110,failed=0,ignored=0,newTests=12,commands=checks,ciAllFeatureStrictClippy=feature_check),swiftAudit=swift_audit,memory=dict(maximumTracks=10000,maximumPrimitives=20000,maximumSingleIndexRetainedBytes=1048576,measuredInlineBytes=72,measuredEntryBytes=32,measuredFactBytes=24,measuredBorrowedTrackBytes=16,measuredMaximumIndexRetainedBytes=640072,maximumLogicalBorrowedPayloadBytes=640000,maximumLogicalInputPlusTwoIndicesBytes=1920144,heapSortScratchBytes=0,note='Parent input spare capacity and actual snapshot/Inspector/string/allocator/RSS ownership remain separate host aggregate; no RSS/GUI benchmark claim.'),identity=dict(fields=['sessionID','generation','snapshotRevision'],ownerRequirements=['Fresh nonreused revision on every snapshot replacement including equal generation/nil/loading','Current identity check before lookup/dereference and after await/state transitions','Existing publication gate remains authoritative; index identity does not authorize old publish']),ciPlan=dict(command=plan_cmd,stdout=run.stdout,exitCode=run.returncode,fullLanesCompleted=False),limits=['Prototype only; no owner/SDK/FFI/App/wire integration','No complete Inspector facts projection','No Windows native runner','No macOS 26 runtime proof','No native GUI performance proof','No complete CI workspace build/all-features test/migration smoke/SDK consumer gate','No commit/push/PR'],archivedLogMappings=[dict(receipt='snapshot-event-index-verification/first-attempt-receipt.json',original='snapshot-event-index-verification/clippy.log',archived='snapshot-event-index-verification/first-attempt-clippy.log'),dict(receipt='snapshot-event-index-verification/second-attempt-receipt.json',original='snapshot-event-index-verification/viewer-tests.log',archived='snapshot-event-index-verification/second-attempt-viewer-tests.log'),dict(receipt='snapshot-event-index-swift-regressions-first-attempt-receipt.json',original='snapshot-event-index-swift-regressions.log',archived='snapshot-event-index-swift-regressions-first-attempt.log')],failuresPreserved=['first-attempt-clippy.log: E0689 detail_count type, fixed usize','snapshot-event-index-swift-regressions-first-attempt.log: Apps omitted from private source mirror, fixed copy','second-attempt-viewer-tests.log: density unit variant ignored extra fields, fixed empty struct variant'])
(ROOT/(STEM+'.json')).write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
(ROOT/(STEM+'.sha256')).write_text(''.join(h(ROOT/x)+'  '+x+'\n' for x in owned if x!=STEM+'.sha256'),encoding='utf-8')
print(json.dumps(dict(ownedFiles=len(owned),checksums=len(owned)-1,jsonSHA256=h(ROOT/(STEM+'.json')),report=str(md_path))))
