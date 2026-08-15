#!/bin/sh
set -eu

fail() {
    printf 'Phase 3 benchmark failed: %s\n' "$1" >&2
    exit 1
}

bounded_failure_summary() {
    benchmark_failure_log=$1
    benchmark_sanitized_log="$temporary_root/benchmark.sanitized.log"
    sed \
        -e "s|$repository_root|<repo>|g" \
        -e "s|$temporary_root|<temp>|g" \
        -e "s|$ARKTRACE_REVIEWED_BUILD_ROOT|<build>|g" \
        -e "s|$ARKTRACE_REVIEWED_TEMP_ROOT|<system-temp>|g" \
        "$benchmark_failure_log" \
        | sed -E 's#(/[A-Za-z0-9._ -]+)+#<path>#g' \
        | cut -c1-512 >"$benchmark_sanitized_log"
    grep -nE 'error: -\[|Test Case .* failed|fatal error|unexpected failure' \
        "$benchmark_sanitized_log" | tail -40 >&2 || true
    printf 'benchmark subprocess diagnostics withheld; bounded failure locations shown above\n' \
        >&2
}

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd -P)
. "$script_directory/phase3_shell_safety.sh"
fixture_lock="$repository_root/Fixtures/phase3-performance-fixtures.json"
fixture_class=${1:-medium}
warmup_only=${ARKTRACE_PHASE3_WARMUP_ONLY:-0}
parser=${ARKTRACE_TRACE_STREAMER:-$repository_root/ThirdParty/TraceStreamer/macx/trace_streamer}
locked_parser="$repository_root/ThirdParty/TraceStreamer/macx/trace_streamer"
locked_manifest="$repository_root/ThirdParty/TraceStreamer/macx/manifest.json"
default_evidence_directory="$repository_root/.build/phase3-evidence"
requested_evidence=${ARKTRACE_PHASE3_EVIDENCE_OUTPUT:-$default_evidence_directory/arktrace-phase3-$fixture_class-$(date -u +%Y%m%dT%H%M%SZ)-$$.json}
arktrace_validate_reviewed_roots "$repository_root"
[ "$fixture_class" = medium ] || [ "$fixture_class" = large ] \
    || fail "fixture class must be medium or large"
[ "$warmup_only" = 0 ] || [ "$warmup_only" = 1 ] \
    || fail "warm-up mode must be 0 or 1"
command -v openssl >/dev/null 2>&1 || fail "OpenSSL is unavailable"
[ -x "$parser" ] && [ -f "$parser" ] && [ ! -L "$parser" ] \
    || fail "pinned TraceStreamer is unavailable"
evidence_name=$(basename -- "$requested_evidence")
case "$evidence_name" in
    arktrace-phase3-*.json) ;;
    *) fail "benchmark evidence filename is invalid" ;;
esac
arktrace_validate_owned_directory_request \
    "$(dirname -- "$requested_evidence")" "benchmark evidence"
arktrace_create_reviewed_build_root
evidence_directory=$(arktrace_secure_owned_directory \
    "$(dirname -- "$requested_evidence")" .arktrace-phase3-evidence-v1 "benchmark evidence")
evidence_output="$evidence_directory/$evidence_name"
[ ! -e "$evidence_output" ] && [ ! -L "$evidence_output" ] \
    || fail "benchmark evidence output already exists"
temporary_root=$(mktemp -d "$ARKTRACE_REVIEWED_TEMP_ROOT/arktrace-benchmark.XXXXXX")
partial_evidence=$(mktemp "$evidence_directory/.evidence.XXXXXX")
rm -f -- "$partial_evidence"
cleanup() {
    rm -f -- "$partial_evidence"
    rm -rf -- "$temporary_root"
}
trap cleanup EXIT HUP INT TERM

