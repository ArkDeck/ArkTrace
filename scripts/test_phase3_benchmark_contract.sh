#!/bin/sh
set -eu

fail() {
    printf 'Phase 3 benchmark contract test failed: %s\n' "$1" >&2
    exit 1
}

source_scripts=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_root=$(CDPATH= cd -- "$source_scripts/.." && pwd)
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/arktrace-benchmark-contract.XXXXXX")
cleanup() { rm -rf -- "$temporary_root"; }
trap cleanup EXIT HUP INT TERM
repository="$temporary_root/repository"
mkdir -p "$repository/scripts" "$repository/Fixtures/release-evidence" \
    "$repository/ThirdParty/TraceStreamer/macx"
cp "$source_scripts/benchmark_phase3.sh" \
    "$source_scripts/verify_htrace_integrity.py" \
    "$source_scripts/source_tree_identity.py" \
    "$source_scripts/verify_phase3_evidence_times.py" \
    "$source_scripts/verify_phase3_review_manifest.jq" \
    "$source_scripts/verify_phase3_query_plans.jq" \
    "$source_scripts/verify_phase4_workloads.jq" \
    "$source_scripts/phase3_shell_safety.sh" "$repository/scripts/"
chmod +x "$repository/scripts/"*

issuer_key_relative=Fixtures/release-evidence/phase3-large/grant-issuer-public.pem
issuer_key="$source_root/$issuer_key_relative"
trust_configuration="$source_root/Config/ArkTraceReleaseReviewers.json"
[ -f "$issuer_key" ] && [ ! -L "$issuer_key" ] \
    || fail "grant issuer public key is not a regular non-symlink"
git -C "$source_root" ls-files --error-unmatch "$issuer_key_relative" \
    >/dev/null 2>&1 || fail "grant issuer public key is not tracked"
git -C "$source_root" cat-file -e "HEAD:$issuer_key_relative" 2>/dev/null \
    || fail "grant issuer public key is absent from HEAD"
issuer_key_sha=$(shasum -a 256 "$issuer_key" | awk '{print $1}')
issuer_head_sha=$(git -C "$source_root" show "HEAD:$issuer_key_relative" \
    | shasum -a 256 | awk '{print $1}')
[ "$issuer_key_sha" = "$issuer_head_sha" ] \
    || fail "grant issuer public key differs from HEAD"
[ "$issuer_key_sha" = "$(jq -er \
    '.redistributionGrantIssuerPublicKeySHA256' "$trust_configuration")" ] \
    || fail "grant issuer public key differs from the trusted SHA"
issuer_key_bits=$(openssl pkey -pubin -in "$issuer_key" -text_pub -noout 2>/dev/null \
    | sed -n 's/^Public-Key: (\([0-9][0-9]*\) bit)$/\1/p')
[ "$issuer_key_bits" -ge 3072 ] 2>/dev/null \
    || fail "grant issuer public key is weaker than RSA-3072"
mutated_issuer_key="$temporary_root/mutated-grant-issuer-public.pem"
cp "$issuer_key" "$mutated_issuer_key"
printf '\n' >>"$mutated_issuer_key"
[ "$(shasum -a 256 "$mutated_issuer_key" | awk '{print $1}')" != \
    "$issuer_key_sha" ] || fail "mutated grant issuer public key reused the trusted SHA"

reviewer_key_relative=Fixtures/release-evidence/phase3-large/reviewer-public.pem
reviewer_key="$source_root/$reviewer_key_relative"
[ -f "$reviewer_key" ] && [ ! -L "$reviewer_key" ] \
    || fail "large reviewer public key is not a regular non-symlink"
git -C "$source_root" ls-files --error-unmatch "$reviewer_key_relative" \
    >/dev/null 2>&1 || fail "large reviewer public key is not tracked"
git -C "$source_root" cat-file -e "HEAD:$reviewer_key_relative" 2>/dev/null \
    || fail "large reviewer public key is absent from HEAD"
reviewer_key_sha=$(shasum -a 256 "$reviewer_key" | awk '{print $1}')
reviewer_head_sha=$(git -C "$source_root" show "HEAD:$reviewer_key_relative" \
    | shasum -a 256 | awk '{print $1}')
[ "$reviewer_key_sha" = "$reviewer_head_sha" ] \
    || fail "large reviewer public key differs from HEAD"
