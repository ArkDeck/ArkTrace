#!/bin/sh
# Phase 7 gate: upstream alignment.
#
# What this gate is for: Phase 7 closed gaps where SmartPerf Host could read a
# trace offline and ArkTrace could not. "Aligned" is only worth something if it
# is executable, so the gate's own job — beyond running the inherited
# regressions — is to prove that each alignment assertion still *exists and
# runs*. A deleted test is otherwise indistinguishable from a passing one.
#
# Inheritance (TASKS.md §6): Phase 1 (real parser, locked fixtures, zero-skip
# suite) and Phase 6 (offline evidence integrity), plus the API-baseline,
# CI-planner and license contracts. It deliberately does NOT inherit the Phase
# 3/4/5 distribution gates: those bind Developer ID signing, notarization and a
# reviewed large trace, none of which Phase 7 touched, and this phase's
# acceptance is that it is green wherever the pinned parser has been built.
# `scripts/test_phase5.sh` remains the gate for that chain.
#
# Fails closed. A missing pinned parser, a missing upstream fixture, or an
# alignment test that no longer runs is a failure, never a skip.
set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd -P)

fail() {
    printf 'Phase 7 gate failed: %s\n' "$1" >&2
    exit 1
}

pass() {
    printf 'phase7: ok   %s\n' "$1"
}

for command_name in swift jq shasum git python3; do
    command -v "$command_name" >/dev/null 2>&1 \
        || fail "$command_name is unavailable"
done

parser="$repository_root/ThirdParty/TraceStreamer/macx/trace_streamer"
[ -x "$parser" ] && [ ! -L "$parser" ] \
    || fail "pinned trace_streamer is unavailable; run scripts/build_trace_streamer.sh"

phase7_temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/arktrace-phase7.XXXXXX")
alignment_log="$phase7_temporary_directory/alignment.log"
evidence="$phase7_temporary_directory/phase7-evidence.json"
cleanup() {
    rm -rf -- "$phase7_temporary_directory"
}
trap cleanup EXIT HUP INT TERM

# ---------------------------------------------------------------------------
# 1. Inherited gates.
# ---------------------------------------------------------------------------
"$script_directory/test_phase1.sh" >/dev/null || fail "Phase 1 gate failed"
pass "Phase 1 inherited: real parser, locked fixtures, zero skipped tests"
"$script_directory/test_phase6.sh" >/dev/null || fail "Phase 6 gate failed"
pass "Phase 6 inherited: recorded closed-loop evidence is intact"
"$script_directory/test_api_baseline.sh" >/dev/null \
    || fail "public API baseline no longer compiles from outside the package"
pass "API baseline compiles from outside the package"
"$script_directory/test_ci_plan.sh" >/dev/null || fail "CI planner contract failed"
pass "CI planner still routes README edits to the SwiftPM lane"
"$script_directory/verify_licenses.sh" >/dev/null || fail "license inventory failed"
pass "license inventory verified"

