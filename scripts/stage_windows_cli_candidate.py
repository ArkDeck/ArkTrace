#!/usr/bin/env python3
"""Stage a private development Rust CLI candidate for native Windows x64 checks.

This is a development candidate, not a signed distribution (AT-RUST-016 packages
the release). It is built with the `development-resources` feature, so every image
is pinned by its whole SHA-256 only. The layout is the closed Windows installation
layout documented in docs/guides/CLI.md:

    <output>/arktrace.exe
    <output>/resources/ArkTraceRust/runtime.json
    <output>/resources/Helpers/arktrace-host-process.exe
    <output>/resources/Helpers/trace_streamer.exe
    <output>/resources/zlib.htrace                (doctor --self-test trace)

The parser must be the locally rebuilt recipe binary whose SHA-256 equals
ThirdParty/TraceStreamer/windows-x86_64/manifest.json; it is never committed.
"""
import argparse
import hashlib
import json
import platform
import shutil
import subprocess
import sys
from pathlib import Path
from windows_cli_distribution import stage_attribution

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "ThirdParty/TraceStreamer/windows-x86_64/manifest.json"
SELF_TEST_SHA256 = "eb196eeb30c6b959c23d5e18d159ec946ba664ee8d9bc6f1acc32947b4ff5cfe"
IDENTITY_KEYS = ["name", "reportedVersion", "binarySHA256", "upstreamRepository", "upstreamRevision",
                 "architecture", "adapterVersion", "buildRecipeVersion"]


def digest(path):
    hasher = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            hasher.update(block)
    return hasher.hexdigest()


def cargo(*args):
    return subprocess.check_output([sys.executable, str(ROOT / "scripts/run-cargo.py"), *args], cwd=ROOT)


def stage(output, parser, namespace, release):
    if sys.platform != "win32" or platform.machine().lower() not in ("amd64", "x86_64"):
        raise RuntimeError("native Windows x64 required")
    output = Path(output)
    if not output.is_absolute() or output.exists():
        raise RuntimeError("candidate destination must be absolute and absent")
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    if digest(parser) != manifest["binarySHA256"]:
        raise RuntimeError("parser SHA-256 differs from the committed Windows manifest")
    profile = ["--release"] if release else []
    cargo("build", *profile, "-p", "arktrace-cli", "--bin", "arktrace", "--features", "development-resources")
    cargo("build", *profile, "-p", "arktrace-platform", "--bin", "arktrace-host-process")
    target = Path(json.loads(cargo("metadata", "--format-version", "1", "--no-deps"))["target_directory"])
    built = target / ("release" if release else "debug")
    helpers = output / "resources/Helpers"
    runtime_dir = output / "resources/ArkTraceRust"
    for directory in (helpers, runtime_dir):
        directory.mkdir(parents=True)
    shutil.copyfile(built / "arktrace.exe", output / "arktrace.exe")
    shutil.copyfile(built / "arktrace-host-process.exe", helpers / "arktrace-host-process.exe")
    shutil.copyfile(parser, helpers / "trace_streamer.exe")
    # doctor --self-test trace; the CLI pins its whole SHA-256.
    self_test = ROOT / "Fixtures/traces/zlib.htrace"
    if digest(self_test) != SELF_TEST_SHA256:
        raise RuntimeError("self-test trace differs from the pinned fixture")
    shutil.copyfile(self_test, output / "resources/zlib.htrace")
    stage_attribution(ROOT, output / 'resources/licenses')
    identity = {key: manifest[key] for key in IDENTITY_KEYS}
    # The manifest names the file; the identity carries the logical parser name.
    identity["name"] = "trace_streamer"
    runtime = {"formatVersion": 1, "productVersion": "0.1.0", "architecture": "x86_64", "development": True,
               "helperSHA256": digest(helpers / "arktrace-host-process.exe"),
               "unsignedParserSHA256": manifest["binarySHA256"], "parser": identity,
               "maximumSourceBytes": 1024 * 1024 * 1024, "maximumDatabaseBytes": 4 * 1024 * 1024 * 1024,
               "storageNamespace": namespace}
    (runtime_dir / "runtime.json").write_text(json.dumps(runtime, sort_keys=True) + "\n", encoding="utf-8")
    return {"developmentResources": True, "productionSigned": False, "readyAcceptance": False,
            "executableSHA256": digest(output / "arktrace.exe"),
            "helperSHA256": runtime["helperSHA256"],
            "parserSHA256": digest(helpers / "trace_streamer.exe"),
            "candidate": str(output)}


def main():
    arguments = argparse.ArgumentParser(description=__doc__)
    arguments.add_argument("--output", type=Path, required=True)
    arguments.add_argument("--parser", type=Path, required=True)
    arguments.add_argument("--namespace", default="com.arktrace.ArkTrace.rust-migration")
    arguments.add_argument("--debug", action="store_true")
    options = arguments.parse_args()
    print(json.dumps(stage(options.output, options.parser, options.namespace, not options.debug), sort_keys=True))


if __name__ == "__main__":
    main()