[ "$reviewer_key_sha" = "$(jq -er \
    '.largeTraceReviewerPublicKeySHA256' "$trust_configuration")" ] \
    || fail "large reviewer public key differs from the trusted SHA"
reviewer_key_bits=$(openssl pkey -pubin -in "$reviewer_key" -text_pub -noout 2>/dev/null \
    | sed -n 's/^Public-Key: (\([0-9][0-9]*\) bit)$/\1/p')
[ "$reviewer_key_bits" -ge 3072 ] 2>/dev/null \
    || fail "large reviewer public key is weaker than RSA-3072"
[ "$reviewer_key_sha" != "$issuer_key_sha" ] \
    || fail "large reviewer and grant issuer reused one trust key"
mutated_reviewer_key="$temporary_root/mutated-large-reviewer-public.pem"
cp "$reviewer_key" "$mutated_reviewer_key"
printf '\n' >>"$mutated_reviewer_key"
[ "$(shasum -a 256 "$mutated_reviewer_key" | awk '{print $1}')" != \
    "$reviewer_key_sha" ] || fail "mutated large reviewer key reused the trusted SHA"

(
    . "$repository/scripts/phase3_shell_safety.sh"
    arktrace_is_fully_allocated_regular_file \
        "$repository/scripts/benchmark_phase3.sh"
) || fail "ordinary physical benchmark script was classified as sparse"
sparse_probe="$temporary_root/sparse-large-probe"
/usr/bin/truncate -s 1048576 "$sparse_probe"
if (
    . "$repository/scripts/phase3_shell_safety.sh"
    arktrace_is_fully_allocated_regular_file "$sparse_probe"
); then
    fail "sparse file passed the shared large-trace allocation contract"
fi

PYTHONDONTWRITEBYTECODE=1 python3 -B - \
    "$repository/scripts/source_tree_identity.py" "$temporary_root" <<'PY'
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("source_identity", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
root = pathlib.Path(sys.argv[2])
regular = root / "identity-source"
regular.write_bytes(b"source")
def grow():
    with regular.open("ab") as handle:
        handle.write(b"growth")
try:
    module.hash_regular_file(regular, after_open=grow)
except SystemExit:
    pass
else:
    raise SystemExit("growing source file was accepted")
target = root / "identity-target"
target.write_bytes(b"target")
link = root / "identity-link"
link.symlink_to(target)
try:
    module.hash_regular_file(link)
except OSError:
    pass
else:
    raise SystemExit("source symlink was accepted")
outside = root / "identity-outside"
outside.mkdir()
(outside / "file").write_bytes(b"outside")
physical_parent = root / "identity-physical-parent"
physical_parent.mkdir()
(physical_parent / "file").write_bytes(b"inside")
root_fd = __import__("os").open(root, __import__("os").O_RDONLY | __import__("os").O_DIRECTORY)
try:
    physical_parent.rename(root / "identity-displaced-parent")
    (root / "identity-physical-parent").symlink_to(outside, target_is_directory=True)
    try:
        module.hash_regular_file(
            root_descriptor=root_fd, raw_path=b"identity-physical-parent/file"
        )
    except OSError:
        pass
    else:
        raise SystemExit("source parent symlink was accepted")
finally:
    __import__("os").close(root_fd)
oversized = root / "identity-oversized"
with oversized.open("wb") as handle:
    handle.truncate(module.MAX_SOURCE_FILE_BYTES + 1)
try:
    module.hash_regular_file(oversized)
except SystemExit:
    pass
else:
    raise SystemExit("oversized source file was accepted")
try:
    module.add_total_bytes(module.MAX_SOURCE_TOTAL_BYTES, 1)
except SystemExit:
    pass
else:
    raise SystemExit("oversized source projection was accepted")
PY

valid_workload="$temporary_root/valid-workload.json"
jq -n '{contextWorkload:{
  name:"timestamp-default-v1",
  time:{timestampNs:10200000000,windowBeforeNs:50000000,windowAfterNs:50000000},
  normalizedRange:{startNs:10150000000,endNs:10250000000},
  filters:{cpu:null,processKey:null,pid:null,threadKey:null,tid:null,
    rawState:null,normalizedState:null,name:null,nameMatch:"exact",
    minimumDurationNs:null,depth:null,counterFilterID:null},
  maximumEvents:10000,maximumRows:10000,maximumOutputBytes:8388608,
  timeoutSeconds:30,timeoutAttoseconds:0
},analysisWorkload:{
  name:"agent-range-default-v1",
  range:{startNs:10100000000,endNs:10300000000},
  globalMaximumRows:10000,
  parameters:{
    filters:{cpu:null,processKey:null,pid:null,threadKey:null,tid:null,
      rawState:null,normalizedState:null,name:null,nameMatch:"exact",
      minimumDurationNs:null,depth:null,counterFilterID:null},
    maximumCPUSlices:10000,maximumProcessSlices:10000,
    maximumThreadSlices:10000,maximumStateIntervals:10000,
    maximumNamedSlices:10000,maximumSchedulingEvents:10000,
    maximumHotEvents:10000,topProcessLimit:1000,topThreadLimit:1000,
    longSliceLimit:1000,schedulingSampleLimit:1000,hotIntervalLimit:1000,
    hotBucketCount:100,minimumLongSliceDurationNs:0,
    timeoutSeconds:30,timeoutAttoseconds:0
  }
}}' >"$valid_workload"
jq -e -f "$repository/scripts/verify_phase4_workloads.jq" \
    "$valid_workload" >/dev/null \
    || fail "reviewed Phase 4 workloads were rejected"
