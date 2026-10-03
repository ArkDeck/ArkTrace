#!/usr/bin/env python3
"""Verify current Swift event-query oracle inputs, output and source identity."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = "rust/crates/arktrace-store/tests/fixtures/"


def verify(stem, input_name, count, databases, required, facts):
    receipt = json.loads((ROOT / FIXTURE / f"{stem}-receipt.json").read_text(encoding="utf-8"))
    assert receipt["vectors"] == count
    assert all(receipt[key] == value for key, value in facts.items())
    assert receipt["xcode"] == "Xcode 27.0\nBuild version 27A266a"
    assert receipt["swift"].startswith("Apple Swift version 6.4 ")
    seen = set()
    for entry in receipt["sourceDigests"]:
        relative = entry["path"]
        assert relative not in seen
        seen.add(relative)
        path = ROOT / relative
        assert not path.is_symlink() and path.resolve().is_relative_to(ROOT)
        data = path.read_bytes()
        assert len(data) == entry["byteCount"] and hashlib.sha256(data).hexdigest() == entry["sha256"], relative
    for name in ("ArkTraceCore", "ArkTraceStore", "ArkTraceAnalysis"):
        assert {p.relative_to(ROOT).as_posix() for p in (ROOT / "Sources" / name).rglob("*.swift")} == {p for p in seen if p.startswith(f"Sources/{name}/")}
    assert {FIXTURE + input_name + ".json", FIXTURE + stem + ".json", *required} <= seen
    inputs = json.loads((ROOT / FIXTURE / (input_name + ".json")).read_text(encoding="utf-8"))
    output = json.loads((ROOT / FIXTURE / (stem + ".json")).read_text(encoding="utf-8"))
    ids = [v["id"] for v in inputs["cases"]]
    assert len(ids) == len(set(ids)) == len(output) == count
    assert set(ids) == {v["id"] for v in output}
    assert len(receipt["databases"]) == databases and all(v["bytesUnchanged"] for v in receipt["databases"])


def main():
    verify("swift-event-pages", "event-pages-input", 62, 10,
           ["rust/crates/arktrace-store/oracle/EventOracle.swift", "rust/crates/arktrace-store/oracle/run_event_oracle.py"],
           {"frames": 50, "agentViews": 12})
    verify("swift-argument-pages", "argument-pages-input", 84, 15,
           ["rust/crates/arktrace-store/oracle/ArgumentOracle.swift", "rust/crates/arktrace-store/oracle/run_argument_oracle.py"],
           {"inspectorLookups": 4})
    verify("swift-search-pages", "search-pages-input", 138, 3,
           ["rust/crates/arktrace-store/oracle/SearchOracle.swift", "rust/crates/arktrace-store/oracle/run_search_oracle.py"],
           {"recordedSourceCalls": 570})
    verify("swift-density-pages", "density-pages-input", 190, 8,
           ["rust/crates/arktrace-store/oracle/DensityOracle.swift", "rust/crates/arktrace-store/oracle/run_density_oracle.py"], {})
    # The old Swift implementation and harness are historical identities;
    # immutable controlled input and output remain verifiable in this tree.
    receipt = json.loads((ROOT / FIXTURE / "swift-arguments-before-receipt.json").read_text(encoding="utf-8"))
    assert receipt["vectors"] == 84
    for entry in receipt["sourceDigests"]:
        if entry["path"] in {FIXTURE + "argument-pages-input.json", FIXTURE + "swift-arguments-before.json"}:
            data = (ROOT / entry["path"]).read_bytes()
            assert len(data) == entry["byteCount"] and hashlib.sha256(data).hexdigest() == entry["sha256"], entry["path"]
    search_before = json.loads((ROOT / FIXTURE / "swift-search-before-receipt.json").read_text(encoding="utf-8"))
    assert search_before["vectors"] == 138
    for entry in search_before["sourceDigests"]:
        if entry["path"] in {FIXTURE + "search-pages-input.json", FIXTURE + "swift-search-before.json"}:
            data = (ROOT / entry["path"]).read_bytes()
            assert len(data) == entry["byteCount"] and hashlib.sha256(data).hexdigest() == entry["sha256"], entry["path"]
    print("Store oracles: 62 frame/raw/Agent + 84 argument/Inspector + 138 search outputs and 570 exact source calls + 190 density results; current Swift source/input/output identities; retained before-fix argument output")


if __name__ == "__main__":
    main()
