# AT-RUST-012 — async Swift SDK development slice

Status: **in progress**. Base: `2baf711608f160281805bb2c4c7f5f0d012a45ea`.
Rust **1.99.0**, Xcode **27.0 / 27A266a**, Swift 6.4 in language mode 6;
deployment remains macOS 26 arm64. [Complete machine record](AT-RUST-012-2026-10-04-swift-sdk.json)
contains fresh native SDK output, complete UTF-8 and borrowed record fields,
fresh independent Swift oracle output, artifact/source pins and check receipts.

The opt-in `ArkTraceRustRuntime` product links a content-addressed local
XCFramework built from the actual release Rust static library. Cargo's stable
runner holds its lock through archive capture, so another feature configuration
cannot replace the bytes between building and copying. Whole-artifact receipt
verification checks contract/toolchain/configuration pins, membership, hashes,
macOS arm64 slice and generated headers; changed bytes, links and escaping paths
are rejected. SwiftPM stages an immutable relative binary target in its external
source mirror. The default existing package products keep their implementation.
The fixture and production archives are distinct; no native artifact enters Git.

`RustEngine` serializes lifecycle admission without blocking the UI, and polls
with suspending bounded retries. Cancellation racing native admission finishes
cancel/release/close before returning; close and shutdown share in-flight tasks.
`RustSession`, immutable `RustResult` and `RustSnapshot` own native ARC leases.
Value copies share one lease, with release scheduled only after the last Swift
owner drops. Synchronous `withBytes`/`withRecords` callbacks expose borrowed
`Span` values; the hot path reads retained immutable arrays without JSON, FFI
polling or a copy. Cold decoding uses the concurrent executor and a separate
64 MiB process-wide credit pool for explicit temporary JSON byte copies.
Decoder scratch, decoded DTO retention and consumer copies are not covered by
that counter; it does not measure RSS.

The provisional v1 ABI now has **23 exports**, ten layouts and 95 offsets.
`session_error_acquire` retains the complete canonical error of a failed close
before its handle is released. `RustCleanup.flush` waits for already-scheduled
ARC work and preserves the first bounded structured failure. The existing closed
public contract maps this cleanup failure to `TRACE_PARSE_FAILED`,
`openingDatabase`, retryable, reason `sessionCleanupFailed`; no new error stage
or diagnostic path is introduced.

Executed:

- Both actual fixture and production release XCFrameworks built using the
  pinned toolchains. Production Swift SDK compiled with strict memory safety
  and warnings as errors, without fixture-only construction APIs enabled.
- A package-external Swift consumer imports the actual root package and links
  the fixture static archive. It opens three pinned small traces with the actual
  fixed parser. **33** viewport projections and **42** density resolutions match
  a freshly executed independent actual Swift repository/loader/geometry oracle
  on each same Ready database. Complete record fields/string bytes and cold
  native UTF-8 are retained in the machine record.
- MainActor reads scoped borrowed records while its heartbeat continues through
  SDK parsing/querying. Compiler-negative consumers actually reject escaping
  byte spans and capturing primitive spans in a Task, under normal compiler
  settings. No experimental lifetime feature is enabled.
- Pre-cancelled queries, cancellation after native open admission, duplicate
  concurrent close, queries after close and two concurrent sessions pass.
  Retained records remain byte/field-equivalent after close and, on two traces,
  after Engine release. On the third trace, actual retained native payload bytes
  return to **zero** before Engine release when the last result owner drops.
  Owned Ready databases disappear and original trace hashes remain unchanged.
- A separate real filesystem fault moves the owned Ready directory outside the
  Engine namespace and puts a foreign replacement at its former location. ARC
  close reports the complete canonical cleanup failure; it preserves both the
  foreign replacement and escaped original bytes. This deliberately leaves
  unresolved owned residue and is **failure observability**, not successful
  residue recovery. The first failure remains observable after later flushes.
- **337** Rust tests, zero failed/ignored; strict clippy and format checks pass.
  Production C/Swift C-import layout/admission smoke and 1,000 genuinely
  allocated byte fuzz cases pass. This is not 1,000 full lifecycle cycles.
- **607** existing Swift tests: 601 passed, six explicit existing skips, zero
  failed. The initial restricted run failed two AppKit draw checks because it
  could not reach WindowServer; the approved normal graphics-session rerun
  passed. Package-external promised public API baseline also compiles.
- SwiftPM/Cargo/Xcode runners (5/11/6 tests), artifact staging (5 tests), planner,
  migration/architecture/license/parser/palette and historical Phase 6 offline
  evidence verifiers pass. The latter verify historical evidence only.
- Xcode 27 builds the existing Swift App, and the built bundle document types
  pass. An explicit cache-owned `INDEX_DATA_STORE_DIR` fixes the missing index
  path that caused Clang hardening flags to be interpreted as Swift conditions.
  One Xcode tool warning remains: App Intents metadata extraction is skipped
  because the App has no AppIntents.framework dependency. No compiler warnings
  remain in this build; it is not an App Rust cutover check.

The SwiftPM runner changed, so all four controlled SQL Swift oracles were
actually replayed: event 62, arguments 84, search 138, density 190, **474** complete
outputs. Their bytes and oracle executable identities are unchanged; only the
current runner source pin changes in the four current receipts. Original and
refreshed receipts are retained; historical before-fix evidence is unchanged.

CI adds the artifact staging regression and a package-external async consumer
compile plus real borrow compile rejections. The hosted lane uses `--build-only`
when no pinned parser exists, so it supplies no native Engine lifecycle/parity
acceptance. Windows generated C# declarations remain checked by the separate
native Windows lane; this local Mac run has no dotnet and proves no Windows
Engine lifecycle.

Remaining gates include complete typed Swift response/schema adaptation and
retained decoded-owner budgeting, C# SafeHandle owners, bounded native
metric/event batches, 1,000 complete native lifecycle cycles, production
Developer ID helper/parser evidence and immutable published XCFramework/NuGet
consumption. Persistent cache and AT-RUST-011 presentation/tree/navigation
remain incomplete. The App still uses the existing Swift implementation;
medium/large performance and final macOS cross-platform acceptance have not
passed. Neither this development SDK slice nor the existing App build completes
AT-RUST-012 or the active Goal.
