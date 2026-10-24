# Changelog

All notable changes to ArkTrace are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project intends to use [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once it has a stable release.

ArkTrace is in development. This repository does not publish git tags or
GitHub Releases. History before this file is the git log on `main`.

## [Unreleased]

### Added

- Public contributor entry points: `CONTRIBUTING.md`, `SECURITY.md`,
  `CODE_OF_CONDUCT.md`, GitHub issue and pull request templates,
  `.github/CODEOWNERS`, and a root `justfile` that wraps the existing build,
  test, lint, and CI-plan commands.

### Changed

- Repository roots are lowercase: `Sources/` is now `sources/`, `Tests/` is
  now `tests/`, and `third_party/TraceStreamer/` is now
  `third_party/trace-streamer/`. `Package.swift` sets an explicit `path:` for
  every target; target and module names are unchanged. The macOS
  TraceStreamer `buildRecipeVersion` is re-pinned because the build script's
  bytes changed; the pinned binary SHA-256 is unchanged and was not rebuilt.
- Top-level directories are consolidated: `bindings/` is now `api/bindings/`,
  `fuzz/` is now `rust/fuzz/` (still a separate cargo-fuzz workspace,
  excluded from `rust/Cargo.toml`), and the Swift test targets moved from
  `tests/<Target>/` to `test/swift/<Target>/` next to `test/fixtures/`. Target
  names are unchanged. Oracle receipts that pin current source bytes are
  re-pinned for the moved paths and the one-hop-deeper `#filePath` root
  lookups in the tests; the Swift oracles were not re-run.
