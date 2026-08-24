#!/bin/sh
# CI lane planner. Reads one changed path per line on stdin and prints the
# lane plan as KEY=true/false lines:
#
#   lane_swiftpm   - SwiftPM build + full test suite + skip audit
#   lane_app       - Xcode app-target build + bundle document-type checks
#   lane_contracts - offline release/contract gates (licenses, parser lock,
#                    phase6 evidence, distribution and planner contracts)
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
saw_any=false

select_all() {
    swiftpm=true
    app=true
    contracts=true
}

while IFS= read -r path; do
    [ -n "$path" ] || continue
    saw_any=true
    case "$path" in
        .github/workflows/*|scripts/ci_plan.sh|scripts/test_ci_plan.sh|scripts/run-swiftpm.sh|scripts/test_run_swiftpm.py|scripts/run-xcodebuild.sh|scripts/test_run_xcodebuild.py)
            # The planner cannot prove anything about a change to itself.
            select_all
            ;;
        Package.swift)
            swiftpm=true
            app=true
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
        Apps/*|ArkTrace.xcodeproj/*)
            app=true
            contracts=true
            ;;
        Config/*)
            # Product identity is mirrored into Swift constants (SwiftPM
            # tests), stamped into the app, and pinned by release contracts.
            swiftpm=true
            app=true
            contracts=true
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
