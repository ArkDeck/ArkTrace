#!/usr/bin/env python3
"""Input/staging failure regressions; synthetic bytes never execute as tools."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import subprocess
from copy_native_app_resources import copy
from prepare_macos_native_app import INHERITED_ENTITLEMENTS_DER, ROOT, signature, validate_inputs


class NativeResourcesTests(unittest.TestCase):
    def inputs(self):
        root = Path(self.enterContext(tempfile.TemporaryDirectory(dir="/private/tmp")))
        inputs = root / "inputs"
        values = {"Helpers/arktrace-host-process": b"synthetic helper", "Helpers/trace_streamer": b"synthetic parser"}
        digest = lambda data: hashlib.sha256(data).hexdigest()
        values["TraceStreamer/manifest.json"] = json.dumps({"binarySHA256": digest(values["Helpers/trace_streamer"])}).encode()
        values["ArkTraceRuntime/manifest.json"] = json.dumps({"formatVersion": 1, "contractSHA256": (ROOT / "api/ffi-v2.sha256").read_text().strip(),
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

    def test_arkdeck_copy_uses_its_fixed_parser_location(self):
        root, inputs, receipt = self.inputs()
        receipt["inputs"].update(product="arkdeck", sandboxInheritance=True)
        (inputs / "receipt.json").write_text(json.dumps(receipt))
        copy(inputs, root / "ArkDeck.app", "arkdeck")
        self.assertEqual((root / "ArkDeck.app/Contents/MacOS/trace_streamer").read_bytes(), b"synthetic parser")
        self.assertTrue((root / "ArkDeck.app/Contents/Helpers/arktrace-host-process").is_file())
        self.assertFalse((root / "ArkDeck.app/Contents/Helpers/trace_streamer").exists())
        with self.assertRaisesRegex(ValueError, "product mismatch"):
            copy(inputs, root / "ArkTrace.app")
        self.assertFalse((root / "ArkTrace.app").exists())

    def test_foreign_or_changed_inheritance_profile_fails_before_copy(self):
        root, inputs, receipt = self.inputs()
        for product, inheritance in (("arkdeck", False), ("arktrace", True), ("unknown", True), ("arkdeck", 1)):
            with self.subTest(product=product, inheritance=inheritance):
                receipt["inputs"].update(product=product, sandboxInheritance=inheritance)
                (inputs / "receipt.json").write_text(json.dumps(receipt))
                with self.assertRaises(ValueError):
                    copy(inputs, root / "Candidate.app", "arkdeck")
                self.assertFalse((root / "Candidate.app").exists())

    def test_effective_signature_rights_must_match_the_entire_profile(self):
        publisher = "Identifier=com.arkdeck.desktop.host-process\nTeamIdentifier=8AQTYW5FKR\nCodeDirectory v=20500 flags=0x10000(runtime)\n"
        for inherit, payload, accepted in ((True, INHERITED_ENTITLEMENTS_DER, True),
                                          (False, b"", True), (True, b"", False),
                                          (False, INHERITED_ENTITLEMENTS_DER, False),
                                          (True, INHERITED_ENTITLEMENTS_DER + b"extra", False)):
            with self.subTest(inherit=inherit, payload=payload):
                outputs = [subprocess.CompletedProcess([], 0), subprocess.CompletedProcess([], 0, stderr=publisher),
                           subprocess.CompletedProcess([], 0, stdout=payload)]
                with patch("prepare_macos_native_app.subprocess.run", side_effect=outputs):
                    if accepted:
                        signature(Path("synthetic"), "com.arkdeck.desktop.host-process", "8AQTYW5FKR", inherit)
                    else:
                        with self.assertRaisesRegex(ValueError, "effective entitlements"):
                            signature(Path("synthetic"), "com.arkdeck.desktop.host-process", "8AQTYW5FKR", inherit)


if __name__ == "__main__":
    unittest.main()
