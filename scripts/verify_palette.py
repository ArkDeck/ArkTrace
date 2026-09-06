#!/usr/bin/env python3
"""Offline gate for the timeline palette.

Why this exists
---------------
Between 2026-08-19 and 2026-08-24 `AT-RENDER-008` and `docs/DESIGN.md` §13.5
carried inline measurements of the twenty-entry palette -- OKLab ΔE, colour
vision deficiency, contrast -- produced by a tool that was never committed.
Nothing re-ran them, so nobody noticed that the headline figure ("worst
adjacent pair ΔE 30, 15.6 under deuteranopia") measured *slot* adjacency.
Slot adjacency has no visual meaning: `hashFunc` scatters identities, so any
two slots can end up abutting on screen. Measured over all 190 pairs the same
table scored 3.8 and 0.4.

This script is that tool, committed. It reads the shipped Swift source as the
single source of truth -- no colour value is duplicated here -- and fails the
build when a measured property of the shipped tables stops holding.

What it does *not* do, so the docs do not over-claim again: it cannot check
figures about tables that no longer exist in the source (the "before" columns
in DESIGN §13.5 are history, not invariants), and it measures the palette, not
the renderer. `--report` prints everything it derives; anything quoted in prose
that is not in that output is unverified by construction.

It needs no toolchain, no parser binary and no network, so it belongs to the
offline `contracts` lane in `.github/workflows/ci.yml`.

Colour science
--------------
* OKLab / OKLCh: Björn Ottosson's published matrices. ΔE is Euclidean distance
  in OKLab scaled by 100, which is the convention the DESIGN §13.5 figures
  were quoted in (it reproduces the historical "ΔE 8.5" and "ΔE 30" exactly).
* Contrast: WCAG 2.1 relative luminance.
* Colour vision deficiency: Machado, Oliveira & Fernandes (2009) severity-1.0
  matrices, applied in linear RGB.

Canvas references are the values AppKit actually resolves on macOS, verified
with `NSAppearance.performAsCurrentDrawingAppearance`. There are **four**, not
two, because `drawTracks` stripes alternate rows with
`NSColor.alternatingContentBackgroundColors`:

    Aqua      even rows #FFFFFF   odd rows #F4F5F5
    DarkAqua  even rows #1E1E1E   odd rows #292929   (white at 4.7% over #1E1E1E)

A fill has to clear 3:1 against all four, because which row a track lands on is
an accident of ordering. Missing the odd-row pair is not hypothetical: the
striping and the palette landed in the same change, and the first cut of that
change put six fills between 2.78:1 and 2.96:1 against `#F4F5F5` -- including
the two most common thread states -- while this gate reported 0/20 because it
only knew about `#FFFFFF`.

Usage
-----
    python3 scripts/verify_palette.py [--report]

`--report` prints the full measurement table even when everything passes.
"""

from __future__ import annotations

import argparse
import itertools
import math
import re
import string
import struct
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PALETTE_SOURCE = REPO_ROOT / "Sources" / "ArkTraceRendering" / "TimelineColorPalette.swift"
PALETTE_TESTS = (
    REPO_ROOT / "Tests" / "ArkTraceRenderingTests" / "TimelinePaletteTests.swift"
)

# Every canvas a fill can land on. `drawTracks` alternates row backgrounds, so
# a track's background depends on its index -- there is no single canvas.
CANVASES = (
    ("Aqua even rows", "#ffffff"),
    ("Aqua odd rows", "#f4f5f5"),
    ("DarkAqua even rows", "#1e1e1e"),
    ("DarkAqua odd rows", "#292929"),
)

# The number of distinct fills upstream's `getStateColor` chain implies: D-NIO,
# D-IO, R, R-B, I, Running, S. Pinned so that *merging* two states -- which
# dedup would otherwise hide from every measurement below -- fails loudly.
UPSTREAM_STATE_FILL_COUNT = 7

# Slot occupancy is a property of upstream's hash, not of the table, so it is
# measured rather than declared. These are the tiers the table is designed
# around; `measure_occupancy` proves the split still looks like this.
TIER_A = (0, 4, 8, 12, 16)
TIER_B = (2, 6, 10, 14, 18)

# `hash("0", modulus: 20)`, i.e. where a CPU slice with neither pid nor tid
# lands. Asserted rather than hardcoded blindly -- see `check_palette`.
NO_IDENTITY_SLOT = 5


