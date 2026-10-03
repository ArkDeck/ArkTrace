# Shared Rust engine migration

Toolchain: exact Rust **1.99.0**, edition 2024, MSRV 1.99. Native product targets
are `aarch64-apple-darwin` and `x86_64-pc-windows-msvc`. FFI-capable release builds
use unwind; Windows binaries use static CRT. Dependency resolution is frozen
in `Cargo.lock` and checked against `dependency-licenses.json`.

Run from the repository root:

```sh
python3 scripts/run-cargo.py build --workspace
python3 scripts/run-cargo.py test --workspace --all-features
python3 scripts/run-cargo.py clippy --workspace --all-targets --all-features -- -D warnings
python3 scripts/run-cargo.py fmt --all -- --check
python3 scripts/verify_rust_workspace.py
```

The runner owns a stable source mirror, serialized invocation, target and
dependency caches outside the worktree. Set `ARKTRACE_CARGO_CACHE_ROOT` to an
absolute writable external directory in restricted environments. Set
`ARKTRACE_CARGO_HOME` only to explicitly reuse another external dependency
cache. Cargo receives `--locked`; intentional dependency updates use the
runner's `generate-lockfile` command. `ARKTRACE_EXPECT_NATIVE_HOST=macos-arm64`
or `windows-x64` refuses a different host before testing.
The macOS runner requires Xcode 27 and fixes `MACOSX_DEPLOYMENT_TARGET=26.0`,
preserving the current product floor. It refuses an ambient deployment override.

Currently implemented: validated time ranges, machine-safe quality facts,
cache key/lease identities, shared Swift/Rust vectors and native host smoke.
The macOS platform port holds no-follow file/directory descriptors, validates
owner-only modes, ACLs and filesystem ownership enforcement, copies/hash-checks
bounded read-only snapshots, acquires shared/exclusive `flock` leases, and
publishes files with an exclusive same-volume rename. Cancellation rolls back
owned publication; cleanup identity failure takes precedence over cancellation.
Flat staging directories can freeze up to 64 readonly regular files with an
aggregate byte limit, full metadata and SHA-256. Directory promotion validates
the entire membership/payload before and after a no-replace rename and restores
the complete candidate on cancellation. This is a publication primitive;
schema/index/metadata readiness and entry-lease coordination remain Engine/Store work.
Unsafe is confined to the audited macOS syscall module; domain crates forbid it.

The `arktrace` binary now provides the actual macOS migration adapter for
`inspect`, `processes`, `threads` and CPU/thread-state `query`, requiring explicit `--no-cache`. It supports
bounded argv, JSON/pretty/human output, closed errors, invocation deadlines and
first-signal cancellation. Native output commits use nonblocking writes and
bounded polling; inherited output flags are restored on ordinary exits. A partial
write emits no second JSON document. Error reporting also has a small independent
budget, including when stdout and stderr share a blocked destination.

Resources must come from the sealed `.app` containing the kernel-mapped Mach-O,
with verified fixed helper/parser snapshots. Default builds require Developer ID
and hardened runtime; ad-hoc resources require the explicit development feature.
Temporary product roots are private euid-scoped directories under the canonical
trusted sticky `/private/tmp`, independent of TMPDIR/HOME/PATH. Existing permissions
are checked without repair. This remains a migration candidate; the remaining
query views and five commands,
production signing/distribution, launch recovery and SDK/App/ArkDeck are unfinished.

```sh
python3 scripts/test_macos_rust_cli.py
python3 scripts/build_macos_rust_cli_candidate.py --development --output /private/tmp/ArkTraceRustCLI.app
```

See [packaged CLI evidence](../docs/migration-runs/AT-RUST-010-2026-10-03-packaged-cli.md).
The query route enforces both maxRows/maxEvents, required relative ranges,
applicable filters and exactly one result event array. Its 51 full Machine JSON
documents match the frozen fresh Swift oracle; only the actual executable SHA
and established hiprofiler DB-byte identity variation use T1. Native presentation,
query errors and the existing signal/output-pressure matrix are retained in
[query CLI evidence](../docs/migration-runs/AT-RUST-010-2026-10-03-query-cli.md).

