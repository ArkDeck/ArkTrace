#!/usr/bin/env python3
"""Replay actual Swift analysis in a private minimal package; no parser/SQL.

The snapshot has no .git, required by the stable Swift runner. The harness
therefore creates its own cache-owned Git source mirror, preserving all source
bytes, then appends only a test method to the existing repository test seam.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[4]
CRATE = ROOT / "rust/crates/arktrace-analysis"
CACHE = Path(os.environ.get("ARKTRACE_SWIFTPM_CACHE_ROOT", "/private/tmp/arktrace-parallel-analysis-swiftpm"))
SOURCE = CACHE / "oracle-source"
DEVIATIONS = "--deviations" in sys.argv
MAINLINE = "--mainline" in sys.argv
STEM = "swift-mainline" if MAINLINE else ("swift-deviations" if DEVIATIONS else "swift-oracle")
INPUT = CRATE / ("tests/fixtures/mainline-inputs.json" if MAINLINE else ("tests/fixtures/deviation-inputs.json" if DEVIATIONS else "tests/fixtures/inputs.json"))
OUTPUT = CRATE / f"tests/fixtures/{STEM}.json"


def main():
    if not CACHE.is_absolute() or CACHE.resolve().is_relative_to(ROOT):
        raise SystemExit("oracle cache must be absolute and outside source")
    xcode = subprocess.check_output(["xcodebuild", "-version"], text=True, cwd=ROOT)
    if not xcode.startswith("Xcode 27."):
        raise SystemExit("Xcode 27 required")
    SOURCE.mkdir(parents=True, exist_ok=True)
    for directory in ("Sources/ArkTraceCore", "Sources/ArkTraceAnalysis", "Tests/ArkTraceAnalysisTests", "scripts"):
        shutil.copytree(ROOT / directory, SOURCE / directory, dirs_exist_ok=True)
    (SOURCE / "Package.swift").write_text('''// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "ArkTrace", platforms: [.macOS(.v26)], targets: [
    .target(name: "ArkTraceCore", swiftSettings: [.strictMemorySafety()]),
    .target(name: "ArkTraceAnalysis", dependencies: ["ArkTraceCore"], swiftSettings: [.strictMemorySafety()]),
    .testTarget(name: "ArkTraceAnalysisTests", dependencies: ["ArkTraceAnalysis"])
], swiftLanguageModes: [.v6])
''')
    harness = CRATE / "oracle/OracleHarness.swift"
    test = SOURCE / "Tests/ArkTraceAnalysisTests/TraceAgentBatchTests.swift"
    test.write_bytes(test.read_bytes() + b"\n" + harness.read_bytes())
    subprocess.run(["git", "init", "--quiet"], cwd=SOURCE, check=True)
    environment = os.environ.copy()
    environment.update(ARKTRACE_SWIFTPM_CACHE_ROOT=str(CACHE),
        ARKTRACE_ANALYSIS_ORACLE_INPUT=str(INPUT),
        ARKTRACE_ANALYSIS_ORACLE_OUTPUT=str(OUTPUT))
    with (CACHE / "oracle.log").open("w") as log:
        result = subprocess.run(["sh", "scripts/run-swiftpm.sh", "test", "--disable-sandbox", "--config-path", str(CACHE / "configuration"), "--security-path", str(CACHE / "security"), "--filter", "TraceAgentBatchTests.testParallelAnalysisOracle"],
            cwd=SOURCE, env=environment, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        print((CACHE / "oracle.log").read_text()[-10000:])
        return result.returncode
    def digest(path):
        data = path.read_bytes()
        return {"path": str(path.relative_to(ROOT)), "sha256": hashlib.sha256(data).hexdigest(), "byteCount": len(data)}
    paths = sorted((ROOT / "Sources/ArkTraceAnalysis").glob("*.swift"))
    paths += sorted((ROOT / "Sources/ArkTraceCore").rglob("*.swift"))
    paths += [ROOT / "Tests/ArkTraceAnalysisTests/TraceAgentBatchTests.swift", harness, INPUT, OUTPUT]
    receipt = {"oracle": "actual Swift TraceDeterministicAnalysisEngine + retainingRows", "xcode": xcode.strip(),
        "swift": subprocess.check_output(["swift", "--version"], text=True, cwd=ROOT).strip(),
        "scope": "six pure section projections; longSlices excluded before Swift global row projection", "vectors": len(json.loads(OUTPUT.read_text())),
        "sourceDigests": [digest(path) for path in paths]}
    (CRATE / f"tests/fixtures/{STEM}-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"Swift oracle: {receipt['vectors']} actual engine results; {OUTPUT}")
    if "--regressions" in sys.argv:
        selected = "TraceAgentBatchTests.test(DeterministicAnalysisCoversClippingRankingStatesLatencyAndHotBuckets|SchedulingPercentileNearestRankAndUnsupportedAreStable|SchedulingRequiresObservedRunnableEndAndPreservesClosedProof|HotBucketsUseExactNonDivisibleBoundariesAndCountEachSwitchOnce|AnalysisTruncatedSourcesDoNotClaimExactMatchedCounts)|TraceViewerAnalysisTests.test(RangeAndDeterministicAnalysisAgreeOnThreadStateDistribution|ThreadStateDistributionTruncationIsReportedNotSilent|RangeAnalysisIsBoundedDeterministicAndCancellationAware|TopThreadsSplitTimePerCPUAndTheSplitSumsToTheTotal)"
        with (CACHE / "swift-regressions.log").open("w") as log:
            result = subprocess.run(["sh", "scripts/run-swiftpm.sh", "test", "--disable-sandbox", "--config-path", str(CACHE / "configuration"), "--security-path", str(CACHE / "security"), "--filter", selected], cwd=SOURCE, env=environment, stdout=log, stderr=subprocess.STDOUT)
        print((CACHE / "swift-regressions.log").read_text()[-7000:])
        return result.returncode
    return 0


if __name__ == "__main__":
    sys.exit(main())
