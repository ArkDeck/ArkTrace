#!/usr/bin/env python3
"""Prepare the mandatory native SDK and fixed bundled tools for an App build.

Unsigned preparation is compile-only. Supplying a Developer ID identity signs
both real tools and writes their actual publisher and post-signing byte pins.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from build_macos_rust_sdk import build
from stage_macos_rust_sdk import stage, verified_receipt

ROOT = Path(__file__).resolve().parent.parent
PREFIX = "com.arktrace.ArkTrace"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def regular(path):
    require(path.is_file() and not any(p.is_symlink() for p in (path, *path.parents)), "physical regular input required")


def signature(path, identifier, team):
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(path)], check=True, stdout=subprocess.DEVNULL)
    result = subprocess.run(["/usr/bin/codesign", "-dv", "--verbose=4", str(path)], check=True, capture_output=True, text=True)
    lines = result.stderr.splitlines()
    require("Identifier=" + identifier in lines and "TeamIdentifier=" + team in lines, "signed tool publisher mismatch")
    require(any("(runtime)" in line for line in lines if line.startswith("CodeDirectory ")), "signed tool hardened runtime required")


def build_helper():
    # Use the runner's existing owner/mirror/lock policy and capture while its
    # lock is still held, rather than guessing a cache path after a subprocess.
    spec = importlib.util.spec_from_file_location("arktrace_app_cargo_runner", ROOT / "scripts/run-cargo.py")
    runner = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = runner
    spec.loader.exec_module(runner)
    options = ["-p", "arktrace-platform", "--release", "--bin", "arktrace-host-process"]
    with runner.managed_workspace("build", options) as workspace:
        subprocess.run([workspace.cargo, "+" + workspace.pin, "build", "--locked", *options],
                       cwd=workspace.root / "rust", env=workspace.environment, check=True, stdout=subprocess.DEVNULL)
        helper = workspace.cache / "target/release/arktrace-host-process"
        regular(helper)
        return helper.read_bytes()


def prepare(workspace, sdk=None, signing_identity=None):
    workspace = workspace.absolute()
    require(workspace.is_dir() and not workspace.is_symlink(), "physical workspace required")
    if sdk is None:
        sdk, _ = build(False)
    sdk = sdk.absolute()
    sdk_receipt, _ = verified_receipt(sdk, False)
    helper_bytes = build_helper()
    parser = ROOT / "ThirdParty/TraceStreamer/macx/trace_streamer"
    parser_manifest = ROOT / "ThirdParty/TraceStreamer/macx/manifest.json"
    for path in (parser, parser_manifest):
        regular(path)
    original_manifest = json.loads(parser_manifest.read_text())
    require(sha(parser) == original_manifest["binarySHA256"], "locked parser identity mismatch")
    publisher = None
    certificate = None
    if signing_identity:
        identities = subprocess.check_output(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"], text=True)
        matches = re.findall(r'([0-9A-Fa-f]{40}) "' + re.escape(signing_identity) + r'"', identities)
        require(len(matches) == 1 and signing_identity.startswith("Developer ID Application: "), "unique Developer ID identity required")
        team = re.search(r"\(([A-Z0-9]{10})\)$", signing_identity)
        require(team is not None, "Developer ID team unavailable")
        certificate = matches[0].upper()
        publisher = {"teamIdentifier": team[1], "helperCodeIdentifier": PREFIX + ".host-process", "parserCodeIdentifier": PREFIX + ".trace-streamer"}
    inputs = {"contractSHA256": sdk_receipt["contractSHA256"], "unsignedHelperSHA256": hashlib.sha256(helper_bytes).hexdigest(),
              "unsignedParserSHA256": sha(parser), "parserManifestSHA256": sha(parser_manifest),
              "publisher": publisher, "certificateSHA1": certificate, "signingPolicy": "developer-id-runtime-timestamp" if publisher else "unsigned-compile-only"}
    key = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()
    artifacts = Path(os.environ.get("ARKTRACE_NATIVE_APP_INPUT_CACHE_ROOT", "/private/tmp/arktrace-native-app-inputs"))
    require(artifacts.is_absolute() and not artifacts.is_symlink() and not artifacts.resolve().is_relative_to(ROOT), "external input artifact cache required")
    artifacts.mkdir(mode=0o700, parents=True, exist_ok=True)
    artifact = artifacts / key
    if not artifact.exists():
        with tempfile.TemporaryDirectory(prefix="app-inputs-", dir=artifacts) as directory:
            temporary = Path(directory)
            for folder in ("Helpers", "TraceStreamer", "ArkTraceRuntime"):
                (temporary / folder).mkdir(mode=0o700)
            tools = [(helper_bytes, temporary / "Helpers/arktrace-host-process", PREFIX + ".host-process"),
                     (parser.read_bytes(), temporary / "Helpers/trace_streamer", PREFIX + ".trace-streamer")]
            for source, target, identifier in tools:
                target.write_bytes(source)
                target.chmod(0o700)
                if publisher:
                    subprocess.run(["/usr/bin/codesign", "--force", "--sign", certificate, "--identifier", identifier,
                                    "--options", "runtime", "--timestamp", str(target)], check=True, stdout=subprocess.DEVNULL)
                    signature(target, identifier, publisher["teamIdentifier"])
                target.chmod(0o555)
            manifest = dict(original_manifest)
            manifest["binarySHA256"] = sha(temporary / "Helpers/trace_streamer")
            (temporary / "TraceStreamer/manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
            runtime = {"formatVersion": 1, "contractSHA256": inputs["contractSHA256"],
                       "helperSHA256": sha(temporary / "Helpers/arktrace-host-process"), "publisher": publisher}
            (temporary / "ArkTraceRuntime/manifest.json").write_text(json.dumps(runtime, indent=2) + "\n")
            files = []
            for path in sorted(temporary.rglob("*")):
                if path.is_file():
                    if path.suffix == ".json":
                        path.chmod(0o444)
                    files.append({"path": path.relative_to(temporary).as_posix(), "byteCount": path.stat().st_size,
                                  "mode": path.stat().st_mode & 0o777, "sha256": sha(path)})
            receipt = {"formatVersion": 1, "inputs": inputs, "runtimeUsable": publisher is not None, "releaseAcceptance": False, "files": files}
            (temporary / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
            (temporary / "receipt.json").chmod(0o444)
            temporary.rename(artifact)
    validate_inputs(artifact)
    require(json.loads((artifact / "receipt.json").read_text())["inputs"] == inputs, "input artifact identity mismatch")
    relative_sdk = stage(sdk, workspace, False)
    target = workspace / ".arktrace-native/AppInputs"
    require(not target.is_symlink(), "staged inputs must not be a link")
    if target.exists():
        validate_inputs(target)
        if (target / "receipt.json").read_bytes() != (artifact / "receipt.json").read_bytes():
            shutil.rmtree(target)
    if not target.exists():
        shutil.copytree(artifact, target)
    validate_inputs(target)
    return {"relativeSDK": relative_sdk, "inputs": str(artifact), "stagedInputs": str(target),
            "runtimeUsable": publisher is not None, "releaseAcceptance": False}


def validate_inputs(directory):
    regular(directory / "receipt.json")
    receipt = json.loads((directory / "receipt.json").read_text())
    require(receipt["formatVersion"] == 1, "input receipt version mismatch")
    expected = {"Helpers/arktrace-host-process", "Helpers/trace_streamer", "TraceStreamer/manifest.json", "ArkTraceRuntime/manifest.json"}
    require({row["path"] for row in receipt["files"]} == expected and len(receipt["files"]) == 4, "input membership mismatch")
    actual = set()
    for path in directory.rglob("*"):
        require(not path.is_symlink(), "input links forbidden")
        if path.is_file():
            actual.add(path.relative_to(directory).as_posix())
        else:
            require(path.is_dir(), "input special object forbidden")
    require(actual == expected | {"receipt.json"}, "extra input member")
    for row in receipt["files"]:
        path = directory / row["path"]
        regular(path)
        require(path.stat().st_size == row["byteCount"] and path.stat().st_mode & 0o777 == row["mode"] and sha(path) == row["sha256"], "input bytes or mode drift")
    require(type(receipt["runtimeUsable"]) is bool, "explicit runtime usability required")
    runtime = json.loads((directory / "ArkTraceRuntime/manifest.json").read_text())
    require(runtime == {"formatVersion": 1, "contractSHA256": (ROOT / "contracts/ffi-v1.sha256").read_text().strip(),
                        "helperSHA256": sha(directory / "Helpers/arktrace-host-process"),
                        "publisher": receipt["inputs"]["publisher"]}, "runtime manifest provenance mismatch")
    parser = json.loads((directory / "TraceStreamer/manifest.json").read_text())
    require(parser["binarySHA256"] == sha(directory / "Helpers/trace_streamer"), "parser manifest provenance mismatch")
    require(receipt["runtimeUsable"] == (receipt["inputs"]["publisher"] is not None), "unsigned inputs cannot be runtime usable")
    if receipt["runtimeUsable"]:
        publisher = receipt["inputs"]["publisher"]
        signature(directory / "Helpers/arktrace-host-process", publisher["helperCodeIdentifier"], publisher["teamIdentifier"])
        signature(directory / "Helpers/trace_streamer", publisher["parserCodeIdentifier"], publisher["teamIdentifier"])
    return receipt


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--sdk", type=Path)
    parser.add_argument("--signing-identity")
    args = parser.parse_args()
    try:
        print(json.dumps(prepare(args.workspace, args.sdk, args.signing_identity), indent=2))
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit("native App preparation: " + str(error))
