#!/usr/bin/env python3
"""Actual pinned parser/Ready Viewer density compared with actual Swift repository.

No CLI/SDK/App cutover is claimed. Controlled SQL goldens are separate from
these real small traces. This is partial migration evidence, not App cutover.
"""
import json
from pathlib import Path
import shutil
import tempfile

from test_macos_parser_process import ROOT, cargo, digest


def main():
    receipt_path = ROOT / "rust/crates/arktrace-store/tests/fixtures/swift-density-pages-receipt.json"
    receipt = json.loads(receipt_path.read_text())
    for entry in receipt["sourceDigests"]:
        path = ROOT / entry["path"]
        assert path.stat().st_size == entry["byteCount"] and digest(path) == entry["sha256"], entry["path"]
    swift = Path("/private/tmp/arktrace-density-swiftpm/build/out/Products/Debug/DensityOracle")
    assert digest(swift) == receipt["executableSHA256"]
    oracle = json.loads((ROOT / "docs/migration-runs/AT-RUST-001-2026-10-02-small-oracle.json").read_text())
    parser = ROOT / "ThirdParty/TraceStreamer/macx/trace_streamer"
    manifest = json.loads(parser.with_name("manifest.json").read_text())
    assert digest(parser) == manifest["binarySHA256"] == oracle["parser"]["binarySHA256"]
    identity = {k: manifest[k] for k in ("name", "reportedVersion", "binarySHA256", "upstreamRepository", "upstreamRevision", "architecture", "adapterVersion", "buildRecipeVersion")}
    cargo("build", "-p", "arktrace-platform", "--bin", "arktrace-host-process")
    target = Path(json.loads(cargo("metadata", "--format-version", "1", "--no-deps"))["target_directory"])
    base = Path(tempfile.mkdtemp(prefix="arktrace-density-空 格-", dir="/private/tmp")).resolve()
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
            sources = [{"cpu":{"_0":0}}, {"threadState":{"_0":{"itid":0}}}, {"namedSlice":{}}, {"cpuCounter":{"filterID":3}}, {"processCounter":{"filterID":3}}, {"frame":{}}]
            for i, source_kind in enumerate(sources):
                for count in [1,32]:
                    cases.append({"id":f"{fixture}/density/static-{i}-{count}","fixture":fixture,"query":{"range":{"startNs":0,"endNs":1},"source":source_kind,"bucketCount":count}})
        report = json.loads(cargo("run", "-p", "arktrace-engine", "--example", "macos_density_probe", "--", str(base), str(ROOT / "Fixtures/traces"), json.dumps(identity), helper_pin, json.dumps(cases), str(swift)))
        assert 36 <= len(report["results"]) <= 96 and len(report["negativeCases"]) == 21
        assert all(r["parity"] == "T0" for r in report["results"])
        assert all(v["nextRequestUnchanged"] for v in report["negativeCases"])
        assert all(s["rawBytesUnchanged"] and s["explicitCloseRemovedReadyOwnersAndLeases"] and s["positiveDensities"] > 0 for s in report["sources"])
        assert digest(swift) == receipt["executableSHA256"] and digest(parser) == manifest["binarySHA256"]
        for source in oracle["corpus"]:
            assert digest(ROOT / source["path"]) == source["sha256"]
        # Retain the exact binaries that ran, before a later all-features
        # workspace build can replace Cargo's shared top-level output paths.
        retained = Path(tempfile.mkdtemp(prefix="arktrace-density-artifacts-", dir="/private/tmp")).resolve()
        artifacts = []
        for binary, name in [(tools / "host-process", "host-process"), (target / "debug/examples/macos_density_probe", "density-probe"), (swift, "swift-density-oracle")]:
            pin = digest(binary)
            destination = retained / name
            shutil.copyfile(binary, destination)
            destination.chmod(0o500)
            assert digest(destination) == pin
            artifacts.append({"path":str(destination),"sha256":pin,"byteCount":destination.stat().st_size})
        assert artifacts[0]["sha256"] == helper_pin and artifacts[2]["sha256"] == receipt["executableSHA256"]
        output = {"sharedDensityQueries": True, "nativeDensity": report, "swiftProbeSHA256": receipt["executableSHA256"], "helperSHA256": helper_pin, "retainedExactRunArtifacts": artifacts, "parser": identity, "rawSourcesUnchanged": True, "ownedHarnessRootRemoved": True}
        shutil.rmtree(base)
        print(json.dumps(output, ensure_ascii=False, indent=2))
    except BaseException:
        print(f"Preserved failed density harness: {base}")
        raise


if __name__ == "__main__":
    main()
