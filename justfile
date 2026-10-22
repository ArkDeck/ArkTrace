# ArkTrace task runner.
#
# Recipes wrap the scripts the repository already uses. They do not fetch
# dependencies, select a toolchain, or replace hack/ci_plan.sh.

set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

# List the recipes.
default:
    @just --list

# Build the Swift package.
build-swift:
    sh hack/run-swiftpm.sh build

# Build the macOS app. The Xcode runner accepts no extra arguments.
build-app:
    sh hack/run-xcodebuild.sh

# Build the Rust workspace with the pinned toolchain.
build-rust:
    python3 hack/run-cargo.py build

# Build the Swift package and the Rust workspace.
build: build-swift build-rust

# Test the Swift package. Pass an XCTest or Swift Testing filter.
test-swift filter="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -n "{{filter}}" ]]; then
        sh hack/run-swiftpm.sh test --filter "{{filter}}"
    else
        sh hack/run-swiftpm.sh test
    fi

# Test one Rust crate. Defaults to the CLI crate.
test-rust crate="arktrace-cli":
    python3 hack/run-cargo.py test -p {{crate}}

# Run the default Swift and Rust test entry points.
test: test-swift test-rust

# Type-check the Rust workspace, or one crate when crate is set.
check-rust crate="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -n "{{crate}}" ]]; then
        python3 hack/run-cargo.py check -p "{{crate}}"
    else
        python3 hack/run-cargo.py check
    fi

# Check rustfmt on the pinned workspace.
fmt:
    python3 hack/run-cargo.py fmt --all -- --check

# Format-check Rust, clippy one crate, and verify workspace edges.
lint crate="arktrace-contract":
    python3 hack/run-cargo.py fmt --all -- --check
    python3 hack/run-cargo.py clippy -p {{crate}} --all-targets -- -D warnings
    python3 hack/verify_rust_workspace.py

# Print the CI lane plan for commits since origin/main. This does not run the lanes.
ci-plan:
    #!/usr/bin/env bash
    set -euo pipefail
    base=$(git merge-base origin/main HEAD)
    git diff --name-only "$base" HEAD | sh hack/ci_plan.sh

# Run the planner's hermetic self-test.
planner-test:
    sh hack/test_ci_plan.sh
