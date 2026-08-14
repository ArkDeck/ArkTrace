#!/bin/sh
set -eu

fail() {
    printf 'Phase 3 distribution contract test failed: %s\n' "$1" >&2
    exit 1
}

source_scripts=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/arktrace-distribution-contract.XXXXXX")
cleanup() { rm -rf -- "$temporary_root"; }
trap cleanup EXIT HUP INT TERM
repository="$temporary_root/repository"
fake_bin="$temporary_root/bin"
operation_log="$temporary_root/operations.log"
identity='Developer ID Application: ArkTrace Test (TEAMTEST)'
team=TEAMTEST

mkdir -p "$repository/scripts" "$repository/ArkTrace.xcodeproj" \
    "$repository/Apps/ArkTraceApp" \
    "$repository/Config" \
    "$repository/ThirdParty/TraceStreamer/macx" \
    "$repository/ThirdParty/TraceStreamer/LICENSES" \
    "$repository/Fixtures/release-evidence" "$fake_bin"
cp "$source_scripts/build_phase3_distribution_candidate.sh" \
    "$source_scripts/package_phase3.sh" \
    "$source_scripts/verify_phase3_evidence_times.py" \
    "$source_scripts/phase3_shell_safety.sh" "$repository/scripts/"
chmod +x "$repository/scripts/"*.sh
PYTHONDONTWRITEBYTECODE=1 python3 -B \
    "$repository/scripts/verify_phase3_evidence_times.py" \
    --timestamp '2026-08-13T00:00:00Z' \
    || fail "canonical accessibility timestamp was rejected"
for timestamp in '2026-99-99T00:00:00Z' '2026-08-13T00:00:00Zsuffix' '2026-08-13T00:00:00+00:00'; do
    if PYTHONDONTWRITEBYTECODE=1 python3 -B \
        "$repository/scripts/verify_phase3_evidence_times.py" \
        --timestamp "$timestamp" >/dev/null 2>&1
    then
        fail "invalid accessibility review timestamp was accepted"
    fi
done
printf 'raw parser bytes\n' >"$repository/ThirdParty/TraceStreamer/macx/trace_streamer"
raw_sha=$(shasum -a 256 \
    "$repository/ThirdParty/TraceStreamer/macx/trace_streamer" | awk '{print $1}')
jq -n --arg sha "$raw_sha" --arg recipe "$(printf recipe | shasum -a 256 | awk '{print $1}')" \
    '{binarySHA256:$sha,buildRecipeVersion:$recipe}' \
    >"$repository/ThirdParty/TraceStreamer/macx/manifest.json"
printf 'MIT License\nfixture\n' >"$repository/LICENSE"
printf 'third-party notice\n' >"$repository/THIRD_PARTY_NOTICES.md"
printf '{}\n' >"$repository/ThirdParty/TraceStreamer/license-inventory.json"
printf 'component license\n' >"$repository/ThirdParty/TraceStreamer/LICENSES/component.txt"
printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>\n' \
    >"$repository/Apps/ArkTraceApp/ArkTraceApp.entitlements"
cat >"$repository/Config/ArkTraceProduct.xcconfig" <<'CONFIG'
ARKTRACE_PRODUCT_VERSION = 0.1.0
ARKTRACE_PRODUCT_BUILD = 1
ARKTRACE_BUNDLE_IDENTIFIER = com.arktrace.ArkTrace
CONFIG

source_app="$temporary_root/source/ArkTrace.app"
mkdir -p "$source_app/Contents/Helpers" \
    "$source_app/Contents/Resources/TraceStreamer" \
    "$source_app/Contents/Resources/Licenses" "$source_app/Contents/MacOS"
cp "$repository/ThirdParty/TraceStreamer/macx/trace_streamer" \
    "$source_app/Contents/Helpers/trace_streamer"
cp "$repository/ThirdParty/TraceStreamer/macx/manifest.json" \
    "$source_app/Contents/Resources/TraceStreamer/manifest.json"
cp "$repository/LICENSE" "$repository/THIRD_PARTY_NOTICES.md" \
    "$repository/ThirdParty/TraceStreamer/license-inventory.json" \
    "$source_app/Contents/Resources/"
