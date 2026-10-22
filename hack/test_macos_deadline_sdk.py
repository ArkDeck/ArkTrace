#!/usr/bin/env python3
"""Exact per-slot continuous deadlines through SDK/Core vs current Swift repository.

Uses an explicitly supplied private controlled-opening fixture and independent
Ready source copy. No fresh original-trace parse, App or signed release acceptance is claimed. CI can build the independent reference alone.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
from test_macos_event_sdk import build_reference
from test_macos_rust_sdk import ROOT, consumer


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--reference-build-only", action="store_true")
    parser.add_argument("--controlled-opening", type=Path)
    parser.add_argument("--evidence-dir", type=Path)
    options = parser.parse_args()
    oracle = build_reference("deadline")
    reference_receipt = oracle.parents[4] / "reference-build-receipt.json"
    if options.reference_build_only:
        print(reference_receipt.read_text(), end="")
        return
    assert options.controlled_opening and options.evidence_dir
    fixture = json.loads(options.controlled_opening.read_text())
    config = fixture["configurationTemplate"]
    original_source = Path(fixture["sourceForControlledOpening"])
    assert sha(original_source) == fixture["readySHA256"]
    assert original_source.stat().st_size == fixture["readyBytes"]
    assert config["parserIdentity"]["adapterVersion"] == "1"
    base = options.evidence_dir
    assert base.is_absolute() and not base.exists() and not base.parent.is_symlink()
    base.mkdir(mode=0o700)
    source = base / "controlled-source.db"
    shutil.copyfile(original_source, source); source.chmod(0o400)
    tools = base / "tools"; tools.mkdir(mode=0o700)
    for name, pin in (("helper", config["helperSHA256"]), ("parser", config["parserIdentity"]["binarySHA256"])):
        assert sha(config[name]) == pin
        shutil.copyfile(config[name], tools / name); (tools / name).chmod(0o500)
        assert sha(tools / name) == pin
    artifact = Path(os.environ["ARKTRACE_RUST_XCFRAMEWORK"])
    _, receipt = consumer(artifact)
    cache = Path(os.environ.get("ARKTRACE_RUST_SDK_CONSUMER_CACHE_ROOT", "/private/tmp/arktrace-rust-sdk-consumer"))
    executable = cache / "arktrace/build/out/Products/Debug/ArkTraceRustCoreConformance"
    assert sha(executable) == receipt["coreExecutable"]["sha256"]
    namespace = base / "runtime"; namespace.mkdir(mode=0o700)
    value = dict(source=str(source), format=1, namespace=str(namespace), helper=str(tools / "helper"), parser=str(tools / "parser"),
        helperSHA256=config["helperSHA256"], parserIdentity=config["parserIdentity"], vectors=[], deadlineOracle=str(oracle))
    input_path = base / "input.json"; input_path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n"); input_path.chmod(0o400)
    command = [str(executable), str(input_path)]
    command_receipt = dict(argv=command, cwd=str(ROOT), inputSHA256=sha(input_path), executableSHA256=sha(executable))
    (base / "consumer-command.json").write_text(json.dumps(command_receipt, indent=2) + "\n")
    process = subprocess.run(command, cwd=ROOT, capture_output=True, timeout=120)
    (base / "consumer.stdout").write_bytes(process.stdout); (base / "consumer.stderr").write_bytes(process.stderr)
    command_receipt.update(exitCode=process.returncode, stdoutSHA256=hashlib.sha256(process.stdout).hexdigest(),
        stderrSHA256=hashlib.sha256(process.stderr).hexdigest())
    (base / "consumer-receipt.json").write_text(json.dumps(command_receipt, indent=2) + "\n")
    assert process.returncode == 0 and not process.stderr, (process.returncode, process.stderr.decode(errors="replace")[-6000:])
    actual = json.loads(process.stdout); proof = actual["deadlineProof"]
    assert len(proof["responses"]) == 11 and proof["retainedOwnersBeforeShutdown"] == 6
    assert proof["retainedBytesBeforeShutdown"] > 0 and proof["readyDatabaseBytesUnchanged"]
    successes = failures = 0
    for row in proof["responses"]:
        assert row["initialCore"] == row["initialSDK"] == row["originalSwift"], row["request"]["plan"]["id"]
        value = row["initialCore"]
        if "value" in value:
            successes += 1
            assert row["afterShutdownCore"] == row["afterShutdownSDK"] == value
        else:
            failures += 1
            assert value["code"] == "QUERY_TIMEOUT" and value["stage"] == "querying" and value["retryable"]
            assert "afterShutdownCore" not in row and "afterShutdownSDK" not in row
    assert successes == 6 and failures == 5
    assert proof["originalOracleExitCode"] == 0
    assert all(actual[key] == 0 for key in ("storageBytesAfterCopies", "storageOwnersAfterCopies", "stagingBytesAfterCopies",
        "stagingOwnersAfterCopies", "nativeBytesBeforeShutdown"))
    assert not list(namespace.rglob("trace.db"))
    assert sha(source) == sha(original_source) == fixture["readySHA256"]
    assert sha(tools / "helper") == config["helperSHA256"] and sha(tools / "parser") == config["parserIdentity"]["binarySHA256"]
    print(json.dumps(dict(deadlineSDK=True, rustAppCutover=False, fullSDKAcceptance=False, individualCoreDeadlinesTransported=True,
        controlledReadyOpening=True, originalTraceReparsed=False, sourceSHA256=sha(source), sourceBytes=source.stat().st_size,
        originalReadySupplementSHA256=fixture["originalReadySupplementSHA256"],
        successfulRequests=successes, timedOutRequests=failures, nativeBatchCalls=22, referenceReceipt=json.loads(reference_receipt.read_text()), sdkReceipt=receipt, consumerCommand=command_receipt,
        output=actual, controlledSourceUnchanged=True, ownedReadyDatabaseRemoved=True), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
