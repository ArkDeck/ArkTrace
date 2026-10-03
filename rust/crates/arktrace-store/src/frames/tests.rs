use super::*;
use crate::{ValidationBudget, database::Database};
use arktrace_contract::{QualityCategory, TraceTimeRange};
use arktrace_platform::CancellationToken;
use rusqlite::Connection;
use std::time::{Duration, Instant};
const SCHEMA:&str="CREATE TABLE trace_range(start_ts INTEGER,end_ts INTEGER);INSERT INTO trace_range VALUES(1000,2000);
CREATE TABLE process(ipid INTEGER,pid INTEGER,name TEXT,start_ts INTEGER);INSERT INTO process VALUES(-10,900,'process',1000);
CREATE TABLE thread(itid INTEGER,tid INTEGER,name TEXT,start_ts INTEGER,ipid INTEGER);INSERT INTO thread VALUES(-11,901,'thread',1000,-10);
CREATE TABLE sched_slice(id INTEGER,ts INTEGER,dur INTEGER,cpu INTEGER,itid INTEGER,ipid INTEGER);
CREATE TABLE thread_state(id INTEGER,ts INTEGER,dur INTEGER,itid INTEGER,state TEXT);
CREATE TABLE callstack(id INTEGER,ts INTEGER,dur INTEGER,callid INTEGER,name TEXT);";
const FRAME: &str = "CREATE TABLE frame_slice(id INTEGER,ts INTEGER,dur INTEGER,vsync INTEGER,ipid INTEGER,type INTEGER,flag INTEGER,itid INTEGER);";
fn budget() -> ValidationBudget {
    ValidationBudget {
        maximum_database_bytes: 256 * 1024 * 1024,
        deadline: Instant::now() + Duration::from_secs(10),
        cancellation: CancellationToken::default(),
    }
}
fn fixture(extra: &str) -> (Connection, DatabaseInspection) {
    let c = Connection::open_in_memory().unwrap();
    c.execute_batch(SCHEMA).unwrap();
    c.execute_batch(extra).unwrap();
    let i = Database::borrow_writable(&c, &budget())
        .unwrap()
        .inspect()
        .unwrap();
    (c, i)
}
fn query(start: i64, end: i64, limit: usize) -> TraceFrameQuery {
    TraceFrameQuery {
        range: TraceTimeRange::event(start, end).unwrap(),
        process_key: None,
        limit,
    }
}
fn frames(
    c: &Connection,
    i: &DatabaseInspection,
    q: &TraceFrameQuery,
) -> Result<EventPage<TraceFrame>, StoreError> {
    let b = budget();
    let db = Database::borrow_readonly(c, &b)?;
    FrameSchema::read(&db)?.frames(&db, i, q)
}
#[test]
fn seven_required_columns_work_without_additive_thread_identity() {
    let (c, i) = fixture(
        "CREATE TABLE frame_slice(id INTEGER,ts INTEGER,dur INTEGER,vsync INTEGER,ipid INTEGER,type INTEGER,flag INTEGER);INSERT INTO frame_slice VALUES(1,1100,100,9,-10,0,2);",
    );
    let p = frames(&c, &i, &query(0, 1000, 20)).unwrap();
    assert!(p.capability_available);
    assert_eq!(p.items.len(), 1);
    assert_eq!(p.items[0].thread_key, None);
    assert_eq!(p.items[0].process_key, Some(ProcessKey { ipid: -10 }));
    assert_eq!(p.items[0].pid, Some(900));
    assert!(!p.items[0].is_jank());
}
#[test]
fn frame_kind_and_raw_jank_flag_are_independent() {
    let (c, i) = fixture(&format!(
        "{FRAME} INSERT INTO frame_slice VALUES(1,1100,10,900,-10,0,1,-11),(2,1100,9,900,-10,1,2,-11),(3,1200,10,901,-10,0,3,-11),(4,1300,10,902,-10,0,-99,-11),(5,1400,10,903,-10,9,1,-11);"
    ));
    let p = frames(&c, &i, &query(0, 1000, 20)).unwrap();
    assert_eq!(
        p.items.iter().map(|f| f.kind).collect::<Vec<_>>(),
        [
            TraceFrameKind::Actual,
            TraceFrameKind::Expected,
            TraceFrameKind::Actual,
            TraceFrameKind::Actual
        ]
    );
    assert_eq!(
        p.items.iter().map(TraceFrame::is_jank).collect::<Vec<_>>(),
        [true, false, true, false]
    );
    assert_eq!(p.items[3].flag, Some(-99));
    assert!(p.truncated);
    assert!(
        p.data_quality
            .warnings
            .iter()
            .any(|w| w.category == QualityCategory::DroppedValue
                && w.scope.as_deref() == Some("frame_slice.value")
                && w.count == Some(1))
    );
}
#[test]
fn frame_intersection_keeps_full_ranges_instants_and_open_ends() {
    let (c, i) = fixture(&format!(
        "{FRAME} INSERT INTO frame_slice VALUES(-2,900,300,1,-10,0,2,-11),(1,1050,200,1,-10,0,2,-11),(2,1150,0,1,-10,1,2,-11),(3,1160,NULL,1,-10,0,2,-11),(4,1170,-1,1,-10,0,2,-11),(5,1200,0,1,-10,0,2,-11),(6,1100,50,1,-10,0,2,-11);"
    ));
    let p = frames(&c, &i, &query(150, 200, 20)).unwrap();
    assert_eq!(
        p.items.iter().map(|f| f.key.row_id).collect::<Vec<_>>(),
        [-2, 1, 2, 3, 4]
    );
    assert_eq!(p.items[0].range, TraceTimeRange::event(0, 200).unwrap());
    assert_eq!(p.items[1].range, TraceTimeRange::event(50, 250).unwrap());
    assert_eq!(p.items[2].range, TraceTimeRange::event(150, 150).unwrap());
    assert!(
        p.items[3..]
            .iter()
            .all(|f| f.is_open_ended && f.range.end_ns() == 1000)
    );
    assert!(!p.truncated);
}
#[test]
fn admitted_unknown_kind_is_dropped_without_refilling_source_budget() {
    let (c, i) = fixture(&format!(
        "{FRAME} INSERT INTO frame_slice VALUES(1,1000,1,1,-10,8,2,-11),(2,1001,1,1,-10,0,2,-11);"
    ));
    let p = frames(&c, &i, &query(0, 1000, 1)).unwrap();
    assert!(p.items.is_empty());
    assert!(p.truncated);
}
#[test]
fn malformed_identity_only_fails_when_the_row_is_admitted() {
    let (c, i) = fixture(&format!(
        "{FRAME} INSERT INTO frame_slice VALUES(1,1000,1,1,-10,0,2,-11),('bad',1001,1,1,-10,0,2,-11);"
    ));
    assert_eq!(frames(&c, &i, &query(0, 1000, 1)).unwrap().items.len(), 1);
    assert_eq!(
        frames(&c, &i, &query(0, 1000, 2)),
        Err(StoreError::InvalidFrameIdentity)
    );
}
#[test]
fn frame_optional_storage_does_not_invent_quality_or_remove_zero_identities() {
    let (c, i) = fixture(&format!(
        "{FRAME} UPDATE process SET name=CAST(x'ff' AS TEXT);INSERT INTO frame_slice VALUES(0,1000,1,9223372036854775807,-10,0,1.5,0),(-1,1100,1,1,0,1,NULL,NULL);"
    ));
    let p = frames(&c, &i, &query(0, 1000, 20)).unwrap();
    assert_eq!(p.items[0].key.row_id, 0);
    assert_eq!(p.items[0].flag, None);
    assert_eq!(p.items[0].pid, Some(900));
    assert_eq!(p.items[0].process_name, None);
    assert_eq!(p.items[0].thread_key, Some(ThreadKey { itid: 0 }));
    assert_eq!(p.items[1].process_key, Some(ProcessKey { ipid: 0 }));
    assert!(!p.truncated);
}
#[test]
fn missing_capability_precedes_range_checks_but_query_limits_always_apply() {
    let (c, i) = fixture("");
    for q in [query(0, 0, 1), query(0, 1001, 1)] {
        assert!(!frames(&c, &i, &q).unwrap().capability_available);
    }
    assert_eq!(
        frames(&c, &i, &query(0, 1000, 20_001)),
        Err(StoreError::InvalidQuery)
    );
    let (c, i) = fixture(FRAME);
    for q in [query(0, 0, 1), query(0, 1001, 1)] {
        assert_eq!(frames(&c, &i, &q), Err(StoreError::InvalidQuery));
    }
    assert!(
        frames(&c, &i, &query(0, 1000, 1))
            .unwrap()
            .capability_available
    );
}
#[test]
fn process_key_filter_and_cancellation_leave_next_request_unchanged() {
    let (c, i) = fixture(&format!(
        "{FRAME} INSERT INTO frame_slice VALUES(1,1000,1,1,-10,0,2,-11),(2,1001,1,1,0,0,2,0);"
    ));
    let q = TraceFrameQuery {
        process_key: Some(-10),
        ..query(0, 1000, 20)
    };
    let before = frames(&c, &i, &q).unwrap();
    assert_eq!(before.items.len(), 1);
    let b = budget();
    let db = Database::borrow_readonly(&c, &b).unwrap();
    let schema = FrameSchema::read(&db).unwrap();
    b.cancellation.cancel();
    assert_eq!(schema.frames(&db, &i, &q), Err(StoreError::Cancelled));
    assert_eq!(frames(&c, &i, &q).unwrap(), before);
}
