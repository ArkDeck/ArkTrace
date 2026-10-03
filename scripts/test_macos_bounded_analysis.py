#!/usr/bin/env python3
"""Actual Store/Engine CPU/state/named analysis; partial Swift CLI parity only.

The five wired sections use fresh Swift CLI results. Scheduling remains
unattested and the long-slice reduction is still absent. No full analysis,
production CLI, App, performance or final macOS acceptance is claimed.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile

from test_macos_event_queries import install_swift
from test_macos_parser_process import ROOT, cargo, digest


def request(start, end, **changes):
    value = {"range": {"startNs": start, "endNs": end}, "maximumCPUSlices": 16,
             "maximumProcessSlices": 16, "maximumThreadSlices": 16,
             "maximumStateIntervals": 16, "maximumSchedulingEvents": 16,
             "maximumHotEvents": 16, "topProcessLimit": 5, "topThreadLimit": 5,
             "schedulingSampleLimit": 5, "hotIntervalLimit": 5, "hotBucketCount": 100,
             "minimumLongSliceDurationNs": 0, "maximumOutputRows": 128}
    value.update(changes)
    return value


def compare(actual, expected, path):
    if isinstance(expected, dict):
        assert actual.keys() == expected.keys(), path
        for key, value in expected.items():
            compare(actual[key], value, f"{path}.{key}")
    elif isinstance(expected, list):
        assert len(actual) == len(expected), path
        for i, (a, b) in enumerate(zip(actual, expected)):
            compare(a, b, f"{path}[{i}]")
    elif path.rsplit(".", 1)[-1] in {"utilization", "shareOfOneCPU", "percentageOfRange"}:
        assert struct.pack("!d", float(actual)) == struct.pack("!d", float(expected)), path
    else:
        assert type(actual) is type(expected) and actual == expected, path


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
    oracle = json.loads((ROOT / "docs/migration-runs/AT-RUST-007-2026-10-03-scheduling-queries.json").read_text())
    assert digest(parser) == manifest["binarySHA256"]
    corpus = oracle["nativeSchedulingQueries"]["sources"]
    for source in corpus:
        assert digest(ROOT / "Fixtures/traces" / source["fixture"]) == source["source"]["sha256"]
    cargo("build", "-p", "arktrace-platform", "--bin", "arktrace-host-process")
    target = Path(json.loads(cargo("metadata", "--format-version", "1", "--no-deps"))["target_directory"])
    base = Path(tempfile.mkdtemp(prefix="arktrace-analysis-空 格-")).resolve()
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
        for source in corpus:
            fixture = source["fixture"]
            duration = source["inspection"]["durationNs"]
            whole = next(r for r in oracle["nativeSchedulingQueries"]["results"] if r["fixture"] == fixture and r["id"].endswith("/cpu-slices/whole"))
            first = (whole["repositoryPage"]["items"] or [{}])[0]
            empty = {"processKey": None, "pid": None, "threadKey": None, "tid": None}
            scenarios = [
                ("whole", request(0, duration), empty),
                ("window", request(0, min(duration, 1_000_000_000)), empty),
                ("named-minimum-duration", request(0, duration, minimumLongSliceDurationNs=1_000_000), empty),
                ("named-duration-max-int64", request(0, duration, minimumLongSliceDurationNs=9_223_372_036_854_775_807), empty),
                ("empty-identities", request(0, duration), dict(empty, processKey=-10, threadKey=-11)),
                ("internal-identities", request(0, duration), dict(empty,
                    processKey=(first.get("processKey") or {}).get("ipid", -10),
                    threadKey=(first.get("threadKey") or {}).get("itid", -11))),
                ("pid-tid", request(0, duration), dict(empty,
                    pid=first.get("pid") if first.get("pid") is not None else 1,
                    tid=first.get("tid") if first.get("tid") is not None else 1)),
            ]
            for name, value, scope in scenarios:
                identifier = f"{Path(fixture).stem}/{name}"
                case = {"id": identifier, "fixture": fixture, "request": value, "scope": scope}
                cases.append(case)
                arguments = [str(installed), "--json", "--no-cache", "--trace-streamer", str(parser),
                    "--max-rows", "128", "--max-events", "16", "analyze", str(ROOT / "Fixtures/traces" / fixture),
                    "--kind", "range", "--start-ns", str(value["range"]["startNs"]),
                    "--end-ns", str(value["range"]["endNs"]), "--limit", "5",
                    "--threshold-ns", str(value["minimumLongSliceDurationNs"])]
                for key, flag in [("processKey", "--process-key"), ("pid", "--pid"), ("threadKey", "--thread-key"), ("tid", "--tid")]:
                    if scope[key] is not None:
                        arguments += [flag, str(scope[key])]
                actual = subprocess.run(arguments, cwd=ROOT, capture_output=True, timeout=45)
                assert len(actual.stdout) + len(actual.stderr) <= 8_388_608
                assert not actual.stderr and actual.stdout
                document = json.loads(actual.stdout)
                if actual.returncode:
                    (base / "failed-swift.json").write_text(json.dumps({"case": case, "document": document}, ensure_ascii=False, indent=2))
                assert actual.returncode == 0, identifier
                encoded = json.dumps(document, ensure_ascii=False)
                assert all(p not in encoded for p in [str(ROOT), str(base), "/Users/", "/private/"])
                assert document["schemaVersion"] == "1.0" and document["tool"]["buildRevision"] == installed_pin
                records.append({"id": identifier, "document": document, "exitCode": actual.returncode})
            cases.append({"id": f"{Path(fixture).stem}/independent-page-budgets", "fixture": fixture,
                "request": request(0, duration, maximumCPUSlices=1, maximumProcessSlices=3,
                    maximumThreadSlices=5, maximumStateIntervals=2, maximumSchedulingEvents=4, maximumHotEvents=6), "scope": empty})
        identity = {key: manifest[key] for key in ["name", "reportedVersion", "binarySHA256", "upstreamRepository", "upstreamRevision", "architecture", "adapterVersion", "buildRecipeVersion"]}
        report = json.loads(cargo("run", "-p", "arktrace-engine", "--example", "macos_analysis_probe", "--",
            str(base), str(ROOT / "Fixtures/traces"), json.dumps(identity), helper_pin, json.dumps(cases)))
        assert len(report["results"]) == 24 and len(report["negativeCases"]) == 27
        assert all(n["nextRequestUnchanged"] for n in report["negativeCases"])
        rows = {r["id"]: r for r in report["results"]}
        fields = ["cpuUtilization", "topProcesses", "topThreads", "threadStateDistribution", "hotIntervals"]
        for record in records:
            row = rows[record["id"]]
            actual = row["result"]
            expected = record["document"]["result"]["analysis"]
            try:
                compare(actual["range"], expected["range"], f"{record['id']}.range")
                for field in fields:
                    compare(actual[field], expected[field], f"{record['id']}.{field}")
                    for fact in ["returnedCount", "matchedCount", "truncated"]:
                        compare(actual["sections"][field][fact], expected["sections"][field][fact], f"{record['id']}.sections.{field}.{fact}")
                compare(actual["dataQuality"], expected["dataQuality"], f"{record['id']}.dataQuality")
            except AssertionError:
                (base / "failed-parity.json").write_text(json.dumps({"swift": record, "rust": row}, ensure_ascii=False, indent=2))
                raise
            row["fiveSectionParity"] = "T0"
            row["analysisQualityParity"] = "T0"
        assert any(r["result"]["cpuUtilization"] for r in report["results"])
        assert any(r["result"]["threadStateDistribution"] for r in report["results"])
        assert any(h["namedSliceCount"] > 0 for r in report["results"] for h in r["result"]["hotIntervals"])
        assert all(s["rawBytesUnchanged"] and s["explicitCloseRemovedReadyOwnersAndLeases"] for s in report["sources"])
        for source in corpus:
            assert digest(ROOT / "Fixtures/traces" / source["fixture"]) == source["source"]["sha256"]
        assert digest(parser) == manifest["binarySHA256"] and digest(tools / "host-process") == helper_pin and digest(installed) == installed_pin
        report.update(swiftRecords=records, fiveSectionCases=len(records), independentBudgetCases=3,
            helperExecutableSHA256=helper_pin, swiftExecutableSHA256=installed_pin,
            rustProbeExecutableSHA256=digest(target / "debug/examples/macos_analysis_probe"), xcode=xcode.strip(),
            comparedFields=fields, comparison="five complete arrays, section facts and analysis dataQuality T0; exact integer/binary64; partial analysis only",
            schedulingAttested=False, namedQueriesImplemented=True, longSliceReductionImplemented=False, fullAnalysisEnvelopeAccepted=False,
            rawInputsAndOriginalParserUnchanged=True)
        shutil.rmtree(base)
        report["ownedTemporaryRootRemoved"] = True
        print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    except BaseException:
        print(f"Owned probe root retained for diagnostics: {base}", file=sys.stderr)
        raise


if __name__ == "__main__":
    main()
