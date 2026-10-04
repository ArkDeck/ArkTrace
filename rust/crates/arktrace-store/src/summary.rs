use crate::{
    DatabaseInspection, StoreError,
    counters::{CounterSchema, absolute_time_filter},
    database::{DEFAULT_VM_BUDGET, Database, integer, text},
    events::absolute_intersection,
};
use arktrace_contract::{
    QualityCategory, QualityIssue, TraceBoundedCount, TraceEventSourceCount,
    TraceEventSourceCounts, TraceSummaryFacts, TraceSummaryQuery,
};
use rusqlite::{
    Row, params_from_iter,
    types::{Value, ValueRef},
};
use std::collections::{BTreeMap, BTreeSet};

/// Whole-request policy, independent of result limits: each SQL statement also
/// retains the usual two-million-step bound. Decode credit is shared (128 MiB).
const SUMMARY_VM_STEPS: u64 = 8_000_000;

struct Prefix {
    end: bool,
    row_id: Option<&'static str>,
}
impl Prefix {
    fn sql(&self, table: &str, projection: &str) -> String {
        match self.row_id {
            Some(alias) => format!("SELECT {projection} FROM {table} ORDER BY {alias} ASC LIMIT ?"),
            None => format!("SELECT {projection} FROM {table} NOT INDEXED LIMIT ?"),
        }
    }
}
pub(crate) struct SummarySchema {
    prefixes: BTreeMap<&'static str, Prefix>,
}
impl SummarySchema {
    pub(crate) fn read(
        db: &Database<'_>,
        inspection: &DatabaseInspection,
    ) -> Result<Self, StoreError> {
        let mut tables = vec!["process", "thread"];
        if inspection.capabilities.cpu_counters {
            tables.push("cpu_measure_filter");
        }
        if inspection.capabilities.process_counters {
            tables.push("process_measure_filter");
        }
        if inspection.event_source_counts_available {
            tables.push("stat");
        }
        let mut prefixes = BTreeMap::new();
        for table in tables {
            let columns = db.query(
                &format!("PRAGMA table_xinfo({table})"),
                [],
                2000,
                DEFAULT_VM_BUDGET,
                |r| text(r, 1),
            )?;
            let kind = db.query("SELECT wr FROM pragma_table_list(?) WHERE schema='main' AND name=? AND type='table' LIMIT 2", [table, table], 2, 10_000, |r| integer(r, 0))?;
            if kind.len() != 1 || ![0, 1].contains(&kind[0]) {
                return Err(StoreError::SchemaUnsupported);
            }
            let row_id = (kind[0] == 0)
                .then(|| {
                    ["rowid", "_rowid_", "oid"]
                        .into_iter()
                        .find(|alias| !columns.iter().any(|c| c.eq_ignore_ascii_case(alias)))
                })
                .flatten();
            prefixes.insert(
                table,
                Prefix {
                    end: columns.iter().any(|c| c == "end_ts"),
                    row_id,
                },
            );
        }
        Ok(Self { prefixes })
    }
    fn prefix(&self, table: &str) -> Result<&Prefix, StoreError> {
        self.prefixes
            .get(table)
            .ok_or(StoreError::SchemaUnsupported)
    }
    pub(crate) fn facts(
        &self,
        db: &Database<'_>,
        inspection: &DatabaseInspection,
        counters: &CounterSchema,
        query: &TraceSummaryQuery,
    ) -> Result<TraceSummaryFacts, StoreError> {
        query
            .validate()
            .map_err(|_| StoreError::InvalidSummaryQuery)?;
        db.check()?;
        let window = Window::new(inspection, query)?;
        let db = db.summary_request(SUMMARY_VM_STEPS)?;
        let event_limit = query.maximum_events_per_section;
        let mut issues = Vec::new();
        // CPU discovery is whole-trace topology. Preserve the original Swift
        // predicate even at a saturated end (its CPU path has no final OR).
        let cpu_count = if inspection.capabilities.cpu_scheduling {
            let (predicate, mut values) = absolute_intersection(
                inspection.trace_start_ts,
                inspection.trace_end_ts.saturating_add(1),
                inspection.trace_end_ts,
            );
            values.push(Value::Integer(event_limit as i64 + 1));
            Some(count(
                &db,
                &format!(
                    "SELECT COUNT(*) FROM (SELECT DISTINCT s.cpu FROM sched_slice s WHERE typeof(s.cpu)='integer' AND {predicate} LIMIT ?)"
                ),
                values,
                event_limit,
            )?)
        } else {
            None
        };
        let process_count = self.directory(
            &db,
            "process",
            "ipid",
            window,
            query.maximum_rows_per_section,
            &mut issues,
        )?;
        let thread_count = self.directory(
            &db,
            "thread",
            "itid",
            window,
            query.maximum_rows_per_section,
            &mut issues,
        )?;
        let cpu_slice_count = inspection
            .capabilities
            .cpu_scheduling
            .then(|| event_count(&db, inspection, "sched_slice", window, event_limit))
            .transpose()?;
        let thread_state_count = inspection
            .capabilities
            .thread_states
            .then(|| event_count(&db, inspection, "thread_state", window, event_limit))
            .transpose()?;
        let named_slice_count = inspection
            .capabilities
            .named_slices
            .then(|| event_count(&db, inspection, "callstack", window, event_limit))
            .transpose()?;
        let counter_series_count =
            self.counter_count(&db, inspection, counters, window, event_limit)?;
        let event_count_by_source =
            if query.range.is_none() && inspection.event_source_counts_available {
                Some(self.sources(&db, event_limit, &mut issues)?)
            } else {
                None
            };
        db.check()?;
        Ok(TraceSummaryFacts {
            cpu_count,
            process_count,
            thread_count,
            cpu_slice_count,
            thread_state_count,
            named_slice_count,
            counter_series_count,
            event_count_by_source,
            data_quality_issues: issues,
        })
    }
    fn directory(
        &self,
        db: &Database<'_>,
        table: &str,
        identity: &str,
        window: Window,
        limit: usize,
        issues: &mut Vec<QualityIssue>,
    ) -> Result<TraceBoundedCount, StoreError> {
        let prefix = self.prefix(table)?;
        let sql = prefix.sql(
            table,
            &format!(
                "{identity},start_ts,{}",
                if prefix.end { "end_ts" } else { "NULL" }
            ),
        );
        let rows = db.query(
            &sql,
            [limit as i64 + 1],
            limit + 1,
            DEFAULT_VM_BUDGET,
            |r| Ok((scalar(r, 0)?, scalar(r, 1)?, scalar(r, 2)?)),
        )?;
        let tail = rows.len() > limit;
        let (mut value, mut invalid, mut unknown) = (0, 0, 0);
        for (index, (identity, start, end)) in rows.into_iter().take(limit).enumerate() {
            if index.is_multiple_of(1024) {
                db.check()?;
            }
            let Scalar::Integer(identity) = identity else {
                return Err(StoreError::InvalidIdentity);
            };
            if identity == 0 {
                continue;
            }
            let start = match start {
                Scalar::Integer(v) => Some(v),
                Scalar::Null => {
                    unknown += 1;
                    None
                }
                Scalar::Invalid => {
                    invalid += 1;
                    continue;
                }
            };
            let ends_after_start = match end {
                Scalar::Integer(end) => {
                    if start.is_some_and(|start| end <= start) {
                        invalid += 1;
                        continue;
                    }
                    end > window.start
                }
                Scalar::Null => true,
                Scalar::Invalid => {
                    invalid += 1;
                    continue;
                }
            };
            if ends_after_start
                && start.is_none_or(|start| {
                    start < window.end || (window.final_timestamp && start == window.end)
                })
            {
                value += 1;
            }
        }
        if tail {
            issue(
                issues,
                QualityCategory::ProbeTruncated,
                &format!("{table}.lifecycle"),
                None,
            )?;
        }
        if invalid > 0 {
            issue(
                issues,
                QualityCategory::InvalidValue,
                &format!("{table}.lifecycle"),
                Some(invalid),
            )?;
        }
        if unknown > 0 {
            issue(
                issues,
                QualityCategory::UnavailableValue,
                &format!("{table}.start_ts"),
                Some(unknown),
            )?;
        }
        Ok(TraceBoundedCount {
            value,
            truncated: tail || invalid > 0,
        })
    }
    fn filter_ids(
        &self,
        db: &Database<'_>,
        table: &str,
        limit: usize,
    ) -> Result<(BTreeSet<i64>, bool), StoreError> {
        let rows = db.query(
            &self.prefix(table)?.sql(table, "id"),
            [limit as i64 + 1],
            limit + 1,
            DEFAULT_VM_BUDGET,
            |r| scalar(r, 0),
        )?;
        let mut incomplete = rows.len() > limit;
        let mut ids = BTreeSet::new();
        for (index, row) in rows.into_iter().take(limit).enumerate() {
            if index.is_multiple_of(1024) {
                db.check()?;
            }
            if let Scalar::Integer(id) = row {
                ids.insert(id);
            } else {
                incomplete = true;
            }
        }
        Ok((ids, incomplete))
    }
    fn counter_count(
        &self,
        db: &Database<'_>,
        inspection: &DatabaseInspection,
        counters: &CounterSchema,
        window: Window,
        limit: usize,
    ) -> Result<Option<TraceBoundedCount>, StoreError> {
        if !inspection.capabilities.cpu_counters && !inspection.capabilities.process_counters {
            return Ok(None);
        }
        let tables: Vec<_> = inspection
            .cpu_counter_sample_tables
            .iter()
            .chain(&inspection.process_counter_sample_tables)
            .copied()
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect();
        let mut branches = Vec::new();
        let mut values = Vec::new();
        for (index, table) in tables.iter().enumerate() {
            let (predicate, mut bindings) = absolute_time_filter(
                window.start,
                window.end,
                inspection.trace_end_ts,
                counters.has_duration(*table)?,
            );
            let predicate = window.include_final(predicate, &mut bindings, "m.ts");
            branches.push(format!("SELECT DISTINCT {index} AS sample_table,m.filter_id AS filter_id FROM {} m WHERE typeof(m.filter_id)='integer' AND ({predicate})", table.name()));
            values.extend(bindings);
        }
        values.push(Value::Integer(limit as i64 + 1));
        let rows = db.query(&format!("SELECT sample_table,filter_id FROM ({}) ORDER BY sample_table ASC,filter_id ASC LIMIT ?", branches.join(" UNION ALL ")), params_from_iter(values), limit + 1, DEFAULT_VM_BUDGET, |r| Ok((integer(r, 0)?, integer(r, 1)?)))?;
        let mut incomplete = rows.len() > limit;
        let mut filters = Vec::new();
        for (enabled, scope, table, eligible) in [
            (
                inspection.capabilities.cpu_counters,
                0,
                "cpu_measure_filter",
                &inspection.cpu_counter_sample_tables,
            ),
            (
                inspection.capabilities.process_counters,
                1,
                "process_measure_filter",
                &inspection.process_counter_sample_tables,
            ),
        ] {
            if enabled {
                let (ids, truncated) = self.filter_ids(db, table, limit)?;
                incomplete |= truncated;
                filters.push((scope, eligible, ids));
            }
        }
        let mut series = BTreeSet::new();
        for (index, (table_index, id)) in rows.into_iter().take(limit).enumerate() {
            if index.is_multiple_of(1024) {
                db.check()?;
            }
            let Some(table) = usize::try_from(table_index)
                .ok()
                .and_then(|i| tables.get(i))
            else {
                incomplete = true;
                continue;
            };
            for (scope, eligible, ids) in &filters {
                if eligible.contains(table) && ids.contains(&id) {
                    series.insert((*scope, id));
                }
            }
        }
        Ok(Some(TraceBoundedCount {
            value: series.len() as i64,
            truncated: incomplete,
        }))
    }
    fn sources(
        &self,
        db: &Database<'_>,
        limit: usize,
        issues: &mut Vec<QualityIssue>,
    ) -> Result<TraceEventSourceCounts, StoreError> {
        let sql = self.prefix("stat")?.sql("stat", "CASE WHEN typeof(source)='text' AND length(CAST(source AS BLOB)) BETWEEN 1 AND 256 THEN source ELSE NULL END, CASE WHEN typeof(event_name)='text' AND length(CAST(event_name AS BLOB))<=256 THEN 1 ELSE 0 END, count, typeof(stat_type)='text', typeof(stat_type)='text' AND stat_type='received'");
        let rows = db.query(
            &sql,
            [limit as i64 + 1],
            limit + 1,
            DEFAULT_VM_BUDGET,
            |r| {
                let source = match r.get_ref(0).map_err(crate::database::sqlite_error)? {
                    ValueRef::Text(v) => Some(v.to_vec()),
                    _ => None,
                };
                Ok((
                    source,
                    integer(r, 1)? != 0,
                    scalar(r, 2)?,
                    integer(r, 3)? != 0,
                    integer(r, 4)? != 0,
                ))
            },
        )?;
        let mut truncated = rows.len() > limit;
        let mut totals: BTreeMap<String, i64> = BTreeMap::new();
        let mut invalid_utf8 = 0;
        for (index, (source, valid_name, count, valid_type, received)) in
            rows.into_iter().take(limit).enumerate()
        {
            if index.is_multiple_of(1024) {
                db.check()?;
            }
            if !valid_type {
                truncated = true;
                continue;
            }
            if !received {
                continue;
            }
            let (Some(source), true, Scalar::Integer(count)) = (source, valid_name, count) else {
                truncated = true;
                continue;
            };
            if count < 0 {
                truncated = true;
                continue;
            }
            let source = match String::from_utf8(source) {
                Ok(source) => source,
                Err(_) => {
                    truncated = true;
                    invalid_utf8 += 1;
                    continue;
                }
            };
            let total = totals.entry(source).or_default();
            *total = total
                .checked_add(count)
                .ok_or(StoreError::SummaryQueryFailed)?;
        }
        if invalid_utf8 > 0 {
            issue(
                issues,
                QualityCategory::InvalidValue,
                "stat.source",
                Some(invalid_utf8),
            )?;
        }
        // Rust String ordering compares UTF-8 bytes, preserving NUL and distinct
        // canonically equivalent Unicode spellings just like Swift Data keys.
        let mut items = Vec::with_capacity(totals.len());
        for (index, (source, count)) in totals.into_iter().enumerate() {
            if index.is_multiple_of(1024) {
                db.check()?;
            }
            items.push(TraceEventSourceCount { source, count });
        }
        Ok(TraceEventSourceCounts { items, truncated })
    }
}
#[derive(Clone, Copy)]
struct Window {
    start: i64,
    end: i64,
    final_timestamp: bool,
}
impl Window {
    fn new(inspection: &DatabaseInspection, query: &TraceSummaryQuery) -> Result<Self, StoreError> {
        if let Some(range) = query.range {
            if range.end_ns() > inspection.duration_ns {
                return Err(StoreError::InvalidSummaryQuery);
            }
            Ok(Self {
                start: inspection
                    .trace_start_ts
                    .checked_add(range.start_ns())
                    .ok_or(StoreError::InvalidSummaryQuery)?,
                end: inspection
                    .trace_start_ts
                    .checked_add(range.end_ns())
                    .ok_or(StoreError::InvalidSummaryQuery)?,
                final_timestamp: false,
            })
        } else {
            Ok(Self {
                start: inspection.trace_start_ts,
                end: inspection.trace_end_ts.saturating_add(1),
                final_timestamp: inspection.trace_end_ts == i64::MAX,
            })
        }
    }
    fn include_final(self, predicate: String, values: &mut Vec<Value>, timestamp: &str) -> String {
        if self.final_timestamp {
            values.push(Value::Integer(self.end));
            format!("({predicate}) OR (typeof({timestamp})='integer' AND {timestamp}=?)")
        } else {
            predicate
        }
    }
}
#[derive(Clone, Copy)]
enum Scalar {
    Integer(i64),
    Null,
    Invalid,
}
fn scalar(row: &Row<'_>, index: usize) -> Result<Scalar, StoreError> {
    Ok(
        match row.get_ref(index).map_err(crate::database::sqlite_error)? {
            ValueRef::Integer(v) => Scalar::Integer(v),
            ValueRef::Null => Scalar::Null,
            _ => Scalar::Invalid,
        },
    )
}
fn issue(
    issues: &mut Vec<QualityIssue>,
    category: QualityCategory,
    scope: &str,
    count: Option<i64>,
) -> Result<(), StoreError> {
    issues.push(
        QualityIssue {
            category,
            scope: Some(scope.to_owned()),
            count,
            message: None,
        }
        .into_machine()
        .map_err(|_| StoreError::InvalidQualityContract)?,
    );
    Ok(())
}
fn count(
    db: &Database<'_>,
    sql: &str,
    values: Vec<Value>,
    limit: usize,
) -> Result<TraceBoundedCount, StoreError> {
    let rows = db.query(sql, params_from_iter(values), 1, DEFAULT_VM_BUDGET, |r| {
        integer(r, 0)
    })?;
    let [value] = rows.as_slice() else {
        return Err(StoreError::SummaryQueryFailed);
    };
    if *value < 0 {
        return Err(StoreError::SummaryQueryFailed);
    }
    Ok(TraceBoundedCount {
        value: (*value).min(limit as i64),
        truncated: *value > limit as i64,
    })
}
fn event_count(
    db: &Database<'_>,
    inspection: &DatabaseInspection,
    table: &str,
    window: Window,
    limit: usize,
) -> Result<TraceBoundedCount, StoreError> {
    let (predicate, mut values) =
        absolute_intersection(window.start, window.end, inspection.trace_end_ts);
    let predicate = window.include_final(predicate, &mut values, "s.ts");
    values.push(Value::Integer(limit as i64 + 1));
    count(
        db,
        &format!("SELECT COUNT(*) FROM (SELECT 1 FROM {table} s WHERE {predicate} LIMIT ?)"),
        values,
        limit,
    )
}

#[cfg(test)]
mod tests;
