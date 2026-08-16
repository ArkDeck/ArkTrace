#!/bin/sh
set -eu

fail() {
    printf 'Phase 3 retained notarization verification failed: %s\n' "$1" >&2
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

sha256() {
    shasum -a 256 "$1" | awk '{print $1}'
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
                sha=$(sha256 "$relative")
                printf 'F\0%s\0%s\0%s\0%s\0' \
                    "$mode" "$relative" "$bytes" "$sha"
            fi
        done
    ) | shasum -a 256 | awk '{print $1}'
}

reviewed_head_file() {
    relative=$1
    candidate=$2
    git -C "$repository_root" cat-file -e "HEAD:$relative" 2>/dev/null \
        || fail "reviewed release evidence is absent from HEAD"
    head_sha=$(git -C "$repository_root" show "HEAD:$relative" 2>/dev/null \
        | shasum -a 256 | awk '{print $1}')
    [ "$head_sha" = "$(sha256 "$candidate")" ] \
        || fail "reviewed release evidence differs from HEAD"
}

reviewed_evidence_file() {
    candidate=$1
    label=$2
    byte_bound=$3
    [ -f "$candidate" ] && [ ! -L "$candidate" ] \
        || fail "$label is unavailable or is a symlink"
    parent=$(CDPATH= cd -- "$(dirname -- "$candidate")" && pwd -P) \
        || fail "$label parent is inaccessible"
    physical="$parent/$(basename -- "$candidate")"
    case "$physical" in "$repository_root"/*) ;; *) fail "$label is outside the repository" ;; esac
    relative=${physical#"$repository_root"/}
    case "$relative" in Fixtures/release-evidence/*) ;; *) fail "$label is outside the evidence root" ;; esac
    case "/$relative/" in */../*|*/./*) fail "$label path is invalid" ;; esac
    arktrace_assert_physical_file_within "$repository_root" "$physical" "$label"
    git -C "$repository_root" ls-files --error-unmatch "$relative" >/dev/null 2>&1 \
        || fail "$label is not tracked"
    reviewed_head_file "$relative" "$physical"
    [ "$(stat -f '%z' "$physical")" -le "$byte_bound" ] \
        || fail "$label exceeds its byte bound"
    printf '%s\t%s\n' "$physical" "$relative"
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

signature_cdhash() {
    candidate=$1
    label=$2
    detail="$temporary_root/$label-cdhash.txt"
    codesign -dv --verbose=4 "$candidate" >"$temporary_root/$label-cdhash.stdout" 2>"$detail" \
        || fail "$label CodeDirectory is unreadable"
    value=$(sed -n 's/^CDHash=//p' "$detail" | head -1)
    [ "$(printf '%s\n' "$value" | grep -Ec '^[0-9a-f]{40}$')" -eq 1 ] \
        || fail "$label CodeDirectory hash is invalid"
    printf '%s\n' "$value"
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

verify_accessibility_artifact() {
    check_name=$1
    relative=$2
    expected_sha=$3
    case "$relative" in Fixtures/release-evidence/*) ;; *) fail "accessibility artifact escaped its evidence root" ;; esac
    case "/$relative/" in */../*|*/./*) fail "accessibility artifact path is invalid" ;; esac
    candidate="$repository_root/$relative"
    arktrace_assert_physical_file_within \
        "$repository_root" "$candidate" "accessibility artifact"
    git -C "$repository_root" ls-files --error-unmatch "$relative" >/dev/null 2>&1 \
        || fail "accessibility artifact is not tracked"
    reviewed_head_file "$relative" "$candidate"
    [ "$(stat -f '%z' "$candidate")" -le 16777216 ] \
        || fail "accessibility artifact exceeds its byte bound"
    [ "$(sha256 "$candidate")" = "$expected_sha" ] \
        || fail "accessibility artifact SHA drifted"
    case "$relative" in
        *.png)
            /usr/bin/sips -g pixelWidth -g pixelHeight "$candidate" \
                >"$temporary_root/accessibility-image.txt" 2>&1 \
                || fail "accessibility screenshot is not a valid image"
            width=$(awk '/pixelWidth:/{print $2}' "$temporary_root/accessibility-image.txt")
            height=$(awk '/pixelHeight:/{print $2}' "$temporary_root/accessibility-image.txt")
            [ "${width:-0}" -ge 800 ] && [ "${height:-0}" -ge 600 ] \
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
            grep -Fx "candidateTreeSHA256: $candidate_tree" "$candidate" >/dev/null \
                || fail "accessibility transcript is not candidate-bound"
            grep -F 'steps:' "$candidate" >/dev/null \
                && grep -F 'observations:' "$candidate" >/dev/null \
                || fail "accessibility transcript lacks reviewed observations"
            ;;
        *) fail "accessibility artifact type is unsupported" ;;
    esac
}

validate_app_resources() {
    resource_app=$1
    label=$2
    helper_path="$resource_app/Contents/Helpers/trace_streamer"
    manifest_path="$resource_app/Contents/Resources/TraceStreamer/manifest.json"
    signing_path="$resource_app/Contents/Resources/TraceStreamer/distribution-signing.json"
    for physical_file in \
        "$helper_path" "$manifest_path" "$signing_path" \
        "$resource_app/Contents/Info.plist" \
        "$resource_app/Contents/Resources/LICENSE" \
        "$resource_app/Contents/Resources/THIRD_PARTY_NOTICES.md" \
        "$resource_app/Contents/Resources/license-inventory.json"
    do
        arktrace_assert_physical_file_within "$resource_app" "$physical_file" "$label resource"
    done
    arktrace_assert_physical_directory_chain "$resource_app" \
        "$resource_app/Contents/Resources/Licenses" \
        || fail "$label license directory is not physical"
    [ -z "$(find "$resource_app" -type l -print -quit)" ] \
        || fail "$label contains a symlink"
}

verify_product_identity() {
    product_app=$1
    label=$2
    version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$product_app/Contents/Info.plist" 2>/dev/null) \
        || fail "$label version is unreadable"
    build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
        "$product_app/Contents/Info.plist" 2>/dev/null) \
        || fail "$label build is unreadable"
    bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$product_app/Contents/Info.plist" 2>/dev/null) \
        || fail "$label bundle identifier is unreadable"
    [ "$version" = "$canonical_version" ] \
        && [ "$build" = "$canonical_build" ] \
        && [ "$bundle" = "$canonical_bundle_id" ] \
        || fail "$label product identity drifted"
}

verify_bundled_closure() {
    closure_app=$1
    label=$2
    helper_path="$closure_app/Contents/Helpers/trace_streamer"
    manifest_path="$closure_app/Contents/Resources/TraceStreamer/manifest.json"
    signing_path="$closure_app/Contents/Resources/TraceStreamer/distribution-signing.json"
    cmp "$repository_root/LICENSE" "$closure_app/Contents/Resources/LICENSE" >/dev/null 2>&1 \
        || fail "$label ArkTrace license drifted"
    cmp "$repository_root/THIRD_PARTY_NOTICES.md" \
        "$closure_app/Contents/Resources/THIRD_PARTY_NOTICES.md" >/dev/null 2>&1 \
        || fail "$label third-party notice drifted"
    cmp "$repository_root/ThirdParty/TraceStreamer/license-inventory.json" \
        "$closure_app/Contents/Resources/license-inventory.json" >/dev/null 2>&1 \
        || fail "$label license inventory drifted"
    diff -qr "$repository_root/ThirdParty/TraceStreamer/LICENSES" \
        "$closure_app/Contents/Resources/Licenses" >/dev/null 2>&1 \
        || fail "$label license directory drifted"
    helper_sha=$(sha256 "$helper_path")
    [ "$helper_sha" = "$(jq -er '.binarySHA256' "$manifest_path")" ] \
        || fail "$label helper differs from its bundled manifest"
    repository_manifest="$repository_root/ThirdParty/TraceStreamer/macx/manifest.json"
    jq -e \
        --arg unsigned "$(jq -er '.binarySHA256' "$repository_manifest")" \
        --arg signed "$helper_sha" \
        --arg recipe "$(jq -er '.buildRecipeVersion' "$repository_manifest")" \
        --arg team "$team" --arg identity "$identity" \
        --arg certificate "$certificate_sha1" '
        .formatVersion == 1
        and ((keys | sort) == ["buildRecipeVersion","formatVersion","signedBinarySHA256","signingCertificateSHA1","signingIdentity","signingPolicy","teamIdentifier","unsignedBinarySHA256"])
        and .unsignedBinarySHA256 == $unsigned
        and .signedBinarySHA256 == $signed
        and .buildRecipeVersion == $recipe
        and .teamIdentifier == $team
        and .signingIdentity == $identity
        and .signingCertificateSHA1 == $certificate
        and .signingPolicy == "developer-id-runtime-timestamp"
    ' "$signing_path" >/dev/null \
        || fail "$label parser signing provenance is incomplete"
}

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd -P)
. "$script_directory/phase3_shell_safety.sh"

identity=${ARKTRACE_DEVELOPER_ID_APPLICATION:-}
team=${ARKTRACE_DEVELOPMENT_TEAM:-}
reviewed_app_input=${ARKTRACE_REVIEWED_SIGNED_APP:-}
accessibility_input=${ARKTRACE_ACCESSIBILITY_EVIDENCE:-}
artifact_input=${ARKTRACE_REVIEWED_NOTARIZED_ZIP:-}
notarization_input=${ARKTRACE_REVIEWED_NOTARIZATION_EVIDENCE:-}

[ -n "$identity" ] && [ -n "$team" ] \
    || fail "Developer ID identity and team are required"
[ -n "$reviewed_app_input" ] && [ -n "$accessibility_input" ] \
    || fail "the reviewed signed App and accessibility evidence are required"
[ -n "$artifact_input" ] && [ -n "$notarization_input" ] \
    || fail "both retained notarized ZIP and notarization evidence are required"

arktrace_validate_reviewed_roots "$repository_root"
umask 077
temporary_root=$(mktemp -d \
    "$ARKTRACE_REVIEWED_TEMP_ROOT/arktrace-retained-notarization.XXXXXX") \
    || fail "verification workspace could not be created"
cleanup() { rm -rf -- "$temporary_root"; }
trap cleanup EXIT HUP INT TERM
external_log_index=0

evidence_fields=$(reviewed_evidence_file "$notarization_input" \
    "notarization evidence" 32768)
notarization_evidence=${evidence_fields%%$(printf '\t')*}
notarization_relative=${evidence_fields#*$(printf '\t')}
accessibility_fields=$(reviewed_evidence_file "$accessibility_input" \
    "accessibility evidence" 16384)
accessibility_evidence=${accessibility_fields%%$(printf '\t')*}
accessibility_relative=${accessibility_fields#*$(printf '\t')}

jq -e '
    .formatVersion == 1
    and ((keys | sort) == ["accessibilityEvidence","app","artifact","artifactReview","evidenceRevision","formatVersion","notarization","packagedAt","reviewedAt","sourceRevision"])
    and ((.accessibilityEvidence | keys | sort) == ["path","sha256"])
    and ((.app | keys | sort) == ["build","bundleIdentifier","candidateCodeDirectoryHash","candidateTreeSHA256","signingCertificateSHA1","signingIdentity","teamIdentifier","version"])
    and ((.artifact | keys | sort) == ["byteCount","fileName","sha256"])
    and ((.artifactReview | keys | sort) == ["method","reviewEndedAt","reviewStartedAt","reviewer"])
    and ((.notarization | keys | sort) == ["finalArchiveReverified","gatekeeperAssessment","nestedAndOuterSignaturesValid","receiptPath","receiptSHA256","stapledTicketValidated","status","submissionID"])
    and (.artifact.fileName | test("^ArkTrace-[0-9]{8}T[0-9]{6}Z(?:-retained)?[.]zip$"))
    and (.artifact.byteCount | type == "number" and . > 0 and . <= 1073741824 and floor == .)
    and (.artifact.sha256 | test("^[0-9a-f]{64}$"))
    and (.app.candidateTreeSHA256 | test("^[0-9a-f]{64}$"))
    and (.app.candidateCodeDirectoryHash | test("^[0-9a-f]{40}$"))
    and (.app.signingCertificateSHA1 | test("^[0-9A-F]{40}$"))
    and (.app.signingIdentity | type == "string" and length > 0 and length <= 128)
    and (.app.teamIdentifier | test("^[A-Z0-9]{10}$"))
    and (.artifactReview.method == "independent-agent-review" or .artifactReview.method == "independent-human-review")
    and (.artifactReview.reviewer | type == "string" and length > 0 and length <= 128)
    and .notarization.finalArchiveReverified == true
    and .notarization.nestedAndOuterSignaturesValid == true
    and .notarization.stapledTicketValidated == true
    and .notarization.gatekeeperAssessment == "accepted"
    and .notarization.status == "Accepted"
    and (.notarization.submissionID | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))
    and (.notarization.receiptSHA256 | test("^[0-9a-f]{64}$"))
    and (.sourceRevision | test("^[0-9a-f]{40}$"))
    and (.evidenceRevision | test("^[0-9a-f]{40}$"))
' "$notarization_evidence" >/dev/null \
    || fail "notarization evidence schema is invalid"

candidate_tree=$(jq -er '.app.candidateTreeSHA256' "$notarization_evidence")
candidate_cdhash=$(jq -er '.app.candidateCodeDirectoryHash' "$notarization_evidence")
certificate_sha1=$(jq -er '.app.signingCertificateSHA1' "$notarization_evidence")
[ "$(jq -er '.app.signingIdentity' "$notarization_evidence")" = "$identity" ] \
    && [ "$(jq -er '.app.teamIdentifier' "$notarization_evidence")" = "$team" ] \
    || fail "configured signing identity differs from reviewed evidence"
[ "$(jq -er '.accessibilityEvidence.path' "$notarization_evidence")" = "$accessibility_relative" ] \
    && [ "$(jq -er '.accessibilityEvidence.sha256' "$notarization_evidence")" = "$(sha256 "$accessibility_evidence")" ] \
    || fail "notarization evidence does not bind the accessibility review"

for timestamp in \
    "$(jq -er '.packagedAt' "$notarization_evidence")" \
    "$(jq -er '.reviewedAt' "$notarization_evidence")" \
    "$(jq -er '.artifactReview.reviewStartedAt' "$notarization_evidence")" \
    "$(jq -er '.artifactReview.reviewEndedAt' "$notarization_evidence")"
do
    PYTHONDONTWRITEBYTECODE=1 python3 -B \
        "$script_directory/verify_phase3_evidence_times.py" --timestamp "$timestamp" \
        >/dev/null 2>&1 || fail "notarization evidence timestamp is invalid"
done
packaged_at=$(jq -er '.packagedAt' "$notarization_evidence")
review_started=$(jq -er '.artifactReview.reviewStartedAt' "$notarization_evidence")
review_ended=$(jq -er '.artifactReview.reviewEndedAt' "$notarization_evidence")
[ "$packaged_at" \< "$review_started" ] \
    && [ "$review_started" \< "$review_ended" ] \
    && [ "$(jq -er '.reviewedAt' "$notarization_evidence")" = "$review_ended" ] \
    || fail "notarization artifact review timestamps are inconsistent"

source_revision=$(jq -er '.sourceRevision' "$notarization_evidence")
evidence_revision=$(jq -er '.evidenceRevision' "$notarization_evidence")
git -C "$repository_root" cat-file -e "$source_revision^{commit}" 2>/dev/null \
    && git -C "$repository_root" cat-file -e "$evidence_revision^{commit}" 2>/dev/null \
    && git -C "$repository_root" merge-base --is-ancestor "$source_revision" "$evidence_revision" \
    && git -C "$repository_root" merge-base --is-ancestor "$evidence_revision" HEAD \
    || fail "notarization evidence revision lineage is invalid"
[ "$(git -C "$repository_root" show "$evidence_revision:$accessibility_relative" 2>/dev/null \
    | shasum -a 256 | awk '{print $1}')" = "$(sha256 "$accessibility_evidence")" ] \
    || fail "accessibility evidence was not fixed by its reviewed revision"

reviewed_app_parent=$(CDPATH= cd -- "$(dirname -- "$reviewed_app_input")" && pwd -P) \
    || fail "reviewed App parent is inaccessible"
reviewed_app_input="$reviewed_app_parent/$(basename -- "$reviewed_app_input")"
reviewed_app_root=$(arktrace_root_for_path "$reviewed_app_input") \
    || fail "reviewed App is outside reviewed build/temp roots"
arktrace_assert_physical_directory_chain "$reviewed_app_root" "$reviewed_app_input" \
    || fail "reviewed App path is not physical"
[ -d "$reviewed_app_input" ] && [ ! -L "$reviewed_app_input" ] \
    || fail "reviewed App is unavailable or is a symlink"
candidate_app="$temporary_root/candidate/ArkTrace.app"
mkdir "$temporary_root/candidate"
run_external "reviewed App copy failed" /usr/bin/ditto --noqtn \
    "$reviewed_app_input" "$candidate_app"
validate_app_resources "$candidate_app" "reviewed App"
signature_detail "$candidate_app/Contents/Helpers/trace_streamer" "reviewed-helper"
signature_detail "$candidate_app" "reviewed-app"
run_external "reviewed App nested signatures are invalid" \
    codesign --verify --deep --strict --verbose=2 "$candidate_app"
[ "$(app_tree_sha "$candidate_app")" = "$candidate_tree" ] \
    || fail "reviewed App tree differs from notarization evidence"
[ "$(signature_cdhash "$candidate_app" reviewed-app)" = "$candidate_cdhash" ] \
    || fail "reviewed App CodeDirectory differs from notarization evidence"

configuration="$repository_root/Config/ArkTraceProduct.xcconfig"
canonical_version=$(awk -F= '/^ARKTRACE_PRODUCT_VERSION[[:space:]]*=/{gsub(/[[:space:]]/,"",$2);print $2}' "$configuration")
canonical_build=$(awk -F= '/^ARKTRACE_PRODUCT_BUILD[[:space:]]*=/{gsub(/[[:space:]]/,"",$2);print $2}' "$configuration")
canonical_bundle_id=$(awk -F= '/^ARKTRACE_BUNDLE_IDENTIFIER[[:space:]]*=/{gsub(/[[:space:]]/,"",$2);print $2}' "$configuration")
verify_product_identity "$candidate_app" "reviewed App"
[ "$(jq -er '.app.version' "$notarization_evidence")" = "$canonical_version" ] \
    && [ "$(jq -er '.app.build' "$notarization_evidence")" = "$canonical_build" ] \
    && [ "$(jq -er '.app.bundleIdentifier' "$notarization_evidence")" = "$canonical_bundle_id" ] \
    || fail "notarization evidence product identity drifted"

jq -e \
    --arg tree "$candidate_tree" --arg cdhash "$candidate_cdhash" \
    --arg version "$canonical_version" --arg build "$canonical_build" \
    --arg bundle "$canonical_bundle_id" --arg team "$team" '
    .formatVersion == 1
    and ((keys | sort) == ["app","checks","formatVersion","reviewMethod","reviewedAt","reviewer"])
    and .app.treeSHA256 == $tree
    and .app.codeDirectoryHash == $cdhash
    and .app.version == $version and .app.build == $build
    and .app.bundleIdentifier == $bundle and .app.teamIdentifier == $team
    and ((.app | keys | sort) == ["build","bundleIdentifier","codeDirectoryHash","teamIdentifier","treeSHA256","version"])
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
    and (.reviewMethod == "independent-agent-review" or .reviewMethod == "independent-human-review")
    and (.reviewedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
' "$accessibility_evidence" >/dev/null \
    || fail "accessibility evidence does not bind the notarized candidate"
PYTHONDONTWRITEBYTECODE=1 python3 -B \
    "$script_directory/verify_phase3_evidence_times.py" \
    --timestamp "$(jq -er '.reviewedAt' "$accessibility_evidence")" >/dev/null 2>&1 \
    || fail "accessibility review timestamp is invalid"
while IFS="$(printf '\t')" read -r check_name artifact_path artifact_sha; do
    verify_accessibility_artifact "$check_name" "$artifact_path" "$artifact_sha"
done <<EOF
$(jq -r '.checks | to_entries[] | [.key,.value.artifactPath,.value.artifactSHA256] | @tsv' "$accessibility_evidence")
EOF

entitlements="$temporary_root/candidate-entitlements.plist"
codesign -d --entitlements :- "$candidate_app" >"$entitlements" 2>/dev/null \
    || fail "reviewed App entitlements are unreadable"
[ "$(plutil -p "$entitlements" | tr -d '[:space:]')" = '{}' ] \
    || fail "reviewed App must have empty entitlements"
verify_bundled_closure "$candidate_app" "reviewed App"
candidate_helper="$candidate_app/Contents/Helpers/trace_streamer"
candidate_helper_sha=$(sha256 "$candidate_helper")
candidate_helper_cdhash=$(signature_cdhash "$candidate_helper" reviewed-helper)
candidate_signing_record="$candidate_app/Contents/Resources/TraceStreamer/distribution-signing.json"

receipt_relative=$(jq -er '.notarization.receiptPath' "$notarization_evidence")
case "$receipt_relative" in Fixtures/release-evidence/*) ;; *) fail "notarization receipt escaped its evidence root" ;; esac
case "/$receipt_relative/" in */../*|*/./*) fail "notarization receipt path is invalid" ;; esac
receipt="$repository_root/$receipt_relative"
arktrace_assert_physical_file_within "$repository_root" "$receipt" "notarization receipt"
git -C "$repository_root" ls-files --error-unmatch "$receipt_relative" >/dev/null 2>&1 \
    || fail "notarization receipt is not tracked"
reviewed_head_file "$receipt_relative" "$receipt"
[ "$(stat -f '%z' "$receipt")" -le 65536 ] \
    || fail "notarization receipt exceeds its byte bound"
[ "$(sha256 "$receipt")" = "$(jq -er '.notarization.receiptSHA256' "$notarization_evidence")" ] \
    || fail "notarization receipt SHA drifted"
submission_id=$(jq -er '.notarization.submissionID' "$notarization_evidence")
jq -e \
    --arg id "$submission_id" --arg app "$candidate_cdhash" \
    --arg helper "$candidate_helper_cdhash" '
    ((keys | sort) == ["archiveFilename","issues","jobId","logFormatVersion","sha256","status","statusCode","statusSummary","ticketContents","uploadDate"])
    and .archiveFilename == "ArkTrace-notary-submission.zip"
    and .issues == null and .jobId == $id and .logFormatVersion == 1
    and (.sha256 | test("^[0-9a-f]{64}$"))
    and .status == "Accepted" and .statusCode == 0
    and .statusSummary == "Ready for distribution"
    and (.uploadDate | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[.][0-9]{3}Z$"))
    and (.ticketContents | length == 4)
    and ([.ticketContents[] | ((keys | sort) == ["arch","cdhash","digestAlgorithm","path"])] | all)
    and ([.ticketContents[] | .arch == "arm64" and .digestAlgorithm == "SHA-256"] | all)
    and ([.ticketContents[] | select(.path == "ArkTrace-notary-submission.zip/ArkTrace.app" and .cdhash == $app)] | length == 1)
    and ([.ticketContents[] | select(.path == "ArkTrace-notary-submission.zip/ArkTrace.app/Contents/MacOS/ArkTrace" and .cdhash == $app)] | length == 1)
    and ([.ticketContents[] | select(.path == "ArkTrace-notary-submission.zip/ArkTrace.app/Contents/Helpers/trace_streamer" and .cdhash == $helper)] | length == 2)
    and ([.ticketContents[] | .path] | all(. == "ArkTrace-notary-submission.zip/ArkTrace.app" or . == "ArkTrace-notary-submission.zip/ArkTrace.app/Contents/MacOS/ArkTrace" or . == "ArkTrace-notary-submission.zip/ArkTrace.app/Contents/Helpers/trace_streamer"))
' "$receipt" >/dev/null \
    || fail "notarization receipt does not close over the exact candidate"

[ -f "$artifact_input" ] && [ ! -L "$artifact_input" ] \
    || fail "retained notarized ZIP is unavailable or is a symlink"
artifact_parent=$(CDPATH= cd -- "$(dirname -- "$artifact_input")" && pwd -P) \
    || fail "retained notarized ZIP parent is inaccessible"
artifact="$artifact_parent/$(basename -- "$artifact_input")"
artifact_root=$(arktrace_root_for_path "$artifact") \
    || fail "retained notarized ZIP is outside reviewed build/temp roots"
arktrace_assert_physical_directory_chain "$artifact_root" "$artifact_parent" \
    || fail "retained notarized ZIP parent chain is not physical"
arktrace_is_fully_allocated_regular_file "$artifact" \
    || fail "retained notarized ZIP is sparse or non-regular"
[ "$(basename -- "$artifact")" = "$(jq -er '.artifact.fileName' "$notarization_evidence")" ] \
    && [ "$(stat -f '%z' "$artifact")" = "$(jq -er '.artifact.byteCount' "$notarization_evidence")" ] \
    && [ "$(sha256 "$artifact")" = "$(jq -er '.artifact.sha256' "$notarization_evidence")" ] \
    || fail "retained notarized ZIP identity drifted"
run_external "retained notarized ZIP CRC validation failed" unzip -tqq "$artifact"

extracted="$temporary_root/extracted"
mkdir "$extracted"
run_external "retained notarized ZIP extraction failed" \
    /usr/bin/ditto -x -k "$artifact" "$extracted"
[ "$(find "$extracted" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')" -eq 1 ] \
    && [ -d "$extracted/ArkTrace.app" ] && [ ! -L "$extracted/ArkTrace.app" ] \
    || fail "retained notarized ZIP top-level shape is invalid"
final_app="$extracted/ArkTrace.app"
validate_app_resources "$final_app" "retained App"
while IFS= read -r physical_file; do
    arktrace_is_fully_allocated_regular_file "$physical_file" \
        || fail "retained App contains a sparse or non-regular file"
done <<EOF
$(find "$final_app" -type f -print)
EOF

final_helper="$final_app/Contents/Helpers/trace_streamer"
signature_detail "$final_helper" "retained-helper"
signature_detail "$final_app" "retained-app"
run_external "retained App nested signatures are invalid" \
    codesign --verify --deep --strict --verbose=2 "$final_app"
run_external "retained App does not contain a valid Apple staple ticket" \
    xcrun stapler validate "$final_app"
run_external "retained App Gatekeeper assessment failed" \
    spctl --assess --type execute --verbose=2 "$final_app"
verify_product_identity "$final_app" "retained App"
verify_bundled_closure "$final_app" "retained App"
[ "$(signature_cdhash "$final_app" retained-app)" = "$candidate_cdhash" ] \
    && [ "$(signature_cdhash "$final_helper" retained-helper)" = "$candidate_helper_cdhash" ] \
    || fail "retained App CodeDirectory identity drifted"
[ "$(sha256 "$final_helper")" = "$candidate_helper_sha" ] \
    || fail "retained App helper bytes drifted"
cmp "$candidate_signing_record" \
    "$final_app/Contents/Resources/TraceStreamer/distribution-signing.json" >/dev/null 2>&1 \
    || fail "retained App parser signing record drifted"

ticket="$final_app/Contents/CodeResources"
[ -f "$ticket" ] && [ ! -L "$ticket" ] && [ "$(stat -f '%Lp' "$ticket")" = 600 ] \
    || fail "retained App staple ticket shape or mode is invalid"
normalized="$temporary_root/normalized/ArkTrace.app"
mkdir "$temporary_root/normalized"
run_external "retained App normalization copy failed" \
    /usr/bin/ditto --noqtn "$final_app" "$normalized"
rm -f -- "$normalized/Contents/CodeResources"
[ ! -e "$normalized/Contents/CodeResources" ] \
    && [ "$(app_tree_sha "$normalized")" = "$candidate_tree" ] \
    || fail "retained App differs from the reviewed candidate beyond the Apple ticket"

printf 'Phase 3 retained notarization verification passed: artifact=%s sha256=%s notarizationStatus=Accepted submissionID=%s\n' \
    "$(basename -- "$artifact")" "$(sha256 "$artifact")" "$submission_id"
