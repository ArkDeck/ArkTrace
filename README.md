<img src="Apps/ArkTraceApp/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" alt="ArkTrace" width="128" height="128">

# ArkTrace

[![CI](https://github.com/ArkDeck/ArkTrace/actions/workflows/ci.yml/badge.svg)](https://github.com/ArkDeck/ArkTrace/actions/workflows/ci.yml)
[![Swift](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)](Package.swift)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20·%20Apple%20silicon-blue?logo=apple)](docs/APP_DISTRIBUTION.md)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

**English** | [简体中文](README.zh-CN.md)

**Native macOS trace workbench for OpenHarmony** — one core that serves both humans, through a native timeline viewer, and AI agents, through a deterministic CLI.

ArkTrace captures traces from an explicitly selected OpenHarmony device or opens existing files, then reuses the pinned TraceStreamer to parse `.htrace` / `.ftrace` / `.systrace` data into a local SQLite database:

- **ArkTrace.app** — a SwiftUI + CoreGraphics native timeline viewer: CPU / thread-state / named-slice / counter / frame tracks grouped by process, with call-depth rows, zoom, pan, search, range selection, timeline flags and marks, and an inspector with range analysis.
- **Device capture** — a native, cancellable HDC workflow with App responsiveness, CPU scheduling and System overview presets; captured files are validated, saved locally and opened automatically.
- **`arktrace` CLI** — typed, bounded, versioned JSON queries and analysis built for agents: `doctor`, `inspect`, `summary`, `processes`, `threads`, `query`, `context`, `analyze`, plus a fail-closed `licenses` command.
- **ArkDeck integration** — a host-only Trace Analysis Engine inside [ArkDeck](https://github.com/ArkDeck)'s automated debugging loop, with zero device capability by design.

## Highlights

- **Deterministic and agent-friendly.** Machine JSON 1.0 emitted as a single document on stdout, typed errors with stable exit codes, and explicit row / event / byte / deadline budgets — no raw SQL, no unbounded output.
- **Local and private.** Everything runs on your Mac. Parsed traces live in a content-addressed local cache; `--no-cache` switches to a session-owned ephemeral database.
- **Reproducible parser.** The bundled TraceStreamer is pinned to an exact upstream revision with a byte-reproducible build recipe and a fully tracked license inventory.
- **Evidence-driven releases.** Every phase ships behind fail-closed verification gates, closed with real-device (DAYU 200) evidence rather than claims.
- **Reads a trace the way SmartPerf Host does.** Slice colours, call-depth nesting, jank tagging and the navigation keys follow the pinned upstream, so the same slice looks and reads the same in either tool — and each of those claims is an assertion in `scripts/test_phase7.sh`, not a promise.

## Requirements

- Apple silicon Mac running macOS 26 or later
- Swift 6.3 toolchain / Xcode 26.6 (Xcode for building the app)
- OpenHarmony SDK `hdc` and a connected device with `hiprofiler_cmd` (capture only)
- `jq` — ships with macOS 15+
- Network access the first time you build the pinned TraceStreamer

## Quick start

### 1. Build the pinned parser

The TraceStreamer binary is a locally built artifact excluded from Git — cloning alone is not enough:

```bash
scripts/build_trace_streamer.sh
```

This produces `ThirdParty/TraceStreamer/macx/trace_streamer` and its identity manifest. Pinned revision and build recipe: [docs/TRACE_STREAMER.md](docs/TRACE_STREAMER.md).

### 2. Build and test

```bash
swift build -c release --product arktrace
swift test
```

For fast day-to-day iteration across branches and worktrees, use the stable
cache runners. They reuse one content-verified source mirror and shared build,
dependency and module caches; unchanged source is not recompiled:

```bash
sh scripts/run-swiftpm.sh build
sh scripts/run-swiftpm.sh test
sh scripts/run-xcodebuild.sh
```

### 3. Query a trace from the CLI

A small sample trace ships in the repository, so this works out of the box:

```bash
PARSER="$PWD/ThirdParty/TraceStreamer/macx/trace_streamer"
.build/release/arktrace --trace-streamer "$PARSER" inspect Fixtures/traces/zlib.htrace
.build/release/arktrace --trace-streamer "$PARSER" --json summary Fixtures/traces/zlib.htrace
.build/release/arktrace --trace-streamer "$PARSER" --json processes Fixtures/traces/zlib.htrace --limit 100
.build/release/arktrace --trace-streamer "$PARSER" --json query Fixtures/traces/zlib.htrace --view cpu-slices --start-ns 0 --end-ns 1000000
.build/release/arktrace --trace-streamer "$PARSER" --json context Fixtures/traces/zlib.htrace --timestamp-ns 500000 --window-ms 1
.build/release/arktrace --trace-streamer "$PARSER" --json analyze Fixtures/traces/zlib.htrace --kind range --start-ns 0 --end-ns 1000000
```

> **Note** — the bare `swift build` product is a development build: it carries no reviewed parser or license resources, so `doctor --self-test` and `licenses` fail closed, and the parser must be passed explicitly (the CLI never searches `PATH`). The full install unit is the signed, notarized `ArkTraceCLI.app` described in [docs/CLI_DISTRIBUTION.md](docs/CLI_DISTRIBUTION.md); production and ArkDeck execute its `Contents/MacOS/arktrace` directly, which locates the bundled parser on its own.

Full command reference, Machine JSON contract, limits, signal handling and privacy guarantees: [docs/CLI.md](docs/CLI.md).

### 4. Run the viewer

Open `ArkTrace.xcodeproj` in Xcode, select the `ArkTraceApp` scheme and run. Open `.htrace` / `.ftrace` / `.systrace` files via **File → Open**, Finder “Open With”, drag & drop, or Recents; **Reload** reopens the current trace from its original file.

To capture a new trace, connect an OpenHarmony device with USB or network debugging enabled, then choose **File → Capture Trace…** (<kbd>⌘N</kbd>). ArkTrace finds `hdc` in the configured SDK/PATH or lets you choose it directly. Select a device, profile, duration and buffer size, choose the local destination, and start capture. The completed file opens automatically. Full behavior and failure recovery: [docs/CAPTURE.md](docs/CAPTURE.md).

The sidebar toggles tracks and filters them to one process by name or PID; the timeline supports mouse/trackpad pan and zoom, range selection and real event selection; the toolbar search locates events by TID / thread / slice name; the inspector shows event details or range analysis.

Keyboard, following SmartPerf Host where it has a binding:

| Keys | Action |
|---|---|
| <kbd>W</kbd> / <kbd>S</kbd> | Zoom in / out about the pointer |
| <kbd>A</kbd> / <kbd>D</kbd> | Pan backward / forward |
| <kbd>F</kbd>, <kbd>[</kbd>, <kbd>]</kbd> | Zoom to the selected range |
| <kbd>←</kbd> / <kbd>→</kbd> | Previous / next real event in the track |
| <kbd>↑</kbd> / <kbd>↓</kbd> | Adjacent visible track |
| <kbd>Option</kbd>+<kbd>←</kbd>/<kbd>→</kbd> | Pan by ~10% of the viewport |
| <kbd>+</kbd> / <kbd>-</kbd> | Zoom about the selection or viewport center |
| <kbd>Return</kbd> · <kbd>0</kbd> · <kbd>Esc</kbd> | Select focused event · reset zoom · clear selection |
| <kbd>,</kbd> / <kbd>.</kbd> | Scroll the nearest flag back into view |
| <kbd>Ctrl</kbd>+<kbd>,</kbd> / <kbd>Ctrl</kbd>+<kbd>.</kbd> | Jump to the previous / next flag |
| <kbd>M</kbd> / <kbd>Shift</kbd>+<kbd>M</kbd> | Mark the selection — temporary / kept |
| <kbd>Ctrl</kbd>+<kbd>[</kbd> / <kbd>Ctrl</kbd>+<kbd>]</kbd> | Jump to the previous / next mark |

Pointer, on the timeline:

| Keys | Action |
|---|---|
| Drag | Select a time range; drag either edge to adjust it |
| Scroll | Pan horizontally |
| <kbd>Option</kbd> or <kbd>Ctrl</kbd> + Scroll | Zoom about the pointer |
| Pinch | Zoom about the pointer |
| Click the time ruler | Place a flag at that instant |

Search Results:

| Keys | Action |
|---|---|
| <kbd>↑</kbd> / <kbd>↓</kbd> | Previous / next match, revealing it on the timeline |
| <kbd>Return</kbd> | Go to the selected match and move focus to the timeline |

All three tables are also in the app under **Help → Keyboard Shortcuts**, generated from the same source as this page. Flags and marks are listed in the Inspector, where they can be renamed, recolored and deleted. They are saved with the trace — reopening the same file brings them back — and are keyed by the trace's content hash, so nothing about where the file lives is written down.

Hold a key to keep zooming or panning — macOS key repeat drives it. Unlike the web UI, the shortcuts are scoped to the focused timeline, so typing `w`, `s` or `m` in the search field stays typing, and ⌘-modified keys always reach the menu.

Slices are colored the way SmartPerf Host colors them: a CPU slice takes its running process's color, a named slice hashes its own name into upstream's twenty-entry palette (digits stripped, so `ipc::41` and `ipc::42` match), and thread states use upstream's fixed state colors. The same slice therefore has the same color in either tool. Details and the exact ported functions: [docs/DESIGN.md](docs/DESIGN.md) §13.5.

## Testing and release gates

`swift test` covers the regular regression suite. Releases are guarded by cumulative, fail-closed phase gates that verify real parser output, CLI contracts, benchmarks, signing/notarization and end-to-end evidence — each inherits everything before it and fails closed when required external inputs are missing:

```bash
scripts/test_phase1.sh   # clean build, real parser + fixtures, zero skipped tests
scripts/test_phase2.sh   # + release CLI contract, signal and benchmark gates
scripts/test_phase3.sh   # + signed app, document types, notarization, large-trace gates
scripts/test_phase4.sh   # + agent CLI contract, medium/large performance gates
scripts/test_phase5.sh   # + CLI distribution and the real ArkDeck artifact chain
scripts/test_phase6.sh   # offline audit of the real closed-loop evidence
scripts/test_phase7.sh   # upstream-alignment regressions + viewport performance on the real medium fixture
```

CI builds, tests and runs the offline gates on every pull request, but hosted runners cannot build the pinned parser, so parser-integration tests skip there — the phase scripts remain the release authority.

## Status

Phases 0–7 are complete and **all 10 release gates are closed**. Phase 7 (upstream alignment, 13/13) closed every actionable gap in [docs/UPSTREAM_ALIGNMENT_AUDIT.md](docs/UPSTREAM_ALIGNMENT_AUDIT.md) behind `scripts/test_phase7.sh`. The final gate closed a real debug loop on a DAYU 200 board — typed capture → structured analysis → agent judgement → typed re-verification — with the target app's CPU usage judged `improved` (−87.09%). Full task index: [docs/TASKS.md](docs/TASKS.md); final report: [docs/PHASE_6_VERIFICATION.md](docs/PHASE_6_VERIFICATION.md).

Known limitations: Apple silicon / macOS 26+ only; capture requires an OpenHarmony SDK `hdc`, a connected device and device-side `hiprofiler_cmd`. The viewer does not draw irq / hilog / syscall lanes (those tables are empty in every real capture checked so far), does not offer user-defined colour themes, and its range statistics have no min/avg/max percentiles yet — see [docs/UPSTREAM_ALIGNMENT_AUDIT.md](docs/UPSTREAM_ALIGNMENT_AUDIT.md) §10 for the next-round list. The CLI and ArkDeck analyzer remain host-only and have no device authority. The macOS 26 minimum is the current baseline; distribution artifacts signed before this bump were built against macOS 14 and remain valid only as historical evidence — the next signed release must be produced and verified against the new baseline.

## Documentation

| Document | Contents |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | Product and technical design: evidence baseline, architecture, domain model, TraceStreamer integration, renderer, ArkDeck boundary, release gates |
| [docs/CAPTURE.md](docs/CAPTURE.md) | App-only HDC capture workflow, profiles, lifecycle, security boundary and troubleshooting |
| [docs/SPECIFICATION.md](docs/SPECIFICATION.md) | Normative requirements (`AT-*`), machine JSON contract, end-to-end acceptance scenarios (`AC-AT-*`), Definition of Done |
| [docs/TASKS.md](docs/TASKS.md) | Phase 0–6 task index and release-gate status |
| [docs/CLI.md](docs/CLI.md) | `arktrace` installation, commands, flags, Machine JSON, exit status, signals and privacy |
| [docs/CLI_DISTRIBUTION.md](docs/CLI_DISTRIBUTION.md) | Pinnable CLI app layout, manifest, signing/notarization, upgrade and rollback |
| [docs/APP_DISTRIBUTION.md](docs/APP_DISTRIBUTION.md) | ArkTrace.app signing, notarization and distribution decisions |
| [docs/ARKDECK_INTEGRATION.md](docs/ARKDECK_INTEGRATION.md) | ArkDeck production profile, real artifact chain, restart and Gate 9 evidence |
| [docs/TRACE_STREAMER.md](docs/TRACE_STREAMER.md) | Pinned TraceStreamer revision, build recipe, identity and invocation constraints |
| [docs/DAYU200_LARGE_HTRACE_INTEGRITY.md](docs/DAYU200_LARGE_HTRACE_INTEGRITY.md) | Integrity investigation of the real-device large trace kept outside Git as a content-addressed release artifact |
| Verification reports: [Phase 1](docs/PHASE_1_VERIFICATION.md) · [Phase 2](docs/PHASE_2_VERIFICATION.md) · [Phase 3](docs/PHASE_3_VERIFICATION.md) · [Phase 6](docs/PHASE_6_VERIFICATION.md) | Per-phase evidence: fixtures, hashes, benchmarks, gates and known limitations |

## ArkDeck integration

ArkDeck invokes the pinned `arktrace` CLI through its typed operations `analyzer.summarize-trace@1` and `analyzer.analyze-trace@1` — immutable trace artifact leases in, derived analysis artifacts out. Both operations pin the signed tool, parser and JSON identity via the [CLI distribution contract](docs/CLI_DISTRIBUTION.md), and ArkTrace never gains device control. Details and the full identity chain: [docs/ARKDECK_INTEGRATION.md](docs/ARKDECK_INTEGRATION.md).

## TraceStreamer provenance

ArkTrace does not rewrite the parser; it reuses the pinned upstream TraceStreamer from [openharmony/developtools_smartperf_host @ GitCode](https://gitcode.com/openharmony/developtools_smartperf_host). `source-lock.json` locks the upstream, 13 source dependencies and the GN/Ninja artifacts; independent patches and build scripts yield a content-derived recipe identity, and `scripts/test_trace_streamer_reproducibility.sh` requires two fresh worktrees to produce byte-identical binaries.

## License

ArkTrace is released under the [MIT License](LICENSE).

The bundled TraceStreamer's 14 source components, 2 build tools, license expressions and exact license bytes are tracked in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and `ThirdParty/TraceStreamer/license-inventory.json`; `scripts/verify_licenses.sh` verifies the inventory, source lock and file hashes fail-closed. In the app, **Settings → Licenses** shows the same locked set that `arktrace licenses` prints.
