#!/bin/sh
set -eu

fail() {
    printf 'Phase 3 distribution candidate build failed: %s\n' "$1" >&2
    exit 1
}

run_external() {
    label=$1
    shift
    log="$temporary_root/external-$external_log_index.log"
    external_log_index=$((external_log_index + 1))
    if ! "$@" >"$log" 2>&1; then
        arktrace_bounded_failure_summary "$log"
        fail "$label"
    fi
}

app_tree_sha() {
    candidate=$1
    (
        cd "$candidate"
        find . \( -type f -o -type l \) -print | LC_ALL=C sort |
        while IFS= read -r relative; do
            mode=$(stat -f '%Lp' "$relative")
            if [ -L "$relative" ]; then
                printf 'L\0%s\0%s\0%s\0' "$mode" "$relative" "$(readlink "$relative")"
            else
                printf 'F\0%s\0%s\0%s\0%s\0' "$mode" "$relative" \
                    "$(stat -f '%z' "$relative")" \
                    "$(shasum -a 256 "$relative" | awk '{print $1}')"
            fi
        done
    ) | shasum -a 256 | awk '{print $1}'
}

signature_certificate_sha1() {
    candidate=$1
    label=$2
    prefix="$temporary_root/$label-certificate-"
    run_external "$label certificate extraction failed" \
        codesign -d --extract-certificates "$prefix" "$candidate"
    leaf="${prefix}0"
    [ -f "$leaf" ] && [ ! -L "$leaf" ] \
        || fail "$label signing certificate is unavailable"
    shasum -a 1 "$leaf" | awk '{print toupper($1)}'
}

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd -P)
. "$script_directory/phase3_shell_safety.sh"
identity=${ARKTRACE_DEVELOPER_ID_APPLICATION:-}
team=${ARKTRACE_DEVELOPMENT_TEAM:-}
candidate_directory=${ARKTRACE_PHASE3_CANDIDATE_DIR:-$repository_root/.build/phase3-candidates}
[ -n "$identity" ] && [ -n "$team" ] \
    || fail "Developer ID identity and team are required"
arktrace_validate_reviewed_roots "$repository_root"
arktrace_validate_owned_directory_request "$candidate_directory" "candidate output"
arktrace_create_reviewed_build_root

temporary_root=$(mktemp -d "$ARKTRACE_REVIEWED_TEMP_ROOT/arktrace-candidate.XXXXXX")
partial_candidate=
cleanup() {
    if [ -n "$partial_candidate" ]; then rm -rf -- "$partial_candidate"; fi
    rm -rf -- "$temporary_root"
}
trap cleanup EXIT HUP INT TERM
external_log_index=0
identity_log="$temporary_root/security-identities.log"
security find-identity -v -p codesigning >"$identity_log" 2>&1 \
    || fail "Developer ID identities are unavailable"
