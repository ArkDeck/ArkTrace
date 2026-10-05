#!/usr/bin/env python3
"""Input/staging failure regressions; synthetic bytes never execute as tools."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from copy_native_app_resources import copy
from prepare_macos_native_app import ROOT, validate_inputs


class NativeResourcesTests(unittest.TestCase):
    def inputs(self):
        root = Path(self.enterContext(tempfile.TemporaryDirectory(dir="/private/tmp")))
        inputs = root / "inputs"
        values = {"Helpers/arktrace-host-process": b"synthetic helper", "Helpers/trace_streamer": b"synthetic parser"}
        digest = lambda data: hashlib.sha256(data).hexdigest()
        values["TraceStreamer/manifest.json"] = json.dumps({"binarySHA256": digest(values["Helpers/trace_streamer"])}).encode()
        values["ArkTraceRuntime/manifest.json"] = json.dumps({"formatVersion": 1, "contractSHA256": (ROOT / "contracts/ffi-v1.sha256").read_text().strip(),
            "helperSHA256": digest(values["Helpers/arktrace-host-process"]), "publisher": None}).encode()
        rows = []
        for name, data in values.items():
            path = inputs / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            mode = 0o555 if name.startswith("Helpers/") else 0o444
            path.chmod(mode)
            rows.append({"path": name, "byteCount": len(data), "sha256": digest(data), "mode": mode})
        receipt = {"formatVersion": 1, "runtimeUsable": False, "inputs": {"publisher": None}, "files": rows}
        (inputs / "receipt.json").write_text(json.dumps(receipt))
        return root, inputs, receipt

    def test_exact_resources_copy_and_mode(self):
        root, inputs, _ = self.inputs()
        app = root / "ArkTrace.app"
        copy(inputs, app)
        copy(inputs, app)
        helper = app / "Contents/Helpers/arktrace-host-process"
        self.assertEqual(helper.read_bytes(), b"synthetic helper")
        self.assertEqual(helper.stat().st_mode & 0o777, 0o555)

    def test_changed_bytes_mode_extra_members_and_links_fail(self):
        root, inputs, _ = self.inputs()
        file = inputs / "Helpers/arktrace-host-process"
        file.chmod(0o755)
        with self.assertRaisesRegex(ValueError, "drift"):
            validate_inputs(inputs)
        file.chmod(0o555)
        extra = inputs / "unexpected"
        extra.write_text("unknown")
        with self.assertRaisesRegex(ValueError, "extra"):
            validate_inputs(inputs)
        extra.unlink()
        extra.symlink_to(file)
        with self.assertRaisesRegex(ValueError, "links"):
            validate_inputs(inputs)

    def test_receipt_cannot_mark_unsigned_inputs_usable(self):
        _, inputs, receipt = self.inputs()
        receipt["runtimeUsable"] = True
        (inputs / "receipt.json").write_text(json.dumps(receipt))
        with self.assertRaisesRegex(ValueError, "unsigned"):
            validate_inputs(inputs)

    def test_destination_symlink_is_preserved_and_rejected(self):
        root, inputs, _ = self.inputs()
        outside = root / "user-data"
        outside.write_bytes(b"preserve")
        target = root / "ArkTrace.app/Contents/Helpers/arktrace-host-process"
        target.parent.mkdir(parents=True)
        target.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "destination links"):
            copy(inputs, root / "ArkTrace.app")
        self.assertEqual(outside.read_bytes(), b"preserve")
        self.assertTrue(target.is_symlink())


if __name__ == "__main__":
    unittest.main()
