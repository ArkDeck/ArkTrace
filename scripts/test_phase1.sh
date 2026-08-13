#!/bin/sh
set -eu

fail() {
    printf 'Phase 1 gate failed: %s\n' "$1" >&2
    exit 1
}

command -v swift >/dev/null 2>&1 || fail "swift is unavailable"
command -v jq >/dev/null 2>&1 || fail "jq is unavailable"
command -v shasum >/dev/null 2>&1 || fail "shasum is unavailable"
command -v git >/dev/null 2>&1 || fail "git is unavailable"
command -v file >/dev/null 2>&1 || fail "file is unavailable"

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
manifest="$repository_root/ThirdParty/TraceStreamer/macx/manifest.json"
binary="$repository_root/ThirdParty/TraceStreamer/macx/trace_streamer"
schema_evidence="$repository_root/Fixtures/databases/trace_streamer_4.3.7.schema-evidence.json"
license="$repository_root/Fixtures/traces/LICENSE.Apache-2.0.txt"

gate_temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/arktrace-phase1.XXXXXX")
test_log="$gate_temporary_directory/swift-test.log"
sanitized_test_log="$gate_temporary_directory/swift-test.sanitized.log"
machine_evidence="$gate_temporary_directory/phase1-evidence.json"
machine_evidence_with_results="$gate_temporary_directory/phase1-evidence-with-results.json"
cleanup() {
    rm -rf -- "$gate_temporary_directory"
}
trap cleanup EXIT HUP INT TERM

print_test_failure() {
    sed \
        -e "s|$repository_root|<repo>|g" \
        -e "s|$gate_temporary_directory|<temp>|g" \
        "$test_log" >"$sanitized_test_log"
    grep -nE 'error: -\[|Test Case .* failed|fatal error|unexpected failure' \
        "$sanitized_test_log" >&2 || true
    tail -n 120 "$sanitized_test_log" >&2
}

[ -r "$manifest" ] || fail "pinned manifest is missing"
[ -x "$binary" ] || fail "pinned trace_streamer is missing or not executable"
[ -r "$schema_evidence" ] || fail "locked schema evidence is missing"
[ -r "$license" ] || fail "pinned fixture license is missing"

jq -e '
    .name == "trace_streamer"
    and .upstreamRepository == "https://gitcode.com/openharmony/developtools_smartperf_host.git"
    and .upstreamRevision == "447a0a49a7b3b914d6e9bd00648ba5a340f6fbf6"
    and .reportedVersion == "4.3.7"
    and .architecture == "arm64"
    and .adapterVersion == "1"
    and .buildRecipeVersion == "1"
    and (.binarySHA256 | test("^[0-9a-f]{64}$"))
' "$manifest" >/dev/null || fail "manifest format or pinned identity drifted"

jq -e '
    .formatVersion == 1
    and .schemaAdapterVersion == "2"
    and (.schemaFingerprint | test("^[0-9a-f]{64}$"))
    and (.fixtures | length == 2)
    and ([.fixtures[].name] | sort == ["trace_small_10.systrace", "zlib.htrace"])
' "$schema_evidence" >/dev/null || fail "schema evidence format or fixture set drifted"

actual_binary_sha=$(shasum -a 256 "$binary" | awk '{print $1}')
manifest_binary_sha=$(jq -er '.binarySHA256' "$manifest")
evidence_binary_sha=$(jq -er '.parser.binarySHA256' "$schema_evidence")
[ "$actual_binary_sha" = "$manifest_binary_sha" ] \
    || fail "trace_streamer SHA does not match manifest"
[ "$actual_binary_sha" = "$evidence_binary_sha" ] \
    || fail "trace_streamer SHA does not match locked evidence"

file -b "$binary" | grep -q 'Mach-O 64-bit executable arm64' \
    || fail "trace_streamer is not a native arm64 Mach-O executable"

verify_locked_file() {
    relative_path=$1
    evidence_name=$2
    file_path="$repository_root/$relative_path"
    [ -r "$file_path" ] || fail "locked file is missing: $evidence_name"
    expected_sha=$(jq -er --arg name "$evidence_name" \
        '.fixtures[] | select(.name == $name) | .sourceSHA256' "$schema_evidence")
    expected_bytes=$(jq -er --arg name "$evidence_name" \
        '.fixtures[] | select(.name == $name) | .sourceByteCount' "$schema_evidence")
    expected_blob=$(jq -er --arg name "$evidence_name" \
        '.fixtures[] | select(.name == $name) | .upstreamBlob' "$schema_evidence")
    actual_sha=$(shasum -a 256 "$file_path" | awk '{print $1}')
    actual_bytes=$(stat -f '%z' "$file_path")
    actual_blob=$(git -C "$repository_root" hash-object "$file_path")
    [ "$actual_sha" = "$expected_sha" ] || fail "fixture SHA drifted: $evidence_name"
    [ "$actual_bytes" = "$expected_bytes" ] || fail "fixture size drifted: $evidence_name"
    [ "$actual_blob" = "$expected_blob" ] || fail "fixture Git blob drifted: $evidence_name"
}

