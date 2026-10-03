#!/usr/bin/env python3
"""Generate actual Swift Viewer search outputs and typed source-call transcripts.

This checks query semantics, not parser, real corpus, Viewer or release gates.
Databases are independently built from retained SQL, sealed, hashed and removed.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import sys

ROOT = Path(__file__).resolve().parents[4]
CRATE = ROOT / "rust/crates/arktrace-store"
CACHE = Path("/private/tmp/arktrace-search-swiftpm")
INPUT = CRATE / "tests/fixtures/search-pages-input.json"
OUTPUT = CRATE / ("tests/fixtures/swift-search-before.json" if "--before" in sys.argv else "tests/fixtures/swift-search-pages.json")


def digest(path):
    data = path.read_bytes()
    return {"path": str(path.relative_to(ROOT)), "sha256": hashlib.sha256(data).hexdigest(), "byteCount": len(data)}


def main():
    if "--before" in sys.argv and OUTPUT.exists():
        raise SystemExit("Retained search before-fix oracle already exists; preserve its historical bytes")
    xcode = subprocess.check_output(["/usr/bin/xcodebuild", "-version"], text=True).strip()
    assert xcode.startswith("Xcode 27.")
    source = CACHE / "oracle-source"
    source.mkdir(parents=True, exist_ok=True)
    for name in ("ArkTraceCore", "ArkTraceStore", "ArkTraceAnalysis"):
        target = source / "Sources" / name
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(ROOT / "Sources" / name, target)
    shutil.copytree(ROOT / "scripts", source / "scripts", dirs_exist_ok=True)
    target = source / "Sources/SearchOracle"
    target.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(CRATE / "oracle/SearchOracle.swift", target / "SearchOracle.swift")
    (source / "Package.swift").write_text('''// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "ArkTrace", platforms: [.macOS(.v26)], targets: [
    .target(name: "ArkTraceCore", swiftSettings: [.strictMemorySafety()]),
    .target(name: "ArkTraceStore", dependencies: ["ArkTraceCore"], swiftSettings: [.strictMemorySafety()]),
    .target(name: "ArkTraceAnalysis", dependencies: ["ArkTraceCore"], swiftSettings: [.strictMemorySafety()]),
    .executableTarget(name: "SearchOracle", dependencies: ["ArkTraceCore", "ArkTraceStore", "ArkTraceAnalysis"])
], swiftLanguageModes: [.v6])
''')
    subprocess.run(["/usr/bin/git", "init", "--quiet"], cwd=source, check=True)
    environment = os.environ.copy()
    environment["ARKTRACE_SWIFTPM_CACHE_ROOT"] = str(CACHE)
    with (CACHE / "oracle-build.log").open("w") as log:
        result = subprocess.run(["sh", "scripts/run-swiftpm.sh", "build", "--disable-sandbox", "--config-path", str(CACHE / "configuration"), "--security-path", str(CACHE / "security"), "--product", "SearchOracle"], cwd=source, env=environment, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        print((CACHE / "oracle-build.log").read_text()[-12000:])
        result.check_returncode()
    assert "warning:" not in (CACHE / "oracle-build.log").read_text()
    executable = CACHE / "build/out/Products/Debug/SearchOracle"
    executable_pin = hashlib.sha256(executable.read_bytes()).hexdigest()
    inputs = json.loads(INPUT.read_text())
    manifest = json.loads((ROOT / "ThirdParty/TraceStreamer/macx/manifest.json").read_text())
    parser = {k: manifest[k] for k in ("name", "reportedVersion", "binarySHA256", "upstreamRepository", "upstreamRevision", "architecture", "adapterVersion", "buildRecipeVersion")}
    records, databases = [], []
    with tempfile.TemporaryDirectory(prefix="arktrace-search-oracle-", dir="/private/tmp") as directory:
        for fixture in inputs["fixtures"]:
            db = Path(directory) / (fixture["id"] + ".sqlite")
            connection = sqlite3.connect(db)
            try:
                connection.executescript(inputs["schemaSQL"] + fixture["sql"])
                connection.commit()
            finally:
                connection.close()
            db.chmod(0o400)
            pin = hashlib.sha256(db.read_bytes()).hexdigest()
            cases = [c for c in inputs["cases"] if c["fixture"] == fixture["id"]]
            source_info = {"sha256": "a" * 64, "byteCount": 100}
            result = subprocess.run([str(executable), str(db), json.dumps(parser), json.dumps(source_info), json.dumps(cases)], check=True, capture_output=True, text=True, timeout=60)
            assert len(result.stdout.encode()) <= 8 * 1024 * 1024 and not result.stderr
            values = json.loads(result.stdout)
            assert [v["id"] for v in values] == [c["id"] for c in cases]
            assert hashlib.sha256(db.read_bytes()).hexdigest() == pin
            records.extend(values)
            databases.append({"fixture": fixture["id"], "sha256": pin, "byteCount": db.stat().st_size, "bytesUnchanged": True})
    assert hashlib.sha256(executable.read_bytes()).hexdigest() == executable_pin
    assert len(records) == len(inputs["cases"])
    OUTPUT.write_text(json.dumps(records, ensure_ascii=False, indent=2) + "\n")
    paths = []
    for name in ("ArkTraceCore", "ArkTraceStore", "ArkTraceAnalysis"):
        paths += sorted((ROOT / "Sources" / name).rglob("*.swift"))
    paths += [CRATE / "oracle/SearchOracle.swift", Path(__file__), ROOT / "scripts/run-swiftpm.sh", INPUT, OUTPUT]
    receipt = {"oracle": "actual Swift TraceViewerSearchEngine + SQLiteTraceRepository; complete typed source-call transcript", "scope": "controlled SQL query semantics; no real parser/corpus/Viewer acceptance", "xcode": xcode, "swift": subprocess.check_output(["/usr/bin/swift", "--version"], text=True).strip(), "vectors": len(records), "recordedSourceCalls": sum(len(r["steps"]) for r in records), "executableSHA256": executable_pin, "databases": databases, "sourceDigests": [digest(p) for p in paths]}
    (CRATE / ("tests/fixtures/swift-search-before-receipt.json" if "--before" in sys.argv else "tests/fixtures/swift-search-pages-receipt.json")).write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"Actual Swift search oracle: {len(records)} controlled cases; databases unchanged and temporary root removed")


if __name__ == "__main__":
    main()
