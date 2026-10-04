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
    case "$expected" in
        *lane_rust_macos=*) ;;
        *) expected="$expected
lane_rust_macos=false
lane_rust_windows=false" ;;
    esac
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
lane_contracts=true
lane_rust_macos=true
lane_rust_windows=true'

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

expect "the palette table selects the contract lane too (verify_palette.py reads it)" \
    'lane_swiftpm=true
lane_app=true
lane_contracts=true' \
    'Sources/ArkTraceRendering/TimelineColorPalette.swift'

expect "another rendering source keeps the compile lanes only" \
    'lane_swiftpm=true
lane_app=true
lane_contracts=false' \
    'Sources/ArkTraceRendering/TimelineNSView.swift'

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

expect "shared Rust source runs on both native platforms" \
    'lane_swiftpm=false
lane_app=false
lane_contracts=false
lane_rust_macos=true
lane_rust_windows=true' 'rust/crates/arktrace-contract/src/time.rs'

expect "contract vectors run both languages and native platforms" \
    'lane_swiftpm=true
lane_app=false
lane_contracts=true
lane_rust_macos=true
lane_rust_windows=true' 'contracts/time-range-vectors.json'

expect "bindings select their consuming builds" "$all_lanes" 'bindings/Swift/Engine.swift'

expect "Windows files select Windows and contract checks" \
    'lane_swiftpm=false
lane_app=false
lane_contracts=true
lane_rust_macos=false
lane_rust_windows=true' 'windows/SDK/Engine.cs'

expect "production Viewer JSON consumer runs on both native platforms" \
    'lane_swiftpm=false
lane_app=false
lane_contracts=false
lane_rust_macos=true
lane_rust_windows=true' 'scripts/test_viewer_json_roundtrip.py'

expect "Rust documentation does not build" "$docs_only" 'rust/README.md'

expect "cargo runner change fails closed" "$all_lanes" 'scripts/run-cargo.py'

expect "Swift native SDK selects macOS artifact and contract gates" \
    'lane_swiftpm=false
lane_app=false
lane_contracts=true
lane_rust_macos=true
lane_rust_windows=false' 'Sources/ArkTraceRustRuntime/RustEngine.swift
scripts/swift-sdk-conformance/Consumer.swift
scripts/swift-sdk-lifecycle/Lifecycle.swift
scripts/test_macos_rust_sdk.py
scripts/test_macos_rust_lifecycle.py'

expect "native APFS harness selects the macOS Rust lane" \
    'lane_swiftpm=false
lane_app=false
lane_contracts=true
lane_rust_macos=true
lane_rust_windows=false' 'scripts/test_macos_file_volumes.py'

expect "native parser process harness selects the macOS Rust lane" \
    'lane_swiftpm=false
lane_app=false
lane_contracts=true
lane_rust_macos=true
lane_rust_windows=false' 'scripts/test_macos_parser_process.py'

expect "native directory commands harness selects the macOS Rust lane" \
    'lane_swiftpm=false
lane_app=false
lane_contracts=true
lane_rust_macos=true
lane_rust_windows=false' 'scripts/test_macos_directory_commands.py'

for path in scripts/test_macos_event_queries.py scripts/test_macos_slice_queries.py scripts/test_macos_counter_queries.py scripts/test_macos_frame_queries.py scripts/test_macos_argument_queries.py scripts/test_macos_search.py scripts/test_macos_density_queries.py scripts/test_macos_batch_queries.py scripts/test_macos_async_runtime.py scripts/test_macos_viewer_owner.py scripts/test_macos_viewport_owner.py scripts/test_macos_ffi_owner.py scripts/test_macos_bounded_analysis.py scripts/test_macos_rust_cli.py scripts/build_macos_rust_cli_candidate.py ThirdParty/TraceStreamer/macx/manifest.json; do
    expect "native packaged CLI inputs select the macOS Rust lane" \
        'lane_swiftpm=false
lane_app=false
lane_contracts=true
lane_rust_macos=true
lane_rust_windows=false' "$path"
done

for path in scripts/generate_ffi_bindings.py scripts/ffi_test_support.py scripts/test_ffi_contract.py; do
    expect "generated ABI inputs select both Rust host consumers" \
        'lane_swiftpm=false
lane_app=false
lane_contracts=true
lane_rust_macos=true
lane_rust_windows=true' "$path"
done

if [ "$failures" -gt 0 ]; then
    printf 'ci-plan: %d failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'ci-plan: all planner cases passed\n'
