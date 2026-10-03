#!/bin/sh
# CI lane planner. Reads one changed path per line on stdin and prints the
# lane plan as KEY=true/false lines:
#
#   lane_swiftpm   - SwiftPM build + full test suite + skip audit
#   lane_app       - Xcode app-target build + bundle document-type checks
#   lane_contracts - offline release/contract gates (licenses, parser lock,
#                    phase6 evidence, distribution and planner contracts)
#   lane_rust_macos / lane_rust_windows - pinned workspace on native hosts
#
# Fail-closed rules:
#   - an empty input selects every lane (an unknown diff is treated as "could
#     be anything", exactly like an unresolvable merge base);
#   - any path that matches no known rule selects every lane;
#   - workflow or planner changes select every lane.
#
# The mapping follows the actual target graph. Tests and CLI-only modules do
# not rebuild the GUI; modules linked by ArkTraceApp still select both compile
# lanes. Unknown source modules fail closed because their graph is not known.
set -eu

swiftpm=false
app=false
contracts=false
rust_macos=false
rust_windows=false
saw_any=false

select_all() {
    swiftpm=true
    app=true
    contracts=true
    rust_macos=true
    rust_windows=true
}

while IFS= read -r path; do
    [ -n "$path" ] || continue
    saw_any=true
    case "$path" in
        .github/workflows/*|scripts/ci_plan.sh|scripts/test_ci_plan.sh|scripts/run-swiftpm.sh|scripts/test_run_swiftpm.py|scripts/run-xcodebuild.sh|scripts/test_run_xcodebuild.py|scripts/run-cargo.py|scripts/test_run_cargo.py|scripts/verify_rust_workspace.py)
            # The planner cannot prove anything about a change to itself.
            select_all
            ;;
        rust/*.md|rust/*/*.md|contracts/*.md|bindings/*.md|windows/*.md)
            ;;
        scripts/test_viewer_json_roundtrip.py)
            rust_macos=true
            rust_windows=true
            ;;
        rust/*)
            rust_macos=true
            rust_windows=true
            ;;
        scripts/generate_ffi_bindings.py|scripts/ffi_test_support.py|scripts/test_ffi_contract.py)
            contracts=true
            rust_macos=true
            rust_windows=true
            ;;
        contracts/*)
            # Shared vectors are consumed by both language implementations.
            swiftpm=true
            contracts=true
            rust_macos=true
            rust_windows=true
            ;;
        bindings/*)
            swiftpm=true
            app=true
            contracts=true
            rust_macos=true
            rust_windows=true
            ;;
        windows/*)
            contracts=true
            rust_windows=true
            ;;
        Package.swift)
            swiftpm=true
            app=true
            ;;
        Sources/ArkTraceRendering/TimelineColorPalette.swift)
            # The palette tables are also an offline contract:
            # scripts/verify_palette.py reads this file and re-measures every
            # figure AT-RENDER-008 quotes, so an edit here has to run the
            # contract lane as well as both compile lanes.
            swiftpm=true
            app=true
            contracts=true
            ;;
        Sources/ArkTraceCore/*|Sources/ArkTraceParser/*|Sources/ArkTraceStore/*|Sources/ArkTraceRuntime/*|Sources/ArkTraceAnalysis/*|Sources/ArkTraceRendering/*|Sources/ArkTraceAppSupport/*|Sources/ArkTraceCapture/*)
            # These modules are linked directly or transitively by ArkTraceApp.
            swiftpm=true
            app=true
            ;;
        Sources/ArkTraceCLI/*|Sources/ArkTraceSignalShim/*|Sources/ArkTraceCLIResourceFixtures/*|Sources/arktrace/*|Tests/*)
            # Tests and command-line-only targets never feed the app binary.
            swiftpm=true
            ;;
        Sources/*)
            # A newly added source target has unknown app reachability.
            select_all
            ;;
        scripts/api-baseline/*|scripts/test_api_baseline.sh)
            # The API baseline compiles against the package surface, so it
            # rides the SwiftPM lane rather than the offline contract lane.
            swiftpm=true
            ;;
        scripts/test_macos_file_volumes.py|scripts/test_macos_parser_process.py|scripts/test_macos_directory_commands.py|scripts/test_macos_event_queries.py|scripts/test_macos_slice_queries.py|scripts/test_macos_counter_queries.py|scripts/test_macos_frame_queries.py|scripts/test_macos_argument_queries.py|scripts/test_macos_search.py|scripts/test_macos_density_queries.py|scripts/test_macos_batch_queries.py|scripts/test_macos_async_runtime.py|scripts/test_macos_viewer_owner.py|scripts/test_macos_viewport_owner.py|scripts/test_macos_ffi_owner.py|scripts/test_macos_bounded_analysis.py|scripts/test_macos_rust_cli.py|scripts/build_macos_rust_cli_candidate.py|ThirdParty/TraceStreamer/macx/manifest.json)
            # This native acceptance harness consumes the macOS Rust port.
            rust_macos=true
            contracts=true
            ;;
        Apps/*|ArkTrace.xcodeproj/*)
            app=true
            contracts=true
            ;;
        Config/*)
            # Product identity is mirrored into Swift constants (SwiftPM
            # tests), stamped into the app, and pinned by release contracts.
            select_all
            ;;
        Fixtures/*)
            # Test fixtures feed SwiftPM tests; release evidence feeds gates.
            swiftpm=true
            contracts=true
            ;;
        scripts/*|ThirdParty/*|LICENSE|THIRD_PARTY_NOTICES.md)
            contracts=true
            ;;
        docs/PHASE_6_SCENARIO.md)
            # The phase6 offline gate binds this frozen scenario document.
            contracts=true
            ;;
        README.md|README.zh-CN.md)
            # `ShortcutCatalogTests` generates the shortcut tables in both
            # READMEs from `TraceShortcutCatalog` and fails on drift. Skipping
            # the SwiftPM lane for a README-only edit would skip exactly the
            # change that assertion exists to catch.
            swiftpm=true
            ;;
        docs/*|*.md|.gitignore)
            # Documentation-only paths request no compile lane on their own.
            ;;
        *)
            # Unknown path: fail closed.
            select_all
            ;;
    esac
done

if [ "$saw_any" = false ]; then
    select_all
fi

printf 'lane_swiftpm=%s\n' "$swiftpm"
printf 'lane_app=%s\n' "$app"
printf 'lane_contracts=%s\n' "$contracts"
printf 'lane_rust_macos=%s\n' "$rust_macos"
printf 'lane_rust_windows=%s\n' "$rust_windows"
