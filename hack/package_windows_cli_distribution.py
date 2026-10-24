#!/usr/bin/env python3
"""Package the Windows x64 ArkTrace CLI distribution (AT-RUST-016).

    python hack/package_windows_cli_distribution.py --output <new absolute directory>
        --parser <trace_streamer.exe rebuilt from the committed Windows recipe>
        [--publisher <Authenticode publisher> --certificate-thumbprint <SHA-1 in CurrentUser\\My>]
        [--timestamp-url <RFC 3161 URL>] [--development-pinned] [--allow-dirty]

Policies (ArkDeck TASK-XPA-021 ruling (b)):
- authenticode-publisher (default): a release build whose CLI pins the publisher
  at build time (ARKTRACE_WINDOWS_PUBLISHER); arktrace.exe, the helper and the
  parser are Authenticode-signed with the given certificate (`/fd SHA256`), and
  every file is also pinned by SHA-256/byte count. A development publisher (the
  host-trusted `ArkDeck Development Daemon (host-trusted only)` certificate) is a
  development package, not a release; the production publisher is a release input.
- development-pinned: a `development-resources` build; images are unsigned and
  pinned by SHA-256 only.

The unsigned bytes of every image are recorded separately from the signed
identity. Output: <output>/ArkTraceCLI-<version>-windows-x86_64/ (extracted tree)
and <output>/arktrace-<version>-windows-x86_64.zip, then both are verified with
verify_windows_cli_distribution.py. Binaries and archives are never committed.
"""
import argparse
import importlib.util
import json
import os
import platform
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = Path(__file__).resolve().parent


def load(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


verifier = load("verify_windows_cli_distribution")
# One module instance, so one ContractError class.
contract = verifier.contract
PARSER_MANIFEST = ROOT / "third_party/trace-streamer/windows-x86_64/manifest.json"
SIGNTOOL = Path(r"C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe")
IDENTITY_KEYS = ["name", "reportedVersion", "binarySHA256", "upstreamRepository", "upstreamRevision",
                 "architecture", "adapterVersion", "buildRecipeVersion"]


def fail(message):
    raise SystemExit("package refused: " + message)


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT).decode().strip()


def cargo(environment, *args):
    subprocess.run([sys.executable, str(ROOT / "hack/run-cargo.py"), *args], cwd=ROOT, check=True,
                   env=environment, stdout=sys.stderr)
    return json.loads(subprocess.check_output(
        [sys.executable, str(ROOT / "hack/run-cargo.py"), "metadata", "--format-version", "1", "--no-deps"],
        cwd=ROOT, env=environment))["target_directory"]


def sign(path, thumbprint, timestamp_url):
    command = [str(SIGNTOOL), "sign", "/sha1", thumbprint, "/s", "My", "/fd", "SHA256"]
    if timestamp_url:
        command += ["/tr", timestamp_url, "/td", "SHA256"]
    result = subprocess.run(command + [str(path)], capture_output=True, text=True)
    if result.returncode != 0:
        fail("signtool sign failed for " + path.name)
    result = subprocess.run([str(SIGNTOOL), "verify", "/pa", str(path)], capture_output=True, text=True)
    if result.returncode != 0:
        fail("signtool verify /pa failed for " + path.name)


def facts(path):
    return path.stat().st_size, contract.sha256_file(path)


