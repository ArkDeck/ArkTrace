#!/usr/bin/env python3
"""Execute original loadCatalog/actions with access/logging seams in private cache.

No production Swift or root manifest is edited. The source-index Git metadata
is outside the snapshot and records no commit; runner --locked contracts stay.
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

def main():
    cache = Path(os.environ["ARKTRACE_SWIFTPM_CACHE_ROOT"])
    if not cache.is_absolute() or cache.resolve().is_relative_to(ROOT): raise SystemExit("external absolute cache required")
    source = cache / "navigation-oracle-source"
    source.mkdir(parents=True, exist_ok=True)
    for directory in ("Sources", "Tests", "scripts", "ThirdParty", "Fixtures"):
        shutil.copytree(ROOT / directory, source / directory, dirs_exist_ok=True,ignore=shutil.ignore_patterns("__pycache__", "trace_streamer"))
    for path in ROOT.iterdir():
        if path.is_file() and not path.is_symlink(): shutil.copyfile(path, source / path.name)
    controller_path = "Sources/ArkTraceAppSupport/TraceDocumentController.swift"
    original = (ROOT / controller_path).read_text()
    patched = original.replace("    private func scheduleSnapshot(preference: TimelineDetailPreference) {", "    private func scheduleSnapshot(preference: TimelineDetailPreference) {\n        navigationOraclePreferences.append(preference)")
    patched = patched.replace("    private func persistViewState() {", "    private func persistViewState() {\n        navigationOraclePersistCount += 1")
    patched = patched.replace("    public private(set) var trackGroups: [TraceTrackGroup] = []", "    public private(set) var trackGroups: [TraceTrackGroup] = []\n    package var navigationOraclePreferences: [TimelineDetailPreference] = []\n    package var navigationOraclePersistCount = 0")
    assert patched != original and "navigationOraclePersistCount += 1" in patched
    patched += "\n" + (CRATE / "oracle/navigation_controller_seam.swift").read_text()
    (source / controller_path).write_text(patched)
    rendering_path = "Sources/ArkTraceRendering/TimelineNSView.swift"
    (source / rendering_path).write_text((ROOT / rendering_path).read_text()+"\n"+(CRATE / "oracle/navigation_rendering_seam.swift").read_text())
    test_path = source / "Tests/ArkTraceAppSupportTests/NavigationCanonicalOracleTests.swift"
    shutil.copyfile(CRATE / "oracle/navigation_harness.swift", test_path)
    # No other session can share this mutable source or dependency cache.
    environment = os.environ.copy()
    environment.pop("GIT_DIR",None); environment.pop("GIT_WORK_TREE",None)
    subprocess.run(["git","init","--quiet"],cwd=source,env=environment,check=True)
    environment.update(ARKTRACE_NAVIGATION_INPUT=str(CRATE / "tests/fixtures/navigation-inputs.json"),ARKTRACE_NAVIGATION_OUTPUT=str(CRATE / "tests/fixtures/navigation-swift-oracle.json"),ARKTRACE_NAVIGATION_RENDERING_INPUT=str(CRATE / "tests/fixtures/navigation-rendering-inputs.json"),ARKTRACE_NAVIGATION_RENDERING_OUTPUT=str(CRATE / "tests/fixtures/navigation-rendering-swift-oracle.json"))
    environment.update(ARKTRACE_NAVIGATION_RESTORE_INPUT=str(CRATE / "tests/fixtures/navigation-restore-inputs.json"),ARKTRACE_NAVIGATION_RESTORE_OUTPUT=str(CRATE / "tests/fixtures/navigation-restore-swift-oracle.json"),ARKTRACE_NAVIGATION_TEST_CACHE=str(cache/"navigation-test-fixtures"))
    environment["ARKTRACE_NAVIGATION_WHITESPACE_OUTPUT"] = str(CRATE/"tests/fixtures/navigation-whitespace-swift-oracle.json")
    command = ["sh", "scripts/run-swiftpm.sh", "test", "--disable-sandbox", "--config-path",str(cache / "configuration"),"--security-path",str(cache / "security"),"--filter","NavigationCanonicalOracleTests"]
    with (cache / "navigation-oracle.log").open("w") as log: result = subprocess.run(command,cwd=source,env=environment,stdout=log,stderr=subprocess.STDOUT)
    def digest(path):
        data = path.read_bytes(); return dict(path=str(path),sha256=hashlib.sha256(data).hexdigest(),byteCount=len(data))
    receipt = dict(schemaVersion=1,canonical="Current Swift TraceDocumentController.loadCatalog + original action methods + TimelineNSView private focus/anchor methods",command=command,exitCode=result.returncode,sourceFiles=[digest(ROOT / controller_path),digest(ROOT / rendering_path)],patchedSources=[digest(source / controller_path),digest(source / rendering_path)],seams=[digest(CRATE / "oracle/navigation_controller_seam.swift"),digest(CRATE / "oracle/navigation_rendering_seam.swift")],harness=digest(CRATE / "oracle/navigation_harness.swift"),inputs=[digest(CRATE / "tests/fixtures/navigation-inputs.json"),digest(CRATE / "tests/fixtures/navigation-rendering-inputs.json")],log=digest(cache / "navigation-oracle.log"),note="Synthetic typed repository facts; no real DB corpus and no parser. Only access/logging changed; catalog and actions execute original code. Unicode matcher is a host port.")
    receipt["inputs"].append(digest(CRATE/"tests/fixtures/navigation-restore-inputs.json"))
    receipt["sourceFiles"] += [digest(ROOT/p) for p in ("Sources/ArkTraceAppSupport/TraceViewStateStore.swift","Sources/ArkTraceRendering/TimelineModels.swift","Sources/ArkTraceCore/Model/TraceModels.swift","Sources/ArkTraceCore/Model/TraceEventModels.swift")]
    if result.returncode == 0: receipt["outputs"] = [digest(CRATE / "tests/fixtures/navigation-swift-oracle.json"),digest(CRATE / "tests/fixtures/navigation-rendering-swift-oracle.json"),digest(CRATE/"tests/fixtures/navigation-restore-swift-oracle.json"),digest(CRATE/"tests/fixtures/navigation-whitespace-swift-oracle.json")]
    (CRATE / "tests/fixtures/navigation-swift-receipt.json").write_text(json.dumps(receipt,indent=2)+"\n")
    print(json.dumps(dict(exitCode=result.returncode,log=str(cache / "navigation-oracle.log"))))
    if result.returncode: print((cache / "navigation-oracle.log").read_text()[-10000:])
    return result.returncode

if __name__ == "__main__": sys.exit(main())
