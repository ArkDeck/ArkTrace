#!/usr/bin/env python3
"""Check actual Swift Inspector, EventKey lookup and action catalog receipts."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "rust/crates/arktrace-viewer/tests/fixtures"


def main():
    receipt = json.loads((FIXTURES / "viewer-facts-mainline-swift-receipt.json").read_text(encoding="utf-8"))
    assert receipt["exitCode"] == 0 and receipt["copiedExpectedAlgorithms"] is False
    assert receipt["manifestUnchanged"] is True
    assert all(command["exitCode"] == 0 for command in receipt["commandReceipts"])
    seen = set()
    for entry in receipt["sourceDigests"]:
        relative = entry["path"]
        assert relative not in seen
        seen.add(relative)
        path = ROOT / relative
        assert not path.is_symlink() and path.resolve().is_relative_to(ROOT)
        data = path.read_bytes()
        assert len(data) == entry["byteCount"] and hashlib.sha256(data).hexdigest() == entry["sha256"], relative
    assert receipt["sourceModules"] == [
        "ArkTraceCore", "ArkTraceParser", "ArkTraceStore", "ArkTraceRuntime",
        "ArkTraceAnalysis", "ArkTraceRendering", "ArkTraceAppSupport",
    ]
    for module in receipt["sourceModules"]:
        prefix = f"Sources/{module}/"
        assert {p.relative_to(ROOT).as_posix() for p in (ROOT / prefix).rglob("*.swift")} == {p for p in seen if p.startswith(prefix)}
    for prefix in ("Apps/ArkTraceApp/", "Tests/ArkTraceRenderingTests/", "Tests/ArkTraceAppSupportTests/", "Tests/ArkTraceCoreTests/"):
        assert {p.relative_to(ROOT).as_posix() for p in (ROOT / prefix).rglob("*.swift")} == {p for p in seen if p.startswith(prefix)}
    required = {
        "inspector-projection-inputs.json", "inspector-projection-swift.json",
        "snapshot-event-index-inputs.json", "snapshot-event-index-swift-oracle.json",
        "action-catalog-inputs.json", "action-catalog-keyboard-swift.json", "action-catalog-display-swift.json",
    }
    assert {(FIXTURES / name).relative_to(ROOT).as_posix() for name in required} <= seen
    load = lambda name: json.loads((FIXTURES / name).read_text(encoding="utf-8"))
    inspector = load("inspector-projection-swift.json")
    index = load("snapshot-event-index-swift-oracle.json")
    keyboard = load("action-catalog-keyboard-swift.json")
    catalog = load("action-catalog-display-swift.json")
    assert len(inspector["cases"]) == 362
    assert sum(len(case["facts"]) for case in inspector["cases"]) == 393
    assert index["cases"] == 295 and len(index["rows"]) == 11923
    assert sum(row["lookup"]["kind"] == "matched" and not row["lookup"]["location"]["hasInspector"] for row in index["rows"]) == 2555
    assert len(keyboard["cases"]) == 664 and len(keyboard["directCommands"]) == 14
    assert sum(len(section["entries"]) for section in catalog["sections"]) == 19
    assert receipt["counts"] == {
        "canonicalSwiftTests": 4, "relatedSwiftTests": 40,
        "inspectorCases": 362, "inspectorPositions": 393,
        "nativeKeyCases": 664, "directCommandCases": 14, "catalogRows": 19,
        "eventIndexSnapshots": 295, "eventIndexLookups": 11923, "firstNilInspectorMatches": 2555,
    }
    print("Viewer facts: actual Inspector fields, first-detail lookup including nil blocking, and native key/catalog outputs with current source identities")


if __name__ == "__main__":
    main()
