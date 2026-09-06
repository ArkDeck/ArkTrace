#!/bin/sh
set -eu

fail() {
    printf 'Phase 5 CLI candidate build failed: %s\n' "$1" >&2
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
candidate_directory=${ARKTRACE_PHASE5_CLI_CANDIDATE_DIR:-$repository_root/.build/phase5-cli-candidates}
[ -n "$identity" ] && [ -n "$team" ] \
    || fail "Developer ID identity and team are required"

arktrace_validate_reviewed_roots "$repository_root"
arktrace_validate_owned_directory_request "$candidate_directory" "CLI candidate output"
arktrace_create_reviewed_build_root
candidate_directory=$(arktrace_secure_owned_directory \
    "$candidate_directory" .arktrace-phase5-cli-candidates-v1 "CLI candidate output")
umask 077
publication_staging=$(mktemp -d "$candidate_directory/.publication.XXXXXX") \
    || fail "CLI candidate publication staging could not be created"
chmod 700 "$publication_staging"

temporary_root=
cleanup() {
    rm -rf -- "$publication_staging"
    if [ -n "$temporary_root" ]; then rm -rf -- "$temporary_root"; fi
}
trap cleanup EXIT HUP INT TERM
temporary_root=$(mktemp -d "$ARKTRACE_REVIEWED_TEMP_ROOT/arktrace-cli-candidate.XXXXXX") \
    || fail "CLI candidate private work root could not be created"
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

source_revision=$(git -C "$repository_root" rev-parse HEAD)
source_tree_sha=$(python3 -B "$script_directory/source_tree_identity.py" "$repository_root") \
    || fail "source tree identity is unavailable"
build_root="$temporary_root/build"
run_external "production arktrace build failed" \
    swift build --package-path "$repository_root" --scratch-path "$build_root" \
        -c release --product arktrace
bin_path=$(swift build --package-path "$repository_root" --scratch-path "$build_root" \
    -c release --show-bin-path 2>/dev/null) \
    || fail "production build output path is unavailable"
unsigned_tool="$bin_path/arktrace"
[ -f "$unsigned_tool" ] && [ ! -L "$unsigned_tool" ] \
    || fail "production CLI build is incomplete"
file "$unsigned_tool" | grep -F 'Mach-O 64-bit executable arm64' >/dev/null \
    || fail "production CLI is not an arm64 Mach-O executable"
# A raw SwiftPM product is deliberately a developer core binary, not an
# installed CLI. The isolated scratch build must not discover stale resources
# from another build or the source checkout.
raw_license_output="$temporary_root/raw-swiftpm-licenses.json"
raw_license_error="$temporary_root/raw-swiftpm-licenses.log"
if "$unsigned_tool" --json licenses >"$raw_license_output" 2>"$raw_license_error"; then
    fail "raw SwiftPM CLI unexpectedly resolved installed resources"
fi
jq -e '
    .schemaVersion == "1.0"
    and .request.command == "licenses"
    and .error.code == "INTERNAL_ERROR"
    and .error.stage == "preparing"
    and .error.retryable == false
    and .error.details == {}
' "$raw_license_output" >/dev/null \
    || fail "raw SwiftPM CLI resource failure is not typed"

# Even a byte-exact legacy SwiftPM bundle beside the raw product must not turn
# that developer-core executable into an accidental installation.
legacy_bundle="$bin_path/ArkTrace_ArkTraceCLI.bundle"
mkdir "$legacy_bundle"
run_external "legacy SwiftPM product license copy failed" \
    /usr/bin/ditto --noqtn "$repository_root/LICENSE" "$legacy_bundle/LICENSE"
run_external "legacy SwiftPM notice copy failed" \
    /usr/bin/ditto --noqtn "$repository_root/THIRD_PARTY_NOTICES.md" \
        "$legacy_bundle/THIRD_PARTY_NOTICES.md"
run_external "legacy SwiftPM inventory copy failed" \
    /usr/bin/ditto --noqtn \
        "$repository_root/ThirdParty/TraceStreamer/license-inventory.json" \
        "$legacy_bundle/license-inventory.json"
run_external "legacy SwiftPM license files copy failed" \
    /usr/bin/ditto --noqtn "$repository_root/ThirdParty/TraceStreamer/LICENSES" \
        "$legacy_bundle/LICENSES"
run_external "legacy SwiftPM self-test fixture copy failed" \
    /usr/bin/ditto --noqtn "$repository_root/Fixtures/traces/zlib.htrace" \
        "$legacy_bundle/zlib.htrace"
# Also plant the old sibling share shape next to the scratch Release directory.
# Only a reviewed <prefix>/bin/arktrace installation may resolve that layout.
legacy_share="$(dirname "$bin_path")/share/arktrace"
mkdir -p "$legacy_share"
run_external "legacy SwiftPM share copy failed" \
    /usr/bin/ditto --noqtn "$legacy_bundle/" "$legacy_share/"
if "$unsigned_tool" --json licenses >"$raw_license_output" 2>"$raw_license_error"; then
    fail "raw SwiftPM CLI consumed stale legacy resources"
fi
jq -e '
    .schemaVersion == "1.0"
    and .request.command == "licenses"
    and .error.code == "INTERNAL_ERROR"
    and .error.stage == "preparing"
    and .error.retryable == false
    and .error.details == {}
' "$raw_license_output" >/dev/null \
    || fail "raw SwiftPM stale-resource rejection is not typed"
signed_tool_input="$temporary_root/arktrace-signed"
run_external "production CLI signing copy failed" \
    /usr/bin/ditto --noqtn "$unsigned_tool" "$signed_tool_input"
run_external "arktrace executable signing failed" \
    codesign --force --sign "$certificate_sha1" --options runtime --timestamp \
        "$signed_tool_input"

app="$temporary_root/ArkTraceCLI.app"
mkdir -p \
    "$app/Contents/MacOS" \
    "$app/Contents/Helpers" \
    "$app/Contents/Resources/TraceStreamer" \
    "$app/Contents/Resources/Attribution/LICENSES" \
    "$app/Contents/Resources/ArkTraceCLIResources"
run_external "production CLI copy failed" \
    /usr/bin/ditto --noqtn "$signed_tool_input" "$app/Contents/MacOS/arktrace"
cli_resources="$app/Contents/Resources/ArkTraceCLIResources"
run_external "CLI self-test fixture copy failed" \
    /usr/bin/ditto --noqtn "$repository_root/Fixtures/traces/zlib.htrace" \
        "$cli_resources/zlib.htrace"
run_external "CLI product license copy failed" \
    /usr/bin/ditto --noqtn "$repository_root/LICENSE" "$cli_resources/LICENSE"
run_external "CLI notice copy failed" \
    /usr/bin/ditto --noqtn "$repository_root/THIRD_PARTY_NOTICES.md" \
        "$cli_resources/THIRD_PARTY_NOTICES.md"
run_external "CLI license inventory copy failed" \
    /usr/bin/ditto --noqtn \
        "$repository_root/ThirdParty/TraceStreamer/license-inventory.json" \
        "$cli_resources/license-inventory.json"
run_external "CLI license files copy failed" \
    /usr/bin/ditto --noqtn "$repository_root/ThirdParty/TraceStreamer/LICENSES" \
        "$cli_resources/LICENSES"
run_external "TraceStreamer copy failed" \
    /usr/bin/ditto --noqtn "$repository_root/ThirdParty/TraceStreamer/macx/trace_streamer" \
        "$app/Contents/Helpers/trace_streamer"
run_external "TraceStreamer manifest copy failed" \
    /usr/bin/ditto --noqtn "$repository_root/ThirdParty/TraceStreamer/macx/manifest.json" \
        "$app/Contents/Resources/TraceStreamer/manifest.json"
run_external "license copy failed" \
    /usr/bin/ditto --noqtn "$repository_root/LICENSE" \
        "$app/Contents/Resources/Attribution/LICENSE"
run_external "notice copy failed" \
    /usr/bin/ditto --noqtn "$repository_root/THIRD_PARTY_NOTICES.md" \
        "$app/Contents/Resources/Attribution/THIRD_PARTY_NOTICES.md"
run_external "license inventory copy failed" \
    /usr/bin/ditto --noqtn "$repository_root/ThirdParty/TraceStreamer/license-inventory.json" \
        "$app/Contents/Resources/Attribution/license-inventory.json"
run_external "third-party licenses copy failed" \
    /usr/bin/ditto --noqtn "$repository_root/ThirdParty/TraceStreamer/LICENSES" \
        "$app/Contents/Resources/Attribution/LICENSES"

info="$app/Contents/Info.plist"
plutil -create xml1 "$info"
plutil -insert CFBundleExecutable -string arktrace "$info"
plutil -insert CFBundleIdentifier -string com.arktrace.ArkTrace.CLI "$info"
plutil -insert CFBundleName -string ArkTraceCLI "$info"
plutil -insert CFBundleDisplayName -string ArkTraceCLI "$info"
plutil -insert CFBundlePackageType -string APPL "$info"
plutil -insert CFBundleShortVersionString -string 0.1.0 "$info"
plutil -insert CFBundleVersion -string 1 "$info"
plutil -insert LSMinimumSystemVersion -string 26.0 "$info"
plutil -insert LSBackgroundOnly -bool true "$info"
plutil -insert NSHighResolutionCapable -bool true "$info"
chmod 644 "$info"

helper="$app/Contents/Helpers/trace_streamer"
parser_manifest="$app/Contents/Resources/TraceStreamer/manifest.json"
tool="$app/Contents/MacOS/arktrace"
chmod 755 "$helper" "$tool"
run_external "nested TraceStreamer signing failed" \
    codesign --force --sign "$certificate_sha1" --options runtime --timestamp "$helper"
signed_parser_sha=$(shasum -a 256 "$helper" | awk '{print $1}')
unsigned_parser_sha=$(jq -er '.binarySHA256' \
    "$repository_root/ThirdParty/TraceStreamer/macx/manifest.json")
jq --arg sha "$signed_parser_sha" '.binarySHA256 = $sha' "$parser_manifest" \
    >"$temporary_root/parser-manifest.json" \
    || fail "signed parser manifest update failed"
mv "$temporary_root/parser-manifest.json" "$parser_manifest"
chmod 644 "$parser_manifest"

parser_signing_record="$app/Contents/Resources/TraceStreamer/distribution-signing.json"
jq -n \
    --arg unsigned "$unsigned_parser_sha" \
    --arg signed "$signed_parser_sha" \
    --arg recipe "$(jq -er '.buildRecipeVersion' "$parser_manifest")" \
    --arg team "$team" \
    --arg identity "$identity" \
    --arg certificate "$certificate_sha1" '
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
' >"$parser_signing_record" \
    || fail "parser signing record could not be created"
chmod 644 "$parser_signing_record"

umask 022
run_external "outer CLI bundle signing failed" \
    codesign --force --sign "$certificate_sha1" --options runtime --timestamp "$app"
umask 077
run_external "CLI candidate signatures are invalid" \
    codesign --verify --deep --strict --verbose=2 "$app"
require_signature "$helper" helper
require_signature "$tool" tool
require_signature "$app" app
require_no_entitlements "$helper" helper
require_no_entitlements "$tool" tool
require_no_entitlements "$app" app
python3 -B "$script_directory/verify_phase5_cli_distribution.py" \
    verify-app pre-notary "$app" >/dev/null \
    || fail "CLI candidate pre-notary closure is invalid"

tool_sha=$(shasum -a 256 "$tool" | awk '{print $1}')
tool_bytes=$(stat -f '%z' "$tool")
parser_bytes=$(stat -f '%z' "$helper")
parser_manifest_sha=$(shasum -a 256 "$parser_manifest" | awk '{print $1}')
parser_manifest_bytes=$(stat -f '%z' "$parser_manifest")
parser_signing_sha=$(shasum -a 256 "$parser_signing_record" | awk '{print $1}')
parser_signing_bytes=$(stat -f '%z' "$parser_signing_record")
tool_cdhash=$(codesign -dv --verbose=4 "$tool" 2>&1 \
    | sed -n 's/^CDHash=//p' | head -1)
parser_cdhash=$(codesign -dv --verbose=4 "$helper" 2>&1 \
    | sed -n 's/^CDHash=//p' | head -1)
app_cdhash=$(codesign -dv --verbose=4 "$app" 2>&1 \
    | sed -n 's/^CDHash=//p' | head -1)
[ "$(jq -er '.binarySHA256' "$parser_manifest")" = "$signed_parser_sha" ] \
    || fail "signed parser manifest identity is open"

cmp "$repository_root/LICENSE" "$app/Contents/Resources/Attribution/LICENSE" \
    >/dev/null 2>&1 || fail "candidate MIT license drifted"
cmp "$repository_root/THIRD_PARTY_NOTICES.md" \
    "$app/Contents/Resources/Attribution/THIRD_PARTY_NOTICES.md" \
    >/dev/null 2>&1 || fail "candidate third-party notice drifted"
cmp "$repository_root/ThirdParty/TraceStreamer/license-inventory.json" \
    "$app/Contents/Resources/Attribution/license-inventory.json" \
    >/dev/null 2>&1 || fail "candidate license inventory drifted"
diff -qr "$repository_root/ThirdParty/TraceStreamer/LICENSES" \
    "$app/Contents/Resources/Attribution/LICENSES" >/dev/null 2>&1 \
    || fail "candidate license files drifted"

# Remove the exact SwiftPM scratch location before the product smoke. The
# production executable has no SwiftPM resource target dependency; the smoke
# additionally proves the executable-relative App layout is sufficient.
mv "$build_root" "$temporary_root/build-retired"
smoke_home="$temporary_root/smoke-home"
mkdir -p "$smoke_home/Library/Caches"
doctor="$temporary_root/doctor.json"
if ! CFFIXED_USER_HOME="$smoke_home" HOME="$smoke_home" \
    "$tool" doctor --self-test --json --no-cache --timeout-ms 120000 \
    >"$doctor" 2>"$temporary_root/doctor.log"
then
    arktrace_bounded_failure_summary "$temporary_root/doctor.log"
    fail "installed CLI doctor self-test failed"
fi
jq -e --arg tool "$tool_sha" '
    .schemaVersion == "1.0"
    and .tool.name == "arktrace"
    and .tool.version == "0.1.0"
    and .tool.buildRevision == $tool
    and .request.command == "doctor"
    and .result.selfTest == true
    and ([.result.checks[].status] | all(. == "ok"))
' "$doctor" >/dev/null \
    || fail "installed CLI doctor contract is invalid"
require_licenses_contract "$tool" "$smoke_home" candidate
if strings "$tool" | grep -F "$repository_root" >/dev/null 2>&1; then
    fail "production CLI embeds the repository path"
fi

candidate_name="ArkTraceCLI-review-candidate-$(date -u +%Y%m%dT%H%M%SZ).app"
candidate="$candidate_directory/$candidate_name"
record="$candidate_directory/$candidate_name.json"
arktrace_require_absent_leaf "$candidate" "CLI candidate"
arktrace_require_absent_leaf "$record" "CLI candidate record"
partial_candidate="$publication_staging/$candidate_name.partial.app"
partial_record="$publication_staging/$candidate_name.partial.json"
python3 -B "$script_directory/verify_phase5_cli_distribution.py" \
    snapshot-tree "$app" "$partial_candidate" \
    || fail "CLI candidate bounded copy failed"
python3 -B "$script_directory/verify_phase5_cli_distribution.py" \
    verify-app pre-notary "$partial_candidate" >/dev/null \
    || fail "CLI candidate publication snapshot drifted"
run_external "CLI candidate copy signature verification failed" \
    codesign --verify --deep --strict --verbose=2 "$partial_candidate"

app_tree_sha=$(python3 -B "$script_directory/verify_phase5_cli_distribution.py" \
    tree-sha "$partial_candidate") || fail "CLI candidate tree identity is unavailable"
resource_tree_sha=$(python3 -B "$script_directory/verify_phase5_cli_distribution.py" \
    tree-sha "$partial_candidate/Contents/Resources/ArkTraceCLIResources") \
    || fail "CLI resource tree identity is unavailable"
record_staging="$temporary_root/candidate-record.json"
jq -n \
    --arg app "$candidate_name" \
    --arg revision "$source_revision" \
    --arg tree "$source_tree_sha" \
    --arg appTree "$app_tree_sha" \
    --arg resourceTree "$resource_tree_sha" \
    --arg tool "$tool_sha" \
    --argjson toolBytes "$tool_bytes" \
    --arg toolCDHash "$tool_cdhash" \
    --arg appCDHash "$app_cdhash" \
    --arg parser "$signed_parser_sha" \
    --arg unsignedParser "$unsigned_parser_sha" \
    --argjson parserBytes "$parser_bytes" \
    --arg parserCDHash "$parser_cdhash" \
    --arg parserManifest "$parser_manifest_sha" \
    --argjson parserManifestBytes "$parser_manifest_bytes" \
    --arg parserSigning "$parser_signing_sha" \
    --argjson parserSigningBytes "$parser_signing_bytes" \
    --arg parserVersion "$(jq -er '.reportedVersion' "$parser_manifest")" \
    --arg parserRevision "$(jq -er '.upstreamRevision' "$parser_manifest")" \
    --arg recipe "$(jq -er '.buildRecipeVersion' "$parser_manifest")" \
    --arg team "$team" \
    --arg identity "$identity" \
    --arg certificate "$certificate_sha1" '
    {
      formatVersion: 1,
      app: $app,
      source: {revision: $revision, treeSHA256: $tree},
      product: {
        name: "arktrace", version: "0.1.0", build: "1",
        architecture: "arm64", bundleIdentifier: "com.arktrace.ArkTrace.CLI",
        jsonContract: {major: 1, minor: 0}
      },
      appTreeSHA256: $appTree,
      resourceTreeSHA256: $resourceTree,
      appCodeDirectoryHash: $appCDHash,
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
      }
    }
' >"$record_staging" || fail "CLI candidate record could not be created"
chmod 600 "$record_staging"
python3 -B "$script_directory/verify_phase5_cli_distribution.py" \
    snapshot-json "$record_staging" "$partial_record" \
    || fail "CLI candidate record publication snapshot failed"

expected_record_sha=$(shasum -a 256 "$partial_record" | awk '{print $1}')
expected_record_bytes=$(stat -f '%z' "$partial_record")
arktrace_phase5_publish_candidate_pair \
    "$partial_candidate" "$candidate" "$app_tree_sha" \
    "$partial_record" "$record" "$expected_record_sha" "$expected_record_bytes" \
    "$script_directory/verify_phase5_cli_distribution.py" \
    || fail "CLI candidate publication collided"
[ -d "$candidate" ] && [ -f "$record" ] \
    || fail "CLI candidate publication did not complete"
printf 'Phase 5 signed CLI candidate ready: candidate=%s record=%s treeSHA256=%s toolSHA256=%s parserSHA256=%s\n' \
    "$candidate_name" "$(basename "$record")" "$app_tree_sha" "$tool_sha" "$signed_parser_sha"
