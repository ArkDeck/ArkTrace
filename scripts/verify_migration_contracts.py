#!/usr/bin/env python3
"""Verify migration vectors against their existing authoritative sources."""
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent


def main():
    from verify_analysis_oracles import main as verify_analysis_oracles
    verify_analysis_oracles()
    from verify_store_oracles import main as verify_store_oracles
    verify_store_oracles()
    source = (ROOT / "Sources/ArkTraceCore/Model/TraceModels.swift").read_text()
    scope_block = source.split("machineAllowed: Set<String> = [", 1)[1].split("\n    ]", 1)[0]
    scopes = sorted(re.findall(r'"([^"\n]+)"', scope_block))
    assert scopes == json.loads((ROOT / "contracts/quality-scopes.json").read_text()), "quality scope drift"
    index = json.loads((ROOT / "contracts/machine-fixtures-index.json").read_text())
    assert index["version"] == 1
    fixtures = {p.relative_to(ROOT).as_posix() for p in (ROOT / index["sourceDirectory"]).glob("*.json")}
    assert fixtures == {entry["path"] for entry in index["fixtures"]}, "machine fixture set drift"
    for entry in index["fixtures"]:
        data = (ROOT / entry["path"]).read_bytes()
        assert hashlib.sha256(data).hexdigest() == entry["sha256"], entry["path"]
        assert json.loads(data)["schemaVersion"] == "1.0", entry["path"]
    for name in ["time-range-vectors.json", "quality-vectors.json", "cache-lease-vectors.json"]:
        corpus = json.loads((ROOT / "contracts" / name).read_text())
        assert corpus["version"] == 1 and corpus["vectors"]
        ids = [vector["id"] for vector in corpus["vectors"]]
        assert len(ids) == len(set(ids)), f"duplicate vector in {name}"
    protocol = json.loads((ROOT / "contracts/cache-lease-vectors.json").read_text())["protocol"]
    assert protocol["windows"] == {"primitive": "LockFileEx", "offsetDecimal": str(2**64 - 2), "lengthBytes": 1}
    assert protocol["lockOrder"] == ["keyLock", "exclusiveEntryLease", "ownerLock"]
    definitions = json.loads((ROOT / "contracts/index-definitions.json").read_text())
    assert definitions["version"] == 1 and definitions["indexSchemaVersion"] == 3
    preparer = (ROOT / "Sources/ArkTraceStore/TraceDatabaseStagingPreparer.swift").read_text()
    block = preparer.split("private static let indexes = [", 1)[1].split("\n    ]", 1)[0]
    frozen = []
    for definition in re.findall(r"IndexDefinition\((.*?)\n        \)", block, re.S):
        def string_field(name):
            return re.search(rf'{name}: "([^"\n]+)"', definition)[1]

        def bool_field(name, default=None):
            match = re.search(rf"{name}: (true|false)", definition)
            assert match or default is not None, f"missing {name}"
            return match[1] == "true" if match else default

        frozen.append({
            "name": string_field("name"), "table": string_field("table"),
            "columns": re.findall(r'"([^"\n]+)"', re.search(r"columns: \[(.*?)\]", definition, re.S)[1]),
            "bootstrap": bool_field("bootstrapForValidation"),
            "required": bool_field("requiredForReady"),
            "unique": bool_field("unique", False), "partial": bool_field("partial", False),
        })
    assert len(frozen) == 24 and definitions["definitions"] == frozen, "Swift/Rust index definition drift"
    assert len({d["name"] for d in frozen}) == 24
    metadata = json.loads((ROOT / "contracts/ready-metadata.json").read_text())
    runtime = (ROOT / "Sources/ArkTraceRuntime/TraceCache.swift").read_text()
    keys = runtime.split("private enum CodingKeys: String, CodingKey, CaseIterable {", 1)[1].split("\n    }", 1)[0]
    expected = {key.strip() for line in keys.splitlines() if "case " in line for key in line.split("case ", 1)[1].split(",")}
    assert set(metadata) == expected and metadata["formatVersion"] == 1, "metadata root fields drift"
    parser = source.split("public struct TraceParserIdentity", 1)[1].split("/// Capability", 1)[0]
    assert set(metadata["parser"]) == set(re.findall(r"public let (\w+):", parser)), "parser identity fields drift"
    parser_api = (ROOT / "Sources/ArkTraceCore/Parser/TraceParser.swift").read_text()
    preparation = parser_api.split("package struct TraceDatabasePreparationResult", 1)[1].split("package struct TraceDatabaseMetadataSidecar", 1)[0]
    assert set(metadata["databasePreparation"]) == set(re.findall(r"public let (\w+):", preparation)), "preparation metadata fields drift"
    assert len((ROOT / "contracts/ready-metadata.json").read_bytes()) <= 16384
    print(f"migration contracts: {len(fixtures)} existing Machine JSON fixtures; {len(scopes)} closed scopes; {len(frozen)} index definitions; {len(expected)} Ready metadata fields")


if __name__ == "__main__":
    main()
