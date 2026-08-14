#!/bin/sh
set -eu

fail() {
    printf 'Phase 3 package/notarization failed: %s\n' "$1" >&2
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
                value=$(readlink "$relative")
                printf 'L\0%s\0%s\0%s\0' "$mode" "$relative" "$value"
            else
                bytes=$(stat -f '%z' "$relative")
                sha=$(shasum -a 256 "$relative" | awk '{print $1}')
                printf 'F\0%s\0%s\0%s\0%s\0' "$mode" "$relative" "$bytes" "$sha"
            fi
        done
    ) | shasum -a 256 | awk '{print $1}'
}

signature_certificate_sha1() {
    candidate=$1
    label=$2
    prefix="$temporary_root/$label-certificate-"
    run_external "$label certificate extraction failed" \
        codesign -d "--extract-certificates=$prefix" "$candidate"
    leaf="${prefix}0"
    [ -f "$leaf" ] && [ ! -L "$leaf" ] \
        || fail "$label signing certificate is unavailable"
    shasum -a 1 "$leaf" | awk '{print toupper($1)}'
}

signature_detail() {
    candidate=$1
    label=$2
    detail="$temporary_root/$label-signature.txt"
    run_external "$label signature verification failed" \
        codesign --verify --strict --verbose=2 "$candidate"
    codesign -dv --verbose=4 "$candidate" >"$temporary_root/$label-detail.stdout" 2>"$detail" \
        || fail "$label signature details are unreadable"
    grep -Fx "TeamIdentifier=$team" "$detail" >/dev/null \
        || fail "$label TeamIdentifier drifted"
    grep -E '^CodeDirectory .* flags=.*\(runtime\)' "$detail" >/dev/null \
        || fail "$label hardened runtime is missing"
    grep -E '^Timestamp=' "$detail" >/dev/null \
        || fail "$label trusted timestamp is missing"
    grep -Fx "Authority=$identity" "$detail" >/dev/null \
        || fail "$label Developer ID authority drifted"
    [ "$(signature_certificate_sha1 "$candidate" "$label")" = "$certificate_sha1" ] \
        || fail "$label signing certificate drifted"
}

reviewed_head_file() {
    relative=$1
    candidate=$2
    git -C "$repository_root" cat-file -e "HEAD:$relative" 2>/dev/null \
        || fail "reviewed release evidence is absent from HEAD"
    head_sha=$(git -C "$repository_root" show "HEAD:$relative" 2>/dev/null \
        | shasum -a 256 | awk '{print $1}')
    [ "$head_sha" = "$(shasum -a 256 "$candidate" | awk '{print $1}')" ] \
        || fail "reviewed release evidence differs from HEAD"
}

