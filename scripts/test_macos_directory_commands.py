#!/usr/bin/env python3
"""Actual small-trace command parity; development pins, no production CLI claim."""
import copy
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

from test_macos_parser_process import ROOT, cargo, digest


def run_probe(base, identity, helper_pin, oracle):
    probe = json.loads(cargo("run", "-p", "arktrace-cli", "--example", "macos_commands_probe", "--",
                             str(base), str(ROOT / "Fixtures/traces"), json.dumps(identity), helper_pin))
    target = Path(json.loads(cargo("metadata", "--format-version", "1", "--no-deps"))["target_directory"])
    actual_tool = digest(target / "debug/examples/macos_commands_probe")
    assert actual_tool == probe["toolExecutableSHA256"]
    assert probe["readyAcceptance"] is False and probe["productionCliReplacement"] is False
    assert probe["developmentTrustOnly"] is True
    canonical = lambda value: json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()
    assert len(probe["results"]) == 9
    for row in probe["results"]:
        assert row["rawBytesUnchanged"] and row["explicitCloseRemovedReadyOwnersAndLeases"]
        identifier = Path(row["fixture"]).stem + "/" + row["command"]
        original = next(r["document"] for r in oracle["records"] if r["id"] == identifier)
        expected = copy.deepcopy(original)
        actual = row["document"]
        assert actual["tool"]["buildRevision"] == actual_tool
        tolerances = [{"pointer": "/tool/buildRevision", "reason": "actual Rust probe executable replaces actual Swift executable identity",
                       "swift": expected["tool"]["buildRevision"], "rust": actual_tool}]
        expected["tool"]["buildRevision"] = actual_tool
        if row["fixture"] == "hiprofiler_data_ability.htrace" and actual["provenance"]["upstreamDatabaseSha256"] != expected["provenance"]["upstreamDatabaseSha256"]:
            tolerances.append({"pointer": "/provenance/upstreamDatabaseSha256", "reason": "existing fixed C++ exporter nondeterminism",
                               "swift": expected["provenance"]["upstreamDatabaseSha256"], "rust": actual["provenance"]["upstreamDatabaseSha256"]})
            expected["provenance"]["upstreamDatabaseSha256"] = actual["provenance"]["upstreamDatabaseSha256"]
        if canonical(actual) != canonical(expected):
            raise AssertionError(f"Machine contract mismatch: {identifier}")
        row["swiftOracleParity"] = "T1"
        row["tolerances"] = tolerances
        row["allOtherMachineFacts"] = "T0"
    assert {r["scenario"] for r in probe["negativeCases"]} == {"output-limit", "cancelled", "deadline", "invalid-limit"}
    assert all(not r["successBytesReturned"] and r["rawBytesUnchanged"] and r["explicitCloseRemovedReadyOwnersAndLeases"] for r in probe["negativeCases"])
    assert probe["typedSessionFiltersAndNextRequest"]
    return probe


def main():
    if sys.platform != "darwin" or os.uname().machine != "arm64":
        raise SystemExit("native macOS arm64 required; no simulated PASS")
    parser = ROOT / "ThirdParty/TraceStreamer/macx/trace_streamer"
    manifest = json.loads((parser.parent / "manifest.json").read_text())
    oracle = json.loads((ROOT / "docs/migration-runs/AT-RUST-001-2026-10-02-small-oracle.json").read_text())
    assert digest(parser) == manifest["binarySHA256"] == oracle["parser"]["binarySHA256"]
    for fixture in oracle["corpus"]:
        assert digest(ROOT / fixture["path"]) == fixture["sha256"]
    cargo("build", "-p", "arktrace-platform", "--bin", "arktrace-host-process")
    target = Path(json.loads(cargo("metadata", "--format-version", "1", "--no-deps"))["target_directory"])
    helper = target / "debug/arktrace-host-process"
    base = Path(tempfile.mkdtemp(prefix="arktrace-directory-空 格-")).resolve()
    try:
        tools = base / "tools"
        tools.mkdir(mode=0o700)
        for source, name in [(helper, "host-process"), (parser, "trace-streamer")]:
            shutil.copyfile(source, tools / name)
            (tools / name).chmod(0o500)
        identity = {key: manifest[key] for key in ["name", "reportedVersion", "binarySHA256", "upstreamRepository", "upstreamRevision", "architecture", "adapterVersion", "buildRecipeVersion"]}
        report = run_probe(base, identity, digest(tools / "host-process"), oracle)
        for fixture in oracle["corpus"]:
            assert digest(ROOT / fixture["path"]) == fixture["sha256"]
        assert digest(parser) == manifest["binarySHA256"]
        shutil.rmtree(base)
        report["ownedTemporaryRootRemoved"] = True
        report["rawInputsAndOriginalParserUnchanged"] = True
        print(json.dumps(report, sort_keys=True))
    except BaseException:
        sys.stderr.write(f"Failed probe preserved its owned private root: {base}\n")
        raise


if __name__ == "__main__":
    main()
