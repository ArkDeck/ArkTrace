use crate::{
    DatabaseInspection, StoreError,
    database::{DEFAULT_VM_BUDGET, Database, integer, text},
};
use arktrace_contract::{
    CpuSlice, CpuSliceQuery, DataQuality, EventKey, EventPage, EventTable, ProcessKey,
    QualityCategory, QualityIssue, QualityStatus, ThreadKey, ThreadStateInterval, ThreadStateQuery,
    TraceThreadState, TraceTimeRange,
};
use rusqlite::{
    Row, params_from_iter,
    types::{Value, ValueRef},
};
use std::collections::BTreeMap;

#[derive(Clone, Copy)]
pub(crate) struct EventSchema {
    sched_end_state: bool,
    sched_priority: bool,
    state_cpu: bool,
}
impl EventSchema {
    pub(crate) fn read(db: &Database<'_>) -> Result<Self, StoreError> {
        let sched = db.query(
            "PRAGMA table_xinfo(sched_slice)",
            [],
            2000,
            DEFAULT_VM_BUDGET,
            |r| text(r, 1),
        )?;
        let state = db.query(
            "PRAGMA table_xinfo(thread_state)",
            [],
            2000,
            DEFAULT_VM_BUDGET,
            |r| text(r, 1),
        )?;
        Ok(Self {
            sched_end_state: sched.iter().any(|c| c == "end_state"),
            sched_priority: sched.iter().any(|c| c == "priority"),
            state_cpu: state.iter().any(|c| c == "cpu"),
        })
    }
    pub(crate) fn cpu_slices(
        self,
        db: &Database<'_>,
        inspection: &DatabaseInspection,
        query: &CpuSliceQuery,
    ) -> Result<EventPage<CpuSlice>, StoreError> {
        query.validate().map_err(|_| StoreError::InvalidQuery)?;
        if !inspection.capabilities.cpu_scheduling {
            return unavailable();
        }
        let (mut conditions, mut values) = intersection(inspection, query.range)?;
        filters(
            &mut conditions,
            &mut values,
            [
                ("typeof(s.cpu)='integer' AND s.cpu", query.cpu),
                ("s.ipid", query.process_key),
                ("p.pid", query.pid),
                ("s.itid", query.thread_key),
                ("t.tid", query.tid),
            ],
        );
        values.push(Value::Integer(query.limit as i64 + 1));
        let end_state = if self.sched_end_state {
            bounded_text("s.end_state", 256)
        } else {
            "NULL".to_owned()
        };
        let priority = if self.sched_priority {
            "CASE WHEN typeof(s.priority)='integer' THEN s.priority ELSE NULL END"
        } else {
            "NULL"
        };
        let mut invalid = vec![
            invalid_integer("p.pid"),
            invalid_integer("t.tid"),
            invalid_text("p.name", 4096),
            invalid_text("t.name", 4096),
        ];
        if self.sched_end_state {
            invalid.push(invalid_text("s.end_state", 256));
        }
        if self.sched_priority {
            invalid.push(invalid_integer("s.priority"));
        }
        let sql = format!(
            "SELECT s.id,s.ts,s.dur,s.cpu,s.ipid,s.itid,p.pid,t.tid,{},{},{end_state},{priority},
             CASE WHEN s.ipid IS NOT NULL AND s.ipid<>0 AND p.ipid IS NULL THEN 1 ELSE 0 END,
             CASE WHEN s.itid IS NOT NULL AND s.itid<>0 AND t.itid IS NULL THEN 1 ELSE 0 END,{}
             FROM sched_slice s LEFT JOIN process p ON p.ipid=s.ipid LEFT JOIN thread t ON t.itid=s.itid
             WHERE {} ORDER BY s.ts ASC,s.id ASC LIMIT ?",
            bounded_text("p.name",4096), bounded_text("t.name",4096), invalid.join(" + "), conditions.join(" AND ")
        );
        let rows = db.query(
            &sql,
            params_from_iter(values),
            query.limit + 1,
            DEFAULT_VM_BUDGET,
            |r| {
                Ok(EventRow {
                    id: optional_integer(r, 0)?,
                    timestamp: optional_integer(r, 1)?,
                    duration: optional_integer(r, 2)?,
                    duration_null: r.get_ref(2).map_err(crate::database::sqlite_error)?
                        == ValueRef::Null,
                    cpu: optional_integer(r, 3)?,
                    process_key: optional_integer(r, 4)?,
                    thread_key: optional_integer(r, 5)?,
                    pid: optional_integer(r, 6)?,
                    tid: optional_integer(r, 7)?,
                    process_name: optional_text(r, 8)?,
                    thread_name: optional_text(r, 9)?,
                    state: optional_text(r, 10)?,
                    priority: optional_integer(r, 11)?,
                    missing: integer(r, 12)? + integer(r, 13)?,
                    invalid: integer(r, 14)?,
                })
            },
        )?;
        let mut items = Vec::new();
        let mut quality = EventQuality::default();
        let mut last_end = BTreeMap::<i64, i64>::new();
        for (index, row) in rows.iter().take(query.limit).enumerate() {
            if index % 1024 == 0 {
                db.check()?;
            }
            let id = row.id.ok_or(StoreError::InvalidIdentity)?;
            quality.invalid_value += row.invalid;
            let Some(cpu) = row.cpu else {
                quality.invalid_value += 1;
                continue;
            };
            let Some((range, open)) = interval(
                row.timestamp,
                row.duration,
                row.duration_null,
                inspection,
                &mut quality,
            )?
            else {
                continue;
            };
            quality.missing_reference += row.missing;
            if last_end
                .get(&cpu)
                .is_some_and(|end| range.start_ns() < *end)
            {
                quality.overlap += 1;
            }
            last_end
                .entry(cpu)
                .and_modify(|end| *end = (*end).max(range.end_ns()))
                .or_insert(range.end_ns());
            items.push(CpuSlice {
                key: EventKey {
                    table: EventTable::SchedSlice,
                    row_id: id,
                },
                range,
                cpu,
                thread_key: row
                    .thread_key
                    .filter(|v| *v != 0)
                    .map(|itid| ThreadKey { itid }),
                process_key: row
                    .process_key
                    .filter(|v| *v != 0)
                    .map(|ipid| ProcessKey { ipid }),
                tid: row.tid,
                pid: row.pid,
                thread_name: row.thread_name.clone(),
                process_name: row.process_name.clone(),
                end_state: row.state.clone(),
                priority: row.priority,
                is_open_ended: open,
            });
        }
        db.check()?;
        page(
            items,
            rows.len(),
            query.limit,
            "sched_slice",
            inspection,
            quality,
        )
    }
    pub(crate) fn thread_states(
        self,
        db: &Database<'_>,
        inspection: &DatabaseInspection,
        query: &ThreadStateQuery,
    ) -> Result<EventPage<ThreadStateInterval>, StoreError> {
        query.validate().map_err(|_| StoreError::InvalidQuery)?;
        if !inspection.capabilities.thread_states || (query.cpu.is_some() && !self.state_cpu) {
            return unavailable();
        }
        let (mut conditions, mut values) = intersection(inspection, query.range)?;
        filters(
            &mut conditions,
            &mut values,
            [
                ("typeof(s.cpu)='integer' AND s.cpu", query.cpu),
                ("t.ipid", query.process_key),
                ("p.pid", query.pid),
                ("s.itid", query.thread_key),
                ("t.tid", query.tid),
            ],
        );
        if let Some(state) = &query.raw_state {
            conditions.push("s.state=?".to_owned());
            values.push(Value::Text(state.clone()));
        }
        if let Some(state) = query.state {
            conditions.push(state_predicate(state).to_owned());
        }
        values.push(Value::Integer(query.limit as i64 + 1));
        let cpu = if self.state_cpu {
            "CASE WHEN typeof(s.cpu)='integer' THEN s.cpu ELSE NULL END"
        } else {
            "NULL"
        };
        let mut invalid = vec![
            "CASE WHEN s.itid IS NULL OR typeof(s.itid)<>'integer' OR s.itid=0 THEN 1 ELSE 0 END"
                .to_owned(),
            invalid_integer("p.pid"),
            invalid_integer("t.tid"),
        ];
        if self.state_cpu {
            invalid.push(invalid_integer("s.cpu"));
        }
        let sql = format!(
            "SELECT s.id,s.ts,s.dur,{cpu},t.ipid,s.itid,p.pid,t.tid,{},{},{},
             CASE WHEN s.itid IS NOT NULL AND s.itid<>0 AND t.itid IS NULL THEN 1 ELSE 0 END,{}
             FROM thread_state s LEFT JOIN thread t ON t.itid=s.itid LEFT JOIN process p ON p.ipid=t.ipid
             WHERE {} ORDER BY s.ts ASC,s.id ASC LIMIT ?",
            bounded_text("s.state",256), bounded_text("p.name",4096), bounded_text("t.name",4096), invalid.join(" + "), conditions.join(" AND ")
        );
        let rows = db.query(
            &sql,
            params_from_iter(values),
            query.limit + 1,
            DEFAULT_VM_BUDGET,
            |r| {
                Ok(EventRow {
                    id: optional_integer(r, 0)?,
                    timestamp: optional_integer(r, 1)?,
                    duration: optional_integer(r, 2)?,
                    duration_null: r.get_ref(2).map_err(crate::database::sqlite_error)?
                        == ValueRef::Null,
                    cpu: optional_integer(r, 3)?,
                    process_key: optional_integer(r, 4)?,
                    thread_key: optional_integer(r, 5)?,
                    pid: optional_integer(r, 6)?,
                    tid: optional_integer(r, 7)?,
                    state: optional_text(r, 8)?,
                    process_name: optional_text(r, 9)?,
                    thread_name: optional_text(r, 10)?,
                    priority: None,
                    missing: integer(r, 11)?,
                    invalid: integer(r, 12)?,
                })
            },
        )?;
        let mut items = Vec::new();
        let mut quality = EventQuality::default();
        for (index, row) in rows.iter().take(query.limit).enumerate() {
            if index % 1024 == 0 {
                db.check()?;
            }
            let id = row.id.ok_or(StoreError::InvalidIdentity)?;
            quality.invalid_value += row.invalid;
            let Some(itid) = row.thread_key.filter(|v| *v != 0) else {
                continue;
            };
            let Some(state) = &row.state else {
                quality.invalid_value += 1;
                continue;
            };
            let Some((range, open)) = interval(
                row.timestamp,
                row.duration,
                row.duration_null,
                inspection,
                &mut quality,
            )?
            else {
                continue;
            };
            let normalized = normalize_state(state);
            if normalized.is_none() {
                quality.unknown_state += 1;
            }
            quality.missing_reference += row.missing;
            items.push(ThreadStateInterval {
                key: EventKey {
                    table: EventTable::ThreadState,
                    row_id: id,
                },
                range,
                thread_key: ThreadKey { itid },
                process_key: row
                    .process_key
                    .filter(|v| *v != 0)
                    .map(|ipid| ProcessKey { ipid }),
                state: state.clone(),
                normalized_state: normalized,
                cpu: row.cpu,
                tid: row.tid,
                pid: row.pid,
                process_name: row.process_name.clone(),
                thread_name: row.thread_name.clone(),
                is_open_ended: open,
            });
        }
        db.check()?;
        page(
            items,
            rows.len(),
            query.limit,
            "thread_state",
            inspection,
            quality,
        )
    }
}