for mutation in context-range context-events context-rows context-bytes context-timeout \
    analysis-range analysis-budget analysis-output analysis-timeout
do
    candidate="$temporary_root/workload-$mutation.json"
    case "$mutation" in
        context-range) jq '.contextWorkload.normalizedRange.startNs += 1' "$valid_workload" >"$candidate" ;;
        context-events) jq '.contextWorkload.maximumEvents -= 1' "$valid_workload" >"$candidate" ;;
        context-rows) jq '.contextWorkload.maximumRows -= 1' "$valid_workload" >"$candidate" ;;
        context-bytes) jq '.contextWorkload.maximumOutputBytes -= 1' "$valid_workload" >"$candidate" ;;
        context-timeout) jq '.contextWorkload.timeoutSeconds = 10' "$valid_workload" >"$candidate" ;;
        analysis-range) jq '.analysisWorkload.range.startNs += 1' "$valid_workload" >"$candidate" ;;
        analysis-budget) jq '.analysisWorkload.parameters.maximumCPUSlices -= 1' "$valid_workload" >"$candidate" ;;
        analysis-output) jq '.analysisWorkload.parameters.topProcessLimit -= 1' "$valid_workload" >"$candidate" ;;
        analysis-timeout) jq '.analysisWorkload.parameters.timeoutSeconds = 10' "$valid_workload" >"$candidate" ;;
    esac
    if jq -e -f "$repository/scripts/verify_phase4_workloads.jq" \
        "$candidate" >/dev/null
    then
        fail "drifted Phase 4 workload was accepted: $mutation"
    fi
done

time_acquisition="$temporary_root/time-acquisition.json"
time_grant="$temporary_root/time-grant.json"
time_review="$temporary_root/time-review.json"
jq -n '{captureStartedAt:"2026-08-14T00:00:00Z",captureEndedAt:"2026-08-14T00:10:00Z",reviewedAt:"2026-08-14T01:00:00Z",reviewedBy:"independent-reviewer"}' \
    >"$time_acquisition"
jq -n '{issuedAt:"2026-08-13T00:00:00Z"}' >"$time_grant"
jq -n '{reviewedAt:"2026-08-14T01:00:00Z",reviewer:"independent-reviewer"}' \
    >"$time_review"
PYTHONDONTWRITEBYTECODE=1 python3 -B \
    "$repository/scripts/verify_phase3_evidence_times.py" \
    "$time_acquisition" "$time_grant" "$time_review" \
    || fail "consistent canonical review timestamps were rejected"
for mutation in reversed invalid-date reviewer-mismatch time-mismatch; do
    candidate="$temporary_root/time-$mutation.json"
    case "$mutation" in
        reversed) jq '.captureEndedAt="2026-08-14T02:00:00Z"' "$time_acquisition" >"$candidate" ;;
        invalid-date) jq '.captureStartedAt="2026-02-30T00:00:00Z"' "$time_acquisition" >"$candidate" ;;
        reviewer-mismatch) jq '.reviewedBy="different-reviewer"' "$time_acquisition" >"$candidate" ;;
        time-mismatch) jq '.reviewedAt="2026-08-14T01:00:01Z"' "$time_acquisition" >"$candidate" ;;
    esac
    if PYTHONDONTWRITEBYTECODE=1 python3 -B \
        "$repository/scripts/verify_phase3_evidence_times.py" \
        "$candidate" "$time_grant" "$time_review" >/dev/null 2>&1
    then
        fail "inconsistent evidence timestamp was accepted: $mutation"
    fi
