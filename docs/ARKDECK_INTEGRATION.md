# ArkDeck integration

ArkDeck consumes ArkTrace only through reviewed, typed analyzer operations. The production
integration does not accept an executable path, argv array, shell fragment, raw SQL, GUI
automation, HDC route, or RuntimeCapability from the caller.

## Production profile

The signed ArkTrace CLI distribution is selected by an owner-only descriptor. ArkDeck installs
that descriptor into the daemon LaunchAgent with:

```sh
arkdeck agentd update --arktrace-descriptor <absolute-physical-descriptor>
```

The LaunchAgent receipt and status bind the descriptor byte count and SHA-256. The daemon resolves
the manifest and signed App from that descriptor, verifies the fixed tool/parser/profile identity,
runs `doctor --self-test --json`, and publishes availability before accepting an analyzer Job.
Ordinary daemon updates preserve the pin only while the live descriptor still matches the prior
install receipt; selecting different bytes requires an explicit descriptor argument.

The LaunchAgent integration was merged in ArkDeck PR #1311 as
`4e478b46f202a139dbeb2c91d79e36d6d7774fac`. The real run below used the preceding protected-main
analyzer baseline `0d8f01964b058d954112604900db19dea28ef39f`; these identities are intentionally
recorded separately.

## Real Artifact chain

The reviewed Phase 5 run exercised the production path:

```text
capture.diagnostics@1
  -> immutable trace.htrace Artifact lease
  -> analyzer.summarize-trace@1 (hostOnly)
  -> pinned arktrace summary --json --no-cache
  -> validated exact trace-summary.json bytes
  -> persisted derived Artifact with source/tool/parser/request lineage
```

The analyzer Job used the source Artifact target so ArkDeck could resolve the device-bound source
lease, while the analyzer action itself remained `hostOnly`. Availability for both capture and
summary was `available` before submit. No manual ArkTrace launch, GUI automation, HDC route, or
RuntimeCapability was used by the analyzer.

| Evidence | Identity |
|---|---|
| Capture Job | `job-876a0741ebd945358b598a37b584c11a` |
| Source Artifact | `ART-fd0a93c85a005703f6edf1cfb47a3daa` |
| Source bytes | 1,240 bytes; SHA-256 `a5c20c3b85b3daf56618517b114f678635391e4e4da653acbedf38d0c4b85b35` |
| Analyzer Job | `job-9e47472de912cbe7e040757019421d57` |
| Derived Artifact | `ART-13f8ddd3192811c11efc40c048a078eb` |
| Derived bytes | 1,781 bytes; SHA-256 `009f9beb60ea9265fd8b21161689cf705b83a78f6b7cecd178e85a721055a3fe` |
| Tool | SHA-256 `0c552cbaac49d2ed641e999cb01163b3aa8bac5ce2015d52ef7caf552dabdc65` |
| TraceStreamer | 4.3.7; SHA-256 `2e8316265f8fdc027614d81c7d71646a0eb7dfadffbb2503e13ee66287f937e5` |

After `launchctl kickstart -k`, the daemon returned ready, the operation remained available, and
the derived Artifact remained readable with the same SHA-256. The path-free machine evidence is
`Fixtures/release-evidence/phase5-arkdeck-real-artifact.json`; the retained exact derived bytes are
`Fixtures/release-evidence/phase5-arkdeck-real-artifact-summary.json`. `scripts/test_phase5.sh`
rehashes those bytes and closes their source, parser, distribution, Job, restart, and lineage
relationships.

## Deferred large evidence

This run is a real small Trace captured by ArkDeck. It closes Phase 5 Gate 9, but it is not the
independently captured, redistributable >500 MiB fixture. Phase 3 Gates 6/7, P4-T06 large
performance, and the Phase 3/4 full exits remain open and fail closed when that external evidence
is absent.
