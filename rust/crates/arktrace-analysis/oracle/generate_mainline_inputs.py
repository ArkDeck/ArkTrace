#!/usr/bin/env python3
"""Extend the retained inputs; only actual Swift generates expected results."""
import copy
import json
from pathlib import Path

CRATE = Path(__file__).resolve().parent.parent


def main():
    fixture = CRATE / "tests/fixtures"
    old = json.loads((fixture / "inputs.json").read_text())
    deviations = json.loads((fixture / "deviation-inputs.json").read_text())
    vectors = old + deviations
    pairs = [
        ("canonical-decomposed-first", ["e\u0301", "é"]),
        ("canonical-raw-label-sort", ["e\u0301", "f", "é"]),
        ("canonical-hangul", ["\u1100\u1161", "가"]),
        ("canonical-mark-order", ["a\u0315\u0300", "a\u0300\u0315"]),
        ("compatibility-forms-remain-distinct", ["ﬀ", "ff", "Ｆ", "F"]),
        ("canonical-embedded-nul-and-empty", ["", "é\0", "e\u0301\0", "é"]),
    ]
    for name, labels in pairs:
        vector = copy.deepcopy(deviations[1])
        vector["name"], vector["stateRows"] = name, []
        for index, label in enumerate(labels):
            row = copy.deepcopy(deviations[1]["stateRows"][0])
            row["key"]["rowID"] = index + 1
            row["range"] = {"startNs": index * 30, "endNs": (index + 1) * 30}
            row["state"] = label
            vector["stateRows"].append(row)
        vectors.append(vector)
    vector = copy.deepcopy(deviations[1])
    vector["name"] = "canonical-identities-properties-normalized-state-separated"
    vector["stateRows"] = []
    for index, changes in enumerate([{}, {"processKey": {"ipid": 2}}, {"pid": 99},
            {"tid": 99}, {"normalizedState": "running"}, {"threadKey": {"itid": 12}},
            {"state": "e\u0301"}]):
        row = copy.deepcopy(deviations[1]["stateRows"][0])
        row["key"]["rowID"] = index + 1
        row["range"] = {"startNs": index * 30, "endNs": (index + 1) * 30}
        row.update(changes)
        vector["stateRows"].append(row)
    vectors.append(vector)
    vector = copy.deepcopy(deviations[0])
    vector["name"] = "observed-proof-survives-unobserved-interval"
    row = copy.deepcopy(vector["stateRows"][0])
    row["key"]["rowID"] = 2
    row["range"]["startNs"] = 80
    row["isOpenEnded"] = False
    vector["stateRows"].append(row)
    vectors.append(vector)
    assert len(vectors) == 33
    (fixture / "mainline-inputs.json").write_text(json.dumps(vectors, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
