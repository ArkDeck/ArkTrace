#!/usr/bin/env python3
"""Check contracts/arkdeck-contract.json against the Swift and Rust constants.

ArkDeck currently hardcodes the same three values. This file is the
ArkTrace-owned machine-readable source. ArkDeck should read it in a separate
change; this script does not modify ArkDeck.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTRACT = ROOT / "contracts" / "arkdeck-contract.json"
KEYS = ("index_schema_version", "parser_adapter_version", "schema_adapter_version")


def _read(relative):
    return (ROOT / relative).read_text(encoding="utf-8")


def _string_constant(text, pattern, label):
    match = re.search(pattern, text)
    if match is None:
        raise SystemExit(f"missing {label}")
    return match.group(1)


def source_contract():
    parser = _read("Sources/ArkTraceParser/TraceStreamerProcessParser.swift")
    schema = _read("Sources/ArkTraceStore/TraceSchemaAdapter.swift")
    preparer = _read("Sources/ArkTraceStore/TraceDatabaseStagingPreparer.swift")
    rust = _read("rust/crates/arktrace-contract/src/lib.rs")
    swift = {
        "parser_adapter_version": _string_constant(
            parser, r'public static let adapterVersion = "([^"]+)"', "Swift parser adapter"
        ),
        "schema_adapter_version": _string_constant(
            schema, r"static let version = \"([^\"]+)\"", "Swift schema adapter"
        ),
        "index_schema_version": int(_string_constant(
            preparer, r"public static let indexVersion = ([0-9]+)", "Swift index schema"
        )),
    }
    rust_values = {
        "parser_adapter_version": _string_constant(
            rust, r'pub const PARSER_ADAPTER_VERSION: &str = "([^"]+)";', "Rust parser adapter"
        ),
        "schema_adapter_version": _string_constant(
            rust, r'pub const SCHEMA_ADAPTER_VERSION: &str = "([^"]+)";', "Rust schema adapter"
        ),
        "index_schema_version": int(_string_constant(
            rust, r"pub const INDEX_SCHEMA_VERSION: u32 = ([0-9]+);", "Rust index schema"
        )),
    }
    if swift != rust_values:
        raise SystemExit(f"Swift/Rust ArkDeck contract drift: {swift} != {rust_values}")
    definitions = json.loads(_read("contracts/index-definitions.json"))
    if definitions["indexSchemaVersion"] != swift["index_schema_version"]:
        raise SystemExit("index-definitions.json indexSchemaVersion drifted from source")
    return {"format": 1, **swift}


def render(document):
    # LF bytes only. Windows text mode would rewrite the checked contract as CRLF.
    return (json.dumps(document, indent=2, sort_keys=True) + "\n").encode("utf-8")


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    write = "--write" in argv
    if any(arg not in ("--check", "--write") for arg in argv):
        raise SystemExit("usage: verify_arkdeck_contract.py [--check|--write]")
    document = source_contract()
    if set(document) != {"format", *KEYS}:
        raise SystemExit("contract key set drifted")
    encoded = render(document)
    if write:
        CONTRACT.write_bytes(encoded)
        print(f"wrote {CONTRACT.relative_to(ROOT)}")
        return
    actual = CONTRACT.read_bytes()
    if actual != encoded:
        raise SystemExit(
            "contracts/arkdeck-contract.json drifted from Swift and Rust constants; "
            "regenerate with scripts/verify_arkdeck_contract.py --write"
        )
    loaded = json.loads(actual.decode("utf-8"))
    if loaded != document:
        raise SystemExit("arkdeck contract JSON does not match source constants")
    print(
        "arkdeck contract: "
        f"parser {document['parser_adapter_version']}, "
        f"schema {document['schema_adapter_version']}, "
        f"index {document['index_schema_version']}"
    )


if __name__ == "__main__":
    main()