`arktrace-store` now inspects macOS immutable snapshots using a retained private
readonly descriptor and bundled SQLite **3.53.2** via exact rusqlite **0.40.2**.
`sqlite-build-lock.json` freezes the source ID, C/header digests and public-domain
declaration in addition to all 35 crate license identities. The runner rejects
ambient libsqlite3 build overrides; the native probe records actual compile options.
The runner injects frozen `SQLITE_ENABLE_FILESTAT=1`. The macOS writable port
reads native FILESTAT metadata before any SQL and compares SQLite's actual file
descriptor's device/inode with the owned candidate. Runtime availability is
tested separately because this SQLite version omits FILESTAT from compile_options.
SQL/connection state stay private, with no busy waiting, query-only/defensive and
untrusted-schema settings, mmap disabled, schema/row/VM bounds and request-owned
cancellation/deadline. WAL headers and SQLite sidecars are rejected for standalone
snapshots. Validation ports fingerprint v2, affinities, strict INTEGER identities,
range/clock correction, bounded relationships, counter source selection and typed
quality evidence. Three real parser exports match the frozen Swift fingerprint,
capabilities, duration and complete quality facts exactly. Store now prepares
indexes on a fresh private 0600 copy: bounded page growth, bootstrap
and remaining-index transactions, schema validation, complete index introspection,
restored DELETE journaling, checked SQLite close and independently hashed 0400
sealing. The 24 definitions match existing Swift index schema version 3; optional
columns determine applicability. Cancellation, panic, full-page budget, expression/
partial/unique/collation/order mismatches and restored-path foreign-inode binding
have actual disk regressions. Three parser exports retain exact semantic parity
after indexing. Store preparation alone does not establish product Ready.

`StoreReader` retains one indexed immutable snapshot and one private connection.
It is neither Send nor Sync, so the caller must create and use it on the owning
worker. Typed process/thread queries reuse that connection with fresh request
budgets and reset progress handlers, parameter bindings, stable identity order,
limit+1 lookahead, escaped LIKE matching and trace-relative lifecycle values.
Invalid names and inverted lifetimes produce closed page quality facts. Engine
retains the reader for its ephemeral session, checks entry/metadata identity at
each query boundary and performs checked connection close before owner disposal.

Typed CPU slices and thread-state intervals also reuse this reader. They preserve
half-open queries, instants, NULL/negative open ends, checked Int64 normalization,
table-qualified event IDs, negative stable identities and optional-field quality.
Limits admit source rows; a dropped row never causes the reader to refill from
the lookahead. Raw repository pages distinguish supported-empty from unavailable;
`NoCacheSession::query_cpu_slices` / `query_thread_states` compose the Agent-facing
quality and normalized-time ordering used by Swift. The three real small inputs
pass 51 exact event-page comparisons to fresh Swift CLI query output and 18
failure/next-request checks. Run the native harness with an explicitly built
Swift CLI:

```sh
python3 scripts/test_macos_event_queries.py --swift-cli /absolute/path/to/arktrace
```

