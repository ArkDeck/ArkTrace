#!/usr/bin/env python3
"""Run the pinned Rust workspace using a serialized, stable external cache."""
import contextlib
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import sys
import tomllib
from dataclasses import dataclass
from cargo_cache import (STATE, cache_root, is_link, load_state, owner_id, register,
                         regular_file, runner_lock, source_identity, source_paths, within)

ROOT = Path(__file__).resolve().parent.parent
COMMANDS = {"build", "check", "test", "clippy", "fmt", "metadata", "generate-lockfile", "run"}


def fail(message):
    raise SystemExit(f"run-cargo: {message}")


def native_configuration(cwd, dependency):
    paths = [dependency / 'config', dependency / 'config.toml']
    for directory in (cwd, *cwd.parents):
        paths += [directory / '.cargo/config', directory / '.cargo/config.toml']
    for path in paths:
        if path.exists() or is_link(path):
            regular_file(path, path.parent.parent if path.parent.name == '.cargo' else dependency)
            if path.stat().st_size > 1024 * 1024:
                fail('Cargo configuration exceeds native validation limit')
            configuration = tomllib.loads(path.read_text())
            if 'target' in configuration.get('build', {}):
                fail('native host builds only; Cargo build.target configuration is prohibited')


def sync_sources(workspace, source_root=None):
    source_root = ROOT if source_root is None else source_root
    paths = source_paths(source_root)
    wanted = set()
    # Validate both trees completely before mkdir/copy/unlink follows any path.
    for base in (workspace / "rust", workspace / "contracts", workspace / "ThirdParty"):
        within(base, workspace)
        if base.exists():
            for path in base.rglob("*"):
                within(path, workspace)
    for raw in paths:
        if not raw:
            continue
        relative = Path(os.fsdecode(raw))
        if relative.is_absolute() or '..' in relative.parts:
            fail("source mirror path escapes source root")
        source = source_root / relative
        within(source, source_root)
        if not source.exists():
            continue
        if source.is_symlink() or not source.is_file() or not source.resolve().is_relative_to(source_root.resolve()):
            fail("source mirror accepts regular files only")
        wanted.add(relative)
        destination = workspace / relative
        within(destination, workspace)
        destination.parent.mkdir(parents=True, exist_ok=True)
        if not destination.is_file() or source.read_bytes() != destination.read_bytes():
            shutil.copyfile(source, destination)
    for base in (workspace / "rust", workspace / "contracts"):
        if base.exists():
            for path in base.rglob("*"):
                if path.is_file() and path.relative_to(workspace) not in wanted:
                    path.unlink()
    return wanted


@dataclass(frozen=True)
class Workspace:
    root: Path
    cache: Path
    source_root: Path
    environment: dict
    cargo: str
    pin: str
    sources: set
    capture: Path | None


