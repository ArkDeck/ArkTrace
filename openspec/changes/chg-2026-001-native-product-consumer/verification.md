# Verification

This change supplies fixed native product composition and packaging. No
signed distribution, sandboxed App acceptance or hardware result is claimed.

## Local targeted checks

2026-10-29, macOS arm64, Xcode 27.1 / Swift 6.4, Rust 1.99.0:

- `python3 -B hack/test_native_app_resources.py`: exit 0, 7 tests.
  Log: `/private/tmp/arkdeck-main-sync-20261029/upstream-native-resources.log`.
- `python3 -B hack/test_stage_macos_rust_sdk.py`: exit 0, 6 tests.
  Log: `/private/tmp/arkdeck-main-sync-20261029/upstream-sdk-staging.log`.
- `python3 -B hack/build_macos_rust_sdk.py`: exit 0, normal ABI-2 SDK.
  Log: `/private/tmp/arkdeck-main-sync-20261029/upstream-sdk-build.log`.
- `sh hack/run-swiftpm.sh test --filter TraceBundledRustRuntimeTests`, with
  that explicit normal SDK: exit 0, 6 tests, no compiler warnings.
  Log: `/private/tmp/arkdeck-main-sync-20261029/upstream-swift-tests.log`.
- Fixed `arkdeck` input preparation with the same SDK: exit 0; unsigned,
  runtimeUsable=false. No signing identity or production cache was used.
  Log: `/private/tmp/arkdeck-main-sync-20261029/native-inputs.log`.

- `sh hack/test_api_baseline.sh` from the staged cache-owned package, with
  the same normal SDK: exit 0, no compiler warnings.
  Log: `/private/tmp/arkdeck-main-sync-20261029/upstream-api-baseline.log`.

The existing native App CI gate also runs this baseline after staging its
normal SDK. Standalone
Debug/Release App builds are left to the selected CI App lane; the dependent
ArkDeck PR separately validates its own App graph. Rust source and contracts
are unchanged, so no full local Rust test matrix was run.

## CI

Pending the PR on the committed head. CI uses Xcode 27.0; local compilation
on 27.1 does not claim that pinned CI result.
