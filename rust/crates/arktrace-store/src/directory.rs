use crate::{
    DatabaseInspection, StoreError,
    database::{DEFAULT_VM_BUDGET, Database, integer, text},
};
use arktrace_contract::{
    DirectoryNameMatch, DirectoryPage, ProcessQuery, QualityCategory, QualityIssue, ThreadQuery,
    TraceProcess, TraceThread,
};
use rusqlite::{
    Row, params_from_iter,
    types::{Value, ValueRef},
};

#[derive(Clone, Copy)]
pub(crate) struct DirectorySchema {
    process_end: bool,
    process_thread_count: bool,
    thread_end: bool,
    thread_main: bool,
}
impl DirectorySchema {
    pub(crate) fn read(db: &Database<'_>) -> Result<Self, StoreError> {
        let process = db.query(
            "PRAGMA table_xinfo(process)",
            [],
            2000,
            DEFAULT_VM_BUDGET,
            |r| text(r, 1),
        )?;
        let thread = db.query(
            "PRAGMA table_xinfo(thread)",
            [],
            2000,
            DEFAULT_VM_BUDGET,
            |r| text(r, 1),
        )?;
        Ok(Self {
            process_end: process.iter().any(|v| v == "end_ts"),
            process_thread_count: process.iter().any(|v| v == "thread_count"),
            thread_end: thread.iter().any(|v| v == "end_ts"),
            thread_main: thread.iter().any(|v| v == "is_main_thread"),
        })
    }
    pub(crate) fn processes(
        self,
        db: &Database<'_>,
        inspection: &DatabaseInspection,
        query: &ProcessQuery,
    ) -> Result<DirectoryPage<TraceProcess>, StoreError> {
        query.validate().map_err(|_| StoreError::InvalidQuery)?;
        let mut select = "ipid,pid,name,start_ts".to_owned();
        if self.process_end {
            select.push_str(",end_ts");
        }
        if self.process_thread_count {
            select.push_str(",thread_count");
        }
        let mut conditions = vec!["(ipid IS NULL OR ipid <> 0)".to_owned()];
        let mut values = Vec::new();
        integer_filter("ipid", query.process_key, &mut conditions, &mut values);
        integer_filter("pid", query.pid, &mut conditions, &mut values);
        name_filter(
            "name",
            query.name.as_deref(),
            query.name_match,
            &mut conditions,
            &mut values,
        );
        values.push(Value::Integer(query.limit as i64 + 1));
        let sql = format!(
            "SELECT {select} FROM process WHERE {} ORDER BY pid ASC,ipid ASC LIMIT ?",
            conditions.join(" AND ")
        );
        let end_index = self.process_end.then_some(4);
        let count_index = self
            .process_thread_count
            .then_some(if self.process_end { 5 } else { 4 });
        let mut bad_names = 0;
        let mut bad_lifecycle = 0;
        let rows = db.query(
            &sql,
            params_from_iter(values),
            query.limit + 1,
            DEFAULT_VM_BUDGET,
            |r| {
                let start = relative(optional_integer(r, 3)?, inspection)?;
                let end = lifecycle_end(
                    start,
                    relative(optional_column(r, end_index)?, inspection)?,
                    &mut bad_lifecycle,
                );
                Ok(TraceProcess {
                    key: integer(r, 0).map_err(|_| StoreError::InvalidIdentity)?,
                    pid: integer(r, 1).map_err(|_| StoreError::InvalidIdentity)?,
                    name: bounded_name(r, 2, &mut bad_names)?,
                    start_ns: start,
                    end_ns: end,
                    thread_count: optional_column(r, count_index)?,
                })
            },
        )?;
        page(
            rows,
            query.limit,
            &[
                ("process.name", bad_names),
                ("process.lifecycle", bad_lifecycle),
            ],
        )
    }
    pub(crate) fn threads(
        self,
        db: &Database<'_>,
        inspection: &DatabaseInspection,
        query: &ThreadQuery,
    ) -> Result<DirectoryPage<TraceThread>, StoreError> {
        query.validate().map_err(|_| StoreError::InvalidQuery)?;
        let mut select = "t.itid,t.tid,t.name,t.start_ts,t.ipid,p.pid,p.name".to_owned();
        if self.thread_end {
            select.push_str(",t.end_ts");
        }
        if self.thread_main {
            select.push_str(",t.is_main_thread");
        }
        let mut conditions = vec!["(t.itid IS NULL OR t.itid <> 0)".to_owned()];
        let mut values = Vec::new();
        for (column, value) in [
            ("t.ipid", query.process_key),
            ("p.pid", query.pid),
            ("t.itid", query.thread_key),
            ("t.tid", query.tid),
        ] {
            integer_filter(column, value, &mut conditions, &mut values);
        }
        name_filter(
            "t.name",
            query.name.as_deref(),
            query.name_match,
            &mut conditions,
            &mut values,
        );
        values.push(Value::Integer(query.limit as i64 + 1));
        let sql = format!(
            "SELECT {select} FROM thread t LEFT JOIN process p ON t.ipid=p.ipid WHERE {} ORDER BY (p.pid IS NULL) ASC,p.pid ASC,t.tid ASC,t.itid ASC LIMIT ?",
            conditions.join(" AND ")
        );
        let end_index = self.thread_end.then_some(7);
        let main_index = self
            .thread_main
            .then_some(if self.thread_end { 8 } else { 7 });
        let (mut bad_names, mut bad_process_names, mut bad_lifecycle) = (0, 0, 0);
        let rows = db.query(
            &sql,
            params_from_iter(values),
            query.limit + 1,
            DEFAULT_VM_BUDGET,
            |r| {
                let start = relative(optional_integer(r, 3)?, inspection)?;
                let end = lifecycle_end(
                    start,
                    relative(optional_column(r, end_index)?, inspection)?,
                    &mut bad_lifecycle,
                );
                Ok(TraceThread {
                    key: integer(r, 0).map_err(|_| StoreError::InvalidIdentity)?,
                    process_key: optional_integer(r, 4)?.filter(|v| *v != 0),
                    tid: integer(r, 1).map_err(|_| StoreError::InvalidIdentity)?,
                    pid: optional_integer(r, 5)?,
                    name: bounded_name(r, 2, &mut bad_names)?,
                    process_name: bounded_name(r, 6, &mut bad_process_names)?,
                    start_ns: start,
                    end_ns: end,
                    is_main_thread: optional_column(r, main_index)?.map(|v| v != 0),
                })
            },
        )?;
        page(
            rows,
            query.limit,
            &[
                ("thread.name", bad_names),
                ("thread.processName", bad_process_names),
                ("thread.lifecycle", bad_lifecycle),
            ],
        )
    }
}
fn integer_filter(
    column: &str,
    value: Option<i64>,
    conditions: &mut Vec<String>,
    values: &mut Vec<Value>,
) {
    if let Some(value) = value {
        conditions.push(format!("{column}=?"));
        values.push(Value::Integer(value));
    }
}
pub(crate) fn name_filter(
    column: &str,
    value: Option<&str>,
    kind: DirectoryNameMatch,
    conditions: &mut Vec<String>,
    values: &mut Vec<Value>,
) {
    let Some(value) = value else { return };
    let value = match kind {
        DirectoryNameMatch::Exact => {
            conditions.push(format!("{column}=?"));
            value.to_owned()
        }
        DirectoryNameMatch::Prefix | DirectoryNameMatch::Contains => {
            conditions.push(format!("{column} LIKE ? ESCAPE '\\'"));
            let escaped = value
                .replace('\\', "\\\\")
                .replace('%', "\\%")
                .replace('_', "\\_");
            if kind == DirectoryNameMatch::Prefix {
                format!("{escaped}%")
            } else {
                format!("%{escaped}%")
            }
        }
    };
    values.push(Value::Text(value));
}
fn optional_integer(row: &Row<'_>, index: usize) -> Result<Option<i64>, StoreError> {
    Ok(
        match row.get_ref(index).map_err(crate::database::sqlite_error)? {
            ValueRef::Integer(v) => Some(v),
            _ => None,
        },
    )
}
fn optional_column(row: &Row<'_>, index: Option<usize>) -> Result<Option<i64>, StoreError> {
    index
        .map(|i| optional_integer(row, i))
        .transpose()
        .map(Option::flatten)
}
fn bounded_name(
    row: &Row<'_>,
    index: usize,
    invalid: &mut i64,
) -> Result<Option<String>, StoreError> {
    let value = row.get_ref(index).map_err(crate::database::sqlite_error)?;
    if value == ValueRef::Null {
        return Ok(None);
    }
    if let ValueRef::Text(bytes) = value
        && !bytes.is_empty()
        && bytes.len() <= 4096
        && let Ok(text) = std::str::from_utf8(bytes)
    {
        return Ok(Some(text.to_owned()));
    }
    *invalid += 1;
    Ok(None)
}
fn relative(
    value: Option<i64>,
    inspection: &DatabaseInspection,
) -> Result<Option<i64>, StoreError> {
    value
        .map(|v| {
            if v <= inspection.trace_start_ts {
                Ok(0)
            } else if v >= inspection.trace_end_ts {
                Ok(inspection.duration_ns)
            } else {
                v.checked_sub(inspection.trace_start_ts)
                    .ok_or(StoreError::InvalidDatabase)
            }
        })
        .transpose()
}
fn lifecycle_end(start: Option<i64>, end: Option<i64>, invalid: &mut i64) -> Option<i64> {
    if let (Some(start), Some(end)) = (start, end)
        && end < start
    {
        *invalid += 1;
        None
    } else {
        end
    }
}
fn page<T>(
    mut rows: Vec<T>,
    limit: usize,
    issues: &[(&str, i64)],
) -> Result<DirectoryPage<T>, StoreError> {
    let truncated = rows.len() > limit;
    rows.truncate(limit);
    let data_quality_issues = issues
        .iter()
        .filter(|(_, count)| *count > 0)
        .map(|(scope, count)| QualityIssue {
            category: QualityCategory::InvalidValue,
            scope: Some((*scope).to_owned()),
            count: Some(*count),
            message: None,
        })
        .collect();
    Ok(DirectoryPage {
        items: rows,
        truncated,
        data_quality_issues,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ValidationBudget;
    use arktrace_platform::CancellationToken;
    use rusqlite::Connection;
    use std::time::{Duration, Instant};
    fn budget() -> ValidationBudget {
        ValidationBudget {
            maximum_database_bytes: 256 * 1024 * 1024,
            deadline: Instant::now() + Duration::from_secs(10),
            cancellation: CancellationToken::default(),
        }
    }
    fn fixture(extra: &str) -> Connection {
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch("CREATE TABLE trace_range(start_ts INTEGER,end_ts INTEGER);INSERT INTO trace_range VALUES(100,1000);CREATE TABLE process(ipid INTEGER,pid INTEGER,name TEXT,start_ts INTEGER);CREATE TABLE thread(itid INTEGER,tid INTEGER,name TEXT,start_ts INTEGER,ipid INTEGER);CREATE TABLE sched_slice(id INTEGER,ts INTEGER,dur INTEGER,cpu INTEGER,itid INTEGER,ipid INTEGER);CREATE TABLE thread_state(id INTEGER,ts INTEGER,dur INTEGER,itid INTEGER,state TEXT);CREATE TABLE callstack(id INTEGER,ts INTEGER,dur INTEGER,callid INTEGER,name TEXT);").unwrap();
        db.execute_batch(extra).unwrap();
        db
    }
    fn process_query(limit: usize) -> ProcessQuery {
        ProcessQuery {
            process_key: None,
            pid: None,
            name: None,
            name_match: DirectoryNameMatch::Exact,
            limit,
        }
    }
    fn thread_query(limit: usize) -> ThreadQuery {
        ThreadQuery {
            process_key: None,
            pid: None,
            thread_key: None,
            tid: None,
            name: None,
            name_match: DirectoryNameMatch::Exact,
            limit,
        }
    }
    #[test]
    fn reused_pids_keep_identity_order_and_lookahead_quality() {
        let budget = budget();
        let db=Database::new(fixture("INSERT INTO process VALUES(9,10,'later',110),(2,10,'first',90),(3,11,x'FF',100),(0,0,'sentinel',100)"),&budget).unwrap();
        let inspection = db.inspect().unwrap();
        let schema = DirectorySchema::read(&db).unwrap();
        let page = schema
            .processes(&db, &inspection, &process_query(2))
            .unwrap();
        assert_eq!(page.items.iter().map(|p| p.key).collect::<Vec<_>>(), [2, 9]);
        assert_eq!(page.items[0].start_ns, Some(0));
        assert!(page.truncated);
        assert_eq!(
            page.data_quality_issues[0].scope.as_deref(),
            Some("process.name")
        );
        assert_eq!(page.data_quality_issues[0].count, Some(1));
        let mut query = process_query(20);
        query.process_key = Some(9);
        assert_eq!(
            schema
                .processes(&db, &inspection, &query)
                .unwrap()
                .items
                .len(),
            1
        );
        query.process_key = None;
        query.pid = Some(10);
        assert_eq!(
            schema
                .processes(&db, &inspection, &query)
                .unwrap()
                .items
                .len(),
            2
        );
    }
    #[test]
    fn optional_lifetimes_clamp_int64_extremes_and_inverted_ends() {
        let budget = budget();
        let db=Database::new(fixture("ALTER TABLE process ADD COLUMN end_ts INTEGER;ALTER TABLE process ADD COLUMN thread_count INTEGER;INSERT INTO process VALUES(1,1,'one',-9223372036854775808,9223372036854775807,2),(2,2,'two',800,500,NULL),(3,3,NULL,120,'bad',-1);ALTER TABLE thread ADD COLUMN is_main_thread INTEGER;INSERT INTO thread VALUES(1,1,'t',200,1,2)"),&budget).unwrap();
        let inspection = db.inspect().unwrap();
        let schema = DirectorySchema::read(&db).unwrap();
        let page = schema
            .processes(&db, &inspection, &process_query(20))
            .unwrap();
        assert_eq!(
            (page.items[0].start_ns, page.items[0].end_ns),
            (Some(0), Some(900))
        );
        assert_eq!(
            (page.items[1].start_ns, page.items[1].end_ns),
            (Some(700), None)
        );
        assert_eq!(page.items[2].end_ns, None);
        assert_eq!(page.items[2].thread_count, Some(-1));
        assert_eq!(
            page.data_quality_issues[0].scope.as_deref(),
            Some("process.lifecycle")
        );
        assert_eq!(
            schema
                .threads(&db, &inspection, &thread_query(20))
                .unwrap()
                .items[0]
                .is_main_thread,
            Some(true)
        );
    }
    #[test]
    fn unassociated_threads_sort_last_and_zero_parent_is_absent() {
        let budget = budget();
        let db=Database::new(fixture("INSERT INTO process VALUES(1,7,'parent',100);INSERT INTO thread VALUES(4,1,'orphan',100,NULL),(3,9,'third',100,1),(2,9,'second',100,1),(1,2,'zero',100,0),(0,0,'sentinel',100,0)"),&budget).unwrap();
        let inspection = db.inspect().unwrap();
        let schema = DirectorySchema::read(&db).unwrap();
        let rows = schema
            .threads(&db, &inspection, &thread_query(20))
            .unwrap()
            .items;
        assert_eq!(rows.iter().map(|t| t.key).collect::<Vec<_>>(), [2, 3, 4, 1]);
        assert_eq!(rows[0].process_name.as_deref(), Some("parent"));
        assert_eq!(rows[3].process_key, None);
        assert_eq!(rows[2].pid, None);
        let mut query = thread_query(20);
        query.thread_key = Some(3);
        query.pid = Some(7);
        query.tid = Some(9);
        query.process_key = Some(1);
        assert_eq!(
            schema
                .threads(&db, &inspection, &query)
                .unwrap()
                .items
                .len(),
            1
        );
    }
    #[test]
    fn like_patterns_escape_metacharacters_and_preserve_unicode() {
        let budget = budget();
        let db=Database::new(fixture("INSERT INTO process VALUES(1,1,'A%_\\中文-tail',100),(2,2,'AXX中文-tail',100),(3,3,'prefix-A%_\\中文',100)"),&budget).unwrap();
        let inspection = db.inspect().unwrap();
        let schema = DirectorySchema::read(&db).unwrap();
        let mut query = process_query(20);
        query.name = Some("a%_\\中文".to_owned());
        query.name_match = DirectoryNameMatch::Prefix;
        assert_eq!(
            schema.processes(&db, &inspection, &query).unwrap().items[0].key,
            1
        );
        query.name_match = DirectoryNameMatch::Contains;
        assert_eq!(
            schema
                .processes(&db, &inspection, &query)
                .unwrap()
                .items
                .iter()
                .map(|p| p.key)
                .collect::<Vec<_>>(),
            [1, 3]
        );
        query.name_match = DirectoryNameMatch::Exact;
        assert!(
            schema
                .processes(&db, &inspection, &query)
                .unwrap()
                .items
                .is_empty()
        );
    }
    #[test]
    fn bad_storage_empty_utf8_and_oversized_names_degrade_without_losing_rows() {
        let budget = budget();
        let db=Database::new(fixture("INSERT INTO process VALUES(1,1,cast(x'FF' AS TEXT),100),(2,2,'',100),(3,3,zeroblob(4097),100),(4,4,NULL,100);INSERT INTO thread VALUES(1,1,x'FF',100,1)"),&budget).unwrap();
        let inspection = db.inspect().unwrap();
        let schema = DirectorySchema::read(&db).unwrap();
        let page = schema
            .processes(&db, &inspection, &process_query(20))
            .unwrap();
        assert_eq!(page.items.len(), 4);
        assert!(page.items.iter().all(|p| p.name.is_none()));
        assert_eq!(page.data_quality_issues[0].count, Some(3));
        let page = schema.threads(&db, &inspection, &thread_query(20)).unwrap();
        assert_eq!(page.data_quality_issues.len(), 2);
        assert!(page.items[0].name.is_none() && page.items[0].process_name.is_none());
    }
    #[test]
    fn query_bounds_and_request_cancellation_do_not_poison_next_request() {
        let connection = fixture("INSERT INTO process VALUES(1,1,'ok',100)");
        let first = budget();
        let db = Database::borrow_readonly(&connection, &first).unwrap();
        let inspection = db.inspect().unwrap();
        let schema = DirectorySchema::read(&db).unwrap();
        for limit in [0, 100001] {
            assert_eq!(
                schema.processes(&db, &inspection, &process_query(limit)),
                Err(StoreError::InvalidQuery)
            );
        }
        let mut query = process_query(1);
        query.name = Some("中".repeat(1366));
        assert_eq!(
            schema.processes(&db, &inspection, &query),
            Err(StoreError::InvalidQuery)
        );
        first.cancellation.cancel();
        assert_eq!(
            schema.processes(&db, &inspection, &process_query(1)),
            Err(StoreError::Cancelled)
        );
        let next = budget();
        let db = Database::borrow_readonly(&connection, &next).unwrap();
        assert_eq!(
            schema
                .processes(&db, &inspection, &process_query(1))
                .unwrap()
                .items[0]
                .key,
            1
        );
        let expired = ValidationBudget {
            deadline: Instant::now() - Duration::from_millis(1),
            ..budget()
        };
        assert!(matches!(
            Database::borrow_readonly(&connection, &expired),
            Err(StoreError::DeadlineExceeded)
        ));
    }
}
