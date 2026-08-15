#!/bin/sh
set -eu

fail() {
    printf 'Phase 5 CLI distribution contract failed: %s\n' "$1" >&2
    exit 1
}

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd -P)
temporary_root=$(mktemp -d /private/tmp/arktrace-cli-distribution-contract.XXXXXX)
cleanup() { rm -rf -- "$temporary_root"; }
trap cleanup EXIT HUP INT TERM

require_bounded_tree_rejection() {
    tree=$1
    label=$2
    diagnostic="$temporary_root/rejection-$label.log"
    if python3 -B "$script_directory/verify_phase5_cli_distribution.py" \
        tree-sha "$tree" >/dev/null 2>"$diagnostic"
    then
        fail "$label tree was accepted"
    fi
    grep -Fx 'Phase 5 CLI distribution verification failed' "$diagnostic" >/dev/null \
        && ! grep -F "$temporary_root" "$diagnostic" >/dev/null 2>&1 \
        || fail "$label tree rejection was not bounded and path-free"
}

require_snapshot_tree_rejection() {
    tree=$1
    label=$2
    destination="$temporary_root/snapshot-rejected-$label"
    diagnostic="$temporary_root/snapshot-rejection-$label.log"
    if python3 -B "$script_directory/verify_phase5_cli_distribution.py" \
        snapshot-tree "$tree" "$destination" >/dev/null 2>"$diagnostic"
    then
        fail "$label tree snapshot was accepted"
    fi
    [ ! -e "$destination" ] && [ ! -L "$destination" ] \
        && grep -Fx 'Phase 5 CLI distribution verification failed' "$diagnostic" >/dev/null \
        && ! grep -F "$temporary_root" "$diagnostic" >/dev/null 2>&1 \
        || fail "$label tree snapshot rejection was not bounded and path-free"
}

root="$temporary_root/ArkTraceCLI-0.1.0"
app="$root/ArkTraceCLI.app"
resource="$app/Contents/Resources/ArkTraceCLIResources"
mkdir -p \
    "$app/Contents/MacOS" \
    "$app/Contents/Helpers" \
    "$app/Contents/_CodeSignature" \
    "$app/Contents/Resources/TraceStreamer" \
    "$resource" \
    "$app/Contents/Resources/Attribution"
printf 'synthetic arktrace\n' >"$app/Contents/MacOS/arktrace"
printf 'synthetic trace streamer\n' >"$app/Contents/Helpers/trace_streamer"
printf 'synthetic code resources\n' >"$app/Contents/_CodeSignature/CodeResources"
chmod 755 "$app/Contents/MacOS/arktrace" "$app/Contents/Helpers/trace_streamer"
/usr/bin/ditto --noqtn "$repository_root/LICENSE" "$root/LICENSE"
/usr/bin/ditto --noqtn "$repository_root/THIRD_PARTY_NOTICES.md" \
    "$root/THIRD_PARTY_NOTICES.md"
/usr/bin/ditto --noqtn "$repository_root/LICENSE" "$resource/LICENSE"
/usr/bin/ditto --noqtn "$repository_root/THIRD_PARTY_NOTICES.md" \
    "$resource/THIRD_PARTY_NOTICES.md"
/usr/bin/ditto --noqtn "$repository_root/ThirdParty/TraceStreamer/license-inventory.json" \
    "$resource/license-inventory.json"
/usr/bin/ditto --noqtn "$repository_root/ThirdParty/TraceStreamer/LICENSES" \
    "$resource/LICENSES"
/usr/bin/ditto --noqtn "$repository_root/Fixtures/traces/zlib.htrace" \
    "$resource/zlib.htrace"
/usr/bin/ditto --noqtn "$repository_root/LICENSE" \
    "$app/Contents/Resources/Attribution/LICENSE"
/usr/bin/ditto --noqtn "$repository_root/THIRD_PARTY_NOTICES.md" \
    "$app/Contents/Resources/Attribution/THIRD_PARTY_NOTICES.md"
/usr/bin/ditto --noqtn "$repository_root/ThirdParty/TraceStreamer/license-inventory.json" \
    "$app/Contents/Resources/Attribution/license-inventory.json"
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
plutil -insert LSMinimumSystemVersion -string 14.0 "$info"
plutil -insert LSBackgroundOnly -bool true "$info"
plutil -insert NSHighResolutionCapable -bool true "$info"
chmod 644 "$info"