The harness requires Xcode 27, fixed parser bytes and actual macOS arm64. See
[scheduling query evidence](../docs/migration-runs/AT-RUST-007-2026-10-03-scheduling-queries.md).
The packaged Rust CLI exposes these two query views. The same StoreReader and
NoCacheSession now also provide raw/Agent named slices, with full 14-field coded
DTOs, escaped name filters, full trace-clamped duration thresholds and a closed
missing-depth error. Argument-set handles are fetched only when requested and
never encoded in Machine JSON. Forty-five full pages from three actual small
inputs match fresh Swift CLI output exactly; 30 negative/next-request cases pass.
See [named query evidence](../docs/migration-runs/AT-RUST-007-009-2026-10-03-named-hot.md).
The packaged Rust CLI now also exposes `query --view slices`, with name match,
minimum duration and depth filters. Agent/CLI name filters are bounded to 256
UTF-8 bytes; raw Store names remain bounded to 4096 bytes. Forty-eight fresh
native named pages and 39 negative/next-request cases cover this boundary. The
packaged candidate matches 48 full Swift Machine documents (only actual tool SHA
and the established hiprofiler upstream export SHA variations differ), and all
three query views' human output matches fresh Swift bytes. See the
[named CLI record](../docs/migration-runs/AT-RUST-010-2026-10-03-named-cli.md).
StoreReader/NoCacheSession now provide typed counter samples, independent series
directories and Agent pages; the packaged CLI exposes `query --view counters`.
Values and physical event identities remain Int64. Three small inputs produce
48 query cases (144 raw/directory/Agent pages) exactly matching fresh unchanged
Swift sources; 36 negative/next-request checks pass. Only the hiprofiler fixture
has actual process counters; CPU counters and legacy `measure` sources use
controlled SQLite regressions. The four-view packaged replay compares 156 full
Machine documents, four fresh human outputs and 60 CLI negative cases. Available
counter pages preserve separate open-time/query-time clamp observations even
when they project to identical machine facts. See the
[counter query record](../docs/migration-runs/AT-RUST-007-010-2026-10-03-counters.md).
SDK/App routes and the remaining typed query families still need migration.
Raw typed frames now use the same reader/session, without adding an Agent/CLI
view. The seven required columns suffice; additive `itid` is optional in both
Swift and Rust. Fifty controlled frame requests and twelve existing raw/Agent
cases match the actual Swift implementation, including closed errors. Existing
Agent views preserve distinct clamp observations after machine projection.
Three real parser/Ready sessions compare 24 frame pages and 18 existing
raw/Agent pages exactly, with 15 failure/next-request checks. All three real
frame tables are empty; nonempty frames still require real corpus evidence.
See the [frame query record](../docs/migration-runs/AT-RUST-007-2026-10-03-frame-queries.md).
Typed Inspector arguments now use the same reader/session. Only integer datatype
1 resolves a dictionary value; other types retain the raw Int64 decimal string.
The limit remains 64, with Swift's source lookahead/compaction behavior and no
invented quality warnings. A missing additive args id uses stable value ordering
(also for WITHOUT ROWID); required optional type tables/columns determine
availability. Eighty-four actual Swift controlled cases include four opt-in
slice-handle lookups. Eighteen real parser/Ready pages and fifteen failure/next
request checks pass; all three actual args tables are empty. Real nonempty args,
SDK/App routing and the remaining query families still need acceptance evidence.
See the [argument query record](../docs/migration-runs/AT-RUST-007-2026-10-03-argument-queries.md).

Shared Viewer search now composes typed process/thread/slice queries in pure
Analysis and uses the same NoCacheSession boundary. Excluded domains issue no
queries; first-seen internal identities, UTF-8 title ordering, lifecycle ranges,
real event keys and bounded results match 138 actual Swift controlled requests
and all 570 source calls. Three real parser/Ready traces match 67 full search
results, including real directory and zlib slice positives; 21 failed requests
leave the next request unchanged. This does not connect the Viewer/SDK/App or
replace the sidebar's visible-row filter. See the
[search record](../docs/migration-runs/AT-RUST-007-2026-10-03-search.md).

Density now aggregates all six source families through the same reader/session:
CPU, thread state, named slices, CPU/process counters and frames. Complete
buckets, raw dominant colour identities, capability and quality match 190 actual
Swift controlled requests and 60 real parser/Ready results; 21 failed requests
leave the next query unchanged. Identity reads use batches of at most 128
bindings. Occupancy and utilization remain unavailable, as in Swift. Real
nonempty CPU counters and frames, density caching/read pools and Viewer/SDK/App
integration remain open. See the [density record](../docs/migration-runs/AT-RUST-007-2026-10-03-density-queries.md).

Bounded Viewer details now execute through `NoCacheSession::viewer_details` and
`RepositoryRequest::ViewerDetails` on the existing async Store owner. Typed lane
queries select unattributed slices and CPU/process counter families before
LIMIT; omitted scope fields preserve general-query wire compatibility. Three
real traces pass 21 full async/blocking Rust response comparisons with owned
result lifetime and resource cleanup checks. Complete viewport orchestration,
generation/cache and SDK/App integration remain open.

```sh
python3 scripts/test_macos_viewer_owner.py
```

