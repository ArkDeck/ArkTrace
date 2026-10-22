# Contributing to ArkTrace

Thanks for helping improve ArkTrace. This file is the public entry point. Day-to-day
agent and maintainer boundaries live in [AGENTS.md](AGENTS.md). Product behavior is
[docs/design/SPECIFICATION.md](docs/design/SPECIFICATION.md). Architecture is
[docs/design/DESIGN.md](docs/design/DESIGN.md). The CLI contract is
[docs/guides/CLI.md](docs/guides/CLI.md).

Please read the [Code of Conduct](CODE_OF_CONDUCT.md) before participating.

## What you can change

ArkTrace is a local trace workbench: a macOS app, a host-only `arktrace` CLI, and
a Windows x64 CLI. The app can capture from a device the user selects. The CLI
and the analysis engine do not gain device control.

Ordinary product work is one pull request: the behavior, the tests that prove
it, and the docs that describe it. Keep these boundaries:

- A raw trace is not modified in place, and parsing or analysis does not upload it.
- The production parser is the pinned TraceStreamer identity, not a binary chosen from `PATH`.
- CLI and API output stays typed, bounded, and versioned. It does not expose raw SQL, and machine output and product errors do not include a user's absolute path.
- Disk IO, hashing, parsing, and database work in shared modules stays off the main actor.

Do not open a pull request whose only content is a status flip, a readiness note,
or a release tag. This repository does not cut git tags as part of routine work.
The project is in development.

## Setup

You need the tools listed in [README.md](README.md#requirements):

- an Apple silicon Mac running macOS 26 or later, with Xcode 27.0 (Swift 6.4), for the app and the Swift package
- Rust from [`rust/rust-toolchain.toml`](rust/rust-toolchain.toml) (exact 1.99.0) for the workspace
- a Windows x64 native runner when the change must prove the Windows CLI
- an OpenHarmony `hdc` executable only when the work captures from a device

The root [`justfile`](justfile) wraps the existing commands. It does not introduce
a second build system. Run `just` to list recipes. The same commands work without
`just`.

## Build, test, and lint

From the repository root:

```bash
just build-swift    # Swift package
just build-app      # macOS app
just check-rust     # pinned Rust workspace
just test-swift     # Swift package tests
just test-rust      # arktrace-cli tests
just fmt            # rustfmt check
just lint           # rustfmt, clippy on arktrace-contract, workspace verifier
just ci-plan        # print the path-aware lane plan; it does not run the lanes
```

Equivalent commands, if `just` is not installed:

```bash
sh hack/run-swiftpm.sh build
sh hack/run-swiftpm.sh test --filter '<suite>'
sh hack/run-xcodebuild.sh
python3 hack/run-cargo.py check -p '<crate>'
python3 hack/run-cargo.py test -p '<crate>'
python3 hack/run-cargo.py fmt --all -- --check
python3 hack/run-cargo.py clippy -p arktrace-contract --all-targets -- -D warnings
python3 hack/verify_rust_workspace.py
```

Targeted checks before push:

- Rust formatting: `python3 hack/run-cargo.py fmt --all -- --check`
- For each crate you changed: `python3 hack/run-cargo.py clippy -p <crate> --all-targets -- -D warnings` and `python3 hack/run-cargo.py test -p <crate>`
- Rust workspace edges: `python3 hack/verify_rust_workspace.py`
- Swift: `sh hack/run-swiftpm.sh test --filter <suite>`
- App changes: `sh hack/run-xcodebuild.sh`
- Public Swift API or a dependency edge: `sh hack/test_api_baseline.sh`
- The lane plan for the diff: `just ci-plan`, or pipe changed paths into `sh hack/ci_plan.sh`

The runners keep a stable source mirror and cache. Do not pass `--package-path`,
`--scratch-path`, or `--cache-path` to the SwiftPM runner. Do not run the full
CI matrix locally. GitHub `CI required` is the complete gate. Windows product
verification has to run on a Windows x64 native runner.

## Pull requests

1. Branch from the latest `main`. Use an `agent/<short-topic>` branch for
   agent-drafted work. The name must match `agent/**`.
2. Keep the branch independent. Do not stack it on another open pull request.
   Rebase onto `main` when `main` moves.
3. Push the branch. [`.github/workflows/agent-pr.yml`](.github/workflows/agent-pr.yml)
   opens the pull request as `github-actions[bot]`. Do not open a second pull
   request for the same branch.
4. Write the title and body in English. State what changed, why, and how you
   checked it. The template is
   [`.github/PULL_REQUEST_TEMPLATE.md`](.github/PULL_REQUEST_TEMPLATE.md).
5. The required status check on `main` is `CI required`. A green check is
   verification, not maintainer approval.
6. A human CODEOWNER review is required before merge. See
   [`.github/CODEOWNERS`](.github/CODEOWNERS). Agents do not merge.

Merge is a maintainer action. This repository accepts rebase merges only.
Do not force-push `main`.

## Secrets and trace data

Do not commit device serial numbers, account names, machine names, home
directory paths, signing keys, or raw traces that contain private data. Logs
and evidence that land in the repository must already be redacted.

Report vulnerabilities privately, as described in [SECURITY.md](SECURITY.md).
Do not file a public issue for a security report.

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
