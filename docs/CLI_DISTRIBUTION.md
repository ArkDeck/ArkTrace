# ArkTrace CLI distribution for ArkDeck

Status: Phase 5 production distribution boundary, independently reviewed and
notarized.  The immutable signed/stapled ZIP, source snapshot, tool/parser
identities, Apple `Accepted` submission and live-log semantic projection are
recorded in `Fixtures/release-evidence/phase5-cli-distribution.json`.  The
current artifact was built from source revision
`61d0f2aecb09f63a9633ea50ec8bebc956fe37ac` (the macOS 26 / Swift 6.3 baseline)
and source-tree SHA-256
`0f6e59c8e1718206a2f67df1000fbf8aae6d6365d4a25e6e81aed47b99ca787a`; earlier
pinned artifacts remain recorded in Git history as historical evidence.  The
independently reviewed >500 MiB Trace remains a separate Phase 3/4 gate and is
not implied by this package.

## Closed install layout

The install unit is a versioned directory.  ArkDeck pins the manifest and the
absolute executable path; it never searches PATH or starts the GUI.

```text
ArkTraceCLI-0.1.0/
├── ArkTraceCLI.app/
│   └── Contents/
│       ├── Info.plist
│       ├── CodeResources (Apple staple ticket; post-notarization, mode 0600)
│       ├── _CodeSignature/CodeResources
│       ├── MacOS/arktrace
│       ├── Helpers/trace_streamer
│       └── Resources/
│           ├── TraceStreamer/{manifest.json,distribution-signing.json}
│           ├── ArkTraceCLIResources/
│           │   ├── {LICENSE,THIRD_PARTY_NOTICES.md,license-inventory.json,zlib.htrace}
│           │   └── LICENSES/<18 exact inventory files>
│           └── Attribution/
│               ├── {LICENSE,THIRD_PARTY_NOTICES.md,license-inventory.json}
│               └── LICENSES/<18 exact inventory files>
├── distribution-manifest.json
├── notarization-receipt.json
├── LICENSE
└── THIRD_PARTY_NOTICES.md
```

`ArkTraceCLI.app` is an `LSBackgroundOnly` bundle whose main executable is the
same production `arktrace` CLI.  It exists so both Mach-O executables can be
signed inner-to-outer and the complete CLI install can be notarized and stapled
as one macOS unit; ArkDeck executes `Contents/MacOS/arktrace` directly.  The App
has empty entitlements and no device, HDC, network, automation or GUI authority.

The CLI uses an explicit executable/bundle-relative resource locator instead of
SwiftPM's generated absolute fallback. Candidate acceptance renames the exact
Swift build scratch directory away before running `doctor --self-test --json`
and both human/Machine `licenses`. This proves that the reviewed license set and
self-test fixture come from the installed bundle rather than a build directory.
The raw `swift build --product arktrace` result is a developer core executable,
not a complete install; resource commands typed-fail when run without this App
layout and never fall back to a stale SwiftPM resource bundle.

The pre-notary App closure forbids `Contents/CodeResources`. After Apple accepts
the submission, `stapler` must create that one bounded physical ticket carrier;
the post-staple verifier requires it while continuing to require the original
`Contents/_CodeSignature/CodeResources`. Ticket semantics are proven by
`stapler validate` and Gatekeeper, not inferred from its opaque bytes.

## Manifest and identity

`distribution-manifest.json` is the only supported ArkDeck descriptor input.  It
has a closed schema verified by `scripts/verify_phase5_cli_distribution.py` and
records:

- ArkTrace source-tree identity and Git revision;
- product version/build, arm64 architecture and JSON contract `1.0`;
- fixed relative executable/parser/resource paths;
- signed `arktrace` byte count, SHA-256 and CodeDirectory hash;
- signed TraceStreamer byte count/SHA-256/CodeDirectory plus unsigned identity,
  manifest and distribution-signing record SHA/size, upstream revision,
  reported version and build recipe;
- exact Developer ID team/identity/certificate SHA-1 and hardened-runtime policy;
- Apple Accepted submission, canonical receipt SHA, staple and Gatekeeper facts;
- complete App/resource tree hashes, exact Info.plist identity, fixed executable
  and data modes, product license/notice/inventory/self-test identities, and the
  closed 18-file inventory-derived license set in both runtime and attribution
  resources;
- versioned-directory upgrade and exact-directory rollback policy.

