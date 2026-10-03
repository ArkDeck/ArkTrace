#!/usr/bin/env python3
"""Build a private ad-hoc Rust CLI bundle for native migration verification.

This is a development candidate, not a signed/notarized distribution gate.
Default Rust binaries still require Developer ID; only the explicit build
feature accepts this candidate's ad-hoc seal and fixed development parser.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

from test_macos_parser_process import ROOT, cargo, digest


def build_app(output, *, development, namespace):
    if sys.platform != "darwin" or os.uname().machine != "arm64":
        raise RuntimeError("native macOS arm64 required")
    output = Path(output)
    if not output.is_absolute() or output.exists():
        raise RuntimeError("candidate destination must be absolute and absent")
    parser = ROOT / "ThirdParty/TraceStreamer/macx/trace_streamer"
    manifest = json.loads((parser.parent / "manifest.json").read_text())
    assert digest(parser) == manifest["binarySHA256"]
    args = ["build", "-p", "arktrace-cli", "--bin", "arktrace"]
    if development:
        args.extend(["--features", "development-resources"])
    cargo(*args)
    target = Path(json.loads(cargo("metadata", "--format-version", "1", "--no-deps"))["target_directory"])
    # Freeze both complete artifacts before any later Cargo feature rebuild.
    output.mkdir(mode=0o700)
    contents = output / "Contents"
    for directory in [contents / "MacOS", contents / "Helpers", contents / "Resources/ArkTraceRust"]:
        directory.mkdir(parents=True, mode=0o755)
    executable = contents / "MacOS/arktrace"
    shutil.copyfile(target / "debug/arktrace", executable)
    executable.chmod(0o755)
    cargo("build", "-p", "arktrace-platform", "--bin", "arktrace-host-process")
    helper = contents / "Helpers/arktrace-host-process"
    shutil.copyfile(target / "debug/arktrace-host-process", helper)
    helper.chmod(0o755)
    shutil.copyfile(parser, contents / "Helpers/trace_streamer")
    (contents / "Helpers/trace_streamer").chmod(0o755)
    identity = {key: manifest[key] for key in ["name", "reportedVersion", "binarySHA256", "upstreamRepository", "upstreamRevision", "architecture", "adapterVersion", "buildRecipeVersion"]}
    runtime = {"formatVersion": 1, "productVersion": "0.1.0", "architecture": "arm64", "development": development,
               "helperSHA256": digest(helper), "unsignedParserSHA256": manifest["binarySHA256"], "parser": identity,
               "maximumSourceBytes": 1024 * 1024 * 1024, "maximumDatabaseBytes": 4 * 1024 * 1024 * 1024,
               "storageNamespace": namespace}
    (contents / "Resources/ArkTraceRust/runtime.json").write_text(json.dumps(runtime, sort_keys=True) + "\n")
    info = {"CFBundleIdentifier": "com.arktrace.ArkTrace.CLI", "CFBundleName": "ArkTrace Rust CLI", "CFBundleExecutable": "arktrace",
            "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "0.1.0", "LSMinimumSystemVersion": "26.0"}
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", info["CFBundleIdentifier"], str(output)], check=True, capture_output=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(output)], check=True, capture_output=True)
    for artifact in [executable,helper]:
        load_commands=subprocess.check_output(["/usr/bin/otool","-l",str(artifact)],text=True)
        assert "minos 26.0\n" in load_commands and "sdk 27." in load_commands
        assert subprocess.check_output(["/usr/bin/lipo","-archs",str(artifact)],text=True).strip()=="arm64"
    return {"developmentResources": development, "readyAcceptance": False, "productionSigned": False,
            "minimumSystemVersion":"26.0", "sdkMajorVersion":27,
            "executableSHA256": digest(executable), "helperSHA256": digest(helper), "parserSHA256": digest(contents / "Helpers/trace_streamer"),
            "bundle": output, "executable": executable, "runtime": runtime}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--development", action="store_true", required=True)
    args = parser.parse_args()
    report = build_app(args.output, development=True, namespace="com.arktrace.ArkTrace.rust-migration")
    print(json.dumps({key: str(value) if isinstance(value, Path) else value for key, value in report.items()}, sort_keys=True))


if __name__ == "__main__":
    main()