done

review_trace_sha=$(printf reviewed-trace | shasum -a 256 | awk '{print $1}')
review_acquisition_sha=$(printf reviewed-acquisition | shasum -a 256 | awk '{print $1}')
review_integrity_sha=$(printf reviewed-integrity | shasum -a 256 | awk '{print $1}')
review_grant_sha=$(printf reviewed-grant | shasum -a 256 | awk '{print $1}')
valid_review_manifest="$temporary_root/valid-review-manifest.json"
jq -n \
    --arg traceSHA256 "$review_trace_sha" \
    --arg acquisitionRecordSHA256 "$review_acquisition_sha" \
    --arg integrityReportSHA256 "$review_integrity_sha" \
    --arg redistributionGrantSHA256 "$review_grant_sha" '
  {acquisitionRecordSHA256:$acquisitionRecordSHA256,formatVersion:1,
   integrityReportSHA256:$integrityReportSHA256,
   redistributionGrantSHA256:$redistributionGrantSHA256,
   reviewedAt:"2026-08-14T01:00:00Z",reviewer:"independent-reviewer",
   traceByteCount:524288001,traceSHA256:$traceSHA256}
' >"$valid_review_manifest"
verify_review_manifest() {
    jq -e \
        --arg traceSHA "$review_trace_sha" \
        --arg traceBytes 524288001 \
        --arg acquisitionSHA "$review_acquisition_sha" \
        --arg integritySHA "$review_integrity_sha" \
        --arg grantSHA "$review_grant_sha" \
        -f "$repository/scripts/verify_phase3_review_manifest.jq" "$1" \
        >/dev/null
}
verify_review_manifest "$valid_review_manifest" \
    || fail "complete signed review manifest was rejected"
for mutation in missing-format extra-self-attestation trace-drift; do
    candidate="$temporary_root/review-manifest-$mutation.json"
    case "$mutation" in
        missing-format) jq 'del(.formatVersion)' "$valid_review_manifest" >"$candidate" ;;
        extra-self-attestation) jq '.selfAttested=true' "$valid_review_manifest" >"$candidate" ;;
        trace-drift) jq '.traceSHA256="0000000000000000000000000000000000000000000000000000000000000000"' "$valid_review_manifest" >"$candidate" ;;
    esac
    if verify_review_manifest "$candidate"; then
        fail "invalid signed review manifest was accepted: $mutation"
    fi
done
printf '#!/bin/sh\nexit 0\n' \
    >"$repository/ThirdParty/TraceStreamer/macx/trace_streamer"
chmod +x "$repository/ThirdParty/TraceStreamer/macx/trace_streamer"
locked_parser_sha=$(shasum -a 256 \
    "$repository/ThirdParty/TraceStreamer/macx/trace_streamer" | awk '{print $1}')
jq -n --arg sha "$locked_parser_sha" '{binarySHA256:$sha}' \
    >"$repository/ThirdParty/TraceStreamer/macx/manifest.json"
trace="$temporary_root/caller-large.htrace"
printf 'not a real large trace\n' >"$trace"

# This is the former fail-open shape: every important property is asserted by
# the same caller instead of being derived from bytes and independently bound
# records. Even plausible values must not pass the current schema boundary.
provenance="$repository/Fixtures/release-evidence/large.json"
jq -n --arg sha "$(printf fake | shasum -a 256 | awk '{print $1}')" '
{
  formatVersion:3,fixtureClass:"large",
  trace:{sha256:$sha,byteCount:524288001,durationNs:1,requiredRows:{process:1,thread:1,sched_slice:1,thread_state:1,callstack:1}},
  acquisition:{recordPath:"Fixtures/acquisition.json",recordSHA256:$sha},
  integrity:{reportPath:"Fixtures/integrity.json",reportSHA256:$sha},
  license:{path:"Fixtures/license.txt",sha256:$sha,redistributionGrantPath:"Fixtures/grant.json",redistributionGrantSHA256:$sha,grantSignaturePath:"Fixtures/grant.sig",grantIssuerPublicKeyPath:"Fixtures/grant.pem",grantIssuerPublicKeySHA256:$sha},
  review:{manifestPath:"Fixtures/review.json",manifestSHA256:$sha,signaturePath:"Fixtures/review.sig",reviewerPublicKeyPath:"Fixtures/review.pem",reviewerPublicKeySHA256:$sha}
}
' >"$provenance"
mkdir -p "$repository/Config"
jq -n --arg trusted "$(printf trusted | shasum -a 256 | awk '{print $1}')" '
 {formatVersion:1,
  largeTraceReviewerPublicKeySHA256:$trusted,
  redistributionGrantIssuerPublicKeySHA256:$trusted}
