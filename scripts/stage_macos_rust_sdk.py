#!/usr/bin/env python3
"""Verify and stage an explicit immutable SDK artifact in a cache-owned package."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verified_receipt(artifact, fixtures):
    require(artifact.is_absolute() and artifact.name == "CArkTrace.xcframework", "explicit absolute XCFramework required")
    require(not artifact.is_symlink() and artifact.is_dir(), "XCFramework must be a directory, not a link")
    receipt_path = artifact.parent / "receipt.json"
    require(not receipt_path.is_symlink() and receipt_path.is_file(), "regular receipt required")
    receipt = json.loads(receipt_path.read_text())
    require(receipt["abiVersion"] == 1 and receipt["contractSHA256"] == (ROOT / "contracts/ffi-v1.sha256").read_text().strip(), "ABI or contract digest mismatch")
    require(receipt["developmentFixtures"] is fixtures and receipt["deploymentTarget"] == "26.0", "artifact configuration mismatch")
    require(receipt["rust"].startswith("rustc 1.99.0 ") and receipt["xcode"].startswith("Xcode 27."), "toolchain pin mismatch")
    wanted = set()
    for entry in receipt["files"]:
        relative = PurePosixPath(entry["relativePath"])
        require(not relative.is_absolute() and ".." not in relative.parts and relative.parts[0] == artifact.name, "receipt path escapes artifact")
        require(str(relative) not in wanted, "duplicate receipt path")
        wanted.add(str(relative))
        path = artifact.parent / relative
        require(path.is_file() and not any(p.is_symlink() for p in (path, *path.parents) if p != artifact.parent.parent), "receipt file must be regular")
        data = path.read_bytes()
        require(len(data) == entry["byteCount"] and hashlib.sha256(data).hexdigest() == entry["sha256"], "artifact bytes differ from receipt")
    actual = set()
    for path in artifact.rglob("*"):
        require(not path.is_symlink(), "artifact links are prohibited")
        if path.is_file():
            actual.add(path.relative_to(artifact.parent).as_posix())
        else:
            require(path.is_dir(), "artifact special files are prohibited")
    require(actual == wanted, "artifact membership differs from receipt")
    libraries = plistlib.loads((artifact / "Info.plist").read_bytes())["AvailableLibraries"]
    require(len(libraries) == 1 and libraries[0]["SupportedArchitectures"] == ["arm64"] and libraries[0]["SupportedPlatform"] == "macos", "native macOS arm64 slice required")
    library = libraries[0]
    for field in ("LibraryIdentifier", "LibraryPath", "HeadersPath"):
        relative = PurePosixPath(library[field])
        require(bool(relative.parts) and not relative.is_absolute() and ".." not in relative.parts, "slice path escapes artifact")
    folder = artifact / library["LibraryIdentifier"]
    require(hashlib.sha256((folder / library["LibraryPath"]).read_bytes()).hexdigest() == receipt["library"]["sha256"], "static library identity mismatch")
    for name in ("arktrace_ffi.h", "module.modulemap"):
        require((folder / library["HeadersPath"] / name).read_bytes() == (ROOT / "bindings/c" / name).read_bytes(), "generated headers differ from source contract")
    # Temporary construction paths are not part of this identity. Older local
    # receipts can carry those diagnostic fields; only relative pinned files
    # are authoritative.
    identity = hashlib.sha256(json.dumps({"files": sorted([{key: entry[key] for key in ("relativePath", "byteCount", "sha256")} for entry in receipt["files"]], key=lambda e: e["relativePath"]), "fixtures": fixtures}, sort_keys=True).encode()).hexdigest()
    return receipt, identity


def stage(artifact, workspace, fixtures):
    receipt, identity = verified_receipt(artifact, fixtures)
    require(workspace.is_absolute() and workspace.is_dir() and not workspace.is_symlink() and not workspace.resolve().is_relative_to(ROOT), "cache-owned external package required")
    managed = workspace / ".arktrace-native"
    require(not managed.is_symlink(), "native staging root must not be a link")
    managed.mkdir(mode=0o700, exist_ok=True)
    destination = managed / identity
    require(not destination.is_symlink(), "native staging destination must not be a link")
    if destination.exists():
        verified_receipt(destination / artifact.name, fixtures)
    else:
        with tempfile.TemporaryDirectory(prefix="stage-", dir=managed) as temporary:
            temporary = Path(temporary)
            shutil.copytree(artifact, temporary / artifact.name)
            (temporary / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
            verified_receipt(temporary / artifact.name, fixtures)
            os.rename(temporary, destination)
    return (destination / artifact.name).relative_to(workspace).as_posix()


if __name__ == "__main__":
    try:
        print(stage(Path(sys.argv[1]), Path(sys.argv[2]), os.environ.get("ARKTRACE_RUST_SDK_FIXTURES") == "1"))
    except (ValueError, KeyError, OSError, IndexError) as error:
        raise SystemExit(f"native SDK staging: {error}") from error