# --------------------------------------------------------------------------
# colour maths
# --------------------------------------------------------------------------


def parse_hex(value: str) -> tuple[int, int, int]:
    digits = value.lstrip("#")
    if len(digits) == 3:
        digits = "".join(c * 2 for c in digits)
    if len(digits) != 6:
        raise ValueError(f"not a 6-digit hex colour: {value!r}")
    return tuple(int(digits[i : i + 2], 16) for i in (0, 2, 4))  # type: ignore[return-value]


def to_hex(rgb: tuple[float, float, float]) -> str:
    return "#%02x%02x%02x" % tuple(max(0, min(255, round(c))) for c in rgb)


def srgb_to_linear(channel: float) -> float:
    c = channel / 255
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def linear_to_srgb(channel: float) -> float:
    c = max(0.0, min(1.0, channel))
    v = 12.92 * c if c <= 0.0031308 else 1.055 * (c ** (1 / 2.4)) - 0.055
    return v * 255


def linear(value: str) -> tuple[float, float, float]:
    r, g, b = parse_hex(value)
    return srgb_to_linear(r), srgb_to_linear(g), srgb_to_linear(b)


def relative_luminance(value: str) -> float:
    r, g, b = linear(value)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a: str, b: str) -> float:
    la, lb = relative_luminance(a), relative_luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def oklab(value: str) -> tuple[float, float, float]:
    r, g, b = linear(value)
    l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    l_, m_, s_ = (math.copysign(abs(v) ** (1 / 3), v) for v in (l, m, s))
    return (
        0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
        1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
        0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_,
    )


def oklch(value: str) -> tuple[float, float, float]:
    lightness, a, b = oklab(value)
    return lightness, math.hypot(a, b), math.degrees(math.atan2(b, a)) % 360


def delta_e(a: str, b: str) -> float:
    return 100 * math.dist(oklab(a), oklab(b))


CVD_MATRICES = {
    "protan": ((0.152286, 1.052583, -0.204868), (0.114503, 0.786281, 0.099216), (-0.003882, -0.048116, 1.051998)),
    "deutan": ((0.367322, 0.860646, -0.227968), (0.280085, 0.672501, 0.047413), (-0.011820, 0.042940, 0.968881)),
    "tritan": ((1.255528, -0.076749, -0.178779), (-0.078411, 0.930809, 0.147602), (0.004733, 0.691367, 0.303900)),
}


def simulate(value: str, kind: str) -> str:
    r, g, b = linear(value)
    m = CVD_MATRICES[kind]
    return to_hex(tuple(linear_to_srgb(row[0] * r + row[1] * g + row[2] * b) for row in m))


def label_luma(value: str) -> float:
    """`TimelineColor.preferredLabelColor`'s gray level, byte for byte."""
    r, g, b = parse_hex(value)
    return r * 0.299 + g * 0.587 + b * 0.114


def label_ink(value: str) -> str:
    return "#000000" if label_luma(value) >= 100 else "#ffffff"


# --------------------------------------------------------------------------
# upstream hash, ported from TimelinePalette.fnvHash
# --------------------------------------------------------------------------


def _int32(value: int) -> int:
    """JavaScript's `ToInt32`, which is also Swift's `Int32(truncatingIfNeeded:)`."""
    return ((value + 0x8000_0000) & 0xFFFF_FFFF) - 0x8000_0000


def fnv_hash(units) -> int:
    h = 0x011C_9DC5
    for unit in units:
        h = _int32(h ^ unit)
        # JavaScript `Number` multiply, then ToInt32 -- the product needs up to
        # 55 bits and a double carries 53, so the low bits round away first.
        # `float()` is what reproduces that rounding; dropping it would give a
        # textbook 32-bit FNV-1a, which diverges on almost every real name.
        h = _int32(int(float(h) * 16777619.0) & 0xFFFF_FFFF)
    return h


def utf16_units(name: str) -> list[int]:
    """Swift iterates `value.utf16`, so an astral character is two units.

    Iterating code points instead silently agrees on every ASCII name and
    diverges the moment a slice name carries an emoji or any other non-BMP
    character. `check_hash_port` is what caught that here.
    """
    encoded = name.encode("utf-16-le")
    return list(struct.unpack(f"<{len(encoded) // 2}H", encoded))


