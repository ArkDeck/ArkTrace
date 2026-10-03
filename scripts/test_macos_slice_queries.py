#!/usr/bin/env python3
"""Native named-slice Store/Engine pages compared to fresh installed Swift CLI."""
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
    value = {"range": {"startNs": start, "endNs": end}, "eventKey": None,
             "processKey": None, "pid": None, "threadKey": None, "tid": None,
             "name": None, "nameMatch": "exact", "minimumDurationNs": None,
             "depth": None, "includesArgumentSet": False, "limit": 128}
    value.update(changes)
    return value


def arguments(fixture, value):
    values = ["query", str(ROOT / "Fixtures/traces" / fixture), "--view", "slices",
              "--start-ns", str(value["range"]["startNs"]), "--end-ns", str(value["range"]["endNs"]),
              "--limit", str(value["limit"])]
    for key, flag in [("processKey", "--process-key"), ("pid", "--pid"),
            ("threadKey", "--thread-key"), ("tid", "--tid"), ("name", "--name"),
            ("minimumDurationNs", "--min-duration-ns"), ("depth", "--depth")]:
        if value[key] is not None:
            values += [flag, str(value[key])]
    if value["name"] is not None:
        values += ["--name-match", value["nameMatch"]]
    return values


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
    cargo("build", "-p", "arktrace-platform", "--bin", "arktrace-host-process")
    target = Path(json.loads(cargo("metadata", "--format-version", "1", "--no-deps"))["target_directory"])
    base = Path(tempfile.mkdtemp(prefix="arktrace-slices-空 格-")).resolve()
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
            identifier = f"{Path(fixture).stem}/slices/{name}"
            actual = run_case(installed, parser, arguments(fixture, value), base)
            if actual["exitCode"]:
                (base / "failed-swift.json").write_text(json.dumps({"id": identifier, "query": value, "result": actual}, ensure_ascii=False, indent=2))
            assert actual["exitCode"] == 0, identifier
            result = actual["document"]["result"]
            assert result["range"] == value["range"] and actual["document"]["tool"]["buildRevision"] == installed_pin
            page = {"items": result["slices"], "truncated": result["truncated"],
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
            record(fixture, "source-limit-one", query(0, duration, limit=1))
            record(fixture, "tail-half-open", query(duration - 1, duration))
            record(fixture, "empty-identities", query(0, duration, processKey=-10, threadKey=-11))
            record(fixture, "internal-identities", query(0, duration,
                processKey=(first.get("processKey") or {}).get("ipid", -10),
                threadKey=(first.get("threadKey") or {}).get("itid", -11)))
            record(fixture, "pid-tid", query(0, duration,
                pid=first.get("pid") if first.get("pid") is not None else 1,
                tid=first.get("tid") if first.get("tid") is not None else 1))
            name = first.get("name", "unknown") or "unknown"
            record(fixture, "exact-name", query(0, duration, name=name))
            record(fixture, "prefix-name", query(0, duration, name=name[:max(1, len(name)//2)], nameMatch="prefix"))
            record(fixture, "contains-name", query(0, duration, name=name[:max(1, len(name)//2)], nameMatch="contains"))
            record(fixture, "escaped-like-literal", query(0, duration, name="%_\\中文", nameMatch="contains"))
            record(fixture, "sql-looking-literal", query(0, duration, name="' OR 1=1 --"))
            record(fixture, "agent-name-byte-boundary", query(0, duration, name="界" * 85 + "a"))
            record(fixture, "minimum-duration-one", query(0, duration, minimumDurationNs=1))
            record(fixture, "maximum-duration-filter", query(0, duration, minimumDurationNs=2**63-1))
            record(fixture, "depth", query(0, duration, depth=max(0, first.get("depth") or 0)))
        identity = {key: manifest[key] for key in ["name", "reportedVersion", "binarySHA256", "upstreamRepository", "upstreamRevision", "architecture", "adapterVersion", "buildRecipeVersion"]}
        report = json.loads(cargo("run", "-p", "arktrace-engine", "--example", "macos_slices_probe", "--",
            str(base), str(ROOT / "Fixtures/traces"), json.dumps(identity), helper_pin, json.dumps(cases)))
        assert len(report["results"]) == len(cases) == 48 and len(report["negativeCases"]) == 39
        assert all(n["nextRequestUnchanged"] for n in report["negativeCases"])
        rows = {r["id"]: r for r in report["results"]}
        for record in records:
            row = rows[record["id"]]
            if row["page"] != record["expectedPage"]:
                (base / "failed-parity.json").write_text(json.dumps({"case": record, "rust": row}, ensure_ascii=False, indent=2))
                raise AssertionError(record["id"])
            row["swiftOracleParity"] = "T0"
            record["rustPage"] = row["page"]
        assert report["sdkCases"] and all(s["machineShapeUnchanged"] and s["exactEventIdentity"] for s in report["sdkCases"])
        assert any(r["page"]["items"] for r in report["results"])
        assert any(r["page"]["capabilityAvailable"] and not r["page"]["items"] for r in report["results"])
        assert any(r["page"]["truncated"] for r in report["results"])
        assert all(s["rawBytesUnchanged"] and s["explicitCloseRemovedReadyOwnersAndLeases"] for s in report["sources"])
        for source in oracle["corpus"]:
            assert digest(ROOT / source["path"]) == source["sha256"]
        assert digest(parser) == manifest["binarySHA256"] and digest(tools / "host-process") == helper_pin and digest(installed) == installed_pin
        report.update(swiftRecords=records, helperExecutableSHA256=helper_pin, swiftExecutableSHA256=installed_pin,
            rustProbeExecutableSHA256=digest(target / "debug/examples/macos_slices_probe"), xcode=xcode.strip(),
            comparison="all typed named-slice page facts T0; no omitted fields or tolerance",
            rawInputsAndOriginalParserUnchanged=True, rustCliAcceptanceClaimed=False)
        shutil.rmtree(base)
        report["ownedTemporaryRootRemoved"] = True
        print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    except BaseException:
        print(f"Owned probe root retained for diagnostics: {base}", file=sys.stderr)
        raise


if __name__ == "__main__":
    main()
