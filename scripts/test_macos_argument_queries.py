#!/usr/bin/env python3
"""Actual pinned parser/Ready argument pages compared with the Swift repository.

No Argument Agent/CLI view is invented. Controlled SQL goldens are separate from
these real small traces. This is partial migration evidence, not App cutover.
"""
import json
from pathlib import Path
import shutil
import tempfile

from test_macos_parser_process import ROOT, cargo, digest


def main():
    receipt_path = ROOT / "rust/crates/arktrace-store/tests/fixtures/swift-argument-pages-receipt.json"
    receipt = json.loads(receipt_path.read_text())
    for entry in receipt["sourceDigests"]:
        path = ROOT / entry["path"]
        assert path.stat().st_size == entry["byteCount"] and digest(path) == entry["sha256"], entry["path"]
    swift = Path("/private/tmp/arktrace-argument-swiftpm/build/out/Products/Debug/ArgumentOracle")
    assert digest(swift) == receipt["executableSHA256"]
    oracle = json.loads((ROOT / "docs/migration-runs/AT-RUST-001-2026-10-02-small-oracle.json").read_text())
    parser = ROOT / "ThirdParty/TraceStreamer/macx/trace_streamer"
    manifest = json.loads(parser.with_name("manifest.json").read_text())
    assert digest(parser) == manifest["binarySHA256"] == oracle["parser"]["binarySHA256"]
    identity = {k: manifest[k] for k in ("name", "reportedVersion", "binarySHA256", "upstreamRepository", "upstreamRevision", "architecture", "adapterVersion", "buildRecipeVersion")}
    cargo("build", "-p", "arktrace-platform", "--bin", "arktrace-host-process")
    target = Path(json.loads(cargo("metadata", "--format-version", "1", "--no-deps"))["target_directory"])
    base = Path(tempfile.mkdtemp(prefix="arktrace-arguments-空 格-", dir="/private/tmp")).resolve()
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
            for name, identity_value, limit in [
                ("zero-set",0,64),("one-set",1,64),("one-limit-one",1,1),
                ("negative-set",-1,64),("minimum-set",-9223372036854775808,64),
                ("maximum-set",9223372036854775807,64),
            ]:
                cases.append({"id":f"{Path(fixture).stem}/arguments/{name}","fixture":fixture,"query":{"argSetID":identity_value,"limit":limit},"lookup":None})
        report = json.loads(cargo("run", "-p", "arktrace-engine", "--example", "macos_arguments_probe", "--", str(base), str(ROOT / "Fixtures/traces"), json.dumps(identity), helper_pin, json.dumps(cases), str(swift)))
        assert 18 <= len(report["results"]) <= 36 and len(report["negativeCases"]) == 15
        assert all(r["parity"] == "T0" for r in report["results"])
        assert all(v["nextRequestUnchanged"] for v in report["negativeCases"])
        assert all(s["rawBytesUnchanged"] and s["explicitCloseRemovedReadyOwnersAndLeases"] for s in report["sources"])
        assert digest(swift) == receipt["executableSHA256"] and digest(parser) == manifest["binarySHA256"]
        for source in oracle["corpus"]:
            assert digest(ROOT / source["path"]) == source["sha256"]
        output = {"partialArgumentQueries": True, "inspectorHandleReplay": True, "nativeArguments": report, "swiftProbeSHA256": receipt["executableSHA256"], "helperSHA256": helper_pin, "parser": identity, "rawSourcesUnchanged": True, "ownedHarnessRootRemoved": True}
        shutil.rmtree(base)
        print(json.dumps(output, ensure_ascii=False, indent=2))
    except BaseException:
        print(f"Preserved failed argument harness: {base}")
        raise


if __name__ == "__main__":
    main()