def hash_slot(name: str, modulus: int = 20) -> int:
    return abs(fnv_hash(utf16_units(name))) % modulus


def hash_func_slot(name: str, depth: int = 0, modulus: int = 20) -> int:
    # Upstream strips ASCII digits only, by code unit -- not `str.isdigit()`,
    # which is true for every Unicode decimal digit.
    stripped = [u for u in utf16_units(name) if not 0x30 <= u <= 0x39]
    return (abs(fnv_hash(stripped)) + max(0, depth)) % modulus


# --------------------------------------------------------------------------
# reading the shipped table
# --------------------------------------------------------------------------


def read_source() -> str:
    if not PALETTE_SOURCE.is_file():
        fail_hard(f"palette source is missing: {PALETTE_SOURCE}")
    return PALETTE_SOURCE.read_text(encoding="utf-8")


def extract_func_colors(source: str) -> list[str]:
    match = re.search(
        r"public static let funcColorLiterals: \[String\] = \[(.*?)\]", source, re.S
    )
    if not match:
        fail_hard("could not find `funcColorLiterals` in the palette source")
    body = match.group(1)
    malformed = [
        v for v in re.findall(r'"(#[0-9a-fA-F]+)"', body) if len(v) - 1 not in (3, 6)
    ]
    if malformed:
        # Swift's `TimelineColor(hex:)` rejects these too, and `compactMap`
        # then drops them silently -- the table shortens and every slot above
        # the typo shifts, which is an upstream-parity break. Name it here
        # rather than dying in `parse_hex`.
        fail_hard(
            "funcColorLiterals holds malformed hex literals "
            f"{malformed}; TimelineColor(hex:) would drop them and shift every slot above"
        )
    values = re.findall(r'"(#[0-9a-fA-F]{3,6})"', body)
    # A reformatted literal that the pattern only half-matches must fail here
    # rather than quietly hand a short table to a gate that then passes it.
    quoted = body.count('"') // 2
    if len(values) != quoted:
        fail_hard(
            f"funcColorLiterals holds {quoted} quoted strings but only {len(values)} parsed "
            "as colours; the literal shape changed and this gate would be measuring a "
            "partial table"
        )
    return [v.lower() for v in values]


def extract_rgb_constant(source: str, name: str) -> str:
    match = re.search(
        rf"let {re.escape(name)} = TimelineColor\(\s*red: (0x[0-9A-Fa-f]+),\s*"
        rf"green: (0x[0-9A-Fa-f]+),\s*blue: (0x[0-9A-Fa-f]+)\s*\)",
        source,
    )
    if not match:
        fail_hard(f"could not find the `{name}` constant in the palette source")
    return to_hex(tuple(int(g, 16) for g in match.groups()))


def extract_state_colors(source: str) -> dict[str, str]:
    match = re.search(
        r"static let stateColors: \[String: TimelineColor\] = \[(.*?)\n    \]", source, re.S
    )
    if not match:
        fail_hard("could not find `stateColors` in the palette source")
    body = match.group(1)
    entries = re.findall(
        r'"([^"]+)":\s*TimelineColor\(\s*red: (0x[0-9A-Fa-f]+),\s*'
        r"green: (0x[0-9A-Fa-f]+),\s*blue: (0x[0-9A-Fa-f]+)\s*\)",
        body,
    )
    # Same failure mode as `extract_func_colors`, and worse here: a silently
    # partial state table would let an invisible fill through the gate. Count
    # the *keys*, not the constructor spelling -- an entry written `.init(...)`
    # would match a `TimelineColor(` count while never reaching a measurement.
    declared = len(re.findall(r'"[^"]+":', body))
    if len(entries) != declared or not entries:
        fail_hard(
            f"stateColors declares {declared} fills but only {len(entries)} parsed; "
            "the literal shape changed and this gate would be measuring a partial table"
        )
    return {key: to_hex((int(r, 16), int(g, 16), int(b, 16))) for key, r, g, b in entries}


def extract_jank_colors(source: str) -> list[str]:
    """The jank table is reported but not gated; it is still read strictly.

    Not gating it is a decision (its values are upstream's and unchanged, and
    two of them are below 3:1 -- recorded as outstanding in DESIGN §13.5).
    Failing to *find* it is not a decision, so a rename fails here like every
    other symbol rather than quietly deleting the reporting block.
    """
    match = re.search(r"static let jankColors: \[TimelineColor\] = \[(.*?)\]", source, re.S)
    if not match:
        fail_hard("could not find `jankColors` in the palette source")
    return [v.lower() for v in re.findall(r'"(#[0-9a-fA-F]{6})"', match.group(1))]


