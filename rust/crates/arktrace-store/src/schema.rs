use crate::database::{DEFAULT_VM_BUDGET, Database, integer, text};
use crate::{
    CounterSampleTable, DatabaseInspection, RELATIONSHIP_VM_BUDGET, StoreError, TraceCapabilities,
};
use arktrace_contract::{DataQuality, QualityCategory, QualityIssue, QualityStatus};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

const PROBE_ROWS: usize = 1024;
const MAX_TABLES: usize = 4096;
const MAX_COLUMNS: usize = 65536;
const MAX_SCHEMA_BYTES: usize = 16 * 1024 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Affinity {
    Integer,
    Text,
    Blob,
    Real,
    Numeric,
}
fn affinity(declared: &str) -> Affinity {
    let value = declared.to_uppercase();
    if value.contains("INT") {
        Affinity::Integer
    } else if ["CHAR", "CLOB", "TEXT"].iter().any(|s| value.contains(s)) {
        Affinity::Text
    } else if value.is_empty() || value.contains("BLOB") {
        Affinity::Blob
    } else if ["REAL", "FLOA", "DOUB"].iter().any(|s| value.contains(s)) {
        Affinity::Real
    } else {
        Affinity::Numeric
    }
}
#[derive(Clone, Debug)]
struct Column {
    name: String,
    declared: String,
    not_null: bool,
    primary_key: u64,
    hidden: u64,
}
type Catalog = BTreeMap<String, Vec<Column>>;
type Requirements = &'static [(&'static str, Affinity)];
const REQUIRED: &[(&str, Requirements)] = &[
    (
        "trace_range",
        &[
            ("start_ts", Affinity::Integer),
            ("end_ts", Affinity::Integer),
        ],
    ),
    (
        "process",
        &[
            ("ipid", Affinity::Integer),
            ("pid", Affinity::Integer),
            ("name", Affinity::Text),
            ("start_ts", Affinity::Integer),
        ],
    ),
    (
        "thread",
        &[
            ("itid", Affinity::Integer),
            ("tid", Affinity::Integer),
            ("name", Affinity::Text),
            ("start_ts", Affinity::Integer),
            ("ipid", Affinity::Integer),
        ],
    ),
    (
        "sched_slice",
        &[
            ("id", Affinity::Integer),
            ("ts", Affinity::Integer),
            ("dur", Affinity::Integer),
            ("cpu", Affinity::Integer),
            ("itid", Affinity::Integer),
            ("ipid", Affinity::Integer),
        ],
    ),
    (
        "thread_state",
        &[
            ("id", Affinity::Integer),
            ("ts", Affinity::Integer),
            ("dur", Affinity::Integer),
            ("itid", Affinity::Integer),
            ("state", Affinity::Text),
        ],
    ),
    (
        "callstack",
        &[
            ("id", Affinity::Integer),
            ("ts", Affinity::Integer),
            ("dur", Affinity::Integer),
            ("callid", Affinity::Integer),
            ("name", Affinity::Text),
        ],
    ),
];
const MEASURE: Requirements = &[
    ("ts", Affinity::Integer),
    ("value", Affinity::Integer),
    ("filter_id", Affinity::Integer),
];
const CPU_FILTER: Requirements = &[
    ("id", Affinity::Integer),
    ("name", Affinity::Text),
    ("cpu", Affinity::Integer),
];
const PROCESS_FILTER: Requirements = &[
    ("id", Affinity::Integer),
    ("name", Affinity::Text),
    ("ipid", Affinity::Integer),
];

