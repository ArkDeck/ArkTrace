# Read-only macOS process sampler — A41R1 delivery

The sole reusable source files are `process_forest_sampler.py` and `proc_bridge.c`. Both retain the exact bytes tested in A41; the adjacent `proc_bridge.dylib` retains the exact tested binary. This package repairs delivery and provenance only. Original A41 remains **FAILED** because its final metadata deadline expired. Its independently completed controlled-tree and three synthetic decision tests are reused with original command, PID, wait, stdio, source, header, oracle and output records under `evidence/a41/`. No controlled tree or product run was repeated in A41R1. Original absolute paths in historical receipts remain unchanged; `provenance-index.json` maps them to exact copied bytes.

After ROOT accepts this new package, MAIN may import the two source files and this README. The copied bridge is evidence of the tested local binary; MAIN must either independently verify it in the current environment or compile its own adjacent bridge from the accepted C source. No `supervision.py`, preparation, freeze, driver, or historical test code is a product dependency. Rebuilding this small local bridge does not rebuild or stage an ArkTrace SDK.

## Backend and launch binding

This delivery uses existing CPython 3.14.8 (PSF license), Apple Clang and the registered macOS 27 SDK `libproc.h`, `sys/proc_info.h`, `sys/proc.h`, and `sys/resource.h` (Apple APSL/BSD notices). The tested binary targets Apple silicon/macOS 26+. The API requires libproc BSD process information and task resident bytes; the C/Python bridge row is 56 bytes, native BSD/task structs are 136/96 bytes, start offsets are 120/128 and task resident-byte offset is 8. R1 verified the adjacent copied dylib at its new location by ABI getter calls only, with zero proc-list, identity and RSS queries. Source AST and CLI help were checked; no functional sampling was rerun. Registration distinguishes historical full tool/header hashes from R1 six-field identity checks.

From the imported tool directory, use the existing verified compiler/SDK; this is the original successful compile command with only the two local input/output paths changed:

```sh
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang -std=c17 -Wall -Wextra -Werror -O2 -fno-modules -dynamiclib -arch arm64 -mmacosx-version-min=26.0 -isysroot /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk proc_bridge.c -lproc -o proc_bridge.dylib
```

Before any real measurement, MAIN must register the **current** App, helper, parser, SDK, source, sampler and compiled bridge identities/hashes from the same validated launch packet. Obtain that App PID and its exact kernel start seconds/microseconds from the current launch. A PID alone or an old pressure binary does not bind current product behavior. Record real open/cancel events independently, with monotonic times and small non-path identifiers, and supervise sampler completion/stdio separately.

Replace the symbolic values below; `NEW_OUTPUT.jsonl` must not exist:

```sh
python3 -B process_forest_sampler.py --root-pid PID --expect-root-start SEC:USEC --duration-ms 20000 --interval-ms 50 --max-processes 256 --max-samples 1000 --max-output-bytes 16777216 --list-capacity 8192 --output NEW_OUTPUT.jsonl --stage-marker open-start:MONOTONIC_NS
```

An optional `--cancel-marker cancel-request:MONOTONIC_NS` records a caller-supplied marker. Such markers are not discovered/authenticated product events. Missing markers remain missing; their location before/within/after the sampling window is reported. A marker, sampler summary or exit code 0 does not prove real cancellation or product acceptance.

## Bounds and interpretation

The CLI accepts duration 100..300000 ms, interval 10..10000 ms, tracked identities 1..256, samples 1..10000, PID enumeration capacity 1..8192, total output 128 KiB..16 MiB, and 16 markers per kind with ASCII identifiers at most 32 characters. Predicted samples must fit the requested budget. Each record is at most 64 KiB, process rows are emitted in sorted chunks of 16, and the final error/summary has reserved output space. Each sample's proc-query ceiling is checked before calls. Results are schema-versioned streaming JSONL; errors do not include target argv, environment or absolute user paths.

The sampler is read-only: it never launches/signals/attaches a product, switches UI, accesses devices, uploads, or queries target argv/environment/files. Identity is PID plus kernel start seconds/microseconds. New descendants require parent/child identity and parent-relation rechecks; identified children remain tracked after reparenting. Changed start identity rejects PID reuse for the old owner. Unknown identity/RSS remains unknown, not zero. Termination observations bound last live/first absent or zombie observations; they do not supply actual exit codes, cause, or wait/reaped status.

Every polling sample remains **partial**. Parent relationships and enumeration are not atomic, kernel permissions can hide candidates, and transient processes may be missed. The peak is the sampled RSS sum for identified live owners with available fields, a lower bound for that observed set. Shared pages can be counted for multiple processes. It is not total physical RAM, a proven complete forest, product peak or p95. A sample must finish within its duration; scheduling can place summary/output closure afterward, so MAIN must independently bound tool exit and output closure.

The reused controlled-tree result contains three PID/start owners, 180 samples, 370 records, real reparenting and natural termination bounds. Its sampled known-live RSS peak is 73,891,840 bytes; unrelated unavailable candidate counts were 177..179 and tracked unknown counts were 0. Direct root wait/exit 0 and exported parent FD closure were observed; child/grandchild actual wait exit codes are null. Kernel PID reuse was not observed: reuse, permissions, malformed clock/data/markers and output limits are separately labeled synthetic decisions. No complete descendant FD/reaping, real ArkTrace performance/cancel, quiet-20-sample, GUI, device, Windows or overall macOS acceptance is included.
