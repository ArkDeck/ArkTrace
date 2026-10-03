#!/usr/bin/env python3
"""Hermetic checks for stable caches, formatting and fail-closed toolchains."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
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
        self.source = self.root / "rust/crates/example/src/lib.rs"
        self.source.write_text("pub fn example() {}\n")
        self.cache = self.base / "external-cache"
        self.calls = []
        self.compiler_version = "rustc 1.99.0 (test)"
        self.xcode_version = "Xcode 27.0\nBuild version 27A266a\n"

    def fake_run(self, arguments, **kwargs):
        if arguments == ["/usr/bin/xcodebuild", "-version"]:
            return subprocess.CompletedProcess(arguments, 0, stdout=self.xcode_version, stderr="")
        if arguments[-1] == "--version":
            return subprocess.CompletedProcess(arguments, 0, stdout=self.compiler_version, stderr="")
        self.calls.append((arguments, kwargs))
        if "fmt" in arguments and "--check" not in arguments:
            (kwargs["cwd"] / "crates/example/src/lib.rs").write_text("pub fn formatted() {}\n")
        return subprocess.CompletedProcess(arguments, 0)

    def invoke(self, *arguments, environment=None):
        env = {"ARKTRACE_CARGO_CACHE_ROOT": str(self.cache)}
        if environment:
            env.update(environment)
        paths = [p.relative_to(self.root).as_posix() for p in self.root.rglob("*") if p.is_file()]
        listed = ("\0".join(paths) + "\0").encode()
        with patch.object(RUNNER, "ROOT", self.root), patch.object(sys, "argv", ["runner", *arguments]), \
             patch.dict(os.environ, env, clear=True), patch.object(RUNNER.shutil, "which", return_value="tool"), \
             patch.object(RUNNER.subprocess, "run", side_effect=self.fake_run), \
             patch.object(RUNNER.subprocess, "check_output", return_value=listed):
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


if __name__ == "__main__":
    unittest.main()
