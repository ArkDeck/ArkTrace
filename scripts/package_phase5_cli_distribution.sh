#!/bin/sh
set -eu

fail() {
    printf 'Phase 5 CLI package/notarization failed: %s\n' "$1" >&2
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

require_signature() {
    candidate=$1
    label=$2
    detail="$temporary_root/signature-$label.txt"
    codesign -dv --verbose=4 "$candidate" 2>"$detail" \
        || fail "$label signature details are unavailable"
    grep -Fx "TeamIdentifier=$team" "$detail" >/dev/null \
        || fail "$label TeamIdentifier drifted"
    grep -Fx "Authority=$identity" "$detail" >/dev/null \
        || fail "$label Developer ID authority drifted"
    grep -E '^CodeDirectory .* flags=.*\(runtime\)' "$detail" >/dev/null \
        || fail "$label hardened runtime is missing"
    grep -E '^Timestamp=' "$detail" >/dev/null \
        || fail "$label trusted timestamp is missing"
    [ "$(signature_certificate_sha1 "$candidate" "$label")" = "$certificate_sha1" ] \
        || fail "$label signing certificate drifted"
}

require_no_entitlements() {
    candidate=$1
    label=$2
    output="$temporary_root/entitlements-$label.plist"
    diagnostic="$temporary_root/entitlements-$label.log"
    if ! codesign -d --entitlements - "$candidate" >"$output" 2>"$diagnostic"; then
        fail "$label entitlement inspection failed"
    fi
    [ ! -s "$output" ] \
        && ! grep -F 'invalid entitlements blob' "$diagnostic" >/dev/null 2>&1 \
        || fail "$label must contain no entitlement blob"
}

require_licenses_contract() {
    candidate_tool=$1
    candidate_home=$2
    label=$3
    machine_output="$temporary_root/licenses-$label.json"
    human_output="$temporary_root/licenses-$label.txt"
    machine_error="$temporary_root/licenses-$label-machine.log"
    human_error="$temporary_root/licenses-$label-human.log"
    if ! CFFIXED_USER_HOME="$candidate_home" HOME="$candidate_home" \
        "$candidate_tool" --json licenses >"$machine_output" 2>"$machine_error"
    then
        arktrace_bounded_failure_summary "$machine_error"
        fail "$label installed CLI machine licenses failed"
    fi
    jq -e '
        .schemaVersion == "1.0"
        and .request.command == "licenses"
        and .result.componentCount == 14
        and .result.buildToolCount == 2
        and (.result.licenseFiles | length) == 18
        and ([.result.licenseFiles[].resource] | unique | length) == 18
        and ([.result.licenseFiles[] |
            (.resource | startswith("LICENSES/"))
            and (.sha256 | test("^[0-9a-f]{64}$"))
            and (.byteCount | type == "number" and . > 0)] | all)
        and .dataQuality.status == "ok"
        and .truncation.truncated == false
    ' "$machine_output" >/dev/null \
        || fail "$label installed CLI machine licenses contract is invalid"
    [ ! -s "$machine_error" ] \
        || fail "$label installed CLI machine licenses emitted diagnostics"
    if ! CFFIXED_USER_HOME="$candidate_home" HOME="$candidate_home" \
        "$candidate_tool" licenses >"$human_output" 2>"$human_error"
    then
        arktrace_bounded_failure_summary "$human_error"
        fail "$label installed CLI human licenses failed"
    fi
    grep -Fx '# ArkTrace Product License' "$human_output" >/dev/null \
        && grep -Fx '# ArkTrace Third-Party Notices' "$human_output" >/dev/null \
        && grep -Fx '# Bundled Third-Party License Files' "$human_output" >/dev/null \
        || fail "$label installed CLI human licenses contract is invalid"
    [ ! -s "$human_error" ] \
        || fail "$label installed CLI human licenses emitted diagnostics"
}

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd -P)
. "$script_directory/phase3_shell_safety.sh"
. "$script_directory/phase5_publish.sh"

