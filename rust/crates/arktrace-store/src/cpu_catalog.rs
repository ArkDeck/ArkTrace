use crate::{
    DatabaseInspection, StoreError,
    database::{DEFAULT_VM_BUDGET, Database},
    events::{EventQuality, intersection, interval, optional_integer, page, unavailable},
};
use arktrace_contract::{CpuActivity, CpuCatalog, CpuCatalogQuery, CpuIdentity, ProcessKey};
use rusqlite::{params_from_iter, types::Value};

pub(crate) fn query(
    db: &Database<'_>,
    inspection: &DatabaseInspection,
    query: &CpuCatalogQuery,
) -> Result<CpuCatalog, StoreError> {
    query.validate().map_err(|_| StoreError::InvalidQuery)?;
    if !inspection.capabilities.cpu_scheduling {
        return Ok(CpuCatalog {
            cpus: unavailable()?,
            activity: unavailable()?,
        });
    }
    // The same VM credit spans every identity seek and the activity query.
    // A busy CPU is skipped with an indexed strict successor seek; there is
    // no event sample from which to infer that the identity set is complete.
    let db = db.summary_request(DEFAULT_VM_BUDGET)?;
    let (conditions, values) = intersection(inspection, query.range)?;
    let mut cpus = Vec::new();
    let mut previous = None;
    while cpus.len() <= query.limit {
        let mut bindings = values.clone();
        bindings.push(Value::Integer(previous.unwrap_or(i64::MIN)));
        let comparison = if previous.is_some() { ">" } else { ">=" };
        let sql = format!(
            "SELECT s.cpu FROM sched_slice s WHERE {} AND s.cpu{comparison}? \
             AND typeof(s.cpu)='integer' ORDER BY s.cpu ASC LIMIT 1",
            conditions.join(" AND ")
        );
        let next = db.query(
            &sql,
            params_from_iter(bindings),
            1,
            DEFAULT_VM_BUDGET,
            |row| optional_integer(row, 0),
        )?;
        let Some(cpu) = next.first().copied().flatten() else {
            break;
        };
        cpus.push(CpuIdentity { cpu });
        previous = Some(cpu);
        if cpu == i64::MAX {
            break;
        }
    }
    let cpu_rows = cpus.len();
    cpus.truncate(query.limit);

    // Preserve the original first-N scheduling activity order and bounds,
    // without allocating names or joining process/thread detail for each row.
    let mut bindings = values;
    bindings.push(Value::Integer(query.activity_limit as i64 + 1));
    let rows = db.query(
        &format!(
            "SELECT s.id,s.ts,s.dur,s.cpu,s.ipid FROM sched_slice s WHERE {} \
            ORDER BY s.ts ASC,s.id ASC LIMIT ?",
            conditions.join(" AND ")
        ),
        params_from_iter(bindings),
        query.activity_limit + 1,
        DEFAULT_VM_BUDGET,
        |row| {
            Ok((
                optional_integer(row, 0)?,
                optional_integer(row, 1)?,
                optional_integer(row, 2)?,
                matches!(
                    row.get_ref(2).map_err(crate::database::sqlite_error)?,
                    rusqlite::types::ValueRef::Null
                ),
                optional_integer(row, 3)?,
                optional_integer(row, 4)?,
            ))
        },
    )?;
    let mut quality = EventQuality::default();
    let mut activity = Vec::new();
    for (id, ts, dur, dur_null, cpu, owner) in rows.iter().take(query.activity_limit) {
        db.check()?;
        if id.is_none() {
            return Err(StoreError::InvalidIdentity);
        }
        if cpu.is_none() {
            quality.invalid_value += 1;
            continue;
        }
        if interval(*ts, *dur, *dur_null, inspection, &mut quality)?.is_none() {
            continue;
        }
        activity.push(CpuActivity {
            process_key: owner.filter(|v| *v != 0).map(|ipid| ProcessKey { ipid }),
        });
    }
    db.reserve_decoded(
        (cpus.capacity() * size_of::<CpuIdentity>()
            + activity.capacity() * size_of::<CpuActivity>()) as u64,
    )?;
    Ok(CpuCatalog {
        cpus: page(
            cpus,
            cpu_rows,
            query.limit,
            "sched_slice",
            inspection,
            EventQuality::default(),
        )?,
        activity: page(
            activity,
            rows.len(),
            query.activity_limit,
            "sched_slice",
            inspection,
            quality,
        )?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ValidationBudget;
    use arktrace_contract::TraceTimeRange;
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
    fn fixture() -> (Connection, DatabaseInspection) {
        let c = Connection::open_in_memory().unwrap();
        c.execute_batch("CREATE TABLE trace_range(start_ts INTEGER,end_ts INTEGER); INSERT INTO trace_range VALUES(1000,2000);
            CREATE TABLE process(ipid INTEGER,pid INTEGER,name TEXT,start_ts INTEGER);
            INSERT INTO process VALUES(-10,900,'process',1000);
            CREATE TABLE thread(itid INTEGER,tid INTEGER,name TEXT,start_ts INTEGER,ipid INTEGER);
            CREATE TABLE sched_slice(id INTEGER,ts INTEGER,dur INTEGER,cpu INTEGER,itid INTEGER,ipid INTEGER);
            INSERT INTO sched_slice VALUES(1,1000,1,0,NULL,-10);
            CREATE INDEX cpu_seek ON sched_slice(cpu,ts,id,dur,itid,ipid);
            CREATE INDEX event_order ON sched_slice(ts,id);
            CREATE TABLE thread_state(id INTEGER,ts INTEGER,dur INTEGER,itid INTEGER,state TEXT);
            CREATE TABLE callstack(id INTEGER,ts INTEGER,dur INTEGER,callid INTEGER,name TEXT);").unwrap();
        let inspection = Database::borrow_writable(&c, &budget())
            .unwrap()
            .inspect()
            .unwrap();
        (c, inspection)
    }
    fn request(limit: usize, activity_limit: usize) -> CpuCatalogQuery {
        CpuCatalogQuery {
            range: TraceTimeRange::query(0, 1000).unwrap(),
            limit,
            activity_limit,
        }
    }
    #[test]
    fn late_sparse_signed_identities_do_not_depend_on_activity_sample() {
        let (c, inspection) = fixture();
        c.execute_batch(
            "WITH RECURSIVE n(i) AS (VALUES(2) UNION ALL SELECT i+1 FROM n WHERE i<21000)
            INSERT INTO sched_slice SELECT i,1001,1,0,NULL,-10 FROM n;
            INSERT INTO sched_slice VALUES(21001,1800,0,-9223372036854775808,NULL,-10);
            INSERT INTO sched_slice VALUES(21002,1900,NULL,9223372036854775807,NULL,NULL);
            INSERT INTO sched_slice VALUES(21003,1999,-1,99,NULL,5);",
        )
        .unwrap();
        let b = budget();
        let db = Database::borrow_writable(&c, &b).unwrap();
        let result = query(&db, &inspection, &request(4096, 20_000)).unwrap();
        assert_eq!(
            result.cpus.items.iter().map(|v| v.cpu).collect::<Vec<_>>(),
            [i64::MIN, 0, 99, i64::MAX]
        );
        assert!(!result.cpus.truncated);
        assert!(result.activity.truncated);
        assert_eq!(result.activity.items.len(), 20_000);
        assert!(
            result
                .activity
                .items
                .iter()
                .all(|v| v.process_key == Some(ProcessKey { ipid: -10 }))
        );
        let truncated = query(&db, &inspection, &request(2, 1)).unwrap();
        assert_eq!(
            truncated
                .cpus
                .items
                .iter()
                .map(|v| v.cpu)
                .collect::<Vec<_>>(),
            [i64::MIN, 0]
        );
        assert!(truncated.cpus.truncated);
    }
    #[test]
    fn ranges_keep_instant_open_ended_and_invalid_cpu_semantics() {
        let (c, inspection) = fixture();
        c.execute_batch(
            "INSERT INTO sched_slice VALUES(2,1100,0,1,NULL,2);
            INSERT INTO sched_slice VALUES(3,1200,-1,2,NULL,-10);
            INSERT INTO sched_slice VALUES(4,1300,NULL,3,NULL,0);
            INSERT INTO sched_slice VALUES(5,1500,0,4,NULL,2);
            INSERT INTO sched_slice VALUES(6,1450,1,'bad',NULL,2);
            INSERT INTO sched_slice VALUES(7,'bad',1,5,NULL,2);
            INSERT INTO sched_slice VALUES(8,1400,'bad',6,NULL,2);",
        )
        .unwrap();
        let mut q = request(4096, 20_000);
        q.range = TraceTimeRange::query(100, 500).unwrap();
        let b = budget();
        let db = Database::borrow_writable(&c, &b).unwrap();
        let result = query(&db, &inspection, &q).unwrap();
        assert_eq!(
            result.cpus.items.iter().map(|v| v.cpu).collect::<Vec<_>>(),
            [1, 2, 3]
        );
        assert!(!result.cpus.truncated);
        assert!(result.activity.truncated);
        assert_eq!(
            result
                .activity
                .items
                .iter()
                .map(|v| v.process_key.map(|k| k.ipid))
                .collect::<Vec<_>>(),
            [Some(2), Some(-10), None]
        );
        assert!(
            result
                .activity
                .data_quality
                .warnings
                .iter()
                .any(|v| v.scope.as_deref() == Some("sched_slice.value"))
        );
    }
    #[test]
    fn malformed_identity_and_expired_or_cancelled_queries_fail_closed() {
        let (c, inspection) = fixture();
        c.execute_batch("INSERT INTO sched_slice VALUES('bad',1001,1,1,NULL,2)")
            .unwrap();
        let b = budget();
        let db = Database::borrow_writable(&c, &b).unwrap();
        assert!(matches!(
            query(&db, &inspection, &request(4096, 20_000)),
            Err(StoreError::InvalidIdentity)
        ));
        let mut b = budget();
        b.deadline = Instant::now() - Duration::from_secs(1);
        assert!(matches!(
            Database::borrow_writable(&c, &b).and_then(|db| query(
                &db,
                &inspection,
                &request(1, 1)
            )),
            Err(StoreError::DeadlineExceeded)
        ));
        let b = budget();
        b.cancellation.cancel();
        assert!(matches!(
            Database::borrow_writable(&c, &b).and_then(|db| query(
                &db,
                &inspection,
                &request(1, 1)
            )),
            Err(StoreError::Cancelled)
        ));
    }
    #[test]
    fn scanning_out_of_range_rows_does_not_reset_vm_budget_or_return_unavailable() {
        let (c, inspection) = fixture();
        c.execute_batch("DELETE FROM sched_slice; WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<100000)
            INSERT INTO sched_slice SELECT i,1001,1,0,NULL,-10 FROM n;").unwrap();
        let mut q = request(4096, 1);
        q.range = TraceTimeRange::query(900, 1000).unwrap();
        let b = budget();
        let db = Database::borrow_writable(&c, &b).unwrap();
        assert!(matches!(
            query(&db, &inspection, &q),
            Err(StoreError::VmBudgetExceeded)
        ));
    }
}
