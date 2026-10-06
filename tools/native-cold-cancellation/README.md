# macOS normal SDK cold cancellation acceptance

This local acceptance tool uses Rust 1.99.0, Xcode 27 and a pinned normal
SDK consumer built from `scripts/swift-sdk-cancel/NativeColdOpenCancellation.swift`.
It does not use the development-fixture SDK for product cancellation.

The caller prepares a private evidence directory, an exact schema-1 packet
(`supervisor.PACKET_KEYS`), and a read-only JSON input (`supervisor.INPUT_KEYS`).
The packet pins the consumer, Swift source, kernel bridge and SDK library by
SHA-256. The input pins the signed helper/parser, publisher and source identity.
Normal mode requires a new empty, owner-only ephemeral namespace and a physical
owner-only read-only source file. Preflight holds that source without reading
its contents; the SDK performs its own source hashing.

Register the operation's absolute `time.monotonic_ns()` deadline once, then run:

```sh
python3 tools/native-cold-cancellation/supervisor.py packet.json --deadline-ns ORIGINAL_DEADLINE
```

The hash budget is shared throughout that invocation: 64 MiB per file, 128 MiB
total, 64 KiB reads, the original deadline and cancellation callback. Stdout is
limited to 128 KiB, stderr to 8 KiB, 256 records and three caller controls.
The controller authenticates the direct child before Engine creation. It sends
one Task.cancel only after live parsing, kernel birth/path/group admission,
source revalidation and a recent calibrated progress observation. EOF lets the
consumer perform its own cleanup. The supervisor sends no process signals.

Guard mode needs the exact disposable 15-file set in `protocol_fixtures.py`;
it exercises 14 protocol and 21 input cases without Engine/open/cancel calls.
Its local Unix socket is bound and immediately closed, with no listen/connect.

Compile `kernel_bridge.c` and `rss_bridge.c` together as a macOS 26+ dynamic
library with Xcode 27 and `-lproc`, then register its digest in the packet.
The Swift consumer must link the declared normal SDK and current public Swift
modules; keep the actual compile command, source/input pins and binary receipt.
An old stress executable or a fixture SDK is not a replacement.

A successful operation proves measured cancellation, public retained bytes,
normal shutdown/flush, the direct natural wait, seven observed descriptor
closes, three registered PID absence observations and an empty actor skeleton.
Resource sampling does not prove complete peak RSS, an atomic process forest,
descendant wait statuses or private registry counts. These stay unsupported in
the report. This tool alone does not complete macOS acceptance.

The `test_*.py` scripts and the two `*_regressions/run.py` entries cover source,
namespace, clock, budget, transport closure and terminal consistency failures.
`test_kernel_observer.py` additionally takes the compiled bridge path. The
protocol fixture regression needs permission to bind its disposable local
socket. See [migration validation requirements](../../docs/RUST_CORE_MIGRATION_DESIGN.md).