identity=${ARKTRACE_DEVELOPER_ID_APPLICATION:-}
team=${ARKTRACE_DEVELOPMENT_TEAM:-}
notary_profile=${ARKTRACE_NOTARY_PROFILE:-}
candidate_input=${ARKTRACE_PHASE5_CLI_CANDIDATE:-}
artifact_directory=${ARKTRACE_PHASE5_CLI_ARTIFACT_DIR:-$repository_root/.build/phase5-cli-artifacts}
[ -n "$identity" ] && [ -n "$team" ] && [ -n "$notary_profile" ] \
    || fail "Developer ID identity, team, and notary profile are required"
[ -n "$candidate_input" ] || fail "reviewed CLI candidate is required"

arktrace_validate_reviewed_roots "$repository_root"
arktrace_validate_owned_directory_request "$artifact_directory" "CLI artifact output"
arktrace_create_reviewed_build_root
artifact_directory=$(arktrace_secure_owned_directory \
    "$artifact_directory" .arktrace-phase5-cli-artifacts-v1 "CLI artifact output")
umask 077
publication_staging=$(mktemp -d "$artifact_directory/.publication.XXXXXX") \
    || fail "CLI artifact publication staging could not be created"
chmod 700 "$publication_staging"
temporary_root=
cleanup() {
    rm -rf -- "$publication_staging"
    if [ -n "$temporary_root" ]; then rm -rf -- "$temporary_root"; fi
}
trap cleanup EXIT HUP INT TERM
case "$candidate_input" in /*) candidate=$candidate_input ;; *) fail "CLI candidate path must be absolute" ;; esac
candidate_parent=$(dirname -- "$candidate")
candidate_root=$(arktrace_root_for_path "$candidate") \
    || fail "CLI candidate is outside reviewed build/temp roots"
arktrace_assert_physical_directory_chain "$candidate_root" "$candidate_parent" \
    || fail "CLI candidate parent chain is not physical"
[ -d "$candidate" ] && [ ! -L "$candidate" ] \
    || fail "CLI candidate is not a physical App bundle"
record="$candidate.json"
arktrace_assert_physical_file_within "$candidate_root" "$record" "CLI candidate record"

temporary_root=$(mktemp -d "$ARKTRACE_REVIEWED_TEMP_ROOT/arktrace-cli-package.XXXXXX") \
    || fail "CLI package private work root could not be created"
external_log_index=0

# Consume the caller-provided sidecar exactly once through a bounded,
# no-follow descriptor, then make every later decision from this private
# immutable snapshot rather than repeatedly reopening external bytes.
record_input=$record
record="$temporary_root/candidate-record.json"
python3 -B "$script_directory/verify_phase5_cli_distribution.py" \
    snapshot-json "$record_input" "$record" \
    || fail "CLI candidate record snapshot failed"

identity_log="$temporary_root/security-identities.log"
security find-identity -v -p codesigning >"$identity_log" 2>&1 \
    || fail "Developer ID identities are unavailable"
certificate_sha1=$(awk -v suffix="\"$identity\"" '
    substr($0, length($0) - length(suffix) + 1) == suffix { print $2 }
' "$identity_log")
[ "$(printf '%s\n' "$certificate_sha1" | grep -Ec '^[0-9A-Fa-f]{40}$')" -eq 1 ] \
    || fail "configured Developer ID Application identity is not uniquely available"
certificate_sha1=$(printf '%s' "$certificate_sha1" | tr '[:lower:]' '[:upper:]')

expected_source_tree=$(python3 -B "$script_directory/source_tree_identity.py" "$repository_root") \
    || fail "source tree identity is unavailable"
expected_revision=$(git -C "$repository_root" rev-parse HEAD)
jq -e \
    --arg app "$(basename "$candidate")" \
    --arg revision "$expected_revision" \
    --arg tree "$expected_source_tree" \
    --arg team "$team" \
    --arg identity "$identity" \
    --arg certificate "$certificate_sha1" '
    .formatVersion == 1
    and ((keys | sort) == [
      "app","appCodeDirectoryHash","appTreeSHA256","formatVersion","product",
      "resourceTreeSHA256","signing","source","tool","traceStreamer"
    ])
    and .app == $app
    and .source == {revision: $revision, treeSHA256: $tree}
    and .product == {
      name: "arktrace", version: "0.1.0", build: "1",
      architecture: "arm64", bundleIdentifier: "com.arktrace.ArkTrace.CLI",
      jsonContract: {major: 1, minor: 0}
    }
    and (.appTreeSHA256 | test("^[0-9a-f]{64}$"))
    and (.resourceTreeSHA256 | test("^[0-9a-f]{64}$"))
    and (.appCodeDirectoryHash | test("^[0-9a-f]{40}$"))
    and (.tool | (keys | sort) == ["binarySHA256","byteCount","codeDirectoryHash"])
    and (.tool.binarySHA256 | test("^[0-9a-f]{64}$"))
    and (.tool.byteCount | type == "number" and . > 0)
    and (.tool.codeDirectoryHash | test("^[0-9a-f]{40}$"))
    and (.traceStreamer | (keys | sort) == [
      "binarySHA256","buildRecipeVersion","byteCount","codeDirectoryHash",
      "manifestByteCount","manifestSHA256","reportedVersion","signingRecordByteCount",
      "signingRecordSHA256","unsignedBinarySHA256","upstreamRevision"
    ])
    and (.traceStreamer.unsignedBinarySHA256 | test("^[0-9a-f]{64}$"))
    and (.traceStreamer.binarySHA256 | test("^[0-9a-f]{64}$"))
    and (.traceStreamer.byteCount | type == "number" and . > 0)
    and (.traceStreamer.codeDirectoryHash | test("^[0-9a-f]{40}$"))
    and (.traceStreamer.manifestSHA256 | test("^[0-9a-f]{64}$"))
    and (.traceStreamer.manifestByteCount | type == "number" and . > 0)
    and (.traceStreamer.signingRecordSHA256 | test("^[0-9a-f]{64}$"))
    and (.traceStreamer.signingRecordByteCount | type == "number" and . > 0)
    and (.traceStreamer.upstreamRevision | test("^[0-9a-f]{40}$"))
    and (.traceStreamer.buildRecipeVersion | test("^[0-9a-f]{64}$"))
    and .signing == {
      teamIdentifier: $team, identity: $identity,
      certificateSHA1: $certificate,
      policy: "developer-id-runtime-timestamp"
    }
' "$record" >/dev/null || fail "CLI candidate record is invalid or stale"

# Copy the caller-owned App through one no-follow root descriptor. The copier
# enforces the complete tree bounds while reading and rechecks the bound source
# tree after the private snapshot is complete, closing the preflight/copy race.
app="$temporary_root/ArkTraceCLI.app"
python3 -B "$script_directory/verify_phase5_cli_distribution.py" \
    snapshot-tree "$candidate" "$app" \
    || fail "CLI candidate bounded private snapshot failed"
python3 -B "$script_directory/verify_phase5_cli_distribution.py" \
    verify-app pre-notary "$app" >/dev/null \
    || fail "caller CLI candidate closure is invalid"
tool="$app/Contents/MacOS/arktrace"
helper="$app/Contents/Helpers/trace_streamer"
parser_manifest="$app/Contents/Resources/TraceStreamer/manifest.json"
parser_signing_record="$app/Contents/Resources/TraceStreamer/distribution-signing.json"
for candidate_file in "$tool" "$helper" "$parser_manifest" "$parser_signing_record" \
    "$app/Contents/Info.plist"
do
    arktrace_assert_physical_file_within "$app" "$candidate_file" "CLI candidate resource"
done
[ "$(python3 -B "$script_directory/verify_phase5_cli_distribution.py" tree-sha "$app")" = \
    "$(jq -er '.appTreeSHA256' "$record")" ] \
    || fail "CLI candidate tree drifted"
[ "$(python3 -B "$script_directory/verify_phase5_cli_distribution.py" \
    tree-sha "$app/Contents/Resources/ArkTraceCLIResources")" = \
    "$(jq -er '.resourceTreeSHA256' "$record")" ] \
    || fail "CLI resource tree drifted"
[ "$(shasum -a 256 "$tool" | awk '{print $1}')" = \
    "$(jq -er '.tool.binarySHA256' "$record")" ] \
    || fail "CLI executable identity drifted"
[ "$(stat -f '%z' "$tool")" = "$(jq -er '.tool.byteCount' "$record")" ] \
    || fail "CLI executable byte count drifted"
[ "$(shasum -a 256 "$helper" | awk '{print $1}')" = \
    "$(jq -er '.traceStreamer.binarySHA256' "$record")" ] \
    || fail "TraceStreamer identity drifted"
[ "$(shasum -a 256 "$parser_manifest" | awk '{print $1}')" = \
    "$(jq -er '.traceStreamer.manifestSHA256' "$record")" ] \
    || fail "TraceStreamer manifest identity drifted"
[ "$(shasum -a 256 "$parser_signing_record" | awk '{print $1}')" = \
    "$(jq -er '.traceStreamer.signingRecordSHA256' "$record")" ] \
    || fail "TraceStreamer signing record identity drifted"
actual_tool_cdhash=$(codesign -dv --verbose=4 "$tool" 2>&1 \
    | sed -n 's/^CDHash=//p' | head -1)
actual_parser_cdhash=$(codesign -dv --verbose=4 "$helper" 2>&1 \
    | sed -n 's/^CDHash=//p' | head -1)
actual_app_cdhash=$(codesign -dv --verbose=4 "$app" 2>&1 \
    | sed -n 's/^CDHash=//p' | head -1)
[ "$actual_tool_cdhash" = "$(jq -er '.tool.codeDirectoryHash' "$record")" ] \
    || fail "CLI executable CodeDirectory drifted"
[ "$actual_parser_cdhash" = "$(jq -er '.traceStreamer.codeDirectoryHash' "$record")" ] \
    || fail "TraceStreamer CodeDirectory drifted"
[ "$actual_app_cdhash" = "$(jq -er '.appCodeDirectoryHash' "$record")" ] \
    || fail "CLI App CodeDirectory drifted"
[ "$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist")" = \
    "com.arktrace.ArkTrace.CLI" ] \
    && [ "$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")" = \
        "0.1.0" ] \
    && [ "$(plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist")" = "1" ] \
    && [ "$(plutil -extract CFBundleExecutable raw -o - "$app/Contents/Info.plist")" = \
        "arktrace" ] \
    && [ "$(plutil -extract LSMinimumSystemVersion raw -o - "$app/Contents/Info.plist")" = \
        "14.0" ] \
    && [ "$(plutil -extract LSBackgroundOnly raw -o - "$app/Contents/Info.plist")" = \
        "true" ] \
    || fail "CLI App Info.plist identity drifted"
run_external "CLI candidate signature verification failed" \
    codesign --verify --deep --strict --verbose=2 "$app"
require_signature "$tool" tool
require_signature "$helper" helper
require_signature "$app" app
require_no_entitlements "$tool" tool
require_no_entitlements "$helper" helper
require_no_entitlements "$app" app
jq -e \
    --arg unsigned "$(jq -er '.traceStreamer.unsignedBinarySHA256' "$record")" \
    --arg signed "$(jq -er '.traceStreamer.binarySHA256' "$record")" \
    --arg recipe "$(jq -er '.traceStreamer.buildRecipeVersion' "$record")" \
    --arg team "$team" --arg identity "$identity" --arg certificate "$certificate_sha1" '
    . == {
      formatVersion: 1,
      unsignedBinarySHA256: $unsigned,
      signedBinarySHA256: $signed,
      buildRecipeVersion: $recipe,
      teamIdentifier: $team,
      signingIdentity: $identity,
      signingCertificateSHA1: $certificate,
      signingPolicy: "developer-id-runtime-timestamp"
    }
' "$parser_signing_record" >/dev/null \
    || fail "TraceStreamer signing provenance drifted"
preflight_home="$temporary_root/preflight-home"
mkdir -p "$preflight_home/Library/Caches"
require_licenses_contract "$tool" "$preflight_home" preflight
python3 -B "$script_directory/verify_phase5_cli_distribution.py" \
    verify-app pre-notary "$app" >/dev/null \
    || fail "pre-notary CLI App closure is invalid"

submission_zip="$temporary_root/ArkTraceCLI-notary-submission.zip"
run_external "notary submission archive failed" \
    /usr/bin/ditto -c -k --keepParent --sequesterRsrc "$app" "$submission_zip"
notary_response="$temporary_root/notary-response.json"
notary_log="$temporary_root/notary-response.log"
if ! xcrun notarytool submit "$submission_zip" \
    --keychain-profile "$notary_profile" --wait --output-format json \
    >"$notary_response" 2>"$notary_log"
then
    arktrace_bounded_failure_summary "$notary_log"
    fail "Apple notarization submission failed"
fi
jq -e '
    (keys | sort) == ["id","message","status"]
    and (.id | type == "string" and length >= 8 and length <= 64)
    and .status == "Accepted"
    and (.message | type == "string" and length <= 1024)
' "$notary_response" >/dev/null 2>&1 \
    || fail "Apple notarization was not accepted"
submission_id=$(jq -er '.id' "$notary_response")
run_external "notarization ticket could not be stapled" xcrun stapler staple "$app"
run_external "stapled ticket validation failed" xcrun stapler validate "$app"
run_external "Gatekeeper rejected the CLI App" spctl -a -t exec -vv "$app"
run_external "stapled CLI signature verification failed" \
    codesign --verify --deep --strict --verbose=2 "$app"
python3 -B "$script_directory/verify_phase5_cli_distribution.py" \
    verify-app post-staple "$app" >/dev/null \
    || fail "post-staple CLI App closure is invalid"
require_signature "$tool" final-tool
require_signature "$helper" final-helper
require_signature "$app" final-app
require_no_entitlements "$tool" final-tool
require_no_entitlements "$helper" final-helper
require_no_entitlements "$app" final-app

final_root="$temporary_root/ArkTraceCLI-0.1.0"
mkdir "$final_root"
run_external "stapled App copy failed" /usr/bin/ditto --noqtn "$app" "$final_root/ArkTraceCLI.app"
run_external "product license copy failed" /usr/bin/ditto --noqtn \
    "$repository_root/LICENSE" "$final_root/LICENSE"
run_external "third-party notice copy failed" /usr/bin/ditto --noqtn \
    "$repository_root/THIRD_PARTY_NOTICES.md" "$final_root/THIRD_PARTY_NOTICES.md"
jq '{formatVersion: 1, id, status, message}' "$notary_response" \
    >"$final_root/notarization-receipt.json" \
    || fail "notarization receipt projection failed"
chmod 644 "$final_root/notarization-receipt.json"

final_app="$final_root/ArkTraceCLI.app"
final_tool="$final_app/Contents/MacOS/arktrace"
final_helper="$final_app/Contents/Helpers/trace_streamer"
final_parser_manifest="$final_app/Contents/Resources/TraceStreamer/manifest.json"
final_parser_signing_record="$final_app/Contents/Resources/TraceStreamer/distribution-signing.json"
tool_sha=$(shasum -a 256 "$final_tool" | awk '{print $1}')
tool_bytes=$(stat -f '%z' "$final_tool")
tool_cdhash=$(codesign -dv --verbose=4 "$final_tool" 2>&1 \
    | sed -n 's/^CDHash=//p' | head -1)
app_cdhash=$(codesign -dv --verbose=4 "$final_app" 2>&1 \
    | sed -n 's/^CDHash=//p' | head -1)
parser_sha=$(shasum -a 256 "$final_helper" | awk '{print $1}')
parser_bytes=$(stat -f '%z' "$final_helper")
parser_cdhash=$(codesign -dv --verbose=4 "$final_helper" 2>&1 \
    | sed -n 's/^CDHash=//p' | head -1)
parser_manifest_sha=$(shasum -a 256 "$final_parser_manifest" | awk '{print $1}')
parser_manifest_bytes=$(stat -f '%z' "$final_parser_manifest")
parser_signing_sha=$(shasum -a 256 "$final_parser_signing_record" | awk '{print $1}')
parser_signing_bytes=$(stat -f '%z' "$final_parser_signing_record")
unsigned_parser_sha=$(jq -er '.unsignedBinarySHA256' "$final_parser_signing_record")
app_tree_sha=$(python3 -B "$script_directory/verify_phase5_cli_distribution.py" \
    tree-sha "$final_app") || fail "final App tree identity is unavailable"
resource_tree_sha=$(python3 -B "$script_directory/verify_phase5_cli_distribution.py" \
    tree-sha "$final_app/Contents/Resources/ArkTraceCLIResources") \
    || fail "final resource tree identity is unavailable"
receipt_sha=$(shasum -a 256 "$final_root/notarization-receipt.json" | awk '{print $1}')
license_sha=$(shasum -a 256 "$final_root/LICENSE" | awk '{print $1}')
notice_sha=$(shasum -a 256 "$final_root/THIRD_PARTY_NOTICES.md" | awk '{print $1}')
license_bytes=$(stat -f '%z' "$final_root/LICENSE")
notice_bytes=$(stat -f '%z' "$final_root/THIRD_PARTY_NOTICES.md")
inventory_path="$final_app/Contents/Resources/ArkTraceCLIResources/license-inventory.json"
inventory_sha=$(shasum -a 256 "$inventory_path" | awk '{print $1}')
inventory_bytes=$(stat -f '%z' "$inventory_path")
self_test_path="$final_app/Contents/Resources/ArkTraceCLIResources/zlib.htrace"
self_test_sha=$(shasum -a 256 "$self_test_path" | awk '{print $1}')
self_test_bytes=$(stat -f '%z' "$self_test_path")

jq -n \
    --arg revision "$expected_revision" \
    --arg sourceTree "$expected_source_tree" \
    --arg tool "$tool_sha" \
    --argjson toolBytes "$tool_bytes" \
    --arg toolCDHash "$tool_cdhash" \
    --arg appCDHash "$app_cdhash" \
    --arg parser "$parser_sha" \
    --arg unsignedParser "$unsigned_parser_sha" \
    --argjson parserBytes "$parser_bytes" \
    --arg parserCDHash "$parser_cdhash" \
    --arg parserManifest "$parser_manifest_sha" \
    --argjson parserManifestBytes "$parser_manifest_bytes" \
    --arg parserSigning "$parser_signing_sha" \
    --argjson parserSigningBytes "$parser_signing_bytes" \
    --arg parserVersion "$(jq -er '.reportedVersion' "$final_parser_manifest")" \
    --arg parserRevision "$(jq -er '.upstreamRevision' "$final_parser_manifest")" \
    --arg recipe "$(jq -er '.buildRecipeVersion' "$final_parser_manifest")" \
    --arg team "$team" \
    --arg identity "$identity" \
    --arg certificate "$certificate_sha1" \
    --arg submission "$submission_id" \
    --arg receipt "$receipt_sha" \
    --arg appTree "$app_tree_sha" \
    --arg resourceTree "$resource_tree_sha" \
    --arg license "$license_sha" \
    --argjson licenseBytes "$license_bytes" \
    --arg notice "$notice_sha" \
    --argjson noticeBytes "$notice_bytes" \
    --arg inventory "$inventory_sha" \
    --argjson inventoryBytes "$inventory_bytes" \
    --arg selfTest "$self_test_sha" \
    --argjson selfTestBytes "$self_test_bytes" '
    {
      formatVersion: 1,
      source: {revision: $revision, treeSHA256: $sourceTree},
      product: {
        name: "arktrace", version: "0.1.0", build: "1",
        architecture: "arm64", bundleIdentifier: "com.arktrace.ArkTrace.CLI",
        jsonContract: {major: 1, minor: 0}
      },
      layout: {
        bundle: "ArkTraceCLI.app",
        executable: "ArkTraceCLI.app/Contents/MacOS/arktrace",
        parserExecutable: "ArkTraceCLI.app/Contents/Helpers/trace_streamer",
        parserManifest: "ArkTraceCLI.app/Contents/Resources/TraceStreamer/manifest.json",
        parserSigningRecord: "ArkTraceCLI.app/Contents/Resources/TraceStreamer/distribution-signing.json",
        resourceBundle: "ArkTraceCLI.app/Contents/Resources/ArkTraceCLIResources"
      },
      tool: {binarySHA256: $tool, byteCount: $toolBytes, codeDirectoryHash: $toolCDHash},
      traceStreamer: {
        unsignedBinarySHA256: $unsignedParser,
        binarySHA256: $parser, byteCount: $parserBytes,
        codeDirectoryHash: $parserCDHash,
        manifestSHA256: $parserManifest, manifestByteCount: $parserManifestBytes,
        signingRecordSHA256: $parserSigning,
        signingRecordByteCount: $parserSigningBytes,
        reportedVersion: $parserVersion, upstreamRevision: $parserRevision,
        buildRecipeVersion: $recipe
      },
      signing: {
        teamIdentifier: $team, identity: $identity,
        certificateSHA1: $certificate,
        policy: "developer-id-runtime-timestamp"
      },
      notarization: {
        status: "Accepted", submissionID: $submission,
        receipt: "notarization-receipt.json", receiptSHA256: $receipt,
        stapledTicketValidated: true, gatekeeperAssessment: "accepted"
      },
      integrity: {
        appTreeSHA256: $appTree, resourceTreeSHA256: $resourceTree,
        appCodeDirectoryHash: $appCDHash
      },
      attribution: {
        license: "LICENSE", licenseSHA256: $license, licenseByteCount: $licenseBytes,
        notice: "THIRD_PARTY_NOTICES.md", noticeSHA256: $notice,
        noticeByteCount: $noticeBytes,
        inventory: "ArkTraceCLI.app/Contents/Resources/ArkTraceCLIResources/license-inventory.json",
        inventorySHA256: $inventory, inventoryByteCount: $inventoryBytes,
        licenseFileCount: 18,
        selfTestFixture: "ArkTraceCLI.app/Contents/Resources/ArkTraceCLIResources/zlib.htrace",
        selfTestFixtureSHA256: $selfTest, selfTestFixtureByteCount: $selfTestBytes
      },
      upgradePolicy: {
        identity: "distribution-manifest+tool-parser-hashes",
        installMode: "versioned-directory",
        pathSelection: "reviewed-absolute-descriptor-only",
        rollback: "retain-prior-exact-directory"
      }
    }
' >"$final_root/distribution-manifest.json" \
    || fail "distribution manifest could not be created"
chmod 644 "$final_root/distribution-manifest.json"

python3 -B "$script_directory/verify_phase5_cli_distribution.py" "$final_root" >/dev/null \
    || fail "final distribution manifest or layout is invalid"
smoke_home="$temporary_root/smoke-home"
mkdir -p "$smoke_home/Library/Caches"
doctor="$temporary_root/final-doctor.json"
if ! CFFIXED_USER_HOME="$smoke_home" HOME="$smoke_home" \
    "$final_tool" doctor --self-test --json --no-cache --timeout-ms 120000 \
    >"$doctor" 2>"$temporary_root/final-doctor.log"
then
    arktrace_bounded_failure_summary "$temporary_root/final-doctor.log"
    fail "final installed CLI doctor self-test failed"
fi
jq -e --arg tool "$tool_sha" '
    .schemaVersion == "1.0"
    and .tool.buildRevision == $tool
    and .request.command == "doctor"
    and .result.selfTest == true
    and ([.result.checks[].status] | all(. == "ok"))
' "$doctor" >/dev/null || fail "final installed CLI doctor contract is invalid"
require_licenses_contract "$final_tool" "$smoke_home" final

artifact_name="ArkTraceCLI-0.1.0-$(date -u +%Y%m%dT%H%M%SZ).zip"
final_zip="$artifact_directory/$artifact_name"
arktrace_require_absent_leaf "$final_zip" "final CLI artifact"
partial_zip="$publication_staging/$artifact_name.partial.zip"
run_external "final CLI archive creation failed" \
    /usr/bin/ditto -c -k --keepParent --sequesterRsrc "$final_root" "$partial_zip"

extracted="$temporary_root/extracted"
mkdir "$extracted"
run_external "final CLI archive extraction failed" /usr/bin/ditto -x -k "$partial_zip" "$extracted"
extracted_root="$extracted/ArkTraceCLI-0.1.0"
python3 -B "$script_directory/verify_phase5_cli_distribution.py" "$extracted_root" >/dev/null \
    || fail "extracted CLI distribution drifted"
extracted_manifest="$extracted_root/distribution-manifest.json"
extracted_app="$extracted_root/ArkTraceCLI.app"
extracted_tool="$extracted_app/Contents/MacOS/arktrace"
extracted_helper="$extracted_app/Contents/Helpers/trace_streamer"
[ "$(codesign -dv --verbose=4 "$extracted_app" 2>&1 \
    | sed -n 's/^CDHash=//p' | head -1)" = \
    "$(jq -er '.integrity.appCodeDirectoryHash' "$extracted_manifest")" ] \
    && [ "$(codesign -dv --verbose=4 "$extracted_tool" 2>&1 \
        | sed -n 's/^CDHash=//p' | head -1)" = \
        "$(jq -er '.tool.codeDirectoryHash' "$extracted_manifest")" ] \
    && [ "$(codesign -dv --verbose=4 "$extracted_helper" 2>&1 \
        | sed -n 's/^CDHash=//p' | head -1)" = \
        "$(jq -er '.traceStreamer.codeDirectoryHash' "$extracted_manifest")" ] \
    || fail "extracted CLI CodeDirectory identity drifted"
run_external "extracted CLI signature verification failed" \
    codesign --verify --deep --strict --verbose=2 "$extracted_app"
require_no_entitlements "$extracted_tool" extracted-tool
require_no_entitlements "$extracted_helper" extracted-helper
require_no_entitlements "$extracted_app" extracted-app
run_external "extracted CLI ticket validation failed" \
    xcrun stapler validate "$extracted_app"
run_external "Gatekeeper rejected the extracted CLI App" \
    spctl -a -t exec -vv "$extracted_app"
run_external "quarantine marker could not be applied" \
    xattr -r -w com.apple.quarantine "0081;$(printf '%x' "$(date +%s)");ArkTrace;" \
        "$extracted_app"
quarantine_home="$temporary_root/quarantine-home"
mkdir -p "$quarantine_home/Library/Caches"
quarantine_doctor="$temporary_root/quarantine-doctor.json"
if ! CFFIXED_USER_HOME="$quarantine_home" HOME="$quarantine_home" \
    "$extracted_tool" \
        doctor --self-test --json --no-cache --timeout-ms 120000 \
        >"$quarantine_doctor" 2>"$temporary_root/quarantine-doctor.log"
then
    arktrace_bounded_failure_summary "$temporary_root/quarantine-doctor.log"
    fail "quarantined CLI doctor self-test failed"
fi
jq -e --arg tool "$tool_sha" '
    .tool.buildRevision == $tool
    and .request.command == "doctor"
    and .result.selfTest == true
    and ([.result.checks[].status] | all(. == "ok"))
' "$quarantine_doctor" >/dev/null \
    || fail "quarantined CLI doctor contract is invalid"
require_licenses_contract \
    "$extracted_tool" \
    "$quarantine_home" quarantine

expected_zip_sha=$(shasum -a 256 "$partial_zip" | awk '{print $1}')
expected_zip_bytes=$(stat -f '%z' "$partial_zip")
arktrace_phase5_publish_file \
    "$partial_zip" "$final_zip" "$expected_zip_sha" "$expected_zip_bytes" \
    || fail "final CLI artifact publication collided"
artifact_sha=$(shasum -a 256 "$final_zip" | awk '{print $1}')
artifact_bytes=$(stat -f '%z' "$final_zip")
manifest_sha=$(shasum -a 256 "$final_root/distribution-manifest.json" | awk '{print $1}')
printf 'Phase 5 CLI package/notarization passed: artifact=%s byteCount=%s sha256=%s manifestSHA256=%s notarizationStatus=Accepted submissionID=%s\n' \
    "$artifact_name" "$artifact_bytes" "$artifact_sha" "$manifest_sha" "$submission_id"
