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
# These follow the retained rounds, not whatever is pinned right now. The
# evidence is a real two-round device run, so its tool and parser identity are
# frozen at what shipped when it was captured; editing these constants without
# re-running the scenario would assert only that the recorded bytes had been
# changed.
#
# The 2026-08-16 CLI re-pin therefore did not update them on its own — it left
# this gate attesting a retired binary until the DAYU 200 scenario in
# docs/PHASE_6_SCENARIO.md was re-run. The same discipline applied to the
# 2026-08-17 macOS 26 / Swift 6.3 re-pin (source 61d0f2a): the scenario was
# re-run end to end on that distribution (PHASE_6_SCENARIO.md §10.3), both
# rounds reached the same verdict, and tool and parser below moved together
# with the freshly captured evidence.
expected_tool=cdfc91679211c7537db343693b035e1b7c9752beadd9b60dd9cfad90874829c1
expected_parser=7c5ed515fc4d74517476fb901e3f7812914cb33b651324f49466d709d4641b35
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

# Discarded attempts must stay visible: a silently dropped run is a rewritten
# result. A run that discarded nothing is a legitimate outcome, but it has to say
# so — an empty list on its own is indistinguishable from an omitted one, so it
# only passes when the evidence also states why there was nothing to discard.
jq -e '.discardedAttempts | type == "array"' "$evidence" >/dev/null 2>&1 \
    || fail "discarded attempts were not recorded"
if [ "$(jq -r '.discardedAttempts | length' "$evidence")" -eq 0 ]; then
    jq -er 'select((.noDiscardedAttemptsReason // "") != "") | .noDiscardedAttemptsReason' \
        "$evidence" >/dev/null 2>&1 \
        || fail "an empty discarded-attempt list carries no explanation"
fi
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

# The confirmatory Phase 6 documents do not carry the release verdict, so they
# are not re-derived here. They are still published evidence, so the two
# invariants that hold for any evidence document are checked: it must parse,
# and it must not leak a local path. Being unchecked is how a confirmatory file
# rots into malformed JSON or grows an absolute path without anyone noticing.
confirmatory_failures=$failures
for name in phase6-capability-probe phase6-loop-reproduction \
    phase6-context-closure phase6-lease-reresolution
do
    confirmatory="$repository_root/Fixtures/release-evidence/$name.json"
    if [ ! -f "$confirmatory" ]; then
        fail "confirmatory evidence is absent: $name.json"
        continue
    fi
    jq -e . "$confirmatory" >/dev/null 2>&1 \
        || fail "confirmatory evidence is not valid JSON: $name.json"
    if grep -Eq '"/Users/|/home/|/private/var/folders' "$confirmatory"; then
        fail "confirmatory evidence contains an absolute user path: $name.json"
    fi
done
[ "$failures" -eq "$confirmatory_failures" ] \
    && pass "confirmatory evidence parses and carries no absolute user path"

if [ "$failures" -ne 0 ]; then
    printf 'phase6: %d check(s) failed\n' "$failures" >&2
    exit 1
fi
printf 'phase6: all checks passed\n'
