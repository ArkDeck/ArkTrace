#!/usr/bin/env python3
"""Actual pinned parser/Ready Viewer search compared with actual Swift composition and repository.

No CLI/SDK/App cutover is claimed. Controlled SQL goldens are separate from
these real small traces. This is partial migration evidence, not App cutover.
"""
import json
from pathlib import Path
import shutil
import tempfile

from test_macos_parser_process import ROOT, cargo, digest


def main():
    receipt_path = ROOT / "rust/crates/arktrace-store/tests/fixtures/swift-search-pages-receipt.json"
    receipt = json.loads(receipt_path.read_text())
    for entry in receipt["sourceDigests"]:
        path = ROOT / entry["path"]
        assert path.stat().st_size == entry["byteCount"] and digest(path) == entry["sha256"], entry["path"]
    swift = Path("/private/tmp/arktrace-search-swiftpm/build/out/Products/Debug/SearchOracle")
    assert digest(swift) == receipt["executableSHA256"]
    oracle = json.loads((ROOT / "docs/migration-runs/AT-RUST-001-2026-10-02-small-oracle.json").read_text())
    parser = ROOT / "ThirdParty/TraceStreamer/macx/trace_streamer"
    manifest = json.loads(parser.with_name("manifest.json").read_text())
    assert digest(parser) == manifest["binarySHA256"] == oracle["parser"]["binarySHA256"]
    identity = {k: manifest[k] for k in ("name", "reportedVersion", "binarySHA256", "upstreamRepository", "upstreamRevision", "architecture", "adapterVersion", "buildRecipeVersion")}
    cargo("build", "-p", "arktrace-platform", "--bin", "arktrace-host-process")
    target = Path(json.loads(cargo("metadata", "--format-version", "1", "--no-deps"))["target_directory"])
    base = Path(tempfile.mkdtemp(prefix="arktrace-search-空 格-", dir="/private/tmp")).resolve()
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
            for name, text, domains, limit in [
                ("whole","42",7,16),("toolbar","42",6,16),("process-only","42",1,16),
                ("slice-only","42",4,16),("limit-one","42",7,1),("name","worker",7,16),
                ("absent","migration-search-absent-value",7,16),("unknown-domain","42",8,16),
                ("literal-wildcards","%_\\",7,16),
            ]:
                cases.append({"id":f"{Path(fixture).stem}/search/{name}","fixture":fixture,"query":{"text":text,"domains":domains,"limit":limit}})
        report = json.loads(cargo("run", "-p", "arktrace-engine", "--example", "macos_search_probe", "--", str(base), str(ROOT / "Fixtures/traces"), json.dumps(identity), helper_pin, json.dumps(cases), str(swift)))
        assert 27 <= len(report["results"]) <= 75 and len(report["negativeCases"]) == 21
        assert all(r["parity"] == "T0" for r in report["results"])
        assert all(v["nextRequestUnchanged"] for v in report["negativeCases"])
        assert all(s["rawBytesUnchanged"] and s["explicitCloseRemovedReadyOwnersAndLeases"] and s["positiveSearches"] > 0 for s in report["sources"])
        assert digest(swift) == receipt["executableSHA256"] and digest(parser) == manifest["binarySHA256"]
        for source in oracle["corpus"]:
            assert digest(ROOT / source["path"]) == source["sha256"]
        # Retain the exact binaries that ran, before a later all-features
        # workspace build can replace Cargo's shared top-level output paths.
        retained = Path(tempfile.mkdtemp(prefix="arktrace-search-artifacts-", dir="/private/tmp")).resolve()
        artifacts = []
        for binary, name in [(tools / "host-process", "host-process"), (target / "debug/examples/macos_search_probe", "search-probe"), (swift, "swift-search-oracle")]:
            pin = digest(binary)
            destination = retained / name
            shutil.copyfile(binary, destination)
            destination.chmod(0o500)
            assert digest(destination) == pin
            artifacts.append({"path":str(destination),"sha256":pin,"byteCount":destination.stat().st_size})
        assert artifacts[0]["sha256"] == helper_pin and artifacts[2]["sha256"] == receipt["executableSHA256"]
        output = {"sharedSearchQueries": True, "nativeSearch": report, "swiftProbeSHA256": receipt["executableSHA256"], "helperSHA256": helper_pin, "retainedExactRunArtifacts": artifacts, "parser": identity, "rawSourcesUnchanged": True, "ownedHarnessRootRemoved": True}
        shutil.rmtree(base)
        print(json.dumps(output, ensure_ascii=False, indent=2))
    except BaseException:
        print(f"Preserved failed search harness: {base}")
        raise


if __name__ == "__main__":
    main()
