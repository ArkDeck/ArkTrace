#!/usr/bin/env python3
"""Replay actual Swift Viewer in a private minimal package; no parser/SQL.

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
CRATE = ROOT / "rust/crates/arktrace-viewer"
CACHE = Path(os.environ.get("ARKTRACE_SWIFTPM_CACHE_ROOT", "/private/tmp/arktrace-viewer-swiftpm"))
SOURCE = CACHE / "oracle-source"
PLAN = "--plan" in sys.argv or "--migration-plan" in sys.argv
BOUNDARIES = "--boundaries" in sys.argv
DETAIL = "--detail" in sys.argv
# Original pre-migration plan output is retained as independent history.
STEM = "swift-detail-oracle" if DETAIL else "swift-boundary-oracle" if BOUNDARIES else "swift-plan-migration-oracle" if PLAN else "swift-geometry-oracle"
INPUT = CRATE / ("tests/fixtures/detail-inputs.json" if DETAIL else "tests/fixtures/boundary-inputs.json" if BOUNDARIES else "tests/fixtures/plan-inputs.json" if PLAN else "tests/fixtures/geometry-inputs.json")
OUTPUT = CRATE / f"tests/fixtures/{STEM}.json"


def main():
    if sum((PLAN, BOUNDARIES, DETAIL)) > 1:
        raise SystemExit("select one oracle mode")
    if not CACHE.is_absolute() or CACHE.resolve().is_relative_to(ROOT):
        raise SystemExit("oracle cache must be absolute and outside source")
    xcode = subprocess.check_output(["xcodebuild", "-version"], text=True, cwd=ROOT)
    if not xcode.startswith("Xcode 27."):
        raise SystemExit("Xcode 27 required")
    SOURCE.mkdir(parents=True, exist_ok=True)
    for directory in ("Sources/ArkTraceCore", "Sources/ArkTraceRendering", "Tests/ArkTraceRenderingTests", "scripts"):
        shutil.copytree(ROOT / directory, SOURCE / directory, dirs_exist_ok=True)
    (SOURCE / "Package.swift").write_text('''// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "ArkTrace", platforms: [.macOS(.v26)], targets: [
    .target(name: "ArkTraceCore", swiftSettings: [.strictMemorySafety()]),
    .target(name: "ArkTraceRendering", dependencies: ["ArkTraceCore"], swiftSettings: [.strictMemorySafety()]),
    .testTarget(name: "ArkTraceRenderingTests", dependencies: ["ArkTraceRendering"])
], swiftLanguageModes: [.v6])
''')
    harness = CRATE / "oracle/OracleHarness.swift"
    test = SOURCE / "Tests/ArkTraceRenderingTests/TimelineRenderingTests.swift"
    test.write_bytes(test.read_bytes() + b"\n" + harness.read_bytes() + (b"\n" + (CRATE / "oracle/DetailOracleHarness.swift").read_bytes() if DETAIL else b""))
    if DETAIL:
        view_source = SOURCE / "Sources/ArkTraceRendering/TimelineNSView.swift"
        view_source.write_text(view_source.read_text() + '\n' + """
