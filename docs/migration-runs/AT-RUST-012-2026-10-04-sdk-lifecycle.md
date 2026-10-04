# AT-RUST-012 — native Swift SDK lifecycle pressure

Status: **in progress; 1,000-cycle development lifecycle gate passed**. Base:
`04c04f43def3c708ef528e6563b40b3d1feea52f`. Rust **1.99.0**, Xcode
**27.0 / 27A266a**, Swift **6.4**, language mode 6, macOS 26 arm64.
This is a development SDK gate; the App continues to use its Swift implementation.
[Complete machine record](AT-RUST-012-2026-10-04-sdk-lifecycle.json) retains all
21 checkpoints, actual binary/fixture identities, 442 source pins, compiler
rejection diagnostics and check receipts.

The package-external `Lifecycle` consumer imports the actual root package and
links the verified fixture XCFramework. Its Swift build uses strict memory safety,
warnings as errors and Debug configuration; the Rust static library is a Release
build. The existing actual compiler-negative Span escape and Task-capture checks
also run. The native library and generated binding contract are unchanged.

Each measured cycle performs a successful real pinned-parser open, a bounded
slice query and a nonempty native viewport snapshot. A second actual open is
cancelled after the SDK acknowledges native admission. That acknowledgement
does not prove that the second parser or SQLite query was already running.
Two concurrent closes finish before complete cold-byte and hot-record digests
are compared with their pre-close digests. A MainActor callback reads borrowed
primitive records; a MainActor heartbeat runs throughout the async work.

Swift value copies share their ARC result leases. After one value is dropped,
the native retained-byte counter remains positive while a copy is held. After
the final copy drops, awaited `RustCleanup.flush` completes. Every measured
cycle requires actual native retained bytes, SDK sessions and SDK requests to
be zero. No fixed cleanup sleep replaces this completion condition.

Ten complete cycles warm the runtime before the measured run. At the warmed
baseline and every 50 measured cycles, actual Darwin `proc_pidinfo` supplies
the producer's FD count and resident bytes; `proc_listchildpids` supplies its
direct-child count. While the consumer waits for an explicit acknowledgement,
the Python supervisor checks the complete namespace membership, absence of
Ready databases and the unchanged original source hash. The allowed persistent
namespace entries are only `.actors` and `.actors/.owners`.

The frozen allowances are **32 MiB above the warmed baseline** at checkpoints,
and **8 MiB growth from the first sample in the latter half**. These are small
corpus lifecycle allowances, not medium/large performance SLOs or total
parent-plus-child RSS bounds. RSS is sampled rather than continuously measured.
The final resource sample precedes Engine shutdown; shutdown and ARC flush are
awaited afterwards. No post-Engine-release FD/RSS value is claimed.

The original pressure process exited **0** after **2,304.83 seconds**, including
ten warmup cycles. Measured results are 1,000 successful full parser opens,
1,000 admitted cancelled second opens, 1,000 raw queries and 1,000 native
snapshots. All 1,000 post-close digest comparisons and final-owner refunds pass.
The 2,020 primitive reads include warmups; the MainActor heartbeat advanced
1,124,347 times. This is an executor/liveness observation, not an input-latency
SLO measurement. Other full build/test checks ran on the host concurrently.

| Producer resource | Warmed baseline | Maximum checkpoint | Final before shutdown |
|---|---:|---:|---:|
| FD count | 22 | 22 | 22 |
| Resident bytes | 20,430,848 | 20,856,832 | 20,480,000 |
| Direct children | 0 | 0 | 0 |
| Native retained payload bytes | 0 | 0 | 0 |

The latter-half RSS maximum is 20,480,000 bytes, equal to its first sample;
growth under the frozen rule is zero. Namespace membership stays at the two
expected owner-root directories, every Ready scope is removed and the original
fixture hash remains unchanged. The actual rebuilt archive is
`8c5d0e32ee5c4d856e1adcbd87a8f5f0faf4e8253ad277239ef442edd39b1242`.

Verification in this slice:

- A reduced five-cycle development run passed after ten warmups. It does not
  stand in for the full 1,000-cycle gate.
- **337** Rust tests pass, zero failed/ignored, with strict clippy and format
  checks. The first restricted run missed startup markers in two host SIGKILL
  tests; the unchanged complete suite passed in the normal host environment.
  Both logs are retained, and no assertion or test was skipped to obtain green.
- **607** existing Swift tests: 601 passed, six existing explicit skips, zero
  failed. The package-external promised public API compiles with warnings as
  errors. The existing App builds with Xcode 27 and its document types pass.
  The single App Intents metadata tool warning remains; no compiler warnings
  were emitted. This does not demonstrate Rust App cutover.
- Planner, artifact staging, runner, migration, license, parser lock, palette
  and historical Phase 6 offline checks pass. Historical evidence validation
  does not become a new performance or release acceptance result.

After the power interruption, old `/private/tmp` artifacts were absent. The
parser and fixed toolchains remained. Rebuilding from exact Cargo.lock initially
failed because restricted DNS was unavailable, then offline resolution lacked
`cc 1.5.1`; an approved normal build fetched the remaining locked dependencies.
The rebuilt fixture archive has the same SHA256 as the previous SDK record.
The first DNS log was overwritten before freezing, so only its earlier tool
output excerpt remains; the offline failure and later successful build have
complete logs. This limitation is recorded rather than inventing a raw log.

The initial lifecycle probe also failed strict-memory/warning checks and then
selected an empty global slice track. It was corrected to use a real populated
`namedSlice(ThreadKey(itid: 1))` track from the pinned fixture. The nonempty
primitive assertion and resource allowances remain enforced. Failed probe
attempts are retained. No product implementation or parser identity changed.

The new lifecycle source compiles in CI's existing package-external SDK step.
Its `--build-only` mode does not execute this pressure gate. Hosted App/parser
skips also cannot substitute for this local actual parser run.

Actual binaries and logs are also frozen under the Git-ignored
`.build/agent-coordination/arktrace/sdk-lifecycle-20261004/` directory; they do
not enter Git. Complete typed Swift response/schema adaptation and decoded-owner
budgeting, metric/event batches, C# SafeHandle owners, immutable release assets,
production publisher signatures, persistent cache, Viewer/App cutover and final
macOS acceptance remain unfinished. The active Goal remains active.