The verifier rejects extra top-level/App/resource bytes, symlink roots/components,
non-regular or oversized files, mode/schema/key drift, unsupported contract/layout,
Info.plist mismatch, executable or parser hash drift, parser signing-provenance
mismatch, incomplete notarization, resource-tree drift and attribution drift. It
enumerates and reads through physical directory descriptors rather than mixing a
path walk with opened descriptors. It is not a signature verifier by itself;
the build/package scripts additionally require exact `codesign`, certificate,
hardened-runtime, timestamp, `stapler` and Gatekeeper results.

## Build and notarize

The candidate and final artifact scripts reuse the Phase 3 reviewed filesystem
and diagnostic boundary.  Output is allowed only below the physical repository
`.build` root or the physical system temporary root; partial output is private
and atomically published only after all checks pass.

```bash
export ARKTRACE_DEVELOPER_ID_APPLICATION='Developer ID Application: Hanfeng Fu (8AQTYW5FKR)'
export ARKTRACE_DEVELOPMENT_TEAM='8AQTYW5FKR'
export ARKTRACE_NOTARY_PROFILE='arktrace-notary'

scripts/build_phase5_cli_distribution_candidate.sh

export ARKTRACE_PHASE5_CLI_CANDID="$PWD/.build/phase5-cli-candidates/<candidate>.app"
scripts/package_phase5_cli_distribution.sh
```

The first script performs a clean Release product build, constructs the closed
bundle, signs TraceStreamer and its manifest before the CLI/App, revalidates the
certificate/runtime/timestamp/empty entitlements, removes the build dependency,
and runs the installed self-test plus human/Machine license closure. It emits an
exact candidate record beside the App.

The package script rechecks that candidate against the current source-tree and
record, submits a private ZIP to Apple, requires `Accepted`, staples the exact
App, requires Gatekeeper acceptance, constructs the final distribution manifest,
verifies a freshly extracted archive, applies a quarantine marker to that copy,
and reruns `doctor --self-test --json` plus both license modes. Publication also
requires the private partial to disappear and the final identity to equal the
precomputed partial identity, so `mv -n` collision cannot accept an older file.
Only then is the final ZIP published.

## ArkDeck install, upgrade and rollback

An administrator extracts the artifact to an owner-only versioned directory and
verifies it before installing an ArkDeck analyzer descriptor.  The descriptor
stores the physical distribution root plus manifest SHA-256; requests never
contain either value.  The profile fixed arguments are `summary --json` plus
reviewed limits, and AnalyzerProvider appends only the Artifact lease path.

Upgrade stages another complete versioned directory and atomically selects its
verified descriptor.  It never overwrites the active executable, parser or
manifest.  Existing Jobs retain their materialized profile snapshot.  Rollback
selects a retained prior exact descriptor/directory; if any prior byte has
drifted it is unavailable rather than repaired or guessed.  Removing all
descriptors leaves `analyzer.summarize-trace@1` published but honestly
unavailable.

## Local contract

```bash
scripts/test_phase5_cli_distribution_contract.sh
```

The contract covers a valid closed distribution, parser drift, extra shipped
bytes, symlink-root escape, executable modes and shell syntax.  The live
Developer ID/notary/quarantine facts cannot be satisfied by this synthetic
contract and remain bound to the tracked release evidence.

## Windows x64 Rust CLI distribution

The Windows headless install is separate from the macOS Apple-only format.
Its closed schema is
`contracts/distribution/arktrace-cli-distribution-windows-x86_64-v1.schema.json`,
generated by `scripts/windows_cli_distribution.py`. Its schema ID is
`arktrace.cli-distribution.windows-x86_64/1`; the original macOS descriptor
does not accept these fields.

```text
ArkTraceCLI-0.1.0-windows-x86_64/
├── distribution-manifest.json
├── arktrace.exe
└── resources/
    ├── ArkTraceRust/runtime.json
    ├── Helpers/{arktrace-host-process.exe,trace_streamer.exe}
    ├── TraceStreamer/manifest.json
    ├── zlib.htrace
    └── licenses/
        ├── {LICENSE,THIRD_PARTY_NOTICES.md,license-inventory.json,windows-license-inventory.json}
        ├── LICENSES/<18 inventory files>
        ├── LICENSES-windows/<6 inventory files>
        └── rust/
            ├── dependency-licenses.json
            └── licenses/<37 dependency directories, 75 exact texts>
```

The manifest binds every file's size and SHA-256, the source revision and dirty
state, the unsigned and signed image hashes, the fixed parser recipe, schema
and index provenance, attribution and versioned-directory rollback policy.
The tree digest begins with `arktrace-windows-x86_64-tree/1` and uses `x` for
the three declared executables and `r` for data files, so NTFS does not invent
POSIX execute permissions. The root manifest is excluded from its own digest.

