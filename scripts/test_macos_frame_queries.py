#!/usr/bin/env python3
"""Actual pinned parser/Ready frame pages compared with the Swift repository.

No Frame Agent/CLI view is invented. Controlled SQL goldens are separate from
these real small traces. This is partial migration evidence, not App cutover.
"""
import json
from pathlib import Path
import shutil
import tempfile

from test_macos_parser_process import ROOT, cargo, digest


def main():
    receipt_path = ROOT / "rust/crates/arktrace-store/tests/fixtures/swift-event-pages-receipt.json"
    receipt = json.loads(receipt_path.read_text())
    for entry in receipt["sourceDigests"]:
        path = ROOT / entry["path"]
        assert path.stat().st_size == entry["byteCount"] and digest(path) == entry["sha256"], entry["path"]
    swift = Path("/private/tmp/arktrace-event-swiftpm/build/out/Products/Debug/EventOracle")
    assert digest(swift) == receipt["executableSHA256"]
    oracle = json.loads((ROOT / "docs/migration-runs/AT-RUST-001-2026-10-02-small-oracle.json").read_text())
    parser = ROOT / "ThirdParty/TraceStreamer/macx/trace_streamer"
    manifest = json.loads(parser.with_name("manifest.json").read_text())
    assert digest(parser) == manifest["binarySHA256"] == oracle["parser"]["binarySHA256"]
    identity = {k: manifest[k] for k in ("name", "reportedVersion", "binarySHA256", "upstreamRepository", "upstreamRevision", "architecture", "adapterVersion", "buildRecipeVersion")}
    cargo("build", "-p", "arktrace-platform", "--bin", "arktrace-host-process")
    target = Path(json.loads(cargo("metadata", "--format-version", "1", "--no-deps"))["target_directory"])
    base = Path(tempfile.mkdtemp(prefix="arktrace-frames-空 格-", dir="/private/tmp")).resolve()
    try:
        tools = base / "tools"
        tools.mkdir(mode=0o700)
        for source, name in [(target / "debug/arktrace-host-process", "host-process"), (parser, "trace-streamer")]:
            shutil.copyfile(source, tools / name)
            (tools / name).chmod(0o500)
        helper_pin = digest(tools / "host-process")
        cases = []
        for source in oracle["corpus"]:
            fixture = Path(source["path"]).name
            assert digest(ROOT / source["path"]) == source["sha256"]
            trace = next(r["document"]["trace"] for r in oracle["records"] if r["id"] == f"{Path(fixture).stem}/inspect")
            duration = trace["durationNs"]
            for name, start, end, limit, key in [
                ("whole", 0, duration, 128, None),
                ("window", 0, min(duration, 1_000_000_000), 128, None),
                ("limit-one", 0, duration, 1, None),
                ("tail", duration - 1, duration, 128, None),
                ("process-one", 0, duration, 128, 1),
                ("negative-process", 0, duration, 128, -10),
                ("zero-process", 0, duration, 128, 0),
                ("empty-process", 0, duration, 128, 9223372036854775807),
            ]:
                cases.append({"id": f"{Path(fixture).stem}/frames/{name}", "fixture": fixture, "view": "frames", "query": {"range": {"startNs": start, "endNs": end}, "processKey": key, "limit": limit}})
            for view in ["cpuSlices", "threadStates", "slices"]:
                cases.append({"id": f"{Path(fixture).stem}/{view}/whole", "fixture": fixture, "view": view, "query": {"range": {"startNs": 0, "endNs": duration}, "processKey": None, "limit": 128}})
        report = json.loads(cargo("run", "-p", "arktrace-engine", "--example", "macos_frames_probe", "--", str(base), str(ROOT / "Fixtures/traces"), json.dumps(identity), helper_pin, json.dumps(cases), str(swift)))
        assert len(report["results"]) == 33 and len(report["negativeCases"]) == 15
        assert all(r["parity"] == "T0" for r in report["results"])
        assert all(v["nextRequestUnchanged"] for v in report["negativeCases"])
        assert all(s["rawBytesUnchanged"] and s["explicitCloseRemovedReadyOwnersAndLeases"] for s in report["sources"])
        assert digest(swift) == receipt["executableSHA256"] and digest(parser) == manifest["binarySHA256"]
        for source in oracle["corpus"]:
            assert digest(ROOT / source["path"]) == source["sha256"]
        output = {"partialFrameQueries": True, "agentCompositionReplay": True, "nativeFrames": report, "swiftProbeSHA256": receipt["executableSHA256"], "helperSHA256": helper_pin, "parser": identity, "rawSourcesUnchanged": True, "ownedHarnessRootRemoved": True}
        shutil.rmtree(base)
        print(json.dumps(output, ensure_ascii=False, indent=2))
    except BaseException:
        print(f"Preserved failed frame harness: {base}")
        raise


if __name__ == "__main__":
    main()
