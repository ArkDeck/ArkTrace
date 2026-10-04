# Rust host boundary (AT-RUST-012 in progress)

`contracts/ffi-v1.json` is the provisional v1 ABI source. Run
`python3 scripts/generate_ffi_bindings.py` after intentional changes; `--check`
verifies C declarations, Rust records, C# `LibraryImport` declarations, layouts
and the exact contract SHA256. Version 1 is not yet a published SDK artifact.
C/C++ compile-time assertions and Rust constant assertions cover all 95 field
offsets and ten 64-bit record sizes. C# consumer assertions run on Windows.

The process registry uses monotonically increasing integer engine/result-owner
IDs. Session/request IDs retain Engine's generation and engine identity checks.
Admission uses `try_lock`/`try_send`: `BUSY` and `CAPACITY` are bounded outcomes;
callers retry on a background executor. Input UTF-8 is copied before returning.
All parse, SQLite, viewport projection, record packing and data JSON encoding run
on Engine workers. Acquiring a failed request encodes only its small closed
public error envelope. `engine_drain` initiates cleanup; poll `engine_drain_status`
and release only after `DRAIN_DRAINED`. A host must keep polling during shutdown.

`request_submit` accepts `{"operation":"viewport","query":{"request":...,"backingScale":2}}`
or another listed typed operation. Query payloads use the existing Contract,
Viewer and Analysis serde types with unknown fields rejected. Requests cannot
change Engine configuration, signing policy or parser identity. This JSON
operation schema has typed Swift request factories; its published SDK schema
and C# wrappers remain pending.

`result_acquire` retains immutable UTF-8; failed requests expose the closed,
path-free public error envelope. `snapshot_acquire` retains arrays of tracks,
primitives, complete machine quality and a UTF-8 string table, packed by the
worker. Arrays keep original signed Int64 ranges, identities and depth,
closed style/source tags, binary64 geometry and optional-value flags. These
records represent the current geometry/detail/density projection. Labels,
full inspector/palette/jank presentation and tree/navigation remain AT-RUST-011
work. No consumer should recreate those missing semantics.

A borrowed view remains valid while its integer result owner stays live, even
after request release, session close or Engine drain/release. Clone an owner
before concurrent use, keep it live throughout reads, and release each lease
exactly once. JSON capacity and retained record/string capacities share the
Engine result budget, charged until the last underlying owner drops. The
counter is retained payload allocation accounting, not a process RSS limit.
Records and buffers require correctly aligned, live, exclusive/non-overlapping
caller allocations. Null/wrong-size/oversize admission rejects before access;
no arbitrary dangling-pointer safety is claimed.

Unexpected export unwind is caught, poisons the retained Engine context and
initiates its drain without reacquiring the process registry. Controlled worker
panic tests retain their existing session/cleanup failure behavior. Native
faults, allocation aborts and OOM can terminate the process. No panic hook is
installed by this library.

Normal Engine creation requires product publisher expectations with separate
helper/parser signed identifiers and the actual fixed SHA256/parser identity.
Fixture creation is available only with `process-fixtures`; it still verifies
Mach-O signatures and exact binary pins. A packaged Swift SDK must supply
immutable release configuration. Windows currently exposes ABI identity and
closed admission results with no Engine capability; real Windows Engine support
must return `UNSUPPORTED_HOST` until implemented.

Verification:

- `scripts/test_ffi_contract.py`: native production library, C layouts, 1,000
  bounded valid-allocation byte cases, Swift static C import on Xcode 27 or C#
  `LibraryImport` on Windows. The C# declaration pattern follows Microsoft's
  [P/Invoke source-generation contract](https://learn.microsoft.com/en-us/dotnet/standard/native-interop/pinvoke-source-generation).
- `scripts/test_macos_ffi_owner.py`: actual fixed parser, newly queried three
  traces, fresh independent Swift repository/loader/geometry parity, retained
  arrays/UTF-8 ownership, cancellation of stale generations, last-owner budget
  refund, cleanup, FD/raw-source checks and controlled export panic isolation.

- `scripts/test_macos_rust_sdk.py`: package-external async Swift consumer,
  actual parser/Swift parity, ARC owners and observable cleanup failures,
  concurrent sessions/cancellation, MainActor borrowed records, last-owner
  refund, and compiler rejection of escaping/capturing borrowed spans.

- `scripts/test_macos_rust_lifecycle.py`: actual package-external SDK
  open/query/snapshot/admitted-cancel/concurrent-close pressure. Ten warmup
  cycles precede 1,000 measured cycles. Final ARC owners refund native bytes
  every cycle; actual FD/RSS/direct-child and namespace/raw-hash checkpoints
  use explicit acknowledgements rather than cleanup sleeps. `--cycles 5`
  supplies development feedback only. With a verified fixture XCFramework:

  ```sh
  ARKTRACE_RUST_XCFRAMEWORK=/absolute/path/CArkTrace.xcframework \
  ARKTRACE_CARGO_CACHE_ROOT=/absolute/writable/cargo-cache \
  python3 scripts/test_macos_rust_lifecycle.py
  ```

  The [1,000-cycle record](../docs/migration-runs/AT-RUST-012-2026-10-04-sdk-lifecycle.md)
  passed using the fixed parser and pinned toolchains. Its resource allowances
  are small-corpus development bounds, not a Release App performance SLO.
  CI's existing `--build-only` consumer step compiles this probe without
  executing its native lifecycle.

The development `ArkTraceRustRuntime` product is opt-in. Build an immutable local
artifact with `scripts/build_macos_rust_sdk.py`, set `ARKTRACE_RUST_XCFRAMEWORK`
to its absolute path, then use `scripts/run-swiftpm.sh`. The runner verifies the
entire receipt and stages a relative content-addressed binary target in its
external package mirror. The source checkout never receives native binaries.
Fixture artifacts require `--fixtures` and `ARKTRACE_RUST_SDK_FIXTURES=1`;
production creation still requires the fixed publisher and separate signed
helper/parser identities. Neither artifact is a published release.

`RustEngine` provides async admission/poll/cancel/close/drain; immutable
`RustResult`/`RustSnapshot` values share ARC leases. `withBytes`/`withRecords`
expose synchronous borrowed spans, without a hot-path copy or JSON decode.
Cold JSON decoding runs on the concurrent executor; explicit temporary byte
copies share a 64 MiB process-wide credit pool. Decoder scratch, retained
decoded values and consumer copies are outside this counter. `RustCleanup.flush`
waits for already-scheduled ARC cleanup and reports its first bounded canonical
failure. A session cleanup error can be retained before releasing its handle
through `session_error_acquire`.

All sixteen Swift request factories compile; native SDK checks execute CPU,
slice, viewport and density-resolution operations. Remaining work includes complete
Swift response/schema adaptation and decoded-owner budgeting, C# SafeHandle
owners, event/metric batches, immutable XCFramework/NuGet distribution and App cutover. Neither
consumer smoke nor these development slices mark
AT-RUST-012 or macOS cross-platform acceptance complete.
