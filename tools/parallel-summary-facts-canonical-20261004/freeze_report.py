#!/usr/bin/env python3
"""Freeze owned canonical handoff and read-only scope audit; never run queries."""
import ast,hashlib,json,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];OWN=Path(__file__).resolve().parent
BASE='AT-RUST-007-parallel-summary-facts-canonical-2026-10-04'
REPORT=ROOT/'docs/migration-runs'/BASE
load=lambda p:json.loads(p.read_text(encoding='utf-8'))
def pin(p):
 d=p.read_bytes();return dict(path=str(p),byteCount=len(d),sha256=hashlib.sha256(d).hexdigest())
def save(p,v):p.write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
manifest=load(ROOT/'parallel-snapshot.json');assert len(manifest['files'])==1311
for r in manifest['files']:assert pin(ROOT/r['path'])['sha256']==r['sha256'],r['path']
for p in OWN.glob('*.py'):ast.parse(p.read_text(encoding='utf-8'),filename=str(p))
compiled=load(OWN/'fixtures/compiled-identities.json');canon=load(OWN/'fixtures/canonical-15.json');verified=load(OWN/'verification/canonical-verification.json')
assert verified['status']=='pass' and verified['actualSummaryRequests']==15 and verified['boundedTotal']==16
paths={p.relative_to(ROOT).as_posix() for p in OWN.rglob('*') if p.is_file()}
qa=OWN/'verification/final-scope-audit.json'
owned=paths|{qa.relative_to(ROOT).as_posix()}|{str(REPORT.relative_to(ROOT))+ext for ext in ('.md','.json','.sha256')}
ownedCount=len(owned);checkCount=ownedCount-1
REPORT.with_suffix('.md').write_text(f'''# AT-RUST-007 原 Swift summaryFacts canonical（2026-10-04）

完成 bounded canonical 交付：15 个实际 summary 请求（9 个 Store 成功、1 个原 Analysis 消费者成功、5 个预期错误），加 1 个原 schema 拒绝控制，共 16 项。未执行 native summary parity。固定 commit `817b33d39a9b7211039472ee80f076edd2dadc18`；1311 个 baseline 文件逐字节保持，{ownedCount} 个 owned 文件、{checkCount} 个 checks（包含 snapshot manifest；排除本 JSON 与 checksum，避免循环 hash）。

## 固定源与实际入口

- `parallel-snapshot.json` SHA256 `91e05c7db55f5ddbf48bf9eb55aa900d5e4e1ed27e7538cc6ced384843ea173c`。所有输入从该已提交候选捕获，未读取不稳定主工作树来替换实现。
- 编译原 Core/Store/Analysis 共 28 个 Swift 文件。原 repository 文件只在私有 cache 末尾追加两个 package 入口：观察内部 SQL、用原 TraceDatabase 和原 staging preparer 建造专属受控 fixture。原文件完整字节前缀、git blob、compiled SHA 均记录；任何 SQL、统计和归约算法未复制为 expected oracle。
- [原 Store](../../Sources/ArkTraceStore/SQLiteTraceRepository.swift#L789) 实际 `summaryFacts`；[原 Analysis](../../Sources/ArkTraceAnalysis/TraceSummary.swift#L168) 实际 `TraceSummaryEngine.summarize`，直接消费同一个原 repository。所有 IO/hash/SQLite、请求调用与观测在 detached Task/MainActor 外。
- 使用 `caches/parallel-summary-facts-canonical-swiftpm` 和 `caches/parallel-summary-facts-canonical-native`；源快照仅允许 `tools/parallel-summary-facts-canonical-20261004/**` 和本报告三件套新增。没有修改共享生产代码、viewer/root locks/SDK/ABI，也没有接 App/CLI。

## 真正留存的结果

| fixture / 请求 | 实际结果 |
|---|---|
| zlib full | process 100、thread 198、namedSlice 3067；CPU/state/counter 不支持为 null；stat trace=6138 |
| zlib 显式整个时长 | 相同目录/切片值；stat 不可 range-scoped，eventCountBySource=null |
| ability full | process/thread 250、counterSeries 2250；其余事件能力 null；stat trace=12396 |
| ability event budget 1 | counterSeries 1/truncated；stat trace=0/truncated；目录仍 250，使用独立 row budget |
| temporal full / 显式 [0,1000) | CPU topology 均 5；CPU slices 5/4、states 4/3、named slices 4/3，证明最终 instant 的 inclusive/half-open 差异 |
| temporal [200,400) | process/thread 2/truncated、CPU slices/states 2、named/counter 1；未知生命周期和非法生命周期质量原样保留 |
| temporal 低源行预算 | process/thread 0/truncated；probeTruncated.count=null，未把尾部推测为已观察非法行 |
| 原 Analysis 消费低预算 | 值取自原 facts；truncatedSections 为 cpuCount/processCount/threadCount/cpuSliceCount/threadStateCount；合并元数据 stat 质量和查询 lifecycle 质量 |
| 合法 1 ns、空事件且无能力的 trace | process/thread 0/非 truncated；所有可选 section 为 null，warnings/qualityIssues 为空 |
| 空显式 query、超时长、row budget 0 | 原 INVALID_ARGUMENT/request/retryable=false；0 条 query SQL |
| 过期 Swift deadline | 原 QUERY_TIMEOUT/querying/retryable=true；入口已过期，仅 1 条已观察 statement；未证明 VM 中途 deadline |
| 已取消 Swift Task | 原 CancellationError；未观察到 public typed CANCELLED 翻译，也没有 native admission/interrupt 证据 |
| 零时长 schema 控制 | 原 preparer/validator 拒绝 trace_range(1000,1000)，TRACE_DATABASE_INVALID/validating；child -5 的完整日志保留 |

上述表来自实际输出。完整可空计数对象、eventCountBySource、warnings、每个质量字段、错误、元数据及逐请求 SQL 观测在 [canonical](../../tools/parallel-summary-facts-canonical-20261004/fixtures/canonical-15.json)；[16 项 handoff golden](../../tools/parallel-summary-facts-canonical-20261004/fixtures/handoff-golden.json) 不含 SQL。原 encoders 同时保留，handoff 仅补 known optional 的显式 null，不重排或重算任何值。

## 需要主任务知道的兼容性差异

固定代码并不对所有 section 使用统一的 raw-source-row 上界。目录、stat 和 filter 目录先取 rowid prefix；事件 SQL 先匹配时间、再 LIMIT matching rows；CPU 先 DISTINCT；counter 先时间过滤和 DISTINCT(sample table,filter id)，再配合有独立 prefix 限制的 filter 目录。低预算 namedSlice=1/非 truncated 和 process=0/truncated 是原入口的真实差异。`summaryFacts` 顶部“every table sampled by rowid before filtering or reduction”的注释对事件/CPU/counter 已不准确；相邻实际实现已解释匹配/去重预算。[接口建议](../../tools/parallel-summary-facts-canonical-20261004/fixtures/interface-proposal.json) 按 section 写明此差异；若目标要求统一源行预算，应由主任务明确版本/契约并验证实际 native 工作量，不能把此报告当成其通过证据。

`NULL start_ts` 被计入并附 unavailableValue；不应丢弃或猜测成 0。非法 `end_ts<=start_ts` 被排除并标记 lower bound，所以本 fixture 的 final-instant process/thread 行并非合法生命周期，两个 invalidValue 的 count=2。最终 instant 的时间边界证明来自 sched/thread-state/callstack，而不是目录。零时长 Core range 可以建造，但 SQLite trace schema 必须严格正时长；原 summaryFacts 对零时长的注释不能作为 Ready DB 支持证据。

原 TraceSummaryFacts 的 synthesized encoder 会省略 nil，而不是显式 null；原 TraceSummary 的计数字段已有 null 编码。质量 issue 的 optional count/scope/message 原 encoder 也会省略；wire golden 仅补 null。需保留逐 section truncation、质量类别/范围/未知数量以及原数组顺序；Analysis 合并质量的规则直接由原实现执行，未仿制。

## 数据与 provenance

两份真实 DB 从上一 SDK parity 的 durable delivery 副本复制，验证了原 opening 中 parser identity、source hash/size、duration、preparation 和 schemaFingerprint。当前文件是新捕获 inode，不能声称仍是历史已关闭 SDK 连接的 inode。原 trace、delivery DB 的 SHA256 前后保持；四个当前 DB 的 SHA256、size、schema SHA、device/inode、mtime/ctime 与 mode0400 前后相同，目录成员不变，无 WAL/journal 产物。

| 当前 DB | byteCount | SHA256 |
|---|---:|---|
| zlib | 2351104 | `004cca580c192cb04d940d1e275dfffc9ff667c0b851e91dfaa2710242299a4a` |
| ability | 2072576 | `b9c19f1a3ccf53e75864a4d465d087fe61be46bc32fe11c1f5f4c413c5b7732a` |
| temporal | 143360 | `0bd192e748b5575a8ff195805ecd665e259023fd9e990607d93303034d994d43` |
| empty absent | 106496 | `5ceea34c1366c797f8eac6cafacbc36831fae990c4e1abb631aa720d0faa1940` |

受控 DB 恰为两个。temporal 基础数据字面取自原 Store test fixture，只增加专属 final instant 行；没有复制计数算法。零时长失败后的同一 owned empty DB inode 通过原 TraceDatabase 将 end_ts 改为1001，再经原 preparer/验证。观察开始后的四份 DB 不再写入。临时 schema-failure 也计入16项，不隐藏或将失败当成成功。

## 实际命令与检查

- `run.py build valid-empty-fixture`：Swift 6.4、Xcode27.0(27A266a)、Swift language6、strict memory safety、warnings-as-errors，exit0/0 warnings；Mach-O minOS26.0/SDK26.0，实际编译路径为 MacOSX27.0.sdk。宿主 macOS27.0 arm64；未在macOS26实机重跑。
- `run.py repair-construction valid-range`：原构造/prepare，exit0；两个受控 fixture。
- `run.py observe once`：唯一次15项真实 summary 调用，exit0；9 Store、1 Analysis 成功，5个预期错误全部验证。执行二进制 SHA256 `{compiled['executable']['sha256']}`。
- `verify.py` 和 handoff QA：实际 values/nullable/flags/order/quality/errors、原编译源 prefix/28源 pins、四 DB 同 inode/字节不变、两旧 SDK 报告不变均通过。没有重跑旧14/18/1000/32/135等矩阵。
- 失败保留：首次构造访问内部 TraceDatabase 导致 build exit1；后续 async Thread.isMainThread/strict-memory UnsafeCurrentTask 检查 build exit1；修复后 strict build 通过。首次零时长构造 child-5；同 inode合法fixture修复后通过。首次 observe 的 parent preflight 因 SQLite tuple 与 JSON list 比较而 exit1、未启动 child/0请求；规范化编码形状后唯一实际观察通过。没有降低编译检查、预算或时间语义。

完整 argv、exit、warnings、log SHA、source/oracle/fixture/compiled pins 保存在 [verification](../../tools/parallel-summary-facts-canonical-20261004/verification/) 与 JSON报告。固定候选中的历史报告仅含 summary延期、forwarding/stub 或 inventory；未找到此精确 Store facts canonical，所以只填补该缺口。

## 剩余边界与交付

固定817候选没有已实现的 native Store/SDK/FFI summaryFacts 入口，本轮未收到另一份冻结接口和 actual artifact，未编译不稳定主工作树来补齐。交付的是可直接消费的原 Swift canonical 与 typed/wire/errors/quality 提案；native 同 request parity、native VM deadline/cancel、owner/scratch预算、共享接口接线、CI/App构建和生产 publisher runtime 仍由主任务处理。没有声明完整 AT-RUST-007/012/013 通过；没有生产发布、PR或提交，也没有创建新聊天/agent或向主聊天反向发消息。

此前 SDK directory 联合生命周期报告已冻结且 SHA256 保持 `78f834d06e6b90b505be6896e49b0cdb6af3ec5503cbb595743fd0b3facc03e0`；完整1000轮实际联合链通过，旧700轮 parent缓冲停顿按失败保留，不拼接计数。上一 SDK parity 报告 SHA256 `9e2eb9190eda776fa5cd620445a3e41e50f1b52e7a2d1770021b3f12a7d7e4e7` 也保持。两项没有在本轮重跑。
''',encoding='utf-8')
actual={p.relative_to(ROOT).as_posix() for p in ROOT.rglob('*') if p.is_file()};baseline={r['path'] for r in manifest['files']}|{'parallel-snapshot.json'}
assert actual-baseline<=owned and baseline<=actual
main=Path('/Users/fuhanfeng/Dropbox/Code/Github/ArkTrace')
cmd=['git','status','--short'];status=subprocess.run(cmd,cwd=main,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,encoding='utf-8');assert status.returncode==0
head=subprocess.run(['git','rev-parse','HEAD'],cwd=main,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,encoding='utf-8');assert head.returncode==0
save(qa,dict(status='pass',baselineFileCount=1311,baselineManifest=pin(ROOT/'parallel-snapshot.json'),baselineByteHashesUnchanged=True,
    ownedFileCount=ownedCount,checkCount=checkCount,ownedPaths=sorted(owned),outsideOwnedAdditions=[],
    originalSwiftPrefixAndCompiledPinsVerified=True,actualObservationRequestCount=15,schemaRejectionControls=1,boundedTotal=16,
    checks=[dict(relativePath=p.relative_to(ROOT).as_posix(),**pin(p)) for p in sorted(OWN.rglob('*')) if p.is_file() and p!=qa],
    markdown=pin(REPORT.with_suffix('.md')),mainStatus=dict(command=cmd,exitCode=status.returncode,output=status.stdout),mainHeadAtFreeze=head.stdout.strip(),
    candidateSwitchPerformed=False,reverseMessageSent=False,subAgentsCreated=False))