// Oracle-only access to the actual private renderer style selection.
extension TimelineNSView {
    package static func detailOracleStyleName(_ category: String?) -> String {
        String(describing: visualStyle(for: category))
    }
}
""")
    subprocess.run(["git", "init", "--quiet"], cwd=SOURCE, check=True)
    environment = os.environ.copy()
    environment.update(ARKTRACE_SWIFTPM_CACHE_ROOT=str(CACHE),
        ARKTRACE_VIEWER_ORACLE_INPUT=str(INPUT),
        ARKTRACE_VIEWER_ORACLE_OUTPUT=str(OUTPUT))
    with (CACHE / f"{STEM}.log").open("w") as log:
        result = subprocess.run(["sh", "scripts/run-swiftpm.sh", "test", "--disable-sandbox", "--config-path", str(CACHE / "configuration"), "--security-path", str(CACHE / "security"), "--filter", ("TimelineRenderingTests.testActualDetailDTOOracle" if DETAIL else "TimelineRenderingTests.testParallelViewerBoundaryOracle" if BOUNDARIES else "TimelineRenderingTests.testParallelViewerPlanOracle" if PLAN else "TimelineRenderingTests.testParallelViewerGeometryOracle")],
            cwd=SOURCE, env=environment, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        print((CACHE / f"{STEM}.log").read_text()[-10000:])
        return result.returncode
    def digest(path):
        data = path.read_bytes()
        return {"path": str(path.relative_to(ROOT)), "sha256": hashlib.sha256(data).hexdigest(), "byteCount": len(data)}
    paths = sorted((ROOT / "Sources/ArkTraceRendering").glob("*.swift"))
    paths += sorted((ROOT / "Sources/ArkTraceCore").rglob("*.swift"))
    paths += [ROOT / "Tests/ArkTraceRenderingTests/TimelineRenderingTests.swift", harness, INPUT, OUTPUT]
    if DETAIL:
        paths += [CRATE / "oracle/DetailOracleHarness.swift", Path(__file__)]
    receipt = {"oracle": "actual TimelineGeometry, TimelineInteraction, TimelineNSView and TimelineSnapshotLoader", "xcode": xcode.strip(),
        "swift": subprocess.check_output(["swift", "--version"], text=True, cwd=ROOT).strip(),
        "scope": "actual loader detail mapping of bounded typed repository DTO pages" if DETAIL else "actual NSView selection event entry points and nonfinite pan differences" if BOUNDARIES else "actual loader with bounded synthetic repository pages" if PLAN else "geometry and hit/interaction projections; no copied oracle formulas", "vectors": len(json.loads(OUTPUT.read_text())),
        "sourceDigests": [digest(path) for path in paths]}
    if DETAIL:
        receipt["oracleOnlyTransformations"] = {
            "location": "cache copies only; repository Swift files unchanged",
            "test": "append original harness and DetailOracleHarness.swift",
            "renderer": "append access method that calls actual private visualStyle; no copied mapping",
            "augmentedSources": [{"path": str(p), "sha256": hashlib.sha256(p.read_bytes()).hexdigest(), "byteCount": p.stat().st_size}
                for p in (test, SOURCE / "Sources/ArkTraceRendering/TimelineNSView.swift")],
        }
    (CRATE / f"tests/fixtures/{STEM}-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"Swift oracle: {receipt['vectors']} actual engine results; {OUTPUT}")
    if "--regressions" in sys.argv:
        selected = "TimelineRenderingTests.test(DetailBudgetContract|GeometryAndHitTestingUseSameFrameAndDensityCarriesNoEventKey|OverlappingDetailHitUsesTheSameClosedStyleZOrderAsDrawing|PrimitivesOutsideTheViewportAreNeitherDrawnNorHitTested|InstantDetailRetainsDomainRangeButDrawsAtLeastOnePhysicalPixel|ExtremeInt64ViewportEndpointsRoundTripAndRulerDrawsWithoutTrap|PanDeltaSaturatesAndRejectsNonFinitePointDeltas|ViewportRejectsNonFiniteNanosecondsPerPoint|PanAndCursorAnchoredZoomAreOverflowSafe|PrimitiveBudgetIsGlobalAcrossTracks|AutomaticLODDoesNotGiveUnusedBudgetToTheFinalBusyTrack|DensityPrefetchChunksBeyondTheEventBatchQueryCap|LoaderQueriesOnlyVerticallyVisibleTracksWithOverscan|ExplicitDetailQueriesOnlyVerticallyVisibleTracksWithOverscan|NestedDepthRowsAreDistinctAndHitTestMatchesTheDrawnFrame|LoaderBuildsDepthRowsAndFlatteningReturnsToOneBand|DepthBeyondReservedRowsClampsInsideTheTrack)|TimelineDensitySelectionTests|TimelinePointerGestureTests.test(EndpointHitAreasAreLargeEnoughAndNeverOverlap|DraggingAnEndpointMovesOnlyThatEndpoint|PressingAwayFromAHandleStillSweepsANewRange)"
        with (CACHE / "swift-regressions.log").open("w") as log:
            result = subprocess.run(["sh", "scripts/run-swiftpm.sh", "test", "--disable-sandbox", "--config-path", str(CACHE / "configuration"), "--security-path", str(CACHE / "security"), "--filter", selected], cwd=SOURCE, env=environment, stdout=log, stderr=subprocess.STDOUT)
        print((CACHE / "swift-regressions.log").read_text()[-7000:])
        return result.returncode
    return 0


if __name__ == "__main__":
    sys.exit(main())
