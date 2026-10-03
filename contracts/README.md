# Migration contracts

The existing Swift implementation is the initial behavior oracle. Machine JSON
1.0 fixtures remain authoritative in `Tests/ArkTraceCLITests/Fixtures/MachineJSON`;
`machine-fixtures-index.json` records their original bytes, rather than copying
an independently editable corpus here.

`time-range-vectors.json` and `quality-vectors.json` are run against both Swift
and Rust. They cover Int64 bounds, half-open intervals, instants, invalid inputs
and the corrected diagnostic-message privacy boundary. Rust quality scopes are
generated at build time from `quality-scopes.json`, verified against the current
Swift source by `scripts/verify_migration_contracts.py`.
The counter-source budget vector includes `schema.counterSource`: the existing
Swift Store emits this optional degradation, so both machine boundaries now
recognize it and remove its diagnostic prose. This corrects the previously
missing closed-vocabulary entry; it does not make an unproven source readable.

`cache-lease-vectors.json` covers the existing length-prefixed parser key,
entry identifier and `.locks`/`.leases` layout in Swift and Rust. It freezes the
key-lock → exclusive entry lease → owner-lock order and Windows lock offset
as decimal text to preserve all 64 bits. The native macOS tests prove `flock`
exclusion against another process. Native ArkDeck purge interoperability,
owner recovery and Windows `LockFileEx` admission remain separate acceptance.

These are the first AT-RUST-001 vectors. Query, analysis, lifecycle, Viewer,
distribution and ABI contracts will be added when those capabilities migrate.
This directory does not claim those contracts are already frozen or implemented.

`index-definitions.json` freezes all 24 current Swift index definitions in their
existing creation order, with columns, bootstrap/required flags and nonunique,
nonpartial shape. `verify_migration_contracts.py` checks the current Swift source;
Rust consumes the same corpus for private preparation and full index introspection.
Index schema version remains 3. Five definitions bootstrap schema validation,
17 are required; absent optional columns disable the corresponding optional index.

`ready-metadata.json` is the format-1 codec fixture. Its 13 root, 8 parser, 6 key
and 5 preparation fields match current Swift types; timestamps retain ISO 8601.
Both implementations round-trip it, and unknown nested fields remain rejected.
This freezes codec compatibility, not a production signature or Ready artifact.

Comparison levels follow the migration design: T0 exact canonical bytes for
the same identity; T1 explicitly selected semantic comparison with actual
provenance verified separately; T2 host/presentation differences. Never discard
whole provenance, quality or truncation sections to obtain parity.
