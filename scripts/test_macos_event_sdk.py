#!/usr/bin/env python3
"""Seven actual SDK event operations vs current original Swift repository.

The independent Swift process reads the same Ready SQLite database. Existing
Core consumer also holds typed SDK owners and copied DTOs through shutdown.
Development/no-cache evidence only, not App or signed release acceptance.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from test_macos_core_sdk import main as core_main
from test_macos_rust_sdk import ROOT


def build_reference(kind="event"):
    assert kind in ("event", "density")
    name = "EventOriginalOracle" if kind == "event" else "DensityOriginalOracle"
    cache = Path(os.environ.get("ARKTRACE_EVENT_ORACLE_CACHE_ROOT", "/private/tmp/arktrace-" + kind + "-reference"))
    assert cache.is_absolute() and not cache.resolve().is_relative_to(ROOT) and not cache.is_symlink()
    source = cache / "oracle-source"
    source.mkdir(parents=True, exist_ok=True)
    for module in ("ArkTraceCore", "ArkTraceStore"):
        target = source / "Sources" / module
        if target.exists(): shutil.rmtree(target)
        shutil.copytree(ROOT / "Sources" / module, target)
    target = source / "Sources" / name
    target.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / "scripts/swift-sdk-core/EventProofModel.swift", target / "EventProofModel.swift")
    if kind == "density":
        shutil.copyfile(ROOT / "scripts/swift-sdk-core/DensityProofModel.swift", target / "DensityProofModel.swift")
    main = "EventSDKOriginal.swift" if kind == "event" else "DensitySDKOriginal.swift"
    shutil.copyfile(ROOT / "rust/crates/arktrace-store/oracle" / main, target / main)
    shutil.copytree(ROOT / "scripts", source / "scripts", dirs_exist_ok=True)
    (source / "Package.swift").write_text('''// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "ArkTrace", platforms: [.macOS(.v26)], targets: [
 .target(name: "ArkTraceCore", swiftSettings: [.strictMemorySafety()]),
 .target(name: "ArkTraceStore", dependencies: ["ArkTraceCore"], swiftSettings: [.strictMemorySafety()]),
 .executableTarget(name: "%s", dependencies: ["ArkTraceCore", "ArkTraceStore"], swiftSettings: [.strictMemorySafety()])
], swiftLanguageModes: [.v6])
''' % name)
    subprocess.run(["git", "init", "--quiet"], cwd=source, check=True)
    env = os.environ.copy(); env["ARKTRACE_SWIFTPM_CACHE_ROOT"] = str(cache)
    env.pop("ARKTRACE_RUST_XCFRAMEWORK", None); env.pop("ARKTRACE_RUST_SDK_FIXTURES", None)
    command = ["sh", "scripts/run-swiftpm.sh", "build", "--disable-sandbox", "--config-path", str(cache / "configuration"),
        "--security-path", str(cache / "security"), "--product", name, "-Xswiftc", "-warnings-as-errors"]
    log = cache / "reference-build.log"
    with log.open("w") as output:
        process = subprocess.run(command, cwd=source, env=env, stdout=output, stderr=subprocess.STDOUT)
    if process.returncode: raise RuntimeError((process.returncode, log.read_text()[-6000:]))
    assert "warning:" not in log.read_text() and "error:" not in log.read_text()
    executable = cache / "build/out/Products/Debug" / name
    receipt = dict(command=command, cwd=str(source), environmentOverrides={"ARKTRACE_SWIFTPM_CACHE_ROOT": str(cache)},
        removedEnvironmentKeys=["ARKTRACE_RUST_XCFRAMEWORK", "ARKTRACE_RUST_SDK_FIXTURES"], exitCode=process.returncode,
        executableSHA256=hashlib.sha256(executable.read_bytes()).hexdigest(),
        logSHA256=hashlib.sha256(log.read_bytes()).hexdigest(), sourcePins=[])
    for folder in (cache / "workspace/Sources/ArkTraceCore", cache / "workspace/Sources/ArkTraceStore", cache / "workspace/Sources" / name):
        for path in sorted(folder.rglob("*.swift")):
            content = path.read_bytes()
            receipt["sourcePins"].append(dict(path=str(path), byteCount=len(content), sha256=hashlib.sha256(content).hexdigest()))
    (cache / "reference-build-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return executable


if __name__ == "__main__":
    executable = build_reference()
    if "--reference-build-only" in sys.argv:
        cache = executable.parents[4]
        print((cache / "reference-build-receipt.json").read_text(), end="")
    else:
        os.environ["ARKTRACE_EVENT_REFERENCE_ORACLE"] = str(executable)
        core_main()
