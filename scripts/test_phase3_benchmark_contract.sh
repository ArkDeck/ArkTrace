#!/bin/sh
set -eu

fail() {
    printf 'Phase 3 benchmark contract test failed: %s\n' "$1" >&2
    exit 1
}

source_scripts=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
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
    "$source_scripts/verify_phase3_query_plans.jq" \
    "$source_scripts/phase3_shell_safety.sh" "$repository/scripts/"
chmod +x "$repository/scripts/"*

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
 {formatVersion:1,accessibilityReviewerPublicKeySHA256:null,
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
second_tree_sha=$(PYTHONDONTWRITEBYTECODE=1 python3 -B \
    "$repository/scripts/source_tree_identity.py" "$repository")
[ "$first_tree_sha" != "$second_tree_sha" ] \
    || fail "dirty source bytes did not change the audited source identity"
printf 'candidate byte B\n' >"$repository/source-identity-probe.txt"
third_tree_sha=$(PYTHONDONTWRITEBYTECODE=1 python3 -B \
    "$repository/scripts/source_tree_identity.py" "$repository")
[ "$second_tree_sha" != "$third_tree_sha" ] \
    || fail "same HEAD with different untracked bytes reused a source identity"
rm -f -- "$repository/source-identity-probe.txt"

valid_plan="$temporary_root/valid-plan.json"
jq -n '{diagnostics:{queryPlans:{
  "viewport.cpu.detail":["SEARCH s USING COVERING INDEX arktrace_v2_sched_slice_cpu_ts_id_dur_itid (cpu=?)","SEARCH t USING COVERING INDEX arktrace_v2_thread_itid_tid_name_ipid (itid=?)","SEARCH p USING COVERING INDEX arktrace_v2_process_ipid_pid_name (ipid=?)"],
  "viewport.threadState.detail":["SEARCH s USING COVERING INDEX arktrace_v2_thread_state_itid_ts_id_dur (itid=?)","SEARCH t USING COVERING INDEX arktrace_v2_thread_itid_tid_name_ipid (itid=?)","SEARCH p USING COVERING INDEX arktrace_v2_process_ipid_pid_name (ipid=?)"],
  "viewport.namedSlice.detail":["SEARCH s USING COVERING INDEX arktrace_v2_callstack_callid_ts_id_dur (callid=?)","SEARCH t USING COVERING INDEX arktrace_v2_thread_itid_tid_name_ipid (itid=?)","SEARCH p USING COVERING INDEX arktrace_v2_process_ipid_pid_name (ipid=?)"],
  "viewport.cpu.density":["SEARCH s USING COVERING INDEX arktrace_v2_sched_slice_cpu_ts_id_dur_itid (cpu=?)","USE TEMP B-TREE FOR GROUP BY"],
  "viewport.threadState.density":["SEARCH s USING COVERING INDEX arktrace_v2_thread_state_itid_ts_id_dur (itid=?)","USE TEMP B-TREE FOR GROUP BY"],
  "viewport.namedSlice.density":["SEARCH s USING COVERING INDEX arktrace_v2_callstack_callid_ts_id_dur (callid=?)","USE TEMP B-TREE FOR GROUP BY"]
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

printf 'Phase 3 benchmark contract test passed: self-attested large provenance rejected\n'
