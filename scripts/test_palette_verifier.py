#!/usr/bin/env python3
"""Mutation tests for the palette gate.

`verify_palette.py` exists because an unverifiable measurement rotted once
already. A gate that cannot fail rots the same way and is harder to notice, so
each case below breaks the shipped palette in one specific way and asserts the
gate rejects it.

Anchors are derived from the shipped source rather than transcribed, so
re-tuning the palette does not silently turn these into no-ops: a mutation that
can no longer be applied fails loudly instead of passing vacuously.

The repo copy is never modified. Every case runs against a temporary tree
holding the script, a mutated copy of the palette source, and the test file the
gate reads its upstream hash vectors from.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("verify_palette.py")
REPO_ROOT = SCRIPT.parent.parent
PALETTE_RELATIVE = Path("Sources/ArkTraceRendering/TimelineColorPalette.swift")
TESTS_RELATIVE = Path("Tests/ArkTraceRenderingTests/TimelinePaletteTests.swift")


def _load_verifier():
    spec = importlib.util.spec_from_file_location("verify_palette", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


VP = _load_verifier()


class PaletteVerifierTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.original = (REPO_ROOT / PALETTE_RELATIVE).read_text(encoding="utf-8")
        cls.tests_source = (REPO_ROOT / TESTS_RELATIVE).read_text(encoding="utf-8")
        cls.ring = VP.extract_func_colors(cls.original)
        cls.states = VP.extract_state_colors(cls.original)
        cls.grey = VP.extract_rgb_constant(cls.original, "greyColor")
        cls.unknown = VP.extract_rgb_constant(cls.original, "unknownStateColor")

    # -- plumbing ------------------------------------------------------------

    def run_against(self, palette_text: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            shutil.copy2(SCRIPT, root / "scripts" / SCRIPT.name)
            for relative, text in (
                (PALETTE_RELATIVE, palette_text),
                (TESTS_RELATIVE, self.tests_source),
            ):
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(text, encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(root / "scripts" / SCRIPT.name)],
                capture_output=True,
                text=True,
                check=False,
            )

    def mutate(self, old: str, new: str) -> str:
        self.assertEqual(
            self.original.count(old),
            1,
            f"mutation anchor {old!r} does not appear exactly once in the palette source; "
            "this case would otherwise pass without mutating anything",
        )
        return self.original.replace(old, new)

    def swift_rgb(self, colour: str) -> str:
        r, g, b = VP.parse_hex(colour)
        return f"TimelineColor(red: 0x{r:02X}, green: 0x{g:02X}, blue: 0x{b:02X})"

    def state_entry(self, key: str) -> str:
        """The shipped `"KEY": TimelineColor(...)` line, matched from source."""
        pattern = rf'"{re.escape(key)}": TimelineColor\(red: 0x[0-9A-Fa-f]+, '
        pattern += r"green: 0x[0-9A-Fa-f]+, blue: 0x[0-9A-Fa-f]+\)"
        found = re.findall(pattern, self.original)
        self.assertEqual(len(found), 1, f"expected one stateColors entry for {key!r}")
        return found[0]

    def assert_rejected(self, palette_text: str, because: str) -> None:
        self.assertNotEqual(
            palette_text, self.original, f"the {because} case did not mutate anything"
        )
        result = self.run_against(palette_text)
        self.assertNotEqual(
            result.returncode, 0, f"the gate accepted a palette that {because}"
        )

    # -- the shipped table has to pass, or every case below is vacuous -------

    def test_shipped_palette_passes(self) -> None:
        result = self.run_against(self.original)
        self.assertEqual(
            result.returncode, 0, f"the shipped palette must pass:\n{result.stderr}"
        )

    # -- visibility, on all four canvases ------------------------------------

    def test_rejects_a_fill_that_vanishes_on_the_light_canvas(self) -> None:
        self.assert_rejected(
            self.mutate(f'"{self.ring[0]}"', '"#f2f4f6"'), "is invisible on #FFFFFF"
        )

    def test_rejects_a_fill_that_vanishes_on_the_dark_canvas(self) -> None:
        self.assert_rejected(
            self.mutate(f'"{self.ring[8]}"', '"#12303a"'), "is invisible on #1E1E1E"
        )

    def test_rejects_a_fill_that_only_fails_on_the_striped_row(self) -> None:
        """The regression that produced the four-canvas rule.

        `#8b95a3` clears 3:1 against `#FFFFFF` at 3.03 and fails against the
        odd-row `#F4F5F5` at 2.78. A two-canvas gate reports this palette as
        clean, which is exactly what happened.
        """
        self.assert_rejected(
            self.mutate(f'"{self.ring[0]}"', '"#8b95a3"'),
            "clears #FFFFFF but fails the odd-row #F4F5F5",
        )

    def test_rejects_a_state_fill_that_vanishes(self) -> None:
        self.assert_rejected(
            self.mutate(self.state_entry("S"), f'"S": {self.swift_rgb("#1f2022")}'),
            "makes the most common thread state invisible on #1E1E1E",
        )

    # -- separability --------------------------------------------------------

    def test_rejects_two_near_identical_fills(self) -> None:
        r, g, b = VP.parse_hex(self.ring[0])
        near = VP.to_hex((r + 1, g, b))
        self.assert_rejected(
            self.mutate(f'"{self.ring[1]}"', f'"{near}"'),
            "holds two indistinguishable fills",
        )

    def test_rejects_an_alarm_that_reads_as_an_ordinary_slice(self) -> None:
        """Checking the catch-all only against `S` pins the wrong pair."""
        r, g, b = VP.parse_hex(self.ring[16])
        nearby = VP.to_hex((min(255, r + 12), max(0, g - 10), max(0, b - 10)))
        self.assert_rejected(
            self.mutate(
                f"unknownStateColor = {self.swift_rgb(self.unknown)}",
                f"unknownStateColor = {self.swift_rgb(nearby)}",
            ),
            "puts the alarm colour next to an identity fill",
        )

    # -- the no-identity neutral --------------------------------------------

    def test_rejects_a_saturated_no_identity_slot(self) -> None:
        self.assert_rejected(
            self.mutate(f'"{self.ring[5]}"', '"#a8256b"'),
            "paints an unidentifiable CPU slice a saturated colour",
        )

    def test_rejects_greycolor_drifting_from_the_no_identity_slot(self) -> None:
        self.assert_rejected(
            self.mutate(
                f"greyColor = {self.swift_rgb(self.grey)}",
                f"greyColor = {self.swift_rgb('#f0f0f0')}",
            ),
            "gives the two no-identity fallbacks different colours",
        )

    # -- upstream parity -----------------------------------------------------

    def test_rejects_a_broken_upstream_state_group(self) -> None:
        self.assert_rejected(
            self.mutate(
                self.state_entry("DK-IO"),
                f'"DK-IO": {self.swift_rgb(self.states["I"])}',
            ),
            "splits a group upstream's getStateColor keeps together",
        )

    def test_rejects_two_states_merged_onto_one_fill(self) -> None:
        """Dedup would otherwise make a merge vanish instead of fail."""
        self.assert_rejected(
            self.mutate(
                self.state_entry("Running"),
                f'"Running": {self.swift_rgb(self.states["S"])}',
            ),
            "merges two states upstream's chain keeps apart",
        )

    def test_rejects_a_missing_state(self) -> None:
        self.assert_rejected(
            self.mutate(f"        {self.state_entry('R-B')},\n", ""),
            "drops a state upstream's chain names",
        )

    def test_rejects_a_hash_port_that_disagrees_with_the_pinned_vectors(self) -> None:
        """The occupancy tiers are meaningless if the port is measuring itself."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            drifted = SCRIPT.read_text(encoding="utf-8").replace(
                "h = 0x011C_9DC5", "h = 0x011C_9DC6", 1
            )
            self.assertNotEqual(drifted, SCRIPT.read_text(encoding="utf-8"))
            (root / "scripts" / SCRIPT.name).write_text(drifted, encoding="utf-8")
            for relative, text in (
                (PALETTE_RELATIVE, self.original),
                (TESTS_RELATIVE, self.tests_source),
            ):
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(text, encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(root / "scripts" / SCRIPT.name)],
                capture_output=True,
                text=True,
                check=False,
            )
        self.assertNotEqual(
            result.returncode, 0, "a drifted hash port must fail the cross-check"
        )

    # -- semantics -----------------------------------------------------------

    def test_rejects_a_quiet_catch_all(self) -> None:
        self.assert_rejected(
            self.mutate(
                f"unknownStateColor = {self.swift_rgb(self.unknown)}",
                f"unknownStateColor = {self.swift_rgb('#8b8d90')}",
            ),
            "lets an unrecognised scheduler state blend into the wall",
        )

    # -- the gate must not be fooled by a partial parse -----------------------

    def test_survives_a_reformatted_state_literal(self) -> None:
        """Reformatting is not a defect; silently measuring half a table is."""
        entry = self.state_entry("R-B")
        body = entry[entry.index("(") + 1 : -1]
        result = self.run_against(
            self.mutate(entry, f'"R-B": TimelineColor(\n            {body}\n        )')
        )
        self.assertEqual(
            result.returncode,
            0,
            f"a reformatted literal must still parse in full:\n{result.stderr}",
        )

    def test_rejects_a_state_literal_it_cannot_fully_parse(self) -> None:
        entry = self.state_entry("R-B")
        self.assert_rejected(
            self.mutate(entry, entry.replace("red: 0x", "red: someConstant0x", 1)),
            "the gate could only parse part of, which would measure a partial table",
        )

    def test_rejects_a_state_entry_written_with_a_different_spelling(self) -> None:
        """`.init(...)` used to satisfy the count check while never being measured."""
        entry = self.state_entry("R-B")
        self.assert_rejected(
            self.mutate(
                f"        {entry},\n",
                f"        {entry},\n"
                f"        \"T\": .init(red: 0x22, green: 0x22, blue: 0x22),\n",
            ),
            "smuggles an unmeasured fill past the entry-count check",
        )

    def test_rejects_a_malformed_hex_literal(self) -> None:
        broken = self.ring[3][:-1]
        self.assert_rejected(
            self.mutate(f'"{self.ring[3]}"', f'"{broken}"'),
            "TimelineColor(hex:) would drop, shifting every slot above it",
        )

    def test_rejects_a_missing_symbol(self) -> None:
        self.assert_rejected(
            self.mutate("public static let funcColorLiterals", "public static let renamedTable"),
            "no longer declares the table the gate measures",
        )

    def test_reports_a_wrong_sized_table_without_crashing(self) -> None:
        result = self.run_against(
            self.mutate(f'"{self.ring[19]}",\n', f'"{self.ring[19]}",\n        "#7a6f9c",\n')
        )
        self.assertNotEqual(result.returncode, 0, "a 21-entry table must be rejected")
        self.assertNotIn(
            "Traceback",
            result.stderr,
            "the operator must get the diagnostic, not a stack trace",
        )
        self.assertIn("20 entries", result.stderr)

    # -- determinism ---------------------------------------------------------

    def test_occupancy_corpus_is_reproducible(self) -> None:
        """The tier thresholds are measured, so the corpus must not drift."""
        first = self.run_against(self.original)
        second = self.run_against(self.original)
        self.assertEqual(first.stdout, second.stdout)


if __name__ == "__main__":
    unittest.main()