See [scoped owner evidence](../docs/migration-runs/AT-RUST-011-2026-10-04-scoped-owner.md).

The shared CLI library consumes a no-cache session for inspect/processes/threads/query,
validates Machine JSON values and provenance, serializes within the output byte
budget (including escapes and newline), and returns bytes only after explicit
close succeeds. Actual three-fixture outputs match the Swift oracle apart from
the real Rust executable SHA and the established C++ hiprofiler export digest
variation. The development packaged argv/signal/resource route is recorded
above. Remaining typed queries, persistent sessions and the other five commands
still need migration.

`arktrace-analysis` supplies bounded CPU/state reductions, nearest-rank scheduling
percentiles and hot bucket formulas. Swift's canonical-equivalent raw state
grouping is preserved with exact `unicode-normalization` **0.1.25**; the first
reported raw label stays unchanged, and result order uses that label's UTF-8.
An open-ended Runnable endpoint cannot establish an observed scheduling boundary;
the shared Swift oracle now applies the same rule. Thirty-three current actual
Swift vectors compare exact integers, binary64 bits, arrays and section facts.
Historical oracle evidence remains intact.

`NoCacheSession::analyze_bounded` composes independent raw Store pages with exact
process/thread identity filters, per-request cancellation/deadline and a final
retained database/metadata/lease check. Scheduling remains unattested. Real named
pages now supply hot inputs under an independent Store limit and minimum-duration
filter, retaining actual callstack identities, full ranges, quality and truncation.
The long-slice reduction is still absent. This six-section API is
a migration seam; full summary/context/analysis envelopes, filters, provenance,
byte budgets and CLI/SDK/App exposure remain pending. Twenty-one real-fixture requests
match five full Swift CLI arrays, section facts and analysis dataQuality exactly,
with three independent-budget and 27 negative cases. The prior
[mainline analysis evidence](../docs/migration-runs/AT-RUST-009-2026-10-03-mainline-analysis.md)
is retained; current checks are in the
[named/hot record](../docs/migration-runs/AT-RUST-007-009-2026-10-03-named-hot.md).

```sh
python3 scripts/test_macos_bounded_analysis.py --swift-cli /absolute/path/to/arktrace
python3 scripts/test_macos_slice_queries.py --swift-cli /absolute/path/to/arktrace
python3 scripts/test_macos_rust_cli.py --swift-cli /absolute/path/to/arktrace --named-oracle docs/migration-runs/AT-RUST-010-2026-10-03-named-cli.json
python3 scripts/verify_analysis_oracles.py
```

`arktrace-engine::open_no_cache` now composes verified tools, owned source
snapshots, actual export, indexed readonly preparation, format-1 metadata and
atomic ephemeral Ready publication. Reopen validates indexes, file identity/modes
and metadata before returning. A fresh publication name and exclusive ephemeral
lease isolate each no-cache session; explicit close removes its owner and lease.
Drop retains proof. The stable key lock covers construction; persistent cache
hits and shared-reader leases remain separate work. Metadata keeps exactly the
existing Swift fields and UTC ISO 8601 encoding with a 16 KiB decode boundary.

The fixed zlib fixture leaves `ts_tmp/unzlib_file.txt` (849657 bytes). Engine admits
only this exact private directory/file shape, hashes it under the source-byte
budget after process cleanup, and removes it with the input owner before Ready.
The supervisor also monitors this declared nested file during execution and
process-group cleanup. It retains private no-follow parent descriptors as soon
as they appear and rejects directory replacement or disappearance.

`OwnerStore` retains format-2 ownership records in the isolated Rust namespace.
Bound ephemeral entries now use format 3, adding a closed key/session/lease
identity binding; other new owners and old format-2 records keep their five fields.
An exclusive owner lease spans creating-before-mkdir, bound directory identity,
publication-location registration and quarantine/removing/removed transactions.
Record IO is capped at 4 KiB; recovery/cleanup have 4096-entry and eight-level
bounds and use held no-follow parents. Drop releases handles but performs no IO.
Stale recovery refuses live owners, retains unbound creating/invalid/unknown
proof, and requires entry-lease authority for published directories. If the
directory is gone before a removed tombstone became durable, proof is retained
as unresolved. Formats 2/3 must not be handed to existing format-1 Swift/ArkDeck
writers or purgers. Native SIGKILL fixtures cover eight transaction windows.