@contextlib.contextmanager
def managed_workspace(command, options):
    if command not in COMMANDS:
        fail("unsupported cargo command")
    if any(option.split("=", 1)[0] in {"--manifest-path", "--target-dir", "--config", "--lockfile-path"} for option in options):
        fail("manifest, target, config and lockfile paths are managed by this runner")
    if any(option.split("=", 1)[0] == "--target" for option in options) or "CARGO_BUILD_TARGET" in os.environ:
        fail("native host builds only; --target and CARGO_BUILD_TARGET overrides are prohibited")
    if 'RUSTC' in os.environ:
        fail('the exact native rustc is managed; RUSTC override is prohibited')
    for name, value in os.environ.items():
        if name == 'CARGO_ENCODED_RUSTFLAGS':
            flags = value.split('\x1f')
        elif name == 'RUSTFLAGS' or name.startswith('CARGO_TARGET_') and name.endswith('_RUSTFLAGS'):
            flags = shlex.split(value)
        else:
            continue
        if any(flag == '--target' or flag.startswith('--target=') for flag in flags):
            fail('native host builds only; rustflags target overrides are prohibited')
    source_root = ROOT
    if "ARKTRACE_CARGO_SOURCE_ROOT" in os.environ:
        source_root = Path(os.environ["ARKTRACE_CARGO_SOURCE_ROOT"])
        if not source_root.is_absolute() or not source_root.is_dir() or source_root.is_symlink():
            fail("source override must be an absolute regular directory")
        source_root = source_root.resolve()
        expected_source = os.environ.get("ARKTRACE_CARGO_SOURCE_SHA256")
        if not expected_source or source_identity(source_root)["sourceSHA256"] != expected_source:
            fail("source override requires its exact source-identity SHA256")
        if command == "generate-lockfile" or command == "fmt" and "--check" not in options:
            fail("pinned source overrides cannot be rewritten by fmt or generate-lockfile")
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
    pin = tomllib.loads((source_root / "rust/rust-toolchain.toml").read_text())["toolchain"]["channel"]
    if pin != "1.99.0":
        fail("Rust must be pinned to exact 1.99.0")
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
    triples = {"macos-arm64": "aarch64-apple-darwin", "windows-x64": "x86_64-pc-windows-msvc"}
    if host not in triples:
        fail("supported native runners are macOS arm64 and Windows x64 MSVC")
    compiler = subprocess.run([rustc, f"+{pin}", "-vV"], capture_output=True, text=True)
    if compiler.returncode or f"host: {triples[host]}" not in compiler.stdout.splitlines():
        fail("rustc host triple differs from the actual native OS/architecture")
    if host == "macos-arm64":
        xcode = subprocess.run(["/usr/bin/xcodebuild", "-version"], capture_output=True, text=True)
        if xcode.returncode or not xcode.stdout.startswith("Xcode 27."):
            fail("Xcode 27 is required; no floating SDK fallback")
        if os.environ.get("MACOSX_DEPLOYMENT_TARGET", "26.0") != "26.0":
            fail("macOS deployment target is fixed at 26.0")
    owner = owner_id(os.environ.get("ARKTRACE_CARGO_OWNER", os.environ.get("CODEX_THREAD_ID", "local")))
    default_base = Path.home() / "Library/Caches/com.arkdeck.ArkTrace/Cargo/Owners" if sys.platform == "darwin" else Path.home() / ".cache/arktrace/cargo/owners"
    default = default_base / owner
    cache = Path(os.environ.get("ARKTRACE_CARGO_CACHE_ROOT", default))
    if not cache.is_absolute() or cache.resolve().is_relative_to(ROOT) or cache.resolve().is_relative_to(source_root):
        fail("cache root must be absolute and outside the worktree")
    cache = cache_root(cache)
    cache.mkdir(parents=True, exist_ok=True)
    if "ARKTRACE_CARGO_CACHE_ROOT" not in os.environ and not (cache / STATE).exists():
        register(cache, owner, source_root)
    if "ARKTRACE_CARGO_OWNER" in os.environ and not (cache / STATE).exists():
        fail("explicit owner requires cargo_cache.py register; use adopt-existing for an existing cache")
    dependency = Path(os.environ.get("ARKTRACE_CARGO_HOME", cache / "dependencies"))
    if not dependency.is_absolute() or dependency.resolve().is_relative_to(ROOT) or dependency.resolve().is_relative_to(source_root):
        fail("dependency cache must be absolute and outside the worktree")
    dependency.mkdir(parents=True, exist_ok=True)
    workspace = cache / "workspace"
    if is_link(workspace) or is_link(cache / "target"):
        fail("workspace and target must be owned regular directories")
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
    with runner_lock(cache, wait=True, create=True):
        if (cache / STATE).exists():
            state = load_state(cache, owner)
            if state["lifecycle"] != "active" or state["sourceRoot"] != str(source_root.resolve()):
                fail("registered owner must be active and use its registered source root")
        if "ARKTRACE_CARGO_SOURCE_ROOT" in os.environ and source_identity(source_root)["sourceSHA256"] != expected_source:
            fail("pinned source changed before mirror synchronization")
        sources = sync_sources(workspace, source_root)
        native_configuration(workspace / 'rust', dependency)
        yield Workspace(workspace, cache, source_root, environment, cargo, pin, sources, capture)