allOwned=sorted(p for p in ROOT.rglob('*') if p.is_file() and p.relative_to(ROOT).as_posix() in owned)
checks=[dict(relativePath=p.relative_to(ROOT).as_posix(),**pin(p)) for p in [ROOT/'parallel-snapshot.json']+allOwned if p not in (REPORT.with_suffix('.json'),REPORT.with_suffix('.sha256'))]
assert len(checks)==checkCount
report=dict(schemaVersion=1,task='AT-RUST-007 bounded actual original Swift Store summaryFacts canonical',status='canonicalCompleteNativeParityNotExecuted',
    fixedCommit=manifest['fixedCommit'],snapshot=str(ROOT),snapshotManifest=pin(ROOT/'parallel-snapshot.json'),baselineFileCount=1311,ownedFileCount=ownedCount,checkCount=checkCount,
    boundedTotal=16,actualSummaryRequests=15,schemaRejectionControls=1,successfulStoreRequests=9,successfulOriginalAnalysisConsumerRequests=1,expectedSwiftErrorRequests=5,
    sources=load(OWN/'fixtures/oracle-source-identities.json'),compiled=compiled,toolchain=load(OWN/'verification/toolchain.json'),
    fixtures=load(OWN/'fixtures/input-observation.json'),realCaptureProvenance=load(OWN/'fixtures/real-capture-provenance.json'),controlledConstruction=load(OWN/'fixtures/controlled-construction-provenance.json'),
    databaseBefore=load(OWN/'fixtures/database-before.json'),databaseAfter=load(OWN/'fixtures/database-after.json'),canonical=canon,
    handoff=load(OWN/'fixtures/handoff-golden.json'),interfaceProposal=load(OWN/'fixtures/interface-proposal.json'),historicalGap=load(OWN/'fixtures/history-and-native-gap-assessment.json'),
    verification=verified,handoffAndPriorFreeze=load(OWN/'verification/handoff-and-prior-freeze-verification.json'),scopeAudit=load(qa),checks=checks,
    executions=[load(p) for p in sorted((OWN/'verification').glob('*.receipt.json'))],
    nonExecutionFailure=load(OWN/'verification/pre-observation-identity-drift.json'),
    untouched=['shared production files','baseline viewer/root lock files','SDK/ABI','old frozen snapshots/reports','main worktree'],
    limitations=['No frozen implemented native summaryFacts interface/artifact; no native parity','Actual Swift sections differ in source-prefix versus matching/distinct budget; uniform raw-source-row bound not proven',
        'Raw pre-cancelled Swift CancellationError is not typed public CANCELLED evidence','Expired Swift entry deadline is not native VM deadline/interrupt','No SDK/FFI summary owner budget or App/CLI integration',
        'No main CI/App rebuild or production publisher runtime, no macOS26/Windows run','Original encoders omit optionals; handoff explicit-null projection is encoding only'])
save(REPORT.with_suffix('.json'),report)
REPORT.with_suffix('.sha256').write_text(pin(REPORT.with_suffix('.json'))['sha256']+'  '+REPORT.with_suffix('.json').name+'\n',encoding='utf-8')
actual={p.relative_to(ROOT).as_posix() for p in ROOT.rglob('*') if p.is_file()}
assert actual==baseline|owned
print(json.dumps(dict(status='frozen',baseline=1311,owned=ownedCount,checks=checkCount,report=pin(REPORT.with_suffix('.json')),mainStatus=status.stdout)))
