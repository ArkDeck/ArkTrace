# AT-RUST-012 — retained typed opening SDK

Status: **in progress**. Rust **1.99.0**, Xcode **27.0 / 27A266a**,
Swift 6.4 / language mode 6, macOS 26 arm64. Source base is
`9b31a5d5485167b7a6881a82cc10d37120336f3b`; the
[machine record](AT-RUST-012-2026-10-04-typed-opening-sdk.json) pins 257
current source/contract paths and the executed producer logs/artifacts.

`RustSession.openingView()` now returns immutable typed opening facts from the
already admitted native result. It submits no new query. The private result
checks its Engine identity; the closed envelope checks the exact admitted
Session, request and format version before publication. Re-decoding explicitly
admits another SDK owner. The view, metadata/parser/cache/preparation/inspection
facets and extracted text share one ARC credit. No public mutable arrays,
Decodable constructor or unowned String getter escapes that storage owner.
Capability/scalar reads and borrowed UTF-8 are synchronous; JSON decoding and
explicit caller String copies execute off MainActor.

All 13 metadata, eight parser, six cache-key, five preparation, nine inspection
and five capability fields have closed wire checks. Required fields, integer
widths, text/digest bounds, physical table vocabulary/uniqueness and machine
quality status/vocabulary are checked. Inspection preserves supplied quality
order and duplicates, including null scopes/counts and mandatory null machine
messages. Native cache/parser validation, cache-key hashing, UTC semantics and
Ready authority remain in Rust. The SDK does not reproduce those algorithms.
The legacy generic `RustOpenResult.traceMetadata` still uses Core's existing
quality initializer; its duplicate collapse remains a pending adapter issue.

Directory and opening decoders reuse the same context, envelope, quality and
bounded array implementation. Raw JSON is checked before Foundation can
collapse duplicate fields, including differently escaped spellings. These two
schemas contain integer numeric fields only; `1.0`, `1e0` and `1E+0` cannot
masquerade as Int64. A single escaped valid key remains accepted. The raw scanner
bounds input to 16 MiB, value recursion depth to 32 (root depth 0), each object
to 32 fields, raw key tokens to 256 bytes and active decoded key text to 16 KiB;
it polls task cancellation while scanning. Value strings are not copied by the
scanner; Foundation still validates their decoding and the typed schema.

Storage scopes remain explicit:

- All typed SDK owners share **128 MiB / 256 owners**, including directories
  and metadata. Credits cover current private POD inline/array/UTF-8 capacities
  plus fixed owner policy. Keeping only a facet/text conservatively retains the
  original whole-view charge until the final ARC reference drops.
- The shared staging pool is **128 MiB / 768 credits**. Packed array capacities
  and text growth are checked against reservations; JSON keys have a separate
  bounded logical policy reservation during scanning. These credits do not
  measure Set/String allocator capacity or Foundation decoder scratch.
- Explicit temporary JSON copies retain their **64 MiB** pool. Native result
  leases and caller materialization are separate. The counters are not a
  combined allocator/RSS bound, concurrent atomic snapshot or App SLO.
  `developmentColdStorageCounts` describes the shared scope; the old directory
  diagnostic remains available and delegates to it.

Executed checks:

- **27 actual SDK tests**, zero failures/skips/warnings, plus four actual
  package-external Span escape/capture compiler rejections. The new cases cover
  duplicate fields and escaped keys, floating integer tokens, nested closed
  fields/identity/version, machine duplicates/status, physical table order,
  scalar extrema, last-facet/text retention, shared metadata/directory admission,
  cancellation/refund/recovery and raw JSON grammar/admission limits.
- Three fixed-parser real traces use the current fixture artifact. Every typed
  opening field equals the same native opening DTO; the bodies remain identical
  after session close and Engine shutdown. The three actual inspections retain
  6/8/7 quality issues. Each retains one owner through parser-facet then text-only
  holding and refunds to zero. This verifies SDK adaptation; independent
  original Swift metadata comparison against that same Ready DB remains pending.
- **18 current typed directory pages** replay the existing real owner/identity/
  256-owner-cap and recovery gate. Final SDK/staging/native bytes are zero, Ready
  scopes disappear and original trace/tool hashes stay unchanged. Two traces
  exercise retained text; zlib's all-nil directory names explicitly do not.
- Existing independent actual Swift viewport/density parity is rerun: 33
  viewport and 42 density results, plus the observable foreign-replacement
  cleanup failure. This is a separate regression, not metadata oracle evidence.
- Current **442 Rust runtime + six compile-fail = 448** tests, strict fmt/clippy,
  workspace/license verifier, artifact staging tests, public API baseline,
  migration/CP1252/checkout-byte regressions and 55 planner cases pass.
  Current production-mode SDK compiles with strict memory safety and no warnings;
  production signing/runtime acceptance is not implied.
- The full default Swift suite executes 607 tests: 601 pass and six existing
  explicitly opt-in/worker Integration cases skip; no warning or failure. The
  current default Swift App builds with Xcode 27, zero warnings, and its bundle
  document types pass. Two earlier output-root switches emitted stale cache
  warnings; the identical restored stable-output rerun is warning-free. This
  validates the existing App build, not Rust App cutover.

The actual old duplicate-key test failed with three accepted malformed responses
and a passing single-escape control. A second actual red test proved the three
floating tokens were accepted by the old integer decoder. Initial optional-range
scanner compilation, a wrong production artifact path and a wrong planner
script name remain separate failed evidence. Final source mirrors and raw log
hashes are audited; later builds never replace earlier receipts. The final
common decoder EOF whitespace fix has fresh byte-identical SDK source mirrors,
27 tests, four borrow rejections, production compilation and three native opening
checks. The earlier 18-page directory source receipt remains frozen separately;
only the trailing blank line differs. The postprocess
first mistook `test error::tests::...` for a compiler diagnostic; anchoring actual
diagnostic lines corrected that audit without changing the zero-exit producer.
A repeated freeze initially tried to overwrite its own read-only executable;
finalization now verifies an existing immutable copy instead of writing it.
The producer bytes, source identity and actual exit status remain unchanged.

Exact new-commit CI is audited after push. Predecessor `9b31a5d` CI37185523625
passed macOS 448 and native Windows 321 Rust tests, SDK14 and four borrow
rejections; it does not prove this new SDK. Its actual hosted App build/document
steps skipped for absent parser. The App still uses the existing Swift kernel.

Remaining: independent same-DB Swift metadata parity and validated Core machine
quality materialization, the other 14 typed responses, genuine native
`summaryFacts`, aggregate ownership/scratch and current lifecycle/performance,
production App/event/metric integration, signed published assets, C# ownership
and final macOS acceptance. AT-RUST-012 and the Goal remain active.
