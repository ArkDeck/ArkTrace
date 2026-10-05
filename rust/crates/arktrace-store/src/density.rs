//! Stream all matching rows into fixed bucket state under one SQL VM budget.
//! At most one identity per bucket survives; identities are attributes used
//! for colour, never invented selectable events.
use crate::{
    CounterSampleTable, DatabaseInspection, StoreError,
    counters::CounterSchema,
    database::{DEFAULT_VM_BUDGET, Database},
    events::{absolute_bounds, optional_integer, optional_text},
    frames::FrameSchema,
};
use arktrace_contract::{
    DataQuality, QualityCategory, QualityIssue, QualityStatus, TraceDensityBucket,
    TraceDensityIdentity, TraceDensityQuery, TraceDensityResult, TraceDensitySource,
    TraceTimeRange,
};
use rusqlite::{
    params_from_iter,
    types::{Value, ValueRef},
};
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
    let (start, _) = absolute_bounds(inspection, query.range)?;
    let duration = query.range.duration_ns();
    let width =
        duration / query.bucket_count as i64 + i64::from(duration % query.bucket_count as i64 != 0);
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
            filter_id,
            process_key.map(|v| v.ipid),
            &inspection.process_counter_sample_tables,
            "process_measure_filter",
            "ipid",
            &mut bindings,
        )?,
        _ => interval_source(inspection, query, &mut bindings)?,
    };
    let rows = aggregate_rows(db, inspection, query, start, width, &source_sql, bindings)?;
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

#[cfg(test)]
fn bucket_sql(alias: &str, count: usize) -> String {
    format!(
        "MIN({},MAX(0,CASE WHEN {alias}.ts<=? THEN 0 ELSE ({alias}.ts-?)/? END))",
        count - 1
    )
}

