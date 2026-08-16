#!/bin/bash
# Phase 6 gate: verify the recorded real closed-loop evidence is internally
# consistent, complete, and free of the substitutions Phase 6 forbids.
#
# This gate is deliberately offline. The loop itself needs a real authorised
# device, a real ArkDeck daemon and a real application build; re-running it here
# would not be a check, it would be a second experiment. What this gate does
# check is that the recorded evidence still says what the release gate claims,
# that it is bound to the pinned tool and parser identity, and that it never
# quietly downgrades an open finding into a closed one.
#
# Fails closed: a missing or malformed evidence document is a failure, never a skip.
set -u

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
evidence="$repository_root/Fixtures/release-evidence/phase6-real-debug-loop.json"
scenario="$repository_root/docs/PHASE_6_SCENARIO.md"
failures=0

fail() {
    printf 'phase6: FAIL %s\n' "$1" >&2
    failures=$((failures + 1))
}

pass() {
    printf 'phase6: ok   %s\n' "$1"
}

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }
[ -f "$evidence" ] || { fail "evidence document is absent: Fixtures/release-evidence/phase6-real-debug-loop.json"; exit 1; }
[ -f "$scenario" ] || { fail "frozen scenario is absent: docs/PHASE_6_SCENARIO.md"; exit 1; }
jq -e . "$evidence" >/dev/null 2>&1 || { fail "evidence document is not valid JSON"; exit 1; }

# The evidence must never carry a user's absolute path or a secret.
if grep -Eq '"/Users/|/home/|/private/var/folders' "$evidence"; then
    fail "evidence contains an absolute user path"
else
    pass "evidence carries no absolute user path"
fi

# Pinned identity must match the distribution this evidence was recorded against.
#
# These are deliberately NOT the currently pinned distribution. The retained
# evidence is a real two-round device run, so its tool and parser identity are
# frozen at whatever shipped when it was captured; rewriting these constants to
# follow a re-pin would only assert that the recorded bytes had been edited.
#
# The 2026-08-16 re-pin therefore left Phase 6 attesting to a retired binary:
# tool a7859d69… / parser 66887fae… now ship, while the rounds below ran on
# 0c552cba… / 2e831626…. Closing that gap needs the DAYU 200 scenario in
# docs/PHASE_6_SCENARIO.md re-run on the current pin — it cannot be done on the
# host. Until then this gate proves the retained run is intact, not that the
# shipping distribution has been exercised end to end on a device.
#
# The analysis half of that chain has since been verified on the current pin
# against a fresh 948 KB DAYU 200 capture — see docs/PHASE_6_VERIFICATION.md
# §7.2. What remains uncovered here is the two-round debug loop: host compile,
# HAP import/sign, debug.hap@1 deploy, and the frozen comparison judgement.
expected_tool=0c552cbaac49d2ed641e999cb01163b3aa8bac5ce2015d52ef7caf552dabdc65
expected_parser=2e8316265f8fdc027614d81c7d71646a0eb7dfadffbb2503e13ee66287f937e5
expected_revision=447a0a49a7b3b914d6e9bd00648ba5a340f6fbf6
[ "$(jq -r '.toolIdentity.arkTraceBuildRevision' "$evidence")" = "$expected_tool" ] \
    || fail "ArkTrace build revision drifted from the pinned distribution"
[ "$(jq -r '.toolIdentity.parserBinarySHA256' "$evidence")" = "$expected_parser" ] \
    || fail "TraceStreamer binary SHA drifted from the pinned distribution"
[ "$(jq -r '.toolIdentity.parserUpstreamRevision' "$evidence")" = "$expected_revision" ] \
    || fail "TraceStreamer upstream revision drifted"
pass "tool and parser identity match the pinned distribution"

# Both rounds must be real, terminal, and distinct.
for round in baseline followup; do
    state=$(jq -r ".rounds.$round.capture.state" "$evidence")
    [ "$state" = "succeeded" ] || fail "$round capture did not reach a terminal success"
    deploy=$(jq -r ".rounds.$round.deploy.deployState" "$evidence")
    [ "$deploy" = "succeeded" ] || fail "$round deploy did not reach a terminal success"
    bytes=$(jq -r ".rounds.$round.capture.traceByteCount" "$evidence")
    [ "$bytes" -gt 0 ] 2>/dev/null || fail "$round trace has no bytes"
    jq -er ".rounds.$round.capture.traceSHA256 | test(\"^[0-9a-f]{64}$\")" "$evidence" >/dev/null \
        || fail "$round trace SHA-256 is malformed"