cp "$repository/ThirdParty/TraceStreamer/LICENSES/component.txt" \
    "$source_app/Contents/Resources/Licenses/"
printf '#!/bin/sh\nexit 0\n' >"$source_app/Contents/MacOS/ArkTrace"
chmod +x "$source_app/Contents/MacOS/ArkTrace" \
    "$source_app/Contents/Helpers/trace_streamer"
cat >"$source_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.arktrace.ArkTrace</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST

cat >"$fake_bin/security" <<'SH'
#!/bin/sh
printf '  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: ArkTrace Test (TEAMTEST)"\n'
SH
cat >"$fake_bin/xcodebuild" <<'SH'
#!/bin/sh
archive=
printf 'xcodebuild' >>"$ARKTRACE_FAKE_OPERATION_LOG"
for argument in "$@"; do printf ' %s' "$argument" >>"$ARKTRACE_FAKE_OPERATION_LOG"; done
printf '\n' >>"$ARKTRACE_FAKE_OPERATION_LOG"
while [ "$#" -gt 0 ]; do
    if [ "$1" = -archivePath ]; then archive=$2; shift 2; else shift; fi
done
[ -n "$archive" ] || exit 2
mkdir -p "$archive/Products/Applications"
/usr/bin/ditto --noqtn "$ARKTRACE_FAKE_SOURCE_APP" \
    "$archive/Products/Applications/ArkTrace.app"
case "${ARKTRACE_FAKE_ARCHIVE_LICENSE_DRIFT:-}" in
    inventory) printf 'drift\n' >>"$archive/Products/Applications/ArkTrace.app/Contents/Resources/license-inventory.json" ;;
    file) printf 'drift\n' >>"$archive/Products/Applications/ArkTrace.app/Contents/Resources/Licenses/component.txt" ;;
esac
SH
cat >"$fake_bin/codesign" <<'SH'
#!/bin/sh
printf 'codesign' >>"$ARKTRACE_FAKE_OPERATION_LOG"
for argument in "$@"; do
    case "$argument" in
        -*) label=$argument ;;
        *) label=$(basename "$argument") ;;
    esac
    printf ' %s' "$label" >>"$ARKTRACE_FAKE_OPERATION_LOG"
done
printf '\n' >>"$ARKTRACE_FAKE_OPERATION_LOG"
for argument in "$@"; do
    case "$argument" in
        --extract-certificates=*)
            prefix=${argument#--extract-certificates=}
            printf 'fake-certificate\n' >"${prefix}0"
            exit 0
            ;;
        --extract-certificates)
            printf 'certificate prefix must use the audited equals form\n' >&2
            exit 64
            ;;
    esac
done
case " $* " in
    *' --entitlements :- '*)
        printf '<?xml version="1.0"?><plist version="1.0"><dict/></plist>\n'
        exit 0 ;;
esac
case " $* " in
    *' --sign '*' trace_streamer '*)
        for last; do :; done
        printf 'developer-id-signature\n' >>"$last" ;;
esac
case " $* " in
    *' -dv '*|*' -d '*)
        printf 'Authority=Developer ID Application: ArkTrace Test (TEAMTEST)\n' >&2
        printf 'TeamIdentifier=TEAMTEST\nCodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=1+1 location=embedded\nTimestamp=Aug 13, 2026\nCDHash=0123456789abcdef\n' >&2 ;;
esac
if [ "${ARKTRACE_FAKE_FAIL_PARTIAL_VERIFY:-0}" = 1 ]; then
    for argument in "$@"; do
        case "$argument" in *.partial-*|*/.partial-*)
            printf 'verification failed at %s/private/user/path\n' "$argument" >&2
            exit 1 ;;
        esac
    done
fi
exit 0
SH
cat >"$fake_bin/shasum" <<'SH'
#!/bin/sh
for last; do :; done
case "$last" in
    *-certificate-0)
        printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA  %s\n' "$last" ;;
    *) exec /usr/bin/shasum "$@" ;;
