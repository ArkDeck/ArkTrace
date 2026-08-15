#!/bin/sh
set -eu

fail() {
    printf 'Phase 5 gate failed: %s\n' "$1" >&2
    exit 1
}

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd -P)
evidence="$repository_root/Fixtures/release-evidence/phase5-arkdeck-real-artifact.json"
summary="$repository_root/Fixtures/release-evidence/phase5-arkdeck-real-artifact-summary.json"
distribution="$repository_root/Fixtures/release-evidence/phase5-cli-distribution.json"

# Phase 5 inherits the reviewed medium Phase 4 batch, but deliberately does
# not invoke the final Phase 4 large gate while that external fixture remains
# explicitly deferred and fail-closed.
"$script_directory/test_phase4_batch1.sh"
"$script_directory/test_phase5_cli_distribution_contract.sh"

for required in "$evidence" "$summary" "$distribution"; do
    [ -f "$required" ] && [ ! -L "$required" ] \
        || fail "a committed evidence input is missing or symbolic"
    relative_path=${required#"$repository_root"/}
    git -C "$repository_root" ls-files --error-unmatch -- "$relative_path" >/dev/null 2>&1 \
        || fail "an evidence input is not tracked"
    git -C "$repository_root" diff --quiet HEAD -- "$relative_path" \
        || fail "an evidence input differs from HEAD"
done

summary_sha=$(shasum -a 256 "$summary" | awk '{print $1}')
summary_bytes=$(stat -f '%z' "$summary")
[ "$summary_sha" = "$(jq -r '.derivedArtifact.sha256' "$evidence")" ] \
    || fail "derived Artifact SHA does not match retained exact bytes"
[ "$summary_bytes" = "$(jq -r '.derivedArtifact.byteCount' "$evidence")" ] \
    || fail "derived Artifact byte count does not match retained exact bytes"

jq -e --slurpfile summary "$summary" --slurpfile distribution "$distribution" '
  def sha256: type == "string" and test("^[0-9a-f]{64}$");
  def oid40: type == "string" and test("^[0-9a-f]{40}$");
  def utc: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
  def exact($names): keys == ($names | sort);
  exact([
    "arkDeck", "availability", "derivedArtifact", "derivation", "execution",
    "formatVersion", "largeTraceGateApplied", "recordedAtUTC", "restartProof",
    "sourceArtifact", "summaryBytes"
  ])
  and .formatVersion == 1
  and .largeTraceGateApplied == false
  and (.recordedAtUTC | utc)
  and .summaryBytes == "phase5-arkdeck-real-artifact-summary.json"
  and (.arkDeck | exact([
    "catalogDigest", "daemonBinarySHA256", "descriptor", "launchAgentIntegrationMerge",
    "protectedMainBaseline", "runtimeProtocolVersion"
  ]))
  and (.arkDeck.catalogDigest | sha256)
  and (.arkDeck.daemonBinarySHA256 | sha256)
  and .arkDeck.launchAgentIntegrationMerge == "4e478b46f202a139dbeb2c91d79e36d6d7774fac"
  and (.arkDeck.protectedMainBaseline | oid40)
  and .arkDeck.runtimeProtocolVersion == "1.0.0"
  and (.arkDeck.descriptor | exact(["byteCount", "manifestSHA256", "sha256"]))
  and .arkDeck.descriptor.byteCount > 0
  and .arkDeck.descriptor.byteCount <= 16384
  and (.arkDeck.descriptor.manifestSHA256 | sha256)
  and (.arkDeck.descriptor.sha256 | sha256)
  and (.availability | exact([
    "analyzer.summarize-trace@1", "capture.diagnostics@1", "checkedBeforeSubmit"
  ]))
  and .availability["analyzer.summarize-trace@1"] == "available"
  and .availability["capture.diagnostics@1"] == "available"
  and .availability.checkedBeforeSubmit == true
  and (.sourceArtifact | exact([
    "artifactID", "bindingRevision", "byteCount", "captureFinishedAtUTC",
    "captureJobID", "captureState", "mediaType", "name", "sha256",
    "sourceOperation", "stableIdentitySHA256", "status", "targetID"
  ]))
  and (.sourceArtifact.artifactID | test("^ART-[0-9a-f]{32}$"))
  and (.sourceArtifact.captureJobID | test("^job-[0-9a-f]{32}$"))
  and .sourceArtifact.bindingRevision > 0
  and .sourceArtifact.byteCount > 0
  and (.sourceArtifact.captureFinishedAtUTC | utc)
  and .sourceArtifact.captureState == "succeeded"
  and .sourceArtifact.mediaType == "application/octet-stream"
  and .sourceArtifact.name == "trace.htrace"
  and (.sourceArtifact.sha256 | sha256)
  and .sourceArtifact.sourceOperation == "capture.diagnostics@1"
  and (.sourceArtifact.stableIdentitySHA256 | sha256)
  and .sourceArtifact.status == "published"
  and (.sourceArtifact.targetID | test("^TGT-[0-9a-f]{12}$"))
  and (.execution | exact([
    "actualEffect", "executionMode", "finishedAtUTC", "guiAutomationUsed",
    "jobID", "manualArkTraceLaunchUsed", "operation", "outcomeUnknown",
    "runtimeCapabilityConsumed", "startedAtUTC", "state", "targetID"
  ]))
  and .execution.actualEffect == "hostOnly"
  and .execution.executionMode == "execute"
  and (.execution.startedAtUTC | utc)
  and (.execution.finishedAtUTC | utc)
  and .execution.guiAutomationUsed == false
  and .execution.manualArkTraceLaunchUsed == false
  and .execution.runtimeCapabilityConsumed == false
  and .execution.outcomeUnknown == false
  and .execution.operation == "analyzer.summarize-trace@1"
  and .execution.state == "succeeded"
  and .execution.targetID == .sourceArtifact.targetID
  and (.derivedArtifact | exact([
    "artifactID", "byteCount", "createdAtUTC", "jobID", "mediaType", "name",
    "privacy", "redactionApplied", "sha256", "status", "targetID"
  ]))
  and (.derivedArtifact.artifactID | test("^ART-[0-9a-f]{32}$"))
  and (.derivedArtifact.createdAtUTC | utc)
  and .derivedArtifact.jobID == .execution.jobID
  and .derivedArtifact.jobID != .sourceArtifact.captureJobID
  and .derivedArtifact.mediaType == "application/json"
  and .derivedArtifact.name == "trace-summary.json"
  and .derivedArtifact.privacy == "standard"
  and .derivedArtifact.redactionApplied == false
  and (.derivedArtifact.sha256 | sha256)
  and .derivedArtifact.status == "published"
  and .derivedArtifact.targetID == .sourceArtifact.targetID
  and (.derivation | exact([
    "analyzerRef", "analyzerVersion", "indexSchemaVersion", "maxEvents",
    "maxOutputBytes", "maxRows", "parserAdapterVersion", "parserBuildRecipeVersion",
    "parserSHA256", "parserUpstreamRevision", "parserVersion", "schemaAdapterVersion",
    "sourceArtifactID", "sourceByteCount", "sourceSHA256", "timeoutMs", "toolSHA256"
  ]))
  and .derivation.analyzerRef == "trace-summary@1"
  and .derivation.analyzerVersion == "0.1.0+1"
  and .derivation.sourceArtifactID == .sourceArtifact.artifactID
  and .derivation.sourceByteCount == .sourceArtifact.byteCount
  and .derivation.sourceSHA256 == .sourceArtifact.sha256
  and .derivation.maxEvents == 10000
  and .derivation.maxRows == 1000
  and .derivation.maxOutputBytes == 8388608
  and .derivation.timeoutMs == 30000
  and (.derivation.toolSHA256 | sha256)
  and (.derivation.parserSHA256 | sha256)
  and (.derivation.parserUpstreamRevision | oid40)
  and (.derivation.parserBuildRecipeVersion | sha256)
  and (.restartProof | exact([
    "artifactReadable", "daemonReady", "derivedSHA256AfterRestart",
    "operationAvailable", "restartedAtUTC"
  ]))
  and .restartProof.artifactReadable == true
  and .restartProof.daemonReady == true
  and .restartProof.operationAvailable == true
  and (.restartProof.restartedAtUTC | utc)
  and .restartProof.derivedSHA256AfterRestart == .derivedArtifact.sha256
  and .arkDeck.descriptor.manifestSHA256 == $distribution[0].finalDistribution.manifestSHA256
  and .derivation.toolSHA256 == $distribution[0].tool.binarySHA256
  and .derivation.parserSHA256 == $distribution[0].traceStreamer.binarySHA256
  and .derivation.parserBuildRecipeVersion == $summary[0].provenance.parserBuildRecipeVersion
  and .sourceArtifact.sha256 == $summary[0].trace.sha256
  and .sourceArtifact.byteCount == $summary[0].trace.byteCount
  and .derivedArtifact.byteCount > 0
  and .derivedArtifact.byteCount <= .derivation.maxOutputBytes
  and .derivation.toolSHA256 == $summary[0].tool.buildRevision
  and .derivation.parserSHA256 == $summary[0].trace.parser.binarySha256
' "$evidence" >/dev/null || fail "real Artifact evidence schema or lineage is invalid"

jq -e '
  [.. | strings | select(
    test("file://"; "i")
    or test("(^|[^A-Za-z0-9_])/[A-Za-z0-9._~-]")
  )] | length == 0
' "$evidence" "$summary" >/dev/null \
    || fail "real Artifact evidence contains a host path"

printf 'Phase 5 gate passed: inherited medium gate + CLI distribution + real ArkDeck capture Artifact to persisted summary Artifact\n'
printf 'Large Trace gates 6/7 and the Phase 4 large exit remain open by explicit deferral.\n'