done
base_sha=$(jq -r '.rounds.baseline.capture.traceSHA256' "$evidence")
follow_sha=$(jq -r '.rounds.followup.capture.traceSHA256' "$evidence")
[ "$base_sha" != "$follow_sha" ] || fail "baseline and follow-up traces are the same bytes"
base_hap=$(jq -r '.rounds.baseline.deploy.signedHapSHA256' "$evidence")
follow_hap=$(jq -r '.rounds.followup.deploy.signedHapSHA256' "$evidence")
[ "$base_hap" != "$follow_hap" ] || fail "both rounds deployed the same signed HAP"
pass "both rounds are terminal, real and distinct"

# The capture request must be identical across rounds; only the build may differ.
[ "$(jq -r '.captureRequest.identicalAcrossRounds' "$evidence")" = "true" ] \
    || fail "capture parameters were not identical across rounds"
pass "capture parameters identical across rounds"

# Phase 6 forbids GUI copy, human-log evidence and unstructured agent inputs.
[ "$(jq -r '.agentDecision.inputsWereStructuredArtifactsOnly' "$evidence")" = "true" ] \
    || fail "agent consumed something other than structured artifacts"
[ "$(jq -r '.agentDecision.guiAutomationUsed' "$evidence")" = "false" ] \
    || fail "GUI automation was used"
[ "$(jq -r '.agentDecision.humanLogReadForEvidence' "$evidence")" = "false" ] \
    || fail "a human log was read as evidence"
pass "agent evidence discipline holds"

# The scenario must have been frozen before the baseline was captured.
[ "$(jq -r '.scenario.frozenBeforeBaselineCapture' "$evidence")" = "true" ] \
    || fail "scenario was not frozen before baseline capture"
[ "$(jq -r '.scenario.amendmentRecordedBeforeBaselineCapture' "$evidence")" = "true" ] \
    || fail "a scenario amendment was not recorded before baseline capture"
pass "scenario freeze discipline holds"

# The verdict must follow the frozen rule from the recorded numbers, not from prose.
verdict=$(jq -r '.comparison.verdict' "$evidence")
m1_delta=$(jq -r '.comparison.M1_appProcessShareOfOneCPU.relativeDelta' "$evidence")
m2_delta=$(jq -r '.comparison.M2_appMainThreadShareOfOneCPU.relativeDelta' "$evidence")
recomputed=$(jq -rn --argjson d1 "$m1_delta" --argjson d2 "$m2_delta" '
    if $d1 <= -0.20 and $d2 <= 0.05 then "improved"
    elif $d1 >= 0.10 then "regressed"
    elif ($d1 | fabs) < 0.10 then "unchanged"
    else "inconclusive" end')
[ "$verdict" = "$recomputed" ] \
    || fail "recorded verdict $verdict does not follow the frozen rule (recomputed $recomputed)"
pass "verdict $verdict follows the frozen decision rule"

# Identity across rounds must be mapped, never assumed.
jq -er '.comparison.identityMapping | test("pid")' "$evidence" >/dev/null \
    || fail "cross-round identity mapping is not recorded"
pass "cross-round identity mapping recorded"

# Discarded attempts must stay visible: a silently dropped run is a rewritten result.
[ "$(jq -r '.discardedAttempts | length' "$evidence")" -ge 1 ] \
    || fail "discarded attempts were not recorded"
jq -er '.discardedAttempts[] | select((.reason // "") == "") | .captureJobID' "$evidence" >/dev/null 2>&1 \
    && fail "a discarded attempt has no reason"
pass "discarded attempts recorded with reasons"

# Open findings must remain open. Gate 10 does not get to close them by omission.
if [ "$(jq -r '.openFindings | length' "$evidence")" -gt 0 ]; then
    jq -er '.openFindings.contextCounterSampleWindow.failedJobID' "$evidence" >/dev/null \
        || fail "an open finding lost its failing job identity"
    pass "open findings retain their failing job identity"
fi

# Privacy contract.
[ "$(jq -r '.privacy.absoluteUserPathsIncluded' "$evidence")" = "false" ] \
    || fail "evidence declares absolute user paths"
[ "$(jq -r '.privacy.thirdPartyProcessNamesIncluded' "$evidence")" = "false" ] \
    || fail "evidence declares third-party process names"
pass "privacy contract holds"

# The scenario document must still carry the frozen sections the evidence cites.
grep -q '## 9. 成功指标（冻结）' "$scenario" || fail "frozen metric section is missing"
grep -q '## 10. 判定规则（冻结）' "$scenario" || fail "frozen decision rule section is missing"
pass "frozen scenario sections present"

if [ "$failures" -ne 0 ]; then
    printf 'phase6: %d check(s) failed\n' "$failures" >&2
    exit 1
fi
printf 'phase6: all checks passed\n'