The default `authenticode-publisher` package compiles the expected publisher
into the CLI, signs all three images and verifies their actual Authenticode
publisher (one subject O=, or one CN= when O= is absent). A leaf certificate
hash is never the publisher pin. `--timestamp-url` requests an RFC 3161
timestamp; a manifest claiming timestamps requires them on every signature.
The existing host-trusted development signer may exercise this path, but its
artifact is a development qualification, not a production release. No script
creates a certificate or changes a trust store.

```powershell
python scripts/package_windows_cli_distribution.py `
  --output <new-absolute-output-directory> `
  --parser <recipe-built-trace_streamer.exe> `
  --publisher <expected-publisher-name> `
  --certificate-thumbprint <existing-code-signing-certificate-thumbprint>
python scripts/verify_windows_cli_distribution.py <produced-zip-or-directory>
python scripts/smoke_windows_cli_distribution.py <produced-zip> <new-absolute-smoke-directory>
```

`--development-pinned` instead builds unsigned, whole-hash-pinned images.
`--allow-dirty` explicitly records an uncommitted source snapshot; a released
artifact must come from its reviewed source. The packager preserves the source
parser, signs only staged copies, and verifies both the extracted install and
the final ZIP. Binaries and ZIPs stay outside Git.

The verifier rejects case collisions, path aliases, links/reparse points,
undeclared files or directories, changed resources, inconsistent runtime or
parser identities/budgets, wrong PE architecture, unshipped DLL dependencies,
signature/publisher drift and missing claimed timestamps. Synthetic archive
tests run in CI; they do not establish a real signature or clean-host pass.
The native smoke records every child's raw stdout, stderr, argv and exit code,
runs from moved Unicode/spaced install paths with a minimal environment and
NUL stdin, and retains its inputs and results for review.

The running image is bound to its held file by the kernel's
`ProcessImageFileMapping` comparison. Cached mapped-image pathnames can retain
the old directory name after a move; they are not used as identity evidence.
The native regression also rejects an identical-byte copy as the running image.
Unavailable native comparison support fails closed.

Windows `licenses` verifies the installed common, Windows-specific and frozen Cargo
attribution closure and offers bounded human or JSON output. Trace commands
continue to require `--no-cache`. A new signed version installs beside the
previous directory; an ArkDeck consumer selects the reviewed manifest and
exact path. Removing an old installation never deletes user Trace data.
Production signing, a clean host without development runtimes, and ArkDeck's
actual load/doctor/inspect/analyze/export integration remain separate checks.

### Native development qualification (2026-10-18)

The host-trusted development signer verified all three staged images, and the
signed ZIP from clean source `a189a95ce1b48fcdfc4947c694fc81a143a73e81` passed
all 26 smoke checks: doctor/self-test, complete common/Windows/Rust attribution
and output budgets, inspect/summary/CPU analysis, extensionless htrace Artifact
IDs, an extensionless systrace, directory relocation, and resource/parser
tamper refusal. The manifest closes 110 files, including 75 Rust license texts.
This used the CLI's existing `ARKTRACE_STORAGE_ROOT` override
with an owner-private root; the verifier does not change existing directory ACLs.
The host's default AppData ancestry failed the privacy check and remains refused.
For a qualified explicit root, pass `--storage-root <existing-private-root>` to
the smoke script. This is not production signing or clean-host acceptance.

Local targeted checks: 20 CLI, 38 engine, 6 FFI and 16 distribution contract
tests pass; native clippy passes for platform/store/engine/CLI/FFI. The platform library run has
37 passing tests, its existing spawned-child helper ignored, and one failure in
the default-AppData workspace test on this host's unqualified ancestry. Test
fixtures may select `ARKTRACE_TEST_STORAGE_ROOT`; they use the same trusted-parent
validation and do not alter the default-storage test. The full Cargo-runner Python
suite assumes a Unix test environment; native focused cache tests and the CI
planner tests pass. CI validates the selected native lanes separately.

The local package's manifest SHA-256 is
`8c8e31b910bed9ba7cabb0c6dbd6243e797860f7cf04b87d3eb53fe24fe4123d`,
and its tree SHA-256 is
`651e80d271f60253e018aab1866448587a537808c510dbdee0f3cb60d08af4ea`.
The signer is host-trusted development material and no timestamp was claimed.
CI has not run for this handoff: publishing the branch awaits authorization for
the `ArkDeck/ArkTrace` GitHub destination.
