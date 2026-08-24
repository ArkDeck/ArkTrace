# ArkTrace.app 0.1 distribution decision

Status: P3-T08 accessibility and P3-T10 Developer ID distribution evidence
completed (2026-08-14); the later exact Phase 4 signed candidate, accessibility
walkthrough, Apple notarization and retained final ZIP were independently
reverified on 2026-08-15. The large-trace Gate 6/7 and Phase 4 final gate are closed.

## Target and signing

- macOS 26 or later, Apple silicon (`arm64`) — current baseline. Historical
  signed candidates in `Fixtures/release-evidence/` were produced against the
  earlier macOS 14 baseline and are kept as recorded evidence, not as proof
  that the macOS 26 baseline has shipped; the next signed candidate must be
  built, notarized and verified against 26.0;
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
camera, microphone, location, or automation capability. Trace analysis remains
offline and host-only. The GUI App now has one explicit device boundary: after
the user opens **Capture Trace…**, it may launch a user-visible `hdc` executable
to discover a selected OpenHarmony target, run a bounded `hiprofiler_cmd`
capture, and copy the result to a Save-panel destination. It does not provide
deployment, flashing, a general remote shell, background capture, or unattended
device control. CLI, Core, Runtime and the ArkDeck analyzer do not link this
capture module and retain no HDC/device route.

## Capture child boundary

Capture and parsing deliberately use different trust models. The bundled
TraceStreamer parser remains pinned and never searches `PATH`. HDC is an SDK
tool chosen by the user or resolved from documented SDK/PATH locations, and its
resolved path stays visible and replaceable in the capture UI. ArkTrace invokes
it directly with `Process.executableURL` and an argument array; no host shell or
command string is involved, and fixed device-side subcommands do not form a
general remote console. Duration and buffers are bounded, output is
bounded, device-side names are per-request UUIDs, and the local trace is exposed
only after a non-empty partial file is atomically promoted. Success, failure,
and cancellation all attempt to stop the profiler and remove only paths owned
by that capture request. See `docs/CAPTURE.md` and AT-APP-014…019.

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
accessibility evidence or large-trace trust configuration during packaging. The
live packaging path still requires the Developer ID identity/team/notary profile.
For an already notarized exact candidate, the complete gate alternatively accepts
only the retained physical ZIP and tracked notarization evidence together, then
reruns receipt/CDHash, signature, staple, Gatekeeper, resource and candidate-tree
closure through `scripts/verify_phase3_notarized_artifact.sh`; one-sided, dirty,
self-attested, unstapled, sparse, symlinked or byte-drifted inputs fail closed.
All distribution output roots must be physical owner-marked descendants of the
repository `.build` directory or the physical system temporary root. External
tool logs remain private; public failure diagnostics are bounded and path-redacted.
