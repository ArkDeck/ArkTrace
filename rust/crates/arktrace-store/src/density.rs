//! Aggregate only in SQLite. At most one identity per bucket is read back;
//! identities are attributes used for colour, never invented selectable events.
use crate::{
    CounterSampleTable, DatabaseInspection, StoreError,
    counters::{CounterSchema, time_filter},
    database::{DEFAULT_VM_BUDGET, Database},
    events::{intersection, optional_integer, optional_text},
    frames::FrameSchema,
};
use arktrace_contract::{
    DataQuality, QualityCategory, QualityIssue, QualityStatus, TraceDensityBucket,
    TraceDensityIdentity, TraceDensityQuery, TraceDensityResult, TraceDensitySource,
    TraceTimeRange,
};
use rusqlite::{params_from_iter, types::Value};
use std::collections::{BTreeMap, BTreeSet};

pub(crate) fn density(
    db: &Database<'_>,
    inspection: &DatabaseInspection,
    counters: &CounterSchema,
    frames: FrameSchema,
    query: &TraceDensityQuery,
) -> Result<TraceDensityResult, StoreError> {
    db.check()?;
    query.validate().map_err(|_| StoreError::InvalidQuery)?;
    // Density validates absolute bounds even when the source is unavailable.
    let (intersection, time_values) = intersection(inspection, query.range)?;
    let duration = query.range.duration_ns();
    let width =
        duration / query.bucket_count as i64 + i64::from(duration % query.bucket_count as i64 != 0);
    let start = inspection
        .trace_start_ts
        .checked_add(query.range.start_ns())
        .ok_or(StoreError::InvalidQuery)?;
    let caps = &inspection.capabilities;
    let (available, scope) = match query.source {
        TraceDensitySource::Cpu { .. } => (caps.cpu_scheduling, "sched_slice.ts"),
        TraceDensitySource::ThreadState { .. } => (caps.thread_states, "thread_state.ts"),
        TraceDensitySource::NamedSlice { .. } => (caps.named_slices, "callstack.ts"),
        TraceDensitySource::CpuCounter { .. } => (caps.cpu_counters, "measure.ts"),
        TraceDensitySource::ProcessCounter { .. } => (caps.process_counters, "process_measure.ts"),
        TraceDensitySource::Frame { .. } => (frames.available(), "frame_slice.ts"),
    };
    if !available {
        return result(Vec::new(), false, Vec::new());
    }
    // Buckets are assembled outside the row mapper. Account for their typed
    // Vec and identity-map overhead before allocating either.
    db.reserve_decoded(
        (query.bucket_count as u64)
            .checked_mul((std::mem::size_of::<TraceDensityBucket>() as u64 + 128) * 4)
            .ok_or(StoreError::DecodedBudgetExceeded)?,
    )?;
    let mut bindings = Vec::new();
    let source_sql = match query.source {
        TraceDensitySource::CpuCounter { filter_id, cpu } => counter_source(
            db,
            inspection,
            counters,
            query,
            width,
            filter_id,
            cpu,
            &inspection.cpu_counter_sample_tables,
            "cpu_measure_filter",
            "cpu",
            &mut bindings,
        )?,
        TraceDensitySource::ProcessCounter {
            filter_id,
            process_key,
        } => counter_source(
            db,
            inspection,
            counters,
            query,
            width,
            filter_id,
            process_key.map(|v| v.ipid),
            &inspection.process_counter_sample_tables,
            "process_measure_filter",
            "ipid",
            &mut bindings,
        )?,
        _ => {
            let (table, index, alias, condition, filter) = match query.source {
                TraceDensitySource::Cpu { cpu } => (
                    "sched_slice",
                    " INDEXED BY arktrace_v3_sched_slice_cpu_ts_dur",
                    "s",
                    "AND typeof(s.cpu)='integer' AND s.cpu=?",
                    Some(cpu),
                ),
                TraceDensitySource::ThreadState { thread } => (
                    "thread_state",
                    " INDEXED BY arktrace_v3_thread_state_itid_ts_dur",
                    "s",
                    "AND typeof(s.itid)='integer' AND s.itid=?",
                    Some(thread.itid),
                ),
                TraceDensitySource::NamedSlice {
                    thread: Some(thread),
                } => (
                    "callstack",
                    " INDEXED BY arktrace_v3_callstack_callid_ts_dur",
                    "s",
                    "AND typeof(s.callid)='integer' AND s.callid=?",
                    Some(thread.itid),
                ),
                TraceDensitySource::NamedSlice { thread: None } => (
                    "callstack",
                    " INDEXED BY arktrace_v3_callstack_callid_ts_dur",
                    "s",
                    "AND (s.callid IS NULL OR s.callid=0)",
                    None,
                ),
                TraceDensitySource::Frame {
                    process_key: Some(key),
                } => (
                    "frame_slice",
                    "",
                    "f",
                    "AND typeof(f.ipid)='integer' AND f.ipid=?",
                    Some(key.ipid),
                ),
                TraceDensitySource::Frame { process_key: None } => {
                    ("frame_slice", "", "f", "", None)
                }
                _ => return Err(StoreError::InvalidQuery),
            };
            bindings.extend(
                [
                    start,
                    start,
                    width,
                    inspection.trace_start_ts,
                    inspection.trace_end_ts,
                ]
                .map(Value::Integer),
            );
            bindings.extend(time_values);
            if let Some(v) = filter {
                bindings.push(Value::Integer(v));
            }
            let bucket = bucket_sql(alias, query.bucket_count);
            let predicate = intersection[0].replace("s.", &format!("{alias}."));
            format!(
                "SELECT {bucket} AS bucket, CASE WHEN {alias}.ts<? OR {alias}.ts>? THEN 1 ELSE 0 END AS clamped, 0 AS invalid_duration, 0 AS clamped_duration, {alias}.rowid AS identity_row, {alias}.dur AS weight FROM {table} AS {alias}{index} WHERE {predicate} {condition}"
            )
        }
    };
    // SQLite's single MAX selects the real witness row for each bucket,
    // including its established tie behaviour. No LIMIT is applied to events.
    let sql = format!(
        "WITH sampled AS ({source_sql}) SELECT bucket,COUNT(*),identity_row,MAX(weight),SUM(clamped),SUM(invalid_duration),SUM(clamped_duration) FROM sampled GROUP BY bucket ORDER BY bucket ASC LIMIT {}",
        query.bucket_count
    );
    let rows = db.query(
        &sql,
        params_from_iter(bindings),
        query.bucket_count,
        DEFAULT_VM_BUDGET,
        |r| {
            Ok(Aggregate {
                bucket: optional_integer(r, 0)?,
                count: optional_integer(r, 1)?,
                identity: optional_integer(r, 2)?,
                clamped: optional_integer(r, 4)?,
                invalid_duration: optional_integer(r, 5)?,
                clamped_duration: optional_integer(r, 6)?,
            })
        },
    )?;
    let mut buckets = Vec::with_capacity(rows.len());
    let mut counts = [0i64; 3];
    for (index, row) in rows.iter().enumerate() {
        if index.is_multiple_of(256) {
            db.check()?;
        }
        let bucket = row
            .bucket
            .filter(|v| *v >= 0 && *v < query.bucket_count as i64)
            .ok_or(StoreError::InvalidDatabase)?;
        let event_count = row
            .count
            .filter(|v| *v >= 0)
            .ok_or(StoreError::InvalidDatabase)?;
        let start = bucket
            .checked_mul(width)
            .and_then(|v| v.checked_add(query.range.start_ns()))
            .ok_or(StoreError::InvalidDatabase)?;
        let end = start
            .checked_add(width)
            .unwrap_or(query.range.end_ns())
            .min(query.range.end_ns());
        let range = TraceTimeRange::query(start, end).map_err(|_| StoreError::InvalidQuery)?;
        for (count, v) in
            counts
                .iter_mut()
                .zip([row.clamped, row.invalid_duration, row.clamped_duration])
        {
            *count = count
                .checked_add(v.unwrap_or(0))
                .filter(|v| *v >= 0)
                .ok_or(StoreError::InvalidDatabase)?;
        }
        buckets.push(TraceDensityBucket {
            range,
            event_count,
            occupied_ns: None,
            utilization: None,
            dominant: None,
        });
    }
    let identities = resolve_identities(db, &query.source, &rows)?;
    for (index, (bucket, row)) in buckets.iter_mut().zip(&rows).enumerate() {
        if index.is_multiple_of(256) {
            db.check()?;
        }
        bucket.dominant = row.identity.and_then(|v| identities.get(&v)).cloned();
    }
    let mut issues = inspection.data_quality.warnings.clone();
    for (count, category, scope) in [
        (counts[0], QualityCategory::ClampedValue, scope),
        (
            counts[1],
            QualityCategory::DroppedValue,
            "timeline.counter.duration",
        ),
        (
            counts[2],
            QualityCategory::ClampedValue,
            "timeline.counter.duration",
        ),
    ] {
        if count > 0 {
            issues.push(issue(category, scope, Some(count)));
        }
    }
    if !buckets.is_empty() {
        issues.push(issue(
            QualityCategory::UnavailableValue,
            "timeline.density.occupancy",
            None,
        ));
    }
    if buckets.iter().any(|v| v.dominant.is_none()) {
        issues.push(issue(
            QualityCategory::UnavailableValue,
            "timeline.density.dominantThread",
            None,
        ));
    }
    db.check()?;
    result(buckets, true, issues)
}