# ---------------------------------------------------------------------------
# 2. Upstream-alignment regressions must exist and run.
#
# Each name is one closed AUDIT gap or one ported upstream encoding. The list
# is the contract: adding an alignment claim to the audit means adding its
# assertion here.
# ---------------------------------------------------------------------------
alignment_tests="
testPaletteMatchesUpstreamTable
testHashMatchesUpstreamVectors
testHashFuncIgnoresEmbeddedDigits
testStateColorsMatchUpstreamChain
testLabelColorMatchesUpstreamLuminanceRule
testCpuSliceTakesProcessIdentity
testSameSliceNameKeepsOneColourAtEveryDepth
testProcessCounterSamplesComeFromProcessMeasureWhenMeasureIsEmpty
testProcessCountersReadLegacyMeasureAndMergeBothSourcesDeterministically
testCPUCounterPathIsUnaffectedByProcessSampleTable
testCounterCapabilityBudgetExhaustionReportsUnavailableInsteadOfRefusingTheTrace
testAProvenPrimarySourceKeepsTheCapabilityWhenTheSecondaryIsUndecidable
testRangeAndDeterministicAnalysisAgreeOnThreadStateDistribution
testNestedDepthRowsAreDistinctAndHitTestMatchesTheDrawnFrame
testSingleDepthTrackGeometryIsUnchanged
testSliceArgumentsResolveNamesAndFollowUpstreamDatatypeRules
testJankColoursMatchUpstreamTable
testJankIsStatedInWordsNotOnlyColour
testExpectedAndActualOccupyDistinctRowsOfOneLane
testRepeatedHoverNeverRebuildsTheDetailPathCache
testHoverPostsNoAccessibilityNotification
testDensityPrefetchChunksBeyondTheEventBatchQueryCap
testEveryCatalogTableAppearsVerbatimInTheEnglishReadme
testEveryCatalogTableAppearsVerbatimInTheChineseReadme
testTheReadmesCarryNoShortcutRowTheCatalogDoesNotProduce
testModifiedVerticalScrollingZoomsInTheUpstreamDirection
testDraggingAnEndpointMovesOnlyThatEndpoint
testEndpointHitAreasAreLargeEnoughAndNeverOverlap
testTopThreadsSplitTimePerCPUAndTheSplitSumsToTheTotal
testSearchResultSteppingRevealsWithoutStealingKeyboardFocus
"

filter=$(printf '%s' "$alignment_tests" | tr '\n' '|' | sed -e 's/^|*//' -e 's/|*$//')
cd "$repository_root"
if ! ARKTRACE_TRACE_STREAMER="$parser" swift test --filter "$filter" \
    >"$alignment_log" 2>&1
then
    grep -E 'error: -\[|Test Case .* failed' "$alignment_log" | tail -20 >&2 || true
    fail "an upstream-alignment regression failed"
fi

missing=
for name in $alignment_tests; do
    grep -q "Test Case .*[ .]$name\]' passed" "$alignment_log" \
        || missing="$missing $name"
done
[ -z "$missing" ] || fail "alignment assertions no longer run:$missing"
alignment_count=$(printf '%s\n' $alignment_tests | grep -c . )
pass "$alignment_count upstream-alignment assertions ran and passed"

# ---------------------------------------------------------------------------
# 3. Contract provenance.
#
# ArkDeck asserts these three as source literals and its envelope validator
# requires exact equality (ARKDECK_INTEGRATION.md). Moving one is a cross-repo
# release, so the gate pins them: a bump has to be a deliberate edit here
# accompanied by the matching ArkDeck release.
# ---------------------------------------------------------------------------
assert_literal() {
    file="$repository_root/$1"
    pattern=$2
    description=$3
    grep -Fq "$pattern" "$file" || fail "$description drifted"
}
assert_literal "Sources/ArkTraceStore/TraceSchemaAdapter.swift" \
    'static let version = "2"' "schemaAdapterVersion"
assert_literal "Sources/ArkTraceStore/TraceDatabaseStagingPreparer.swift" \
    'public static let indexVersion = 3' "indexSchemaVersion"
assert_literal "Sources/ArkTraceParser/TraceStreamerProcessParser.swift" \
    'public static let adapterVersion = "1"' "parserAdapterVersion"
pass "ArkDeck-pinned contract literals unchanged (schema=2 index=3 parser=1)"

# The locked schema evidence must still describe this parser and these
# fixtures. `ParserIntegrationTests` re-probes both fixtures live against it in
# the Phase 1 run above; this is the cheap structural half.
schema_evidence="$repository_root/Fixtures/databases/trace_streamer_4.3.7.schema-evidence.json"
jq -e '
    .schemaAdapterVersion == "2"
    and (.schemaFingerprint | test("^[0-9a-f]{64}$"))
    and ([.fixtures[] | select(.capabilities.cpuCounters or .capabilities.processCounters)]
        | length == 0)
