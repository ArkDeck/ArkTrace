# ArkDeck integration

ArkDeck consumes ArkTrace only through reviewed, typed analyzer operations. The production
integration does not accept an executable path, argv array, shell fragment, raw SQL, GUI
automation, HDC route, or RuntimeCapability from the caller.

## Shared-source direction

ArkTrace is the source owner for Core, Parser, Store, Runtime, Analysis, Rendering and the
product-neutral document engine. ArkDeck should consume a pinned ArkTrace package revision and
keep only its Artifact/Runtime bridge and product UI locally; it should not maintain renamed
copies of those shared modules.

`TraceProductConfiguration` is the composition boundary for legitimate product differences. It
fixes the consumer bundle, cache/staging roots, recent-document preference key, signpost subsystem
and bundle-relative parser/manifest locations before any trace is opened. The default factory is
the standalone ArkTrace profile. ArkDeck must construct its own reviewed profile at its app
composition root; request inputs cannot select or widen any of these values.

This source-dependency migration is incremental. Until ArkDeck deletes its migrated copies, a
dependency bump is not proof of parity by itself; the downstream change must still run ArkTrace
contract fixtures and ArkDeck's complete Trace/App lanes. Once the copies are removed, ArkDeck
updates should change only the pinned ArkTrace revision plus intentional adapter/UI code.

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
`4e478b46f202a139dbeb2c91d79e36d6d7774fac`. The real run below used the protected-main analyzer
baseline `d6b9dd399340182b997e461fcabac835b5b5568e`; these identities are intentionally recorded
separately.

### Schema versions are a release coupling

Everything ArkDeck verifies about a distribution comes from `distribution-manifest.json` except
three values: `parserAdapterVersion`, `schemaAdapterVersion`, and `indexSchemaVersion`. Those it
asserts as source literals in `ArkTraceSummaryInvocationContract`, and its envelope validator
requires exact equality against our `provenance` block.

So moving `TraceDatabaseStagingPreparer.indexVersion` — or either adapter version — is not a
local change. Until a matching ArkDeck release lands, every analyzer Job fails **after admission**
with `analyzer.schemaMismatch: trace-summary@1 produced JSON outside ArkTrace contract 1.0`, while
`arkdeck operation list` still reports the operation `available`. The failure is invisible to a
pin that predates the bump, so it surfaces only when the distribution is rebuilt.

`95ab38d` moved the index schema from 2 to 3; ArkDeck PR #1340 carried the matching change. Diff a
candidate's `provenance` block against those three literals before re-pinning.

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
| Analyzer Job | `job-103395125067567883342ceed0bc1b36` |
| Derived Artifact | `ART-bd09e3971266d9fd9584b2dc17117c1b` |
| Derived bytes | 1,760 bytes; SHA-256 `a76b2df77939caa56bb6f990b3e3e2fece1044ab530fbdca8ce027ffc2fb30de` |
| Tool | SHA-256 `a7859d691e5edbe6a15352dbfbc08adb3e95f1e8979e9c59b8b642b752b32efa` |
| TraceStreamer | 4.3.7; SHA-256 `66887fae680650e2c56adf518ef76679e896a4d09aba7000e05b3db4918772e9` |

After `launchctl kickstart -k`, the daemon returned ready, the operation remained available, and
the derived Artifact remained readable with the same SHA-256. The path-free machine evidence is
`Fixtures/release-evidence/phase5-arkdeck-real-artifact.json`; the retained exact derived bytes are
`Fixtures/release-evidence/phase5-arkdeck-real-artifact-summary.json`. `scripts/test_phase5.sh`
rehashes those bytes and closes their source, parser, distribution, Job, restart, and lineage
relationships.

## Historical large-evidence deferral

This Phase 5 run used a real small Trace captured by ArkDeck and closed Gate 9. At that time it
did not close the separate >500 MiB fixture and performance gates. Gates 6/7 were subsequently
closed with independent large-trace evidence on 2026-08-15, as recorded in [DESIGN.md](./DESIGN.md)
§24 and [TASKS.md](./TASKS.md) §4. That historical result does not replace a new candidate's
required validation: missing required large-trace inputs still fail the applicable gate.