@dataclass
class Consumer:
    workspace: Workspace
    root: Path
    active: bool = True

    def run(self, command, options, **kwargs):
        if not self.active:
            fail("standalone consumer lock scope has ended")
        if command not in {"generate-lockfile", "run", "metadata"}:
            fail("unsupported standalone consumer command")
        if any(option.split("=", 1)[0] in {"--manifest-path", "--target-dir", "--target", "--config", "--lockfile-path"} for option in options):
            fail("standalone consumer paths and native host are managed")
        invocation = [self.workspace.cargo, "+" + self.workspace.pin, command]
        if command != "generate-lockfile":
            invocation.append("--locked")
        invocation.extend(options)
        native_configuration(self.root, Path(self.workspace.environment['CARGO_HOME']))
        return subprocess.run(invocation, cwd=self.root, env=self.workspace.environment, **kwargs)


@contextlib.contextmanager
def managed_consumer(name, source_files):
    """Hold the owner lock throughout an independent consumer's entire gate.

    source_files(workspace_root) returns Cargo.toml and Rust sources pointing
    at the stable mirrored dependencies. Its feature graph stays independent.
    """
    owner_id(name)
    with managed_workspace("run", []) as workspace:
        root = workspace.root / "consumers" / name
        within(root, workspace.root)
        if root.exists():
            for path in root.rglob("*"):
                within(path, workspace.root)
        files = source_files(workspace.root)
        if "Cargo.toml" not in files:
            fail("standalone consumer requires its own Cargo.toml")
        for name, data in files.items():
            relative = Path(name)
            if relative.is_absolute() or '..' in relative.parts or not (name == "Cargo.toml" or name.startswith("src/") and relative.suffix == ".rs"):
                fail("consumer inputs must be Cargo.toml and Rust source files")
            destination = root / relative
            within(destination, workspace.root)
            destination.parent.mkdir(parents=True, exist_ok=True)
            if not destination.exists() or destination.read_bytes() != data:
                destination.write_bytes(data)
        for path in root.rglob("*.rs"):
            if path.relative_to(root).as_posix() not in files:
                path.unlink()
        consumer = Consumer(workspace, root)
        try:
            yield consumer
        finally:
            consumer.active = False


def main():
    arguments = sys.argv[1:]
    if not arguments or arguments[0] in {"-h", "--help"}:
        print("usage: python3 scripts/run-cargo.py {build|test|check|clippy|fmt|metadata|generate-lockfile|run} [cargo options]")
        print("ARKTRACE_CARGO_CACHE_ROOT: absolute external cache; ARKTRACE_CARGO_HOME: optional external dependency cache")
        print("ARKTRACE_CARGO_OWNER: registered stable session owner; default caches use CODEX_THREAD_ID or local")
        print("ARKTRACE_CARGO_SOURCE_ROOT + ARKTRACE_CARGO_SOURCE_SHA256: explicit pinned source override")
        return 0
    command, *options = arguments
    with managed_workspace(command, options) as workspace:
        invocation = [workspace.cargo, "+" + workspace.pin, command]
        if command not in {"fmt", "generate-lockfile"}:
            invocation.append("--locked")
        invocation.extend(options)
        result = subprocess.run(invocation, cwd=workspace.root / "rust", env=workspace.environment)
        if result.returncode == 0 and workspace.capture:
            shutil.copyfile(workspace.cache / "target/release/libarktrace_ffi.a", workspace.capture)
        if result.returncode == 0 and command == "generate-lockfile":
            shutil.copyfile(workspace.root / "rust/Cargo.lock", workspace.source_root / "rust/Cargo.lock")
        if result.returncode == 0 and command == "fmt" and "--check" not in options:
            for relative in workspace.sources:
                if relative.suffix == ".rs":
                    source = workspace.root / relative
                    destination = workspace.source_root / relative
                    if source.read_bytes() != destination.read_bytes():
                        shutil.copyfile(source, destination)
        return result.returncode


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        fail(str(error))