reviewed_file() {
    relative=$1
    expected_sha=$2
    maximum_bytes=${3:-1048576}
    case "$relative" in
        Fixtures/*) ;;
        *) fail "reviewed evidence path is outside Fixtures" ;;
    esac
    case "/$relative/" in */../*|*/./*) fail "reviewed evidence path is invalid" ;; esac
    candidate="$repository_root/$relative"
    arktrace_assert_physical_file_within \
        "$repository_root" "$candidate" "reviewed evidence"
    git -C "$repository_root" ls-files --error-unmatch "$relative" >/dev/null 2>&1 \
        || fail "reviewed evidence is not tracked"
    git -C "$repository_root" cat-file -e "HEAD:$relative" 2>/dev/null \
        || fail "reviewed evidence is absent from HEAD"
    head_sha=$(git -C "$repository_root" show "HEAD:$relative" 2>/dev/null \
        | shasum -a 256 | awk '{print $1}')
    [ "$head_sha" = "$(shasum -a 256 "$candidate" | awk '{print $1}')" ] \
        || fail "reviewed evidence differs from HEAD"
    [ "$(shasum -a 256 "$candidate" | awk '{print $1}')" = "$expected_sha" ] \
        || fail "reviewed evidence drifted"
    [ "$(stat -f '%z' "$candidate")" -le "$maximum_bytes" ] \
        || fail "reviewed evidence exceeds its byte bound"
    printf '%s\n' "$candidate"
}

[ -f "$locked_parser" ] && [ ! -L "$locked_parser" ] \
    && [ -f "$locked_manifest" ] && [ ! -L "$locked_manifest" ] \
    || fail "repository TraceStreamer lock is unavailable"
selected_manifest=$(dirname -- "$parser")/manifest.json
[ -f "$selected_manifest" ] && [ ! -L "$selected_manifest" ] \
    || fail "selected TraceStreamer manifest is unavailable"
cmp "$parser" "$locked_parser" >/dev/null 2>&1 \
    || fail "selected TraceStreamer bytes differ from the repository lock"
cmp "$selected_manifest" "$locked_manifest" >/dev/null 2>&1 \
    || fail "selected TraceStreamer manifest differs from the repository lock"
parser_sha=$(shasum -a 256 "$parser" | awk '{print $1}')
[ "$parser_sha" = "$(jq -er '.binarySHA256' "$locked_manifest")" ] \
    || fail "repository TraceStreamer SHA is inconsistent"

if [ "$fixture_class" = medium ]; then
    trace=$($script_directory/fetch_phase3_fixtures.sh)
    provenance="$fixture_lock"
    provenance_sha=$(shasum -a 256 "$provenance" | awk '{print $1}')
    provenance_source=$(jq -er \
        '.upstream.repository + "@" + .upstream.revision + ":" + .medium.path' \
        "$fixture_lock")
    license_sha=$(jq -er '.upstream.licenseSHA256' "$fixture_lock")
else
    trace=${ARKTRACE_LARGE_TRACE:-}
    supplied_provenance=${ARKTRACE_LARGE_TRACE_EVIDENCE:-}
    [ -n "$trace" ] && [ -n "$supplied_provenance" ] \
        || fail "large trace and its reviewed provenance are required"
    reviewed_path=$(jq -er \
        '.large.reviewedEvidencePath | select(type == "string" and length > 0)' \
        "$fixture_lock") || fail "large provenance has not been locked by review"
    reviewed_sha=$(jq -er \
        '.large.reviewedEvidenceSHA256 | select(test("^[0-9a-f]{64}$"))' \
        "$fixture_lock") || fail "large provenance SHA has not been locked by review"
    provenance=$(reviewed_file "$reviewed_path" "$reviewed_sha" 65536)
    cmp "$supplied_provenance" "$provenance" >/dev/null 2>&1 \
        || fail "caller provenance is not the locked reviewed record"
    [ -f "$trace" ] && [ ! -L "$trace" ] \
        || fail "large trace must be a regular non-symlink"
    jq -e '
        .formatVersion == 3
        and .fixtureClass == "large"
        and ((keys | sort) == ["acquisition","fixtureClass","formatVersion","integrity","license","review","trace"])
        and ((.trace | keys | sort) == ["byteCount","durationNs","requiredRows","sha256"])
        and (.trace.sha256 | test("^[0-9a-f]{64}$"))
        and .trace.byteCount > 524288000 and .trace.byteCount <= 2147483648
        and .trace.durationNs > 0
        and ((.trace.requiredRows | keys | sort) == ["callstack","process","sched_slice","thread","thread_state"])
        and ([.trace.requiredRows[] > 0] | all)
        and ((.acquisition | keys | sort) == ["recordPath","recordSHA256"])
        and (.acquisition.recordPath | test("^Fixtures/[A-Za-z0-9_./+-]+$") and contains("..") | not)
        and (.acquisition.recordSHA256 | test("^[0-9a-f]{64}$"))
        and ((.integrity | keys | sort) == ["reportPath","reportSHA256"])
        and (.integrity.reportPath | test("^Fixtures/[A-Za-z0-9_./+-]+$") and contains("..") | not)
        and (.integrity.reportSHA256 | test("^[0-9a-f]{64}$"))
        and ((.license | keys | sort) == ["grantIssuerPublicKeyPath","grantIssuerPublicKeySHA256","grantSignaturePath","path","redistributionGrantPath","redistributionGrantSHA256","sha256"])
        and (.license.path | test("^Fixtures/[A-Za-z0-9_./+-]+$") and contains("..") | not)
        and (.license.redistributionGrantPath | test("^Fixtures/[A-Za-z0-9_./+-]+$") and contains("..") | not)
        and (.license.sha256 | test("^[0-9a-f]{64}$"))
        and (.license.redistributionGrantSHA256 | test("^[0-9a-f]{64}$"))
        and (.license.grantSignaturePath | test("^Fixtures/[A-Za-z0-9_./+-]+$"))
        and (.license.grantIssuerPublicKeyPath | test("^Fixtures/[A-Za-z0-9_./+-]+$"))
        and (.license.grantIssuerPublicKeySHA256 | test("^[0-9a-f]{64}$"))
        and ((.review | keys | sort) == ["manifestPath","manifestSHA256","reviewerPublicKeyPath","reviewerPublicKeySHA256","signaturePath"])
        and (.review.manifestPath | test("^Fixtures/[A-Za-z0-9_./+-]+$"))
        and (.review.signaturePath | test("^Fixtures/[A-Za-z0-9_./+-]+$"))
        and (.review.reviewerPublicKeyPath | test("^Fixtures/[A-Za-z0-9_./+-]+$"))
        and ([.review.manifestSHA256,.review.reviewerPublicKeySHA256] | all(test("^[0-9a-f]{64}$")))
        and ([.license.grantSignaturePath,.license.grantIssuerPublicKeyPath,
              .review.manifestPath,.review.signaturePath,.review.reviewerPublicKeyPath] |
             all(contains("..") | not))
    ' "$provenance" >/dev/null || fail "locked large provenance schema is invalid"
    trust_configuration="$repository_root/Config/ArkTraceReleaseReviewers.json"
    arktrace_assert_physical_file_within \
        "$repository_root" "$trust_configuration" "release reviewer trust configuration"
    git -C "$repository_root" cat-file -e \
        'HEAD:Config/ArkTraceReleaseReviewers.json' 2>/dev/null \
        || fail "release reviewer trust configuration is absent from HEAD"
    trust_head_sha=$(git -C "$repository_root" show \
        'HEAD:Config/ArkTraceReleaseReviewers.json' 2>/dev/null \
        | shasum -a 256 | awk '{print $1}')
    [ "$trust_head_sha" = "$(shasum -a 256 "$trust_configuration" | awk '{print $1}')" ] \
        || fail "release reviewer trust configuration differs from HEAD"
    trusted_review_key=$(jq -er '
      if (
        .formatVersion == 1
        and ((keys | sort) == ["formatVersion","largeTraceReviewerPublicKeySHA256","redistributionGrantIssuerPublicKeySHA256"])
        and (.largeTraceReviewerPublicKeySHA256 | test("^[0-9a-f]{64}$"))
        and (.redistributionGrantIssuerPublicKeySHA256 | test("^[0-9a-f]{64}$"))
      ) then .largeTraceReviewerPublicKeySHA256 else empty end
    ' "$trust_configuration") || fail "large trace reviewer trust root is not provisioned"
    trusted_grant_key=$(jq -er '.redistributionGrantIssuerPublicKeySHA256' \
        "$trust_configuration")
    [ "$trusted_review_key" = "$(jq -er '.review.reviewerPublicKeySHA256' "$provenance")" ] \
        || fail "large trace reviewer is not trusted"
    [ "$trusted_grant_key" = "$(jq -er '.license.grantIssuerPublicKeySHA256' "$provenance")" ] \
        || fail "large redistribution grant issuer is not trusted"
    generated_integrity="$temporary_root/generated-integrity.json"
    "$script_directory/verify_htrace_integrity.py" "$trace" "$generated_integrity" \
        || fail "large trace container integrity failed"
    [ "$(jq -er '.byteCount' "$generated_integrity")" = \
        "$(jq -er '.trace.byteCount' "$provenance")" ] \
        || fail "large trace byte count differs from reviewed provenance"
    [ "$(jq -er '.traceSHA256' "$generated_integrity")" = \
        "$(jq -er '.trace.sha256' "$provenance")" ] \
        || fail "large trace SHA differs from reviewed provenance"
    [ "$(stat -f '%z' "$trace")" = "$(jq -er '.byteCount' "$generated_integrity")" ] \
        || fail "large trace path changed after verification"
    arktrace_is_fully_allocated_regular_file "$trace" \
        || fail "large trace is sparse or incompletely allocated"
    acquisition_record=$(reviewed_file \
        "$(jq -er '.acquisition.recordPath' "$provenance")" \
        "$(jq -er '.acquisition.recordSHA256' "$provenance")" 65536)
    integrity_report=$(reviewed_file \
        "$(jq -er '.integrity.reportPath' "$provenance")" \
        "$(jq -er '.integrity.reportSHA256' "$provenance")" 1048576)
    license_file=$(reviewed_file \
        "$(jq -er '.license.path' "$provenance")" \
        "$(jq -er '.license.sha256' "$provenance")" 1048576)
    redistribution_grant=$(reviewed_file \
        "$(jq -er '.license.redistributionGrantPath' "$provenance")" \
        "$(jq -er '.license.redistributionGrantSHA256' "$provenance")" 65536)
    capture_log=$(reviewed_file \
        "$(jq -er '.captureLogPath' "$acquisition_record")" \
        "$(jq -er '.captureLogSHA256' "$acquisition_record")" 1048576)
    review_manifest=$(reviewed_file \
        "$(jq -er '.review.manifestPath' "$provenance")" \
        "$(jq -er '.review.manifestSHA256' "$provenance")" 65536)
    review_signature=$(reviewed_file \
        "$(jq -er '.review.signaturePath' "$provenance")" \
        "$(shasum -a 256 "$repository_root/$(jq -er '.review.signaturePath' "$provenance")" | awk '{print $1}')" 65536)
    review_key=$(reviewed_file \
        "$(jq -er '.review.reviewerPublicKeyPath' "$provenance")" \
        "$(jq -er '.review.reviewerPublicKeySHA256' "$provenance")" 65536)
    grant_signature=$(reviewed_file \
        "$(jq -er '.license.grantSignaturePath' "$provenance")" \
        "$(shasum -a 256 "$repository_root/$(jq -er '.license.grantSignaturePath' "$provenance")" | awk '{print $1}')" 65536)
    grant_key=$(reviewed_file \
        "$(jq -er '.license.grantIssuerPublicKeyPath' "$provenance")" \
        "$(jq -er '.license.grantIssuerPublicKeySHA256' "$provenance")" 65536)
    jq -e --arg traceSHA "$(jq -er '.trace.sha256' "$provenance")" '
        .formatVersion == 1
        and ((keys | sort) == ["captureEndedAt","captureLogPath","captureLogSHA256","captureSessionID","captureStartedAt","captureTool","capturedBy","formatVersion","reviewMethods","reviewedAt","reviewedBy","sourceDescription","traceSHA256"])
        and .traceSHA256 == $traceSHA
        and ([.captureSessionID,.captureTool,.capturedBy,.reviewedBy,.sourceDescription] |
            all(type == "string" and length > 0 and length <= 512))
        and .capturedBy != .reviewedBy
        and (.captureStartedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
        and (.captureEndedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
        and (.reviewedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
        and .reviewMethods == ["capture-log","packet-integrity","redistribution-license"]
        and (.captureLogPath | test("^Fixtures/[A-Za-z0-9_./+-]+$") and contains("..") | not)
        and (.captureLogSHA256 | test("^[0-9a-f]{64}$"))
    ' "$acquisition_record" >/dev/null \
        || fail "large acquisition record is not independently reviewable"
    jq -e --arg traceSHA "$(jq -er '.trace.sha256' "$provenance")" \
        --arg session "$(jq -er '.captureSessionID' "$acquisition_record")" '
        .formatVersion == 1
        and ((keys | sort) == ["captureSessionID","formatVersion","issuedAt","issuer","licenseExpression","redistributionAllowed","subject","traceSHA256"])
        and .traceSHA256 == $traceSHA and .captureSessionID == $session
        and .redistributionAllowed == true
        and ([.issuer,.subject,.licenseExpression] | all(type == "string" and length > 0 and length <= 512))
        and (.issuedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
    ' "$redistribution_grant" >/dev/null \
        || fail "large redistribution grant is not trace-bound"
    run_verify_log="$temporary_root/review-signature.log"
    openssl dgst -sha256 -verify "$review_key" -signature "$review_signature" \
        "$review_manifest" >"$run_verify_log" 2>&1 \
        || fail "large independent review signature is invalid"
    openssl dgst -sha256 -verify "$grant_key" -signature "$grant_signature" \
        "$redistribution_grant" >"$run_verify_log" 2>&1 \
        || fail "large redistribution grant signature is invalid"
    jq -e --arg traceSHA "$(jq -er '.trace.sha256' "$provenance")" \
        --arg traceBytes "$(jq -er '.trace.byteCount|tostring' "$provenance")" \
        --arg acquisitionSHA "$(jq -er '.acquisition.recordSHA256' "$provenance")" \
        --arg integritySHA "$(jq -er '.integrity.reportSHA256' "$provenance")" \
        --arg grantSHA "$(jq -er '.license.redistributionGrantSHA256' "$provenance")" \
        -f "$script_directory/verify_phase3_review_manifest.jq" \
        "$review_manifest" >/dev/null \
        || fail "large review manifest is not bound to the complete evidence set"
    PYTHONDONTWRITEBYTECODE=1 python3 -B \
        "$script_directory/verify_phase3_evidence_times.py" \
        "$acquisition_record" "$redistribution_grant" "$review_manifest" \
        >/dev/null 2>&1 \
        || fail "large capture and review timestamps are inconsistent"
    cmp "$generated_integrity" "$integrity_report" >/dev/null 2>&1 \
        || fail "large trace bytes differ from the reviewed integrity report"
    jq -e --slurpfile provenance "$provenance" '
        .traceSHA256 == $provenance[0].trace.sha256
        and .byteCount == $provenance[0].trace.byteCount
        and .segmentCount == 1 and .segments[0].dataType == 0
        and .segments[0].protobufPacketCount == .protobufPacketCount
        and .protobufPacketCount > 0
    ' "$integrity_report" >/dev/null \
        || fail "large trace integrity report is inconsistent"
    provenance_sha=$reviewed_sha
    provenance_source="reviewed-acquisition:$(jq -er '.acquisition.recordSHA256' "$provenance")"
    license_sha=$(jq -er '.license.sha256' "$provenance")
fi

base_revision=$(git -C "$repository_root" rev-parse HEAD)
if [ -z "$(git -C "$repository_root" status --porcelain=v1 --untracked-files=all)" ]; then
    worktree_dirty=0
else
    worktree_dirty=1
fi
source_tree_sha=$(PYTHONDONTWRITEBYTECODE=1 python3 -B \
    "$script_directory/source_tree_identity.py" "$repository_root")
case "$source_tree_sha" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
    *) fail "source tree identity is invalid" ;;
esac
[ "${#source_tree_sha}" -eq 64 ] || fail "source tree identity is invalid"

benchmark_log="$temporary_root/benchmark.log"
if ! ARKTRACE_PHASE3_GATE=1 \
    ARKTRACE_PHASE3_WARMUP_ONLY="$warmup_only" \
    ARKTRACE_PHASE3_FIXTURE_CLASS="$fixture_class" \
    ARKTRACE_PHASE3_TRACE="$trace" \
    ARKTRACE_PHASE3_EVIDENCE_OUTPUT="$partial_evidence" \
    ARKTRACE_PHASE3_PROVENANCE_SHA256="$provenance_sha" \
    ARKTRACE_PHASE3_PROVENANCE_SOURCE="$provenance_source" \
    ARKTRACE_PHASE3_FIXTURE_LICENSE_SHA256="$license_sha" \
    ARKTRACE_TRACE_STREAMER="$parser" \
    ARKTRACE_BASE_REVISION="$base_revision" \
    ARKTRACE_WORKTREE_DIRTY="$worktree_dirty" \
    ARKTRACE_SOURCE_TREE_SHA256="$source_tree_sha" \
    CI=true swift test -c release \
        --filter ParserIntegrationTests.testPhase3GateWritesViewportPerformanceEvidenceWhenRequested \
        >"$benchmark_log" 2>&1
then
    bounded_failure_summary "$benchmark_log"
    fail "performance XCTest failed"
fi

if [ "$warmup_only" = 1 ]; then
    [ -s "$partial_evidence" ] && [ ! -L "$partial_evidence" ] \
        || fail "warm-up did not complete the production evidence workload"
    printf 'Phase 3 %s benchmark warm-up passed: production workload completed without publishing evidence\n' \
        "$fixture_class"
    exit 0
fi

[ -s "$partial_evidence" ] && [ ! -L "$partial_evidence" ] \
    || fail "benchmark did not write private evidence"
jq -e -f "$script_directory/verify_phase3_query_plans.jq" \
    "$partial_evidence" >/dev/null \
    || fail "benchmark query plans do not use the exact reviewed index set"
jq -e -f "$script_directory/verify_phase4_workloads.jq" \
    "$partial_evidence" >/dev/null \
    || fail "benchmark Context or analysis workload drifted from the reviewed default"
jq -e \
    --arg class "$fixture_class" --arg base "$base_revision" \
    --arg sourceTreeSHA "$source_tree_sha" \
    --arg parserSHA "$parser_sha" --arg provenanceSHA "$provenance_sha" \
    --arg provenanceSource "$provenance_source" --arg licenseSHA "$license_sha" \
    --argjson dirty "$worktree_dirty" '
    .formatVersion == 3
    and ((keys | sort) == ["analysisWorkload","arkTraceBaseRevision","arkTraceSourceTreeSHA256","arkTraceTestBinarySHA256","arkTraceVersion","cacheOpenP50Ms","cacheOpenP95Ms","capabilities","coldOpenMs","contextP50Ms","contextP95Ms","contextWorkload","databaseByteCount","deterministicAnalysisP50Ms","deterministicAnalysisP95Ms","diagnostics","fixtureClass","fixtureLicenseSHA256","fixtureProvenanceSHA256","fixtureProvenanceSource","formatVersion","frameP50Ms","frameP95Ms","indexMs","iterations","machine","maximumPrimitives","measuredRows","metadataDirectoryP50Ms","metadataDirectoryP95Ms","panFrameP50Ms","panFrameP95Ms","parseMs","parserBinarySHA256","parserUpstreamRevision","parserVersion","peakRSSBytes","rebuildFrameP50Ms","rebuildFrameP95Ms","selectionFrameP50Ms","selectionFrameP95Ms","traceByteCount","traceDurationNs","traceSHA256","validationMs","viewportLatency","viewportP50Ms","viewportP95Ms","workingTreeDirty"])
    and .fixtureClass == $class
    and .arkTraceBaseRevision == $base
    and .workingTreeDirty == ($dirty == 1)
    and .arkTraceSourceTreeSHA256 == $sourceTreeSHA
    and (.arkTraceTestBinarySHA256 | test("^[0-9a-f]{64}$"))
    and .parserBinarySHA256 == $parserSHA
    and .fixtureProvenanceSHA256 == $provenanceSHA
    and .fixtureProvenanceSource == $provenanceSource
    and .fixtureLicenseSHA256 == $licenseSHA
    and (.arkTraceVersion | type == "string" and length > 0 and length <= 64)
    and (.traceSHA256 | test("^[0-9a-f]{64}$"))
    and (.traceByteCount | type == "number" and . > 0)
    and (.traceDurationNs | type == "number" and . > 0)
    and (.parserVersion | type == "string" and length > 0 and length <= 64)
    and (.parserUpstreamRevision | test("^[0-9a-f]{40}$"))
    and (.databaseByteCount | type == "number" and . > 0)
    and ([.coldOpenMs,.parseMs,.validationMs,.indexMs] | all(type == "number" and . >= 0))
    and ((.machine | keys | sort) == ["architecture","model","operatingSystem","physicalMemoryBytes"])
    and (.machine.physicalMemoryBytes > 0)
    and .iterations == 20
    and .maximumPrimitives == 20000
    and .cacheOpenP95Ms <= 1000
    and .metadataDirectoryP95Ms <= 150
    and .frameP95Ms <= 16.7
    and .selectionFrameP95Ms <= 16.7
    and .panFrameP95Ms <= 16.7
    and .rebuildFrameP95Ms <= 250
    and ((.viewportLatency | keys | sort) == ["automaticLoader","cpuDensity","cpuDetail","namedSliceDensity","namedSliceDetail","threadStateDensity","threadStateDetail"])
    and ([.viewportLatency[] |
        ((keys | sort) == ["p50Ms","p95Ms","sampleCount"])
        and .sampleCount == 20 and .p50Ms >= 0 and .p95Ms >= .p50Ms
        and .p95Ms <= (if $class == "large" then 500 else 250 end)
    ] | all)
    and .viewportP95Ms == ([.viewportLatency[].p95Ms] | max)
    and .viewportP50Ms == ([.viewportLatency[].p50Ms] | max)
    and .contextP95Ms <= (if $class == "large" then 2000 else 1000 end)
    and .deterministicAnalysisP95Ms <= (if $class == "large" then 5000 else 3000 end)
    and .peakRSSBytes <= 1610612736
    and .capabilities.cpuScheduling == true
    and .capabilities.threadStates == true
    and .capabilities.namedSlices == true
    and ([.measuredRows[] > 0] | all)
    and ((.measuredRows | keys | sort) == ["contextBytes","contextEvents","cpuDensityEvents","cpuDetail","deterministicAnalysisRows","namedSliceDensityEvents","namedSliceDetail","threadStateDensityEvents","threadStateDetail"])
    and ((.diagnostics | keys | sort) == ["applicableIndexNames","persistentIndexNames","queryPlans","relationshipProbeSteps","relationshipVMInstructionBudget","tableRowCounts","usesAutomaticIndex"])
    and .diagnostics.relationshipVMInstructionBudget == 250000
    and .diagnostics.usesAutomaticIndex == false
    and ((.diagnostics.relationshipProbeSteps | keys | sort) == ["sched_slice.ipid->process.ipid","sched_slice.itid->thread.itid","thread.ipid->process.ipid","thread_state.itid->thread.itid"])
    and ([.diagnostics.relationshipProbeSteps[] | type == "number" and . > 0 and . < 250000] | all)
    and (.diagnostics.applicableIndexNames | type == "array" and length >= 10)
    and (.diagnostics.applicableIndexNames == (.diagnostics.applicableIndexNames | sort | unique))
    and ((.diagnostics.applicableIndexNames - [
      "arktrace_v1_callstack_callid_ts","arktrace_v1_measure_filter_id_ts",
      "arktrace_v1_process_ipid","arktrace_v1_process_pid",
      "arktrace_v1_sched_slice_itid_ts","arktrace_v1_sched_slice_ts_cpu",
      "arktrace_v1_thread_itid","arktrace_v1_thread_state_itid_ts",
      "arktrace_v1_thread_state_ts_cpu","arktrace_v1_thread_tid_ipid",
      "arktrace_v2_callstack_callid_ts_cover_optional",
      "arktrace_v2_callstack_callid_ts_id_dur","arktrace_v3_callstack_ts_id_dur_callid",
      "arktrace_v2_cpu_measure_filter_id",
      "arktrace_v2_process_ipid_pid_name","arktrace_v2_process_measure_filter_id",
      "arktrace_v2_sched_slice_cpu_ts_cover_optional",
      "arktrace_v2_sched_slice_cpu_ts_id_dur_itid",
      "arktrace_v2_thread_itid_tid_name_ipid",
      "arktrace_v2_thread_state_itid_ts_cover_cpu",
      "arktrace_v2_thread_state_itid_ts_id_dur"
    ]) == [])
    and ([
      "arktrace_v1_process_ipid","arktrace_v2_process_ipid_pid_name",
      "arktrace_v1_thread_itid","arktrace_v2_thread_itid_tid_name_ipid",
      "arktrace_v1_sched_slice_ts_cpu","arktrace_v2_sched_slice_cpu_ts_id_dur_itid",
      "arktrace_v1_thread_state_itid_ts","arktrace_v2_thread_state_itid_ts_id_dur",
      "arktrace_v1_callstack_callid_ts","arktrace_v2_callstack_callid_ts_id_dur",
      "arktrace_v3_callstack_ts_id_dur_callid"
    ] - .diagnostics.applicableIndexNames == [])
    and (.diagnostics.persistentIndexNames == .diagnostics.applicableIndexNames)
' "$partial_evidence" >/dev/null || fail "benchmark evidence does not satisfy Phase 3 budgets"

if [ "$fixture_class" = medium ]; then
    jq -e --slurpfile lock "$fixture_lock" '
        .diagnostics.tableRowCounts == $lock[0].medium.requiredRows
    ' "$partial_evidence" >/dev/null || fail "medium semantic row counts drifted"
else
    jq -e --slurpfile provenance "$provenance" '
        .traceSHA256 == $provenance[0].trace.sha256
        and .traceByteCount == $provenance[0].trace.byteCount
        and .traceDurationNs == $provenance[0].trace.durationNs
        and .diagnostics.tableRowCounts == $provenance[0].trace.requiredRows
    ' "$partial_evidence" >/dev/null || fail "large semantic evidence drifted"

    cancellation_evidence="$temporary_root/large-cancellation.json"
    cancellation_log="$temporary_root/large-cancellation.log"
    if ! ARKTRACE_PHASE3_LARGE_CANCELLATION=1 \
        ARKTRACE_PHASE3_TRACE="$trace" \
        ARKTRACE_PHASE3_LARGE_CANCELLATION_EVIDENCE="$cancellation_evidence" \
        ARKTRACE_TRACE_STREAMER="$parser" \
        CI=true swift test -c release --skip-build \
            --filter ParserIntegrationTests.testPhase3LargeTraceCancellationLeavesNoReadyOrPrivateBuildWhenRequested \
            >"$cancellation_log" 2>&1
    then
        bounded_failure_summary "$cancellation_log"
        fail "large cancellation XCTest failed"
    fi
    executed=$(grep -c "Test Case '-\[ArkTraceIntegrationTests.ParserIntegrationTests testPhase3LargeTraceCancellationLeavesNoReadyOrPrivateBuildWhenRequested\]' passed" \
        "$cancellation_log" || true)
    [ "$executed" -eq 1 ] || fail "large cancellation filter did not execute exactly one XCTest"
    if grep -Ei 'skipped|skip recorded' "$cancellation_log" >/dev/null; then
        fail "large cancellation XCTest was skipped"
    fi
    jq -e --slurpfile provenance "$provenance" '
        .formatVersion == 1 and .fixtureClass == "large"
        and .testExecuted == true and .cancellationObserved == true
        and .residualCount == 0
        and .traceSHA256 == $provenance[0].trace.sha256
        and .traceByteCount == $provenance[0].trace.byteCount
    ' "$cancellation_evidence" >/dev/null \
        || fail "large cancellation evidence is incomplete"
fi

mv -n "$partial_evidence" "$evidence_output" \
    || fail "benchmark evidence publication failed"
[ ! -e "$partial_evidence" ] && [ -f "$evidence_output" ] \
    || fail "benchmark evidence publication did not complete"
evidence_sha=$(shasum -a 256 "$evidence_output" | awk '{print $1}')
printf 'Phase 3 %s benchmark passed: evidence=%s sha256=%s\n' \
    "$fixture_class" "$evidence_name" "$evidence_sha"
