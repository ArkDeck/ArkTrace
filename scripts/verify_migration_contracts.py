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
    viewer = "rust/crates/arktrace-viewer/tests/fixtures/"
    for stem, inputs, count, current in [
        ("swift-geometry-oracle", "geometry-inputs", 25, False),
        ("swift-boundary-oracle", "boundary-inputs", 3, False),
        ("swift-plan-oracle", "plan-inputs", 13, False),
        ("swift-plan-migration-oracle", "plan-inputs", 13, True),
        ("swift-detail-oracle", "detail-inputs", 8, True),
        ("swift-scoped-slices-before", "scoped-slices-inputs", 6, False),
        ("swift-scoped-slices", "scoped-slices-inputs", 6, True),
        ("swift-scoped-counters", "scoped-counters-inputs", 7, True),
    ]:
        receipt = json.loads((ROOT / viewer / f"{stem}-receipt.json").read_text(encoding="utf-8"))
        required = {viewer + inputs + ".json", viewer + stem + ".json"}
        seen = set()
        for entry in receipt["sourceDigests"]:
            relative = entry["path"]
            assert relative not in seen
            seen.add(relative)
            path = ROOT / relative
            assert not path.is_symlink() and path.resolve().is_relative_to(ROOT)
            if current or relative in required:
                data = path.read_bytes()
                assert len(data) == entry["byteCount"] and hashlib.sha256(data).hexdigest() == entry["sha256"], relative
        assert required <= seen
        if current:
            modules = ("ArkTraceCore", "ArkTraceStore", "ArkTraceRendering") if inputs.startswith("scoped-") else ("ArkTraceCore", "ArkTraceRendering")
            for name in modules:
                assert {p.relative_to(ROOT).as_posix() for p in (ROOT / "Sources" / name).rglob("*.swift")} == {p for p in seen if p.startswith(f"Sources/{name}/")}
            if inputs.startswith("scoped-"):
                assert {"rust/crates/arktrace-viewer/oracle/ScopedSliceOracle.swift", "rust/crates/arktrace-viewer/oracle/run_scoped_slice_oracle.py"} <= seen
                assert receipt["database"]["bytesUnchanged"]
        inputs_json = json.loads((ROOT / viewer / f"{inputs}.json").read_text(encoding="utf-8"))
        outputs_json = json.loads((ROOT / viewer / f"{stem}.json").read_text(encoding="utf-8"))
        names = [v["name"] for v in (inputs_json["cases"] if inputs.startswith("scoped-") else inputs_json)]
        assert len(names) == len(set(names)) == len(outputs_json) == receipt["vectors"] == count
        assert names == [v["name"] for v in outputs_json]
    print("Viewer oracles: retained geometry/boundary/old plan/scope-before; 13 current loader, 8 actual detail/style, 6 actual SQLite slices and 7 counter scope vectors with source identities")
    presentation_receipt = json.loads((ROOT / viewer / "presentation-swift-receipt.json").read_text(encoding="utf-8"))
    assert presentation_receipt["copiedAlgorithms"] is False
    presentation_seen = set()
    for entry in presentation_receipt["sourceDigests"]:
        relative = entry["path"]
        assert relative not in presentation_seen
        presentation_seen.add(relative)
        path = ROOT / relative
        assert not path.is_symlink() and path.resolve().is_relative_to(ROOT)
        data = path.read_bytes()
        assert len(data) == entry["byteCount"] and hashlib.sha256(data).hexdigest() == entry["sha256"], relative
    assert {
        viewer + "presentation-inputs.json", viewer + "presentation-swift-oracle.json",
        "Tests/ArkTraceRenderingTests/TimelineRenderingTests.swift",
        "rust/crates/arktrace-viewer/oracle/presentation_harness.swift",
        "rust/crates/arktrace-viewer/oracle/presentation_renderer_access.swift",
        "rust/crates/arktrace-viewer/oracle/presentation_palette_access.swift",
        "rust/crates/arktrace-viewer/oracle/presentation_swift.py",
    } <= presentation_seen
    for name in ("ArkTraceCore", "ArkTraceRendering"):
        assert {p.relative_to(ROOT).as_posix() for p in (ROOT / "Sources" / name).rglob("*.swift")} == {p for p in presentation_seen if p.startswith(f"Sources/{name}/")}
    presentation_inputs = json.loads((ROOT / viewer / "presentation-inputs.json").read_text(encoding="utf-8"))
    presentation_outputs = json.loads((ROOT / viewer / "presentation-swift-oracle.json").read_text(encoding="utf-8"))
    for section, count in (("palette", 1068), ("genericDetails", 38), ("dto", 62)):
        names = [entry["name"] for entry in presentation_inputs[section]]
        assert len(names) == len(set(names)) == presentation_receipt["counts"][section] == count
        assert names == [entry["name"] for entry in presentation_outputs[section]]
    print("Palette/presentation oracle: 1,068 palette, 38 style and 62 DTO vectors with actual Swift source/output identities")
    navigation_receipt = json.loads((ROOT / viewer / "navigation-mainline-swift-receipt.json").read_text(encoding="utf-8"))
    assert navigation_receipt["copiedAlgorithms"] is False and navigation_receipt["exitCode"] == 0
    navigation_seen = set()
    for entry in navigation_receipt["sourceDigests"]:
        relative = entry["path"]
        assert relative not in navigation_seen
        navigation_seen.add(relative)
        path = ROOT / relative
        assert not path.is_symlink() and path.resolve().is_relative_to(ROOT)
        data = path.read_bytes()
        assert len(data) == entry["byteCount"] and hashlib.sha256(data).hexdigest() == entry["sha256"], relative
    assert navigation_receipt["sourceModules"] == ["ArkTraceCore", "ArkTraceStore", "ArkTraceRendering", "ArkTraceAppSupport"]
    for name in navigation_receipt["sourceModules"]:
        assert {p.relative_to(ROOT).as_posix() for p in (ROOT / "Sources" / name).rglob("*.swift")} == {p for p in navigation_seen if p.startswith(f"Sources/{name}/")}
    assert {"rust/crates/arktrace-viewer/oracle/" + name for name in (
        "navigation_controller_seam.swift", "navigation_rendering_seam.swift",
        "navigation_harness.swift", "navigation_run_swift.py",
    )} <= navigation_seen
    navigation_inputs = {}
    for stem, count in (("navigation", 8), ("navigation-rendering", 64), ("navigation-restore", 3)):
        input_path, output_path = viewer + stem + "-inputs.json", viewer + stem + "-swift-oracle.json"
        assert {input_path, output_path} <= navigation_seen
        inputs = json.loads((ROOT / input_path).read_text(encoding="utf-8"))
        outputs = json.loads((ROOT / output_path).read_text(encoding="utf-8"))
        names = [entry["name"] for entry in inputs]
        assert len(names) == len(set(names)) == len(outputs) == count
        assert names == [entry["name"] for entry in outputs]
        navigation_inputs[stem] = inputs
    assert sum(len(case["actions"]) for case in navigation_inputs["navigation"]) == 55
    assert sum(len(case["filters"]) for case in navigation_inputs["navigation"]) == 161
    whitespace_path = viewer + "navigation-whitespace-swift-oracle.json"
    assert whitespace_path in navigation_seen
    whitespace = json.loads((ROOT / whitespace_path).read_text(encoding="utf-8"))
    assert len(whitespace) == len(set(whitespace)) == 26
    assert navigation_receipt["counts"] == {
        "catalogs": 8, "actions": 55, "filters": 161, "nativeNavigation": 64,
        "restore": 3, "whitespaceScalars": 26,
    }
    print("Navigation oracle: 8 catalogs, 55 actions, 161 recorded host filters, 64 native focus/anchor and 3 restore vectors with current Swift source/output identities")
    annotation_receipt = json.loads((ROOT / viewer / "annotation-mainline-swift-receipt.json").read_text(encoding="utf-8"))
    assert annotation_receipt["copiedExpectedStateAlgorithms"] is False and annotation_receipt["exitCode"] == 0
    annotation_seen = set()
    for entry in annotation_receipt["sourceDigests"]:
        relative = entry["path"]
        assert relative not in annotation_seen
        annotation_seen.add(relative)
        path = ROOT / relative
        assert not path.is_symlink() and path.resolve().is_relative_to(ROOT)
        data = path.read_bytes()
        assert len(data) == entry["byteCount"] and hashlib.sha256(data).hexdigest() == entry["sha256"], relative
    assert annotation_receipt["sourceModules"] == ["ArkTraceCore", "ArkTraceParser", "ArkTraceStore", "ArkTraceRuntime", "ArkTraceAnalysis", "ArkTraceRendering", "ArkTraceAppSupport"]
    for name in annotation_receipt["sourceModules"]:
        assert {p.relative_to(ROOT).as_posix() for p in (ROOT / "Sources" / name).rglob("*.swift")} == {p for p in annotation_seen if p.startswith(f"Sources/{name}/")}
    assert {
        viewer + "annotation-inputs.json", viewer + "annotation-swift-oracle.json",
        "rust/crates/arktrace-viewer/oracle/annotation_access.swift",
        "rust/crates/arktrace-viewer/oracle/annotation_harness.swift",
        "rust/crates/arktrace-viewer/oracle/annotation_swift.py",
        "Apps/ArkTraceApp/Viewer/TraceTimelinePane.swift",
        "Apps/ArkTraceApp/Inspector/AnnotationInspectorView.swift",
        "Tests/ArkTraceAppSupportTests/TraceDocumentControllerTests.swift",
        "Tests/ArkTraceAppSupportTests/TraceViewStateStoreTests.swift",
        "Tests/ArkTraceRenderingTests/TimelineAnnotationKeyTests.swift",
        "Tests/ArkTraceRenderingTests/TimelineFlagSelectionTests.swift",
    } <= annotation_seen
    annotation_inputs = json.loads((ROOT / viewer / "annotation-inputs.json").read_text(encoding="utf-8"))["cases"]
    annotation_outputs = json.loads((ROOT / viewer / "annotation-swift-oracle.json").read_text(encoding="utf-8"))["cases"]
    names = [entry["name"] for entry in annotation_inputs]
    assert len(names) == len(set(names)) == len(annotation_outputs) == annotation_receipt["cases"] == 74
    assert names == [entry["name"] for entry in annotation_outputs]
    assert sum(len(entry["steps"]) for entry in annotation_inputs) == annotation_receipt["actions"] == 674
    assert sum(len(entry["states"]) for entry in annotation_outputs) == annotation_receipt["states"] == 748
    assert all(len(inputs["steps"]) + 1 == len(outputs["states"]) for inputs, outputs in zip(annotation_inputs, annotation_outputs))
    rename = annotation_receipt["deferredRenameCompiledOriginalBlock"]
    assert rename["source"] == "Apps/ArkTraceApp/Viewer/TraceTimelinePane.swift"
    body = re.search(r'rename: \{ label in\n(.*?)\n\s*\},', (ROOT / rename["source"]).read_text(encoding="utf-8"), re.S)[1]
    assert body == rename["utf8"] and hashlib.sha256(body.encode("utf-8")).hexdigest() == rename["sha256"]
    print("Annotation oracle: 74 scenarios, 674 actions and 748 actual Swift states with source/output and deferred editor identities")
    source = (ROOT / "Sources/ArkTraceCore/Model/TraceModels.swift").read_text(encoding="utf-8")
    scope_block = source.split("machineAllowed: Set<String> = [", 1)[1].split("\n    ]", 1)[0]
    scopes = sorted(re.findall(r'"([^"\n]+)"', scope_block))
    assert scopes == json.loads((ROOT / "contracts/quality-scopes.json").read_text(encoding="utf-8")), "quality scope drift"
    index = json.loads((ROOT / "contracts/machine-fixtures-index.json").read_text(encoding="utf-8"))
    assert index["version"] == 1
    fixtures = {p.relative_to(ROOT).as_posix() for p in (ROOT / index["sourceDirectory"]).glob("*.json")}
    assert fixtures == {entry["path"] for entry in index["fixtures"]}, "machine fixture set drift"
    for entry in index["fixtures"]:
        data = (ROOT / entry["path"]).read_bytes()
        assert hashlib.sha256(data).hexdigest() == entry["sha256"], entry["path"]
        assert json.loads(data)["schemaVersion"] == "1.0", entry["path"]
    for name in ["time-range-vectors.json", "quality-vectors.json", "cache-lease-vectors.json"]:
        corpus = json.loads((ROOT / "contracts" / name).read_text(encoding="utf-8"))
        assert corpus["version"] == 1 and corpus["vectors"]
        ids = [vector["id"] for vector in corpus["vectors"]]
        assert len(ids) == len(set(ids)), f"duplicate vector in {name}"
    protocol = json.loads((ROOT / "contracts/cache-lease-vectors.json").read_text(encoding="utf-8"))["protocol"]
    assert protocol["windows"] == {"primitive": "LockFileEx", "offsetDecimal": str(2**64 - 2), "lengthBytes": 1}
    assert protocol["lockOrder"] == ["keyLock", "exclusiveEntryLease", "ownerLock"]
    definitions = json.loads((ROOT / "contracts/index-definitions.json").read_text(encoding="utf-8"))
    assert definitions["version"] == 1 and definitions["indexSchemaVersion"] == 3
    preparer = (ROOT / "Sources/ArkTraceStore/TraceDatabaseStagingPreparer.swift").read_text(encoding="utf-8")
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
    metadata = json.loads((ROOT / "contracts/ready-metadata.json").read_text(encoding="utf-8"))
    runtime = (ROOT / "Sources/ArkTraceRuntime/TraceCache.swift").read_text(encoding="utf-8")
    keys = runtime.split("private enum CodingKeys: String, CodingKey, CaseIterable {", 1)[1].split("\n    }", 1)[0]
    expected = {key.strip() for line in keys.splitlines() if "case " in line for key in line.split("case ", 1)[1].split(",")}
    assert set(metadata) == expected and metadata["formatVersion"] == 1, "metadata root fields drift"
    parser = source.split("public struct TraceParserIdentity", 1)[1].split("/// Capability", 1)[0]
    assert set(metadata["parser"]) == set(re.findall(r"public let (\w+):", parser)), "parser identity fields drift"
    parser_api = (ROOT / "Sources/ArkTraceCore/Parser/TraceParser.swift").read_text(encoding="utf-8")
    preparation = parser_api.split("package struct TraceDatabasePreparationResult", 1)[1].split("package struct TraceDatabaseMetadataSidecar", 1)[0]
    assert set(metadata["databasePreparation"]) == set(re.findall(r"public let (\w+):", preparation)), "preparation metadata fields drift"
    assert len((ROOT / "contracts/ready-metadata.json").read_bytes()) <= 16384
    print(f"migration contracts: {len(fixtures)} existing Machine JSON fixtures; {len(scopes)} closed scopes; {len(frozen)} index definitions; {len(expected)} Ready metadata fields")


if __name__ == "__main__":
    main()
