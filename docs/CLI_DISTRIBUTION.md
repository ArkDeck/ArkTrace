# ArkTrace CLI distribution for ArkDeck

Status: Phase 5 production distribution boundary, independently reviewed and
notarized.  The immutable signed/stapled ZIP, source snapshot, tool/parser
identities, Apple `Accepted` submission and live-log semantic projection are
recorded in `Fixtures/release-evidence/phase5-cli-distribution.json`.  That
artifact was built from source revision `cddcd508757db3ebc0f3c7fcad4458076ed07c57`
and source-tree SHA-256 `778c5ad63371b89dd4f5454ea5c71db8bff89f8cb74c7dc397d773baaa8b98d4`;
the status edits made after packaging are a documentation-only delta and do not
rewrite that historical source snapshot.  The independently reviewed >500 MiB
Trace remains a separate Phase 3/4 gate and is not implied by this package.

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
