#!/usr/bin/env python3
"""Actual native persistent sessions, plus an optional real Swift SDK consumer.

Uses an isolated writable root and preserves command/binary evidence. Controlled
Ready copying is explicit; the default exercises a fresh original trace parse.
This is development feedback, not App/distribution or full cache acceptance.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from test_macos_rust_sdk import ROOT, consumer


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def execute(command, directory, name):
    result = subprocess.run(command, cwd=ROOT, capture_output=True, timeout=240)
    (directory / (name + ".stdout")).write_bytes(result.stdout)
    (directory / (name + ".stderr")).write_bytes(result.stderr)
    receipt = dict(argv=command, cwd=str(ROOT), exitCode=result.returncode,
        executableSHA256=sha(command[0]), stdoutSHA256=hashlib.sha256(result.stdout).hexdigest(),
        stderrSHA256=hashlib.sha256(result.stderr).hexdigest())
    (directory / (name + ".receipt.json")).write_text(json.dumps(receipt, indent=2) + "\n")
    assert result.returncode == 0 and not result.stderr, (receipt, result.stderr.decode(errors="replace")[-6000:])
    return json.loads(result.stdout), receipt


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence-dir", type=Path, required=True)
    parser.add_argument("--controlled-opening", type=Path)
    parser.add_argument("--sdk", action="store_true")
    parser.add_argument("--maintenance", action="store_true")
    parser.add_argument("--sdk-maintenance", action="store_true")
    parser.add_argument("--product-runtime", action="store_true")
    options = parser.parse_args()
    base = options.evidence_dir
    assert base.is_absolute() and not base.exists() and not base.parent.is_symlink()
    base.mkdir(mode=0o700)
    cargo = [sys.executable, str(ROOT / "scripts/run-cargo.py")]
    build = cargo + ["build", "-p", "arktrace-engine", "--example", "macos_cache_probe"]
    if options.maintenance:
        build += ["--features", "process-fixtures"]
        os.environ["ARKTRACE_CACHE_MAINTENANCE_PROBE"] = "1"
    subprocess.run(build, cwd=ROOT, check=True, stdout=sys.stderr)
    # The probe may expose deliberate crash windows. The separately pinned
    # production-mode helper must not write the fixture .supervisor-entered
    # marker into the parser's closed disposable output directory.
    subprocess.run(cargo + ["build", "-p", "arktrace-platform", "--bin", "arktrace-host-process"], cwd=ROOT, check=True, stdout=sys.stderr)
    target = Path(json.loads(subprocess.check_output(cargo + ["metadata", "--format-version", "1", "--no-deps"], cwd=ROOT))["target_directory"]) / "debug"
    if options.controlled_opening:
        fixture = json.loads(options.controlled_opening.read_text())
        config = fixture["configurationTemplate"]
        original_source = Path(fixture["sourceForControlledOpening"])
        assert sha(original_source) == fixture["readySHA256"]
        identity = config["parserIdentity"]
        helper = Path(config["helper"]); trace_parser = Path(config["parser"])
        assert sha(helper) == config["helperSHA256"] and sha(trace_parser) == identity["binarySHA256"]
        source_format = "htrace"
    else:
        manifest = json.loads((ROOT / "ThirdParty/TraceStreamer/macx/manifest.json").read_text())
        identity = {k: manifest[k] for k in ("name", "reportedVersion", "binarySHA256", "upstreamRepository", "upstreamRevision", "architecture", "adapterVersion", "buildRecipeVersion")}
        helper = target / "arktrace-host-process"
        trace_parser = ROOT / "ThirdParty/TraceStreamer/macx/trace_streamer"
        assert sha(trace_parser) == identity["binarySHA256"]
        corpus = json.loads((ROOT / "docs/migration-runs/AT-RUST-001-2026-10-02-small-oracle.json").read_text())["corpus"]
        fixture = next(v for v in corpus if Path(v["path"]).name == "zlib.htrace")
        original_source = ROOT / fixture["path"]
        assert sha(original_source) == fixture["sha256"]
        source_format = "htrace"
    source = base / "source.htrace"; shutil.copyfile(original_source, source); source.chmod(0o400)
    tools = base / "tools"; tools.mkdir(mode=0o700)
    for path, name in ((helper, "helper"), (trace_parser, "parser")):
        shutil.copyfile(path, tools / name); (tools / name).chmod(0o500)
    probe = base / "macos-cache-probe"; shutil.copyfile(target / "examples/macos_cache_probe", probe); probe.chmod(0o500)
    native, native_receipt = execute([str(probe), str(base), str(source), json.dumps(identity), sha(tools / "helper"), source_format], base, "native")
    assert native["rawSourceUnchanged"] and native["warmDidNotParse"] and native["stagingPayloadCount"] == 0
    if options.maintenance:
        m = native["maintenance"]
        assert m["rawSourceUnchanged"] and m["reparseAfterPurge"] and m["quarantinePreserved"] and m["stableLeasePreserved"]
        assert [r["window"]["point"] for r in m["interruptedPurges"]] == [0, 1, 2, 3, 4]
        assert all(not r["exitSuccess"] and r["signal"] == 9 for r in m["interruptedPurges"])
    sdk = sdk_receipt = sdk_command = None
    if options.sdk or options.sdk_maintenance or options.product_runtime:
        _, sdk_receipt = consumer(Path(os.environ["ARKTRACE_RUST_XCFRAMEWORK"]))
        cache = Path(os.environ.get("ARKTRACE_RUST_SDK_CONSUMER_CACHE_ROOT", "/private/tmp/arktrace-rust-sdk-consumer"))
        executable = cache / "arktrace/build/out/Products/Debug/ArkTraceRustCoreConformance"
        assert sha(executable) == sdk_receipt["coreExecutable"]["sha256"]
        saved = base / "swift-cache-consumer"; shutil.copyfile(executable, saved); saved.chmod(0o500)
        namespace = base / "sdk-runtime"; namespace.mkdir(mode=0o700)
        persistent = base / "sdk-cache"; persistent.mkdir(mode=0o700)
        input_path = base / "sdk-input.json"
        input_path.write_text(json.dumps(dict(source=str(source), format=1, vectors=[], namespace=str(namespace), cacheDirectory=str(persistent), maintenance=options.sdk_maintenance,
            productRuntime=options.product_runtime, manifest=str(ROOT / "ThirdParty/TraceStreamer/macx/manifest.json"),
            helper=str(tools / "helper"), parser=str(tools / "parser"), helperSHA256=sha(tools / "helper"), parserIdentity=identity), indent=2) + "\n")
        input_path.chmod(0o400)
        sdk, sdk_command = execute([str(saved), str(input_path)], base, "sdk")
        assert all(v for k, v in sdk.items() if k not in ("fullCacheAcceptance", "appCutover"))
        if options.sdk_maintenance:
            assert all(sdk[k] for k in ("runtimeSDKMaintenanceConnected", "cacheMaintenanceBeforeOpen", "cacheMaintenanceActiveProtected",
                "cacheMaintenanceOneReaderProtected", "cacheMaintenancePurgeAndReparse", "cacheMaintenancePreCancelledPreservesReady"))
        if options.product_runtime:
            assert all(sdk[k] for k in ("productRuntimeConnected", "controllerMachineModelsEqualToSwift", "controllerSettingsPurgeAndReparse",
                "annotationsAndFavoritesRoundTrip", "persistenceDrainedBeforeClose"))
            assert len(list((base / "product-runtime/native/traces").rglob("trace.sqlite"))) == 1
            assert not list((base / "product-runtime/native/staging/.actors").glob("owner-*"))
        else:
            assert len(list(persistent.rglob("trace.sqlite"))) == 1
        assert not list(namespace.rglob("trace.db")) and not list(namespace.rglob("trace.sqlite"))
        assert not list((namespace / ".actors").glob("owner-*"))
    assert sha(source) == sha(original_source)
    print(json.dumps(dict(native=native, nativeCommand=native_receipt, sdk=sdk, sdkReceipt=sdk_receipt, sdkCommand=sdk_command,
        controlledOpening=bool(options.controlled_opening), originalTraceReparsed=not bool(options.controlled_opening),
        sourceSHA256=sha(source), sourceBytes=source.stat().st_size, helperSHA256=sha(tools / "helper"), parserIdentity=identity,
        rawSourceUnchanged=True, appCutover=False, fullCacheAcceptance=False), indent=2))


if __name__ == "__main__":
    main()