tool_sha=$(shasum -a 256 "$app/Contents/MacOS/arktrace" | awk '{print $1}')
tool_bytes=$(stat -f '%z' "$app/Contents/MacOS/arktrace")
parser_sha=$(shasum -a 256 "$app/Contents/Helpers/trace_streamer" | awk '{print $1}')
parser_bytes=$(stat -f '%z' "$app/Contents/Helpers/trace_streamer")
jq -n --arg parser "$parser_sha" '
  {
    name: "trace_streamer",
    upstreamRepository: "https://example.invalid/trace_streamer.git",
    upstreamRevision: ("1" * 40),
    reportedVersion: "4.3.7",
    binarySHA256: $parser,
    architecture: "arm64",
    adapterVersion: "1",
    buildRecipeVersion: ("2" * 64),
    plugins: "htrace",
    localPatches: [],
    thirdPartySources: "locked",
    thirdPartyRevisions: {},
    hostToolchain: "test",
    builtAt: "2026-08-14T00:00:00Z"
  }
' >"$app/Contents/Resources/TraceStreamer/manifest.json"
parser_signing="$app/Contents/Resources/TraceStreamer/distribution-signing.json"
jq -n --arg parser "$parser_sha" '
  {
    formatVersion: 1,
    unsignedBinarySHA256: ("3" * 64),
    signedBinarySHA256: $parser,
    buildRecipeVersion: ("2" * 64),
    teamIdentifier: "8AQTYW5FKR",
    signingIdentity: "Developer ID Application: Contract Fixture (8AQTYW5FKR)",
    signingCertificateSHA1: ("A" * 40),
    signingPolicy: "developer-id-runtime-timestamp"
  }
' >"$parser_signing"
chmod 644 "$app/Contents/Resources/TraceStreamer/manifest.json" "$parser_signing"
parser_manifest_sha=$(shasum -a 256 \
    "$app/Contents/Resources/TraceStreamer/manifest.json" | awk '{print $1}')
parser_manifest_bytes=$(stat -f '%z' \
    "$app/Contents/Resources/TraceStreamer/manifest.json")
parser_signing_sha=$(shasum -a 256 "$parser_signing" | awk '{print $1}')
parser_signing_bytes=$(stat -f '%z' "$parser_signing")

python3 -B "$script_directory/verify_phase5_cli_distribution.py" \
    verify-app pre-notary "$app" >/dev/null \
    || fail "valid pre-notary App was rejected"
private_app_snapshot="$temporary_root/private-app-snapshot.app"
python3 -B "$script_directory/verify_phase5_cli_distribution.py" \
    snapshot-tree "$app" "$private_app_snapshot" \
    || fail "valid App bounded snapshot was rejected"
python3 -B "$script_directory/verify_phase5_cli_distribution.py" \
    verify-app pre-notary "$private_app_snapshot" >/dev/null \
    || fail "bounded App snapshot drifted"
[ "$(python3 -B "$script_directory/verify_phase5_cli_distribution.py" tree-sha "$app")" = \
    "$(python3 -B "$script_directory/verify_phase5_cli_distribution.py" \
        tree-sha "$private_app_snapshot")" ] \
    || fail "bounded App snapshot identity drifted"
printf 'synthetic stapled ticket\n' >"$app/Contents/CodeResources"
chmod 600 "$app/Contents/CodeResources"
if python3 -B "$script_directory/verify_phase5_cli_distribution.py" \
    verify-app pre-notary "$app" >/dev/null 2>&1
then
    fail "pre-notary App accepted a stapled ticket"
fi
python3 -B "$script_directory/verify_phase5_cli_distribution.py" \
    verify-app post-staple "$app" >/dev/null \
    || fail "valid post-staple App was rejected"

jq -n '{formatVersion: 1, id: "00000000-0000-0000-0000-000000000000", status: "Accepted", message: "Processing complete"}' \
    >"$root/notarization-receipt.json"