esac
SH
cat >"$fake_bin/xcrun" <<'SH'
#!/bin/sh
printf 'xcrun %s %s\n' "$1" "$2" >>"$ARKTRACE_FAKE_OPERATION_LOG"
if [ "$1" = notarytool ] && [ "$2" = submit ]; then
    if [ "${ARKTRACE_FAKE_NOTARY_INVALID:-0}" = 1 ]; then
        printf '{"id":"11111111-1111-1111-1111-111111111111","status":"Invalid"}\n'
    else
        printf '{"id":"11111111-1111-1111-1111-111111111111","status":"Accepted"}\n'
    fi
elif [ "$1" = stapler ] && [ "$2" = staple ]; then
    mkdir -p "$3/Contents/_CodeSignature"
    printf 'stapled\n' >"$3/Contents/_CodeSignature/arktrace-test-ticket"
elif [ "$1" = stapler ] && [ "$2" = validate ]; then
    if [ "${ARKTRACE_FAKE_FAIL_FINAL_VALIDATE:-0}" = 1 ]; then
        case "$3" in */final/*)
            printf 'invalid ticket at %s/private/user/path with a deliberately long diagnostic %0600d\n' "$3" 1 >&2
            exit 1 ;;
        esac
    fi
    [ -f "$3/Contents/_CodeSignature/arktrace-test-ticket" ] || exit 1
fi
exit 0
SH
cat >"$fake_bin/spctl" <<'SH'
#!/bin/sh
for last; do :; done
[ -f "$last/Contents/_CodeSignature/arktrace-test-ticket" ]
SH
chmod +x "$fake_bin/"*

git -C "$repository" init -q
PATH="$fake_bin:$PATH" \
ARKTRACE_FAKE_SOURCE_APP="$source_app" \
ARKTRACE_FAKE_OPERATION_LOG="$operation_log" \
ARKTRACE_DEVELOPER_ID_APPLICATION="$identity" \
ARKTRACE_DEVELOPMENT_TEAM="$team" \
ARKTRACE_PHASE3_CANDIDATE_DIR="$temporary_root/candidates" \
    "$repository/scripts/build_phase3_distribution_candidate.sh" \
    >"$temporary_root/candidate-output"
candidate=$(find "$temporary_root/candidates" -maxdepth 1 -name '*.app' -print -quit)
[ -d "$candidate" ] || fail "signed review candidate was not produced"
grep -E 'xcodebuild .* -derivedDataPath .*/DerivedData' \
    "$operation_log" >/dev/null \
    || fail "candidate build did not isolate Xcode DerivedData"
helper="$candidate/Contents/Helpers/trace_streamer"
manifest="$candidate/Contents/Resources/TraceStreamer/manifest.json"
record="$candidate/Contents/Resources/TraceStreamer/distribution-signing.json"
[ "$(shasum -a 256 "$helper" | awk '{print $1}')" = \
    "$(jq -er '.binarySHA256' "$manifest")" ] \
    || fail "candidate manifest did not follow inner signing"
jq -e --arg raw "$raw_sha" --arg signed "$(shasum -a 256 "$helper" | awk '{print $1}')" '
    .unsignedBinarySHA256 == $raw and .signedBinarySHA256 == $signed
    and .signingCertificateSHA1 == "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    and .signingPolicy == "developer-id-runtime-timestamp"
' "$record" >/dev/null || fail "candidate distribution provenance is incomplete"
helper_line=$(grep -n 'codesign.*trace_streamer' "$operation_log" | head -1 | cut -d: -f1)
app_line=$(grep -n 'codesign.*ArkTrace.app' "$operation_log" | tail -1 | cut -d: -f1)
[ "$helper_line" -lt "$app_line" ] || fail "outer App was signed before its nested helper"

for drift in inventory file; do
    if PATH="$fake_bin:$PATH" \
        ARKTRACE_FAKE_SOURCE_APP="$source_app" \
        ARKTRACE_FAKE_ARCHIVE_LICENSE_DRIFT="$drift" \
        ARKTRACE_FAKE_OPERATION_LOG="$operation_log" \
        ARKTRACE_DEVELOPER_ID_APPLICATION="$identity" \
        ARKTRACE_DEVELOPMENT_TEAM="$team" \
        ARKTRACE_PHASE3_CANDIDATE_DIR="$temporary_root/license-drift-$drift" \
        "$repository/scripts/build_phase3_distribution_candidate.sh" >/dev/null 2>&1
    then
        fail "candidate accepted archive license drift: $drift"
    fi
    [ -z "$(find "$temporary_root/license-drift-$drift" -maxdepth 1 -name '*.app' -print -quit 2>/dev/null)" ] \
        || fail "license drift published a review candidate: $drift"
