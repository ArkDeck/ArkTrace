# ArkTrace

[![CI](https://github.com/ArkDeck/ArkTrace/actions/workflows/ci.yml/badge.svg)](https://github.com/ArkDeck/ArkTrace/actions/workflows/ci.yml)
[![Swift](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)](Package.swift)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20·%20Apple%20silicon-blue?logo=apple)](docs/APP_DISTRIBUTION.md)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

**English** | [简体中文](README.zh-CN.md)

**Native macOS trace workbench for OpenHarmony** — one core that serves both humans, through a native timeline viewer, and AI agents, through a deterministic CLI.

ArkTrace reuses the pinned OpenHarmony TraceStreamer to parse offline traces (`.htrace` / `.ftrace` / `.systrace`) into a local SQLite database, and builds on top of it:

- **ArkTrace.app** — a SwiftUI + CoreGraphics native timeline viewer: CPU / process / thread / slice / counter tracks with zoom, pan, search, range selection and an inspector with range analysis.
- **`arktrace` CLI** — typed, bounded, versioned JSON queries and analysis built for agents: `doctor`, `inspect`, `summary`, `processes`, `threads`, `query`, `context`, `analyze`, plus a fail-closed `licenses` command.
- **ArkDeck integration** — a host-only Trace Analysis Engine inside [ArkDeck](https://github.com/ArkDeck)'s automated debugging loop, with zero device capability by design.

## Highlights

- **Deterministic and agent-friendly.** Machine JSON 1.0 emitted as a single document on stdout, typed errors with stable exit codes, and explicit row / event / byte / deadline budgets — no raw SQL, no unbounded output.
- **Local and private.** Everything runs on your Mac. Parsed traces live in a content-addressed local cache; `--no-cache` switches to a session-owned ephemeral database.
- **Reproducible parser.** The bundled TraceStreamer is pinned to an exact upstream revision with a byte-reproducible build recipe and a fully tracked license inventory.
- **Evidence-driven releases.** Every phase ships behind fail-closed verification gates, closed with real-device (DAYU 200) evidence rather than claims.

## Requirements

- Apple silicon Mac running macOS 26 or later
- Swift 6.3 toolchain / Xcode 26.6 (Xcode for building the app)
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

The sidebar toggles tracks; the timeline supports mouse/trackpad pan and zoom, range selection and real event selection; search locates events by PID / TID / process / thread / slice name; the inspector shows event details or range analysis. Keyboard basics: arrow keys move across events and tracks, <kbd>Option</kbd>+arrows pan, <kbd>+</kbd>/<kbd>-</kbd> zoom, <kbd>Return</kbd> selects, <kbd>F</kbd> zooms to the selection, <kbd>0</kbd> resets, <kbd>Esc</kbd> clears.

## Testing and release gates

`swift test` covers the regular regression suite. Releases are guarded by cumulative, fail-closed phase gates that verify real parser output, CLI contracts, benchmarks, signing/notarization and end-to-end evidence — each inherits everything before it and fails closed when required external inputs are missing:

```bash
scripts/test_phase1.sh   # clean build, real parser + fixtures, zero skipped tests
scripts/test_phase2.sh   # + release CLI contract, signal and benchmark gates
scripts/test_phase3.sh   # + signed app, document types, notarization, large-trace gates
scripts/test_phase4.sh   # + agent CLI contract, medium/large performance gates
scripts/test_phase5.sh   # + CLI distribution and the real ArkDeck artifact chain
scripts/test_phase6.sh   # offline audit of the real closed-loop evidence
```

CI builds, tests and runs the offline gates on every pull request, but hosted runners cannot build the pinned parser, so parser-integration tests skip there — the phase scripts remain the release authority.

## Status

Phases 0–6 (57/57 tasks) are complete and **all 10 release gates are closed** as of 2026-08-16. The final gate closed a real debug loop on a DAYU 200 board — typed capture → structured analysis → agent judgement → typed re-verification — with the target app's CPU usage judged `improved` (−87.09%). Full task index: [docs/TASKS.md](docs/TASKS.md); final report: [docs/PHASE_6_VERIFICATION.md](docs/PHASE_6_VERIFICATION.md).

Known limitations of the first release: Apple silicon / macOS 26+ only; offline analysis only — no capture, device or network capability. The macOS 26 minimum is the current baseline; distribution artifacts signed before this bump were built against macOS 14 and remain valid only as historical evidence — the next signed release must be produced and verified against the new baseline.

## Documentation

| Document | Contents |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | Product and technical design: evidence baseline, architecture, domain model, TraceStreamer integration, renderer, ArkDeck boundary, release gates |
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