struct EventRow {
    id: Option<i64>,
    timestamp: Option<i64>,
    duration: Option<i64>,
    duration_null: bool,
    cpu: Option<i64>,
    process_key: Option<i64>,
    thread_key: Option<i64>,
    pid: Option<i64>,
    tid: Option<i64>,
    process_name: Option<String>,
    thread_name: Option<String>,
    state: Option<String>,
    priority: Option<i64>,
    missing: i64,
    invalid: i64,
}
#[derive(Default)]
pub(crate) struct EventQuality {
    pub(crate) invalid_value: i64,
    pub(crate) clamped_timestamp: i64,
    pub(crate) clamped_duration: i64,
    pub(crate) missing_reference: i64,
    unknown_state: i64,
    overlap: i64,
}
pub(crate) fn optional_integer(row: &Row<'_>, index: usize) -> Result<Option<i64>, StoreError> {
    Ok(
        match row.get_ref(index).map_err(crate::database::sqlite_error)? {
            ValueRef::Integer(v) => Some(v),
            _ => None,
        },
    )
}
pub(crate) fn optional_text(row: &Row<'_>, index: usize) -> Result<Option<String>, StoreError> {
    Ok(
        match row.get_ref(index).map_err(crate::database::sqlite_error)? {
            ValueRef::Text(bytes) => std::str::from_utf8(bytes).ok().map(str::to_owned),
            _ => None,
        },
    )
}
pub(crate) fn bounded_text(column: &str, bytes: usize) -> String {
    format!(
        "CASE WHEN typeof({column})='text' AND length(CAST({column} AS BLOB))<={bytes} THEN {column} ELSE NULL END"
    )
}
pub(crate) fn invalid_text(column: &str, bytes: usize) -> String {
    format!(
        "CASE WHEN {column} IS NOT NULL AND (typeof({column})<>'text' OR length(CAST({column} AS BLOB))>{bytes}) THEN 1 ELSE 0 END"
    )
}
pub(crate) fn invalid_integer(column: &str) -> String {
    format!("CASE WHEN {column} IS NOT NULL AND typeof({column})<>'integer' THEN 1 ELSE 0 END")
}
pub(crate) fn filters<const N: usize>(
    conditions: &mut Vec<String>,
    values: &mut Vec<Value>,
    filters: [(&str, Option<i64>); N],
) {
    for (column, value) in filters {
        if let Some(value) = value {
            conditions.push(format!("{column}=?"));
            values.push(Value::Integer(value));
        }
    }
}

