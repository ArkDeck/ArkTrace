# ArkTrace Third-Party Notices

ArkTrace itself is licensed under the MIT License; the exact ArkTrace license
is distributed separately as `LICENSE`. The distributed macOS App and CLI
bundle the pinned OpenHarmony TraceStreamer executable. Its conservative
source-closure inventory is machine-readable at
`ThirdParty/TraceStreamer/license-inventory.json`; the exact corresponding
license texts are under `ThirdParty/TraceStreamer/LICENSES/`.

The shipped code includes components under Apache-2.0, MulanPSL-2.0,
bzip2-1.0.6, MIT, BSD-3-Clause, the zlib license, and SQLite's public-domain
dedication. The inventory also preserves notices for build-only inputs and
disabled plugins, including libbpf and LLVM, so a future plugin change cannot
silently escape review.

GN and Ninja are SHA-locked build tools and are not distributed with ArkTrace.
Their exact artifact identities and license texts are included in the same
inventory so the reproducible build toolchain is auditable as well.

No GPL/LGPL-only plugin is enabled in the ArkTrace TraceStreamer recipe.
`hiperf`, `ebpf`, and `native_hook` are excluded by the locked plugin list.
The profiler repository's shipped subset is Apache-2.0; its separately marked
kernel-mode eBPF sources are not part of this binary.

Source repositories and exact revisions are recorded in
`ThirdParty/TraceStreamer/source-lock.json`. Rebuild and source retrieval
instructions are in `docs/TRACE_STREAMER.md`; those HTTPS repositories are the
source offer for this distribution.

## Ported SmartPerf Host timeline palette

`Sources/ArkTraceRendering/TimelineColorPalette.swift` is a Swift port of the
timeline color logic from the same upstream repository, taken at the revision
pinned in `ThirdParty/TraceStreamer/source-lock.json`
(`447a0a49a7b3b914d6e9bd00648ba5a340f6fbf6`), which is Apache-2.0. The port
covers `ColorUtils.FUNC_COLOR_B`, `ColorUtils.JANK_COLOR`, `ColorUtils.hash`,
`ColorUtils.hashFunc`,
`ColorUtils.colorForThread` / `colorForTid` / `colorForName`,
`ColorUtils.funcTextColor` and `Utils.getStateColor` from
`ide/src/trace/component/trace/base/`. It exists so a slice keeps the same
color in ArkTrace as in SmartPerf Host, and it is behavior-compatible by
design — see `docs/DESIGN.md` §13.5 and the parity vectors in
`Tests/ArkTraceRenderingTests/TimelinePaletteTests.swift`.

This is ArkTrace's only port of upstream *application* code; everything else
reuses the upstream parser as a pinned executable rather than as source. The
Apache-2.0 text already ships under `ThirdParty/TraceStreamer/LICENSES/` for
the bundled parser and covers this file as well.