verify_locked_file "Fixtures/traces/trace_small_10.systrace" "trace_small_10.systrace"
verify_locked_file "Fixtures/traces/zlib.htrace" "zlib.htrace"

license_sha=$(shasum -a 256 "$license" | awk '{print $1}')
license_bytes=$(stat -f '%z' "$license")
license_blob=$(git -C "$repository_root" hash-object "$license")
[ "$license_sha" = "$(jq -er '.upstream.licenseSHA256' "$schema_evidence")" ] \
    || fail "fixture license SHA drifted"
[ "$license_bytes" = "$(jq -er '.upstream.licenseByteCount' "$schema_evidence")" ] \
    || fail "fixture license size drifted"
[ "$license_blob" = "$(jq -er '.upstream.licenseBlob' "$schema_evidence")" ] \
    || fail "fixture license Git blob drifted"

cd "$repository_root"
swift package clean
if ! env \
    ARKTRACE_PHASE1_GATE=1 \
    ARKTRACE_PHASE1_EVIDENCE_OUTPUT="$machine_evidence" \
    ARKTRACE_TRACE_STREAMER="$binary" \
    ARKTRACE_TEST_TRACE="$repository_root/Fixtures/traces/trace_small_10.systrace" \
    SWIFTPM_MODULECACHE_OVERRIDE="$gate_temporary_directory/module-cache" \
    CLANG_MODULE_CACHE_PATH="$gate_temporary_directory/module-cache" \
    swift test >"$test_log" 2>&1
then
    print_test_failure
    fail "Swift test suite failed"
fi

# Match XCTest's actual skip output (per-case line and run summary), not the
# XCTSkip identifier, so test names containing "XCTSkip" cannot false-positive.
if grep -Eq "' skipped \(|[0-9] tests? skipped" "$test_log"; then
    print_test_failure
    fail "Phase 1 gate must contain zero skipped tests"
fi

test_count=$(grep -oE 'Executed [0-9]+ tests' "$test_log" | tail -n 1 | awk '{print $2}')
[ -n "$test_count" ] && [ "$test_count" -gt 0 ] \
    || fail "could not determine a positive XCTest count"

[ -s "$machine_evidence" ] || fail "integration did not produce machine evidence"
[ "$(stat -f '%z' "$machine_evidence")" -le 4096 ] \
    || fail "machine evidence exceeded 4096 bytes"
jq --argjson testCount "$test_count" \
    '. + {testCount: $testCount, skippedTestCount: 0}' \
    "$machine_evidence" >"$machine_evidence_with_results"
mv "$machine_evidence_with_results" "$machine_evidence"
[ "$(stat -f '%z' "$machine_evidence")" -le 4096 ] \
    || fail "machine evidence with test results exceeded 4096 bytes"
jq -e '
    .formatVersion == 1
    and (.parserBinarySHA256 | test("^[0-9a-f]{64}$"))
    and (.sourceSHA256 | test("^[0-9a-f]{64}$"))
    and (.upstreamDatabaseSHA256 | test("^[0-9a-f]{64}$"))
    and (.readyDatabaseSHA256 | test("^[0-9a-f]{64}$"))
    and (.schemaFingerprint | test("^[0-9a-f]{64}$"))
    and .schemaAdapterVersion == "2"
    and .indexVersion == 1
    and .testCount > 0
    and .skippedTestCount == 0
    and .durationNs > 0
    and .processSampleCount > 0
    and .threadSampleCount > 0
    and .quickCheck == "ok"
    and .metaTablePresent == false
    and .pathsAbsent == true
    and .stages == [
        "preparing", "hashing", "parsing", "validating",
        "indexing", "openingDatabase", "ready"
    ]
' "$machine_evidence" >/dev/null || fail "machine evidence contract failed"

expected_gate_source_sha=$(jq -er \
    '.fixtures[] | select(.name == "trace_small_10.systrace") | .sourceSHA256' \
    "$schema_evidence")
[ "$(jq -er '.parserBinarySHA256' "$machine_evidence")" = "$actual_binary_sha" ] \
    || fail "machine evidence parser SHA drifted"
[ "$(jq -er '.sourceSHA256' "$machine_evidence")" = "$expected_gate_source_sha" ] \
    || fail "machine evidence source SHA drifted"
[ "$(jq -er '.schemaFingerprint' "$machine_evidence")" \
    = "$(jq -er '.schemaFingerprint' "$schema_evidence")" ] \
    || fail "machine evidence schema fingerprint drifted"

printf 'Phase 1 gate passed: binary=%s tests=%s skipped=0\n' \
    "$actual_binary_sha" "$test_count"
jq -c . "$machine_evidence"
