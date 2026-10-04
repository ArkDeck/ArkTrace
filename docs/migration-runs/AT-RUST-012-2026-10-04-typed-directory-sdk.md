# AT-RUST-012 — retained typed directory SDK

Status: **in progress**. Rust **1.99.0**, Xcode **27.0 / 27A266a**,
Swift 6.4 / language mode 6; macOS 26 arm64 deployment is unchanged.
Rust source base is `44505359b10a27a8d33549c0e36f8ce7af5d3ee5`.
[Machine record](AT-RUST-012-2026-10-04-typed-directory-sdk.json) pins the
actual source bytes, both immutable development artifacts and executed checks.

`RustSession.processes` and `threads` now return closed typed pages. Their
private packed scalar arrays and UTF-8 pools have one ARC storage credit;
page copies, extracted records, quality records and text keep that credit alive.
The final view releases it. Public mutable arrays, unowned String getters and
public decoded-page constructors are absent. `RustOwnedText.withUTF8` lends a
synchronous nonescaping Span; `copyString` explicitly materializes a caller-owned
String on the concurrent executor. Core `ProcessKey`, `ThreadKey`, quality
category and the actual closed quality scope vocabulary are reused.

The decoder validates version 1, the exact admitted request and native session,
required nullable fields, closed field sets, integer/Boolean types, query limits,
4 KiB names and at most 4,096 machine quality issues. It preserves supplied issue
order and duplicates. Directory machine messages must be null, as emitted by the
existing native directory path. Other machine quality adapters have their own
normalization contract; this does not change the legacy Core initializer.
Page and record identities include both Engine and Session. The native result
also carries its Engine identity privately, so the SDK verifies the host binding
before decoding. These identities are ephemeral correlations, not query authority.

Storage accounting has distinct scopes:

- Retained SDK pages share a process-wide **128 MiB / 256-owner** pool. Each
  charge uses actual current packed-array and UTF-8 capacities plus a 256-byte
  fixed owner policy credit. Keeping only a text/quality view conservatively
  retains the original whole-page reservation even if record arrays have freed.
- SDK staging has its own **128 MiB / 768-credit** pool. It admits packed arrays
  before allocation and checks their capacity, admits the bounded UTF-8 growth
  policy and refunds all staging credits on success, rejection or cancellation.
  Mutable decoder context uses a checked Sendable Mutex, without unchecked
  conformance or warning suppression.
- Native leases and the existing **64 MiB** explicit JSON-copy pool remain
  separate. Foundation decoder scratch, allocator overhead and caller copies are
  not measured by these counters. This is not a combined RSS bound or an App SLO.

Executed on the current implementation:

- **14** Swift SDK tests, zero failures/skips/warnings: integer extrema, nullable
  Boolean/identities/timestamps, UTF-8/NUL, record/text/quality retention, duplicate
  issues, exact name bounds, malformed schema, cancellation, byte/owner admission,
  concurrent refunds and recovery. Four real package-external compiler-negative
  consumers reject escaping/capturing result, snapshot and text spans.
- A package-external consumer links the actual current fixture XCFramework and
  fixed parser on three pinned real traces. **18** typed directory pages match
  separate raw native queries field by field. This is native SDK adaptation
  parity, not an independent Swift repository oracle. All three exercise page
  and record survival after close/shutdown; two exercise actual retained text.
  The zlib trace's names are all nil and its text check is explicitly false.
- Each trace admits 256 independent SDK page owners, rejects the next, recovers
  after drops and proves a raw native query remains usable at the SDK cap.
  A second session and separate Engine return distinct full identities with
  equivalent facts. Final SDK/staging bytes and owners, and native retained
  bytes before shutdown, are zero; Ready databases disappear and raw/tool hashes
  stay unchanged. These query-owner checks are not 1,000 full lifecycle cycles.
- The existing actual three-trace SDK viewport/density and cleanup-failure gate
  is replayed with the current source. Its 33 viewport and 42 density outputs
  use a newly executed independent actual Swift repository/geometry oracle.
- Production SDK builds with strict memory safety and zero warnings. The default
  existing Swift App builds with Xcode 27 and its document types pass. **601**
  existing Swift tests pass; six existing worker/opt-in evidence tests skip.
  Public API baseline, runners, staging, planner and applicable offline gates pass.

Initial failed evidence is preserved separately: a lexical Array.span borrow
needed a local immutable COW reference; a single-file executable needed explicit
`-parse-as-library`; a negative test first failed on an unused result rather than
the desired lifetime error; production compilation exposed the non-Sendable
decoder context. Writable cache overrides corrected two restricted-cache checks.
No toolchain, strict memory safety, fixture identity or machine contract was
relaxed. Final positive and negative logs have verified receipt hashes.

CI now actually runs the 14 SDK tests alongside the package-external compile
gate and uploads their log plus all four compiler-rejection logs. The full diff
selects every lane; exact-head hosted results are audited after push. Hosted
compile/unit evidence does not substitute for local real-parser checks.

Remaining: other typed responses, preserving machine quality adaptation,
genuine `summaryFacts` and repository/Engine integration, combined owner/scratch
budgets, production signed/published assets, C# owners, event/metric batches,
App Rust cutover, fresh lifecycle and medium/large performance acceptance.
AT-RUST-012 and the macOS Goal remain active.
