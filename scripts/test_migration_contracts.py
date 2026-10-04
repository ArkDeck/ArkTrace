#!/usr/bin/env python3
"""Run actual migration fixtures with Windows' non-UTF-8 text default."""
import contextlib
import io
from pathlib import Path
import unittest
from unittest.mock import patch

import verify_migration_contracts


class MigrationEncodingTests(unittest.TestCase):
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
    unittest.main()