' >"$repository/Config/ArkTraceReleaseReviewers.json"
provenance_sha=$(shasum -a 256 "$provenance" | awk '{print $1}')
jq -n --arg path 'Fixtures/release-evidence/large.json' --arg sha "$provenance_sha" '
{
 formatVersion:1,
 upstream:{repository:"https://invalid.example",revision:"0000000000000000000000000000000000000000",license:"Apache-2.0",licensePath:"LICENSE",licenseBlob:"0000000000000000000000000000000000000000",licenseSHA256:"0000000000000000000000000000000000000000000000000000000000000000",licenseByteCount:1},
 medium:{path:"medium",blob:"0000000000000000000000000000000000000000",sha256:"0000000000000000000000000000000000000000000000000000000000000000",byteCount:52428801,requiredRows:{process:1,thread:1,sched_slice:1,thread_state:1,callstack:1}},
 large:{minimumByteCount:524288001,maximumByteCount:2147483648,reviewedEvidencePath:$path,reviewedEvidenceSHA256:$sha,requiredEnvironmentVariable:"ARKTRACE_LARGE_TRACE",policy:"reviewed"}
}
' >"$repository/Fixtures/phase3-performance-fixtures.json"
git -C "$repository" init -q
git -C "$repository" add Config Fixtures
git -C "$repository" -c user.name='ArkTrace Contract' \
    -c user.email='contract@invalid.example' commit -qm 'lock benchmark fixtures'

first_tree_sha=$(PYTHONDONTWRITEBYTECODE=1 python3 -B \
    "$repository/scripts/source_tree_identity.py" "$repository")
printf 'candidate byte A\n' >"$repository/source-identity-probe.txt"
untracked_tree_sha=$(PYTHONDONTWRITEBYTECODE=1 python3 -B \
    "$repository/scripts/source_tree_identity.py" "$repository")
[ "$first_tree_sha" != "$untracked_tree_sha" ] \
    || fail "dirty source bytes did not change the audited source identity"
git -C "$repository" add source-identity-probe.txt
staged_tree_sha=$(PYTHONDONTWRITEBYTECODE=1 python3 -B \
    "$repository/scripts/source_tree_identity.py" "$repository")
[ "$untracked_tree_sha" = "$staged_tree_sha" ] \
    || fail "staging unchanged source bytes changed the audited source identity"
git -C "$repository" -c user.name='ArkTrace Contract' \
    -c user.email='contract@invalid.example' commit -qm 'classify source identity probe'
committed_tree_sha=$(PYTHONDONTWRITEBYTECODE=1 python3 -B \
    "$repository/scripts/source_tree_identity.py" "$repository")
[ "$staged_tree_sha" = "$committed_tree_sha" ] \
    || fail "committing unchanged source bytes changed the audited source identity"

printf 'candidate byte B\n' >"$repository/source-identity-probe.txt"
changed_bytes_tree_sha=$(PYTHONDONTWRITEBYTECODE=1 python3 -B \
    "$repository/scripts/source_tree_identity.py" "$repository")
[ "$committed_tree_sha" != "$changed_bytes_tree_sha" ] \
    || fail "same HEAD with different untracked bytes reused a source identity"
git -C "$repository" checkout -q -- source-identity-probe.txt
chmod +x "$repository/source-identity-probe.txt"
executable_tree_sha=$(PYTHONDONTWRITEBYTECODE=1 python3 -B \
    "$repository/scripts/source_tree_identity.py" "$repository")
[ "$committed_tree_sha" != "$executable_tree_sha" ] \
    || fail "source executable mode change reused a source identity"
