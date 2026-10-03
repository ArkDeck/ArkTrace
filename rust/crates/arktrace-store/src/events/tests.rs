use super::*;
use crate::{ValidationBudget, database::Database};
use arktrace_platform::CancellationToken;
use rusqlite::Connection;
use std::time::{Duration, Instant};

const SCHEMA: &str = "
CREATE TABLE trace_range(start_ts INTEGER,end_ts INTEGER); INSERT INTO trace_range VALUES(1000,2000);
CREATE TABLE process(ipid INTEGER,pid INTEGER,name TEXT,start_ts INTEGER);
INSERT INTO process VALUES(-10,900,'process',1000);
CREATE TABLE thread(itid INTEGER,tid INTEGER,name TEXT,start_ts INTEGER,ipid INTEGER);
INSERT INTO thread VALUES(-11,901,'thread',1000,-10);
CREATE TABLE sched_slice(id INTEGER,ts INTEGER,dur INTEGER,cpu INTEGER,itid INTEGER,ipid INTEGER);
INSERT INTO sched_slice VALUES(0,1000,1,0,-11,-10);
CREATE TABLE thread_state(id INTEGER,ts INTEGER,dur INTEGER,itid INTEGER,state TEXT);
INSERT INTO thread_state VALUES(0,1000,1,-11,'Running');
CREATE TABLE callstack(id INTEGER,ts INTEGER,dur INTEGER,callid INTEGER,name TEXT);";
fn budget() -> ValidationBudget {
    ValidationBudget {
        maximum_database_bytes: 256 * 1024 * 1024,
        deadline: Instant::now() + Duration::from_secs(10),
        cancellation: CancellationToken::default(),
    }
}
fn fixture(extra: &str) -> (Connection, DatabaseInspection) {
    let conn = Connection::open_in_memory().unwrap();
    conn.execute_batch(SCHEMA).unwrap();
    let inspection = Database::borrow_writable(&conn, &budget())
        .unwrap()
        .inspect()
        .unwrap();
    // Deliberately mutate only synthetic fixtures after inspection to exercise
    // row degradation independently of the schema probe's earlier warnings.
    conn.execute_batch(extra).unwrap();
    (conn, inspection)
}
fn cpu_query(start: i64, end: i64, limit: usize) -> CpuSliceQuery {
    CpuSliceQuery {
        range: TraceTimeRange::event(start, end).unwrap(),
        cpu: None,
        process_key: None,
        pid: None,
        thread_key: None,
        tid: None,
        limit,
    }
}
fn state_query(start: i64, end: i64, limit: usize) -> ThreadStateQuery {
    ThreadStateQuery {
        range: TraceTimeRange::event(start, end).unwrap(),
        cpu: None,
        process_key: None,
        pid: None,
        thread_key: None,
        tid: None,
        raw_state: None,
        state: None,
        limit,
    }
}
fn cpu(
    conn: &Connection,
    inspection: &DatabaseInspection,
    q: &CpuSliceQuery,
) -> Result<EventPage<CpuSlice>, StoreError> {
    let budget = budget();
    let db = Database::borrow_readonly(conn, &budget)?;
    EventSchema::read(&db)?.cpu_slices(&db, inspection, q)
}
fn states(
    conn: &Connection,
    inspection: &DatabaseInspection,
    q: &ThreadStateQuery,
) -> Result<EventPage<ThreadStateInterval>, StoreError> {
    let budget = budget();
    let db = Database::borrow_readonly(conn, &budget)?;
    EventSchema::read(&db)?.thread_states(&db, inspection, q)
}
fn count<T>(page: &EventPage<T>, category: QualityCategory, scope: &str) -> Option<i64> {
    page.data_quality
        .warnings
        .iter()
        .find(|v| v.category == category && v.scope.as_deref() == Some(scope))
        .and_then(|v| v.count)
}

