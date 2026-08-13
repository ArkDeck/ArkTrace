#!/bin/sh
set -eu

fail() {
    printf 'Phase 3 batch 1 gate failed: %s\n' "$1" >&2
    exit 1
}

bounded_build_failure() {
    printf 'Xcode diagnostics withheld\n' >&2
}

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

scripts/test_phase2.sh
scripts/test_trace_streamer_build_safety.sh
scripts/test_license_verifier.sh
scripts/test_htrace_integrity_verifier.sh
scripts/test_phase3_benchmark_contract.sh
scripts/test_phase3_distribution_contract.sh

derived_data=$(mktemp -d /tmp/arktrace-phase3-app.XXXXXX)
app_log=$(mktemp /tmp/arktrace-phase3-app-log.XXXXXX)
cleanup() {
    rm -rf "$derived_data"
    rm -f "$app_log"
}
trap cleanup EXIT HUP INT TERM

if ! xcodebuild -quiet \
    -project ArkTrace.xcodeproj \
    -scheme ArkTraceApp \
    -configuration Debug \
    -derivedDataPath "$derived_data" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_REQUIRED=YES \
    build >"$app_log" 2>&1
then
    bounded_build_failure
    fail "Debug app build failed"
fi

if ! xcodebuild -quiet \
    -project ArkTrace.xcodeproj \
    -scheme ArkTraceApp \
    -configuration Release \
    -derivedDataPath "$derived_data" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_REQUIRED=YES \
    build >>"$app_log" 2>&1
then
    bounded_build_failure
    fail "Release candidate app build failed"
fi

app="$derived_data/Build/Products/Debug/ArkTrace.app"
release_app="$derived_data/Build/Products/Release/ArkTrace.app"
bundled_parser="$app/Contents/Helpers/trace_streamer"
bundled_manifest="$app/Contents/Resources/TraceStreamer/manifest.json"

codesign --verify --deep --strict "$app" >/dev/null 2>&1 \
    || fail "Debug app signature is invalid"
codesign --verify --deep --strict "$release_app" >/dev/null 2>&1 \
    || fail "Release candidate app signature is invalid"
cmp ThirdParty/TraceStreamer/macx/trace_streamer "$bundled_parser" >/dev/null 2>&1 \
    || fail "bundled parser bytes drifted"
cmp ThirdParty/TraceStreamer/macx/manifest.json "$bundled_manifest" >/dev/null 2>&1 \
    || fail "bundled parser manifest bytes drifted"
cmp ThirdParty/TraceStreamer/macx/trace_streamer \
    "$release_app/Contents/Helpers/trace_streamer" >/dev/null 2>&1 \
    || fail "Release bundled parser bytes drifted"
cmp ThirdParty/TraceStreamer/macx/manifest.json \
    "$release_app/Contents/Resources/TraceStreamer/manifest.json" >/dev/null 2>&1 \
    || fail "Release bundled parser manifest bytes drifted"
for candidate_app in "$app" "$release_app"; do
    cmp LICENSE "$candidate_app/Contents/Resources/LICENSE" >/dev/null 2>&1 \
        || fail "bundled ArkTrace product license bytes drifted"
    cmp THIRD_PARTY_NOTICES.md \
        "$candidate_app/Contents/Resources/THIRD_PARTY_NOTICES.md" >/dev/null 2>&1 \
        || fail "bundled third-party notice bytes drifted"
    cmp ThirdParty/TraceStreamer/license-inventory.json \
        "$candidate_app/Contents/Resources/license-inventory.json" >/dev/null 2>&1 \
        || fail "bundled license inventory bytes drifted"
    diff -qr ThirdParty/TraceStreamer/LICENSES \
        "$candidate_app/Contents/Resources/Licenses" >/dev/null \
        || fail "bundled license text directory drifted"
done
bundled_version=$("$bundled_parser" --version 2>&1 || true)
test "$bundled_version" = "version 4.3.7" \
    || fail "bundled parser version drifted"

