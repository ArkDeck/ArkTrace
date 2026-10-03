use crate::{
    DatabaseInspection, StoreError,
    database::{DEFAULT_VM_BUDGET, Database, text},
    events::{
        EventQuality, intersection, interval, optional_integer, optional_text, page, unavailable,
    },
};
use arktrace_contract::{
    EventKey, EventPage, EventTable, ProcessKey, ThreadKey, TraceFrame, TraceFrameKind,
    TraceFrameQuery,
};
use rusqlite::{
    params_from_iter,
    types::{Value, ValueRef},
};

#[derive(Clone, Copy)]
pub(crate) struct FrameSchema {
    available: bool,
    thread: bool,
}
impl FrameSchema {
    pub(crate) fn available(self) -> bool {
        self.available
    }
    pub(crate) fn read(db: &Database<'_>) -> Result<Self, StoreError> {
        let columns = db.query(
            "PRAGMA table_xinfo(frame_slice)",
            [],
            2000,
            DEFAULT_VM_BUDGET,
            |r| text(r, 1),
        )?;
        Ok(Self {
            available: ["id", "ts", "dur", "vsync", "ipid", "type", "flag"]
                .iter()
                .all(|c| columns.iter().any(|v| v == c)),
            thread: columns.iter().any(|v| v == "itid"),
        })
    }
    pub(crate) fn frames(
        self,
        db: &Database<'_>,
        inspection: &DatabaseInspection,
        query: &TraceFrameQuery,
    ) -> Result<EventPage<TraceFrame>, StoreError> {
        query.validate().map_err(|_| StoreError::InvalidQuery)?;
        if !self.available {
            return unavailable();
        }
        let (conditions, mut values) = intersection(inspection, query.range)?;
        let mut conditions = conditions
            .into_iter()
            .map(|c| c.replace("s.", "f."))
            .collect::<Vec<_>>();
        conditions.extend([
            "typeof(f.vsync)='integer'".into(),
            "typeof(f.type)='integer'".into(),
        ]);
        if let Some(key) = query.process_key {
            conditions.push("typeof(f.ipid)='integer' AND f.ipid=?".into());
            values.push(Value::Integer(key));
        }
        values.push(Value::Integer(query.limit as i64 + 1));
        let thread = if self.thread { "f.itid" } else { "NULL" };
        let sql = format!(
            "SELECT f.id,f.ts,f.dur,f.vsync,f.type,f.flag,f.ipid,{thread},p.pid,p.name FROM frame_slice f LEFT JOIN process p ON p.ipid=f.ipid WHERE {} ORDER BY f.ts ASC,f.id ASC LIMIT ?",
            conditions.join(" AND ")
        );
        let rows = db.query(
            &sql,
            params_from_iter(values),
            query.limit + 1,
            DEFAULT_VM_BUDGET,
            |r| {
                Ok(FrameRow {
                    id: optional_integer(r, 0)?,
                    ts: optional_integer(r, 1)?,
                    duration: optional_integer(r, 2)?,
                    duration_null: r.get_ref(2).map_err(crate::database::sqlite_error)?
                        == ValueRef::Null,
                    vsync: optional_integer(r, 3)?,
                    kind: optional_integer(r, 4)?,
                    flag: optional_integer(r, 5)?,
                    process: optional_integer(r, 6)?,
                    thread: optional_integer(r, 7)?,
                    pid: optional_integer(r, 8)?,
                    name: optional_text(r, 9)?,
                })
            },
        )?;
        let mut items = Vec::new();
        let mut quality = EventQuality::default();
        for (index, row) in rows.iter().take(query.limit).enumerate() {
            if index.is_multiple_of(1024) {
                db.check()?;
            }
            let id = row.id.ok_or(StoreError::InvalidFrameIdentity)?;
            let Some(kind) = row.kind.and_then(|v| TraceFrameKind::try_from(v).ok()) else {
                quality.invalid_value += 1;
                continue;
            };
            let vsync = row.vsync.ok_or(StoreError::InvalidDatabase)?;
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
            items.push(TraceFrame {
                key: EventKey {
                    table: EventTable::FrameSlice,
                    row_id: id,
                },
                range,
                kind,
                vsync,
                process_key: row.process.map(|ipid| ProcessKey { ipid }),
                thread_key: row.thread.map(|itid| ThreadKey { itid }),
                pid: row.pid,
                process_name: row.name.clone(),
                flag: row.flag,
                is_open_ended: open,
            });
        }
        db.check()?;
        page(
            items,
            rows.len(),
            query.limit,
            "frame_slice",
            inspection,
            quality,
        )
    }
}
struct FrameRow {
    id: Option<i64>,
    ts: Option<i64>,
    duration: Option<i64>,
    duration_null: bool,
    vsync: Option<i64>,
    kind: Option<i64>,
    flag: Option<i64>,
    process: Option<i64>,
    thread: Option<i64>,
    pid: Option<i64>,
    name: Option<String>,
}

#[cfg(test)]
mod tests;