chmod -x "$repository/source-identity-probe.txt"
restored_tree_sha=$(PYTHONDONTWRITEBYTECODE=1 python3 -B \
    "$repository/scripts/source_tree_identity.py" "$repository")
[ "$committed_tree_sha" = "$restored_tree_sha" ] \
    || fail "restoring source bytes and mode did not restore source identity"

valid_plan="$temporary_root/valid-plan.json"
jq -n '{diagnostics:{queryPlans:{
  "viewport.cpu.detail":["SEARCH s USING COVERING INDEX arktrace_v2_sched_slice_cpu_ts_id_dur_itid (cpu=?)","SEARCH t USING COVERING INDEX arktrace_v2_thread_itid_tid_name_ipid (itid=?)","SEARCH p USING COVERING INDEX arktrace_v2_process_ipid_pid_name (ipid=?)"],
  "viewport.threadState.detail":["SEARCH s USING COVERING INDEX arktrace_v2_thread_state_itid_ts_id_dur (itid=?)","SEARCH t USING COVERING INDEX arktrace_v2_thread_itid_tid_name_ipid (itid=?)","SEARCH p USING COVERING INDEX arktrace_v2_process_ipid_pid_name (ipid=?)"],
  "viewport.namedSlice.detail":["SEARCH s USING COVERING INDEX arktrace_v2_callstack_callid_ts_id_dur (callid=?)","SEARCH t USING COVERING INDEX arktrace_v2_thread_itid_tid_name_ipid (itid=?)","SEARCH p USING COVERING INDEX arktrace_v2_process_ipid_pid_name (ipid=?)"],
  "viewport.cpu.density":["SEARCH s USING COVERING INDEX arktrace_v3_sched_slice_cpu_ts_dur (cpu=?)","USE TEMP B-TREE FOR GROUP BY"],
  "viewport.threadState.density":["SEARCH s USING COVERING INDEX arktrace_v3_thread_state_itid_ts_dur (itid=?)","USE TEMP B-TREE FOR GROUP BY"],
  "viewport.namedSlice.density":["SEARCH s USING COVERING INDEX arktrace_v3_callstack_callid_ts_dur (callid=?)","USE TEMP B-TREE FOR GROUP BY"]
}}}' >"$valid_plan"
jq -e -f "$repository/scripts/verify_phase3_query_plans.jq" "$valid_plan" >/dev/null \
    || fail "exact reviewed query plan was rejected"
jq 'del(.diagnostics.queryPlans["viewport.cpu.density"][1])' \
    "$valid_plan" >"$temporary_root/missing-group-plan.json"
if jq -e -f "$repository/scripts/verify_phase3_query_plans.jq" \
    "$temporary_root/missing-group-plan.json" >/dev/null
then
    fail "density plan without its bounded GROUP BY shape was accepted"
fi
jq '.diagnostics.queryPlans["viewport.cpu.density"][1] = "USE TEMP B-TREE FOR ORDER BY"' \
    "$valid_plan" >"$temporary_root/wrong-temp-plan.json"
if jq -e -f "$repository/scripts/verify_phase3_query_plans.jq" \
    "$temporary_root/wrong-temp-plan.json" >/dev/null
then
    fail "density plan with a different temporary plan shape was accepted"
fi
jq '.diagnostics.queryPlans["viewport.cpu.detail"][0] |= sub("itid";"itid_evil")' \
    "$valid_plan" >"$temporary_root/evil-plan.json"
if jq -e -f "$repository/scripts/verify_phase3_query_plans.jq" \
    "$temporary_root/evil-plan.json" >/dev/null
then
    fail "suffixed covering index was accepted"
fi
jq '.diagnostics.queryPlans["viewport.cpu.detail"] += ["SEARCH x USING COVERING INDEX arktrace_v2_sched_slice_cpu_ts_id_dur_itid (cpu=?)"]' \
    "$valid_plan" >"$temporary_root/extra-search-plan.json"
if jq -e -f "$repository/scripts/verify_phase3_query_plans.jq" \
    "$temporary_root/extra-search-plan.json" >/dev/null
then
    fail "extra indexed search was accepted"
fi
jq '.diagnostics.queryPlans["viewport.cpu.detail"] += ["SCAN evil"]' \
    "$valid_plan" >"$temporary_root/extra-scan-plan.json"
if jq -e -f "$repository/scripts/verify_phase3_query_plans.jq" \
    "$temporary_root/extra-scan-plan.json" >/dev/null
