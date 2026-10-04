#!/usr/bin/env python3
"""One fixed real Trace: retained density SDK/Core vs original Swift SQLite.

No App/release acceptance. An optional new private directory retains a separate
Ready copy; the session-owned Ready is still removed after close.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
from test_macos_event_sdk import build_reference
from test_macos_rust_sdk import ROOT, consumer


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    args = argparse.ArgumentParser()
    args.add_argument("--reference-build-only", action="store_true")
    args.add_argument("--retain-ready", type=Path)
    options = args.parse_args()
    oracle = build_reference("density")
    reference_receipt = oracle.parents[4] / "reference-build-receipt.json"
    if options.reference_build_only:
        print(reference_receipt.read_text(), end="")
        return
    if options.retain_ready:
        assert options.retain_ready.is_absolute() and not options.retain_ready.exists()
        assert not options.retain_ready.parent.is_symlink()
        options.retain_ready.mkdir(mode=0o700)
    artifact = Path(os.environ["ARKTRACE_RUST_XCFRAMEWORK"])
    _, receipt = consumer(artifact)
    cache = Path(os.environ.get("ARKTRACE_RUST_SDK_CONSUMER_CACHE_ROOT", "/private/tmp/arktrace-rust-sdk-consumer"))
    executable = cache / "arktrace/build/out/Products/Debug/ArkTraceRustCoreConformance"
    assert sha(executable) == receipt["coreExecutable"]["sha256"]
    commands = []

    def cargo(*arguments):
        command = ["python3", str(ROOT / "scripts/run-cargo.py"), *arguments]
        process = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
        commands.append(dict(argv=command, cwd=str(ROOT), exitCode=process.returncode,
            environmentOverrides={key: os.environ[key] for key in ("ARKTRACE_CARGO_CACHE_ROOT", "CARGO_NET_OFFLINE") if key in os.environ},
            stdoutSHA256=hashlib.sha256(process.stdout.encode()).hexdigest(), stderrSHA256=hashlib.sha256(process.stderr.encode()).hexdigest()))
        assert process.returncode == 0, process.stderr
        return process.stdout

    cargo("build", "-p", "arktrace-platform", "--bin", "arktrace-host-process")
    helper = Path(json.loads(cargo("metadata", "--format-version", "1", "--no-deps"))["target_directory"]) / "debug/arktrace-host-process"
    parser = ROOT / "ThirdParty/TraceStreamer/macx/trace_streamer"
    manifest = json.loads((parser.parent / "manifest.json").read_text())
    assert sha(parser) == manifest["binarySHA256"]
    parser_identity = {key: manifest[key] for key in ("name", "reportedVersion", "binarySHA256", "upstreamRepository",
        "upstreamRevision", "architecture", "adapterVersion", "buildRecipeVersion")}
    corpus = json.loads((ROOT / "docs/migration-runs/AT-RUST-001-2026-10-02-small-oracle.json").read_text())["corpus"]
    fixture = next(row for row in corpus if row["path"].endswith("trace_small_10.systrace"))
    source = ROOT / fixture["path"]
    assert sha(source) == fixture["sha256"]
    ready = options.retain_ready / "trace.db" if options.retain_ready else None
    with tempfile.TemporaryDirectory(prefix="arktrace-density-空 格-", dir="/private/tmp") as folder:
        base = Path(folder); tools = base / "tools"; tools.mkdir(mode=0o700)
        for path, name in ((helper, "helper"), (parser, "parser")):
            shutil.copyfile(path, tools / name); (tools / name).chmod(0o500)
        pins = {name: sha(tools / name) for name in ("helper", "parser")}
        namespace = base / "runtime"; namespace.mkdir(mode=0o700)
        value = dict(source=str(source), format=2, namespace=str(namespace), helper=str(tools / "helper"),
            parser=str(tools / "parser"), helperSHA256=pins["helper"], parserIdentity=parser_identity, vectors=[],
            densityOracle=str(oracle), densityReadyCopy=str(ready) if ready else None)
        input_path = base / "input.json"; input_path.write_text(json.dumps(value, ensure_ascii=False))
        command = [str(executable), str(input_path)]
        process = subprocess.run(command, cwd=ROOT, capture_output=True, timeout=120)
        commands.append(dict(argv=command, cwd=str(ROOT), exitCode=process.returncode,
            input=value, inputSHA256=sha(input_path), stdoutSHA256=hashlib.sha256(process.stdout).hexdigest(),
            stderrSHA256=hashlib.sha256(process.stderr).hexdigest()))
        assert process.returncode == 0 and not process.stderr, (process.returncode, process.stderr.decode(errors="replace"))
        assert str(base).encode() not in process.stdout
        actual = json.loads(process.stdout)
        proof = actual["densityProof"]
        assert proof["readyDatabaseBytesUnchanged"] and proof["privateReadyCopyRetained"] == bool(ready)
        assert len(proof["responses"]) == proof["retainedOwnersBeforeShutdown"] == 14
        assert proof["retainedBytesBeforeShutdown"] > 0
        assert {next(iter(row["request"]["source"])) for row in proof["responses"]} == {
            "cpu", "threadState", "namedSlice", "cpuCounter", "processCounter", "frame"}
        for row in proof["responses"]:
            for key in ("initialCore", "afterShutdownCore", "afterShutdownSDK"):
                assert row[key] == row["originalSwift"], row["request"]["id"]
            assert len(json.loads(row["initialCore"]["bodyUTF8"])["buckets"]) <= row["request"]["bucketCount"]
        assert all(actual[key] == 0 for key in ("storageBytesAfterCopies", "storageOwnersAfterCopies", "stagingBytesAfterCopies",
            "stagingOwnersAfterCopies", "nativeBytesBeforeShutdown"))
        assert not list(namespace.rglob("trace.db"))
        assert sha(source) == fixture["sha256"] and all(sha(tools / name) == pin for name, pin in pins.items())
        if ready:
            assert ready.stat().st_mode & 0o777 == 0o400 and sha(ready) == proof["readyDatabaseSHA256"]
            with sqlite3.connect(ready.as_uri() + "?mode=ro&immutable=1", uri=True) as database:
                assert database.execute("PRAGMA quick_check").fetchall() == [("ok",)]
                schema = database.execute("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").fetchall()
                indexes = [row[1] for row in schema if row[0] == "index" and row[1].startswith("arktrace_")]
            supplement = dict(readyDatabase=str(ready), byteCount=ready.stat().st_size, sha256=sha(ready), mode="0400",
                generatedBy="One real fixed systrace native SDK prepare, then independent copy while the owner was open",
                sourceFixture=fixture, metadata=actual["metadata"], parserIdentity=parser_identity, helperSHA256=pins["helper"],
                artifactIdentity=receipt["artifactIdentity"], nativeLibrary=receipt["artifactReceipt"]["library"],
                developmentFixtures=True, schema=schema, preparedIndexNames=indexes,
                consumerExecutableSHA256=receipt["coreExecutable"]["sha256"],
                openingConstraint="SDK has no direct database-open API. Reopening this DB as a source needs a separately pinned controlled copying-parser fixture, and is controlled evidence rather than fresh original-trace parsing.")
            (options.retain_ready / "ready-supplement.json").write_text(json.dumps(supplement, ensure_ascii=False, indent=2) + "\n")
            for path, name in ((helper, "arktrace-host-process"), (parser, "original-parser")):
                shutil.copyfile(path, options.retain_ready / name); (options.retain_ready / name).chmod(0o500)
    print(json.dumps(dict(densitySDK=True, rustAppCutover=False, fullSDKAcceptance=False, source=fixture,
        referenceReceipt=json.loads(reference_receipt.read_text()), sdkReceipt=receipt, commands=commands,
        runtimeTools=pins, parserIdentity=parser_identity, output=actual, rawTraceUnchanged=True,
        ownedReadyDatabaseRemoved=True, separatePrivateReadyCopyRetained=bool(ready)), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