def extract_hash_vectors() -> list[tuple[str, int, int]]:
    """`(name, hash, hashFunc)` triples pinned in `TimelinePaletteTests.swift`.

    These were produced by running upstream's `ColorUtils` under Node. Reading
    them here is what makes the occupancy measurement below an assertion about
    the *shipped* hash rather than about this file's re-implementation of it:
    if the Swift hash changes, the Swift test fails; if this port drifts from
    it, `check_hash_port` fails. Without the cross-check, every occupancy
    figure would be self-confirming.
    """
    if not PALETTE_TESTS.is_file():
        fail_hard(f"palette tests are missing: {PALETTE_TESTS}")
    source = PALETTE_TESTS.read_text(encoding="utf-8")
    match = re.search(
        r"hashVectors: \[\(name: String, hash: Int, hashFunc: Int\)\] = \[(.*?)\n    \]",
        source,
        re.S,
    )
    if not match:
        fail_hard("could not find `hashVectors` in TimelinePaletteTests.swift")
    vectors = [
        (name, int(h), int(hf))
        for name, h, hf in re.findall(
            r'\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*\)', match.group(1)
        )
    ]
    # The literal also holds one computed name (`String(repeating:)`) that this
    # pattern cannot see; the floor is what makes a reformat loud.
    if len(vectors) < 20:
        fail_hard(
            f"only {len(vectors)} hash vectors parsed from TimelinePaletteTests.swift; "
            "the literal shape changed and the hash cross-check would be measuring almost nothing"
        )
    return vectors


# --------------------------------------------------------------------------
# gate plumbing
# --------------------------------------------------------------------------

FAILURES: list[str] = []
NOTES: list[str] = []


