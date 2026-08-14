# ArkTrace.app 0.1 distribution decision

Status: P3-T08 accessibility and P3-T10 Developer ID distribution evidence
completed (2026-08-14). The exact manual artifacts and notarization record are
tracked under `Fixtures/release-evidence/`; only the independent large-trace
Phase 3 gates remain open.

## Target and signing

- macOS 14 or later, Apple silicon (`arm64`) first release;
- direct Developer ID distribution and notarization; App Store/TestFlight and
  Intel are explicitly deferred until the child-process and performance
  evidence is repeated for those channels;
- Debug uses ad-hoc signing for local launch tests. The reviewed Release candidate
  uses Developer ID Application + hardened runtime; Apple notarization returned
  `Accepted`, and the stapled final ZIP passed Gatekeeper and extracted signature/
  ticket verification. Exact identity, artifact SHA and submission ID are in
  `Fixtures/release-evidence/phase3-notarization.json`.

## Sandbox and file grants

ArkTrace 0.1 does **not** enable App Sandbox. The product must execute the
reviewed, pinned TraceStreamer child and support Finder Open With for arbitrary
user-selected traces. This is narrower and more testable than adding broad
temporary sandbox exceptions. P3-T05 will persist security-scoped bookmarks
when URLs arrive with a security scope, but it will not treat a bookmark as
permission to broaden a path or to upload data.

The empty app entitlement file deliberately grants no network client/server,
USB/device, HDC, camera, microphone, location, or automation capability.
ArkTrace 0.1 is an offline local viewer.

## Parser bundle boundary

The Xcode target copies the executable into the standard nested-code location
`Contents/Helpers/trace_streamer` and the non-code manifest into
`Contents/Resources/TraceStreamer/manifest.json`:

- `ThirdParty/TraceStreamer/macx/trace_streamer`;
- `ThirdParty/TraceStreamer/macx/manifest.json`.

Production resolution checks only that bundle location. It never searches
`PATH`, `DYLD_*`, environment variables, Homebrew, or a user-writable global
location. Every parser child receives a fixed minimal environment rather than
the App/CLI environment. Missing bytes return `TRACE_STREAMER_UNAVAILABLE`; manifest, Mach-O,
hash, version, or provenance drift returns
`TRACE_STREAMER_IDENTITY_MISMATCH`. The separate developer resolver accepts an
explicit URL and is compiled only in Debug builds.

The repository binary is the reproducible **unsigned** input. A distribution
archive must sign the nested helper first with Developer ID, hardened runtime,
and trusted timestamp. Because signing changes Mach-O bytes, the candidate
builder then rewrites only `manifest.binarySHA256`, writes a bounded
`distribution-signing.json` that binds unsigned SHA → signed SHA → build recipe
→ exact Team ID/signing identity/certificate SHA-1, and finally re-signs the outer App. The packaging
gate verifies that closure before notarization and again after extracting the
final ZIP. Candidate App and final ZIP are first written to owner-bound private
partial names; only a fully copied, signed, stapled, Gatekeeper-accepted artifact
is atomically published under its final name. The final ZIP is created only after
the App is notarized and stapled.
Ad-hoc Debug/Release build smoke tests continue to compare the pre-distribution
helper and manifest byte-for-byte with the repository inputs.

## Storage

Cache data is dedicated to
`~/Library/Caches/com.arktrace.ArkTrace/`; original traces are never copied into
the cache as user documents. Recent-item/bookmark state belongs in the app's
Application Support container and is implemented by P3-T05. Existing Runtime
ownership, lease, quarantine, and path-hardening rules remain the only cache
mutation implementation.

## Shared implementation

The native target consumes local Swift package products. It does not copy
Core, Parser, Store, Runtime, Analysis, or Rendering sources. The canonical App
version/build/bundle identifier live in `Config/ArkTraceProduct.xcconfig`;
`ArkTraceCore.ArkTraceProduct` is the checked SwiftPM/CLI mirror, while Info.plist
expands the same Xcode build settings. Tests and the app gate fail closed on drift.

## External release evidence

`scripts/build_phase3_distribution_candidate.sh` creates the exact signed App
for manual review. `scripts/package_phase3.sh` consumes that same App and a
tracked evidence manifest under `Fixtures/release-evidence/`; it does not rebuild
or silently substitute a candidate. The six required artifacts and their schema
are documented in that directory. The manifest and all six artifacts must be
tracked, byte-identical to `HEAD`, hash-bound, and tied to the exact candidate;
the independent Agent or human review result is recorded in Git history. A
separate accessibility reviewer key is deliberately not required because it
would not establish additional independence inside the same build workspace.
The large-trace reviewer and redistribution-grant issuer remain independently
key-bound in `Config/ArkTraceReleaseReviewers.json`. A caller cannot mutate the
accessibility evidence or large-trace trust configuration during packaging. A missing Developer ID identity/team/profile,
large-trace record, manual evidence artifact, notarization acceptance, staple,
or Gatekeeper assessment causes the complete Phase 3 gate to fail closed. The
2026-08-14 accessibility/package run satisfies the signed-App/manual/notary
inputs; the complete Phase 3 gate remains blocked only by the independent large record.
All distribution output roots must be physical owner-marked descendants of the
repository `.build` directory or the physical system temporary root. External
tool logs remain private; public failure diagnostics are bounded and path-redacted.