done

app_tree_sha() {
    current=$1
    (
        cd "$current"
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

checks='keyboardNavigation voiceOver minimumWindow reduceMotion minimumTargets focusRestoration'
checks_json='{}'
candidate_tree=$(app_tree_sha "$candidate")
for check in $checks; do
    case "$check" in
        minimumWindow|minimumTargets)
            artifact="Fixtures/release-evidence/$check.png"
            printf 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=' \
                | base64 -D >"$temporary_root/one-pixel.png"
            /usr/bin/sips -z 600 800 "$temporary_root/one-pixel.png" \
                --out "$repository/$artifact" >/dev/null
            printf '%s\n' "$check" >>"$repository/$artifact"
            ;;
        *)
            artifact="Fixtures/release-evidence/$check.txt"
            {
                printf 'ArkTrace accessibility walkthrough v1\n'
                printf 'check: %s\n' "$check"
                printf 'candidateTreeSHA256: %s\n' "$candidate_tree"
                printf 'steps:\n- exercise the exact signed candidate\n'
                printf 'observations:\n- semantic result verified\n'
            } >"$repository/$artifact"
            ;;
    esac
    artifact_sha=$(shasum -a 256 "$repository/$artifact" | awk '{print $1}')
    checks_json=$(printf '%s' "$checks_json" | jq \
        --arg check "$check" --arg path "$artifact" --arg sha "$artifact_sha" \
        '. + {($check): {status:"pass",artifactPath:$path,artifactSHA256:$sha}}')
done
evidence="$repository/Fixtures/release-evidence/accessibility.json"
reviewer_private_key="$temporary_root/reviewer-private.pem"
reviewer_public_key="$temporary_root/reviewer-public.pem"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
    -out "$reviewer_private_key" >/dev/null 2>&1
openssl pkey -in "$reviewer_private_key" -pubout -out "$reviewer_public_key" \
    >/dev/null 2>&1
reviewer_key_sha=$(shasum -a 256 "$reviewer_public_key" | awk '{print $1}')
cat >"$repository/Config/ArkTraceReleaseReviewers.json" <<EOF
{"formatVersion":1,"accessibilityReviewerPublicKeySHA256":"$reviewer_key_sha","largeTraceReviewerPublicKeySHA256":null,"redistributionGrantIssuerPublicKeySHA256":null}
EOF
review_signature_relative='Fixtures/release-evidence/accessibility.sig'
review_signature="$repository/$review_signature_relative"
printf '%s' "$checks_json" | jq \
    --arg tree "$candidate_tree" \
    --arg team "$team" --arg key "$reviewer_key_sha" \
    --arg signature "$review_signature_relative" '
    {
      formatVersion:1,
      app:{treeSHA256:$tree,codeDirectoryHash:"0123456789abcdef",version:"0.1.0",build:"1",bundleIdentifier:"com.arktrace.ArkTrace",teamIdentifier:$team},
      checks:.,reviewedAt:"2026-08-13T00:00:00Z",reviewer:"independent-reviewer",
      reviewerKeySHA256:$key,reviewSignaturePath:$signature
    }
' >"$evidence"
openssl dgst -sha256 -sign "$reviewer_private_key" -out "$review_signature" "$evidence"
git -C "$repository" add Config/ArkTraceReleaseReviewers.json Fixtures/release-evidence
git -C "$repository" -c user.name='ArkTrace Contract' \
    -c user.email='contract@invalid.example' commit -qm 'lock review evidence'
export ARKTRACE_ACCESSIBILITY_REVIEWER_PUBLIC_KEY="$reviewer_public_key"

: >"$operation_log"
PATH="$fake_bin:$PATH" \
ARKTRACE_FAKE_OPERATION_LOG="$operation_log" \
ARKTRACE_DEVELOPER_ID_APPLICATION="$identity" \
ARKTRACE_DEVELOPMENT_TEAM="$team" \
ARKTRACE_NOTARY_PROFILE=arktrace-test \
ARKTRACE_REVIEWED_SIGNED_APP="$candidate" \
ARKTRACE_ACCESSIBILITY_EVIDENCE="$evidence" \
ARKTRACE_PHASE3_ARTIFACT_DIR="$temporary_root/artifacts" \
    "$repository/scripts/package_phase3.sh" >"$temporary_root/package-output"