def fail_hard(message: str) -> None:
    print(f"palette verification failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def require(condition: bool, message: str) -> None:
    if not condition:
        FAILURES.append(message)


def note(message: str) -> None:
    NOTES.append(message)


# --------------------------------------------------------------------------
# measurements
# --------------------------------------------------------------------------


def measure_occupancy(sample: int = 20_000) -> dict[int, float]:
    """Share of identities landing in each slot, through the shipped hash.

    The corpus comes from an explicit 64-bit LCG rather than `random`, so it is
    byte-identical on every interpreter and every runner. `random.choice`'s
    internals are not part of Python's compatibility promise, and a gate whose
    corpus can shift under a toolchain upgrade is a gate that can flip without
    anyone touching the palette.
    """
    state = 0x2026_0824_0000_0001
    alphabet = string.ascii_letters + "_:.#" + string.digits

    def next_value(bound: int) -> int:
        nonlocal state
        state = (state * 6364136223846793005 + 1442695040888963407) & 0xFFFF_FFFF_FFFF_FFFF
        return (state >> 33) % bound

    counts = {slot: 0 for slot in range(20)}
    for _ in range(sample):
        length = 5 + next_value(40)
        name = "".join(alphabet[next_value(len(alphabet))] for _ in range(length))
        counts[hash_func_slot(name)] += 1
    for pid in range(1, 20_000):
        counts[hash_slot(str(pid))] += 1
    total = sum(counts.values())
    return {slot: count / total for slot, count in counts.items()}


def min_pairwise(colors, transform=lambda c: c) -> tuple[float, str, str]:
    best = (math.inf, "", "")
    for a, b in itertools.combinations(colors, 2):
        d = delta_e(transform(a), transform(b))
        if d < best[0]:
            best = (d, a, b)
    return best


def check_hash_port(vectors: list[tuple[str, int, int]]) -> None:
    """Tie this file's hash to the vectors the Swift side pins.

    Every occupancy figure below comes out of `hash_func_slot`. If that is only
    ever compared against itself, "slots 0/4/8/12/16 carry 74.3%" is a fact
    about this script, not about ArkTrace.
    """
    wrong = [
        (name, expected_hash, hash_slot(name), expected_func, hash_func_slot(name))
        for name, expected_hash, expected_func in vectors
        if hash_slot(name) != expected_hash or hash_func_slot(name) != expected_func
    ]
    require(
        not wrong,
        f"{len(wrong)} of {len(vectors)} upstream hash vectors disagree with this "
        "script's port, so every occupancy figure below is measuring the wrong hash: "
        + "; ".join(
            f"{name!r} hash {got}!={want} hashFunc {gotf}!={wantf}"
            for name, want, got, wantf, gotf in wrong[:4]
        ),
    )
    note(f"hash port agrees with all {len(vectors)} vectors pinned in TimelinePaletteTests")


def check_palette(palette: list[str], occupancy: dict[int, float], grey: str) -> None:
    require(len(palette) == 20, f"the palette must have 20 entries, found {len(palette)}")
    if len(palette) != 20:
        return

    # --- the hash still reaches the table the way the tiering assumes -------
    tier_a_share = sum(occupancy[s] for s in TIER_A)
    tier_b_share = sum(occupancy[s] for s in TIER_B)
    require(
        tier_a_share >= 0.70,
        f"slots {TIER_A} carry {tier_a_share:.1%} of identities, expected >= 70%; "
        "the hash changed and the table's tiering no longer matches how it is reached",
    )
    require(
        hash_slot("0") == NO_IDENTITY_SLOT,
        f'hash("0") is now slot {hash_slot("0")}, not {NO_IDENTITY_SLOT}; '
        "the neutral has to move with it",
    )

    tier_a = [palette[s] for s in TIER_A]

    # --- tier A is the timeline's colour scheme; it has to be a family -----
    lightnesses = [oklch(c)[0] for c in tier_a]
    spread = max(lightnesses) - min(lightnesses)
    require(spread <= 0.06, f"tier A lightness spread is {spread:.3f}, must be <= 0.060")
    tier_a_chroma = sum(oklch(c)[1] for c in tier_a) / len(tier_a)
    require(
        tier_a_chroma <= 0.105,
        f"tier A mean chroma is {tier_a_chroma:.3f}, must be <= 0.105",
    )
    require(
        len({label_ink(c) for c in tier_a}) == 1,
        "tier A must take one label ink; it is 74% of the canvas and the ink must not flip",
    )

    # --- what the eye actually receives, weighted by how often it is used ---
    weighted = sum(occupancy[s] * oklch(palette[s])[1] for s in range(20))
    require(
        weighted <= 0.105,
        f"occupancy-weighted chroma is {weighted:.3f}, must be <= 0.105",
    )

    # --- separability, over the pairs that can actually abut ---------------
    worst, a, b = min_pairwise(palette)
    require(worst >= 5.0, f"closest pair is ΔE {worst:.1f} ({a} / {b}), must be >= 5.0")

    # --- visibility on every row, in both appearances, from one table ------
    for name, canvas in CANVASES:
        weak = [
            (i, c, contrast(c, canvas))
            for i, c in enumerate(palette)
            if contrast(c, canvas) < 3.0
        ]
        require(
            not weak,
            f"{len(weak)} palette entries fall under 3:1 against {name} ({canvas}): "
            + ", ".join(f"slot {i} {c} at {r:.2f}:1" for i, c, r in weak),
        )

    # --- label ink is a third channel; it must not strobe ------------------
    inks = [label_ink(c) for c in palette]
    flips = sum(1 for i in range(len(inks) - 1) if inks[i] != inks[i + 1])
    require(flips <= 4, f"label ink flips on {flips} of 19 slot steps, must be <= 4")
    for i, c in enumerate(palette):
        ratio = contrast(c, label_ink(c))
        require(ratio >= 4.5, f"slot {i} {c} gives its label only {ratio:.2f}:1, must be >= 4.5")

    # --- the "no identity" fills mean what they look like ------------------
    neutral = palette[NO_IDENTITY_SLOT]
    neutral_chroma = oklch(neutral)[1]
    require(
        neutral_chroma <= 0.02,
        f"slot {NO_IDENTITY_SLOT} is the no-identity fallback and must read as neutral; "
        f"chroma is {neutral_chroma:.3f}, must be <= 0.020",
    )
    require(
        grey == neutral,
        f"greyColor ({grey}) and the no-identity slot ({neutral}) both mean "
        '"nobody knows whose this is" and must be the same colour',
    )

    note(f"tier A ({', '.join(str(s) for s in TIER_A)}): {tier_a_share:.1%} of identities, "
         f"chroma {tier_a_chroma:.3f}, lightness spread {spread:.3f}")
    note(f"tier B ({', '.join(str(s) for s in TIER_B)}): {tier_b_share:.1%} of identities")
    note(f"occupancy-weighted chroma {weighted:.3f}; closest pair ΔE {worst:.1f}; "
         f"label-ink flips {flips}/19")


def check_states(states: dict[str, str], unknown: str, palette: list[str]) -> None:
    # Upstream's grouping is the parity fact. Break it and colours stop
    # agreeing with SmartPerf Host even though the values are ours.
    groups = [("D-NIO", "DK-NIO"), ("D-IO", "DK-IO", "D", "DK"), ("R", "R+")]
    for group in groups:
        present = [k for k in group if k in states]
        require(
            len(present) == len(group),
            f"upstream state group {group} is incomplete in stateColors: have {present}",
        )
        if len(present) == len(group):
            require(
                len({states[k] for k in group}) == 1,
                f"upstream groups {group} into one fill; stateColors gives them "
                + ", ".join(f"{k}={states[k]}" for k in group),
            )
    for required_key in ("Running", "S", "I", "R-B"):
        require(required_key in states, f"stateColors is missing upstream's `{required_key}`")

    # Dedup below hides a *merge*: give two states one fill and the pair simply
    # stops existing instead of failing a ΔE check. Upstream's chain fixes how
    # many distinct fills there are, so pin that first.
    require(
        len(set(states.values())) == UPSTREAM_STATE_FILL_COUNT,
        f"stateColors resolves to {len(set(states.values()))} distinct fills, expected "
        f"{UPSTREAM_STATE_FILL_COUNT}; upstream's chain keeps these states apart and two "
        "of them have been merged",
    )

    values = sorted(set(states.values()) | {unknown})
    for name, canvas in CANVASES:
        weak = [(v, contrast(v, canvas)) for v in values if contrast(v, canvas) < 3.0]
        require(
            not weak,
            f"{len(weak)} state fills fall under 3:1 against {name} ({canvas}): "
            + ", ".join(f"{v} at {r:.2f}:1" for v, r in weak),
        )
    require(
        len({label_ink(v) for v in values}) == 1,
        "the state table must take one label ink across all of its fills",
    )
    for value in values:
        ratio = contrast(value, label_ink(value))
        require(
            ratio >= 4.5,
            f"state fill {value} gives its label only {ratio:.2f}:1, must be >= 4.5",
        )

    worst, a, b = min_pairwise(values)
    require(worst >= 5.0, f"closest state pair is ΔE {worst:.1f} ({a} / {b}), must be >= 5.0")

    # State lanes and slice lanes alternate row by row, so the two tables have
    # to stay tellable apart even though neither is loud any more.
    cross = min(((delta_e(v, p), v, p) for v in values for p in palette), default=(math.inf, "", ""))
    require(
        cross[0] >= 4.0,
        f"state fill {cross[1]} is only ΔE {cross[0]:.1f} from palette entry {cross[2]}; "
        "state and slice lanes alternate and must stay distinguishable (>= 4.0)",
    )

    # The catch-all is the one fill allowed to shout, and it has to stand clear
    # of *everything* -- checking it only against `S` pins the one pair that was
    # never going to collide, while it sits in the crowded warm arc with a
    # dozen identity fills.
    everything = {v: oklch(v)[1] for v in values}
    everything.update({p: oklch(p)[1] for p in palette})
    require(
        everything[unknown] == max(everything.values()),
        f"the unknown-state fill {unknown} (chroma {everything[unknown]:.3f}) must be the "
        "most chromatic entry in either table; an unrecognised state is a data problem",
    )
    alarm = min(
        ((delta_e(unknown, other), other) for other in everything if other != unknown),
        default=(math.inf, ""),
    )
    require(
        alarm[0] >= 7.0,
        f"the unknown-state fill {unknown} is only ΔE {alarm[0]:.1f} from {alarm[1]}; "
        "an alarm colour that reads as an ordinary slice is not an alarm (>= 7.0)",
    )
    if "S" in states:
        separation = delta_e(states["S"], unknown)
        require(
            separation >= 15.0,
            f"sleeping ({states['S']}) and unknown ({unknown}) are only ΔE {separation:.1f} "
            "apart, must be >= 15.0",
        )

    # Hue crowding. Every fill sits in one narrow luminance band, so hue is
    # doing nearly all the work; piling a third of the table into one arc is
    # how a palette reads as a single smear even when each pair clears ΔE.
    arcs: dict[int, int] = {}
    for value in list(everything):
        if oklch(value)[1] > 0.03:
            arcs[int(oklch(value)[2]) // 45] = arcs.get(int(oklch(value)[2]) // 45, 0) + 1
    worst_arc = max(arcs.items(), key=lambda kv: kv[1], default=(0, 0))
    require(
        worst_arc[1] <= 7,
        f"{worst_arc[1]} chromatic fills sit in the {worst_arc[0] * 45}-"
        f"{worst_arc[0] * 45 + 44}° hue arc, must be <= 7; the tables are crowding one hue",
    )

    note(f"state table: {len(values)} distinct fills, closest pair ΔE {worst:.1f}, "
         f"closest to the identity palette ΔE {cross[0]:.1f}")


def report(palette: list[str], states: dict[str, str], unknown: str,
           jank: list[str], occupancy: dict[int, float]) -> None:
    print("\nIdentity palette (funcColorLiterals)")
    print(f"  {'slot':>4} {'hex':>9} {'share':>7} {'L':>6} {'C':>6} {'H':>6} "
          f"{'aqua':>7} {'aqua/2':>7} {'dark':>7} {'dark/2':>7} {'ink':>6}")
    for i, colour in enumerate(palette):
        lightness, chroma, hue = oklch(colour)
        tier = "A" if i in TIER_A else ("B" if i in TIER_B else "C")
        print(f"  {i:>3}{tier} {colour:>9} {occupancy.get(i, 0.0):>6.1%} {lightness:>6.3f} {chroma:>6.3f} "
              f"{hue:>6.1f} " + " ".join(f"{contrast(colour, cv):>7.2f}" for _, cv in CANVASES)
              + f" {'black' if label_ink(colour) == '#000000' else 'white':>6}")

    print("\nThread states (stateColors)")
    seen: dict[str, list[str]] = {}
    for key, value in states.items():
        seen.setdefault(value, []).append(key)
    seen.setdefault(unknown, []).append("catch-all")
    for value, keys in sorted(seen.items(), key=lambda kv: oklch(kv[0])[1]):
        lightness, chroma, _ = oklch(value)
        print(f"  {value}  L {lightness:.3f}  C {chroma:.3f}  "
              + " ".join(f"{contrast(value, cv):5.2f}" for _, cv in CANVASES)
              + f"  {', '.join(sorted(keys))}")

    print("\nColour-vision deficiency (informational, not gated)")
    print("  Twenty identity colours cannot be made dichromat-distinct at any chroma; "
          "AT-APP-011")
    print("  requires colour never to be the only channel, which is how this is answered.")
    for kind in ("protan", "deutan", "tritan"):
        worst, a, b = min_pairwise(palette, lambda c, k=kind: simulate(c, k))
        print(f"  {kind:>7}: closest palette pair ΔE {worst:5.1f}  ({a} / {b})")

    if jank:
        print("\nJank table (upstream values, NOT gated -- outstanding, see docs/DESIGN.md §13.5)")
        for value in jank[:4]:
            print(f"  {value}  C {oklch(value)[1]:.3f}  "
                  + " ".join(f"{contrast(value, cv):5.2f}" for _, cv in CANVASES))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", action="store_true", help="print the full measurement table")
    args = parser.parse_args()

    source = read_source()
    palette = extract_func_colors(source)
    states = extract_state_colors(source)
    unknown = extract_rgb_constant(source, "unknownStateColor")
    grey = extract_rgb_constant(source, "greyColor")
    jank = extract_jank_colors(source)
    occupancy = measure_occupancy()

    check_hash_port(extract_hash_vectors())
    check_palette(palette, occupancy, grey)
    check_states(states, unknown, palette)

    if args.report or FAILURES:
        report(palette, states, unknown, jank, occupancy)

    print()
    for line in NOTES:
        print(f"  {line}")

    if FAILURES:
        print(f"\npalette verification failed ({len(FAILURES)} problem"
              f"{'' if len(FAILURES) == 1 else 's'}):", file=sys.stderr)
        for problem in FAILURES:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    print(f"\npalette verification passed: {len(palette)} identity fills, "
          f"{len(set(states.values())) + 1} state fills, {len(CANVASES)} canvases.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