fn bucket_sql(alias: &str, count: usize) -> String {
    format!(
        "MIN({},MAX(0,CASE WHEN {alias}.ts<=? THEN 0 ELSE ({alias}.ts-?)/? END))",
        count - 1
    )
}
#[allow(clippy::too_many_arguments)]
fn counter_source(
    db: &Database<'_>,
    inspection: &DatabaseInspection,
    schema: &CounterSchema,
    query: &TraceDensityQuery,
    width: i64,
    filter_id: i64,
    scope: Option<i64>,
    tables: &[CounterSampleTable],
    filter: &str,
    column: &str,
    bindings: &mut Vec<Value>,
) -> Result<String, StoreError> {
    let start = inspection
        .trace_start_ts
        .checked_add(query.range.start_ns())
        .ok_or(StoreError::InvalidQuery)?;
    let mut branches = Vec::new();
    for table in tables {
        db.check()?;
        let duration = schema.has_duration(*table)?;
        let (time, values) = time_filter(inspection, query.range, duration)?;
        bindings.extend(
            [
                start,
                start,
                width,
                inspection.trace_start_ts,
                inspection.trace_end_ts,
            ]
            .map(Value::Integer),
        );
        let (invalid, clamped) = if duration {
            bindings.extend([inspection.duration_ns, inspection.trace_end_ts].map(Value::Integer));
            (
                "CASE WHEN m.dur IS NOT NULL AND typeof(m.dur)<>'integer' THEN 1 ELSE 0 END",
                "CASE WHEN typeof(m.dur)='integer' AND m.dur>0 AND (m.dur>? OR m.ts+m.dur>?) THEN 1 ELSE 0 END",
            )
        } else {
            ("0", "0")
        };
        bindings.extend(values);
        bindings.push(Value::Integer(filter_id));
        if let Some(v) = scope {
            bindings.push(Value::Integer(v));
        }
        let bucket = bucket_sql("m", query.bucket_count);
        let scoped = if scope.is_some() {
            format!("AND f.{column}=?")
        } else {
            String::new()
        };
        branches.push(format!("SELECT {bucket} AS bucket, CASE WHEN m.ts<? OR m.ts>? THEN 1 ELSE 0 END AS clamped, {invalid} AS invalid_duration, {clamped} AS clamped_duration, NULL AS identity_row,0 AS weight FROM {} AS m INNER JOIN {filter} AS f ON f.id=m.filter_id WHERE typeof(m.ts)='integer' AND typeof(m.filter_id)='integer' AND typeof(f.id)='integer' AND typeof(f.{column})='integer' AND ({time}) AND f.id=? {scoped}", table.name()));
    }
    if branches.is_empty() {
        return Err(StoreError::InvalidDatabase);
    }
    Ok(branches.join(" UNION ALL "))
}
struct Aggregate {
    bucket: Option<i64>,
    count: Option<i64>,
    identity: Option<i64>,
    clamped: Option<i64>,
    invalid_duration: Option<i64>,
    clamped_duration: Option<i64>,
}
fn resolve_identities(
    db: &Database<'_>,
    source: &TraceDensitySource,
    rows: &[Aggregate],
) -> Result<BTreeMap<i64, TraceDensityIdentity>, StoreError> {
    let ids = rows
        .iter()
        .filter_map(|v| v.identity)
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect::<Vec<_>>();
    let mut result = BTreeMap::new();
    if matches!(
        source,
        TraceDensitySource::CpuCounter { .. } | TraceDensitySource::ProcessCounter { .. }
    ) {
        return Ok(result);
    }
    // Matches the hardened connection's 128-variable ceiling, even with
    // 40,000 buckets. Never raise a connection limit to accommodate a query.
    for chunk in ids.chunks(128) {
        db.check()?;
        let placeholders = vec!["?"; chunk.len()].join(",");
        let (select, table): (String, &str) = match source {
            TraceDensitySource::Cpu { .. } => ("r.rowid,p.pid,t.tid".into(), "sched_slice AS r LEFT JOIN process AS p ON p.ipid=r.ipid LEFT JOIN thread AS t ON t.itid=r.itid"),
            TraceDensitySource::ThreadState { .. } => ("r.rowid,CASE WHEN typeof(r.state)='text' AND length(CAST(r.state AS BLOB))<=256 THEN r.state ELSE NULL END".into(), "thread_state AS r"),
            TraceDensitySource::NamedSlice { .. } => ("r.rowid,CASE WHEN typeof(r.name)='text' AND length(CAST(r.name AS BLOB))<=4096 THEN r.name ELSE NULL END".into(), "callstack AS r"),
            TraceDensitySource::Frame { .. } => ("r.rowid,CASE WHEN typeof(r.flag)='integer' THEN r.flag ELSE NULL END".into(), "frame_slice AS r"),
            _ => return Ok(result),
        };
        let sql = format!(
            "SELECT {select} FROM {table} WHERE r.rowid IN ({placeholders}) LIMIT {}",
            chunk.len()
        );
        let values = db.query(
            &sql,
            params_from_iter(chunk),
            chunk.len(),
            DEFAULT_VM_BUDGET,
            |r| {
                let id = optional_integer(r, 0)?;
                let identity = match source {
                    TraceDensitySource::Cpu { .. } => {
                        let pid = optional_integer(r, 1)?.unwrap_or(0);
                        let tid = optional_integer(r, 2)?.unwrap_or(0);
                        let value = if pid > 0 { pid } else { tid };
                        (value > 0)
                            .then_some(TraceDensityIdentity::ProcessOrThread { identity: value })
                    }
                    TraceDensitySource::ThreadState { .. } => optional_text(r, 1)?
                        .filter(|v| !v.is_empty())
                        .map(|state| TraceDensityIdentity::ThreadState { state }),
                    TraceDensitySource::NamedSlice { .. } => optional_text(r, 1)?
                        .filter(|v| !v.is_empty())
                        .map(|name| TraceDensityIdentity::Name { name }),
                    TraceDensitySource::Frame { .. } => {
                        optional_integer(r, 1)?.map(|flag| TraceDensityIdentity::Jank { flag })
                    }
                    _ => None,
                };
                Ok(id.zip(identity))
            },
        )?;
        for (id, identity) in values.into_iter().flatten() {
            result.insert(id, identity);
        }
    }
    Ok(result)
}
fn issue(category: QualityCategory, scope: &str, count: Option<i64>) -> QualityIssue {
    QualityIssue {
        category,
        scope: Some(scope.into()),
        count,
        message: None,
    }
}
fn result(
    buckets: Vec<TraceDensityBucket>,
    capability_available: bool,
    issues: Vec<QualityIssue>,
) -> Result<TraceDensityResult, StoreError> {
    let status = if issues.is_empty() {
        QualityStatus::Ok
    } else {
        QualityStatus::Warnings
    };
    Ok(TraceDensityResult {
        buckets,
        capability_available,
        data_quality: DataQuality::machine(status, issues)
            .map_err(|_| StoreError::InvalidQualityContract)?,
    })
}
