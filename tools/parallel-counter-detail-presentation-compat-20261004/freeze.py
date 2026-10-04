#!/usr/bin/env python3
"""Finalize owned files only. The checksum manifest never includes itself."""
import datetime
import hashlib
import json
from pathlib import Path

OWN = Path(__file__).resolve().parent
ROOT = OWN.parents[1]
REPORT = ROOT / 'docs/migration-runs/AT-RUST-011-parallel-counter-detail-presentation-compat-2026-10-04'

def read(path): return json.loads(path.read_text(encoding='utf-8'))
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def digest(path): return {'path': str(path.relative_to(ROOT)), 'byteCount': path.stat().st_size, 'sha256': sha(path)}
def write(path, value): path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')

def main():
    manifest = ROOT / 'parallel-snapshot.json'; baseline = read(manifest)
    base_paths = {v['path'] for v in baseline['files']}
    assert len(base_paths) == 946
    for v in baseline['files']: assert sha(ROOT / v['path']) == v['sha256'], v['path']
    assert not list(OWN.rglob('__pycache__'))
    report_paths = [REPORT.with_suffix(s) for s in ['.md', '.json', '.sha256']]
    own_list = OWN / 'receipts/owned-files.json'
    new_paths = {str(p.relative_to(ROOT)) for p in ROOT.rglob('*') if p.is_file()
                 and str(p.relative_to(ROOT)) not in base_paths and p != manifest}
    new_paths.update(str(p.relative_to(ROOT)) for p in report_paths + [own_list])
    assert all(p.startswith(str(OWN.relative_to(ROOT)) + '/') or p in {str(p.relative_to(ROOT)) for p in report_paths} for p in new_paths)
    write(own_list, {'onlyOwnedNewFiles': sorted(new_paths), 'all946OriginalFilesUnchanged': True,
                     'baselineManifestSHA256': sha(manifest), 'productionExportHunks': [], 'producerChanges': []})
    verification = read(OWN / 'receipts/final-verification.json')
    comparison = read(OWN / 'receipts/comparison.json')
    inheritance = read(OWN / 'receipts/inheritance.json')
    checks = verification['checks']
    latest = {}
    for v in checks:
        label = v['name'].split('-attempt')[0]
        prior = latest.get(label)
        if prior is None or v['name'] > prior['name']: latest[label] = v
        assert sha(Path(v['log']['path'])) == v['log']['sha256']
    required = ['swift-canonical', 'isolated-fmt-check', 'isolated-build', 'isolated-clippy', 'isolated-observe',
                'isolated-controls', 'root-fmt-check', 'root-clippy', 'related-detail-presentation',
                'contract-tests', 'workspace-license', 'license', 'migration-contract']
    assert all(latest[n]['exitCode'] == 0 for n in required)
    assert latest['legal-counter-contract-red']['exitCode'] == 101
    sources = verification['publicRustSources']
    report = {'schemaVersion': 1, 'recordedAtUtc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'task': 'AT-RUST-011 actual Counter DTO detail and Presentation compatibility combinations; validation only',
        'status': 'frozen-validation-complete;two-legal-input-groups-still-rejected-by-unmodified-producers',
        'snapshot': str(ROOT), 'sourceCommit': baseline['sourceCommit'], 'snapshotManifestSHA256': sha(manifest),
        'baselineFiles': 946, 'all946BaselineFilesUnchanged': True,
        'allowedOwnership': [str(OWN.relative_to(ROOT)) + '/**', str(REPORT.relative_to(ROOT)) + '.{md,json,sha256}'],
        'ownedFiles': digest(own_list),
        'publicEntriesActuallyInvoked': ['arktrace_viewer::detail_query', 'arktrace_viewer::map_detail_page', 'arktrace_viewer::present'],
        'namedBridgeSymbolExists': False,
        'actualEngineBridgeSource': 'rust/crates/arktrace-engine/src/no_cache.rs::NoCacheSession::viewer_details',
        'actualNativeEngineBridgeExecutedThisRun': False,
        'newCombinations': 12, 'inheritedActualDTOGroups': 6, 'derivedControlCombinations': 6,
        'actualSwiftNewCanonicalGroups': 6, 'actualSwiftNewCanonicalSamples': 11,
        'actualSwiftNewTestsPassed': 1, 'matchedAcceptedRealGroups': 4, 'matchedAcceptedRealSamples': 8,
        'legalRejectedGroups': comparison['failures'], 'blockedLegalFunctionCalls': 4,
        'controlCombinationsPassed': 6, 'newRustControlTestsPassed': 3, 'newLegalContractTestsFailed': 1,
        'relatedRustTestsPassed': 17, 'contractTestsPassed': 20,
        'consumerBoundary': comparison['publicEntryLimitation'], 'comparison': comparison['comparison'],
        'expectedAlgorithmCopied': False, 'domainDTOCopied': False,
        'pageFixtureAdmission': 'EventPage is not Deserialize; fixture transport constructs public EventPage fields after actual CounterSeries/DataQuality decoding',
        'presentationIsFullInspector': False, 'inspectorCanonicalReusedForSharedFactsOnly': True,
        'qualityComparison': 'actual inherited machine quality vs mapper output; exact status/order/multiplicity,not a new Swift Core adapter claim',
        'swiftCarrierQualityIncluded': False, 'truncationAndCapability': 'map_detail_page preserves source page headers;present has no page input/output',
        'scopeIdentityControls': 'wrong filter/ipid rejected only by source-aware mapper;present retains raw DTO identity and has no source filter',
        'actualStoreOrParserRerun': False, 'priorFullInspectorMatrixRerun': False,
        'priorFrozenEvidenceChecksumsVerified': len(inheritance['allFrozenPriorChecksums']),
        'inheritedRawCopies': inheritance['selectedCopies'],
        'swiftOracle': 'actual original TimelineSnapshotLoader.load + TimelineDetailPalette.color + private visualStyle cache-only accessor',
        'swiftCompiler': (OWN / 'receipts/swift-toolchain-attempt2.log').read_text(encoding='utf-8').strip(),
        'xcodeCompiler': (OWN / 'receipts/xcode-toolchain-attempt2.log').read_text(encoding='utf-8').strip(),
        'rustCompiler': (OWN / 'receipts/rust-toolchain-attempt3.log').read_text(encoding='utf-8').strip(),
        'compiledSwiftSourceIdentity': digest(OWN / 'receipts/swift-source-identities.json'),
        'compiledMirrorVerified': verification['swiftCompiledMirrorMatchesOriginalAndSeams'],
        'rootGateSourceIdentity': digest(OWN / 'receipts/root-gate-source-identities.json'),
        'externalLockedDependenciesRootMatches': verification['externalLockedDependenciesMatchedRoot'],
        'rootManifestOrLockChanged': False, 'productionSources': sources,
        'commandsAndExitCodes': checks,
        'latestGates': {n: {'name': latest[n]['name'], 'exitCode': latest[n]['exitCode'], 'logSHA256': latest[n]['log']['sha256']} for n in required + ['legal-counter-contract-red']},
        'setupAndComparatorFailuresRetained': [
            {'name': 'swift-canonical', 'reason': 'new test harness async call inside XCTUnwrap autoclosure;fixed by awaiting separately;first source and log preserved'},
            {'name': 'isolated-build', 'reason': 'real EventPage lacks Deserialize;fixed fixture carrier uses actual public item/quality types;first source and log preserved'},
            {'name': 'isolated-controls', 'reason': 'CGColor alpha JSON integer1 vs Rust float1.0;fixed only declared RGBA slots compare exact f64;all Int64 equality unchanged'},
            {'name': 'root-fmt-check', 'reason': 'archive has no Git index;stock runner sourced zero files;fixed cache-only Git source of all946 pinned originals'},
            {'name': 'license', 'reason': 'wrong verifier filename;actual verify_licenses.sh exit0;original failure retained'}],
        'finalSwiftRustBuildClippyWarnings': 0,
        'hunkProposal': digest(OWN / 'main-counter-guard-proposal.patch'), 'hunkProposalAppliedOrCompiled': False,
        'mainHandoff': digest(OWN / 'MAIN_HANDOFF.md'),
        'formalAT_RUST_011Passed': False, 'macOSMigrationPassed': False, 'fullSDKFFIAppOrInteractionAcceptance': False,
        'notExecuted': ['production guard repair', 'current main integration tests', 'actual Engine session/App end-to-end', 'FFI/SDK ABI', 'App native interaction', 'full diff CI planner owner-main', 'formal migration acceptance'],
        'noCommitPushOrMainEdits': True,
        'receipts': [digest(p) for p in sorted((OWN / 'receipts').glob('*')) if p.is_file()]}
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    write(REPORT.with_suffix('.json'), report)
    REPORT.with_suffix('.md').write_text('''# AT-RUST-011 Counter detail / Presentation 兼容组合验证

验证交付已冻结；固定提交 `44505359b10a27a8d33549c0e36f8ce7af5d3ee5` 的生产 guard 未改。12 个新增组合包含 6 组继承真实 Rust/Swift Store DTO 和 6 个派生控制。新增实际 Swift SnapshotLoader/DetailPalette canonical 覆盖 6 组、11 个 primitive。

legacy process `measure:1`，以及 `measure:1` / `process_measure:1` 同 rowID 双表输入，均被实际 `map_detail_page` 和 `present` 返回 `InvalidEvidence`，共四个函数调用失败。新契约测试实际 exit 101，未把 observer exit 0 视为产品通过。其余 4 组、8 个 primitive 的标签、颜色、style、identity、时间/key 与 Swift 相符；6 个控制符合入口契约。

准确入口为 `detail_query` / `map_detail_page`；该基线没有 `DetailEvidenceBridge` 命名符号。Presentation 直接消费 CounterSeries，不能消费 DetailInput；quality/truncation/capability 仅在 mapper page 验证，Presentation 无这些字段。5 字段 DetailInput / 13 顶层字段 Presentation 事实不等于完整 19 字段 Inspector。原 Store/parser/362 Inspector 矩阵没有重跑。

通过：新增 Swift 测试 1 项、新 Rust 控制测试 3 项、相关 Rust 回归 17 项、合同测试 20 项、isolated/root fmt 和严格 clippy、workspace/license/migration verifiers；最终编译/clippy 零 warning。初始 harness、EventPage 解码、CGColor JSON 表示、archive 无 Git index、错误 verifier 路径失败均保留原日志和相关 source。整数不转 Double；RGBA 只按其声明浮点类型作精确比较。

946 个基线文件逐 SHA 验证不变，仅新增 tools 和本报告三件套。附两个 main-owned guard 最小 hunk 提案及普通公开 API consumer；提案没有应用或编译。CPU 仍只能 Measure，process 可接受 Measure / ProcessMeasure，使用原 key，保留 source/filter/ipid guard。主会话接入后须以 exit 0 通过当前红契约测试。

这份报告不证明当前主线已修、Engine/App 完整接通、FFI/SDK、交互或正式 AT-RUST-011/macOS 完成。详见 JSON 的实际命令、退出码和源/日志哈希，以及 tools 的 MAIN_HANDOFF.md。
''', encoding='utf-8')
    actual = {str(p.relative_to(ROOT)) for p in ROOT.rglob('*') if p.is_file()
              and str(p.relative_to(ROOT)) not in base_paths and p != manifest}
    assert actual == new_paths - {str(REPORT.with_suffix('.sha256').relative_to(ROOT))} or actual == new_paths
    artifacts = sorted(ROOT / p for p in new_paths if not p.endswith('.sha256'))
    REPORT.with_suffix('.sha256').write_text(''.join(sha(p) + '  ' + str(p.relative_to(ROOT)) + '\n' for p in artifacts), encoding='utf-8')
    for p in report_paths: assert p.is_file()
    print(json.dumps({'report': str(REPORT.with_suffix('.json')), 'reportSHA256': sha(REPORT.with_suffix('.json')),
                      'ownedNewFiles': len(new_paths), 'checksumEntries': len(artifacts), 'all946BaselineUnchanged': True}, ensure_ascii=False))

if __name__ == '__main__': main()
