# AT-RUST-012 — C ABI owned results and viewport records

Status: **in progress**. Base: `eb0d0a2d8d795d70a7cc6cd95a842b122e5c1ea2`.
Rust **1.99.0**, Xcode **27.0**; deployment target macOS 26 and Swift language
mode 6 remain unchanged. [Complete machine record](AT-RUST-012-2026-10-04-c-abi-owner.json)
retains this run's full native UTF-8, record contents, fresh Swift outputs,
source identities and exact loaded development library/helper/oracle artifacts.

Implemented the provisional v1 ABI with 22 exports, ten scalar/record layouts
and 95 checked offsets. One contract generates C declarations, safe Rust
records, Swift layout assertions and C# LibraryImport declarations. Only the
reviewed exports module admits unsafe caller pointers. The existing Engine
owns all worker parsing/querying and packs immutable viewport arrays and UTF-8
string tables before publication. JSON and scene payload capacities share the
owned result budget. Signed Int64 depth is preserved, including Swift's
negative-depth geometry inputs. Complete machine quality facts retain status,
category, optional scope/count and deterministic order.

Engine/result owners use monotonic process IDs, while session/request handles
keep the existing engine identity/generation protection. Admission remains
nonblocking with BUSY/CAPACITY. A retained result or snapshot can outlive its
request, session and Engine. Export unwind retains its Engine context before
the body and poisons/drains that Engine without reacquiring the global registry.
Normal creation requires fixed publisher expectations and separate signed
helper/parser identifiers; fixture creation still verifies signatures/pins.

Executed:

- 336 Rust tests, zero failures/ignored/warnings; strict clippy, format,
  architecture/license checks, nine offline gates and 50 planner cases passed.
- Real production library linked by a Swift 6 C-import consumer under Xcode 27;
  C/Rust/Swift size/alignment/offset assertions passed. 1,000 bounded byte cases
  used genuinely allocated input/output storage. Null, wrong-size, misalignment,
  unknown fields and oversize admission rejected.
- Three freshly parsed pinned small traces: **33** full viewport record
  projections and **42** density resolutions matched freshly executed independent
  actual Swift SQLite repository, loader and geometry oracle. Full JSON and
  original Swift snapshots/inspectors remain in the machine record.
- Caller source storage was overwritten immediately after open admission.
  Foreign Engine handles, wrong handle domains, stale completed viewport
  acquisition and repeated release rejected. Held record/string/JSON views
  survived close/drain; clones survived Engine release. Last-owner payload
  budget refund was directly observed. FD counts returned **4 → 4** for each
  fixture; owned database scopes disappeared and original source hashes matched.
- Controlled export panic returned INTERNAL, blocked new work with POISONED
  and drained its Engine. Another Engine stayed running and published a genuine
  path-free owned failure for a missing source.

Windows native Rust/C# consumer compilation runs in the exact-head CI gate;
local macOS has no dotnet runtime. Windows Engine capability remains zero, with
UNSUPPORTED_HOST rather than simulated lifecycle success. No Windows Engine,
Swift SDK or App acceptance is claimed here.

Remaining AT-RUST-012 work: async Swift wrappers and C# SafeHandle owners,
published typed operation schema, bounded event/metric batches, 1,000 complete
native open/query/cancel/close cycles, package consumer adaptation and immutable
XCFramework/NuGet artifacts. AT-RUST-011 full presentation/tree/navigation and
persistent cache also remain incomplete. DevelopmentPinned signatures do not
substitute for production Developer ID evidence; medium/large performance,
App cutover and final macOS cross-platform acceptance have not passed.
