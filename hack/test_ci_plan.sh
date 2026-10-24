#!/bin/sh
# Unit tests for hack/ci_plan.sh. Hermetic: the planner reads paths from
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

expect "dependabot config skips every compile lane" "$docs_only" \
    '.github/dependabot.yml'

expect "docs-only change skips every compile lane" "$docs_only" \
    'docs/design/DESIGN.md
docs/design/SPECIFICATION.md'

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
    'sources/ArkTraceCore/Model/TraceModels.swift'

expect "test change selects only the SwiftPM lane" \
    'lane_swiftpm=true
lane_app=false
lane_contracts=false' \
    'tests/ArkTraceCoreTests/TraceTimeTests.swift'

expect "CLI-only source selects only the SwiftPM lane" \
    'lane_swiftpm=true
lane_app=false
lane_contracts=false' \
    'sources/ArkTraceCLI/CLIApplication.swift
sources/ArkTraceSignalShim/SignalShim.c
sources/arktrace/main.swift'

expect "new source module fails closed to every lane" "$all_lanes" \
    'sources/NewProductModule/Feature.swift'

expect "manifest change selects SwiftPM and app lanes" \
    'lane_swiftpm=true
lane_app=true
lane_contracts=false' \
    'Package.swift'

expect "app change selects app and contract lanes" \
    'lane_swiftpm=false
lane_app=true
lane_contracts=true' \
    'apple/Apps/ArkTraceApp/ArkTraceApp.swift
apple/ArkTrace.xcodeproj/project.pbxproj'

expect "product config selects every lane" "$all_lanes" \
    'apple/Config/ArkTraceProduct.xcconfig'

expect "script change selects the contract lane" \
    'lane_swiftpm=false
lane_app=false
lane_contracts=true' \
    'hack/verify_licenses.sh'

expect "the palette table selects the contract lane too (verify_palette.py reads it)" \
    'lane_swiftpm=true
lane_app=true
lane_contracts=true' \
    'sources/ArkTraceRendering/TimelineColorPalette.swift'

expect "ArkDeck version sources also run the contract lane" \
    'lane_swiftpm=true
lane_app=true
lane_contracts=true' \
    'sources/ArkTraceParser/TraceStreamerProcessParser.swift
sources/ArkTraceStore/TraceSchemaAdapter.swift
sources/ArkTraceStore/TraceDatabaseStagingPreparer.swift'

expect "Rust ArkDeck constants select both hosts and the contract lane" \
    'lane_swiftpm=false
lane_app=false
lane_contracts=true
lane_rust_macos=true
lane_rust_windows=true' \
    'rust/crates/arktrace-contract/src/lib.rs'

expect "another rendering source keeps the compile lanes only" \
    'lane_swiftpm=true
lane_app=true
lane_contracts=false' \
    'sources/ArkTraceRendering/TimelineNSView.swift'

expect "API baseline change selects the SwiftPM lane" \
    'lane_swiftpm=true
lane_app=false
lane_contracts=false' \
    'hack/api-baseline/Sources/ArkTraceAPIBaseline/APIBaseline.swift'

expect "fixture change selects SwiftPM and contract lanes" \
    'lane_swiftpm=true
lane_app=false
lane_contracts=true' \
    'test/fixtures/traces/zlib.htrace'

expect "phase6 scenario doc feeds the phase6 gate" \
    'lane_swiftpm=false
lane_app=false
lane_contracts=true' \
    'docs/archive/PHASE_6_SCENARIO.md'

expect "workflow change fails closed to every lane" "$all_lanes" \
    '.github/workflows/ci.yml'

expect "planner self-change fails closed to every lane" "$all_lanes" \
    'hack/ci_plan.sh'

expect "stable build runner change fails closed to every lane" "$all_lanes" \
    'hack/run-swiftpm.sh
hack/test_run_xcodebuild.py'

expect "native App preparation selects every lane" "$all_lanes" \
    'hack/prepare_macos_native_app.py
hack/copy_native_app_resources.py
hack/test_native_app_resources.py
hack/native_app_distribution_safety.sh
hack/test_native_app_build.sh'

expect "unknown path fails closed to every lane" "$all_lanes" \
    'mystery/new-subsystem.c'

expect "empty diff (unresolvable base) fails closed to every lane" \
    "$all_lanes" ''

expect "mixed docs and source keeps the compile lanes" \
    'lane_swiftpm=true
lane_app=true
lane_contracts=false' \
    'README.md
sources/ArkTraceCore/Model/TraceModels.swift'

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
lane_rust_windows=true' 'api/time-range-vectors.json'

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
lane_rust_windows=true' 'hack/test_viewer_json_roundtrip.py'

expect "argument query harness selects macOS and contracts" \
    'lane_swiftpm=false
lane_app=false
lane_contracts=true
lane_rust_macos=true
lane_rust_windows=false' 'hack/test_macos_argument_queries.py'

expect "Rust documentation does not build" "$docs_only" 'rust/README.md'