final_zip=$(find "$temporary_root/artifacts" -maxdepth 1 -name '*.zip' -print -quit)
[ -f "$final_zip" ] || fail "final distribution ZIP was not produced"
mkdir "$temporary_root/extracted"
/usr/bin/ditto -x -k "$final_zip" "$temporary_root/extracted"
[ -f "$temporary_root/extracted/ArkTrace.app/Contents/_CodeSignature/arktrace-test-ticket" ] \
    || fail "final ZIP was created before stapling"
grep 'xcrun notarytool submit' "$operation_log" >/dev/null \
    || fail "notarization was not attempted"
grep 'xcrun stapler staple' "$operation_log" >/dev/null \
    || fail "stapling was not attempted"

if PATH="$fake_bin:$PATH" \
    ARKTRACE_FAKE_OPERATION_LOG="$operation_log" \
    ARKTRACE_FAKE_NOTARY_INVALID=1 \
    ARKTRACE_DEVELOPER_ID_APPLICATION="$identity" \
    ARKTRACE_DEVELOPMENT_TEAM="$team" ARKTRACE_NOTARY_PROFILE=arktrace-test \
    ARKTRACE_REVIEWED_SIGNED_APP="$candidate" \
    ARKTRACE_ACCESSIBILITY_EVIDENCE="$evidence" \
    ARKTRACE_PHASE3_ARTIFACT_DIR="$temporary_root/notary-invalid" \
    "$repository/scripts/package_phase3.sh" >/dev/null 2>&1
then
    fail "exit-zero notarization response with Invalid status was accepted"
fi
[ -z "$(find "$temporary_root/notary-invalid" -maxdepth 1 -name '*.zip' -print -quit 2>/dev/null)" ] \
    || fail "invalid notarization response published an artifact"

if PATH="$fake_bin:$PATH" \
    ARKTRACE_FAKE_SOURCE_APP="$source_app" \
    ARKTRACE_FAKE_OPERATION_LOG="$operation_log" \
    ARKTRACE_FAKE_FAIL_PARTIAL_VERIFY=1 \
    ARKTRACE_DEVELOPER_ID_APPLICATION="$identity" \
    ARKTRACE_DEVELOPMENT_TEAM="$team" \
    ARKTRACE_PHASE3_CANDIDATE_DIR="$temporary_root/partial-rejected" \
    "$repository/scripts/build_phase3_distribution_candidate.sh" \
        >/dev/null 2>"$temporary_root/partial-rejected.log"
then
    fail "candidate with failed final verification was published"
fi
[ -z "$(find "$temporary_root/partial-rejected" -maxdepth 1 -name '*.app' -print -quit)" ] \
    || fail "failed candidate left a public App"

if PATH="$fake_bin:$PATH" \
    ARKTRACE_FAKE_OPERATION_LOG="$operation_log" \
    ARKTRACE_FAKE_FAIL_FINAL_VALIDATE=1 \
    ARKTRACE_DEVELOPER_ID_APPLICATION="$identity" \
    ARKTRACE_DEVELOPMENT_TEAM="$team" ARKTRACE_NOTARY_PROFILE=arktrace-test \
    ARKTRACE_REVIEWED_SIGNED_APP="$candidate" \
    ARKTRACE_ACCESSIBILITY_EVIDENCE="$evidence" \
    ARKTRACE_PHASE3_ARTIFACT_DIR="$temporary_root/final-rejected" \
    "$repository/scripts/package_phase3.sh" >/dev/null 2>"$temporary_root/final-rejected.log"
then
    fail "archive with failed final stapler validation was published"
fi
[ -z "$(find "$temporary_root/final-rejected" -maxdepth 1 -name '*.zip' -print -quit)" ] \
    || fail "failed package left a public or partial ZIP"
