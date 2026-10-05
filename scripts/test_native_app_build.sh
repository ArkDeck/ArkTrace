#!/bin/sh
# Compile the mandatory current App graph and verify fixed resources. This
# independent gate makes no inherited performance or runnable-startup claim.
set -eu

fail() {
    printf 'Native App build gate failed: %s\n' "$1" >&2
    exit 1
}

bounded_build_failure() {
    printf 'Xcode diagnostics withheld\n' >&2
}

repo_root=$(CDPATH= cd -P -- "$(dirname -- "$0")/.." && pwd -P)
cd "$repo_root"
. "$repo_root/scripts/phase3_shell_safety.sh"
. "$repo_root/scripts/native_app_distribution_safety.sh"

derived_data=$(mktemp -d /tmp/arktrace-phase3-app.XXXXXX)
derived_data=$(CDPATH= cd -P -- "$derived_data" && pwd -P)
app_log=$(mktemp /tmp/arktrace-phase3-app-log.XXXXXX)
cleanup() {
    rm -rf "$derived_data"
    rm -f "$app_log"
}
trap cleanup EXIT HUP INT TERM

# This gate compiles the mandatory production SDK graph. Unsigned tool
# preparation deliberately cannot establish a runnable native App.
native_preparation="$derived_data/native-app-preparation.json"
native_workspace="$derived_data/workspace"
arktrace_copy_visible_source "$repo_root" "$native_workspace" "$derived_data/native-source-files"
set -- python3 scripts/prepare_macos_native_app.py --workspace "$native_workspace"
if [ -n "${ARKTRACE_RUST_XCFRAMEWORK:-}" ]; then
    set -- "$@" --sdk "$ARKTRACE_RUST_XCFRAMEWORK"
fi
if ! "$@" >"$native_preparation" 2>"$app_log"; then
    bounded_build_failure
    fail "native compile-only App preparation failed"
fi
ARKTRACE_RUST_XCFRAMEWORK=$(jq -er '.relativeSDK' "$native_preparation")
export ARKTRACE_RUST_XCFRAMEWORK
unset ARKTRACE_RUST_SDK_FIXTURES

if ! xcodebuild -quiet \
    -project "$native_workspace/ArkTrace.xcodeproj" \
    -scheme ArkTraceApp \
    -configuration Debug \
    -derivedDataPath "$derived_data" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_REQUIRED=YES \
    build >"$app_log" 2>&1
then
    bounded_build_failure
    fail "Debug app build failed"
fi

if ! xcodebuild -quiet \
    -project "$native_workspace/ArkTrace.xcodeproj" \
    -scheme ArkTraceApp \
    -configuration Release \
    -derivedDataPath "$derived_data" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
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
for candidate_app in "$app" "$release_app"; do
    for resource in \
        'Helpers/trace_streamer:Contents/Helpers/trace_streamer' \
        'Helpers/arktrace-host-process:Contents/Helpers/arktrace-host-process' \
        'TraceStreamer/manifest.json:Contents/Resources/TraceStreamer/manifest.json' \
        'ArkTraceRuntime/manifest.json:Contents/Resources/ArkTraceRuntime/manifest.json'
    do
        cmp "$native_workspace/.arktrace-native/AppInputs/${resource%%:*}" \
            "$candidate_app/${resource#*:}" >/dev/null 2>&1 \
            || fail "bundled native resource bytes drifted"
    done
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
    # Shared with CI so the expected list is never copied per caller.
    scripts/verify_app_document_types.sh "$candidate_app" >/dev/null \
        || fail "$candidate_name document registration drifted from the tracked Info.plist"
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
    -target arm64-apple-macosx26.0 \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -I "$(dirname "$release_module_directory")" \
    -I "$native_workspace/$ARKTRACE_RUST_XCFRAMEWORK/macos-arm64/Headers" \
    "$negative_source" >"$negative_log" 2>&1
then
    fail "Debug-only developer parser resolver remains in the Release module API"
fi
grep 'cannot find.*ArkTraceDeveloperParserResolver' "$negative_log" >/dev/null \
    || fail "Release debug-resolver compile-negative evidence was inconclusive"

# This compile-only manifest cannot admit a native Engine or open a document.
# Bound and reap the direct App process; this is not a GUI/Quit barrier proof.
python3 - "$app" "$app_log" <<'PY_APP'
import json, pathlib, signal, subprocess, sys, time
app = pathlib.Path(sys.argv[1]); log = pathlib.Path(sys.argv[2])
manifest = json.loads((app/'Contents/Resources/ArkTraceRuntime/manifest.json').read_text())
if manifest['publisher'] is not None:
    raise SystemExit('Native App build gate failed: liveness requires compile-only inputs')
def interrupted(_signal, _frame):
    raise RuntimeError('compile-only liveness interrupted')
for item in (signal.SIGTERM, signal.SIGINT): signal.signal(item, interrupted)
process = None
try:
    with log.open('wb') as output:
        process = subprocess.Popen([str(app/'Contents/MacOS/ArkTrace')], stdout=output, stderr=output)
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if process.poll() is not None: raise RuntimeError('compile-only App exited before liveness check')
            if log.stat().st_size > 65_536: raise RuntimeError('compile-only App log exceeded its bound')
            time.sleep(0.02)
        process.terminate()
        status = process.wait(timeout=5)
        if status not in (0, -signal.SIGTERM): raise RuntimeError('compile-only App exit was unexpected')
    print(json.dumps(dict(compileOnlyAppLiveness=True, directChildWaited=True, exitCode=status, guiAcceptance=False, productShutdownAcceptance=False)))
except Exception:
    raise SystemExit('Native App build gate failed: bounded compile-only App liveness failed')
finally:
    if process is not None and process.poll() is None:
        process.kill()
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: raise SystemExit('Native App build gate failed: direct App process could not be reaped')
PY_APP

echo "Native App compile gate passed: Debug/Release, mandatory SDK, pinned resources and Release API boundary; runtime/GUI acceptance not claimed"