fn quote(identifier: &str) -> Result<String, StoreError> {
    if identifier.contains('\0') {
        return Err(StoreError::InvalidDatabase);
    }
    Ok(format!("\"{}\"", identifier.replace('"', "\"\"")))
}
fn catalog(db: &Database<'_>) -> Result<Catalog, StoreError> {
    let tables = db.query(
        "SELECT name FROM sqlite_master WHERE type='table' LIMIT 4097",
        [],
        MAX_TABLES + 1,
        DEFAULT_VM_BUDGET,
        |row| text(row, 0),
    )?;
    if tables.len() > MAX_TABLES {
        return Err(StoreError::SchemaBudgetExceeded);
    }
    let mut catalog = Catalog::new();
    let mut column_count = 0;
    let mut bytes = 0;
    for table in tables {
        db.check()?;
        let sql = format!("PRAGMA table_xinfo({})", quote(&table)?);
        let columns = db.query(&sql, [], 2000, DEFAULT_VM_BUDGET, |row| {
            let primary_key = integer(row, 5)?;
            let hidden = integer(row, 6)?;
            if primary_key < 0 || !(0..=3).contains(&hidden) {
                return Err(StoreError::InvalidDatabase);
            }
            Ok(Column {
                name: text(row, 1)?,
                declared: text(row, 2)?,
                not_null: integer(row, 3)? != 0,
                primary_key: primary_key as u64,
                hidden: hidden as u64,
            })
        })?;
        column_count += columns.len();
        bytes += columns
            .iter()
            .map(|col| table.len() + col.name.len() + col.declared.len() + 48)
            .sum::<usize>();
        if column_count > MAX_COLUMNS || bytes > MAX_SCHEMA_BYTES {
            return Err(StoreError::SchemaBudgetExceeded);
        }
        if catalog.insert(table, columns).is_some() {
            return Err(StoreError::InvalidDatabase);
        }
    }
    Ok(catalog)
}
fn compatible(catalog: &Catalog, table: &str, required: Requirements) -> bool {
    catalog.get(table).is_some_and(|columns| {
        required.iter().all(|(name, expected)| {
            columns
                .iter()
                .find(|col| col.name == *name)
                .is_some_and(|col| affinity(&col.declared) == *expected)
        })
    })
}
fn has_column(catalog: &Catalog, table: &str, column: &str) -> bool {
    catalog
        .get(table)
        .is_some_and(|columns| columns.iter().any(|col| col.name == column))
}
fn exists(db: &Database<'_>, sql: &str, budget: u64) -> Result<bool, StoreError> {
    Ok(!db.query(sql, [], 1, budget, |_| Ok(true))?.is_empty())
}
fn has_rows(db: &Database<'_>, table: &str) -> Result<bool, StoreError> {
    exists(
        db,
        &format!("SELECT 1 FROM {table} LIMIT 1"),
        DEFAULT_VM_BUDGET,
    )
}
fn counter_sources(
    db: &Database<'_>,
    catalog: &Catalog,
    candidates: &[CounterSampleTable],
    filter: &str,
    filter_columns: Requirements,
    issues: &mut Vec<QualityIssue>,
) -> Result<Vec<CounterSampleTable>, StoreError> {
    let mut sources = Vec::new();
    for candidate in candidates {
        let table = candidate.name();
        if !compatible(catalog, table, MEASURE) || !compatible(catalog, filter, filter_columns) {
            continue;
        }
        let sql = format!("SELECT 1 FROM {table} AS sampled_measure CROSS JOIN {filter} AS sampled_filter
            ON sampled_filter.id = sampled_measure.filter_id
            WHERE typeof(sampled_measure.filter_id)='integer' AND typeof(sampled_filter.id)='integer' LIMIT 1");
        match exists(db, &sql, RELATIONSHIP_VM_BUDGET) {
            Ok(true) => sources.push(*candidate),
            Ok(false) => {}
            Err(StoreError::VmBudgetExceeded) => record(
                issues,
                QualityCategory::ProbeTruncated,
                "schema.counterSource",
                None,
            ),
            Err(error) => return Err(error),
        }
    }
    Ok(sources)
}
fn required_probe(db: &Database<'_>, sql: &str) -> Result<bool, StoreError> {
    exists(db, sql, RELATIONSHIP_VM_BUDGET).map_err(|error| match error {
        StoreError::VmBudgetExceeded => StoreError::SchemaUnsupported,
        other => other,
    })
}
fn unique_filter(db: &Database<'_>, filter: &str) -> Result<(), StoreError> {
    if required_probe(
        db,
        &format!(
            "SELECT 1 FROM (SELECT id FROM {filter} WHERE typeof(id)='integer'
        GROUP BY id HAVING COUNT(*)>1 LIMIT 1)"
        ),
    )? {
        return Err(StoreError::AmbiguousCounterIdentity);
    }
    Ok(())
}
fn required_identities(db: &Database<'_>) -> Result<(), StoreError> {
    for (table, predicate) in [
        (
            "process",
            "typeof(ipid)<>'integer' OR typeof(pid)<>'integer'",
        ),
        (
            "thread",
            "typeof(itid)<>'integer' OR typeof(tid)<>'integer' OR (ipid IS NOT NULL AND typeof(ipid)<>'integer')",
        ),
        (
            "sched_slice",
            "typeof(id)<>'integer' OR (itid IS NOT NULL AND typeof(itid)<>'integer') OR (ipid IS NOT NULL AND typeof(ipid)<>'integer')",
        ),
        (
            "thread_state",
            "typeof(id)<>'integer' OR (itid IS NOT NULL AND typeof(itid)<>'integer')",
        ),
        (
            "callstack",
            "typeof(id)<>'integer' OR typeof(callid)<>'integer'",
        ),
    ] {
        if exists(
            db,
            &format!(
                "SELECT 1 FROM (SELECT * FROM {table} LIMIT {PROBE_ROWS} OFFSET 0) AS sampled WHERE {predicate} LIMIT 1"
            ),
            DEFAULT_VM_BUDGET,
        )? {
            return Err(StoreError::InvalidIdentity);
        }
    }
    Ok(())
}
fn required_relationships(db: &Database<'_>) -> Result<(), StoreError> {
    for (source, column, target, key) in [
        ("thread", "ipid", "process", "ipid"),
        ("sched_slice", "itid", "thread", "itid"),
        ("sched_slice", "ipid", "process", "ipid"),
        ("thread_state", "itid", "thread", "itid"),
    ] {
        if required_probe(db, &format!("SELECT 1 FROM (SELECT {column} AS identity FROM {source} LIMIT {PROBE_ROWS} OFFSET 0) AS sampled
            LEFT JOIN {target} AS target ON target.{key}=sampled.identity
            WHERE typeof(sampled.identity)='integer' AND sampled.identity<>0 AND target.{key} IS NULL LIMIT 1"))? {
            return Err(StoreError::BrokenRelationship);
        }
    }
    Ok(())
}
fn trace_range(db: &Database<'_>) -> Result<(i64, i64, i64), StoreError> {
    let range = db.query(
        "SELECT start_ts,end_ts FROM trace_range LIMIT 2",
        [],
        2,
        DEFAULT_VM_BUDGET,
        |row| Ok((integer(row, 0)?, integer(row, 1)?)),
    )?;
    let [(start, end)] = range.as_slice() else {
        return Err(StoreError::InvalidDatabase);
    };
    let duration = end
        .checked_sub(*start)
        .filter(|d| *d > 0)
        .ok_or(StoreError::InvalidDatabase)?;
    let corrected = credible_start(db, *start, *end)?.unwrap_or(*start);
    let effective_duration = end
        .checked_sub(corrected)
        .filter(|d| *d > 0)
        .ok_or(StoreError::InvalidDatabase)?;
    debug_assert!(duration >= effective_duration);
    Ok((corrected, *end, effective_duration))
}
fn credible_start(db: &Database<'_>, start: i64, end: i64) -> Result<Option<i64>, StoreError> {
    let mut samples = Vec::new();
    for table in ["sched_slice", "thread_state", "callstack"] {
        let values = db
            .query(
                &format!("SELECT ts FROM {table} WHERE typeof(ts)='integer' LIMIT {PROBE_ROWS}"),
                [],
                PROBE_ROWS,
                DEFAULT_VM_BUDGET,
                |row| integer(row, 0),
            )?
            .into_iter()
            .filter(|ts| *ts >= start && *ts <= end)
            .collect::<Vec<_>>();
        if !values.is_empty() {
            samples.push(values);
        }
    }
    if samples.len() < 2 {
        return Ok(None);
    }
    let mut medians = samples
        .iter()
        .map(|sample| {
            let mut sorted = sample.clone();
            sorted.sort_unstable();
            sorted[sorted.len() / 2]
        })
        .collect::<Vec<_>>();
    medians.sort_unstable();
    let anchor = medians[medians.len() / 2];
    let (Some(gap), Some(remaining)) = (anchor.checked_sub(start), end.checked_sub(anchor)) else {
        return Ok(None);
    };
    if gap <= 60_000_000_000 || remaining <= 0 || gap / remaining < 8 {
        return Ok(None);
    }
    let lookback = remaining
        .checked_mul(2)
        .map_or(i64::MAX, |d| d.max(1_000_000_000));
    let lower = anchor
        .checked_sub(lookback)
        .map_or(start, |ts| start.max(ts));
    let credible = samples
        .iter()
        .map(|values| {
            values
                .iter()
                .copied()
                .filter(|ts| *ts >= lower && *ts <= end)
                .collect::<Vec<_>>()
        })
        .filter(|values| !values.is_empty())
        .collect::<Vec<_>>();
    if credible.len() < 2 {
        return Ok(None);
    }
    Ok(credible.into_iter().flatten().min())
}
fn record(
    issues: &mut Vec<QualityIssue>,
    category: QualityCategory,
    scope: &str,
    count: Option<i64>,
) {
    issues.push(QualityIssue {
        category,
        scope: Some(scope.to_owned()),
        count,
        message: None,
    });
}

fn quality(
    db: &Database<'_>,
    catalog: &Catalog,
    range: (i64, i64, i64),
) -> Result<Vec<QualityIssue>, StoreError> {
    let mut issues = Vec::new();
    for (table, column) in [
        ("process", "start_ts"),
        ("process", "end_ts"),
        ("thread", "start_ts"),
        ("thread", "end_ts"),
        ("sched_slice", "ts"),
        ("sched_slice", "dur"),
        ("thread_state", "ts"),
        ("thread_state", "dur"),
        ("callstack", "ts"),
        ("callstack", "dur"),
        ("measure", "ts"),
        ("process_measure", "ts"),
    ] {
        if !has_column(catalog, table, column) {
            continue;
        }
        let (lower, upper) = if column == "dur" {
            (0, i64::MAX)
        } else {
            (range.0, range.1)
        };
        let sql = format!("SELECT COUNT(*), COALESCE(SUM(CASE WHEN typeof(value) NOT IN ('integer','null') THEN 1 ELSE 0 END),0),
            COALESCE(SUM(CASE WHEN typeof(value)='integer' AND value<? THEN 1 ELSE 0 END),0),
            COALESCE(SUM(CASE WHEN typeof(value)='integer' AND value>? THEN 1 ELSE 0 END),0)
            FROM (SELECT {column} AS value FROM {table} LIMIT 1025 OFFSET 0) AS sampled");
        let counts = db.query(&sql, [lower, upper], 1, DEFAULT_VM_BUDGET, |row| {
            Ok([
                integer(row, 0)?,
                integer(row, 1)?,
                integer(row, 2)?,
                integer(row, 3)?,
            ])
        })?[0];
        let scope = format!("{table}.{column}");
        if counts[1] > 0 {
            record(
                &mut issues,
                QualityCategory::DroppedValue,
                &scope,
                Some(counts[1].min(PROBE_ROWS as i64)),
            );
        }
        // Every negative duration is an open-ended sentinel, never corruption.
        if column != "dur" {
            for count in [counts[2], counts[3]] {
                if count > 0 {
                    record(
                        &mut issues,
                        QualityCategory::ClampedValue,
                        &scope,
                        Some(count.min(PROBE_ROWS as i64)),
                    );
                }
            }
        }
        if counts[0] > PROBE_ROWS as i64 {
            record(&mut issues, QualityCategory::ProbeTruncated, &scope, None);
        }
    }
    for (table, column, expected, allows_null) in [
        ("sched_slice", "cpu", "integer", false),
        ("thread_state", "cpu", "integer", true),
        ("callstack", "depth", "integer", true),
        ("callstack", "parent_id", "integer", true),
        ("callstack", "cookie", "integer", true),
        ("measure", "filter_id", "integer", false),
        ("measure", "value", "integer", false),
        ("measure", "dur", "integer", true),
        ("process_measure", "filter_id", "integer", false),
        ("process_measure", "value", "integer", false),
        ("process_measure", "dur", "integer", true),
        ("cpu_measure_filter", "id", "integer", false),
        ("cpu_measure_filter", "name", "text", false),
        ("cpu_measure_filter", "cpu", "integer", false),
        ("cpu_measure_filter", "unit", "text", true),
        ("process_measure_filter", "id", "integer", false),
        ("process_measure_filter", "name", "text", false),
        ("process_measure_filter", "ipid", "integer", false),
        ("process_measure_filter", "unit", "text", true),
        ("stat", "count", "integer", false),
        ("stat", "source", "text", false),
        ("stat", "event_name", "text", false),
        ("stat", "stat_type", "text", false),
    ] {
        if !has_column(catalog, table, column) {
            continue;
        }
        let null = if allows_null {
            " OR typeof(value)='null'"
        } else {
            ""
        };
        let sql=format!("SELECT COUNT(*),COALESCE(SUM(CASE WHEN NOT (typeof(value)=?{null}) THEN 1 ELSE 0 END),0)
            FROM (SELECT {column} AS value FROM {table} LIMIT 1025 OFFSET 0) AS sampled");
        let counts = db.query(&sql, [expected], 1, DEFAULT_VM_BUDGET, |row| {
            Ok([integer(row, 0)?, integer(row, 1)?])
        })?[0];
        let scope = format!("{table}.{column}");
        if counts[1] > 0 {
            record(
                &mut issues,
                QualityCategory::DroppedValue,
                &scope,
                Some(counts[1].min(PROBE_ROWS as i64)),
            );
        }
        if counts[0] > PROBE_ROWS as i64 {
            record(&mut issues, QualityCategory::ProbeTruncated, &scope, None);
        }
    }
    if ["stat_type", "count", "source", "event_name"]
        .iter()
        .all(|column| has_column(catalog, "stat", column))
    {
        let counts=db.query("SELECT COUNT(*),
            COALESCE(SUM(CASE WHEN typeof(stat_type)='text' AND stat_type<>'received' THEN 1 ELSE 0 END),0),
            COALESCE(SUM(CASE WHEN typeof(count)='integer' AND count<0 THEN 1 ELSE 0 END),0),
            COALESCE(SUM(CASE WHEN typeof(source)='text' AND length(CAST(source AS BLOB)) NOT BETWEEN 1 AND 256 THEN 1 ELSE 0 END),0),
            COALESCE(SUM(CASE WHEN typeof(event_name)='text' AND length(CAST(event_name AS BLOB))>256 THEN 1 ELSE 0 END),0)
            FROM (SELECT stat_type,count,source,event_name FROM stat LIMIT 1025 OFFSET 0) AS sampled",[],1,DEFAULT_VM_BUDGET,
            |row|Ok([integer(row,0)?,integer(row,1)?,integer(row,2)?,integer(row,3)?,integer(row,4)?]))?[0];
        for (index, category, scope) in [
            (1, QualityCategory::DroppedValue, "stat.stat_type"),
            (2, QualityCategory::InvalidValue, "stat.count"),
            (3, QualityCategory::InvalidValue, "stat.source"),
            (4, QualityCategory::InvalidValue, "stat.event_name"),
        ] {
            if counts[index] > 0 {
                record(
                    &mut issues,
                    category,
                    scope,
                    Some(counts[index].min(PROBE_ROWS as i64)),
                );
            }
        }
        if counts[0] > PROBE_ROWS as i64 {
            record(&mut issues, QualityCategory::ProbeTruncated, "stat", None);
        }
    }
    Ok(issues)
}
fn fingerprint(catalog: &Catalog) -> String {
    let mut records = Vec::new();
    for (table, columns) in catalog {
        for column in columns {
            let mut record = Vec::new();
            for value in [table, &column.name, &column.declared] {
                record.extend_from_slice(&(value.len() as u64).to_be_bytes());
                record.extend_from_slice(value.as_bytes());
            }
            record.push(u8::from(column.not_null));
            record.extend_from_slice(&column.primary_key.to_be_bytes());
            if column.hidden != 0 {
                record.push(0x48);
                record.extend_from_slice(&column.hidden.to_be_bytes());
            }
            records.push(record);
        }
    }
    records.sort_unstable();
    let mut digest = Sha256::new();
    digest.update(b"ArkTraceSchemaFingerprint\0\x02");
    digest.update((records.len() as u64).to_be_bytes());
    for record in records {
        digest.update((record.len() as u64).to_be_bytes());
        digest.update(record);
    }
    format!("{:x}", digest.finalize())
}
pub(crate) fn validate(db: &Database<'_>) -> Result<DatabaseInspection, StoreError> {
    let catalog = catalog(db)?;
    if REQUIRED
        .iter()
        .any(|(table, columns)| !compatible(&catalog, table, columns))
    {
        return Err(StoreError::SchemaUnsupported);
    }
    let mut counter_issues = Vec::new();
    let cpu = counter_sources(
        db,
        &catalog,
        &[CounterSampleTable::Measure],
        "cpu_measure_filter",
        CPU_FILTER,
        &mut counter_issues,
    )?;
    let process = counter_sources(
        db,
        &catalog,
        &[
            CounterSampleTable::ProcessMeasure,
            CounterSampleTable::Measure,
        ],
        "process_measure_filter",
        PROCESS_FILTER,
        &mut counter_issues,
    )?;
    if !cpu.is_empty() {
        unique_filter(db, "cpu_measure_filter")?;
    }
    if !process.is_empty() {
        unique_filter(db, "process_measure_filter")?;
    }
    if cpu.iter().any(|table|process.contains(table)) && required_probe(db,
        "SELECT 1 FROM cpu_measure_filter AS cpu INNER JOIN process_measure_filter AS process ON cpu.id=process.id
        WHERE typeof(cpu.id)='integer' AND typeof(process.id)='integer' LIMIT 1")? {
        return Err(StoreError::AmbiguousCounterIdentity);
    }
    let capabilities = TraceCapabilities {
        cpu_scheduling: has_rows(db, "sched_slice")?,
        thread_states: has_rows(db, "thread_state")?,
        named_slices: has_rows(db, "callstack")?,
        cpu_counters: !cpu.is_empty(),
        process_counters: !process.is_empty(),
    };
    let range = trace_range(db)?;
    required_identities(db)?;
    required_relationships(db)?;
    let mut issues = quality(db, &catalog, range)?;
    issues.extend(counter_issues);
    let status = if issues.is_empty() {
        QualityStatus::Ok
    } else {
        QualityStatus::Warnings
    };
    let data_quality =
        DataQuality::machine(status, issues).map_err(|_| StoreError::InvalidQualityContract)?;
    Ok(DatabaseInspection {
        capabilities,
        schema_fingerprint: fingerprint(&catalog),
        trace_start_ts: range.0,
        trace_end_ts: range.1,
        duration_ns: range.2,
        data_quality,
        event_source_counts_available: compatible(
            &catalog,
            "stat",
            &[
                ("event_name", Affinity::Text),
                ("stat_type", Affinity::Text),
                ("count", Affinity::Integer),
                ("source", Affinity::Text),
            ],
        ),
        cpu_counter_sample_tables: cpu,
        process_counter_sample_tables: process,
    })
}
