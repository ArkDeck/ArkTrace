#!/usr/bin/env python3
"""Run actual migration fixtures with Windows' non-UTF-8 text default."""
import contextlib
import io
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import verify_migration_contracts


class MigrationEncodingTests(unittest.TestCase):
    def test_windows_checkout_preserves_viewer_receipt_bytes(self):
        root = verify_migration_contracts.ROOT
        paths = [
            "README.md", "README.zh-CN.md",
            "rust/crates/arktrace-viewer/oracle/snapshot_event_index_lib_exports.patch",
            "rust/crates/arktrace-viewer/oracle/snapshot_event_index_swift_logging.patch",
        ]
        environment = os.environ.copy()
        environment.pop("GIT_DIR", None)
        environment.pop("GIT_WORK_TREE", None)
        with tempfile.TemporaryDirectory(prefix="arktrace-receipt-checkout-") as directory:
            checkout = Path(directory)
            (checkout / ".gitattributes").write_bytes((root / ".gitattributes").read_bytes())
            original = {path: (root / path).read_bytes() for path in paths}
            for relative, data in original.items():
                path = checkout / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            subprocess.run(["git", "init", "--quiet"], cwd=checkout, env=environment, check=True)
            subprocess.run(["git", "-c", "core.autocrlf=false", "add", "--all"], cwd=checkout, env=environment, check=True)
            # Existing index stat entries can skip a rewrite even with force.
            # Remove working files so Git actually applies checkout conversion.
            for relative in paths:
                (checkout / relative).unlink()
            subprocess.run(["git", "-c", "core.autocrlf=true", "checkout-index", "--all", "--force"],
                           cwd=checkout, env=environment, check=True)
            for relative, data in original.items():
                self.assertEqual((checkout / relative).read_bytes(), data, relative)

    def test_unicode_fixtures_do_not_depend_on_default_code_page(self):
        fixture = (verify_migration_contracts.ROOT / "rust/crates/arktrace-viewer/tests/fixtures/presentation-inputs.json")

        def windows_encoding(encoding, *args):
            return "cp1252" if encoding is None or encoding == "locale" else encoding

        with patch("io.text_encoding", windows_encoding):
            # This is the actual fixture that failed on the Windows runner.
            # First prove the injected environment still catches the old read.
            with self.assertRaises(UnicodeDecodeError):
                fixture.read_text()
            with contextlib.redirect_stdout(io.StringIO()):
                verify_migration_contracts.main()


if __name__ == "__main__":
    unittest.main(verbosity=2)