reviewed_artifact() {
    check_name=$1
    relative=$2
    expected_sha=$3
    case "$relative" in
        Fixtures/release-evidence/*) ;;
        *) fail "accessibility artifact is outside the reviewed evidence root" ;;
    esac
    case "/$relative/" in */../*|*/./*) fail "accessibility artifact path is invalid" ;; esac
    candidate="$repository_root/$relative"
    arktrace_assert_physical_file_within \
        "$repository_root" "$candidate" "accessibility artifact"
    git -C "$repository_root" ls-files --error-unmatch "$relative" >/dev/null 2>&1 \
        || fail "accessibility artifact is not tracked"
    reviewed_head_file "$relative" "$candidate"
    [ "$(stat -f '%z' "$candidate")" -le 16777216 ] \
        || fail "accessibility artifact exceeds its byte bound"
    [ "$(shasum -a 256 "$candidate" | awk '{print $1}')" = "$expected_sha" ] \
        || fail "accessibility artifact SHA drifted"
    case "$relative" in
        *.png)
            /usr/bin/sips -g pixelWidth -g pixelHeight "$candidate" \
                >"$temporary_root/accessibility-image.txt" 2>&1 \
                || fail "accessibility screenshot is not a valid image"
            image_width=$(awk '/pixelWidth:/{print $2}' \
                "$temporary_root/accessibility-image.txt")
            image_height=$(awk '/pixelHeight:/{print $2}' \
                "$temporary_root/accessibility-image.txt")
            [ "${image_width:-0}" -ge 800 ] && [ "${image_height:-0}" -ge 600 ] \
                || fail "accessibility screenshot is too small to review"
            ;;
        *.txt)
            iconv -f UTF-8 -t UTF-8 "$candidate" \
                >"$temporary_root/accessibility-text.txt" 2>/dev/null \
                || fail "accessibility transcript is not valid UTF-8"
            [ "$(wc -l <"$candidate" | tr -d ' ')" -ge 6 ] \
                || fail "accessibility transcript is incomplete"
            grep -Fx 'ArkTrace accessibility walkthrough v1' "$candidate" >/dev/null \
                || fail "accessibility transcript format is invalid"
            grep -Fx "check: $check_name" "$candidate" >/dev/null \
                || fail "accessibility transcript check identity drifted"
            grep -Fx "candidateTreeSHA256: $app_tree" "$candidate" >/dev/null \
                || fail "accessibility transcript is not candidate-bound"
            grep -F 'steps:' "$candidate" >/dev/null \
                && grep -F 'observations:' "$candidate" >/dev/null \
                || fail "accessibility transcript lacks reviewed observations"
            ;;
        *) fail "accessibility artifact type is unsupported" ;;
    esac
}

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd -P)
. "$script_directory/phase3_shell_safety.sh"
identity=${ARKTRACE_DEVELOPER_ID_APPLICATION:-}
team=${ARKTRACE_DEVELOPMENT_TEAM:-}
notary_profile=${ARKTRACE_NOTARY_PROFILE:-}
reviewed_app=${ARKTRACE_REVIEWED_SIGNED_APP:-}
accessibility_evidence=${ARKTRACE_ACCESSIBILITY_EVIDENCE:-}
reviewer_public_key=${ARKTRACE_ACCESSIBILITY_REVIEWER_PUBLIC_KEY:-}
artifact_directory=${ARKTRACE_PHASE3_ARTIFACT_DIR:-$repository_root/.build/phase3-artifacts}
reviewer_configuration="$repository_root/Config/ArkTraceReleaseReviewers.json"

[ -n "$identity" ] && [ -n "$team" ] && [ -n "$notary_profile" ] \
    || fail "Developer ID identity, team, and notary keychain profile are required"
command -v openssl >/dev/null 2>&1 || fail "OpenSSL is unavailable"
[ -n "$reviewed_app" ] && [ -n "$accessibility_evidence" ] \
    || fail "the reviewed signed App and its accessibility evidence are required"
arktrace_validate_reviewed_roots "$repository_root"
arktrace_validate_owned_directory_request "$artifact_directory" "artifact output"
[ -d "$reviewed_app" ] && [ ! -L "$reviewed_app" ] \
    || fail "reviewed signed App is unavailable or is a symlink"
[ -f "$accessibility_evidence" ] && [ ! -L "$accessibility_evidence" ] \
    || fail "accessibility evidence is unavailable or is a symlink"
[ -f "$reviewer_public_key" ] && [ ! -L "$reviewer_public_key" ] \
    || fail "independent accessibility reviewer public key is required"
[ -f "$reviewer_configuration" ] && [ ! -L "$reviewer_configuration" ] \
    || fail "reviewer trust configuration is unavailable"
[ "$(stat -f '%z' "$reviewer_configuration")" -le 16384 ] \
    || fail "reviewer trust configuration exceeds its byte bound"
[ "$(stat -f '%z' "$reviewer_public_key")" -le 65536 ] \
    || fail "accessibility reviewer public key exceeds its byte bound"
arktrace_create_reviewed_build_root
temporary_root=$(mktemp -d "$ARKTRACE_REVIEWED_TEMP_ROOT/arktrace-package.XXXXXX")
partial_zip=
cleanup() {
    if [ -n "$partial_zip" ]; then rm -f -- "$partial_zip"; fi
    rm -rf -- "$temporary_root"
}
trap cleanup EXIT HUP INT TERM
umask 077
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
artifact_directory=$(arktrace_secure_owned_directory \
    "$artifact_directory" .arktrace-phase3-artifacts-v1 "artifact output")

[ "$(stat -f '%z' "$accessibility_evidence")" -le 16384 ] \
    || fail "accessibility evidence exceeds its byte bound"
evidence_parent=$(CDPATH= cd -- "$(dirname -- "$accessibility_evidence")" && pwd -P)
evidence_path="$evidence_parent/$(basename "$accessibility_evidence")"
case "$evidence_path" in
    "$repository_root"/*) ;;
    *) fail "accessibility evidence is not inside the reviewed repository" ;;
esac
evidence_relative=${evidence_path#"$repository_root"/}
git -C "$repository_root" ls-files --error-unmatch "$evidence_relative" >/dev/null 2>&1 \
    || fail "accessibility evidence is not tracked"
reviewed_head_file "$evidence_relative" "$accessibility_evidence"
reviewed_head_file "Config/ArkTraceReleaseReviewers.json" "$reviewer_configuration"

app="$temporary_root/ArkTrace.app"
run_external "reviewed App copy failed" /usr/bin/ditto --noqtn "$reviewed_app" "$app"
helper="$app/Contents/Helpers/trace_streamer"
manifest="$app/Contents/Resources/TraceStreamer/manifest.json"
distribution_record="$app/Contents/Resources/TraceStreamer/distribution-signing.json"
[ -f "$helper" ] && [ -f "$manifest" ] && [ -f "$distribution_record" ] \
    || fail "reviewed App is missing nested parser signing evidence"
for physical_file in \
    "$helper" "$manifest" "$distribution_record" \
    "$app/Contents/Info.plist" \
    "$app/Contents/Resources/LICENSE" \
    "$app/Contents/Resources/THIRD_PARTY_NOTICES.md" \
    "$app/Contents/Resources/license-inventory.json"
do
    arktrace_assert_physical_file_within "$app" "$physical_file" "reviewed App resource"
done
arktrace_assert_physical_directory_chain "$app" \
    "$app/Contents/Resources/Licenses" \
    || fail "reviewed App license directory is not physical"
[ -z "$(find "$app/Contents/Resources/Licenses" -type l -print -quit)" ] \
    || fail "reviewed App license directory contains a symlink"
signature_detail "$helper" helper
signature_detail "$app" app
run_external "reviewed App nested signatures are invalid" \
    codesign --verify --deep --strict --verbose=2 "$app"

app_tree=$(app_tree_sha "$app")
app_cdhash=$(codesign -dv --verbose=4 "$app" 2>&1 \
    | sed -n 's/^CDHash=//p' | head -1)
app_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$app/Contents/Info.plist" 2>"$temporary_root/plist-version.log")
app_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$app/Contents/Info.plist" 2>"$temporary_root/plist-build.log")
app_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$app/Contents/Info.plist" 2>"$temporary_root/plist-bundle.log")
configuration="$repository_root/Config/ArkTraceProduct.xcconfig"
canonical_version=$(awk -F= '/^ARKTRACE_PRODUCT_VERSION[[:space:]]*=/{gsub(/[[:space:]]/,"",$2);print $2}' "$configuration")
canonical_build=$(awk -F= '/^ARKTRACE_PRODUCT_BUILD[[:space:]]*=/{gsub(/[[:space:]]/,"",$2);print $2}' "$configuration")
canonical_bundle_id=$(awk -F= '/^ARKTRACE_BUNDLE_IDENTIFIER[[:space:]]*=/{gsub(/[[:space:]]/,"",$2);print $2}' "$configuration")
[ "$app_version" = "$canonical_version" ] \
    && [ "$app_build" = "$canonical_build" ] \
    && [ "$app_bundle_id" = "$canonical_bundle_id" ] \
    || fail "reviewed App product identity differs from the canonical configuration"
jq -e \
    --arg tree "$app_tree" --arg cdhash "$app_cdhash" \
    --arg version "$app_version" --arg build "$app_build" \
    --arg bundle "$app_bundle_id" --arg team "$team" '
    .formatVersion == 1
    and ((keys | sort) == ["app","checks","formatVersion","reviewSignaturePath","reviewedAt","reviewer","reviewerKeySHA256"])
    and .app.treeSHA256 == $tree
    and .app.codeDirectoryHash == $cdhash
    and .app.version == $version
    and .app.build == $build
    and .app.bundleIdentifier == $bundle
    and .app.teamIdentifier == $team
    and ((.checks | keys | sort) == ["focusRestoration","keyboardNavigation","minimumTargets","minimumWindow","reduceMotion","voiceOver"])
    and ([.checks[] | ((keys | sort) == ["artifactPath","artifactSHA256","status"])] | all)
    and ([.checks[] | .status == "pass"] | all)
    and ([.checks[] | (.artifactPath | test("^Fixtures/release-evidence/[A-Za-z0-9_./+-]+$") and contains("..") | not)] | all)
    and ([.checks[] | (.artifactSHA256 | test("^[0-9a-f]{64}$"))] | all)
    and ([.checks[].artifactPath] | unique | length == 6)
    and ([.checks[].artifactSHA256] | unique | length == 6)
    and (.checks.keyboardNavigation.artifactPath | endswith(".txt"))
    and (.checks.voiceOver.artifactPath | endswith(".txt"))
    and (.checks.minimumWindow.artifactPath | endswith(".png"))
    and (.checks.reduceMotion.artifactPath | endswith(".txt"))
    and (.checks.minimumTargets.artifactPath | endswith(".png"))
    and (.checks.focusRestoration.artifactPath | endswith(".txt"))
    and (.reviewer | type == "string" and length > 0 and length <= 128)
    and (.reviewSignaturePath | test("^Fixtures/release-evidence/[A-Za-z0-9_.+-]+\\.sig$") and contains("..") | not)
    and (.reviewerKeySHA256 | test("^[0-9a-f]{64}$"))
    and (.reviewedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
    and ((.app | keys | sort) == ["build","bundleIdentifier","codeDirectoryHash","teamIdentifier","treeSHA256","version"])
' "$accessibility_evidence" >/dev/null \
    || fail "accessibility evidence does not bind this exact signed App"
accessibility_reviewed_at=$(jq -er '.reviewedAt' "$accessibility_evidence")
PYTHONDONTWRITEBYTECODE=1 python3 -B \
    "$script_directory/verify_phase3_evidence_times.py" \
    --timestamp "$accessibility_reviewed_at" >/dev/null 2>&1 \
    || fail "accessibility review timestamp is not canonical UTC"
expected_reviewer_key_sha=$(jq -er '.reviewerKeySHA256' "$accessibility_evidence")
jq -e '
    .formatVersion == 1
    and ((keys | sort) == ["accessibilityReviewerPublicKeySHA256","formatVersion","largeTraceReviewerPublicKeySHA256","redistributionGrantIssuerPublicKeySHA256"])
    and (.accessibilityReviewerPublicKeySHA256 | test("^[0-9a-f]{64}$"))
    | select(.)
' "$reviewer_configuration" >/dev/null 2>&1 \
    || fail "an independent accessibility reviewer trust root has not been provisioned"
trusted_reviewer_key_sha=$(jq -er '.accessibilityReviewerPublicKeySHA256' \
    "$reviewer_configuration")
[ "$expected_reviewer_key_sha" = "$trusted_reviewer_key_sha" ] \
    || fail "accessibility reviewer is not in the reviewed trust configuration"
[ "$(shasum -a 256 "$reviewer_public_key" | awk '{print $1}')" = \
    "$expected_reviewer_key_sha" ] \
    || fail "accessibility reviewer key identity drifted"
review_signature_relative=$(jq -er '.reviewSignaturePath' "$accessibility_evidence")
review_signature="$repository_root/$review_signature_relative"
[ -f "$review_signature" ] && [ ! -L "$review_signature" ] \
    || fail "accessibility reviewer signature is unavailable"
[ "$(stat -f '%z' "$review_signature")" -le 65536 ] \
    || fail "accessibility reviewer signature exceeds its byte bound"
git -C "$repository_root" ls-files --error-unmatch "$review_signature_relative" \
    >/dev/null 2>&1 || fail "accessibility reviewer signature is not tracked"
reviewed_head_file "$review_signature_relative" "$review_signature"
run_external "accessibility reviewer signature is invalid" \
    openssl dgst -sha256 -verify "$reviewer_public_key" \
        -signature "$review_signature" "$accessibility_evidence"
while IFS="$(printf '\t')" read -r check_name artifact_path artifact_sha; do
    reviewed_artifact "$check_name" "$artifact_path" "$artifact_sha"
done <<EOF
$(jq -r '.checks | to_entries[] | [.key,.value.artifactPath,.value.artifactSHA256] | @tsv' "$accessibility_evidence")
EOF

entitlements="$temporary_root/entitlements.plist"
codesign -d --entitlements :- "$app" >"$entitlements" 2>/dev/null \
    || fail "signed App entitlements are unreadable"
[ "$(plutil -p "$entitlements" | tr -d '[:space:]')" = '{}' ] \
    || fail "distribution candidate must have empty entitlements"

cmp "$repository_root/LICENSE" "$app/Contents/Resources/LICENSE" \
    >/dev/null 2>&1 \
    || fail "bundled ArkTrace MIT license drifted"
cmp "$repository_root/THIRD_PARTY_NOTICES.md" \
    "$app/Contents/Resources/THIRD_PARTY_NOTICES.md" \
    >/dev/null 2>&1 \
    || fail "bundled third-party notice drifted"
cmp "$repository_root/ThirdParty/TraceStreamer/license-inventory.json" \
    "$app/Contents/Resources/license-inventory.json" \
    >/dev/null 2>&1 \
    || fail "bundled license inventory drifted"
diff -qr "$repository_root/ThirdParty/TraceStreamer/LICENSES" \
    "$app/Contents/Resources/Licenses" >/dev/null 2>&1 \
    || fail "bundled license directory drifted"
[ "$(shasum -a 256 "$helper" | awk '{print $1}')" = \
    "$(jq -er '.binarySHA256' "$manifest")" ] \
    || fail "signed helper bytes do not match the bundled manifest"
repository_manifest="$repository_root/ThirdParty/TraceStreamer/macx/manifest.json"
jq -e \
    --arg unsigned "$(jq -er '.binarySHA256' "$repository_manifest")" \
    --arg signed "$(shasum -a 256 "$helper" | awk '{print $1}')" \
    --arg recipe "$(jq -er '.buildRecipeVersion' "$repository_manifest")" \
    --arg team "$team" --arg identity "$identity" --arg certificate "$certificate_sha1" '
    .formatVersion == 1
    and ((keys | sort) == ["buildRecipeVersion","formatVersion","signedBinarySHA256","signingCertificateSHA1","signingIdentity","signingPolicy","teamIdentifier","unsignedBinarySHA256"])
    and .unsignedBinarySHA256 == $unsigned
    and .signedBinarySHA256 == $signed
    and .buildRecipeVersion == $recipe
    and .teamIdentifier == $team and .signingIdentity == $identity
    and .signingCertificateSHA1 == $certificate
    and .signingPolicy == "developer-id-runtime-timestamp"
' "$distribution_record" >/dev/null \
    || fail "nested parser signing provenance does not close over repository bytes"

submission_zip="$temporary_root/ArkTrace-notary-submission.zip"
run_external "notary submission archive failed" \
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$submission_zip"
notary_response="$temporary_root/notary-response.json"
notary_log="$temporary_root/notary-response.log"
if ! xcrun notarytool submit "$submission_zip" \
    --keychain-profile "$notary_profile" --wait --output-format json \
    >"$notary_response" 2>"$notary_log"
then
    arktrace_bounded_failure_summary "$notary_log"
    fail "Apple notarization submission failed"
fi
jq -e '.status == "Accepted" and (.id | test("^[0-9A-Fa-f-]{36}$"))' \
    "$notary_response" >/dev/null 2>&1 \
    || fail "Apple notarization was not accepted"
notary_submission_id=$(jq -er '.id' "$notary_response")
run_external "notarization ticket could not be stapled" xcrun stapler staple "$app"
run_external "stapled ticket validation failed" xcrun stapler validate "$app"
run_external "Gatekeeper assessment failed" spctl --assess --type execute --verbose=2 "$app"

artifact_name="ArkTrace-$(date -u +%Y%m%dT%H%M%SZ).zip"
final_zip="$artifact_directory/$artifact_name"
partial_zip_path="$artifact_directory/.partial-$artifact_name"
arktrace_require_absent_leaf "$final_zip" "final artifact"
arktrace_require_absent_leaf "$partial_zip_path" "final artifact partial"
partial_zip=$partial_zip_path
run_external "final archive creation failed" \
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$partial_zip"
extracted="$temporary_root/final"
mkdir "$extracted"
run_external "final archive extraction failed" /usr/bin/ditto -x -k "$partial_zip" "$extracted"
final_app="$extracted/ArkTrace.app"
final_helper="$final_app/Contents/Helpers/trace_streamer"
final_manifest="$final_app/Contents/Resources/TraceStreamer/manifest.json"
final_distribution_record="$final_app/Contents/Resources/TraceStreamer/distribution-signing.json"
[ -d "$final_app" ] && [ -f "$final_helper" ] && [ -f "$final_manifest" ] \
    && [ -f "$final_distribution_record" ] \
    || fail "final archive shape is invalid"
for physical_file in \
    "$final_helper" "$final_manifest" "$final_distribution_record" \
    "$final_app/Contents/Info.plist" \
    "$final_app/Contents/Resources/LICENSE" \
    "$final_app/Contents/Resources/THIRD_PARTY_NOTICES.md" \
    "$final_app/Contents/Resources/license-inventory.json"
do
    arktrace_assert_physical_file_within \
        "$final_app" "$physical_file" "final archive resource"
done
arktrace_assert_physical_directory_chain "$final_app" \
    "$final_app/Contents/Resources/Licenses" \
    || fail "final archive license directory is not physical"
[ -z "$(find "$final_app/Contents/Resources/Licenses" -type l -print -quit)" ] \
    || fail "final archive license directory contains a symlink"
signature_detail "$final_helper" final-helper
signature_detail "$final_app" final-app
run_external "final archive nested signatures are invalid" \
    codesign --verify --deep --strict --verbose=2 "$final_app"
run_external "final archive does not contain the stapled ticket" \
    xcrun stapler validate "$final_app"
run_external "final archive Gatekeeper assessment failed" \
    spctl --assess --type execute --verbose=2 "$final_app"
[ "$(shasum -a 256 "$final_helper" | awk '{print $1}')" = \
    "$(jq -er '.binarySHA256' "$final_manifest")" ] \
    || fail "final archive helper identity is not closed"
cmp "$distribution_record" "$final_distribution_record" \
    >/dev/null 2>&1 \
    || fail "final archive parser signing provenance drifted"
final_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$final_app/Contents/Info.plist" 2>/dev/null)
final_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$final_app/Contents/Info.plist" 2>/dev/null)
final_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$final_app/Contents/Info.plist" 2>/dev/null)
[ "$final_version" = "$canonical_version" ] \
    && [ "$final_build" = "$canonical_build" ] \
    && [ "$final_bundle_id" = "$canonical_bundle_id" ] \
    || fail "final archive product identity drifted"

mv -n "$partial_zip" "$final_zip" || fail "final artifact publication failed"
[ ! -e "$partial_zip" ] && [ -f "$final_zip" ] \
    || fail "final artifact publication did not complete"
partial_zip=

printf 'Phase 3 package/notarization passed: artifact=%s sha256=%s notarizationStatus=Accepted submissionID=%s\n' \
    "$artifact_name" "$(shasum -a 256 "$final_zip" | awk '{print $1}')" \
    "$notary_submission_id"
