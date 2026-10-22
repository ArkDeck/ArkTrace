# ArkTrace fuzz targets

This is a separate Cargo workspace so `libfuzzer-sys` stays out of the runtime
workspace. It mirrors the ArkForge layout: short nightly runs live in
`.github/workflows/fuzz-nightly.yml`.

`ffi-request` and `ffi-config` decode the same JSON the C ABI accepts for
`arktrace_request_submit` and engine creation, including the closed status
returned for invalid input. `htrace-systrace` fuzzes the session-open gate that
admits format 1 (htrace) and format 2 (systrace) paths. The bytes inside those
trace files are parsed by the pinned TraceStreamer executable, which is not
linked into this workspace.

Build and run one target with nightly Rust and cargo-fuzz 0.13.2:

```sh
cargo +nightly fuzz run ffi-request -- -max_total_time=15 -timeout=5 -max_len=4096
```
