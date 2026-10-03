use crate::{
    DatabaseInspection, StoreError,
    database::{DEFAULT_VM_BUDGET, Database, integer, text},
    directory::name_filter,
    events::{
        EventQuality, bounded_text, filters, intersection, interval, invalid_integer, invalid_text,
        optional_integer, optional_text, page, unavailable,
    },
};
use arktrace_contract::{
    EventKey, EventPage, EventTable, ProcessKey, ThreadKey, TraceSlice, TraceSliceQuery,
};
use rusqlite::{
    params_from_iter,
    types::{Value, ValueRef},
};

#[derive(Clone, Copy)]
pub(crate) struct SliceSchema {
    depth: bool,
    category: bool,
    parent: bool,
    cookie: bool,
    arguments: bool,
}
impl SliceSchema {
    pub(crate) fn read(db: &Database<'_>) -> Result<Self, StoreError> {
        let columns = db.query(
            "PRAGMA table_xinfo(callstack)",
            [],
            2000,
            DEFAULT_VM_BUDGET,
            |r| text(r, 1),
        )?;
        let has = |name| columns.iter().any(|c| c == name);
        Ok(Self {
            depth: has("depth"),
            category: has("cat"),
            parent: has("parent_id"),
            cookie: has("cookie"),
            arguments: has("argsetid"),
        })
    }
    pub(crate) fn slices(
        self,
        db: &Database<'_>,
        inspection: &DatabaseInspection,
        query: &TraceSliceQuery,
    ) -> Result<EventPage<TraceSlice>, StoreError> {
        query.validate().map_err(|_| StoreError::InvalidQuery)?;
        if !inspection.capabilities.named_slices {
            return unavailable();
        }
        if query.depth.is_some() && !self.depth {
            return Err(StoreError::NamedSliceDepthUnavailable);
        }
        let (mut conditions, mut values) = intersection(inspection, query.range)?;
        filters(
            &mut conditions,
            &mut values,
            [
                ("s.id", query.event_key.map(|k| k.row_id)),
                ("t.ipid", query.process_key),
                ("p.pid", query.pid),
                ("s.callid", query.thread_key),
                ("t.tid", query.tid),
            ],
        );
        if query.unattributed_only {
            conditions.push("(s.callid IS NULL OR s.callid=0)".into());
        }
        name_filter(
            "s.name",
            query.name.as_deref(),
            query.name_match,
            &mut conditions,
            &mut values,
        );
        if let Some(minimum) = query.minimum_duration_ns {
            // Compare full trace-clamped duration, never query-clipped duration
            // or ts+dur. Bind integer origins/endpoints exactly like Swift.
            conditions.push("CASE WHEN s.ts>=? THEN 0 WHEN s.dur IS NULL OR s.dur<0 THEN ?-MAX(s.ts,?) WHEN s.dur=0 THEN 0 WHEN s.ts<? THEN CASE WHEN s.dur<=?-s.ts THEN 0 WHEN s.dur>=?-s.ts THEN ? ELSE s.dur-(?-s.ts) END ELSE MIN(s.dur,?-s.ts) END>=?".to_owned());
            values.extend(
                [
                    inspection.trace_end_ts,
                    inspection.trace_end_ts,
                    inspection.trace_start_ts,
                    inspection.trace_start_ts,
                    inspection.trace_start_ts,
                    inspection.trace_end_ts,
                    inspection.duration_ns,
                    inspection.trace_start_ts,
                    inspection.trace_end_ts,
                    minimum,
                ]
                .into_iter()
                .map(Value::Integer),
            );
        }
        filters(
            &mut conditions,
            &mut values,
            [("typeof(s.depth)='integer' AND s.depth", query.depth)],
        );
        values.push(Value::Integer(query.limit as i64 + 1));
        let depth = if self.depth {
            "CASE WHEN typeof(s.depth)='integer' THEN s.depth ELSE NULL END"
        } else {
            "NULL"
        };
        let category = if self.category {
            bounded_text("s.cat", 1024)
        } else {
            "NULL".to_owned()
        };
        let parent = if self.parent {
            "CASE WHEN typeof(s.parent_id)='integer' AND s.parent_id>0 AND s.parent_id<>4294967295 THEN s.parent_id ELSE NULL END"
        } else {
            "NULL"
        };
        let asynchronous = if self.cookie {
            "CASE WHEN typeof(s.cookie)='integer' AND s.cookie<>0 THEN 1 ELSE 0 END"
        } else {
            "0"
        };
        let arguments = if self.arguments && query.includes_argument_set {
            "CASE WHEN typeof(s.argsetid)='integer' THEN s.argsetid ELSE NULL END"
        } else {
            "NULL"
        };
        let mut invalid = vec![
            invalid_integer("p.pid"),
            invalid_integer("t.tid"),
            invalid_text("p.name", 4096),
            invalid_text("t.name", 4096),
        ];
        for (enabled, column) in [
            (self.depth, "s.depth"),
            (self.parent, "s.parent_id"),
            (self.cookie, "s.cookie"),
        ] {
            if enabled {
                invalid.push(invalid_integer(column));
            }
        }
        if self.category {
            invalid.push(invalid_text("s.cat", 1024));
        }
        let sql = format!(
            "SELECT s.id,s.ts,s.dur,s.callid,t.ipid,p.pid,t.tid,{},{},{},{category},{depth},{parent},{asynchronous},CASE WHEN s.callid IS NOT NULL AND s.callid<>0 AND t.itid IS NULL THEN 1 ELSE 0 END,{}, {arguments} FROM callstack s LEFT JOIN thread t ON t.itid=s.callid LEFT JOIN process p ON p.ipid=t.ipid WHERE {} ORDER BY s.ts ASC,s.id ASC LIMIT ?",
            bounded_text("p.name", 4096),
            bounded_text("t.name", 4096),
            bounded_text("s.name", 4096),
            invalid.join(" + "),
            conditions.join(" AND ")
        );
        let rows = db.query(
            &sql,
            params_from_iter(values),
            query.limit + 1,
            DEFAULT_VM_BUDGET,
            |r| {
                Ok(SliceRow {
                    id: optional_integer(r, 0)?,
                    ts: optional_integer(r, 1)?,
                    duration: optional_integer(r, 2)?,
                    duration_null: r.get_ref(2).map_err(crate::database::sqlite_error)?
                        == ValueRef::Null,
                    thread: optional_integer(r, 3)?,
                    process: optional_integer(r, 4)?,
                    pid: optional_integer(r, 5)?,
                    tid: optional_integer(r, 6)?,
                    process_name: optional_text(r, 7)?,
                    thread_name: optional_text(r, 8)?,
                    name: optional_text(r, 9)?,
                    category: optional_text(r, 10)?,
                    depth: optional_integer(r, 11)?,
                    parent: optional_integer(r, 12)?,
                    asynchronous: integer(r, 13)? == 1,
                    missing: integer(r, 14)?,
                    invalid: integer(r, 15)?,
                    arguments: optional_integer(r, 16)?,
                })
            },
        )?;
        let mut items = Vec::new();
        let mut quality = EventQuality::default();
        for (index, row) in rows.iter().take(query.limit).enumerate() {
            if index.is_multiple_of(1024) {
                db.check()?;
            }
            let id = row.id.ok_or(StoreError::InvalidIdentity)?;
            quality.invalid_value += row.invalid;
            let Some(name) = &row.name else {
                quality.invalid_value += 1;
                continue;
            };
            let Some((range, open)) = interval(
                row.ts,
                row.duration,
                row.duration_null,
                inspection,
                &mut quality,
            )?
            else {
                continue;
            };
            quality.missing_reference += row.missing;
            items.push(TraceSlice {
                key: EventKey {
                    table: EventTable::Callstack,
                    row_id: id,
                },
                range,
                thread_key: row
                    .thread
                    .filter(|v| *v != 0)
                    .map(|itid| ThreadKey { itid }),
                process_key: row
                    .process
                    .filter(|v| *v != 0)
                    .map(|ipid| ProcessKey { ipid }),
                pid: row.pid,
                tid: row.tid,
                process_name: row.process_name.clone(),
                thread_name: row.thread_name.clone(),
                name: name.clone(),
                category: row.category.clone(),
                depth: row.depth,
                parent_event_key: row.parent.map(|row_id| EventKey {
                    table: EventTable::Callstack,
                    row_id,
                }),
                is_async: row.asynchronous,
                is_open_ended: open,
                arg_set_id: row.arguments,
            });
        }
        db.check()?;
        page(
            items,
            rows.len(),
            query.limit,
            "callstack",
            inspection,
            quality,
        )
    }
}
struct SliceRow {
    id: Option<i64>,
    ts: Option<i64>,
    duration: Option<i64>,
    duration_null: bool,
    thread: Option<i64>,
    process: Option<i64>,
    pid: Option<i64>,
    tid: Option<i64>,
    process_name: Option<String>,
    thread_name: Option<String>,
    name: Option<String>,
    category: Option<String>,
    depth: Option<i64>,
    parent: Option<i64>,
    asynchronous: bool,
    missing: i64,
    invalid: i64,
    arguments: Option<i64>,
}

#[cfg(test)]
mod tests;