expect "cargo runner change fails closed" "$all_lanes" 'hack/run-cargo.py'
expect "cargo cache management selects every lane" "$all_lanes" 'hack/cargo_cache.py'
expect "cargo cache regression gate selects every lane" "$all_lanes" 'hack/test_cargo_cache.py'

expect "Swift native SDK selects macOS artifact and contract gates" \
    'lane_swiftpm=false
lane_app=false
lane_contracts=true
lane_rust_macos=true
lane_rust_windows=false' 'sources/ArkTraceRustRuntime/RustEngine.swift
hack/swift-sdk-conformance/Consumer.swift
hack/swift-sdk-lifecycle/Lifecycle.swift
hack/test_macos_rust_sdk.py
hack/test_macos_rust_lifecycle.py'

expect "typed directory SDK tests use the artifact-enabled macOS lane" \
    'lane_swiftpm=false
lane_app=false
lane_contracts=true
lane_rust_macos=true
lane_rust_windows=false' 'tests/ArkTraceRustRuntimeTests/DirectoryPageTests.swift'

expect "package-external directory owner selects the native SDK compile gate" \
    'lane_swiftpm=false
lane_app=false
lane_contracts=true
lane_rust_macos=true
lane_rust_windows=false' 'hack/swift-sdk-directory/DirectoryOwnership.swift
hack/test_macos_directory_sdk.py'

expect "package-external summary owner selects the native SDK compile gate" \
    'lane_swiftpm=false
lane_app=false
lane_contracts=true
lane_rust_macos=true
lane_rust_windows=false' 'hack/swift-sdk-summary/SummaryOwnership.swift
hack/test_macos_summary_sdk.py'

for path in hack/swift-sdk-core/CoreOwnership.swift hack/test_macos_core_sdk.py hack/test_macos_event_sdk.py hack/test_macos_density_sdk.py hack/test_macos_batch_sdk.py hack/test_macos_deadline_sdk.py hack/test_macos_repository_sdk.py; do
    expect "Core SDK consumer input selects the artifact-enabled macOS lane" \
        'lane_swiftpm=false
lane_app=false
lane_contracts=true
lane_rust_macos=true
lane_rust_windows=false' "$path"
done

expect "native APFS harness selects the macOS Rust lane" \
    'lane_swiftpm=false
lane_app=false
lane_contracts=true
lane_rust_macos=true
lane_rust_windows=false' 'hack/test_macos_file_volumes.py'

expect "native parser process harness selects the macOS Rust lane" \
    'lane_swiftpm=false
lane_app=false
lane_contracts=true
lane_rust_macos=true
lane_rust_windows=false' 'hack/test_macos_parser_process.py'

expect "native directory commands harness selects the macOS Rust lane" \
    'lane_swiftpm=false
lane_app=false
lane_contracts=true
lane_rust_macos=true
lane_rust_windows=false' 'hack/test_macos_directory_commands.py'

for path in hack/test_macos_event_queries.py hack/test_macos_slice_queries.py hack/test_macos_counter_queries.py hack/test_macos_frame_queries.py hack/test_macos_argument_queries.py hack/test_macos_search.py hack/test_macos_density_queries.py hack/test_macos_batch_queries.py hack/test_macos_async_runtime.py hack/test_macos_viewer_owner.py hack/test_macos_viewport_owner.py hack/test_macos_ffi_owner.py hack/test_macos_bounded_analysis.py hack/test_macos_rust_cli.py hack/build_macos_rust_cli_candidate.py third_party/trace-streamer/macx/manifest.json; do
    expect "native packaged CLI inputs select the macOS Rust lane" \
        'lane_swiftpm=false
lane_app=false
lane_contracts=true
lane_rust_macos=true
lane_rust_windows=false' "$path"
done

for path in hack/generate_ffi_bindings.py hack/ffi_test_support.py hack/test_ffi_contract.py hack/verify_migration_contracts.py hack/test_migration_contracts.py hack/verify_arkdeck_contract.py rust/dependency-licenses.json rust/licenses/serde-1.0.229/LICENSE-MIT; do
    expect "shared ABI and oracle gates select both Rust host consumers" \
        'lane_swiftpm=false
lane_app=false
lane_contracts=true
lane_rust_macos=true
lane_rust_windows=true' "$path"
done

for path in hack/stage_windows_cli_candidate.py hack/package_windows_cli_distribution.py hack/verify_windows_cli_distribution.py hack/windows_cli_distribution.py hack/smoke_windows_cli_distribution.py hack/test_windows_cli_distribution_contract.py third_party/trace-streamer/windows-x86_64/manifest.json third_party/trace-streamer/license-inventory.json third_party/trace-streamer/windows-license-inventory.json third_party/trace-streamer/LICENSES/zlib-Zlib.txt third_party/trace-streamer/LICENSES-windows/gcc-COPYING.RUNTIME; do
    expect "Windows distribution inputs select its Rust consumer and contract checks" \
        'lane_swiftpm=false
lane_app=false
lane_contracts=true
lane_rust_macos=false
lane_rust_windows=true' "$path"
done

if [ "$failures" -gt 0 ]; then
    printf 'ci-plan: %d failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'ci-plan: all planner cases passed\n'
