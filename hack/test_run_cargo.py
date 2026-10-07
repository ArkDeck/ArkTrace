#!/usr/bin/env python3
"""Hermetic checks for stable caches, formatting and fail-closed toolchains."""
import importlib.util
import contextlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("cargo_runner", Path(__file__).with_name("run-cargo.py"))
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class CargoRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.root = self.base / "checkout"
        (self.root / "rust/crates/example/src").mkdir(parents=True)
        (self.root / "rust/rust-toolchain.toml").write_text('[toolchain]\nchannel = "1.99.0"\n')
        (self.root / "rust/Cargo.lock").write_text('version = 4\n')
        (self.root / "rust/Cargo.toml").write_text(
            '[workspace]\n[profile.dev]\nincremental=false\ndebug="line-tables-only"\n'
            '[profile.dev.package."*"]\ndebug=false\n[profile.release]\npanic="unwind"\n')
        self.source = self.root / "rust/crates/example/src/lib.rs"
        self.source.write_text("pub fn example() {}\n")
        self.cache = self.base / "external-cache"
        self.calls = []
        self.compiler_version = "rustc 1.99.0 (test)"
        self.xcode_version = "Xcode 27.0\nBuild version 27A266a\n"
        self.compiler_host = None
        self.mbx = self.base / 'mbx'
        self.mbx.write_bytes(b'fixed compiler cache')
        self.mbx_version = 'mbx 1.22.0\n'

    def mbx_environment(self):
        return {'ARKTRACE_CARGO_MBX': str(self.mbx), 'ARKTRACE_CARGO_MBX_SHA256': RUNNER.digest(self.mbx),
                'ARKTRACE_CARGO_MBX_CACHE_ROOT': str(self.base / 'shared-store')}

    def fake_run(self, arguments, **kwargs):
        if arguments == ["/usr/bin/xcodebuild", "-version"]:
            return subprocess.CompletedProcess(arguments, 0, stdout=self.xcode_version, stderr="")
        if arguments[-1] == "--version":
            if arguments[0] == str(self.mbx):
                return subprocess.CompletedProcess(arguments, 0, stdout=self.mbx_version, stderr='')
            return subprocess.CompletedProcess(arguments, 0, stdout=self.compiler_version, stderr="")
        if arguments[-1] == "-vV":
            host = self.compiler_host or ("aarch64-apple-darwin" if RUNNER.platform.system() == "Darwin" else "x86_64-pc-windows-msvc")
            return subprocess.CompletedProcess(arguments, 0, stdout="host: " + host + "\n", stderr="")
        self.calls.append((arguments, kwargs))
        if "fmt" in arguments and "--check" not in arguments:
            (kwargs["cwd"] / "crates/example/src/lib.rs").write_text("pub fn formatted() {}\n")
        return subprocess.CompletedProcess(arguments, 0)

    @contextlib.contextmanager
    def mocked_tools(self, environment=None):
        env = {"ARKTRACE_CARGO_CACHE_ROOT": str(self.cache)}
        if environment:
            env.update(environment)
        paths = [p.relative_to(self.root).as_posix() for p in self.root.rglob("*") if p.is_file()]
        listed = ("\0".join(paths) + "\0").encode()
        with patch.object(RUNNER, "ROOT", self.root), \
             patch.dict(os.environ, env, clear=True), patch.object(RUNNER.shutil, "which", return_value="tool"), \
             patch.object(RUNNER.subprocess, "run", side_effect=self.fake_run), \
             patch.object(RUNNER.subprocess, "check_output", side_effect=lambda args, **kw: (str(kw['cwd']) + '\n').encode() if 'rev-parse' in args else listed):
            yield

    def invoke(self, *arguments, environment=None):
        with self.mocked_tools(environment), patch.object(sys, 'argv', ['runner', *arguments]):
            return RUNNER.main()

    def test_cache_and_source_identity_survive_repeated_invocations(self):
        self.assertEqual(self.invoke("build", "--workspace"), 0)
        mirror = self.cache / "workspace/rust/crates/example/src/lib.rs"
        initial_time = mirror.stat().st_mtime_ns
        self.assertEqual(self.invoke("test", "--workspace"), 0)
        self.assertEqual(mirror.stat().st_mtime_ns, initial_time)
        for arguments, kwargs in self.calls:
            self.assertEqual(arguments[1], "+1.99.0")
            self.assertIn("--locked", arguments)
            self.assertEqual(Path(kwargs["env"]["CARGO_TARGET_DIR"]), self.cache / "target")
            self.assertEqual(kwargs["cwd"], self.cache / "workspace/rust")
        self.source.write_text("pub fn changed() {}\n")
        self.invoke("check")
        self.assertEqual(mirror.read_text(), self.source.read_text())

    def test_formatter_changes_are_returned_to_the_worktree(self):
        self.invoke("fmt", "--all")
        self.assertEqual(self.source.read_text(), "pub fn formatted() {}\n")
        self.assertNotIn("--locked", self.calls[-1][0])

    def test_removed_sources_are_removed_from_the_mirror(self):
        self.invoke("build")
        self.source.unlink()
        self.invoke("check")
        self.assertFalse((self.cache / "workspace/rust/crates/example/src/lib.rs").exists())

    def test_no_floating_toolchain_fallback(self):
        self.compiler_version = "rustc 1.100.0 (test)"
        with self.assertRaisesRegex(SystemExit, "no floating toolchain fallback"):
            self.invoke("build")
        self.assertFalse(self.calls)

    def test_native_mismatch_does_not_execute_tests(self):
        with self.assertRaisesRegex(SystemExit, "native runner mismatch"):
            self.invoke("test", environment={"ARKTRACE_EXPECT_NATIVE_HOST": "impossible-host"})
        self.assertFalse(self.calls)

    def test_compiler_host_must_match_actual_native_machine(self):
        self.compiler_host = 'x86_64-unknown-linux-gnu'
        with self.assertRaisesRegex(SystemExit, 'rustc host triple'):
            self.invoke('check', '-p', 'example')
        self.assertFalse(self.calls)

    def test_explicit_target_overrides_are_rejected_before_cargo(self):
        for args, environment in [(('check', '--target', 'aarch64-apple-darwin'), {}),
                                  (('check', '--target=x86_64-pc-windows-msvc'), {}),
                                  (('test',), {'CARGO_BUILD_TARGET': ''})]:
            with self.subTest(args=args, environment=environment), self.assertRaisesRegex(SystemExit, 'native host builds only'):
                self.invoke(*args, environment=environment)
        self.assertFalse(self.calls)
        self.assertEqual(self.invoke('clippy', '--all-targets'), 0)

    def test_ambient_compiler_and_target_configuration_cannot_bypass_native_guard(self):
        for environment in [{'RUSTC':'foreign-rustc'}, {'RUSTFLAGS':'--target x86_64-pc-windows-msvc'},
                            {'CARGO_ENCODED_RUSTFLAGS':'--target\x1fx86_64-pc-windows-msvc'},
                            {'CARGO_TARGET_AARCH64_APPLE_DARWIN_RUSTFLAGS':'--target=x86_64-pc-windows-msvc'}]:
            with self.subTest(environment=environment), self.assertRaisesRegex(SystemExit, 'override'):
                self.invoke('check', environment=environment)
        config = self.cache / 'dependencies/config.toml'
        config.parent.mkdir(parents=True)
        config.write_text('[build]\ntarget="aarch64-apple-darwin"\n')
        with self.assertRaisesRegex(SystemExit, 'build.target'):
            self.invoke('check')
        self.assertFalse(self.calls)

    def test_windows_requires_msvc_host_and_no_cross_target_layout(self):
        with patch.object(RUNNER.platform, 'system', return_value='Windows'), patch.object(RUNNER.platform, 'machine', return_value='AMD64'):
            self.assertEqual(self.invoke('check', '-p', 'example'), 0)
            self.assertEqual(self.calls[-1][1]['env']['ARKTRACE_EXPECT_NATIVE_HOST'], 'windows-x64')
            self.assertNotIn('--target', self.calls[-1][0])
            self.compiler_host = 'x86_64-pc-windows-gnu'
            with self.assertRaisesRegex(SystemExit, 'rustc host triple'):
                self.invoke('check')

    def test_symlinked_mirror_ancestor_fails_before_copy_or_unlink(self):
        outside = self.base / 'outside'
        outside.mkdir()
        mirror = self.cache / 'workspace/rust'
        mirror.parent.mkdir(parents=True)
        mirror.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'link'):
            self.invoke('check')
        self.assertEqual(list(outside.iterdir()), [])

    def test_consumer_retains_independent_root_and_entire_gate_lock(self):
        from cargo_cache import runner_lock
        files = lambda root: {'Cargo.toml': b'[package]\nname="consumer"\n', 'src/main.rs': b'fn main() {}\n'}
        with self.mocked_tools():
            with RUNNER.managed_consumer('wire', files) as consumer:
                with self.assertRaisesRegex(ValueError, 'lock is active'):
                    with runner_lock(self.cache):
                        self.fail('consumer must hold its lock across every invocation')
                for command in ['generate-lockfile', 'run', 'metadata']:
                    consumer.run(command, ['--offline'])
                    argv, kw = self.calls[-1]
                    self.assertEqual(kw['cwd'], self.cache / 'workspace/consumers/wire')
                    self.assertEqual(kw['env']['CARGO_TARGET_DIR'], str(self.cache / 'target'))
                    self.assertEqual('--locked' in argv, command != 'generate-lockfile')
                original = (consumer.root / 'src/main.rs').stat().st_mtime_ns
            with self.assertRaisesRegex(SystemExit, 'lock scope has ended'):
                consumer.run('run', [])
            with RUNNER.managed_consumer('wire', files) as second:
                self.assertEqual((second.root / 'src/main.rs').stat().st_mtime_ns, original)

    def test_consumer_profiles_follow_workspace_even_with_conflicting_manifest(self):
        files = lambda root: {'Cargo.toml': b'[package]\nname="consumer"\n'
                              b'[profile.dev]\ndebug=true\nincremental=true\n',
                              'src/main.rs': b'fn main() {}\n'}
        with self.mocked_tools():
            with RUNNER.managed_consumer('wire', files) as consumer:
                configuration = consumer.root / '.cargo/config.toml'
                original = configuration.stat().st_mtime_ns
                actual = tomllib.loads(configuration.read_text())['profile']
                self.assertEqual(actual, tomllib.loads((self.root / 'rust/Cargo.toml').read_text())['profile'])
                self.assertFalse(actual['dev']['incremental'])
            with RUNNER.managed_consumer('wire', files) as consumer:
                self.assertEqual(configuration.stat().st_mtime_ns, original)
            manifest = self.root / 'rust/Cargo.toml'
            manifest.write_text(manifest.read_text().replace('line-tables-only', 'limited'))
            with RUNNER.managed_consumer('wire', files) as consumer:
                self.assertEqual(tomllib.loads(configuration.read_text())['profile']['dev']['debug'], 'limited')

    def test_consumer_rejects_linked_profile_configuration_before_writing(self):
        outside = self.base / 'outside'
        outside.mkdir()
        consumer_root = self.cache / 'workspace/consumers/wire'
        consumer_root.mkdir(parents=True)
        (consumer_root / '.cargo').symlink_to(outside, target_is_directory=True)
        with self.mocked_tools(), self.assertRaisesRegex(ValueError, 'link'):
            with RUNNER.managed_consumer('wire', lambda root: {'Cargo.toml': b'[package]\n'}):
                self.fail('linked configuration must be rejected')
        self.assertEqual(list(outside.iterdir()), [])

    def test_source_override_requires_exact_identity_and_cannot_write(self):
        with self.mocked_tools():
            identity = RUNNER.source_identity(self.root)['sourceSHA256']
        environment = {'ARKTRACE_CARGO_SOURCE_ROOT': str(self.root), 'ARKTRACE_CARGO_SOURCE_SHA256': identity}
        self.assertEqual(self.invoke('check', environment=environment), 0)
        for command in [('fmt', '--all'), ('generate-lockfile',)]:
            with self.assertRaisesRegex(SystemExit, 'cannot be rewritten'):
                self.invoke(*command, environment=environment)
        with self.assertRaisesRegex(SystemExit, 'exact source-identity'):
            self.invoke('check', environment=environment | {'ARKTRACE_CARGO_SOURCE_SHA256': '0' * 64})

    def test_mbx_wraps_only_compilation_with_pinned_toolchain_and_owned_target(self):
        with patch.object(RUNNER.platform, 'system', return_value='Darwin'), patch.object(RUNNER.platform, 'machine', return_value='arm64'):
            for command in ('build', 'check', 'test', 'clippy', 'run', 'metadata', 'fmt', 'generate-lockfile'):
                self.invoke(command, environment=self.mbx_environment())
                argv, kw = self.calls[-1]
                self.assertEqual(argv[0], str(self.mbx) if command in RUNNER.COMPILE_COMMANDS else 'tool')
                self.assertEqual(argv[1], '+1.99.0')
                self.assertEqual(kw['env']['CARGO_TARGET_DIR'], str(self.cache / 'target'))
                if command in RUNNER.COMPILE_COMMANDS:
                    self.assertEqual(kw['env']['MBX_TARGET_VIEWS'], '0')
                    self.assertEqual(kw['env']['MBX_TARGET_LANES'], '0')
                    self.assertEqual(kw['env']['MBX_REMOTE_MODE'], 'write-only')
                    self.assertEqual(kw['env']['MBX_GC_MAX_TOTAL_SIZE'], str(2 * 1024 ** 3) + 'B')
            with self.mocked_tools(self.mbx_environment()):
                with RUNNER.managed_consumer('wire', lambda root: {'Cargo.toml': b'[package]\n'}) as consumer:
                    consumer.run('run', [])
                    self.assertEqual(self.calls[-1][0][0], str(self.mbx))
                    consumer.run('metadata', [])
                    self.assertEqual(self.calls[-1][0][0], 'tool')

    def test_mbx_wrong_identity_version_storage_or_ci_fails_without_cargo_fallback(self):
        with patch.object(RUNNER.platform, 'system', return_value='Darwin'), patch.object(RUNNER.platform, 'machine', return_value='arm64'):
            for overrides, message in [({'ARKTRACE_CARGO_MBX_SHA256': '0' * 64}, 'SHA256'),
                                       ({'ARKTRACE_CARGO_MBX_CACHE_ROOT': str(self.cache / 'shared')}, 'disjoint'),
                                       ({'ARKTRACE_CARGO_MBX_CACHE_ROOT': ''}, 'external shared'),
                                       ({'CI': 'true'}, 'local-only')]:
                with self.subTest(overrides=overrides), self.assertRaisesRegex(SystemExit, message):
                    self.invoke('check', environment=self.mbx_environment() | overrides)
            self.mbx_version = 'mbx 1.23.0\n'
            with self.assertRaisesRegex(SystemExit, 'exact version'):
                self.invoke('check', environment=self.mbx_environment())
        self.assertFalse(self.calls)

    def test_registered_cache_rejects_ended_owner_before_cargo(self):
        from cargo_cache import transition
        with self.mocked_tools():
            RUNNER.register(self.cache, 'fixed', self.root)
        transition(self.cache, 'fixed', 'ended')
        with self.assertRaisesRegex(SystemExit, 'must be active'):
            self.invoke('check', environment={'ARKTRACE_CARGO_OWNER': 'fixed'})
        self.assertFalse(self.calls)

    def test_managed_paths_cannot_be_overridden(self):
        for flag in ["--manifest-path", "--target-dir", "--config", "--lockfile-path"]:
            with self.subTest(flag=flag), self.assertRaisesRegex(SystemExit, "managed by this runner"):
                self.invoke("build", f"{flag}=arbitrary")

    def test_frozen_sqlite_cannot_be_replaced_by_ambient_build_configuration(self):
        for name in ["LIBSQLITE3_SYS_USE_PKG_CONFIG", "LIBSQLITE3_SYS_BUNDLING", "LIBSQLITE3_FLAGS",
                     "SQLITE3_LIB_DIR", "SQLITE3_INCLUDE_DIR", "SQLITE3_STATIC",
                     "SQLITE_MAX_VARIABLE_NUMBER", "SQLITE_MAX_EXPR_DEPTH", "SQLITE_MAX_COLUMN"]:
            with self.subTest(name=name), self.assertRaisesRegex(SystemExit, "SQLite build overrides"):
                self.invoke("build", environment={name: "arbitrary"})
        self.assertFalse(self.calls)

    def test_native_sqlite_descriptor_support_is_always_enabled(self):
        self.assertEqual(self.invoke("build", "--workspace"), 0)
        self.assertEqual(self.invoke("test", "--workspace"), 0)
        for _, kwargs in self.calls:
            self.assertEqual(kwargs["env"]["LIBSQLITE3_FLAGS"], "-DSQLITE_ENABLE_FILESTAT=1")

    def test_cache_must_be_absolute_and_external(self):
        for cache in ["relative", str(self.root / "cache")]:
            with self.subTest(cache=cache), self.assertRaisesRegex(SystemExit, "outside the worktree"):
                self.invoke("build", environment={"ARKTRACE_CARGO_CACHE_ROOT": cache})

    def test_native_macos_uses_xcode_27_and_keeps_the_existing_26_floor(self):
        with patch.object(RUNNER.platform,"system",return_value="Darwin"), patch.object(RUNNER.platform,"machine",return_value="arm64"):
            self.assertEqual(self.invoke("build"),0)
            self.assertEqual(self.calls[-1][1]["env"]["MACOSX_DEPLOYMENT_TARGET"],"26.0")
            self.calls.clear()
            self.xcode_version="Xcode 26.6\n"
            with self.assertRaisesRegex(SystemExit,"Xcode 27"):
                self.invoke("build")
            self.assertFalse(self.calls)
            self.xcode_version="Xcode 27.0\n"
            with self.assertRaisesRegex(SystemExit,"deployment target"):
                self.invoke("build",environment={"MACOSX_DEPLOYMENT_TARGET":"11.0"})
            self.assertFalse(self.calls)

    def test_staticlib_capture_is_exact_fresh_and_native_release_only(self):
        with patch.object(RUNNER.platform, "system", return_value="Darwin"), patch.object(RUNNER.platform, "machine", return_value="arm64"):
            archive = self.cache / "target/release/libarktrace_ffi.a"
            archive.parent.mkdir(parents=True)
            archive.write_bytes(b"exact output under runner lock")
            captured = self.base / "captured.a"
            self.assertEqual(self.invoke("build", "-p", "arktrace-ffi", "--release", environment={"ARKTRACE_CARGO_CAPTURE_STATICLIB": str(captured)}), 0)
            self.assertEqual(captured.read_bytes(), archive.read_bytes())
            with self.assertRaisesRegex(SystemExit, "fresh absolute external"):
                self.invoke("build", "-p", "arktrace-ffi", "--release", environment={"ARKTRACE_CARGO_CAPTURE_STATICLIB": str(captured)})
            with self.assertRaisesRegex(SystemExit, "explicit native SDK release"):
                self.invoke("build", "--workspace", environment={"ARKTRACE_CARGO_CAPTURE_STATICLIB": str(self.base / "other.a")})


if __name__ == "__main__":
    unittest.main()
