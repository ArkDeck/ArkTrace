#!/usr/bin/env python3
"""Verify retained historical input/output and current Swift oracle provenance."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = "rust/crates/arktrace-analysis/tests/fixtures/"


def main():
    for stem, input_name, count, current in [
        ("swift-oracle", "inputs", 23, False),
        ("swift-deviations", "deviation-inputs", 2, False),
        ("swift-mainline", "mainline-inputs", 33, True),
    ]:
        receipt = json.loads((ROOT / FIXTURE / f"{stem}-receipt.json").read_text())
        assert receipt["vectors"] == count
        assert receipt["xcode"] == "Xcode 27.0\nBuild version 27A266a"
        assert receipt["swift"].startswith("Apple Swift version 6.4 ")
        required = {FIXTURE + input_name + ".json", FIXTURE + stem + ".json"}
        seen = set()
        for entry in receipt["sourceDigests"]:
            relative = entry["path"]
            assert relative not in seen
            seen.add(relative)
            path = ROOT / relative
            assert not path.is_symlink() and path.resolve().is_relative_to(ROOT)
            # The original source version remains a historical identity;
            # current Swift intentionally fixes its recorded scheduling bug.
            if current or relative in required:
                data = path.read_bytes()
                assert len(data) == entry["byteCount"]
                assert hashlib.sha256(data).hexdigest() == entry["sha256"], relative
        assert required <= seen
        if current:
            assert "Sources/ArkTraceAnalysis/TraceDeterministicAnalysis.swift" in seen
            assert "rust/crates/arktrace-analysis/oracle/OracleHarness.swift" in seen
        inputs = json.loads((ROOT / FIXTURE / f"{input_name}.json").read_text())
        output = json.loads((ROOT / FIXTURE / f"{stem}.json").read_text())
        names = [v["name"] for v in inputs]
        assert len(inputs) == len(output) == len(set(names)) == count
        assert names == [v["name"] for v in output]
    print("Analysis oracles: 23 historical parity + 2 retained differences; 33 current exact vectors and Swift source/output digests")


if __name__ == "__main__":
    main()
