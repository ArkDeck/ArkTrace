#!/bin/sh
# Unit tests for scripts/ci_plan.sh. Hermetic: the planner reads paths from
# stdin, so every case is a here-doc — no git state involved.
set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
planner="$script_directory/ci_plan.sh"
failures=0

expect() {
    description=$1
    expected=$2
    input=$3
    actual=$(printf '%s\n' "$input" | sh "$planner")
    if [ "$actual" = "$expected" ]; then
        printf 'ci-plan: ok   %s\n' "$description"
    else
        printf 'ci-plan: FAIL %s\n  expected:\n%s\n  actual:\n%s\n' \
            "$description" "$expected" "$actual" >&2
        failures=$((failures + 1))
    fi
}

all_lanes='lane_swiftpm=true
lane_app=true
lane_contracts=true'

docs_only='lane_swiftpm=false
lane_app=false
lane_contracts=false'

expect "docs-only change skips every compile lane" "$docs_only" \
    'docs/DESIGN.md
docs/SPECIFICATION.md'

expect "README change selects the SwiftPM lane (shortcut tables are asserted)" \
    'lane_swiftpm=true
lane_app=false
lane_contracts=false' \
    'README.md
README.zh-CN.md'

expect "app-linked source selects SwiftPM and app lanes" \
    'lane_swiftpm=true
lane_app=true
lane_contracts=false' \
    'Sources/ArkTraceCore/Model/TraceModels.swift'

expect "test change selects only the SwiftPM lane" \
    'lane_swiftpm=true
lane_app=false
lane_contracts=false' \
    'Tests/ArkTraceCoreTests/TraceTimeTests.swift'

expect "CLI-only source selects only the SwiftPM lane" \
    'lane_swiftpm=true
lane_app=false
lane_contracts=false' \
    'Sources/ArkTraceCLI/CLIApplication.swift
Sources/ArkTraceSignalShim/SignalShim.c
Sources/arktrace/main.swift'

expect "new source module fails closed to every lane" "$all_lanes" \
    'Sources/NewProductModule/Feature.swift'

expect "manifest change selects SwiftPM and app lanes" \
    'lane_swiftpm=true
lane_app=true
lane_contracts=false' \
    'Package.swift'

expect "app change selects app and contract lanes" \
    'lane_swiftpm=false
lane_app=true
lane_contracts=true' \
    'Apps/ArkTraceApp/ArkTraceApp.swift
ArkTrace.xcodeproj/project.pbxproj'

expect "product config selects every lane" "$all_lanes" \
    'Config/ArkTraceProduct.xcconfig'

expect "script change selects the contract lane" \
    'lane_swiftpm=false
lane_app=false
lane_contracts=true' \
    'scripts/verify_licenses.sh'

expect "API baseline change selects the SwiftPM lane" \
    'lane_swiftpm=true
lane_app=false
lane_contracts=false' \
    'scripts/api-baseline/Sources/ArkTraceAPIBaseline/APIBaseline.swift'

expect "fixture change selects SwiftPM and contract lanes" \
    'lane_swiftpm=true
lane_app=false
lane_contracts=true' \
    'Fixtures/traces/zlib.htrace'

expect "phase6 scenario doc feeds the phase6 gate" \
    'lane_swiftpm=false
lane_app=false
lane_contracts=true' \
    'docs/PHASE_6_SCENARIO.md'

expect "workflow change fails closed to every lane" "$all_lanes" \
    '.github/workflows/ci.yml'

expect "planner self-change fails closed to every lane" "$all_lanes" \
    'scripts/ci_plan.sh'

expect "stable build runner change fails closed to every lane" "$all_lanes" \
    'scripts/run-swiftpm.sh
scripts/test_run_xcodebuild.py'

expect "unknown path fails closed to every lane" "$all_lanes" \
    'mystery/new-subsystem.c'

expect "empty diff (unresolvable base) fails closed to every lane" \
    "$all_lanes" ''

expect "mixed docs and source keeps the compile lanes" \
    'lane_swiftpm=true
lane_app=true
lane_contracts=false' \
    'README.md
Sources/ArkTraceCore/Model/TraceModels.swift'

if [ "$failures" -gt 0 ]; then
    printf 'ci-plan: %d failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'ci-plan: all planner cases passed\n'
