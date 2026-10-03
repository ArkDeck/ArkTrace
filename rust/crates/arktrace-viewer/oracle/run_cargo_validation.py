#!/usr/bin/env python3
"""Use the pinned stable runner without modifying the snapshot's root/lock.

Creates a cache-owned source mirror with private Git metadata. Adding a crate
requires a Cargo.lock package entry, generated only in this validation mirror.
The integration coordinator must regenerate the real shared lock separately.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[4]
CACHE = Path(os.environ.get("ARKTRACE_CARGO_CACHE_ROOT", "/private/tmp/arktrace-parallel-viewer-cargo"))


def main():
    if not CACHE.is_absolute() or CACHE.resolve().is_relative_to(ROOT):
        raise SystemExit("cargo cache must be absolute and outside source")
    source = CACHE / "validation-source"
    source.mkdir(parents=True, exist_ok=True)
    for directory in ("rust", "contracts", "scripts"):
        shutil.copytree(ROOT / directory, source / directory, dirs_exist_ok=True,
            ignore=shutil.ignore_patterns("target", "__pycache__"))
    manifest = "ThirdParty/TraceStreamer/macx/manifest.json"
    (source / manifest).parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / manifest, source / manifest)
    subprocess.run(["git", "init", "--quiet"], cwd=source, check=True)
    environment = os.environ.copy()
    environment["ARKTRACE_CARGO_CACHE_ROOT"] = str(CACHE)
    environment["CARGO_NET_OFFLINE"] = "true"
    environment.setdefault("ARKTRACE_CARGO_HOME", str(CACHE / "dependencies"))
    # Copy the pinned already-downloaded registry once; never use another
    # session's target directory or acquire its runner/native probe lock.
    registry = CACHE / "dependencies/registry"
    if not registry.exists():
        existing = Path.home() / ".cargo/registry"
        if existing.exists():
            shutil.copytree(existing, registry)
    seed = os.environ.get("ARKTRACE_VIEWER_SEED_CARGO_HOME")
    if seed:
        shutil.copytree(Path(seed) / "registry", registry, dirs_exist_ok=True)
    runner = [sys.executable, "scripts/run-cargo.py"]
    result = subprocess.run(runner + ["generate-lockfile", "--offline"], cwd=source, env=environment)
    if result.returncode: return result.returncode
    args = sys.argv[1:] or ["test", "-p", "arktrace-viewer", "--offline"]
    if args == ["verify"]:
        return subprocess.run([sys.executable, "scripts/verify_rust_workspace.py"], cwd=source, env=environment).returncode
    result = subprocess.run(runner + args, cwd=source, env=environment)
    if result.returncode == 0 and args[0] == "fmt" and "--check" not in args:
        for path in (source / "rust/crates/arktrace-viewer").rglob("*.rs"):
            shutil.copyfile(path, ROOT / path.relative_to(source))
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