receipt_sha=$(shasum -a 256 "$root/notarization-receipt.json" | awk '{print $1}')
license_sha=$(shasum -a 256 "$root/LICENSE" | awk '{print $1}')
notice_sha=$(shasum -a 256 "$root/THIRD_PARTY_NOTICES.md" | awk '{print $1}')
license_bytes=$(stat -f '%z' "$root/LICENSE")
notice_bytes=$(stat -f '%z' "$root/THIRD_PARTY_NOTICES.md")
inventory_sha=$(shasum -a 256 "$resource/license-inventory.json" | awk '{print $1}')
inventory_bytes=$(stat -f '%z' "$resource/license-inventory.json")
self_test_sha=$(shasum -a 256 "$resource/zlib.htrace" | awk '{print $1}')
self_test_bytes=$(stat -f '%z' "$resource/zlib.htrace")
app_tree=$(python3 -B "$script_directory/verify_phase5_cli_distribution.py" tree-sha "$app")
resource_tree=$(python3 -B "$script_directory/verify_phase5_cli_distribution.py" tree-sha "$resource")

jq -n \
    --arg tool "$tool_sha" --argjson toolBytes "$tool_bytes" \
    --arg parser "$parser_sha" --argjson parserBytes "$parser_bytes" \
    --arg parserManifest "$parser_manifest_sha" \
    --argjson parserManifestBytes "$parser_manifest_bytes" \
    --arg parserSigning "$parser_signing_sha" \
    --argjson parserSigningBytes "$parser_signing_bytes" \
    --arg receipt "$receipt_sha" --arg appTree "$app_tree" \
    --arg resourceTree "$resource_tree" --arg license "$license_sha" \
    --argjson licenseBytes "$license_bytes" \
    --arg notice "$notice_sha" --argjson noticeBytes "$notice_bytes" \
    --arg inventory "$inventory_sha" --argjson inventoryBytes "$inventory_bytes" \
    --arg selfTest "$self_test_sha" --argjson selfTestBytes "$self_test_bytes" '
  {
    formatVersion: 1,
    source: {revision: ("0" * 40), treeSHA256: ("0" * 64)},
    product: {
      name: "arktrace", version: "0.1.0", build: "1", architecture: "arm64",
      bundleIdentifier: "com.arktrace.ArkTrace.CLI", jsonContract: {major: 1, minor: 0}
    },
    layout: {
      bundle: "ArkTraceCLI.app",
      executable: "ArkTraceCLI.app/Contents/MacOS/arktrace",
      parserExecutable: "ArkTraceCLI.app/Contents/Helpers/trace_streamer",
      parserManifest: "ArkTraceCLI.app/Contents/Resources/TraceStreamer/manifest.json",
      parserSigningRecord: "ArkTraceCLI.app/Contents/Resources/TraceStreamer/distribution-signing.json",
      resourceBundle: "ArkTraceCLI.app/Contents/Resources/ArkTraceCLIResources"
    },
    tool: {binarySHA256: $tool, byteCount: $toolBytes, codeDirectoryHash: ("a" * 40)},
    traceStreamer: {
      unsignedBinarySHA256: ("3" * 64),
      binarySHA256: $parser, byteCount: $parserBytes,
      codeDirectoryHash: ("b" * 40),
      manifestSHA256: $parserManifest, manifestByteCount: $parserManifestBytes,
      signingRecordSHA256: $parserSigning,
      signingRecordByteCount: $parserSigningBytes,
      reportedVersion: "4.3.7", upstreamRevision: ("1" * 40),
      buildRecipeVersion: ("2" * 64)
    },
    signing: {
      teamIdentifier: "8AQTYW5FKR",
      identity: "Developer ID Application: Contract Fixture (8AQTYW5FKR)",
      certificateSHA1: ("A" * 40), policy: "developer-id-runtime-timestamp"
    },
    notarization: {
      status: "Accepted", submissionID: "00000000-0000-0000-0000-000000000000",
      receipt: "notarization-receipt.json", receiptSHA256: $receipt,
      stapledTicketValidated: true, gatekeeperAssessment: "accepted"
    },
    integrity: {
      appTreeSHA256: $appTree, resourceTreeSHA256: $resourceTree,
      appCodeDirectoryHash: ("c" * 40)
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
' >"$root/distribution-manifest.json"

python3 -B "$script_directory/verify_phase5_cli_distribution.py" "$root" >/dev/null \
    || fail "valid closed distribution was rejected"

refresh_tree_identities() {
    refreshed_app=$(python3 -B "$script_directory/verify_phase5_cli_distribution.py" \
        tree-sha "$app")
    refreshed_resources=$(python3 -B "$script_directory/verify_phase5_cli_distribution.py" \
        tree-sha "$resource")
    jq --arg appTree "$refreshed_app" --arg resourceTree "$refreshed_resources" \
        '.integrity.appTreeSHA256 = $appTree | .integrity.resourceTreeSHA256 = $resourceTree' \
        "$root/distribution-manifest.json" >"$temporary_root/refreshed-manifest.json"
    mv "$temporary_root/refreshed-manifest.json" "$root/distribution-manifest.json"
    chmod 644 "$root/distribution-manifest.json"
}

mv "$app/Contents/CodeResources" "$temporary_root/stapled-CodeResources"
refresh_tree_identities
if python3 -B "$script_directory/verify_phase5_cli_distribution.py" "$root" \
    >/dev/null 2>&1
then
    fail "post-staple distribution without its ticket was accepted"
fi
if python3 -B "$script_directory/verify_phase5_cli_distribution.py" \
    verify-app post-staple "$app" >/dev/null 2>&1
then
    fail "post-staple App without its ticket was accepted"
fi
mv "$temporary_root/stapled-CodeResources" "$app/Contents/CodeResources"
chmod 600 "$app/Contents/CodeResources"
refresh_tree_identities
python3 -B "$script_directory/verify_phase5_cli_distribution.py" "$root" >/dev/null \
    || fail "restored stapled distribution was rejected"

printf 'drift\n' >>"$app/Contents/Helpers/trace_streamer"
refresh_tree_identities
if python3 -B "$script_directory/verify_phase5_cli_distribution.py" "$root" \
    >/dev/null 2>&1
then
    fail "parser identity drift was accepted"
fi
printf 'synthetic trace streamer\n' >"$app/Contents/Helpers/trace_streamer"
chmod 755 "$app/Contents/Helpers/trace_streamer"
refresh_tree_identities

mv "$parser_signing" "$temporary_root/distribution-signing.json"
refresh_tree_identities
if python3 -B "$script_directory/verify_phase5_cli_distribution.py" "$root" \
    >/dev/null 2>&1
then
    fail "missing parser signing provenance was accepted"
fi
mv "$temporary_root/distribution-signing.json" "$parser_signing"
refresh_tree_identities

printf 'unreviewed\n' >"$resource/unreviewed.txt"
refresh_tree_identities
if python3 -B "$script_directory/verify_phase5_cli_distribution.py" "$root" \
    >/dev/null 2>&1
then
    fail "unexpected CLI resource was accepted"
fi
rm "$resource/unreviewed.txt"
refresh_tree_identities

chmod 777 "$app/Contents/MacOS/arktrace"
refresh_tree_identities
if python3 -B "$script_directory/verify_phase5_cli_distribution.py" "$root" \
    >/dev/null 2>&1
then
    fail "wrong executable mode was accepted"
fi
chmod 755 "$app/Contents/MacOS/arktrace"
refresh_tree_identities

chmod 600 "$resource/LICENSE"
refresh_tree_identities
if python3 -B "$script_directory/verify_phase5_cli_distribution.py" "$root" \
    >/dev/null 2>&1
then
    fail "wrong resource mode was accepted"
fi
chmod 644 "$resource/LICENSE"
refresh_tree_identities

plutil -replace CFBundleVersion -string 9 "$info"
refresh_tree_identities
if python3 -B "$script_directory/verify_phase5_cli_distribution.py" "$root" \
    >/dev/null 2>&1
then
    fail "wrong Info.plist identity was accepted"
fi
plutil -replace CFBundleVersion -string 1 "$info"
refresh_tree_identities
python3 -B "$script_directory/verify_phase5_cli_distribution.py" "$root" >/dev/null \
    || fail "restored closed distribution was rejected"

printf 'unexpected\n' >"$root/unreviewed.txt"
if python3 -B "$script_directory/verify_phase5_cli_distribution.py" "$root" \
    >/dev/null 2>&1
then
    fail "unexpected top-level bytes were accepted"
fi
rm "$root/unreviewed.txt"

linked="$temporary_root/linked-distribution"
ln -s "$root" "$linked"
if python3 -B "$script_directory/verify_phase5_cli_distribution.py" "$linked" \
    >/dev/null 2>&1
then
    fail "symlink distribution root was accepted"
fi

fanout="$temporary_root/fanout"
mkdir "$fanout"
fanout_index=0
while [ "$fanout_index" -lt 513 ]; do
    mkdir "$fanout/entry-$fanout_index"
    fanout_index=$((fanout_index + 1))
done
require_bounded_tree_rejection "$fanout" fanout
require_snapshot_tree_rejection "$fanout" fanout

deep="$temporary_root/deep"
mkdir "$deep"
deep_cursor=$deep
deep_index=0
while [ "$deep_index" -lt 34 ]; do
    deep_cursor="$deep_cursor/d"
    mkdir "$deep_cursor"
    deep_index=$((deep_index + 1))
done
require_bounded_tree_rejection "$deep" depth

python3 -B -c '
import importlib.util,sys
spec=importlib.util.spec_from_file_location("phase5_verifier",sys.argv[1])
module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
try:
    module.encoded_name("invalid-\udcff","distribution entry name")
except module.VerificationError:
    raise SystemExit(0)
raise SystemExit(1)
' "$script_directory/verify_phase5_cli_distribution.py" \
    || fail "invalid UTF-8 distribution name was accepted"

oversized="$temporary_root/oversized"
mkdir "$oversized"
python3 -B -c 'import os,sys; descriptor=os.open(sys.argv[1],os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600); os.ftruncate(descriptor,134217729); os.close(descriptor)' \
    "$oversized/too-large"
require_bounded_tree_rejection "$oversized" oversized-leaf
require_snapshot_tree_rejection "$oversized" oversized-leaf

snapshot_source="$temporary_root/snapshot-source.json"
snapshot_copy="$temporary_root/snapshot-copy.json"
printf '{"formatVersion":1,"value":"reviewed"}\n' >"$snapshot_source"
chmod 600 "$snapshot_source"
python3 -B "$script_directory/verify_phase5_cli_distribution.py" \
    snapshot-json "$snapshot_source" "$snapshot_copy" \
    || fail "bounded JSON snapshot was rejected"
cmp "$snapshot_source" "$snapshot_copy" >/dev/null 2>&1 \
    || fail "bounded JSON snapshot bytes drifted"
printf '{"formatVersion":1,"value":"changed"}\n' >"$snapshot_source"
grep -F '"reviewed"' "$snapshot_copy" >/dev/null \
    || fail "private JSON snapshot followed later caller mutation"
if python3 -B "$script_directory/verify_phase5_cli_distribution.py" \
    snapshot-json "$snapshot_source" "$snapshot_copy" >/dev/null 2>&1
then
    fail "JSON snapshot destination collision was accepted"
fi

. "$script_directory/phase5_publish.sh"
publish_partial="$temporary_root/publish-partial.zip"
publish_final="$temporary_root/publish-final.zip"
printf 'new artifact\n' >"$publish_partial"
printf 'old artifact\n' >"$publish_final"
publish_sha=$(shasum -a 256 "$publish_partial" | awk '{print $1}')
publish_bytes=$(stat -f '%z' "$publish_partial")
if arktrace_phase5_publish_file \
    "$publish_partial" "$publish_final" "$publish_sha" "$publish_bytes"
then
    fail "pre-existing artifact publication collision was accepted"
fi
grep -Fx 'old artifact' "$publish_final" >/dev/null \
    && grep -Fx 'new artifact' "$publish_partial" >/dev/null \
    || fail "artifact publication collision mutated bytes"

pair_staging="$temporary_root/pair-staging"
mkdir "$pair_staging"
pair_partial="$pair_staging/pair-partial.app"
pair_final="$temporary_root/pair-final.app"
pair_record_partial="$pair_staging/pair-partial.json"
pair_record_final="$temporary_root/pair-final.json"
mkdir "$pair_partial"
printf 'candidate bytes\n' >"$pair_partial/file"
printf '{"new":true}\n' >"$pair_record_partial"
printf '{"old":true}\n' >"$pair_record_final"
pair_tree=$(python3 -B "$script_directory/verify_phase5_cli_distribution.py" \
    tree-sha "$pair_partial")
pair_record_sha=$(shasum -a 256 "$pair_record_partial" | awk '{print $1}')
pair_record_bytes=$(stat -f '%z' "$pair_record_partial")
if arktrace_phase5_publish_candidate_pair \
    "$pair_partial" "$pair_final" "$pair_tree" \
    "$pair_record_partial" "$pair_record_final" \
    "$pair_record_sha" "$pair_record_bytes" \
    "$script_directory/verify_phase5_cli_distribution.py"
then
    fail "candidate-record publication collision was accepted"
fi
[ -d "$pair_partial" ] && [ ! -e "$pair_final" ] \
    && grep -F '"old":true' "$pair_record_final" >/dev/null \
    && grep -F '"new":true' "$pair_record_partial" >/dev/null \
    || fail "cross-directory candidate publication did not roll back after record collision"

sh -n "$script_directory/build_phase5_cli_distribution_candidate.sh"
sh -n "$script_directory/package_phase5_cli_distribution.sh"
sh -n "$script_directory/phase5_publish.sh"
python3 -B "$script_directory/test_phase5_publish_race.py" >/dev/null \
    || fail "publication replacement race contract failed"
grep -F 'snapshot-tree "$candidate" "$app"' \
    "$script_directory/package_phase5_cli_distribution.sh" >/dev/null \
    || fail "package does not use a descriptor-bound App snapshot"
if grep -F 'ditto --noqtn "$candidate" "$app"' \
    "$script_directory/package_phase5_cli_distribution.sh" >/dev/null
then
    fail "package still copies the caller App by external path"
fi
grep -F 'mktemp -d "$candidate_directory/.publication.XXXXXX"' \
    "$script_directory/build_phase5_cli_distribution_candidate.sh" >/dev/null \
    && grep -F 'partial_candidate="$publication_staging/' \
        "$script_directory/build_phase5_cli_distribution_candidate.sh" >/dev/null \
    && grep -F 'partial_record="$publication_staging/' \
        "$script_directory/build_phase5_cli_distribution_candidate.sh" >/dev/null \
    || fail "candidate partials are not staged on the output filesystem"
grep -F 'mktemp -d "$artifact_directory/.publication.XXXXXX"' \
    "$script_directory/package_phase5_cli_distribution.sh" >/dev/null \
    && grep -F 'partial_zip="$publication_staging/' \
        "$script_directory/package_phase5_cli_distribution.sh" >/dev/null \
    || fail "artifact partial is not staged on the output filesystem"
if grep -F 'Apps/ArkTraceApp/ArkTraceApp.entitlements' \
    "$script_directory/build_phase5_cli_distribution_candidate.sh" >/dev/null
then
    fail "candidate signing still injects an empty entitlement blob"
fi
grep -F 'invalid entitlements blob' \
    "$script_directory/build_phase5_cli_distribution_candidate.sh" >/dev/null \
    || fail "candidate does not reject an invalid entitlement blob"
grep -F 'invalid entitlements blob' \
    "$script_directory/package_phase5_cli_distribution.sh" >/dev/null \
    || fail "package does not reject an invalid entitlement blob"
grep -F 'installed CLI machine licenses contract is invalid' \
    "$script_directory/build_phase5_cli_distribution_candidate.sh" >/dev/null \
    || fail "candidate does not smoke the installed licenses contract"
grep -F 'CLI candidate pre-notary closure is invalid' \
    "$script_directory/build_phase5_cli_distribution_candidate.sh" >/dev/null \
    && grep -F 'CLI candidate publication snapshot drifted' \
        "$script_directory/build_phase5_cli_distribution_candidate.sh" >/dev/null \
    || fail "candidate does not verify both pre-notary App closures"
grep -F 'installed CLI machine licenses contract is invalid' \
    "$script_directory/package_phase5_cli_distribution.sh" >/dev/null \
    || fail "package does not smoke the installed licenses contract"
git -C "$repository_root" diff --check -- \
    scripts/verify_phase5_cli_distribution.py \
    scripts/build_phase5_cli_distribution_candidate.sh \
    scripts/package_phase5_cli_distribution.sh \
    scripts/phase5_publish.sh \
    scripts/test_phase5_publish_race.py \
    scripts/test_phase5_cli_distribution_contract.sh

printf 'Phase 5 CLI distribution contract passed\n'
