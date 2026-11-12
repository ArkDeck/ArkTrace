<img src="apple/Apps/ArkTraceApp/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" alt="ArkTrace" width="128" height="128">

# ArkTrace

[![CI](https://github.com/ArkDeck/ArkTrace/actions/workflows/ci.yml/badge.svg)](https://github.com/ArkDeck/ArkTrace/actions/workflows/ci.yml)
[![Swift](https://img.shields.io/badge/Swift-6.4-F05138?logo=swift&logoColor=white)](Package.swift)
[![Rust](https://img.shields.io/badge/Rust-1.99.0-000000?logo=rust)](rust/rust-toolchain.toml)
[![Platform](https://img.shields.io/badge/platform-macOS%2026%2B%20·%20Apple%20silicon-blue?logo=apple)](docs/guides/APP_DISTRIBUTION.md)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

**English** | [简体中文](README.zh-CN.md)

**Native macOS trace workbench for OpenHarmony** — one core that serves both humans, through a native timeline viewer, and AI agents, through a deterministic CLI.

ArkTrace captures traces from an explicitly selected OpenHarmony device or opens existing files, then uses a pinned TraceStreamer to parse `.htrace` / `.ftrace` / `.systrace` data into a local SQLite database:

- **ArkTrace.app** — a SwiftUI + CoreGraphics timeline viewer: CPU / thread-state / named-slice / counter / frame tracks grouped by process, with call-depth rows, zoom, pan, search, range selection, timeline flags and marks, and an inspector with range analysis.
- **Device capture** — a cancellable HDC workflow with App responsiveness, CPU scheduling and System overview presets; captured files are validated, saved locally and opened automatically.
- **`arktrace` CLI** — typed, bounded, versioned JSON queries and analysis for agents: `doctor`, `inspect`, `summary`, `processes`, `threads`, `query`, `context`, `analyze`, plus a fail-closed `licenses` command.
- **Shared engine for [ArkDeck](https://github.com/ArkDeck/ArkDeck)** — ArkDeck links ArkTrace's Swift packages at a pinned revision for its Trace workspace and runs the `arktrace` CLI as a host-only analyzer with no device capability.

ArkTrace is part of the [ArkDeck organization](https://github.com/ArkDeck). [ArkDeck](https://github.com/ArkDeck/ArkDeck) is the main debugging toolkit; [ArkForge](https://github.com/ArkDeck/ArkForge) handles flashing.

## Status

ArkTrace is in development. There are no tagged releases or published packages; build from source.

- The Swift product (app, CLI and libraries) has completed its phase 0–7 verification gates, including a closed debug loop on a DAYU 200 board. The task index is [docs/archive/TASKS.md](docs/archive/TASKS.md) and the final report is [docs/archive/PHASE_6_VERIFICATION.md](docs/archive/PHASE_6_VERIFICATION.md).
- The shared engine is migrating into the Rust workspace in [`rust/`](rust/) (exact Rust 1.99.0, edition 2024, macOS arm64 and Windows x64). See [rust/README.md](rust/README.md) and [docs/archive/RUST_CORE_MIGRATION_TASKS.md](docs/archive/RUST_CORE_MIGRATION_TASKS.md).
- The macOS app requires Apple silicon and macOS 26 or later. A Windows x64 CLI is built and tested on the native Windows CI lane; it does not replace the macOS app.

Known limitations: capture requires an OpenHarmony SDK `hdc`, a connected device and device-side `hiprofiler_cmd`. The viewer does not draw irq / hilog / syscall lanes (those tables are empty in every real capture checked so far), does not offer user-defined colour themes, and its range statistics have no min/avg/max percentiles yet — see [docs/archive/UPSTREAM_ALIGNMENT_AUDIT.md](docs/archive/UPSTREAM_ALIGNMENT_AUDIT.md) §10. The CLI and the ArkDeck analyzer are host-only and have no device authority. Distribution artifacts signed before the macOS 26 baseline were built against macOS 14 and are kept only as historical evidence.

## Features

- **Deterministic and agent-friendly.** Machine JSON 1.0 emitted as a single document on stdout, typed errors with stable exit codes, and explicit row / event / byte / deadline budgets — no raw SQL, no unbounded output.
- **Local and private.** Everything runs on your Mac. Parsed traces live in a content-addressed local cache; `--no-cache` switches to a session-owned ephemeral database.
- **Reproducible parser.** The TraceStreamer is pinned to an exact upstream revision with a byte-reproducible build recipe and a tracked license inventory.
- **Fail-closed verification.** Cumulative phase gates check real parser output, CLI contracts, performance and end-to-end evidence, and fail when a required input is missing.
- **Reads a trace the way SmartPerf Host does.** Which slice gets which colour, call-depth nesting, jank tagging and the navigation keys follow the pinned upstream, and each of those claims is an assertion in `hack/test_phase7.sh`. The colours themselves are ArkTrace's own, measured by `hack/verify_palette.py` in CI.

## Requirements

- Apple silicon Mac running macOS 26 or later
- Xcode 27.0 with the Swift 6.4 toolchain
- Rust 1.99.0 for the Rust workspace ([`rust/rust-toolchain.toml`](rust/rust-toolchain.toml))
- [Git LFS](https://git-lfs.com) for the large trace fixtures and evidence files
- Python 3 for the build and check scripts, and `jq` (ships with macOS 15+)
- [`just`](https://github.com/casey/just) (optional) for the shortcuts in the root [`justfile`](justfile)
- OpenHarmony SDK `hdc` and a connected device with `hiprofiler_cmd` (capture only)
- Network access the first time you build the pinned TraceStreamer

## Quick start

### 1. Clone and build the pinned parser

```bash
git clone https://github.com/ArkDeck/ArkTrace.git
cd ArkTrace
git lfs pull
```

The TraceStreamer binary is a locally built artifact excluded from Git — cloning alone is not enough:

```bash
hack/build_trace_streamer.sh
```

This produces `third_party/trace-streamer/macx/trace_streamer` and its identity manifest. Pinned revision and build recipe: [docs/design/TRACE_STREAMER.md](docs/design/TRACE_STREAMER.md).

### 2. Build and test

```bash
swift build -c release --product arktrace
swift test
```

For day-to-day work across branches and worktrees, use the cached runners. The root [`justfile`](justfile) wraps them; run `just` to list every recipe.

| Task | `just` recipe | Underlying command |
| --- | --- | --- |
| Build the Swift package | `just build-swift` | `sh hack/run-swiftpm.sh build` |
| Test the Swift package | `just test-swift` | `sh hack/run-swiftpm.sh test` |
| Build the macOS app | `just build-app` | `sh hack/run-xcodebuild.sh` |
| Build the Rust workspace | `just build-rust` | `python3 hack/run-cargo.py build` |
| Test a Rust crate (default `arktrace-cli`) | `just test-rust <crate>` | `python3 hack/run-cargo.py test -p <crate>` |
| Format check, clippy, workspace edges | `just lint` | see the [`justfile`](justfile) |
| Print the CI lane plan for your branch | `just ci-plan` | `sh hack/ci_plan.sh` |

Cache locations and overrides are described in [docs/guides/CARGO_CACHE.md](docs/guides/CARGO_CACHE.md) and [rust/README.md](rust/README.md).

### 3. Query a trace from the CLI

A small sample trace ships in the repository:

```bash
PARSER="$PWD/third_party/trace-streamer/macx/trace_streamer"
.build/release/arktrace --trace-streamer "$PARSER" inspect test/fixtures/traces/zlib.htrace
.build/release/arktrace --trace-streamer "$PARSER" --json summary test/fixtures/traces/zlib.htrace
.build/release/arktrace --trace-streamer "$PARSER" --json processes test/fixtures/traces/zlib.htrace --limit 100
.build/release/arktrace --trace-streamer "$PARSER" --json query test/fixtures/traces/zlib.htrace --view cpu-slices --start-ns 0 --end-ns 1000000
.build/release/arktrace --trace-streamer "$PARSER" --json context test/fixtures/traces/zlib.htrace --timestamp-ns 500000 --window-ms 1
.build/release/arktrace --trace-streamer "$PARSER" --json analyze test/fixtures/traces/zlib.htrace --kind range --start-ns 0 --end-ns 1000000
```

> **Note** — the bare `swift build` product is a development build: it carries no reviewed parser or license resources, so `doctor --self-test` and `licenses` fail closed, and the parser must be passed explicitly (the CLI never searches `PATH`). The full install unit is the signed, notarized `ArkTraceCLI.app` described in [docs/guides/CLI_DISTRIBUTION.md](docs/guides/CLI_DISTRIBUTION.md); production and ArkDeck execute its `Contents/MacOS/arktrace` directly, which locates the bundled parser on its own.

Full command reference, Machine JSON contract, limits, signal handling and privacy guarantees: [docs/guides/CLI.md](docs/guides/CLI.md).

### 4. Run the viewer

Open `apple/ArkTrace.xcodeproj` in Xcode, select the `ArkTraceApp` scheme and run. Open `.htrace` / `.ftrace` / `.systrace` files via **File → Open**, Finder “Open With”, drag & drop, or Recents; **Reload** reopens the current trace from its original file.

To capture a new trace, connect an OpenHarmony device with USB or network debugging enabled, then choose **File → Capture Trace…** (<kbd>⌘N</kbd>). ArkTrace finds `hdc` in the configured SDK/PATH or lets you choose it directly. Select a device, profile, duration and buffer size, choose the local destination, and start capture. The completed file opens automatically. Full behavior and failure recovery: [docs/design/CAPTURE.md](docs/design/CAPTURE.md).

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

Slices are *assigned* colours the way SmartPerf Host assigns them: a CPU slice takes its running process's identity, a named slice hashes its own name (digits stripped, so `ipc::41` and `ipc::42` match) into a twenty-slot table, and thread states go through upstream's state chain. Two slices that share a colour upstream share one here.

The twenty values in those slots, and the state colours, are ArkTrace's own. They are designed around the fact that upstream's hash reaches five of the twenty slots 74% of the time, and every entry is held to measured thresholds — pairwise ΔE, 3:1 against both the light and dark canvas, 4.5:1 for its label — by `hack/verify_palette.py`, which runs in CI. Details: [docs/design/DESIGN.md](docs/design/DESIGN.md) §13.5.

## Verification gates

`swift test` covers the regular regression suite. The phase gates are cumulative and fail closed: each inherits everything before it and fails when a required external input is missing.

```bash
hack/test_phase1.sh   # clean build, real parser + fixtures, zero skipped tests
hack/test_phase2.sh   # + release CLI contract, signal and benchmark gates
hack/test_phase3.sh   # + signed app, document types, notarization, large-trace gates
hack/test_phase4.sh   # + agent CLI contract, medium/large performance gates
hack/test_phase5.sh   # + CLI distribution and the real ArkDeck artifact chain
hack/test_phase6.sh   # offline audit of the real closed-loop evidence
hack/test_phase7.sh   # upstream-alignment regressions + viewport performance on the real medium fixture
```

[CI](.github/workflows/ci.yml) runs on pull requests and on pushes to `main` and `agent/**`. A planner ([`hack/ci_plan.sh`](hack/ci_plan.sh)) selects the SwiftPM, app, contracts, Rust macOS and Rust Windows lanes from the changed paths, and `CI required` is the single check for branch protection. Hosted runners cannot build the pinned parser, so parser-integration tests skip there; the phase scripts remain the final authority.

## ArkDeck integration

ArkTrace is the source owner for the shared Core, Parser, Store, Runtime, Analysis and Rendering modules. ArkDeck consumes a pinned ArkTrace package revision and keeps only its artifact/runtime bridge and product UI. When the native Rust SDK is staged, ArkDeck composes it through `TraceProductConfiguration` with its own reviewed profile.

For automated debugging, ArkDeck runs the pinned `arktrace` CLI through the typed operations `analyzer.summarize-trace@1` and `analyzer.analyze-trace@1` — immutable trace artifact leases in, derived analysis artifacts out. Both operations pin the signed tool, parser and JSON identity through the [CLI distribution contract](docs/guides/CLI_DISTRIBUTION.md), and ArkTrace never gains device control. Details: [docs/guides/ARKDECK_INTEGRATION.md](docs/guides/ARKDECK_INTEGRATION.md).

## TraceStreamer provenance

ArkTrace does not rewrite the parser; it reuses the pinned upstream TraceStreamer from [openharmony/developtools_smartperf_host @ GitCode](https://gitcode.com/openharmony/developtools_smartperf_host). `source-lock.json` locks the upstream, 13 source dependencies and the GN/Ninja artifacts; independent patches and build scripts yield a content-derived recipe identity, and `hack/test_trace_streamer_reproducibility.sh` requires two fresh worktrees to produce byte-identical binaries.

## Repository layout

| Path | Contents |
| --- | --- |
| [`sources/`](sources/) | Swift package targets: Core, Parser, Store, Runtime, Analysis, Rendering, AppSupport, Capture, CLI and the native runtime bridge |
| [`apple/`](apple/) | Xcode project and the `ArkTraceApp` macOS app |
| [`rust/`](rust/) | Rust workspace: analysis, CLI, contract, engine, FFI, platform, store and viewer crates, plus a separate `cargo-fuzz` workspace |
| [`api/`](api/) | Language-neutral contracts, vectors, FFI description and bindings |
| [`openspec/`](openspec/) | Specifications for current capabilities and change history |
| [`test/`](test/) | Swift test targets and trace, database and evidence fixtures |
| [`third_party/`](third_party/) | Pinned TraceStreamer recipe, source lock and license inventory |
| [`hack/`](hack/) | Build, verification, packaging and CI scripts |
| [`docs/`](docs/) | Design, guides, migration runs and the archive |

## Documentation

| Document | Contents |
|---|---|
| [rust/README.md](rust/README.md) | Rust workspace toolchain, macOS and Windows host ports, and migration status |
| [docs/design/DESIGN.md](docs/design/DESIGN.md) | Product and technical design: evidence baseline, architecture, domain model, TraceStreamer integration, renderer, ArkDeck boundary, verification gates |
| [docs/design/CAPTURE.md](docs/design/CAPTURE.md) | App-only HDC capture workflow, profiles, lifecycle, security boundary and troubleshooting |
| [docs/design/SPECIFICATION.md](docs/design/SPECIFICATION.md) | Normative requirements (`AT-*`), machine JSON contract, end-to-end acceptance scenarios (`AC-AT-*`), Definition of Done |
| [docs/design/TRACE_STREAMER.md](docs/design/TRACE_STREAMER.md) | Pinned TraceStreamer revision, build recipe, identity and invocation constraints |
| [docs/guides/CLI.md](docs/guides/CLI.md) | `arktrace` commands, flags, Machine JSON, exit status, signals and privacy |
| [docs/guides/CLI_DISTRIBUTION.md](docs/guides/CLI_DISTRIBUTION.md) | Pinnable CLI app layout, manifest, signing/notarization, upgrade and rollback |
| [docs/guides/APP_DISTRIBUTION.md](docs/guides/APP_DISTRIBUTION.md) | ArkTrace.app signing, notarization and distribution decisions |
| [docs/guides/ARKDECK_INTEGRATION.md](docs/guides/ARKDECK_INTEGRATION.md) | ArkDeck composition, production profile and real artifact chain |
| [docs/guides/CARGO_CACHE.md](docs/guides/CARGO_CACHE.md) | Rust build cache layout and limits |
| [docs/guides/WINDOWS_PRODUCTION_ACCEPTANCE.md](docs/guides/WINDOWS_PRODUCTION_ACCEPTANCE.md) | Windows CLI clean-host acceptance |
| [docs/archive/TASKS.md](docs/archive/TASKS.md) | Phase task index and gate status |
| Verification reports: [Phase 1](docs/archive/PHASE_1_VERIFICATION.md) · [Phase 2](docs/archive/PHASE_2_VERIFICATION.md) · [Phase 3](docs/archive/PHASE_3_VERIFICATION.md) · [Phase 6](docs/archive/PHASE_6_VERIFICATION.md) | Per-phase evidence: fixtures, hashes, benchmarks, gates and known limitations |
| [CHANGELOG.md](CHANGELOG.md) | Notable changes |

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) first. [AGENTS.md](AGENTS.md) defines the agent and maintainer boundary. Community expectations are in [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## Security

Report vulnerabilities privately, as described in [SECURITY.md](SECURITY.md). Do not open a public issue for a security report.

## License

ArkTrace is released under the [MIT License](LICENSE).

The TraceStreamer's 14 source components, 2 build tools, license expressions and exact license bytes are tracked in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and `third_party/trace-streamer/license-inventory.json`; `hack/verify_licenses.sh` verifies the inventory, source lock and file hashes fail-closed. In the app, **Settings → Licenses** shows the same locked set that `arktrace licenses` prints.
