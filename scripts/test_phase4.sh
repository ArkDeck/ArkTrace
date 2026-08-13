#!/bin/sh
set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd -P)
. "$script_directory/phase3_shell_safety.sh"
arktrace_prepare_reviewed_roots "$repository_root"
evidence_directory=$(arktrace_secure_owned_directory \
    "$ARKTRACE_REVIEWED_BUILD_ROOT/phase4-final-evidence" \
    .arktrace-phase3-evidence-v1 "Phase 4 final evidence")

# The final Phase 4 gate inherits the complete Phase 3 distribution gate.
# It therefore fails closed until signed-App accessibility, reviewed large
# trace, Developer ID and notarization inputs exist.
"$script_directory/test_phase3.sh"
"$script_directory/test_phase4_agent_contract.sh"

medium_evidence="$evidence_directory/arktrace-phase3-phase4-medium-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
large_evidence="$evidence_directory/arktrace-phase3-phase4-large-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
ARKTRACE_PHASE3_EVIDENCE_OUTPUT="$medium_evidence" \
    "$script_directory/benchmark.sh" phase4 medium
ARKTRACE_PHASE3_EVIDENCE_OUTPUT="$large_evidence" \
    "$script_directory/benchmark.sh" phase4 large
jq -e '.fixtureClass == "medium" and .contextP95Ms <= 1000
    and .deterministicAnalysisP95Ms <= 3000
    and .measuredRows.contextEvents > 0
    and .measuredRows.deterministicAnalysisRows > 0' \
    "$medium_evidence" >/dev/null
jq -e '.fixtureClass == "large" and .contextP95Ms <= 2000
    and .deterministicAnalysisP95Ms <= 5000
    and .measuredRows.contextEvents > 0
    and .measuredRows.deterministicAnalysisRows > 0' \
    "$large_evidence" >/dev/null

printf 'Phase 4 gate passed: inherited release gates + Agent contract + production medium/large performance\n'