certificate_sha1=$(awk -v suffix="\"$identity\"" '
    substr($0, length($0) - length(suffix) + 1) == suffix { print $2 }
' "$identity_log")
[ "$(printf '%s\n' "$certificate_sha1" | grep -Ec '^[0-9A-Fa-f]{40}$')" -eq 1 ] \
    || fail "configured Developer ID Application identity is not uniquely available"
certificate_sha1=$(printf '%s' "$certificate_sha1" | tr '[:lower:]' '[:upper:]')
candidate_directory=$(arktrace_secure_owned_directory \
    "$candidate_directory" .arktrace-phase3-candidates-v1 "candidate output")
archive="$temporary_root/ArkTrace.xcarchive"
build_log="$temporary_root/archive.log"
if ! xcodebuild -quiet \
    -project "$repository_root/ArkTrace.xcodeproj" \
    -scheme ArkTraceApp \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$temporary_root/DerivedData" \
    -archivePath "$archive" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$certificate_sha1" \
    DEVELOPMENT_TEAM="$team" \
    archive >"$build_log" 2>&1
then
    arktrace_bounded_failure_summary "$build_log"
    fail "Release archive failed"
fi

app="$archive/Products/Applications/ArkTrace.app"
helper="$app/Contents/Helpers/trace_streamer"
manifest="$app/Contents/Resources/TraceStreamer/manifest.json"
[ -d "$app" ] && [ -f "$helper" ] && [ -f "$manifest" ] \
    || fail "archive is missing the App, helper, or manifest"
for physical_file in \
    "$helper" "$manifest" "$app/Contents/Info.plist" \
    "$app/Contents/Resources/LICENSE" \
    "$app/Contents/Resources/THIRD_PARTY_NOTICES.md" \
    "$app/Contents/Resources/license-inventory.json"
do
    arktrace_assert_physical_file_within "$app" "$physical_file" "archive resource"
done
arktrace_assert_physical_directory_chain "$app" \
    "$app/Contents/Resources/Licenses" \
    || fail "archive license directory is not physical"
[ -z "$(find "$app/Contents/Resources/Licenses" -type l -print -quit)" ] \
    || fail "archive license directory contains a symlink"
cmp "$repository_root/ThirdParty/TraceStreamer/macx/trace_streamer" "$helper" \
    >/dev/null 2>&1 \
    || fail "archive helper differs from the locked reproducible binary"
cmp "$repository_root/ThirdParty/TraceStreamer/macx/manifest.json" "$manifest" \
    >/dev/null 2>&1 \
    || fail "archive helper manifest drifted before signing"

run_external "nested helper signing failed" \
    codesign --force --sign "$certificate_sha1" --options runtime --timestamp "$helper"
helper_certificate_sha1=$(signature_certificate_sha1 "$helper" helper)
[ "$helper_certificate_sha1" = "$certificate_sha1" ] \
    || fail "nested helper was signed by an unexpected certificate"
signed_helper_sha=$(shasum -a 256 "$helper" | awk '{print $1}')
unsigned_helper_sha=$(jq -er '.binarySHA256' \
    "$repository_root/ThirdParty/TraceStreamer/macx/manifest.json")
jq --arg sha "$signed_helper_sha" '.binarySHA256 = $sha' "$manifest" \
    >"$temporary_root/manifest.json" || fail "signed manifest update failed"
mv "$temporary_root/manifest.json" "$manifest"
chmod 644 "$manifest"
distribution_record="$app/Contents/Resources/TraceStreamer/distribution-signing.json"
arktrace_require_absent_leaf "$distribution_record" "distribution signing record"
jq -n \
    --arg unsigned "$unsigned_helper_sha" \
    --arg signed "$signed_helper_sha" \
    --arg recipe "$(jq -er '.buildRecipeVersion' "$manifest")" \
    --arg team "$team" --arg identity "$identity" --arg certificate "$certificate_sha1" '
    {
      formatVersion: 1,
      unsignedBinarySHA256: $unsigned,
      signedBinarySHA256: $signed,
      buildRecipeVersion: $recipe,
      teamIdentifier: $team,
      signingIdentity: $identity,
      signingCertificateSHA1: $certificate,
      signingPolicy: "developer-id-runtime-timestamp"
    }
' >"$distribution_record" || fail "distribution signing record could not be created"
chmod 644 "$distribution_record"
run_external "outer App signing failed" codesign --force --sign "$certificate_sha1" --options runtime --timestamp \
    --entitlements "$repository_root/Apps/ArkTraceApp/ArkTraceApp.entitlements" \
    "$app"
app_certificate_sha1=$(signature_certificate_sha1 "$app" app)
[ "$app_certificate_sha1" = "$certificate_sha1" ] \
    || fail "outer App was signed by an unexpected certificate"
run_external "candidate nested signatures are invalid" \
    codesign --verify --deep --strict --verbose=2 "$app"
entitlements="$temporary_root/candidate-entitlements.plist"
codesign -d --entitlements :- "$app" >"$entitlements" 2>/dev/null \
    || fail "candidate entitlements are unreadable"
[ "$(plutil -p "$entitlements" | tr -d '[:space:]')" = '{}' ] \
    || fail "distribution candidate must have empty entitlements"

for candidate in "$helper" "$app"; do
    detail="$temporary_root/signature-$(basename "$candidate").txt"
    codesign -dv --verbose=4 "$candidate" 2>"$detail" \
        || fail "candidate signature details are unavailable"
    grep -Fx "TeamIdentifier=$team" "$detail" >/dev/null \
        || fail "candidate TeamIdentifier drifted"
    grep -E '^flags=.*runtime' "$detail" >/dev/null \
        || fail "candidate hardened runtime is missing"
    grep -E '^Timestamp=' "$detail" >/dev/null \
        || fail "candidate trusted timestamp is missing"
    grep -Fx "Authority=$identity" "$detail" >/dev/null \
        || fail "candidate Developer ID authority drifted"
done
[ "$signed_helper_sha" = "$(jq -er '.binarySHA256' "$manifest")" ] \
    || fail "signed helper manifest identity is open"
jq -e \
    --arg unsigned "$unsigned_helper_sha" --arg signed "$signed_helper_sha" \
    --arg recipe "$(jq -er '.buildRecipeVersion' "$manifest")" \
    --arg team "$team" --arg identity "$identity" --arg certificate "$certificate_sha1" '
    .formatVersion == 1
    and ((keys | sort) == ["buildRecipeVersion","formatVersion","signedBinarySHA256","signingCertificateSHA1","signingIdentity","signingPolicy","teamIdentifier","unsignedBinarySHA256"])
    and .unsignedBinarySHA256 == $unsigned
    and .signedBinarySHA256 == $signed
    and .buildRecipeVersion == $recipe
    and .teamIdentifier == $team
    and .signingIdentity == $identity
    and .signingCertificateSHA1 == $certificate
    and .signingPolicy == "developer-id-runtime-timestamp"
' "$distribution_record" >/dev/null \
    || fail "distribution signing provenance is incomplete"
cmp "$repository_root/LICENSE" "$app/Contents/Resources/LICENSE" \
    >/dev/null 2>&1 \
    || fail "candidate ArkTrace MIT license drifted"
cmp "$repository_root/THIRD_PARTY_NOTICES.md" \
    "$app/Contents/Resources/THIRD_PARTY_NOTICES.md" \
    >/dev/null 2>&1 \
    || fail "candidate third-party notice drifted"
cmp "$repository_root/ThirdParty/TraceStreamer/license-inventory.json" \
    "$app/Contents/Resources/license-inventory.json" \
    >/dev/null 2>&1 \
    || fail "candidate license inventory drifted"
diff -qr "$repository_root/ThirdParty/TraceStreamer/LICENSES" \
    "$app/Contents/Resources/Licenses" >/dev/null 2>&1 \
    || fail "candidate license files drifted"

umask 077
candidate_name="ArkTrace-review-candidate-$(date -u +%Y%m%dT%H%M%SZ).app"
candidate="$candidate_directory/$candidate_name"
arktrace_require_absent_leaf "$candidate" "candidate output"
candidate_partial_path="$candidate_directory/.partial-$candidate_name"
arktrace_require_absent_leaf "$candidate_partial_path" "candidate partial"
partial_candidate=$candidate_partial_path
run_external "candidate copy failed" /usr/bin/ditto --noqtn "$app" "$partial_candidate"
[ "$(app_tree_sha "$partial_candidate")" = "$(app_tree_sha "$app")" ] \
    || fail "candidate copy drifted before publication"
run_external "candidate copy signature verification failed" \
    codesign --verify --deep --strict --verbose=2 "$partial_candidate"
[ "$(signature_certificate_sha1 \
    "$partial_candidate/Contents/Helpers/trace_streamer" partial-helper)" = \
    "$certificate_sha1" ] || fail "candidate helper certificate drifted"
[ "$(signature_certificate_sha1 "$partial_candidate" partial-app)" = \
    "$certificate_sha1" ] || fail "candidate App certificate drifted"
mv -n "$partial_candidate" "$candidate" || fail "candidate publication failed"
[ ! -e "$partial_candidate" ] && [ -d "$candidate" ] \
    || fail "candidate publication did not complete"
partial_candidate=
tree_sha=$(app_tree_sha "$candidate")
cdhash=$(codesign -dv --verbose=4 "$candidate" 2>&1 \
    | sed -n 's/^CDHash=//p' | head -1)
printf 'Phase 3 signed review candidate ready: candidate=%s treeSHA256=%s codeDirectoryHash=%s\n' \
    "$candidate_name" "$tree_sha" "$cdhash"