def package(options):
    if sys.platform != "win32" or platform.machine().lower() not in ("amd64", "x86_64"):
        fail("native Windows x64 required")
    output = options.output
    if not output.is_absolute() or output.exists():
        fail("output must be an absolute, absent directory")
    development = options.development_pinned
    if not development and not (options.publisher and options.certificate_thumbprint):
        fail("authenticode-publisher needs --publisher and --certificate-thumbprint")
    if not development and not SIGNTOOL.is_file():
        fail("signtool unavailable")
    revision = git("rev-parse", "HEAD")
    dirty = bool(git("status", "--porcelain", "--untracked-files=no"))
    if dirty and not options.allow_dirty:
        fail("source tree has uncommitted changes")
    parser_manifest = json.loads(PARSER_MANIFEST.read_text(encoding="utf-8"))
    if contract.sha256_file(options.parser) != parser_manifest["binarySHA256"]:
        fail("parser differs from the committed Windows recipe manifest")

    environment = dict(os.environ)
    environment.pop("ARKTRACE_WINDOWS_PUBLISHER", None)
    features = []
    if development:
        features = ["--features", "development-resources"]
    else:
        environment["ARKTRACE_WINDOWS_PUBLISHER"] = options.publisher
    cargo(environment, "build", "--release", "-p", "arktrace-cli", "--bin", "arktrace", *features)
    target = Path(cargo(environment, "build", "--release", "-p", "arktrace-platform", "--bin",
                        "arktrace-host-process"))
    built = target / "release"

    name = "ArkTraceCLI-{}-windows-x86_64".format(contract.PRODUCT["version"])
    output.mkdir(parents=True)
    tree = output / name
    layout = contract.LAYOUT
    for relative in (layout["helperExecutable"], layout["parserManifest"], layout["runtimeManifest"],
                     layout["licenseDirectory"] + "/LICENSES/x", layout["licenseDirectory"] + "/LICENSES-windows/x"):
        (tree / relative).parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(built / "arktrace.exe", tree / layout["executable"])
    shutil.copyfile(built / "arktrace-host-process.exe", tree / layout["helperExecutable"])
    shutil.copyfile(options.parser, tree / layout["parserExecutable"])
    shutil.copyfile(PARSER_MANIFEST, tree / layout["parserManifest"])
    self_test = ROOT / "test/fixtures/traces/zlib.htrace"
    if contract.sha256_file(self_test) != contract.SELF_TEST_SHA256:
        fail("self-test fixture drift")
    shutil.copyfile(self_test, tree / layout["selfTestFixture"])
    licenses = tree / layout["licenseDirectory"]
    contract.stage_attribution(ROOT, licenses)

    unsigned = {key: facts(tree / layout[key])[1] for key in ("executable", "helperExecutable", "parserExecutable")}
    if not development:
        for key in ("executable", "helperExecutable", "parserExecutable"):
            sign(tree / layout[key], options.certificate_thumbprint, options.timestamp_url)
    identity = {key: parser_manifest[key] for key in IDENTITY_KEYS}
    identity["name"] = "trace_streamer"
    identity["binarySHA256"] = facts(tree / layout["parserExecutable"])[1]
    runtime = {"formatVersion": 1, "productVersion": contract.PRODUCT["version"], "architecture": "x86_64",
               "development": development, "helperSHA256": facts(tree / layout["helperExecutable"])[1],
               "unsignedParserSHA256": parser_manifest["binarySHA256"], "parser": identity,
               "maximumSourceBytes": 1024 * 1024 * 1024, "maximumDatabaseBytes": 4 * 1024 * 1024 * 1024,
               "storageNamespace": contract.STORAGE_NAMESPACE}
    (tree / layout["runtimeManifest"]).write_bytes((json.dumps(runtime, sort_keys=True) + "\n").encode())

    measured = {}
    for relative, path in contract.walk_tree(tree):
        measured[relative] = facts(path)
    files = [{"path": p, "sha256": measured[p][1], "byteCount": measured[p][0]}
             for p in sorted(measured, key=lambda p: p.encode())]
    attribution = {}
    for key, relative in (("license", "LICENSE"), ("notice", "THIRD_PARTY_NOTICES.md"),
                          ("inventory", "license-inventory.json"),
                          ("windowsInventory", "windows-license-inventory.json"),
                          ("rustInventory", "rust/dependency-licenses.json")):
        path = layout["licenseDirectory"] + "/" + relative
        attribution[key] = path
        attribution[key + "SHA256"] = measured[path][1]
        attribution[key + "ByteCount"] = measured[path][0]
    attribution.update(licenseFileCount=contract.LICENSE_FILE_COUNT,
                       windowsLicenseFileCount=contract.WINDOWS_LICENSE_FILE_COUNT,
                       rustDependencyCount=contract.RUST_DEPENDENCY_COUNT,
                       rustLicenseFileCount=contract.RUST_LICENSE_FILE_COUNT,
                       selfTestFixtureSHA256=measured[layout["selfTestFixture"]][1],
                       selfTestFixtureByteCount=measured[layout["selfTestFixture"]][0])

    def image(key):
        return {"binarySHA256": measured[layout[key]][1], "byteCount": measured[layout[key]][0],
                "unsignedBinarySHA256": unsigned[key]}

    manifest = {
        "schema": contract.SCHEMA,
        "formatVersion": 1,
        "source": {"revision": revision, "dirty": dirty},
        "product": contract.PRODUCT,
        "layout": layout,
        "tool": image("executable"),
        "helper": image("helperExecutable"),
        "traceStreamer": {
            "unsignedBinarySHA256": parser_manifest["binarySHA256"],
            "binarySHA256": measured[layout["parserExecutable"]][1],
            "byteCount": measured[layout["parserExecutable"]][0],
            "manifestSHA256": measured[layout["parserManifest"]][1],
            "manifestByteCount": measured[layout["parserManifest"]][0],
            "reportedVersion": parser_manifest["reportedVersion"],
            "upstreamRevision": parser_manifest["upstreamRevision"],
            "buildRecipeVersion": parser_manifest["buildRecipeVersion"],
        },
        "provenance": contract.PROVENANCE,
        "signing": {"policy": "development-pinned" if development else "authenticode-publisher",
                    "publisher": None if development else options.publisher,
                    "timestamped": bool(options.timestamp_url) and not development},
        "integrity": {
            "treeDigest": contract.TREE_DIGEST,
            "treeSHA256": contract.tree_digest([(f["path"], f["byteCount"], f["sha256"]) for f in files],
                                               contract.EXECUTABLES),
            "fileCount": len(files),
            "executables": contract.EXECUTABLES,
            "files": files,
        },
        "attribution": attribution,
        "upgradePolicy": contract.UPGRADE_POLICY,
    }
    manifest_bytes = (json.dumps(manifest, indent=2) + "\n").encode()
    (tree / contract.MANIFEST_NAME).write_bytes(manifest_bytes)
    archive = output / "arktrace-{}-windows-x86_64.zip".format(contract.PRODUCT["version"])
    with zipfile.ZipFile(archive, "x", zipfile.ZIP_DEFLATED) as bundle:
        for relative, path in contract.walk_tree(tree):
            info = zipfile.ZipInfo(name + "/" + relative, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            bundle.writestr(info, path.read_bytes())
    tree_result = verifier.verify(tree)
    archive_result = verifier.verify(archive)
    return {
        "distribution": str(tree),
        "archive": str(archive),
        "archiveSHA256": contract.sha256_file(archive),
        "manifestSHA256": contract.sha256_file(tree / contract.MANIFEST_NAME),
        "treeSHA256": manifest["integrity"]["treeSHA256"],
        "signingPolicy": manifest["signing"]["policy"],
        "publisher": manifest["signing"]["publisher"],
        "unsigned": unsigned,
        "signed": {key: measured[layout[key]][1] for key in unsigned},
        "source": manifest["source"],
        "verifiedTree": tree_result["verified"],
        "verifiedArchive": archive_result["verified"],
        "signatures": tree_result["signatures"],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--parser", type=Path, required=True)
    parser.add_argument("--publisher")
    parser.add_argument("--certificate-thumbprint")
    parser.add_argument("--timestamp-url")
    parser.add_argument("--development-pinned", action="store_true")
    parser.add_argument("--allow-dirty", action="store_true")
    options = parser.parse_args()
    try:
        print(json.dumps(package(options), indent=2, sort_keys=True))
    except contract.ContractError as error:
        fail(str(error))


if __name__ == "__main__":
    main()
