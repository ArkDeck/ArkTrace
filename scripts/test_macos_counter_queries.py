#!/usr/bin/env python3
"""Native counter samples/series/Agent pages against unchanged Swift sources.

Also freezes fresh installed Swift CLI documents for packaged Rust CLI replay.
Requires Xcode 27, Rust 1.99 and the three pinned small traces; no release claim.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from record_swift_oracle import run_case
from test_macos_event_queries import install_swift
from test_macos_parser_process import ROOT, cargo, digest


def query(start, end, **changes):
    value = {"range": {"startNs": start, "endNs": end}, "filterID": None,
             "cpu": None, "processKey": None, "pid": None, "name": None,
             "nameMatch": "exact", "limit": 128}
    value.update(changes)
    return value


def arguments(fixture, value):
    values = ["query", str(ROOT / "Fixtures/traces" / fixture), "--view", "counters",
              "--start-ns", str(value["range"]["startNs"]), "--end-ns", str(value["range"]["endNs"]),
              "--limit", str(value["limit"])]
    for key, flag in [("cpu", "--cpu"), ("processKey", "--process-key"),
                      ("pid", "--pid"), ("filterID", "--filter-id"), ("name", "--name")]:
        if value[key] is not None:
            values += [flag, str(value[key])]
    if value["name"] is not None:
        values += ["--name-match", value["nameMatch"]]
    return values


def build_swift_oracle():
    cache = Path("/private/tmp/arktrace-counter-swiftpm")
    source = cache / "oracle-source"
    source.mkdir(parents=True, exist_ok=True)
    for name in ("ArkTraceCore", "ArkTraceStore", "ArkTraceAnalysis"):
        destination = source / "Sources" / name
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(ROOT / "Sources" / name, destination)
    shutil.copytree(ROOT / "scripts", source / "scripts", dirs_exist_ok=True)
    target = source / "Sources/CounterOracle"
    target.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / "rust/crates/arktrace-store/oracle/CounterOracle.swift", target / "CounterOracle.swift")
    (source / "Package.swift").write_text('''// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "ArkTrace", platforms: [.macOS(.v26)], targets: [
    .target(name: "ArkTraceCore", swiftSettings: [.strictMemorySafety()]),
    .target(name: "ArkTraceStore", dependencies: ["ArkTraceCore"], swiftSettings: [.strictMemorySafety()]),
    .target(name: "ArkTraceAnalysis", dependencies: ["ArkTraceCore"], swiftSettings: [.strictMemorySafety()]),
    .executableTarget(name: "CounterOracle", dependencies: ["ArkTraceCore", "ArkTraceStore", "ArkTraceAnalysis"])
], swiftLanguageModes: [.v6])
''')
    subprocess.run(["/usr/bin/git", "init", "--quiet"], cwd=source, check=True)
    environment = os.environ.copy()
    environment["ARKTRACE_SWIFTPM_CACHE_ROOT"] = str(cache)
    log_path = cache / "oracle-build.log"
    with log_path.open("w") as log:
        result = subprocess.run(["sh", "scripts/run-swiftpm.sh", "build", "--disable-sandbox",
            "--config-path", str(cache / "configuration"), "--security-path", str(cache / "security"),
            "--product", "CounterOracle"], cwd=source, env=environment, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        print(log_path.read_text()[-12000:], file=sys.stderr)
        result.check_returncode()
    assert "warning:" not in log_path.read_text()
    executable = cache / "build/out/Products/Debug/CounterOracle"
    assert executable.is_file(), executable
    return executable, log_path


def main():
    options = argparse.ArgumentParser(description=__doc__)
    options.add_argument("--swift-cli", type=Path, required=True)
    args = options.parse_args()
    if sys.platform != "darwin" or os.uname().machine != "arm64":
        raise SystemExit("native macOS arm64 required; no simulated PASS")
    xcode = subprocess.check_output(["/usr/bin/xcodebuild", "-version"], text=True)
    assert xcode.startswith("Xcode 27.")
    parser = ROOT / "ThirdParty/TraceStreamer/macx/trace_streamer"
    manifest = json.loads(parser.with_name("manifest.json").read_text())
    oracle = json.loads((ROOT / "docs/migration-runs/AT-RUST-001-2026-10-02-small-oracle.json").read_text())
    assert digest(parser) == manifest["binarySHA256"] == oracle["parser"]["binarySHA256"]
    for source in oracle["corpus"]:
        assert digest(ROOT / source["path"]) == source["sha256"]
    swift_probe, swift_build_log = build_swift_oracle()
    swift_probe_pin = digest(swift_probe)
    cargo("build", "-p", "arktrace-platform", "--bin", "arktrace-host-process")
    target = Path(json.loads(cargo("metadata", "--format-version", "1", "--no-deps"))["target_directory"])
    base = Path(tempfile.mkdtemp(prefix="arktrace-counters-空 格-")).resolve()
    try:
        tools = base / "tools"
        tools.mkdir(mode=0o700)
        for source, name in [(target / "debug/arktrace-host-process", "host-process"), (parser, "trace-streamer")]:
            shutil.copyfile(source, tools / name)
            (tools / name).chmod(0o500)
        helper_pin = digest(tools / "host-process")
        installed = install_swift(args.swift_cli.resolve(strict=True), base, parser)
        installed_pin = digest(installed)
        cases, records = [], []

        def record(fixture, name, value):
            identifier = f"{Path(fixture).stem}/counters/{name}"
            actual = run_case(installed, parser, arguments(fixture, value), base)
            if actual["exitCode"]:
                (base / "failed-swift.json").write_text(json.dumps({"id": identifier, "query": value, "result": actual}, ensure_ascii=False, indent=2))
            assert actual["exitCode"] == 0, identifier
            result = actual["document"]["result"]
            assert actual["document"]["tool"]["buildRevision"] == installed_pin
            page = {"items": result["counters"], "truncated": result["truncated"],
                    "capabilityAvailable": result["capabilityAvailable"], "dataQuality": result["dataQuality"]}
            cases.append({"id": identifier, "fixture": fixture, "query": value})
            records.append({"id": identifier, "query": value, "swift": actual, "expectedPage": page})
            return page

        for source in oracle["corpus"]:
            fixture = Path(source["path"]).name
            trace = next(r["document"]["trace"] for r in oracle["records"] if r["id"] == f"{Path(fixture).stem}/inspect")
            duration = trace["durationNs"]
            full = record(fixture, "whole", query(0, duration))
            first = (full["items"] or [{}])[0]
            record(fixture, "window", query(0, min(duration, 1_000_000_000)))
            record(fixture, "sample-limit-one", query(0, duration, limit=1))
            record(fixture, "tail-half-open", query(duration - 1, duration))
            record(fixture, "cpu-scope", query(0, duration, cpu=0))
            record(fixture, "process-scope", query(0, duration, processKey=(first.get("processKey") or {}).get("ipid", -10)))
            record(fixture, "pid-scope", query(0, duration, pid=first.get("pid") if first.get("pid") is not None else 1))
            record(fixture, "filter-id", query(0, duration, filterID=first.get("filterID", 1)))
            record(fixture, "zero-filter-id", query(0, duration, filterID=0))
            record(fixture, "negative-filter-id", query(0, duration, filterID=-1))
            name = first.get("name", "unknown") or "unknown"
            record(fixture, "exact-name", query(0, duration, name=name))
            record(fixture, "prefix-name", query(0, duration, name=name[:max(1, len(name)//2)], nameMatch="prefix"))
            record(fixture, "contains-name", query(0, duration, name=name[:max(1, len(name)//2)], nameMatch="contains"))
            record(fixture, "escaped-like-literal", query(0, duration, name="%_\\中文", nameMatch="contains"))
            record(fixture, "sql-looking-literal", query(0, duration, name="' OR 1=1 --"))
            record(fixture, "name-byte-boundary", query(0, duration, name="界" * 85 + "a"))
        (base / "swift-records.json").write_text(json.dumps(records, ensure_ascii=False, indent=2))
        identity = {key: manifest[key] for key in ["name", "reportedVersion", "binarySHA256", "upstreamRepository", "upstreamRevision", "architecture", "adapterVersion", "buildRecipeVersion"]}
        report = json.loads(cargo("run", "-p", "arktrace-engine", "--example", "macos_counters_probe", "--",
            str(base), str(ROOT / "Fixtures/traces"), json.dumps(identity), helper_pin, json.dumps(cases), str(swift_probe)))
        assert len(report["results"]) == len(cases) == 48 and len(report["negativeCases"]) == 36
        rows = {r["rust"]["id"]: r["rust"] for r in report["results"]}
        for record_value in records:
            row = rows[record_value["id"]]
            assert row["page"] == record_value["expectedPage"], record_value["id"]
            record_value["rustPage"] = row["page"]
        assert all(n["nextRequestUnchanged"] for n in report["negativeCases"])
        assert any(r["rust"]["page"]["items"] for r in report["results"])
        assert any(r["rust"]["page"]["truncated"] for r in report["results"])
        assert all(s["rawBytesUnchanged"] and s["explicitCloseRemovedReadyOwnersAndLeases"] for s in report["sources"])
        assert digest(swift_probe) == swift_probe_pin
        assert digest(parser) == manifest["binarySHA256"] and digest(tools / "host-process") == helper_pin and digest(installed) == installed_pin
        for source in oracle["corpus"]:
            assert digest(ROOT / source["path"]) == source["sha256"]
        source_paths = sorted(path for name in ("ArkTraceCore", "ArkTraceStore", "ArkTraceAnalysis") for path in (ROOT / "Sources" / name).rglob("*.swift"))
        report.update(swiftRecords=records, helperExecutableSHA256=helper_pin, swiftExecutableSHA256=installed_pin,
            swiftOracleExecutableSHA256=swift_probe_pin, swiftOracleBuildLogSHA256=digest(swift_build_log),
            swiftOracleSources=[{"path": str(p.relative_to(ROOT)), "sha256": digest(p), "byteCount": p.stat().st_size} for p in source_paths],
            rustProbeExecutableSHA256=digest(target / "debug/examples/macos_counters_probe"), xcode=xcode.strip(),
            comparison="all raw sample-series, series-directory and Agent page facts T0; complete fresh Swift CLI pages T0",
            rawInputsAndOriginalParserUnchanged=True, rustCliAcceptanceClaimed=False)
        shutil.rmtree(base)
        report["ownedTemporaryRootRemoved"] = True
        print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    except BaseException:
        print(f"Owned probe root retained for diagnostics: {base}", file=sys.stderr)
        raise


if __name__ == "__main__":
    main()