' "$schema_evidence" >/dev/null || fail "locked schema evidence drifted"
schema_fingerprint=$(jq -er '.schemaFingerprint' "$schema_evidence")
pass "locked schema evidence unchanged (fingerprint ${schema_fingerprint%"${schema_fingerprint#????????}"}…)"

# ---------------------------------------------------------------------------
# 4. Viewport performance on the pinned upstream medium fixture.
#
# Phase 7 changed what the viewport draws (call-depth rows, frame lanes) and
# what it selects (arguments), so the phase cannot close without measuring the
# viewport again on a real trace. The benchmark also verifies every viewport
# query plan against the exact reviewed index set, which is what caught the
# `argsetid` selection dropping the hottest query off its covering index.
# ---------------------------------------------------------------------------
"$script_directory/benchmark.sh" phase4 medium >"$phase7_temporary_directory/bench.log" 2>&1 \
    || {
        tail -20 "$phase7_temporary_directory/bench.log" >&2
        fail "medium viewport benchmark failed"
    }
benchmark_evidence=$(sed -n 's/.*evidence=\([^ ]*\).*/\1/p' \
    "$phase7_temporary_directory/bench.log" | tail -1)
[ -n "$benchmark_evidence" ] || fail "benchmark did not report its evidence"
benchmark_path="$repository_root/.build/phase3-evidence/$benchmark_evidence"
[ -f "$benchmark_path" ] || fail "benchmark evidence is not where it was reported"
jq -e '
    .fixtureClass == "medium"
    and .viewportP95Ms > 0
    and .frameP95Ms <= 16.7
    and .panFrameP95Ms <= 16.7
    and .selectionFrameP95Ms <= 16.7
    and .rebuildFrameP95Ms <= 250
' "$benchmark_path" >/dev/null || fail "medium viewport budgets were not met"
pass "medium viewport benchmark within budget and on the reviewed index set"

# ---------------------------------------------------------------------------
# 5. Evidence.
# ---------------------------------------------------------------------------
parser_sha=$(shasum -a 256 "$parser" | awk '{print $1}')
fixture_sha=$(jq -er '.medium.sha256' \
    "$repository_root/Fixtures/phase3-performance-fixtures.json")
jq -n \
    --arg parserSHA "$parser_sha" \
    --arg parserRevision "$(jq -er '.upstreamRevision' \
        "$repository_root/ThirdParty/TraceStreamer/macx/manifest.json")" \
    --arg schemaFingerprint "$schema_fingerprint" \
    --arg mediumFixtureSHA "$fixture_sha" \
    --argjson alignmentAssertions "$alignment_count" \
    --slurpfile benchmark "$benchmark_path" '
    {
        formatVersion: 1,
        phase: 7,
        parserBinarySHA256: $parserSHA,
        parserUpstreamRevision: $parserRevision,
        schemaFingerprint: $schemaFingerprint,
        schemaAdapterVersion: "2",
        indexSchemaVersion: 3,
        parserAdapterVersion: "1",
        mediumFixtureSHA256: $mediumFixtureSHA,
        alignmentAssertions: $alignmentAssertions,
        viewport: {
            p95Ms: $benchmark[0].viewportP95Ms,
            frameP95Ms: $benchmark[0].frameP95Ms,
            panFrameP95Ms: $benchmark[0].panFrameP95Ms,
            rebuildFrameP95Ms: $benchmark[0].rebuildFrameP95Ms,
            selectionFrameP95Ms: $benchmark[0].selectionFrameP95Ms,
            namedSliceDetailP95Ms: $benchmark[0].viewportLatency.namedSliceDetail.p95Ms
        }
    }
' >"$evidence" || fail "evidence could not be assembled"

if grep -Eq '"/Users/|/home/|/private/var/folders' "$evidence"; then
    fail "evidence contains an absolute user path"
fi
[ "$(stat -f '%z' "$evidence")" -le 4096 ] || fail "evidence exceeded 4096 bytes"

printf 'Phase 7 gate passed: alignment=%s parser=%s\n' \
    "$alignment_count" "$parser_sha"
jq -c . "$evidence"
