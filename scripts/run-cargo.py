#!/usr/bin/env python3
"""Run the pinned Rust workspace using a serialized, stable external cache."""
import contextlib
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import time
import tomllib

ROOT = Path(__file__).resolve().parent.parent
COMMANDS = {"build", "check", "test", "clippy", "fmt", "metadata", "generate-lockfile", "run"}


def fail(message):
    raise SystemExit(f"run-cargo: {message}")


@contextlib.contextmanager
def cache_lock(path):
    with path.open("a+b") as lock:
        if os.name == "nt":
            import msvcrt
            lock.seek(0)
            lock.write(b"\0")
            lock.flush()
            deadline = time.monotonic() + 120
            while True:
                lock.seek(0)
                try:
                    msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
                    break
                except OSError:
                    if time.monotonic() >= deadline:
                        fail("cache lock deadline exceeded")
                    time.sleep(0.1)
            try:
                yield
            finally:
                lock.seek(0)
                msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            import fcntl
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)


def sync_sources(workspace):
    paths = subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "rust", "contracts", "ThirdParty/TraceStreamer/macx/manifest.json"],
        cwd=ROOT,
    ).split(b"\0")
    wanted = set()
    for raw in paths:
        if not raw:
            continue
        relative = Path(os.fsdecode(raw))
        source = ROOT / relative
        if not source.exists():
            continue
        if source.is_symlink() or not source.is_file():
            fail("source mirror accepts regular files only")
        wanted.add(relative)
        destination = workspace / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        if not destination.is_file() or source.read_bytes() != destination.read_bytes():
            shutil.copyfile(source, destination)
    for base in (workspace / "rust", workspace / "contracts"):
        if base.exists():
            for path in base.rglob("*"):
                if path.is_file() and path.relative_to(workspace) not in wanted:
                    path.unlink()
    return wanted


