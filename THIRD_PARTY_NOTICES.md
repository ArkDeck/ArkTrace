# ArkTrace Third-Party Notices

ArkTrace itself is licensed under the MIT License; the exact ArkTrace license
is distributed separately as `LICENSE`. The distributed macOS App and CLI
bundle the pinned OpenHarmony TraceStreamer executable. Its conservative
source-closure inventory is machine-readable at
`ThirdParty/TraceStreamer/license-inventory.json`; the exact corresponding
license texts are under `ThirdParty/TraceStreamer/LICENSES/`.

The shipped code includes components under Apache-2.0, MulanPSL-2.0,
bzip2-1.0.6, MIT, BSD-3-Clause, the zlib license, and SQLite's public-domain
dedication. The inventory also preserves notices for build-only inputs and
disabled plugins, including libbpf and LLVM, so a future plugin change cannot
silently escape review.

GN and Ninja are SHA-locked build tools and are not distributed with ArkTrace.
Their exact artifact identities and license texts are included in the same
inventory so the reproducible build toolchain is auditable as well.

No GPL/LGPL-only plugin is enabled in the ArkTrace TraceStreamer recipe.
`hiperf`, `ebpf`, and `native_hook` are excluded by the locked plugin list.
The profiler repository's shipped subset is Apache-2.0; its separately marked
kernel-mode eBPF sources are not part of this binary.

Source repositories and exact revisions are recorded in
`ThirdParty/TraceStreamer/source-lock.json`. Rebuild and source retrieval
instructions are in `docs/TRACE_STREAMER.md`; those HTTPS repositories are the
source offer for this distribution.
