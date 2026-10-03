#!/usr/bin/env python3
"""Record real, path-free Swift CLI results twice; refuse nondeterministic bytes."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
MAX_OUTPUT = 8 * 1024 * 1024


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode() + b"\n"


def run_case(cli, parser, arguments, private_root):
    parser_options = [] if "--trace-streamer" in arguments else ["--trace-streamer", str(parser)]
    started = time.monotonic_ns()
    completed = subprocess.run(
        [str(cli), "--json", "--no-cache", "--max-rows", "128", "--max-events", "128", *parser_options, *arguments],
        cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=45,
    )
    assert len(completed.stdout) + len(completed.stderr) <= MAX_OUTPUT, "output budget exceeded"
    assert not completed.stderr, "machine invocation emitted diagnostics"
    assert completed.stdout, f"empty machine result (exit {completed.returncode}, command {arguments[0]})"
    value = json.loads(completed.stdout)
    assert value["schemaVersion"] == "1.0"
    encoded = canonical(value)
    for private in [str(ROOT), str(private_root), str(parser), "/Users/", "/private/"]:
        assert private.encode() not in encoded, "private path in machine result"
    assert ("error" in value) == (completed.returncode != 0), "exit/envelope mismatch"
    if value.get("trace"):
        identity = json.loads(parser.with_name("manifest.json").read_text())
        assert value["trace"]["parser"]["binarySha256"] == identity["binarySHA256"]
        provenance = value["provenance"]
        assert provenance["parserAdapterVersion"] == "1"
        assert provenance["schemaAdapterVersion"] == "2"
        assert provenance["indexSchemaVersion"] == 3
        assert len(provenance["upstreamDatabaseSha256"]) == 64
        assert all(c in "0123456789abcdef" for c in provenance["upstreamDatabaseSha256"])
        assert provenance["upstreamDatabaseByteCount"] > 0
    return {"exitCode": completed.returncode, "document": value, "wallTimeMs": (time.monotonic_ns() - started) / 1e6}


def semantic(record):
    value = copy.deepcopy(record["document"])
    # Confirmed by two real hiprofiler exports: only this DB-byte identity
    # varies. Keep both actual hashes in the recorded evidence.
    if value.get("provenance"):
        value["provenance"].pop("upstreamDatabaseSha256", None)
    return canonical({"exitCode": record["exitCode"], "document": value})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    cli = args.cli.resolve(strict=True)
    executable = ROOT / "ThirdParty/TraceStreamer/macx/trace_streamer"
    identity = json.loads(executable.with_name("manifest.json").read_text())
    assert digest(executable) == identity["binarySHA256"], "parser hash drift"
    fixtures = [ROOT / "Fixtures/traces" / name for name in [
        "zlib.htrace", "hiprofiler_data_ability.htrace", "trace_small_10.systrace",
    ]]
    corpus = [{"path": path.relative_to(ROOT).as_posix(), "sha256": digest(path), "byteCount": path.stat().st_size} for path in fixtures]
    # This is a development install of the actual Swift executable and
    # reviewed resources. It is never treated as a production distribution.
    with tempfile.TemporaryDirectory(prefix="arktrace-swift-oracle-") as temporary:
        private_root = Path(temporary).resolve()
        installed = private_root / "bin/arktrace"
        installed.parent.mkdir()
        shutil.copy2(cli, installed)
        # Xcode 27's build-system SwiftPM debug executable is unsigned. Apple
        # silicon requires a signature to execute it; sign only this disposable
        # copy, and record its resulting actual identity below.
        subprocess.run(["codesign", "--force", "--sign", "-", str(installed)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        installed_digest = digest(installed)
        resources = private_root / "share/arktrace"
        resources.mkdir(parents=True)
        for path in [ROOT / "LICENSE", ROOT / "THIRD_PARTY_NOTICES.md", executable.with_name("manifest.json"),
                     ROOT / "ThirdParty/TraceStreamer/license-inventory.json", fixtures[0]]:
            shutil.copy2(path, resources / path.name)
        shutil.copytree(ROOT / "ThirdParty/TraceStreamer/LICENSES", resources / "LICENSES")
        malformed = private_root / "malformed.htrace"
        malformed.write_bytes(b"not a trace\0\xff")
        cases = [("doctor", ["doctor", "--self-test"]), ("licenses", ["licenses"])]
        for fixture in corpus:
            trace = fixture["path"]
            stem = Path(trace).stem
            for command in ["inspect", "summary", "processes", "threads"]:
                cases.append((f"{stem}/{command}", [command, trace]))
            cases += [
                (f"{stem}/query", ["query", trace, "--view", "slices", "--start-ns", "0", "--end-ns", "1000000000", "--limit", "10"]),
                (f"{stem}/context", ["context", trace, "--start-ns", "0", "--end-ns", "1000000000"]),
                (f"{stem}/analyze", ["analyze", trace, "--kind", "range", "--start-ns", "0", "--end-ns", "1000000000"]),
            ]
        cases += [
            ("unknown-flag", ["--unknown", "inspect", corpus[0]["path"]]),
            ("duplicate-json", ["--json", "inspect", corpus[0]["path"]]),
            ("invalid-query-range", ["query", corpus[0]["path"], "--view", "slices", "--start-ns", "1", "--end-ns", "1"]),
            ("missing-source", ["inspect", str(private_root / "missing.htrace")]),
            ("missing-parser", ["--trace-streamer", str(private_root / "missing-parser"), "inspect", corpus[0]["path"]]),
            ("minimum-output-budget", ["--max-output-bytes", "1024", "summary", corpus[0]["path"]]),
            ("malformed-source", ["inspect", str(malformed)]),
        ]
        records = []
        for case_id, arguments in cases:
            first = run_case(installed, executable, arguments, private_root)
            second = run_case(installed, executable, arguments, private_root)
            for run in [first, second]:
                assert run["document"]["tool"]["buildRevision"] == installed_digest, "actual CLI identity mismatch"
                if "/" in case_id:
                    expected = next(f for f in corpus if Path(f["path"]).stem == case_id.split("/", 1)[0])
                    assert run["document"]["trace"]["sha256"] == expected["sha256"], "source binding mismatch"
                    assert run["document"]["trace"]["byteCount"] == expected["byteCount"]
            assert semantic(first) == semantic(second), f"semantic nondeterminism: {case_id}"
            exact = canonical(first["document"]) == canonical(second["document"])
            records.append({"id": case_id, "comparison": "T0" if exact else "T1", **first, "repeat": second})
        for fixture in corpus:
            assert digest(ROOT / fixture["path"]) == fixture["sha256"], "raw Trace changed"
        result = {
            "version": 1,
            "sourceRevision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
            "workingTreeDiffSHA256": hashlib.sha256(subprocess.check_output(["git", "diff", "--binary", "HEAD"], cwd=ROOT)).hexdigest(),
            "swiftBuildArtifactSHA256": digest(cli),
            "swiftExecutableSHA256": installed_digest,
            "parser": identity,
            "corpus": corpus,
            "comparison": {
                "runs": 2,
                "profile": {"maxRows": 128, "maxEvents": 128, "storage": "no-cache"},
                "allowedT1Fields": ["/provenance/upstreamDatabaseSha256"],
                "reason": "real repeated hiprofiler exports vary in upstream SQLite bytes; full actual provenance retained for both runs",
                "performance": "two cold no-cache invocation wall samples; not a warm workload/SLO acceptance",
            },
            "distribution": "ad-hoc developer resource install; no production release/signing claim",
            "records": records,
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(canonical(result))
        print(f"Swift oracle: {len(records)} cases recorded twice; raw corpus digests unchanged")


if __name__ == "__main__":
    main()
