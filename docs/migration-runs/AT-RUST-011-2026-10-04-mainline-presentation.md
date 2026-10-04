# AT-RUST-011 — mainline shared palette and presentation module

Status: **in progress**. Base: `6fdd34a8289b314f30ecff0d73713db2320c7b2d`.
Rust 1.99.0 / edition 2024, Xcode 27.0 / 27A266a, Swift 6.4 / language mode 6.
[Machine record](AT-RUST-011-2026-10-04-mainline-presentation.json) retains the
exact reviewed import list, fresh actual Swift receipt and mainline check receipts.

The reviewed parallel delivery adds shared Rust palette and bounded presentation
facts to `arktrace-viewer`. Exactly eighteen owned files were imported; the only
existing Rust source change appends two modules and their exports to `lib.rs`.
No manifest, dependency lock, generated record, Engine, SDK or App source was
copied from the snapshot. The original reviewed receipt and checksum are
preserved. A separate fresh mainline receipt records the replay.

Mainline execution passes **356** Rust tests, including **72** viewer tests,
with zero failures/ignored tests and strict format/clippy/workspace checks.
The actual current Swift implementations were executed again through
cache-only test accessors: **1,068** palette, **38** style discriminator and
**62** DTO cases, **1,168** in total. Complete output bytes match the reviewed
actual Swift output. The **26** selected existing Swift rendering regressions
also pass. The migration verifier now checks complete current Core/Rendering
source identities, input/output digests, oracle accessors, case order and counts.
License, parser lock, palette, generated ABI and 51 planner checks pass.

The complete diff selects contracts and both native Rust lanes. Swift/App
production sources and ABI are unchanged. These pure modules have not been
connected to production Engine projection or immutable snapshot packing;
they supply no new native wire, SDK painting or App acceptance evidence.
The previous 1,000-cycle SDK gate identifies its own frozen artifact and does
not automatically cover a later snapshot/ABI/owner change.

Presentation preserves true detail EventKey, source identity and bounded UTF-8;
density facts have no invented EventKey. Cancellation is checked while scanning,
and output is bounded/all-or-error. The parallel report documents exact retained
struct/Vec/String accounting and excluded allocator/transient overhead.
Production integration still needs primitive/fact association, shared retained
budgets across geometry/quality/presentation, generated versioned records,
ownership/stale/cancel regressions and fresh wire/SDK/App checks.

Two existing implementation/specification gaps remain explicit: actual Swift
uses track color when density dominant is absent for every source, and renders
actual frames at depth one. The specification describes narrower fallback and
zero non-named depth. This import preserves the measured implementation; it
does not silently change the specification or resolve the product rules.

Original and fresh evidence is frozen under Git-ignored
`.build/agent-coordination/arktrace/presentation-mainline-20261004/`.
AT-RUST-011 and final macOS cross-platform acceptance remain incomplete.