#[test]
fn half_open_queries_keep_full_intervals_instants_and_open_ends() {
    let (conn, inspection) = fixture(
        "DELETE FROM sched_slice;
        INSERT INTO sched_slice VALUES(1,1050,200,0,-11,-10),(2,1150,0,0,-11,-10),
        (3,1160,NULL,1,-11,-10),(4,1170,-1,2,-11,-10),(5,1200,0,3,-11,-10),
        (6,1100,50,4,-11,-10),(7,1200,20,5,-11,-10),(8,1060,1,6,-11,-10);",
    );
    let p = cpu(&conn, &inspection, &cpu_query(150, 200, 20)).unwrap();
    assert_eq!(
        p.items.iter().map(|v| v.key.row_id).collect::<Vec<_>>(),
        [1, 2, 3, 4]
    );
    assert_eq!(p.items[0].range, TraceTimeRange::event(50, 250).unwrap());
    assert!(p.items[1].is_instant());
    assert!(
        p.items[2..]
            .iter()
            .all(|v| v.is_open_ended && v.range.end_ns() == 1000)
    );
    assert!(!p.truncated);
    assert!(p.capability_available);
    assert_eq!(
        count(&p, QualityCategory::InvalidValue, "sched_slice.overlap"),
        Some(1)
    );
    assert_eq!(
        count(&p, QualityCategory::DroppedValue, "sched_slice.value"),
        None
    );
}
#[test]
fn pre_trace_and_overflowing_durations_clamp_without_floating_point_times() {
    let (conn,inspection)=fixture("DELETE FROM sched_slice;
        INSERT INTO sched_slice VALUES(1,900,200,0,-11,-10),(2,900,50,1,-11,-10),
        (3,1900,9223372036854775807,2,-11,-10),(4,-9223372036854775808,9223372036854775807,3,-11,-10),
        (5,0,1500,4,-11,-10),(6,900,NULL,5,-11,-10),(7,2000,0,6,-11,-10);");
    let p = cpu(&conn, &inspection, &cpu_query(0, 1000, 20)).unwrap();
    assert_eq!(
        p.items.iter().map(|v| v.key.row_id).collect::<Vec<_>>(),
        [5, 1, 6, 3]
    );
    assert_eq!(
        p.items.iter().map(|v| v.range).collect::<Vec<_>>(),
        [
            TraceTimeRange::event(0, 500).unwrap(),
            TraceTimeRange::event(0, 100).unwrap(),
            TraceTimeRange::event(0, 1000).unwrap(),
            TraceTimeRange::event(900, 1000).unwrap(),
        ]
    );
    assert_eq!(
        count(&p, QualityCategory::ClampedValue, "sched_slice.ts"),
        Some(3)
    );
    assert_eq!(
        count(&p, QualityCategory::ClampedValue, "sched_slice.dur"),
        Some(3)
    );
    assert!(
        !p.truncated,
        "clamping preserves values and does not mean a dropped source row"
    );
}
#[test]
fn negative_trace_origins_and_int64_endpoints_preserve_integer_ranges() {
    for (start, end, ts, dur, relative_start, relative_end) in [
        (-2000, -1000, -1900, 100, 100, 200),
        (i64::MIN, i64::MIN + 1000, i64::MIN + 150, 0, 150, 150),
        (i64::MAX - 1000, i64::MAX, i64::MAX - 100, 200, 900, 1000),
    ] {
        let (conn, mut inspection) = fixture(&format!(
            "DELETE FROM sched_slice;INSERT INTO sched_slice VALUES(1,{ts},{dur},0,-11,-10);"
        ));
        inspection.trace_start_ts = start;
        inspection.trace_end_ts = end;
        let p = cpu(&conn, &inspection, &cpu_query(0, 1000, 10)).unwrap();
        assert_eq!(
            p.items[0].range,
            TraceTimeRange::event(relative_start, relative_end).unwrap()
        );
    }
}
#[test]
fn scheduling_optional_values_count_once_and_do_not_forge_cpu_zero() {
    let (conn, inspection) = fixture(
        "ALTER TABLE sched_slice ADD COLUMN end_state TEXT;
        ALTER TABLE sched_slice ADD COLUMN priority INTEGER;
        UPDATE process SET name=X'FF'; UPDATE thread SET name=X'FF';
        UPDATE sched_slice SET end_state=X'FF',priority='bad';
        INSERT INTO sched_slice VALUES(1,1001,1,'bad',-11,-10,NULL,NULL);",
    );
    let p = cpu(&conn, &inspection, &cpu_query(0, 1000, 10)).unwrap();
    assert_eq!(p.items.len(), 1);
    assert_eq!(
        p.items[0].key.row_id, 0,
        "event row ID zero is not an absent relationship"
    );
    assert!(p.items[0].process_name.is_none() && p.items[0].thread_name.is_none());
    assert!(p.items[0].end_state.is_none() && p.items[0].priority.is_none());
    assert_eq!(
        count(&p, QualityCategory::DroppedValue, "sched_slice.value"),
        Some(7)
    );
    assert!(p.truncated);
}
#[test]
fn optional_strings_keep_empty_and_embedded_nul_and_drop_invalid_utf8() {
    let (conn, inspection) = fixture(
        "ALTER TABLE sched_slice ADD COLUMN end_state TEXT;
        UPDATE process SET name=''; UPDATE thread SET name=CAST(X'610062' AS TEXT);
        UPDATE sched_slice SET end_state=CAST(X'FF' AS TEXT);",
    );
    let p = cpu(&conn, &inspection, &cpu_query(0, 1000, 10)).unwrap();
    assert_eq!(p.items[0].process_name.as_deref(), Some(""));
    assert_eq!(p.items[0].thread_name.as_deref(), Some("a\0b"));
    assert_eq!(p.items[0].end_state, None);
    assert_eq!(
        p.data_quality.status,
        QualityStatus::Ok,
        "the Swift SQL projection counts storage class/byte bounds, not UTF-8 validity for optional CPU text"
    );
    let json = serde_json::to_value(&p.items[0]).unwrap();
    assert!(json["endState"].is_null());
    assert_eq!(json["threadKey"], serde_json::json!({"itid":-11}));
    assert_eq!(json["processKey"], serde_json::json!({"ipid":-10}));
    assert_eq!(
        json["key"],
        serde_json::json!({"table":"sched_slice","rowID":0})
    );
}
#[test]
fn relationships_preserve_internal_keys_and_count_missing_joins() {
    let (conn,inspection)=fixture("DELETE FROM sched_slice;
        INSERT INTO sched_slice VALUES(1,1100,100,0,0,0),(2,1200,100,1,-11,-10),(3,1300,100,2,999,999);
        DELETE FROM thread_state;INSERT INTO thread_state VALUES(1,1100,100,0,'R'),(2,1200,100,-11,'Running'),(3,1300,100,999,'S');");
    let p = cpu(&conn, &inspection, &cpu_query(0, 1000, 10)).unwrap();
    assert!(p.items[0].thread_key.is_none() && p.items[0].process_key.is_none());
    assert_eq!(p.items[1].thread_key, Some(ThreadKey { itid: -11 }));
    assert_eq!(p.items[2].process_key, Some(ProcessKey { ipid: 999 }));
    assert_eq!(
        count(
            &p,
            QualityCategory::ReferentialIntegrity,
            "sched_slice.identity"
        ),
        Some(2)
    );
    let s = states(&conn, &inspection, &state_query(0, 1000, 10)).unwrap();
    assert_eq!(
        s.items.iter().map(|v| v.key.row_id).collect::<Vec<_>>(),
        [2, 3]
    );
    assert_eq!(
        count(&s, QualityCategory::DroppedValue, "thread_state.value"),
        Some(1)
    );
    assert_eq!(
        count(
            &s,
            QualityCategory::ReferentialIntegrity,
            "thread_state.identity"
        ),
        Some(1)
    );
    assert_eq!(s.items[1].thread_key, ThreadKey { itid: 999 });
}
#[test]
fn source_limit_order_and_quality_exclude_the_lookahead_row() {
    let (conn,inspection)=fixture("DELETE FROM sched_slice;
        INSERT INTO sched_slice VALUES(3,1100,1,0,-11,-10),(2,1100,1,0,-11,-10),(4,1200,1,'bad',-11,-10);");
    let p = cpu(&conn, &inspection, &cpu_query(0, 1000, 2)).unwrap();
    assert_eq!(
        p.items.iter().map(|v| v.key.row_id).collect::<Vec<_>>(),
        [2, 3]
    );
    assert!(p.truncated);
    assert_eq!(
        count(&p, QualityCategory::DroppedValue, "sched_slice.value"),
        None
    );
    let p = cpu(&conn, &inspection, &cpu_query(0, 1000, 3)).unwrap();
    assert_eq!(
        count(&p, QualityCategory::DroppedValue, "sched_slice.value"),
        Some(1)
    );
    let (conn, inspection) = fixture(
        "DELETE FROM sched_slice;
        INSERT INTO sched_slice VALUES(1,1000,1,'bad',-11,-10),(2,1100,1,0,-11,-10);",
    );
    let p = cpu(&conn, &inspection, &cpu_query(0, 1000, 1)).unwrap();
    assert!(
        p.items.is_empty() && p.truncated,
        "limits admit source rows; they never fill from extra rows after dropping a malformed one"
    );
}
#[test]
fn malformed_event_id_is_an_error_only_when_admitted() {
    let (conn, inspection) = fixture("INSERT INTO sched_slice VALUES(NULL,1100,1,0,-11,-10);");
    let p = cpu(&conn, &inspection, &cpu_query(0, 1000, 1)).unwrap();
    assert_eq!(p.items[0].key.row_id, 0);
    assert!(p.truncated);
    assert_eq!(
        cpu(&conn, &inspection, &cpu_query(0, 1000, 2)),
        Err(StoreError::InvalidIdentity)
    );
    assert!(cpu(&conn, &inspection, &cpu_query(0, 100, 10)).is_ok());
}
#[test]
fn cpu_overlap_is_per_cpu_in_source_order_including_instants() {
    let (conn, inspection) = fixture(
        "DELETE FROM sched_slice;
        INSERT INTO sched_slice VALUES(1,1000,200,0,-11,-10),(2,1050,0,0,-11,-10),
        (3,1100,10,1,-11,-10),(4,1150,10,0,-11,-10),(5,1200,10,0,-11,-10);",
    );
    let p = cpu(&conn, &inspection, &cpu_query(0, 1000, 10)).unwrap();
    assert_eq!(
        count(&p, QualityCategory::InvalidValue, "sched_slice.overlap"),
        Some(2)
    );
    assert!(!p.truncated);
}
#[test]
fn normalized_and_raw_state_filters_are_bound_case_specific_and_composable() {
    let (conn,inspection)=fixture("DELETE FROM thread_state;
        INSERT INTO thread_state VALUES(1,1100,10,-11,'r'),(2,1100,10,-11,'R+'),(3,1100,10,-11,'READY'),
        (4,1100,10,-11,'Running'),(5,1100,10,-11,'uninterruptible'),(6,1100,10,-11,'Stopped'),
        (7,1100,10,-11,'mystery'),(8,1100,10,-11,''),(9,1100,10,-11,'ſ');");
    let full = states(&conn, &inspection, &state_query(0, 1000, 10)).unwrap();
    assert_eq!(full.items[6].state, "mystery");
    assert_eq!(full.items[6].normalized_state, None);
    assert_eq!(full.items[7].state, "");
    assert_eq!(
        full.items[8].normalized_state,
        Some(TraceThreadState::Sleeping)
    );
    assert_eq!(
        count(&full, QualityCategory::InvalidValue, "thread_state.state"),
        Some(2)
    );
    assert!(!full.truncated);
    let mut q = state_query(0, 1000, 10);
    q.state = Some(TraceThreadState::Runnable);
    assert_eq!(
        states(&conn, &inspection, &q)
            .unwrap()
            .items
            .iter()
            .map(|v| v.key.row_id)
            .collect::<Vec<_>>(),
        [1, 2, 3]
    );
    q.raw_state = Some("r".to_owned());
    assert_eq!(states(&conn, &inspection, &q).unwrap().items.len(), 1);
    q.raw_state = Some("R".to_owned());
    assert!(states(&conn, &inspection, &q).unwrap().items.is_empty());
    q.raw_state = Some("' OR 1=1 --".to_owned());
    q.state = None;
    assert!(states(&conn, &inspection, &q).unwrap().items.is_empty());
    q.raw_state = None;
    q.state = Some(TraceThreadState::Sleeping);
    assert!(
        states(&conn, &inspection, &q).unwrap().items.is_empty(),
        "SQLite UPPER's ASCII filtering is preserved even when a Unicode raw state normalizes in Swift/Rust"
    );
}
#[test]
fn thread_optional_cpu_requires_integer_storage_but_does_not_drop_the_interval() {
    let (conn, inspection) = fixture(
        "ALTER TABLE thread_state ADD COLUMN cpu INTEGER;
        UPDATE thread_state SET cpu='bad'; INSERT INTO thread_state VALUES(1,1100,10,-11,'S',2);
        UPDATE process SET pid='bad'; UPDATE thread SET tid='bad';",
    );
    let full = states(&conn, &inspection, &state_query(0, 1000, 10)).unwrap();
    assert_eq!(full.items.len(), 2);
    assert!(
        full.items[0].cpu.is_none() && full.items[0].pid.is_none() && full.items[0].tid.is_none()
    );
    assert_eq!(
        count(&full, QualityCategory::DroppedValue, "thread_state.value"),
        Some(5)
    );
    let mut q = state_query(0, 1000, 10);
    q.cpu = Some(2);
    assert_eq!(
        states(&conn, &inspection, &q).unwrap().items[0].key.row_id,
        1
    );
}
#[test]
fn thread_required_text_drops_unusable_values_and_bounds_utf8_bytes() {
    let (conn,inspection)=fixture("DELETE FROM thread_state;
        INSERT INTO thread_state VALUES(1,1100,10,-11,NULL),(2,1100,10,-11,X'FF'),(3,1100,10,-11,CAST(X'FF' AS TEXT)),
        (4,1100,10,-11,printf('%0257d',0)),(5,1100,10,-11,'Running');");
    let p = states(&conn, &inspection, &state_query(0, 1000, 10)).unwrap();
    assert_eq!(p.items.len(), 1);
    assert_eq!(p.items[0].key.row_id, 5);
    assert_eq!(
        count(&p, QualityCategory::DroppedValue, "thread_state.value"),
        Some(4)
    );
    let mut q = state_query(0, 1000, 10);
    q.raw_state = Some("界".repeat(86));
    assert_eq!(
        states(&conn, &inspection, &q),
        Err(StoreError::InvalidQuery)
    );
    q.raw_state = Some("界".repeat(85));
    assert!(states(&conn, &inspection, &q).unwrap().items.is_empty());
}
#[test]
fn supported_empty_is_distinct_from_absent_capability_or_absent_cpu_column() {
    let (conn, mut inspection) = fixture("");
    let mut q = state_query(500, 600, 10);
    assert!(states(&conn, &inspection, &q).unwrap().capability_available);
    q.cpu = Some(0);
    let p = states(&conn, &inspection, &q).unwrap();
    assert!(!p.capability_available && !p.truncated && p.items.is_empty());
    inspection.capabilities.cpu_scheduling = false;
    let p = cpu(&conn, &inspection, &cpu_query(0, 1001, 10)).unwrap();
    assert!(
        !p.capability_available,
        "unavailable capability precedes trace-duration validation, as in Swift"
    );
    assert_eq!(
        cpu(&conn, &inspection, &cpu_query(1, 1, 10)),
        Err(StoreError::InvalidQuery)
    );
}
#[test]
fn filters_use_internal_keys_without_confusing_pid_tid_and_reject_invalid_bounds() {
    let (conn, inspection) = fixture("");
    let mut q = cpu_query(0, 1000, 10);
    q.process_key = Some(-10);
    q.thread_key = Some(-11);
    q.pid = Some(900);
    q.tid = Some(901);
    q.cpu = Some(0);
    assert_eq!(cpu(&conn, &inspection, &q).unwrap().items.len(), 1);
    q.process_key = Some(900);
    assert!(cpu(&conn, &inspection, &q).unwrap().items.is_empty());
    for (end, limit) in [(1001, 1), (1000, 0), (1000, 100001)] {
        assert_eq!(
            cpu(&conn, &inspection, &cpu_query(0, end, limit)),
            Err(StoreError::InvalidQuery)
        );
    }
    assert_eq!(
        cpu(&conn, &inspection, &cpu_query(0, 1000, usize::MAX)),
        Err(StoreError::InvalidQuery)
    );
    assert!(cpu(&conn, &inspection, &cpu_query(0, 1000, 1)).is_ok());
}
#[test]
fn cancellation_deadline_and_vm_failures_leave_connection_usable() {
    let (conn, inspection) = fixture("");
    for expired in [false, true] {
        let mut b = budget();
        if expired {
            b.deadline = Instant::now() - Duration::from_millis(1);
        } else {
            b.cancellation.cancel();
        }
        let failed = Database::borrow_readonly(&conn, &b).err().unwrap();
        assert_eq!(
            failed,
            if expired {
                StoreError::DeadlineExceeded
            } else {
                StoreError::Cancelled
            }
        );
        assert_eq!(
            cpu(&conn, &inspection, &cpu_query(0, 1000, 1))
                .unwrap()
                .items
                .len(),
            1
        );
    }
    let b = budget();
    let db = Database::borrow_readonly(&conn, &b).unwrap();
    assert_eq!(db.query("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10000) SELECT sum(x) FROM n",[],1,100,|r|integer(r,0)),Err(StoreError::VmBudgetExceeded));
    assert_eq!(
        EventSchema::read(&db)
            .unwrap()
            .cpu_slices(&db, &inspection, &cpu_query(0, 1000, 1))
            .unwrap()
            .items
            .len(),
        1
    );
}