`recover_no_cache` adds explicit recovery of registered ephemeral Ready entries.
It discovers bounded metadata, takes the matching key lock, then acquires the
existing entry and owner locks without waiting. Native recovery rechecks the
metadata snapshot, exact owner record and held identities before disposal.
Active entries, invalid metadata and unresolved proof are retained. Moved owned
directories can be found inside the bounded namespace without deleting foreign
replacements. Format-3 entries bind the fresh lease immediately after candidate
creation and persist Publishing intent before atomic rename. Removed tombstones
survive payload deletion until the bound lease is unlinked and owner artifacts
are erased. Recovery can reconcile these phases without metadata, and rejects a
different lease inode. Native Engine SIGKILL covers 12 windows: 11 clean fully;
rmdir-before-Removed retains identity-unresolved proof and its bound lease.
Fresh lease allocation before binding and process-active staging recovery still
need complete evidence; retained unbound/unresolved proof is not guessed away.

The macOS process prototype verifies read-only executable snapshots by SHA-256
and code signature, launches suspended children, checks kernel code identity,
and passes literal argv with a held CWD and a fixed environment. A separately
packaged `arktrace-host-process` supervises parser process groups through a private
control pipe. After bootstrap, Engine death closes that pipe and independently
triggers TERM/grace/KILL cleanup. It drains separate bounded stdout/stderr pipes,
keeps the leader unreaped until group cleanup ends, and reports typed path-free
errors. The opt-in `process-fixtures` feature builds adversarial test fixtures;
production builds leave it disabled. CI tests/lints with all features so these
native tests cannot disappear behind their required feature.

Up to 16 declared fresh output files are monitored relative to the held private
CWD, with up to eight path components and 1024 path bytes. Duplicate or prefix-
conflicting declarations and existing top-level objects are rejected before
launch. Each has its own byte limit; retained descriptors reject identity changes,
links and nonprivate files. Limits are checked during execution, during cleanup
and after the entire process group stops. Cleanup-time stdout/stderr excess also
fails the invocation. Final file sizes are reported without names or paths.
The private supervisor protocol is version 3 and binds the held CWD identity.
Monitoring rejects excess results; it is polling rather than a disk quota and
does not yet govern undeclared files; owner transactions are a separate port.

The initial suspended bootstrap window uses Darwin's orphaned stopped-group
SIGHUP/SIGCONT behavior with an explicitly restored default SIGHUP and an empty
signal mask. Native SIGKILL tests cover inherited and terminal-free sessions,
including a parent that ignores HUP; the helper never reaches its entry point.

This prototype still needs remaining spawn/launch/cancellation fault windows,
signed bundle in-place execution, production Developer ID/notarization evidence
and Windows native processes. Development pins require valid code
signatures and cannot satisfy the production trust policy.

Real cross-volume/ENOSPC and ownership-disabled rejection are exercised on a
disposable APFS image on macOS 27. This gate needs native DiskManagement access:

```sh
python3 scripts/test_macos_file_volumes.py
```

Real parser exports, read-only source copies, permissions, raw-input hashes and
SQLite `quick_check` are checked separately using the fixed local parser and
three actual small fixtures (no DiskManagement requirement):

```sh
python3 scripts/test_macos_parser_process.py
python3 scripts/test_macos_directory_commands.py
```

This probe also verifies typed DB/sidecar budget failures with the real fixed
parser, unchanged raw inputs and no publication for failed exports. The probe
uses a 256 MiB DB budget; production parser/Engine limits remain to be defined.

`arktrace-migration-smoke` is a development check. It does not replace the
production Swift `arktrace` or open traces. Windows file ports, complete owner/entry-lease
policy and downstream recovery interoperability, product parser/Ready integration, remaining Store queries, Session, complete CLI and
SDK/App integration remain migration work. No released product selects this
workspace. The APFS gate is separate from the hosted native workspace unit job.
