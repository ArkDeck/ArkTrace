#!/usr/bin/env python3
"""Native CPU/state Engine queries compared to fresh, installed Swift CLI output.

Requires an explicit Swift executable built with Xcode 27, the three locked
small fixtures and the pinned local parser. No production CLI/App acceptance.
Preserves its owned root on failure; never modifies original input artifacts.
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
from test_macos_parser_process import ROOT, cargo, digest


def install_swift(source, base, parser):
    target = base / "swift/bin/arktrace"
    target.parent.mkdir(parents=True, mode=0o700)
    shutil.copyfile(source, target)
    target.chmod(0o700)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(target)],
                   check=True, capture_output=True)
    resources = base / "swift/share/arktrace"
    resources.mkdir(parents=True, mode=0o700)
    for path in [ROOT / "LICENSE", ROOT / "THIRD_PARTY_NOTICES.md", parser.with_name("manifest.json"),
                 ROOT / "ThirdParty/TraceStreamer/license-inventory.json", ROOT / "Fixtures/traces/zlib.htrace"]:
        shutil.copyfile(path, resources / path.name)
    shutil.copytree(ROOT / "ThirdParty/TraceStreamer/LICENSES", resources / "LICENSES")
    return target


def arguments(fixture, view, query):
    values = ["query", str(ROOT / "Fixtures/traces" / fixture), "--view", view,
              "--start-ns", str(query["range"]["startNs"]), "--end-ns", str(query["range"]["endNs"]),
              "--limit", str(query["limit"])]
    for key, flag in [("cpu", "--cpu"), ("processKey", "--process-key"), ("pid", "--pid"),
                      ("threadKey", "--thread-key"), ("tid", "--tid"), ("rawState", "--raw-state"), ("state", "--state")]:
        if query.get(key) is not None:
            values += [flag, str(query[key])]
    return values


def query(view, start, end, **changes):
    result = {"range": {"startNs": start, "endNs": end}, "cpu": None, "processKey": None,
              "pid": None, "threadKey": None, "tid": None, "limit": 128}
    if view == "thread-states":
        result.update(rawState=None, state=None)
    result.update(changes)
    return result


def main():
    options = argparse.ArgumentParser(description=__doc__)
    options.add_argument("--swift-cli", type=Path, required=True)
    args = options.parse_args()
    if sys.platform != "darwin" or os.uname().machine != "arm64":
        raise SystemExit("native macOS arm64 required; no simulated PASS")
    swift_source = args.swift_cli.resolve(strict=True)
    xcode = subprocess.check_output(["/usr/bin/xcodebuild", "-version"], text=True)
    assert xcode.startswith("Xcode 27."), "Xcode 27 required"
    parser = ROOT / "ThirdParty/TraceStreamer/macx/trace_streamer"
    manifest = json.loads(parser.with_name("manifest.json").read_text())
    oracle = json.loads((ROOT / "docs/migration-runs/AT-RUST-001-2026-10-02-small-oracle.json").read_text())
    assert digest(parser) == manifest["binarySHA256"] == oracle["parser"]["binarySHA256"]
    corpus = oracle["corpus"]
    for source in corpus:
        assert digest(ROOT / source["path"]) == source["sha256"]
    cargo("build", "-p", "arktrace-platform", "--bin", "arktrace-host-process")
    target = Path(json.loads(cargo("metadata", "--format-version", "1", "--no-deps"))["target_directory"])
    base = Path(tempfile.mkdtemp(prefix="arktrace-events-空 格-")).resolve()
    try:
        tools = base / "tools"
        tools.mkdir(mode=0o700)
        for source, name in [(target / "debug/arktrace-host-process", "host-process"), (parser, "trace-streamer")]:
            shutil.copyfile(source, tools / name)
            (tools / name).chmod(0o500)
        helper_pin = digest(tools / "host-process")
        installed = install_swift(swift_source, base, parser)
        installed_pin = digest(installed)
        cases, records = [], []

        def record(fixture, view, name, value):
            identifier = f"{Path(fixture).stem}/{view}/{name}"
            actual = run_case(installed, parser, arguments(fixture, view, value), base)
            if actual["exitCode"] != 0:
                (base / "failed-swift-invocation.json").write_text(json.dumps({"id": identifier, "query": value, "result": actual}, ensure_ascii=False, sort_keys=True))
            assert actual["exitCode"] == 0, identifier
            assert actual["document"]["tool"]["buildRevision"] == installed_pin
            result = actual["document"]["result"]
            array = "cpuSlices" if view == "cpu-slices" else "threadStates"
            page = {"items": result[array], "truncated": result["truncated"],
                    "capabilityAvailable": result["capabilityAvailable"], "dataQuality": result["dataQuality"]}
            assert result["range"] == value["range"]
            field = "cpuQuery" if view == "cpu-slices" else "stateQuery"
            cases.append({"fixture": fixture, "id": identifier, "cpuQuery": None, "stateQuery": None, field: value})
            records.append({"id": identifier, "query": value, "swift": actual, "expectedPage": page})
            return page

        for source in corpus:
            fixture = Path(source["path"]).name
            trace = next(r["document"]["trace"] for r in oracle["records"] if r["id"] == f"{Path(fixture).stem}/inspect")
            duration = trace["durationNs"]
            for view in ["cpu-slices", "thread-states"]:
                full = record(fixture, view, "whole", query(view, 0, duration))
                record(fixture, view, "window", query(view, 0, min(duration, 1_000_000_000)))
                record(fixture, view, "source-limit-one", query(view, 0, duration, limit=1))
                record(fixture, view, "empty-cpu", query(view, 0, duration, cpu=2**63-1))
                record(fixture, view, "tail-half-open", query(view, duration-1, duration))
                first = full["items"][0] if full["items"] else {}
                record(fixture, view, "internal-identities", query(view, 0, duration,
                       processKey=(first.get("processKey") or {}).get("ipid", -10),
                       threadKey=(first.get("threadKey") or {}).get("itid", -11)))
                record(fixture, view, "pid-tid-cpu", query(view, 0, duration,
                       pid=first.get("pid") if first.get("pid") is not None else 1,
                       tid=first.get("tid") if first.get("tid") is not None else 1,
                       cpu=first.get("cpu") if first.get("cpu") is not None else 0))
                if view == "thread-states":
                    record(fixture, view, "normalized-running", query(view, 0, duration, state="running"))
                    record(fixture, view, "raw-state-exact", query(view, 0, duration, rawState=first.get("state", "Running")))
                    record(fixture, view, "raw-state-literal", query(view, 0, duration, rawState="' OR 1=1 --"))
        identity = {key: manifest[key] for key in ["name", "reportedVersion", "binarySHA256", "upstreamRepository", "upstreamRevision", "architecture", "adapterVersion", "buildRecipeVersion"]}
        report = json.loads(cargo("run", "-p", "arktrace-engine", "--example", "macos_events_probe", "--",
                                 str(base), str(ROOT / "Fixtures/traces"), json.dumps(identity), helper_pin, json.dumps(cases)))
        assert len(report["results"]) == len(cases) == 51
        assert len(report["negativeCases"]) == 18
        assert all(r["nextRequestUnchanged"] for r in report["negativeCases"])
        assert report["developmentTrustOnly"] and not report["readyAcceptance"] and not report["productionCliReplacement"]
        rows = {row["id"]: row for row in report["results"]}
        for record in records:
            actual = rows[record["id"]]["page"]
            if actual != record["expectedPage"]:
                # Preserve the exact compared facts for a failed native run.
                (base / "failed-parity.json").write_text(json.dumps({"case": record, "rust": actual}, ensure_ascii=False, sort_keys=True))
                raise AssertionError(f"Typed event query mismatch: {record['id']}")
            rows[record["id"]]["swiftOracleParity"] = "T0"
            record["rustPage"] = actual
        assert any(r["page"]["items"] for r in report["results"] if "/cpu-slices/" in r["id"])
        assert any(r["page"]["items"] for r in report["results"] if "/thread-states/" in r["id"])
        assert any(not r["page"]["capabilityAvailable"] for r in report["results"])
        assert any(r["page"]["capabilityAvailable"] and not r["page"]["items"] for r in report["results"])
        assert any(r["page"]["truncated"] for r in report["results"])
        for source in report["sources"]:
            assert source["rawBytesUnchanged"] and source["explicitCloseRemovedReadyOwnersAndLeases"]
        for source in corpus:
            assert digest(ROOT / source["path"]) == source["sha256"]
        assert digest(parser) == manifest["binarySHA256"]
        assert digest(tools / "host-process") == helper_pin
        assert digest(installed) == installed_pin
        report.update(swiftRecords=records, helperExecutableSHA256=helper_pin, swiftExecutableSHA256=installed_pin,
                      rustProbeExecutableSHA256=digest(target / "debug/examples/macos_events_probe"), xcode=xcode.strip(),
                      comparison="all typed event page facts T0; no omitted fields or tolerance", rawInputsAndOriginalParserUnchanged=True)
        shutil.rmtree(base)
        report["ownedTemporaryRootRemoved"] = True
        print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    except BaseException:
        sys.stderr.write(f"Failed probe preserved its owned private root: {base}\n")
        raise


if __name__ == "__main__":
    main()