def main():
    arguments = sys.argv[1:]
    if not arguments or arguments[0] in {"-h", "--help"}:
        print("usage: python3 scripts/run-cargo.py {build|test|check|clippy|fmt|metadata|generate-lockfile|run} [cargo options]")
        print("ARKTRACE_CARGO_CACHE_ROOT: absolute external cache; ARKTRACE_CARGO_HOME: optional external dependency cache")
        return 0
    command, *options = arguments
    if command not in COMMANDS:
        fail("unsupported cargo command")
    if any(option.split("=", 1)[0] in {"--manifest-path", "--target-dir", "--config", "--lockfile-path"} for option in options):
        fail("manifest, target, config and lockfile paths are managed by this runner")
    # The selected rusqlite feature graph is a bundled, frozen SQLite build.
    # libsqlite3-sys otherwise lets these ambient variables select another
    # library/source or silently change semantic limits.
    sqlite_overrides = {
        "LIBSQLITE3_SYS_USE_PKG_CONFIG", "LIBSQLITE3_SYS_BUNDLING", "LIBSQLITE3_FLAGS",
        "SQLITE3_LIB_DIR", "SQLITE3_INCLUDE_DIR", "SQLITE3_STATIC",
        "SQLITE_MAX_VARIABLE_NUMBER", "SQLITE_MAX_EXPR_DEPTH", "SQLITE_MAX_COLUMN",
    }
    if any(name in os.environ for name in sqlite_overrides):
        fail("bundled SQLite build overrides are prohibited")
    pin = tomllib.loads((ROOT / "rust/rust-toolchain.toml").read_text())["toolchain"]["channel"]
    rustc = shutil.which("rustc")
    cargo = shutil.which("cargo")
    if not rustc or not cargo:
        fail(f"rustup with Rust {pin} is required")
    version = subprocess.run([rustc, f"+{pin}", "--version"], capture_output=True, text=True)
    if version.returncode or not version.stdout.startswith(f"rustc {pin} "):
        fail(f"install pinned Rust {pin} with rustup; no floating toolchain fallback")
    host = {("Darwin", "arm64"): "macos-arm64", ("Windows", "AMD64"): "windows-x64"}.get(
        (platform.system(), platform.machine()), "unsupported"
    )
    expected = os.environ.get("ARKTRACE_EXPECT_NATIVE_HOST", host)
    if expected != host:
        fail(f"native runner mismatch: expected {expected}, actual {host}")
    if host == "macos-arm64":
        xcode = subprocess.run(["/usr/bin/xcodebuild", "-version"], capture_output=True, text=True)
        if xcode.returncode or not xcode.stdout.startswith("Xcode 27."):
            fail("Xcode 27 is required; no floating SDK fallback")
        if os.environ.get("MACOSX_DEPLOYMENT_TARGET", "26.0") != "26.0":
            fail("macOS deployment target is fixed at 26.0")
    default = Path.home() / "Library/Caches/com.arkdeck.ArkTrace/Cargo/Shared" if sys.platform == "darwin" else Path.home() / ".cache/arktrace/cargo"
    cache = Path(os.environ.get("ARKTRACE_CARGO_CACHE_ROOT", default))
    if not cache.is_absolute() or cache.resolve().is_relative_to(ROOT):
        fail("cache root must be absolute and outside the worktree")
    cache.mkdir(parents=True, exist_ok=True)
    dependency = Path(os.environ.get("ARKTRACE_CARGO_HOME", cache / "dependencies"))
    if not dependency.is_absolute() or dependency.resolve().is_relative_to(ROOT):
        fail("dependency cache must be absolute and outside the worktree")
    dependency.mkdir(parents=True, exist_ok=True)
    workspace = cache / "workspace"
    workspace.mkdir(exist_ok=True)
    environment = os.environ.copy()
    environment.update(CARGO_HOME=str(dependency), CARGO_TARGET_DIR=str(cache / "target"), ARKTRACE_EXPECT_NATIVE_HOST=host)
    environment["LIBSQLITE3_FLAGS"] = "-DSQLITE_ENABLE_FILESTAT=1"
    capture = os.environ.get("ARKTRACE_CARGO_CAPTURE_STATICLIB")
    if capture:
        capture = Path(capture)
        permitted = [["-p", "arktrace-ffi", "--release"], ["-p", "arktrace-ffi", "--release", "--features", "process-fixtures"]]
        if host != "macos-arm64" or command != "build" or options not in permitted:
            fail("staticlib capture requires an explicit native SDK release build")
        if not capture.is_absolute() or capture.resolve().is_relative_to(ROOT) or capture.exists() or capture.is_symlink():
            fail("staticlib capture requires a fresh absolute external file")
    if host == "macos-arm64":
        environment["MACOSX_DEPLOYMENT_TARGET"] = "26.0"
    with cache_lock(cache / "runner.lock"):
        sources = sync_sources(workspace)
        invocation = [cargo, f"+{pin}", command]
        if command not in {"fmt", "generate-lockfile"}:
            invocation.append("--locked")
        invocation.extend(options)
        result = subprocess.run(invocation, cwd=workspace / "rust", env=environment)
        if result.returncode == 0 and capture:
            # Keep the build lock through the copy: another invocation cannot
            # replace this output with a different feature set in between.
            shutil.copyfile(cache / "target/release/libarktrace_ffi.a", capture)
        if result.returncode == 0 and command == "generate-lockfile":
            shutil.copyfile(workspace / "rust/Cargo.lock", ROOT / "rust/Cargo.lock")
        if result.returncode == 0 and command == "fmt" and "--check" not in options:
            for relative in sources:
                if relative.suffix == ".rs":
                    source = workspace / relative
                    destination = ROOT / relative
                    if source.read_bytes() != destination.read_bytes():
                        shutil.copyfile(source, destination)
        return result.returncode


if __name__ == "__main__":
    sys.exit(main())
