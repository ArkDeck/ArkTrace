#!/usr/bin/env python3
"""Freeze the one guarded repair and dedicated tests; inherited canonical evidence explicit."""
import datetime,difflib,hashlib,json,re,subprocess
from pathlib import Path
OWN=Path(__file__).resolve().parent;ROOT=OWN.parents[1];REC=OWN/'receipts'
STEM='AT-RUST-011-inspector-counter-compat-fix-2026-10-04';REPAIR='rust/crates/arktrace-viewer/src/inspector_projection.rs'
TEST='rust/crates/arktrace-viewer/tests/inspector_counter_compat_regressions.rs'
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_text(encoding='utf-8'))
def write(p,v):p.write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
def main():
 manifest=read(ROOT/'parallel-snapshot.json');assert len(manifest['files'])==886
 changed=[]
 for x in manifest['files']:
  p=ROOT/x['path']
  if digest(p)!=x['sha256']or p.stat().st_size!=x['byteCount']:changed.append(x['path'])
 assert changed==[REPAIR],changed
 original=REC/'original-inspector-projection.rs';old=original.read_text(encoding='utf-8');new=(ROOT/REPAIR).read_text(encoding='utf-8')
 oldguard='''                event_key(
                    sample.key,
                    if series.scope == CounterScope::Cpu {
                        EventTable::Measure
                    } else {
                        EventTable::ProcessMeasure
                    },
                )?;'''
 newguard='''                let valid_table = sample.key.table == EventTable::Measure
                    || (series.scope == CounterScope::Process
                        && sample.key.table == EventTable::ProcessMeasure);
                if !valid_table {
                    return Err(InspectorProjectionError::InvalidEventKey);
                }'''
 assert old.count(oldguard)==1 and old.replace(oldguard,newguard)==new
 baseline_digest=next(x['sha256']for x in manifest['files']if x['path']==REPAIR);assert digest(original)==baseline_digest
 patch=''.join(difflib.unified_diff(old.splitlines(True),new.splitlines(True),fromfile='a/'+REPAIR,tofile='b/'+REPAIR))
 (OWN/'inspector-counter-compat.patch').write_text(patch,encoding='utf-8')
 pins=read(REC/'inherited-pins.json');third=Path(pins['sourceSnapshot'])
 for pin in pins['pins']:
  p=third/pin['path'];assert digest(p)==pin['sha256']and p.stat().st_size==pin['byteCount'],p
 swift=read(REC/'inherited-swift-source-identities.json')
 essential=['Sources/ArkTraceRendering/TimelineSnapshotLoader.swift','Sources/ArkTraceCore/Model/TraceEventModels.swift','Sources/ArkTraceCore/Model/TraceViewerModels.swift','Sources/ArkTraceStore/TraceSchemaAdapter.swift']
 matches=[]
 for path in essential:
  entry=next(x for x in swift if x['path']==path);assert digest(ROOT/path)==entry['baselineSHA256'];matches.append(entry)
 cases=read(OWN/'fixtures/canonical-counters.json');assert len(cases)==6
 assert sum(len(x['swiftFacts'])for x in cases)==11 and all(len(f)==19 for x in cases for f in x['swiftFacts'])
 test=(ROOT/TEST).read_text(encoding='utf-8');assert (OWN/'fixtures/canonical-counters.json').read_text(encoding='utf-8')in test
 before=read(REC/'baseline-replay.json');after=read(REC/'after-attempt-2.json')
 assert before['exitCode']==101 and after['exitCode']==0
 assert before['regressionSourceSHA256']==after['regressionSourceSHA256']==digest(ROOT/TEST)
 assert before['compiledSourceSHA256']==baseline_digest and after['compiledSourceSHA256']==digest(ROOT/REPAIR)
 beforelog=(ROOT/before['log']).read_text(encoding='utf-8')
 for name in ['inherited_legacy_process_measure_matches_actual_swift_facts','inherited_merged_same_rowid_keeps_both_physical_tables_and_values','every_scope_table_pair_accepts_only_actual_schema_sources_and_preserves_key']:assert name in beforelog
 assert 'InvalidEventKey'in beforelog and '3 failed'in beforelog
 gates=[]
 for p in sorted(REC.glob('*.json')):
  x=read(p)
  if isinstance(x,dict)and 'command'in x and 'logSHA256'in x:
   assert digest(ROOT/x['log'])==x['logSHA256'];gates.append(x)
 for name in ['after-attempt-2','clippy-attempt-2','related-attempt-2']:
  assert 'warning:'not in (REC/(name+'.log')).read_text(encoding='utf-8')
 comparison=dict(newCombinations=18,canonicalCases=6,canonicalFacts=11,fieldsPerFact=19,guardScopeTablePairs=12,
  legalScopeTablePairs=3,rejectedScopeTablePairs=9,beforeTypedFailingRegressions=3,afterPassingRegressions=4,
  existingInspectorRegressions=8,existingFrozenSwiftOracleCases=362,existingOracleTests=1,contractTests=20,
  exactSameFinalRegressionBeforeAfter=True,inheritedSwift=True,newSwiftOrDatabaseRun=False)
 write(REC/'comparison-summary.json',comparison)
 source_identity=dict(snapshotManifestSHA256=digest(ROOT/'parallel-snapshot.json'),sourceCommit=manifest['sourceCommit'],
  parentSnapshot=manifest['sourceDirectory'],baselineFiles=886,unchangedBaselineFiles=885,onlyModifiedBaseline=REPAIR,
  originalSourceSHA256=baseline_digest,fixedSourceSHA256=digest(ROOT/REPAIR),regressionSHA256=digest(ROOT/TEST),
  essentialSwiftSourceMatches=matches,sourceContractPins=[dict(path=p,sha256=digest(ROOT/p))for p in ['rust/crates/arktrace-store/src/schema.rs','rust/crates/arktrace-store/src/counters.rs','Sources/ArkTraceStore/TraceSchemaAdapter.swift','rust/crates/arktrace-viewer/src/lib.rs','rust/Cargo.toml','rust/Cargo.lock']],
  sourceDiff=patch)
 write(REC/'source-identity.json',source_identity)
 # All earlier handoffs are read only and verified at their original snapshots.
 old=[('parallel-inspector-projection-20261004','AT-RUST-011-parallel-inspector-projection-2026-10-04'),('parallel-quality-adapter-conformance-20261004','AT-RUST-012-parallel-quality-adapter-conformance-2026-10-04'),('parallel-cold-response-decoding-20261004','AT-RUST-012-parallel-cold-response-decoding-2026-10-04'),('parallel-presentation-20261004','AT-RUST-011-parallel-presentation-2026-10-04')]
 preserved=[]
 for directory,stem in old:
  base=ROOT.parent/directory;p=base/'docs/migration-runs'/(stem+'.sha256');lines=p.read_text(encoding='utf-8').splitlines()
  for line in lines:
   sha,path=line.split(maxsplit=1);assert digest(base/path)==sha,(directory,path)
  preserved.append(dict(snapshot=directory,filesVerified=len(lines),checksumManifestSHA256=digest(p)))
 write(REC/'prior-handoffs-unchanged.json',preserved)
 toolschain={}
 for key,cmd in [('rust',['rustc','+1.99.0','--version','--verbose']),('swift',['xcrun','swift','--version']),('xcode',['xcodebuild','-version'])]:
  toolschain[key]=subprocess.run(cmd,capture_output=True,encoding='utf-8',check=True).stdout.strip()
 write(REC/'toolchains.json',toolschain)
 doc=ROOT/'docs/migration-runs';doc.mkdir(exist_ok=True)
 body='''# AT-RUST-011 Inspector process counter physical-source 兼容修正

已修正纯 InspectorProjection 的 counter EventTable guard：CPU 仅允许 Measure；Process 允许 Measure 或 ProcessMeasure。保留真实 key.table/rowID，SchedSlice/ThreadState/Callstack/FrameSlice 和 CPU ProcessMeasure 仍返回同一 typed InvalidEventKey。时间、所有其它 facts、caps、取消、retained 类型及 API version 均未修改。

本次派生 frozen Inspector snapshot（ff496 parent，886 基线）。唯一修改的 baseline 是 `rust/crates/arktrace-viewer/src/inspector_projection.rs` 的 Counter table 验证块；其它 885 个 baseline、lib.rs、root manifests/lock、生产 Store/Swift/FFI/其它 viewer guard 均逐字节不变。新增专属 regression 文件、owned tools 和三份报告。交付应只导入该修正文件/patch及显式新增清单，不能覆盖旧 snapshot/lib/rootlock。

Store/Swift 的现有 schema 证明 CPU 来源集合为 measure，Process 来源为 process_measure 和兼容的 measure。Store 从实际 sample table 产生 EventTable，不按 scope 重写。原 guard 把所有 Process key 强行匹配 ProcessMeasure，导致合法 measure sample 被拒绝；同 rowID 来自双物理表时也丢失整个 projection。

**回归先失败后通过**

最终同一份测试 source hash 分别对原 guard 和修正 guard执行：baseline-replay 原 guard exit=101，legacy single、merged same-rowID 和 Process/Measure guard 三个测试确切因 InvalidEventKey 失败；after-attempt-2 修正 exit=0，四个 regression 全通过。原 guard 重放只替换隔离 cache source，未回写生产快照。before/before-attempt-2 早期原 guard失败也原样保留；第二次完善 CPU guard descriptor 使用真实 CPU DTO，最终改用 schema 显式允许集合做独立 truth-table，避免用实现布尔表达式生成 expected。没有把三个预期回归失败隐藏为 pass，receipt expectedExitCode=101 与原 log/hash 均保留。

18 个有意义新组合（≤24）：6 个真实 counter 查询 canonical + scope×6 table 的 12 个 guard pair。canonical 覆盖 11 个 Inspector × 全部 19 facts：legacy measure 单条、merged Measure/ProcessMeasure 同 rowID 双条且 value=999/99、CPU predecessor/positive/instant/nil duration、native process nil duration及 nullable metadata/unit empty。guard pair 中 3 个合法，9 个 typed 拒绝；接受时断言实际 key 未被改写。其它原 Inspector regressions 8 个以及已有 362 个 frozen actual Swift loader oracle cases（1 个测试）通过，继续覆盖 query/cancel/budget/时间语义。

**实际 canonical 继承**

原始最小和 bounded Rust repository/Swift output、actual commands、exit、日志和 source identities逐 hash继承自第三会话 parallel-repository-inspector-parity-20261004。所选 repositoryPage 与 Swift repositoryPage 相等，expected facts直接来自实际 Swift输出，没有自造 expected/归一化算法。6 case/11 fact完整输出来自真实 SQLite→typed repository→actual loader；本轮只重跑修正 Rust projector，未重开数据库或生成新 Swift output。实际 loader/Core/Store essential source baseline SHA 与本派生快照相同，private loader cache-only append wrapper、调用测试源码和原日志亦保留。完整继承 pins 与 source identity 见 receipts，不把继承当成新一轮 Store/Swift验收。

canonical JSON 同时嵌入专属 regression 常量，freeze 对原 fixture文本做逐字节核对。这让原 Cargo source mirror/CI 不需要额外复制 tools fixtures，也没有改根 runner/manifest。所有质量、CPU/thread/named/frame其它功能未被改动。

**已执行验证与交付边界**

- 原 guard最终 regression 101 →修正 regression 0，四个测试、18 新组合，19 facts逐字段比较。
- 全部相关旧 Inspector regression/oracle targets（8+1 tests，362 frozen canonical cases），非仅过滤测试名；保留初次按名字过滤的 limited run，不能拿它代替后续完整 targets。
- 原 root fmt --all --check、strict clippy -p arktrace-viewer --all-targets --all-features -D warnings；原 contract 20 tests、workspace/35 frozen licenses/SQLite pin verifier、license verifier和migration contract verifier。
- 精确 source diff、885 unchanged、lib/manifests/lock pin、既有 Inspector/quality/cold/presentation交付原 snapshot checksum校验；最终日志无 warning、没有 test ignored/skip。

本轮不重新编译 Swift，因为全部新增的接受行为已有真实 canonical；guard reject组合是 schema contract 的 typed regression，不声明有新的 Swift输出。Main 的 detail.rs/presentation.rs 对 process table 仍有同类硬编码；本快照不修改它们，具体同步建议见 MAIN_GUARD_PROPOSAL.md。ff496 parent 没有 navigation.rs，不凭这个旧 snapshot 猜当前 main 的行；主线在当前代码审查。Inspector 修正不能声称这些路径或 main集成已经完成。

旧 parent报告/checksum仍描述其当时的原 guard。它们在原 frozen snapshot验证，本派生修正版不改写历史报告来伪造接受证据。无提交/推送、不覆盖 root或第三会话生产文件；SDK typed page/decoded owner/aggregate credit/取消staging、macOS/Windows/GUI及正式验收由主线继续。本开发检查不代替完整diff选择的CI车道。
'''
 (doc/(STEM+'.md')).write_text(body,encoding='utf-8')
 baseline={x['path']for x in manifest['files']};reports={f'docs/migration-runs/{STEM}.{ext}'for ext in ['md','json','sha256']}
 extras=[p.relative_to(ROOT).as_posix()for p in ROOT.rglob('*')if p.is_file()and p.relative_to(ROOT).as_posix()not in baseline]
 assert all(p=='parallel-snapshot.json'or p==TEST or p in reports or p.startswith(OWN.relative_to(ROOT).as_posix()+'/')for p in extras),extras
 inventory=sorted([p for p in OWN.rglob('*')if p.is_file()]+[ROOT/TEST,ROOT/REPAIR,doc/(STEM+'.md')])
 planner=subprocess.run(['sh','scripts/ci_plan.sh'],cwd=ROOT,input='\n'.join(p.relative_to(ROOT).as_posix()for p in inventory)+'\n',capture_output=True,encoding='utf-8',check=True)
 write(REC/'ci-plan.json',dict(output=planner.stdout,allSelectedCIExecuted=False,reason='Unknown tools paths select all; isolated Rust repair validation is not complete CI/App/Windows evidence.'))
 result=dict(schemaVersion=1,task='AT-RUST-011',status='inspector-counter-compat-fix-validated',recordedAtUtc=datetime.datetime.now(datetime.UTC).isoformat(),
  sourceIdentity=source_identity,comparison=comparison,checks=gates,inheritedCanonical=pins,toolchains=toolschain,
  modifiedBaselineFiles=[REPAIR],baselineUnchanged=885,newRegressionFile=TEST,sourceDiffOnlyGuard=True,priorHandoffsUnchanged=preserved,
  mainOtherGuardsFixed=False,formalMigrationAcceptance=False,committed=False,pushed=False,
  ownedNewFiles=[p.relative_to(ROOT).as_posix()for p in sorted(OWN.rglob('*'))if p.is_file()]+[TEST]+sorted(reports),
  handoffInstruction='Import only inspector_projection.rs guard/patch and dedicated new inventory after review; preserve original snapshots/lib/root manifests/lock.')
 write(doc/(STEM+'.json'),result)
 allpaths=sorted([p for p in OWN.rglob('*')if p.is_file()]+[ROOT/TEST,ROOT/REPAIR,doc/(STEM+'.md'),doc/(STEM+'.json')])
 (doc/(STEM+'.sha256')).write_text(''.join(f'{digest(p)}  {p.relative_to(ROOT).as_posix()}\n'for p in allpaths),encoding='utf-8')
 print('frozen',len(allpaths),'checksums;885 baseline unchanged;report SHA256',digest(doc/(STEM+'.json')))
if __name__=='__main__':main()
