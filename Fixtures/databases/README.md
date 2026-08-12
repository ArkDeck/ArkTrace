# TraceStreamer schema evidence

`trace_streamer_4.3.7.schema-evidence.json` locks the database bytes produced by the pinned parser from the redistributable traces in `Fixtures/traces/`. Generated SQLite files are not committed: the original trace plus parser identity is the reproducible source of truth.

The integration gate regenerates each database with the production `-nm` path and verifies:

- source and database SHA-256/byte count;
- actual parser executable SHA-256 against both its manifest and the locked evidence, plus each parsed database's `metadata.parser` identity;
- exact evidence format version and canonical upstream path/blob provenance for every fixture, including a Git blob OID recomputed from the actual fixture bytes;
- pinned license path, SHA-256, byte count and Git blob OID recomputed from the actual license bytes;
- `PRAGMA quick_check`, trace range and the exact six-table required row-count set;
- the schema-adapter-v2, length-prefixed schema fingerprint and the data-aware capability set for each fixture;
- absence of the `meta` table and source/staging absolute paths;
- non-empty scheduling/state evidence in `trace_small_10.systrace` and named-slice evidence in `zlib.htrace`.

Run the evidence gate from the repository root:

```bash
swift test --filter ParserIntegrationTests/testLockedSchemaEvidence
swift test --filter ParserIntegrationTests/testRealSchedulingFixture
swift test --filter ParserIntegrationTests/testRealNamedSliceFixture
```

The recorded database hashes were also reproduced by two direct exports per fixture before being locked. Any parser, schema, fixture or export-byte drift must update the evidence in a reviewed change; tests must never silently regenerate expected values.

`parser.adapterVersion` is the TraceStreamer process-adapter identity from its build manifest. `schemaAdapterVersion` is the independent Store schema/fingerprint contract version; the similar names do not denote the same component.