for rejection_log in "$temporary_root/partial-rejected.log" "$temporary_root/final-rejected.log"; do
    [ "$(stat -f '%z' "$rejection_log")" -le 4096 ] \
        || fail "external-tool rejection diagnostic exceeded its byte bound"
    if grep -F "$temporary_root" "$rejection_log" >/dev/null; then
        fail "external-tool rejection diagnostic disclosed an absolute path"
    fi
done

if PATH="$fake_bin:$PATH" \
    ARKTRACE_FAKE_SOURCE_APP="$source_app" \
    ARKTRACE_FAKE_OPERATION_LOG="$operation_log" \
    ARKTRACE_DEVELOPER_ID_APPLICATION='Developer ID Application: ArkTrace Test' \
    ARKTRACE_DEVELOPMENT_TEAM=TEAMTEST \
    ARKTRACE_PHASE3_CANDIDATE_DIR="$temporary_root/identity-prefix" \
    "$repository/scripts/build_phase3_distribution_candidate.sh" >/dev/null 2>&1
then
    fail "prefix signing identity was accepted"
fi

if PATH="$fake_bin:$PATH" \
    ARKTRACE_FAKE_SOURCE_APP="$source_app" \
    ARKTRACE_FAKE_OPERATION_LOG="$operation_log" \
    ARKTRACE_DEVELOPER_ID_APPLICATION="$identity" \
    ARKTRACE_DEVELOPMENT_TEAM=TEAM \
    ARKTRACE_PHASE3_CANDIDATE_DIR="$temporary_root/team-prefix" \
    "$repository/scripts/build_phase3_distribution_candidate.sh" >/dev/null 2>&1
then
    fail "prefix TeamIdentifier was accepted"
fi

trusted_configuration="$repository/Config/ArkTraceReleaseReviewers.json"
cp "$trusted_configuration" "$temporary_root/trusted-reviewers.json"
jq '.accessibilityReviewerPublicKeySHA256 = ("b" * 64)' \
    "$trusted_configuration" >"$temporary_root/untrusted-reviewers.json"
cp "$temporary_root/untrusted-reviewers.json" "$trusted_configuration"
if PATH="$fake_bin:$PATH" \
    ARKTRACE_FAKE_OPERATION_LOG="$operation_log" \
    ARKTRACE_DEVELOPER_ID_APPLICATION="$identity" \
    ARKTRACE_DEVELOPMENT_TEAM="$team" ARKTRACE_NOTARY_PROFILE=arktrace-test \
    ARKTRACE_REVIEWED_SIGNED_APP="$candidate" \
    ARKTRACE_ACCESSIBILITY_EVIDENCE="$evidence" \
    ARKTRACE_PHASE3_ARTIFACT_DIR="$temporary_root/dirty-trust" \
    "$repository/scripts/package_phase3.sh" >/dev/null 2>&1
then
    fail "caller-modified reviewer trust configuration was accepted"
fi
cp "$temporary_root/trusted-reviewers.json" "$trusted_configuration"

printf 'tampered\n' >>"$repository/Fixtures/release-evidence/voiceOver.txt"
if PATH="$fake_bin:$PATH" \
    ARKTRACE_FAKE_OPERATION_LOG="$operation_log" \
    ARKTRACE_DEVELOPER_ID_APPLICATION="$identity" \
    ARKTRACE_DEVELOPMENT_TEAM="$team" ARKTRACE_NOTARY_PROFILE=arktrace-test \
    ARKTRACE_REVIEWED_SIGNED_APP="$candidate" \
    ARKTRACE_ACCESSIBILITY_EVIDENCE="$evidence" \
    ARKTRACE_PHASE3_ARTIFACT_DIR="$temporary_root/rejected" \
    "$repository/scripts/package_phase3.sh" >/dev/null 2>"$temporary_root/rejected.log"
then
    fail "tampered manual accessibility evidence was accepted"
fi
[ "$(stat -f '%z' "$temporary_root/rejected.log")" -le 1024 ] \
    || fail "rejection diagnostic exceeded its byte bound"
if grep -F "$temporary_root" "$temporary_root/rejected.log" >/dev/null; then
    fail "rejection diagnostic disclosed an absolute path"
fi

printf 'Phase 3 distribution contract test passed: inner-first signing, evidence binding, staple-before-ZIP\n'