/// No ts+dur in SQL: SQLite can promote overflowing sums to floating point.
/// Kept identical to Swift TraceEventIntersection, with nine integer bindings.
pub(crate) fn intersection(
    inspection: &DatabaseInspection,
    range: TraceTimeRange,
) -> Result<(Vec<String>, Vec<Value>), StoreError> {
    let (start, end) = absolute_bounds(inspection, range)?;
    let (predicate, values) = absolute_intersection(start, end, inspection.trace_end_ts);
    Ok((vec![predicate], values))
}
pub(crate) fn absolute_bounds(
    inspection: &DatabaseInspection,
    range: TraceTimeRange,
) -> Result<(i64, i64), StoreError> {
    if range.is_instant() || range.end_ns() > inspection.duration_ns {
        return Err(StoreError::InvalidQuery);
    }
    let start = inspection
        .trace_start_ts
        .checked_add(range.start_ns())
        .ok_or(StoreError::InvalidQuery)?;
    let end = inspection
        .trace_start_ts
        .checked_add(range.end_ns())
        .ok_or(StoreError::InvalidQuery)?;
    if start < inspection.trace_start_ts || end > inspection.trace_end_ts {
        return Err(StoreError::InvalidQuery);
    }
    Ok((start, end))
}
pub(crate) fn absolute_intersection(start: i64, end: i64, trace_end: i64) -> (String, Vec<Value>) {
    let sql =
        "typeof(s.ts)='integer' AND (s.dur IS NULL OR typeof(s.dur)='integer') AND s.ts<? AND (
        (s.dur=0 AND s.ts>=? AND s.ts<?)
        OR ((s.dur IS NULL OR s.dur<0) AND s.ts<? AND ?>?)
        OR (s.dur>0 AND s.ts<? AND (s.ts>? OR s.dur>?-s.ts)))";
    (
        format!("({sql})"),
        [end, start, end, end, trace_end, start, end, start, start]
            .into_iter()
            .map(Value::Integer)
            .collect(),
    )
}
pub(crate) fn relative(value: i64, inspection: &DatabaseInspection) -> Result<i64, StoreError> {
    if value <= inspection.trace_start_ts {
        Ok(0)
    } else if value >= inspection.trace_end_ts {
        Ok(inspection.duration_ns)
    } else {
        value
            .checked_sub(inspection.trace_start_ts)
            .ok_or(StoreError::InvalidDatabase)
    }
}
pub(crate) fn interval(
    timestamp: Option<i64>,
    duration: Option<i64>,
    duration_null: bool,
    inspection: &DatabaseInspection,
    quality: &mut EventQuality,
) -> Result<Option<(TraceTimeRange, bool)>, StoreError> {
    let Some(timestamp) = timestamp else {
        quality.invalid_value += 1;
        return Ok(None);
    };
    if duration.is_none() && !duration_null {
        quality.invalid_value += 1;
        return Ok(None);
    }
    let start = relative(timestamp, inspection)?;
    if timestamp < inspection.trace_start_ts || timestamp > inspection.trace_end_ts {
        quality.clamped_timestamp += 1;
    }
    let (end, open) = match duration {
        None => (inspection.duration_ns, true),
        Some(dur) if dur < 0 => (inspection.duration_ns, true),
        Some(0) => (start, false),
        Some(dur) => {
            if let Some(end) = timestamp.checked_add(dur) {
                let clamped = end.clamp(inspection.trace_start_ts, inspection.trace_end_ts);
                if timestamp < inspection.trace_start_ts || clamped != end {
                    quality.clamped_duration += 1;
                }
                (relative(clamped, inspection)?, false)
            } else {
                quality.clamped_duration += 1;
                (inspection.duration_ns, false)
            }
        }
    };
    if end < start {
        quality.invalid_value += 1;
        return Ok(None);
    }
    Ok(Some((
        TraceTimeRange::event(start, end).map_err(|_| StoreError::InvalidDatabase)?,
        open,
    )))
}
fn normalize_state(raw: &str) -> Option<TraceThreadState> {
    use TraceThreadState::*;
    match raw.to_uppercase().as_str() {
        "RUNNING" => Some(Running),
        "R" | "R+" | "RUNNABLE" | "READY" => Some(Runnable),
        "S" | "SLEEPING" | "SLEEP" => Some(Sleeping),
        "D" | "BLOCKED" | "UNINTERRUPTIBLE" => Some(Blocked),
        "T" | "STOPPED" => Some(Stopped),
        _ => None,
    }
}
fn state_predicate(state: TraceThreadState) -> &'static str {
    match state {
        TraceThreadState::Running => "UPPER(s.state) IN ('RUNNING')",
        TraceThreadState::Runnable => "UPPER(s.state) IN ('R','R+','RUNNABLE','READY')",
        TraceThreadState::Sleeping => "UPPER(s.state) IN ('S','SLEEPING','SLEEP')",
        TraceThreadState::Blocked => "UPPER(s.state) IN ('D','BLOCKED','UNINTERRUPTIBLE')",
        TraceThreadState::Stopped => "UPPER(s.state) IN ('T','STOPPED')",
    }
}
pub(crate) fn unavailable<T>() -> Result<EventPage<T>, StoreError> {
    Ok(EventPage {
        items: Vec::new(),
        truncated: false,
        capability_available: false,
        data_quality: DataQuality::machine(QualityStatus::Ok, Vec::new())
            .map_err(|_| StoreError::InvalidQualityContract)?,
    })
}
pub(crate) fn page<T>(
    items: Vec<T>,
    rows: usize,
    limit: usize,
    table: &str,
    inspection: &DatabaseInspection,
    quality: EventQuality,
) -> Result<EventPage<T>, StoreError> {
    let mut issues = inspection.data_quality.warnings.clone();
    for (category, suffix, count) in [
        (
            QualityCategory::DroppedValue,
            "value",
            quality.invalid_value,
        ),
        (
            QualityCategory::ClampedValue,
            "ts",
            quality.clamped_timestamp,
        ),
        (
            QualityCategory::ClampedValue,
            "dur",
            quality.clamped_duration,
        ),
        (
            QualityCategory::ReferentialIntegrity,
            "identity",
            quality.missing_reference,
        ),
        (
            QualityCategory::InvalidValue,
            "state",
            quality.unknown_state,
        ),
        (QualityCategory::InvalidValue, "overlap", quality.overlap),
    ] {
        if count > 0 {
            issues.push(QualityIssue {
                category,
                scope: Some(format!("{table}.{suffix}")),
                count: Some(count),
                message: None,
            });
        }
    }
    let status = if issues.is_empty() {
        QualityStatus::Ok
    } else {
        QualityStatus::Warnings
    };
    Ok(EventPage {
        items,
        truncated: rows > limit || quality.invalid_value > 0,
        capability_available: true,
        data_quality: DataQuality::machine(status, issues)
            .map_err(|_| StoreError::InvalidQualityContract)?,
    })
}

#[cfg(test)]
mod tests;
