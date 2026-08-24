#!/usr/bin/env python3
"""Contract tests for the stable-path Xcode runner."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("run-xcodebuild.sh")


class RunXcodebuildTests(unittest.TestCase):
    def make_fake_xcodebuild(self, directory: Path) -> Path:
        executable = directory / "xcodebuild"
        executable.write_text(
            "#!/bin/sh\n"
            "printf 'CLANG_MODULE_CACHE_PATH=%s\\n' \"$CLANG_MODULE_CACHE_PATH\"\n"
            "printf 'SWIFTPM_MODULECACHE_OVERRIDE=%s\\n' \"$SWIFTPM_MODULECACHE_OVERRIDE\"\n"
            "printf 'ARG:%s\\n' \"$@\"\n"
            "exit \"${FAKE_XCODEBUILD_EXIT:-0}\"\n",
            encoding="utf-8",
        )
        executable.chmod(0o700)
        return executable

    def make_repo(
        self, root: Path, source_contents: str, modified_time: int
    ) -> tuple[Path, Path]:
        script = root / "scripts/run-xcodebuild.sh"
        script.parent.mkdir(parents=True)
        shutil.copy2(SCRIPT, script)
        project = root / "ArkTrace.xcodeproj/project.pbxproj"
        project.parent.mkdir(parents=True)
        project.write_text("// project\n", encoding="utf-8")
        source = root / "Apps/ArkTraceApp/App.swift"
        source.parent.mkdir(parents=True)
        source.write_text(source_contents, encoding="utf-8")
        parser = root / "ThirdParty/TraceStreamer/macx/trace_streamer"
        parser.parent.mkdir(parents=True)
        parser.write_bytes(b"approved parser")
        parser.chmod(0o700)
        manifest = {"binarySHA256": hashlib.sha256(parser.read_bytes()).hexdigest()}
        (parser.parent / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        (root / ".gitignore").write_text(
            "ThirdParty/TraceStreamer/macx/trace_streamer\n", encoding="utf-8"
        )
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        subprocess.run(["git", "-C", str(root), "add", "."], check=True)
        os.utime(source, (modified_time, modified_time))
        return script, source

    def invoke(
        self,
        script: Path,
        cache_root: Path,
        xcodebuild: Path,
        *,
        output_root: Path | None = None,
        exit_code: str = "0",
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment.update(
            {
                "ARKTRACE_XCODE_CACHE_ROOT": str(cache_root),
                "ARKTRACE_XCODEBUILD_EXECUTABLE": str(xcodebuild),
                "FAKE_XCODEBUILD_EXIT": exit_code,
            }
        )
        if output_root is not None:
            environment["ARKTRACE_XCODE_OUTPUT_ROOT"] = str(output_root)
        return subprocess.run(
            ["/bin/sh", str(script)],
            text=True,
            capture_output=True,
            env=environment,
            check=False,
        )

    def test_build_uses_stable_owned_paths_and_verified_parser(self) -> None:
        temporary = Path(self.enterContext(tempfile.TemporaryDirectory()))
        script, _ = self.make_repo(
            temporary / "repo", "let value = 1\n", 1_700_000_000
        )
        cache_root = temporary / "cache root"
        output_root = temporary / "products"
        result = self.invoke(
            script,
            cache_root,
            self.make_fake_xcodebuild(temporary),
            output_root=output_root,
        )
        canonical = cache_root.resolve()

        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        arguments = [line.removeprefix("ARG:") for line in lines if line.startswith("ARG:")]
        self.assertEqual(arguments[0:2], ["-project", str(canonical / "workspace/ArkTrace.xcodeproj")])
        self.assertIn(f"OBJROOT={canonical / 'Objects'}", arguments)
        self.assertIn(str(canonical / "SourcePackages"), arguments)
        self.assertIn(str(canonical / "PackageCache"), arguments)
        self.assertIn("SWIFT_OPTIMIZATION_LEVEL=-Onone", arguments)
        self.assertIn("SWIFT_COMPILATION_MODE=singlefile", arguments)
        self.assertIn("ARCHS=arm64", arguments)
        self.assertIn("ONLY_ACTIVE_ARCH=YES", arguments)
        self.assertEqual(arguments[-1], "build")
        self.assertEqual(
            (canonical / "workspace/ThirdParty/TraceStreamer/macx/trace_streamer").read_bytes(),
            b"approved parser",
        )

    def test_identical_worktree_content_preserves_mirror_identity(self) -> None:
        temporary = Path(self.enterContext(tempfile.TemporaryDirectory()))
        first, _ = self.make_repo(temporary / "first", "let value = 1\n", 1_700_000_000)
        second, _ = self.make_repo(temporary / "second", "let value = 1\n", 1_800_000_000)
        cache_root = temporary / "cache"
        xcodebuild = self.make_fake_xcodebuild(temporary)

        self.assertEqual(self.invoke(first, cache_root, xcodebuild).returncode, 0)
        mirror = cache_root / "workspace/Apps/ArkTraceApp/App.swift"
        first_stat = mirror.stat()
        self.assertEqual(self.invoke(second, cache_root, xcodebuild).returncode, 0)
        second_stat = mirror.stat()

        self.assertEqual(first_stat.st_ino, second_stat.st_ino)
        self.assertEqual(first_stat.st_mtime_ns, second_stat.st_mtime_ns)

    def test_changed_or_missing_parser_is_rejected_before_xcodebuild(self) -> None:
        temporary = Path(self.enterContext(tempfile.TemporaryDirectory()))
        script, _ = self.make_repo(temporary / "repo", "let value = 1\n", 1_700_000_000)
        parser = temporary / "repo/ThirdParty/TraceStreamer/macx/trace_streamer"
        parser.write_bytes(b"drifted")
        marker = temporary / "called"
        executable = temporary / "xcodebuild"
        executable.write_text(f"#!/bin/sh\ntouch '{marker}'\n", encoding="utf-8")
        executable.chmod(0o700)

        changed = self.invoke(script, temporary / "cache", executable)
        parser.unlink()
        missing = self.invoke(script, temporary / "cache", executable)

        self.assertEqual(changed.returncode, 65)
        self.assertEqual(missing.returncode, 66)
        self.assertFalse(marker.exists())

    def test_invalid_cache_root_and_exit_status_are_preserved(self) -> None:
        temporary = Path(self.enterContext(tempfile.TemporaryDirectory()))
        script, _ = self.make_repo(temporary / "repo", "let value = 1\n", 1_700_000_000)
        executable = self.make_fake_xcodebuild(temporary)

        inside = self.invoke(script, temporary / "repo/cache", executable)
        failed = self.invoke(
            script, temporary / "cache", executable, exit_code="23"
        )

        self.assertEqual(inside.returncode, 64)
        self.assertIn("outside the worktree", inside.stderr)
        self.assertEqual(failed.returncode, 23)

    def test_output_root_inside_worktree_is_rejected(self) -> None:
        temporary = Path(self.enterContext(tempfile.TemporaryDirectory()))
        script, _ = self.make_repo(temporary / "repo", "let value = 1\n", 1_700_000_000)
        result = self.invoke(
            script,
            temporary / "cache",
            self.make_fake_xcodebuild(temporary),
            output_root=temporary / "repo/products",
        )

        self.assertEqual(result.returncode, 64)
        self.assertIn("output root must be outside the worktree", result.stderr)

    def test_shared_invocations_are_serialized(self) -> None:
        temporary = Path(self.enterContext(tempfile.TemporaryDirectory()))
        script, _ = self.make_repo(temporary / "repo", "let value = 1\n", 1_700_000_000)
        cache_root = temporary / "cache"
        active = temporary / "active"
        executable = temporary / "serialized-xcodebuild"
        executable.write_text(
            "#!/bin/sh\nmkdir \"$FAKE_ACTIVE\" || exit 91\n"
            "sleep 0.2\nrmdir \"$FAKE_ACTIVE\"\n",
            encoding="utf-8",
        )
        executable.chmod(0o700)
        environment = os.environ.copy()
        environment.update(
            {
                "ARKTRACE_XCODE_CACHE_ROOT": str(cache_root),
                "ARKTRACE_XCODEBUILD_EXECUTABLE": str(executable),
                "FAKE_ACTIVE": str(active),
            }
        )
        command = ["/bin/sh", str(script)]
        first = subprocess.Popen(command, env=environment)
        second = subprocess.Popen(command, env=environment)
        first.wait(timeout=5)
        second.wait(timeout=5)
        self.assertEqual(first.returncode, 0)
        self.assertEqual(second.returncode, 0)


if __name__ == "__main__":
    unittest.main()
