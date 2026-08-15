#!/bin/sh
set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd -P)

fail() {
    printf 'Phase 4 batch gate failed: %s\n' "$1" >&2
    exit 1
}

. "$script_directory/phase3_shell_safety.sh"
arktrace_prepare_reviewed_roots "$repository_root"
evidence_directory=$(arktrace_secure_owned_directory \
    "$ARKTRACE_REVIEWED_BUILD_ROOT/phase4-evidence" \
    .arktrace-phase3-evidence-v1 "Phase 4 evidence")

"$script_directory/test_phase3_batch1.sh"

wrong_medium=$(mktemp "$ARKTRACE_REVIEWED_TEMP_ROOT/arktrace-phase4-wrong-medium.XXXXXX")
cleanup_wrong_medium() {
    rm -f -- "$wrong_medium"
}
trap cleanup_wrong_medium EXIT HUP INT TERM
if ARKTRACE_PHASE4_MEDIUM_TRACE="$wrong_medium" \
    "$script_directory/test_phase4_agent_contract.sh" >/dev/null 2>&1
then
    fail "synthetic medium override passed the reviewed fixture identity gate"
fi
cleanup_wrong_medium
trap - EXIT HUP INT TERM

"$script_directory/test_phase4_agent_contract.sh"

warmup_evidence="$evidence_directory/arktrace-phase3-medium-phase4-warmup-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
ARKTRACE_PHASE3_WARMUP_ONLY=1 \
ARKTRACE_PHASE3_EVIDENCE_OUTPUT="$warmup_evidence" \
    "$script_directory/benchmark.sh" phase4 medium
[ ! -e "$warmup_evidence" ] && [ ! -L "$warmup_evidence" ] \
    || fail "benchmark warm-up published release evidence"

evidence="$evidence_directory/arktrace-phase3-medium-phase4-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
ARKTRACE_PHASE3_EVIDENCE_OUTPUT="$evidence" \
    "$script_directory/benchmark.sh" phase4 medium
jq -e '
    .fixtureClass == "medium"
    and .iterations == 20
    and .contextP95Ms <= 1000
    and .deterministicAnalysisP95Ms <= 3000
    and .peakRSSBytes <= 1610612736
    and .measuredRows.contextEvents > 0
    and .measuredRows.contextBytes > 0
    and .measuredRows.deterministicAnalysisRows > 0
' "$evidence" >/dev/null \
    || fail "benchmark evidence is invalid"
jq -e -f "$script_directory/verify_phase4_workloads.jq" \
    "$evidence" >/dev/null \
    || fail "benchmark Context or analysis workload is invalid"

printf 'Phase 4 batch gate passed: inherited candidate + real Agent CLI + production Context/Analysis performance\n'