then
    fail "extra table scan was accepted"
fi
jq '.diagnostics.queryPlans["viewport.cpu.density"] += ["SEARCH evil"]' \
    "$valid_plan" >"$temporary_root/unindexed-search-plan.json"
if jq -e -f "$repository/scripts/verify_phase3_query_plans.jq" \
    "$temporary_root/unindexed-search-plan.json" >/dev/null
then
    fail "unindexed search was accepted"
fi
jq '.diagnostics.queryPlans["viewport.cpu.detail"][0] = "garbage USING COVERING INDEX arktrace_v2_sched_slice_cpu_ts_id_dur_itid (cpu=?)"' \
    "$valid_plan" >"$temporary_root/garbage-prefix-plan.json"
if jq -e -f "$repository/scripts/verify_phase3_query_plans.jq" \
    "$temporary_root/garbage-prefix-plan.json" >/dev/null
then
    fail "non-SEARCH text containing an index name was accepted"
fi

alternate="$temporary_root/alternate-parser"
mkdir -p "$alternate"
cp "$repository/ThirdParty/TraceStreamer/macx/trace_streamer" "$alternate/trace_streamer"
printf '# alternate bytes\n' >>"$alternate/trace_streamer"
chmod +x "$alternate/trace_streamer"
alternate_sha=$(shasum -a 256 "$alternate/trace_streamer" | awk '{print $1}')
jq -n --arg sha "$alternate_sha" '{binarySHA256:$sha}' >"$alternate/manifest.json"
if ARKTRACE_TRACE_STREAMER="$alternate/trace_streamer" \
    "$repository/scripts/benchmark_phase3.sh" medium \
    >/dev/null 2>"$temporary_root/alternate-error.log"
then
    fail "self-consistent alternate parser was accepted for release evidence"
fi
grep -F 'selected TraceStreamer bytes differ from the repository lock' \
    "$temporary_root/alternate-error.log" >/dev/null \
    || fail "alternate parser rejection was not stable"

foreign_output="$repository/foreign-evidence.json"
printf 'tracked evidence sentinel\n' >"$foreign_output"
git -C "$repository" add foreign-evidence.json
foreign_sha=$(shasum -a 256 "$foreign_output" | awk '{print $1}')
if ARKTRACE_PHASE3_EVIDENCE_OUTPUT="$foreign_output" \
    "$repository/scripts/benchmark_phase3.sh" medium >/dev/null 2>&1
then
    fail "benchmark accepted a repository file as mutable evidence output"
fi
[ "$(shasum -a 256 "$foreign_output" | awk '{print $1}')" = "$foreign_sha" ] \
    || fail "benchmark modified a foreign tracked output"

collision="${TMPDIR:-/tmp}/arktrace-phase3-evidence-collision-$$.json"
printf 'temporary collision sentinel\n' >"$collision"
collision_sha=$(shasum -a 256 "$collision" | awk '{print $1}')
if ARKTRACE_PHASE3_EVIDENCE_OUTPUT="$collision" \
    "$repository/scripts/benchmark_phase3.sh" medium >/dev/null 2>&1
then
    fail "benchmark accepted an unowned fixed temporary output"
fi
[ "$(shasum -a 256 "$collision" | awk '{print $1}')" = "$collision_sha" ] \
    || fail "benchmark deleted or modified a colliding temporary file"
rm -f -- "$collision"

if ARKTRACE_LARGE_TRACE="$trace" \
    ARKTRACE_LARGE_TRACE_EVIDENCE="$provenance" \
    "$repository/scripts/benchmark_phase3.sh" large \
    >/dev/null 2>"$temporary_root/error.log"
then
    fail "caller-authored large self-attestation was accepted"
fi
[ "$(stat -f '%z' "$temporary_root/error.log")" -le 1024 ] \
    || fail "rejection diagnostic exceeded its byte bound"
grep -F 'large trace reviewer is not trusted' "$temporary_root/error.log" >/dev/null \
    || { cat "$temporary_root/error.log" >&2; fail "self-attestation rejection was not stable"; }
if grep -F "$temporary_root" "$temporary_root/error.log" >/dev/null; then
    fail "rejection diagnostic disclosed an absolute path"
fi

printf 'Phase 3 benchmark contract test passed: signed review schema enforced; self-attested large provenance rejected\n'