verify_candidate_app() {
    candidate_app=$1
    candidate_name=$2
    executable="$candidate_app/Contents/MacOS/ArkTrace"
    entitlements_file="$derived_data/$candidate_name-entitlements.plist"

    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$candidate_app/Contents/Info.plist")" = "com.arktrace.ArkTrace" \
        || fail "$candidate_name bundle identifier drifted"
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$candidate_app/Contents/Info.plist")" = "0.1.0" \
        || fail "$candidate_name product version drifted"
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
        "$candidate_app/Contents/Info.plist")" = "1" \
        || fail "$candidate_name product build drifted"
    test "$(/usr/libexec/PlistBuddy -c \
        'Print :CFBundleDocumentTypes:0:CFBundleTypeRole' \
        "$candidate_app/Contents/Info.plist")" = "Viewer" \
        || fail "$candidate_name document role drifted"
    test "$(/usr/libexec/PlistBuddy -c \
        'Print :CFBundleDocumentTypes:0:CFBundleTypeExtensions:0' \
        "$candidate_app/Contents/Info.plist")" = "htrace" \
        || fail "$candidate_name htrace document registration drifted"
    test "$(/usr/libexec/PlistBuddy -c \
        'Print :CFBundleDocumentTypes:0:CFBundleTypeExtensions:1' \
        "$candidate_app/Contents/Info.plist")" = "systrace" \
        || fail "$candidate_name systrace document registration drifted"
    test "$(/usr/libexec/PlistBuddy -c \
        'Print :CFBundleDocumentTypes:0:CFBundleTypeExtensions:2' \
        "$candidate_app/Contents/Info.plist")" = "trace" \
        || fail "$candidate_name trace document registration drifted"
    test "$(lipo -archs "$executable")" = "arm64" \
        || fail "$candidate_name is not arm64-only"
    codesign -d --entitlements :- "$candidate_app" >"$entitlements_file" 2>/dev/null \
        || fail "$candidate_name entitlements are unreadable"
    plutil -lint "$entitlements_file" >/dev/null \
        || fail "$candidate_name entitlements are not a plist"
    entitlement_shape=$(plutil -p "$entitlements_file" | tr -d '[:space:]')
    test "$entitlement_shape" = "{}" \
        || fail "$candidate_name must have an empty entitlement dictionary"
}

verify_candidate_app "$app" debug
verify_candidate_app "$release_app" release

if nm -gj "$release_app/Contents/MacOS/ArkTrace" \
    | grep 'ArkTraceDeveloperParserResolver' >/dev/null
then
    fail "Debug-only developer parser resolver leaked into Release"
fi

release_module_directory=$(find "$derived_data/Build/Products/Release" \
    -type d -name 'ArkTraceAppSupport.swiftmodule' -print -quit)
test -n "$release_module_directory" \
    || fail "Release ArkTraceAppSupport Swift module is unavailable"
negative_source="$derived_data/release-debug-resolver-negative.swift"
negative_log="$derived_data/release-debug-resolver-negative.log"
printf '%s\n' \
    'import ArkTraceAppSupport' \
    'let _ = ArkTraceDeveloperParserResolver()' >"$negative_source"
if xcrun swiftc -typecheck \
    -target arm64-apple-macosx14.0 \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -I "$(dirname "$release_module_directory")" \
    "$negative_source" >"$negative_log" 2>&1
then
    fail "Debug-only developer parser resolver remains in the Release module API"
fi
grep 'cannot find.*ArkTraceDeveloperParserResolver' "$negative_log" >/dev/null \
    || fail "Release debug-resolver compile-negative evidence was inconclusive"

"$app/Contents/MacOS/ArkTrace" >"$app_log" 2>&1 &
app_pid=$!
sleep 2
if ! kill -0 "$app_pid" 2>/dev/null; then
    wait "$app_pid" || true
    fail "Debug app did not remain running"
fi
set +e
kill -TERM "$app_pid" 2>/dev/null
kill_status=$?
wait "$app_pid"
status=$?
set -e
if test "$kill_status" -ne 0; then
    fail "Debug app exited between liveness check and termination"
fi
if test "$status" -ne 0 && test "$status" -ne 143; then
    fail "Debug app terminated unexpectedly"
fi

echo "Phase 3 batch 1 gate passed: inherited Phase 2 + ad-hoc app candidate + pinned parser"
