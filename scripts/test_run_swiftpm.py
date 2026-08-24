#!/usr/bin/env python3
"""Contract tests for the stable-path SwiftPM runner."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("run-swiftpm.sh")


class RunSwiftPMTests(unittest.TestCase):
    def make_fake_swift(self, directory: Path) -> Path:
        executable = directory / "swift"
        executable.write_text(
            "#!/bin/sh\n"
            "printf 'CLANG_MODULE_CACHE_PATH=%s\\n' \"$CLANG_MODULE_CACHE_PATH\"\n"
            "printf 'SWIFTPM_MODULECACHE_OVERRIDE=%s\\n' \"$SWIFTPM_MODULECACHE_OVERRIDE\"\n"
            "printf 'ARG:%s\\n' \"$@\"\n"
            "exit \"${FAKE_SWIFT_EXIT:-0}\"\n",
            encoding="utf-8",
        )
        executable.chmod(0o700)
        return executable

    def make_repo(
        self, root: Path, source_contents: str, modified_time: int
    ) -> tuple[Path, Path]:
        script = root / "scripts/run-swiftpm.sh"
        script.parent.mkdir(parents=True)
        shutil.copy2(SCRIPT, script)
        source = root / "Sources/Example/Example.swift"
        source.parent.mkdir(parents=True)
        source.write_text(source_contents, encoding="utf-8")
        (root / "Package.swift").write_text(
            "// swift-tools-version: 6.0\n", encoding="utf-8"
        )
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        subprocess.run(["git", "-C", str(root), "add", "."], check=True)
        os.utime(source, (modified_time, modified_time))
        return script, source

    def invoke(
        self,
        script: Path,
        cache_root: Path,
        swift: Path,
        *arguments: str,
        exit_code: str = "0",
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment.update(
            {
                "ARKTRACE_SWIFTPM_CACHE_ROOT": str(cache_root),
                "ARKTRACE_SWIFT_EXECUTABLE": str(swift),
                "FAKE_SWIFT_EXIT": exit_code,
            }
        )
        return subprocess.run(
            ["/bin/sh", str(script), *arguments],
            text=True,
            capture_output=True,
            env=environment,
            check=False,
        )

    def test_build_uses_stable_owned_paths_and_module_cache(self) -> None:
        temporary = Path(self.enterContext(tempfile.TemporaryDirectory()))
        script, _ = self.make_repo(
            temporary / "repo", "public let value = 1\n", 1_700_000_000
        )
        cache_root = temporary / "cache root"
        result = self.invoke(
            script,
            cache_root,
            self.make_fake_swift(temporary),
            "build",
            "--target",
            "Example",
        )
        canonical = cache_root.resolve()

        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertIn(
            f"CLANG_MODULE_CACHE_PATH={canonical / 'ModuleCache'}", lines
        )
        arguments = [line.removeprefix("ARG:") for line in lines if line.startswith("ARG:")]
        self.assertEqual(arguments[0:3], ["build", "--package-path", str(canonical / "workspace")])
        self.assertIn(str(canonical / "build"), arguments)
        self.assertIn(str(canonical / "dependencies"), arguments)
        self.assertEqual(arguments[-2:], ["--target", "Example"])
        self.assertTrue((cache_root / "build.lock").is_file())

    def test_identical_worktree_content_preserves_mirror_identity(self) -> None:
        temporary = Path(self.enterContext(tempfile.TemporaryDirectory()))
        first, _ = self.make_repo(
            temporary / "first", "public let value = 1\n", 1_700_000_000
        )
        second, _ = self.make_repo(
            temporary / "second", "public let value = 1\n", 1_800_000_000
        )
        cache_root = temporary / "cache"
        swift = self.make_fake_swift(temporary)

        self.assertEqual(self.invoke(first, cache_root, swift, "build").returncode, 0)
        mirror = cache_root / "workspace/Sources/Example/Example.swift"
        first_stat = mirror.stat()
        self.assertEqual(self.invoke(second, cache_root, swift, "build").returncode, 0)
        second_stat = mirror.stat()

        self.assertEqual(first_stat.st_ino, second_stat.st_ino)
        self.assertEqual(first_stat.st_mtime_ns, second_stat.st_mtime_ns)

    def test_real_change_updates_mirror_and_exit_status_is_preserved(self) -> None:
        temporary = Path(self.enterContext(tempfile.TemporaryDirectory()))
        first, _ = self.make_repo(
            temporary / "first", "public let value = 1\n", 1_700_000_000
        )
        second, _ = self.make_repo(
            temporary / "second", "public let value = 2\n", 1_800_000_000
        )
        cache_root = temporary / "cache"
        swift = self.make_fake_swift(temporary)

        self.assertEqual(self.invoke(first, cache_root, swift, "build").returncode, 0)
        result = self.invoke(second, cache_root, swift, "test", exit_code="23")

        self.assertEqual(result.returncode, 23)
        self.assertEqual(
            (cache_root / "workspace/Sources/Example/Example.swift").read_text(),
            "public let value = 2\n",
        )

    def test_runner_owned_paths_and_unsafe_cache_roots_are_rejected(self) -> None:
        temporary = Path(self.enterContext(tempfile.TemporaryDirectory()))
        script, _ = self.make_repo(
            temporary / "repo", "public let value = 1\n", 1_700_000_000
        )
        swift = self.make_fake_swift(temporary)

        override = self.invoke(
            script, temporary / "cache", swift, "build", "--scratch-path=/tmp/build"
        )
        inside = self.invoke(script, temporary / "repo/cache", swift, "build")

        self.assertEqual(override.returncode, 64)
        self.assertIn("managed by this runner", override.stderr)
        self.assertEqual(inside.returncode, 64)
        self.assertIn("outside the worktree", inside.stderr)

    def test_shared_invocations_are_serialized(self) -> None:
        temporary = Path(self.enterContext(tempfile.TemporaryDirectory()))
        script, _ = self.make_repo(
            temporary / "repo", "public let value = 1\n", 1_700_000_000
        )
        cache_root = temporary / "cache"
        active = temporary / "active"
        executable = temporary / "serialized-swift"
        executable.write_text(
            "#!/bin/sh\nmkdir \"$FAKE_ACTIVE\" || exit 91\n"
            "sleep 0.2\nrmdir \"$FAKE_ACTIVE\"\n",
            encoding="utf-8",
        )
        executable.chmod(0o700)
        environment = os.environ.copy()
        environment.update(
            {
                "ARKTRACE_SWIFTPM_CACHE_ROOT": str(cache_root),
                "ARKTRACE_SWIFT_EXECUTABLE": str(executable),
                "FAKE_ACTIVE": str(active),
            }
        )
        command = ["/bin/sh", str(script), "build"]
        first = subprocess.Popen(command, env=environment)
        second = subprocess.Popen(command, env=environment)
        first.wait(timeout=5)
        second.wait(timeout=5)
        self.assertEqual(first.returncode, 0)
        self.assertEqual(second.returncode, 0)


if __name__ == "__main__":
    unittest.main()
