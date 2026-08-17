#!/bin/sh
# API baseline gate: compiles a consumer package that sits OUTSIDE the
# ArkTrace package boundary and touches every public symbol the app target
# uses. `package`-level symbols are invisible to it, so an over-eager access
# tightening fails here before it can break the app project or an external
# consumer. Compile-only: nothing in the baseline runs.
set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
baseline="$script_directory/api-baseline"

[ -f "$baseline/Package.swift" ] || {
    printf 'API baseline package is missing\n' >&2
    exit 1
}

swift build --package-path "$baseline" "$@"
printf 'API baseline: promised public surface compiles from outside the package\n'