fn interval_source(
    inspection: &DatabaseInspection,
    query: &TraceDensityQuery,
    bindings: &mut Vec<Value>,
) -> Result<String, StoreError> {
    let (table, index, condition, filter) = match query.source {
        TraceDensitySource::Cpu { cpu } => (
            "sched_slice",
            " INDEXED BY arktrace_v3_sched_slice_cpu_ts_dur",
            "AND typeof(s.cpu)='integer' AND s.cpu=?",
            Some(cpu),
        ),
        TraceDensitySource::ThreadState { thread } => (
            "thread_state",
            " INDEXED BY arktrace_v3_thread_state_itid_ts_dur",
            "AND typeof(s.itid)='integer' AND s.itid=?",
            Some(thread.itid),
        ),
        TraceDensitySource::NamedSlice {
            thread: Some(thread),
        } => (
            "callstack",
            " INDEXED BY arktrace_v3_callstack_callid_ts_dur",
            "AND typeof(s.callid)='integer' AND s.callid=?",
            Some(thread.itid),
        ),
        TraceDensitySource::NamedSlice { thread: None } => (
            "callstack",
            " INDEXED BY arktrace_v3_callstack_callid_ts_dur",
            "AND (s.callid IS NULL OR s.callid=0)",
            None,
        ),
        TraceDensitySource::Frame {
            process_key: Some(key),
        } => (
            "frame_slice",
            "",
            "AND typeof(s.ipid)='integer' AND s.ipid=?",
            Some(key.ipid),
        ),
        TraceDensitySource::Frame { process_key: None } => ("frame_slice", "", "", None),
        _ => return Err(StoreError::InvalidQuery),
    };
    let (start, end) = absolute_bounds(inspection, query.range)?;
    bindings.extend([end, start, start].map(Value::Integer));
    if let Some(value) = filter {
        bindings.push(Value::Integer(value));
    }
    // The validated trace-relative query ends at or before trace_end. This is
    // the shared half-open intersection with redundant branches removed; no
    // ts+dur arithmetic, event LIMIT or event sample is introduced.
    Ok(format!("SELECT s.rowid,s.ts,s.dur FROM {table} s{index}
        WHERE typeof(s.ts)='integer' AND(s.dur IS NULL OR typeof(s.dur)='integer')
        AND s.ts<? AND(s.ts>=? OR s.dur IS NULL OR s.dur<0 OR(s.dur>0 AND s.dur>?-s.ts)) {condition}"))
}

#[allow(clippy::too_many_arguments)]
fn counter_source(
    db: &Database<'_>,
    inspection: &DatabaseInspection,
    schema: &CounterSchema,
    query: &TraceDensityQuery,
    filter_id: i64,
    scope: Option<i64>,
    tables: &[CounterSampleTable],
    filter: &str,
    column: &str,
    bindings: &mut Vec<Value>,
) -> Result<String, StoreError> {
    let (start, end) = absolute_bounds(inspection, query.range)?;
    let mut branches = Vec::new();
    for table in tables {
        db.check()?;
        let duration = schema.has_duration(*table)?;
        let (time, raw_duration) = if duration {
            bindings.extend([end, start, start].map(Value::Integer));
            // Malformed durations count as instants. NULL/negative INTEGER
            // durations remain open-ended, including before the query start.
            (
                "m.ts<? AND(m.ts>=? OR m.dur IS NULL OR(typeof(m.dur)='integer' AND(m.dur<0 OR(m.dur>0 AND m.dur>?-m.ts))))",
                "m.dur",
            )
        } else {
            bindings.extend([start, end].map(Value::Integer));
            ("m.ts>=? AND m.ts<?", "NULL")
        };
        bindings.push(Value::Integer(filter_id));
        if let Some(value) = scope {
            bindings.push(Value::Integer(value));
        }
        let scoped = if scope.is_some() {
            format!("AND f.{column}=?")
        } else {
            String::new()
        };
        branches.push(format!("SELECT NULL,m.ts,{raw_duration} FROM {} m INNER JOIN {filter} f ON f.id=m.filter_id
            WHERE typeof(m.ts)='integer' AND typeof(m.filter_id)='integer' AND typeof(f.id)='integer'
            AND typeof(f.{column})='integer' AND({time}) AND f.id=? {scoped}", table.name()));
    }
    if branches.is_empty() {
        return Err(StoreError::InvalidDatabase);
    }
    // One statement retains one VM credit across both process sample tables.
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
#[derive(Clone, Copy, Default)]
struct Accumulator {
    count: i64,
    identity: Option<i64>,
    weight: Option<i64>,
    clamped: i64,
    invalid_duration: i64,
    clamped_duration: i64,
}

fn aggregate_rows(
    db: &Database<'_>,
    inspection: &DatabaseInspection,
    query: &TraceDensityQuery,
    start: i64,
    width: i64,
    sql: &str,
    bindings: Vec<Value>,
) -> Result<Vec<Aggregate>, StoreError> {
    let counter = matches!(
        query.source,
        TraceDensitySource::CpuCounter { .. } | TraceDensitySource::ProcessCounter { .. }
    );
    // The caller credited bucket state before allocation. No event Vec or
    // decoded strings survive a source row, and VM credit is not reset.
    let mut state = vec![Accumulator::default(); query.bucket_count];
    db.visit(sql, params_from_iter(bindings), DEFAULT_VM_BUDGET, |row| {
        let identity = optional_integer(row, 0)?;
        let timestamp = optional_integer(row, 1)?.ok_or(StoreError::InvalidDatabase)?;
        let duration = optional_integer(row, 2)?;
        let weight = if counter { Some(0) } else { duration };
        let index = if timestamp <= start {
            0
        } else {
            timestamp
                .checked_sub(start)
                .ok_or(StoreError::InvalidDatabase)?
                / width
        }
        .min(query.bucket_count as i64 - 1) as usize;
        let aggregate = &mut state[index];
        // SQLite's single MAX retains the first equal non-null maximum; when
        // every weight is NULL, its bare witness comes from the last row.
        if aggregate.count == 0
            || aggregate.weight.is_none()
            || weight.is_some_and(|value| aggregate.weight.is_some_and(|old| value > old))
        {
            aggregate.identity = identity;
            aggregate.weight = weight;
        }
        aggregate.count = aggregate
            .count
            .checked_add(1)
            .ok_or(StoreError::InvalidDatabase)?;
        if timestamp < inspection.trace_start_ts || timestamp > inspection.trace_end_ts {
            aggregate.clamped = aggregate
                .clamped
                .checked_add(1)
                .ok_or(StoreError::InvalidDatabase)?;
        }
        if counter {
            let malformed = !matches!(
                row.get_ref(2).map_err(crate::database::sqlite_error)?,
                ValueRef::Integer(_) | ValueRef::Null
            );
            let clamped = duration.is_some_and(|value| {
                value > 0
                    && (value > inspection.duration_ns
                        || i128::from(timestamp) + i128::from(value)
                            > i128::from(inspection.trace_end_ts))
            });
            aggregate.invalid_duration = aggregate
                .invalid_duration
                .checked_add(i64::from(malformed))
                .ok_or(StoreError::InvalidDatabase)?;
            aggregate.clamped_duration = aggregate
                .clamped_duration
                .checked_add(i64::from(clamped))
                .ok_or(StoreError::InvalidDatabase)?;
        }
        Ok(())
    })?;
    Ok(state
        .into_iter()
        .enumerate()
        .filter(|(_, value)| value.count > 0)
        .map(|(bucket, value)| Aggregate {
            bucket: Some(bucket as i64),
            count: Some(value.count),
            identity: value.identity,
            clamped: Some(value.clamped),
            invalid_duration: Some(value.invalid_duration),
            clamped_duration: Some(value.clamped_duration),
        })
        .collect())
}

#[cfg(test)]
fn cpu_aggregate(
    db: &Database<'_>,
    inspection: &DatabaseInspection,
    query: &TraceDensityQuery,
    cpu: i64,
    width: i64,
) -> Result<Vec<Aggregate>, StoreError> {
    assert_eq!(query.source, TraceDensitySource::Cpu { cpu });
    let mut bindings = Vec::new();
    let sql = interval_source(inspection, query, &mut bindings)?;
    let (start, _) = absolute_bounds(inspection, query.range)?;
    aggregate_rows(db, inspection, query, start, width, &sql, bindings)
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

#[cfg(test)]
mod cpu_stream_tests {
    use super::*;
    use crate::ValidationBudget;
    use arktrace_platform::CancellationToken;
    use rusqlite::Connection;
    use std::time::{Duration, Instant};

    fn fixture(extra: &str) -> (Connection, DatabaseInspection) {
        let c = Connection::open_in_memory().unwrap();
        c.execute_batch("CREATE TABLE trace_range(start_ts INTEGER,end_ts INTEGER); INSERT INTO trace_range VALUES(1000,1000000);
            CREATE TABLE process(ipid INTEGER,pid INTEGER,name TEXT,start_ts INTEGER); INSERT INTO process VALUES(1,42,'process',1000);
            CREATE TABLE thread(itid INTEGER,tid INTEGER,name TEXT,start_ts INTEGER,ipid INTEGER); INSERT INTO thread VALUES(1,43,'thread',1000,1);
            CREATE TABLE sched_slice(id INTEGER,ts INTEGER,dur INTEGER,cpu INTEGER,itid INTEGER,ipid INTEGER);
            CREATE INDEX arktrace_v3_sched_slice_cpu_ts_dur ON sched_slice(cpu,ts,dur);
            CREATE TABLE thread_state(id INTEGER,ts INTEGER,dur INTEGER,itid INTEGER,state TEXT);
            CREATE TABLE callstack(id INTEGER,ts INTEGER,dur INTEGER,callid INTEGER,name TEXT);").unwrap();
        c.execute_batch(extra).unwrap();
        let b = budget();
        let inspection = Database::borrow_writable(&c, &b)
            .unwrap()
            .inspect()
            .unwrap();
        (c, inspection)
    }
    fn budget() -> ValidationBudget {
        ValidationBudget {
            maximum_database_bytes: 256 * 1024 * 1024,
            deadline: Instant::now() + Duration::from_secs(10),
            cancellation: CancellationToken::default(),
        }
    }
    fn request(start: i64, end: i64, buckets: usize) -> TraceDensityQuery {
        TraceDensityQuery {
            range: TraceTimeRange::query(start, end).unwrap(),
            source: TraceDensitySource::Cpu { cpu: 0 },
            bucket_count: buckets,
        }
    }
    type ReferenceRow = (Option<i64>, Option<i64>, Option<i64>, Option<i64>);

    // Independent SQLite aggregate reference retains its MAX/bare-witness
    // behavior; a larger reference-only budget does not change product credit.
    fn reference(
        db: &Database<'_>,
        inspection: &DatabaseInspection,
        q: &TraceDensityQuery,
        steps: u64,
    ) -> Result<Vec<ReferenceRow>, StoreError> {
        let (start, end) = absolute_bounds(inspection, q.range)?;
        let width = q.range.duration_ns() / q.bucket_count as i64
            + i64::from(q.range.duration_ns() % q.bucket_count as i64 != 0);
        let (predicate, time) =
            crate::events::absolute_intersection(start, end, inspection.trace_end_ts);
        let mut values = vec![
            Value::Integer(start),
            Value::Integer(start),
            Value::Integer(width),
            Value::Integer(inspection.trace_start_ts),
            Value::Integer(inspection.trace_end_ts),
        ];
        values.extend(time);
        db.query(&format!("WITH sampled AS (SELECT {} AS bucket,
            CASE WHEN s.ts<? OR s.ts>? THEN 1 ELSE 0 END AS clamped,s.rowid AS witness,s.dur AS weight
            FROM sched_slice s INDEXED BY arktrace_v3_sched_slice_cpu_ts_dur
            WHERE {predicate} AND typeof(s.cpu)='integer' AND s.cpu=0)
            SELECT bucket,COUNT(*),witness,MAX(weight),SUM(clamped) FROM sampled GROUP BY bucket ORDER BY bucket", bucket_sql("s",q.bucket_count)),
            params_from_iter(values), q.bucket_count, steps,
            |r| Ok((optional_integer(r,0)?,optional_integer(r,1)?,optional_integer(r,2)?,optional_integer(r,4)?)))
    }
    fn compared(rows: Vec<Aggregate>) -> Vec<ReferenceRow> {
        rows.into_iter()
            .map(|r| (r.bucket, r.count, r.identity, r.clamped))
            .collect()
    }
    #[test]
    fn full_cpu_density_fits_existing_credit_and_matches_sqlite_without_sampling() {
        let (c, inspection) = fixture(
            "WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<60000)
            INSERT INTO sched_slice SELECT i,1000+i*10,1,0,1,1 FROM n;",
        );
        let b = budget();
        let db = Database::borrow_writable(&c, &b).unwrap();
        let q = request(0, 999000, 150);
        assert_eq!(
            reference(&db, &inspection, &q, DEFAULT_VM_BUDGET),
            Err(StoreError::VmBudgetExceeded)
        );
        let expected = reference(&db, &inspection, &q, 20_000_000).unwrap();
        let width = q.range.duration_ns() / 150;
        let actual = cpu_aggregate(&db, &inspection, &q, 0, width).unwrap();
        assert_eq!(actual.iter().map(|r| r.count.unwrap()).sum::<i64>(), 60000);
        assert_eq!(compared(actual), expected);
    }
    #[test]
    fn cpu_witness_ties_nulls_instants_open_ends_and_clamping_match_sqlite() {
        let (c, inspection) = fixture(
            "INSERT INTO sched_slice VALUES
            (1,900,NULL,0,1,1),(2,1000,NULL,0,1,1),(3,1000,NULL,0,1,1),
            (4,1100,10,0,1,1),(5,1100,10,0,1,1),(6,1200,0,0,1,1),
            (7,1299,-1,0,1,1),(8,1300,0,0,1,1),(9,1400,1.5,0,1,1),
            (10,1450,1,'bad',1,1),(11,'bad',1,0,1,1),
            (12,-9223372036854775808,9223372036854775807,0,1,1);",
        );
        let b = budget();
        let db = Database::borrow_writable(&c, &b).unwrap();
        for (start, end, buckets) in [
            (0, 600, 6),
            (0, 100, 1),
            (100, 300, 2),
            (200, 300, 1),
            (0, 999000, 150),
        ] {
            let q = request(start, end, buckets);
            let width = q.range.duration_ns() / buckets as i64
                + i64::from(q.range.duration_ns() % buckets as i64 != 0);
            assert_eq!(
                compared(cpu_aggregate(&db, &inspection, &q, 0, width).unwrap()),
                reference(&db, &inspection, &q, DEFAULT_VM_BUDGET).unwrap()
            );
        }
    }
    #[test]
    fn busy_cpu_thread_slice_and_counter_results_keep_every_row_and_identity() {
        let (c, inspection) = fixture(
            "CREATE INDEX arktrace_v3_thread_state_itid_ts_dur ON thread_state(itid,ts,dur);
            CREATE INDEX arktrace_v3_callstack_callid_ts_dur ON callstack(callid,ts,dur);
            CREATE TABLE measure(ts INTEGER,value INTEGER,filter_id INTEGER,dur INTEGER);
            CREATE INDEX counter_filter_time ON measure(filter_id,ts);
            CREATE TABLE cpu_measure_filter(id INTEGER,name TEXT,cpu INTEGER);
            INSERT INTO cpu_measure_filter VALUES(1,'counter',0);
            WITH RECURSIVE n(i) AS(VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<60000)
            INSERT INTO sched_slice SELECT i,1000+i*10,1,0,1,1 FROM n;
            INSERT INTO thread_state SELECT id,ts,dur,itid,'Running' FROM sched_slice;
            INSERT INTO callstack SELECT id,ts,dur,itid,'busy' FROM sched_slice;
            INSERT INTO measure SELECT ts,1,1,dur FROM sched_slice;",
        );
        let b = budget();
        let db = Database::borrow_writable(&c, &b).unwrap();
        let counters = CounterSchema::read(&db, &inspection).unwrap();
        let frames = FrameSchema::read(&db).unwrap();
        for source in [
            TraceDensitySource::Cpu { cpu: 0 },
            TraceDensitySource::ThreadState {
                thread: arktrace_contract::ThreadKey { itid: 1 },
            },
            TraceDensitySource::NamedSlice {
                thread: Some(arktrace_contract::ThreadKey { itid: 1 }),
            },
            TraceDensitySource::CpuCounter {
                filter_id: 1,
                cpu: Some(0),
            },
        ] {
            let q = TraceDensityQuery {
                source: source.clone(),
                ..request(0, 999000, 150)
            };
            let result = density(&db, &inspection, &counters, frames, &q).unwrap();
            assert!(result.capability_available);
            assert_eq!(
                result.buckets.iter().map(|v| v.event_count).sum::<i64>(),
                60000
            );
            let expected = match source {
                TraceDensitySource::Cpu { .. } => {
                    Some(TraceDensityIdentity::ProcessOrThread { identity: 42 })
                }
                TraceDensitySource::ThreadState { .. } => Some(TraceDensityIdentity::ThreadState {
                    state: "Running".into(),
                }),
                TraceDensitySource::NamedSlice { .. } => Some(TraceDensityIdentity::Name {
                    name: "busy".into(),
                }),
                _ => None,
            };
            assert!(result.buckets.iter().all(|v| v.dominant == expected));
        }
    }
}
