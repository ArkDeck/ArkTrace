use super::*;
use crate::{ValidationBudget, database::Database};
use arktrace_contract::{DirectoryNameMatch, QualityCategory, TraceTimeRange};
use arktrace_platform::CancellationToken;
use rusqlite::Connection;
use std::time::{Duration, Instant};

const SCHEMA:&str="CREATE TABLE trace_range(start_ts INTEGER,end_ts INTEGER);INSERT INTO trace_range VALUES(1000,2000);
CREATE TABLE process(ipid INTEGER,pid INTEGER,name TEXT,start_ts INTEGER);INSERT INTO process VALUES(-10,900,'process',1000);
CREATE TABLE thread(itid INTEGER,tid INTEGER,name TEXT,start_ts INTEGER,ipid INTEGER);INSERT INTO thread VALUES(-11,901,'thread',1000,-10);
CREATE TABLE sched_slice(id INTEGER,ts INTEGER,dur INTEGER,cpu INTEGER,itid INTEGER,ipid INTEGER);INSERT INTO sched_slice VALUES(0,1000,1,0,-11,-10);
CREATE TABLE thread_state(id INTEGER,ts INTEGER,dur INTEGER,itid INTEGER,state TEXT);INSERT INTO thread_state VALUES(0,1000,1,-11,'Running');
CREATE TABLE callstack(id INTEGER,ts INTEGER,dur INTEGER,callid INTEGER,name TEXT);INSERT INTO callstack VALUES(0,1000,1,-11,'anchor');";
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
    conn.execute_batch(extra).unwrap();
    (conn, inspection)
}
fn query(start: i64, end: i64, limit: usize) -> TraceSliceQuery {
    TraceSliceQuery {
        range: TraceTimeRange::event(start, end).unwrap(),
        event_key: None,
        process_key: None,
        pid: None,
        thread_key: None,
        tid: None,
        name: None,
        name_match: DirectoryNameMatch::Exact,
        minimum_duration_ns: None,
        depth: None,
        unattributed_only: false,
        includes_argument_set: false,
        limit,
    }
}
fn slices(
    conn: &Connection,
    inspection: &DatabaseInspection,
    q: &TraceSliceQuery,
) -> Result<EventPage<TraceSlice>, StoreError> {
    let budget = budget();
    let db = Database::borrow_readonly(conn, &budget)?;
    SliceSchema::read(&db)?.slices(&db, inspection, q)
}
fn count(p: &EventPage<TraceSlice>, category: QualityCategory, scope: &str) -> Option<i64> {
    p.data_quality
        .warnings
        .iter()
        .find(|w| w.category == category && w.scope.as_deref() == Some(scope))
        .and_then(|w| w.count)
}
#[test]
fn unattributed_scope_selects_before_limit_and_focus_cannot_cross_lanes() {
    let input: serde_json::Value = serde_json::from_str(include_str!(
        "../../../arktrace-viewer/tests/fixtures/scoped-slices-inputs.json"
    ))
    .unwrap();
    let conn = Connection::open_in_memory().unwrap();
    conn.execute_batch(input["sql"].as_str().unwrap()).unwrap();
    let inspection = Database::borrow_readonly(&conn, &budget())
        .unwrap()
        .inspect()
        .unwrap();
    let general = query(0, 1000, 2);
    let swift: Vec<serde_json::Value> = serde_json::from_str(include_str!(
        "../../../arktrace-viewer/tests/fixtures/swift-scoped-slices.json"
    ))
    .unwrap();
    // Complete general page stays identical to the independent actual Swift
    // repository. The Viewer output below retains full Swift snapshots.
    let mut general_expected = swift[0]["result"].clone();
    assert_eq!(
        general_expected["dataQuality"],
        serde_json::json!({"issues":[],"warnings":[],"status":"ok"})
    );
    // Swift's human Codable quality has an additional issues field. Verify
    // its complete empty envelope before comparing the closed machine shape.
    general_expected["dataQuality"] = serde_json::to_value(
        arktrace_contract::DataQuality::machine(arktrace_contract::QualityStatus::Ok, vec![])
            .unwrap(),
    )
    .unwrap();
    assert_eq!(
        serde_json::to_value(slices(&conn, &inspection, &general).unwrap()).unwrap(),
        general_expected
    );
    assert_eq!(
        slices(&conn, &inspection, &general)
            .unwrap()
            .items
            .iter()
            .map(|v| v.key.row_id)
            .collect::<Vec<_>>(),
        [1, 2]
    );
    let mut scoped = general;
    scoped.unattributed_only = true;
    let page = slices(&conn, &inspection, &scoped).unwrap();
    assert_eq!(
        page.items.iter().map(|v| v.key.row_id).collect::<Vec<_>>(),
        [7, 8]
    );
    assert!(page.truncated);
    assert!(page.items.iter().all(|v| v.thread_key.is_none()));
    let compare_details = |page: &EventPage<TraceSlice>, vector: usize| {
        let expected = swift[vector]["result"]["tracks"][0]["primitives"]
            .as_array()
            .unwrap();
        assert_eq!(page.items.len(), expected.len());
        for (item, expected) in page.items.iter().zip(expected) {
            let detail = &expected["detail"]["_0"];
            assert_eq!(serde_json::to_value(item.key).unwrap(), detail["eventKey"]);
            assert_eq!(serde_json::to_value(item.range).unwrap(), detail["range"]);
            assert_eq!(item.is_open_ended, detail["inspector"]["isOpenEnded"]);
            assert_eq!(item.name, detail["inspector"]["name"].as_str().unwrap());
        }
    };
    compare_details(&page, 1);
    compare_details(&page, 5);
    let mut assigned = scoped.clone();
    assigned.unattributed_only = false;
    assigned.thread_key = Some(-11);
    compare_details(&slices(&conn, &inspection, &assigned).unwrap(), 2);
    scoped.event_key = Some(EventKey {
        table: EventTable::Callstack,
        row_id: 1,
    });
    assert!(
        slices(&conn, &inspection, &scoped)
            .unwrap()
            .items
            .is_empty()
    );
    scoped.event_key = Some(EventKey {
        table: EventTable::Callstack,
        row_id: 9,
    });
    let focused = slices(&conn, &inspection, &scoped).unwrap();
    assert_eq!(focused.items.len(), 1);
    assert!(focused.items[0].is_open_ended);
    assert_eq!(
        focused.items[0].range,
        TraceTimeRange::event(300, 1000).unwrap()
    );
    assert_eq!(
        serde_json::to_value(focused.items[0].key).unwrap(),
        swift[4]["result"]["tracks"][0]["primitives"][0]["detail"]["_0"]["eventKey"]
    );
    assert_eq!(
        serde_json::to_value(focused.items[0].range).unwrap(),
        swift[4]["result"]["tracks"][0]["primitives"][0]["detail"]["_0"]["range"]
    );
}

#[test]
fn named_half_open_keeps_full_clipped_ranges_instants_and_open_ends() {
    let (conn, inspection) = fixture(
        "DELETE FROM callstack;INSERT INTO callstack VALUES(1,1050,200,-11,'long'),(2,1150,0,-11,'instant'),(3,1160,NULL,-11,'null'),(4,1170,-1,-11,'negative'),(5,1200,0,-11,'exclusive'),(6,1100,50,-11,'ends'),(8,900,300,-11,'before');",
    );
    let p = slices(&conn, &inspection, &query(150, 200, 20)).unwrap();
    assert_eq!(
        p.items.iter().map(|v| v.key.row_id).collect::<Vec<_>>(),
        [8, 1, 2, 3, 4]
    );
    assert_eq!(p.items[0].range, TraceTimeRange::event(0, 200).unwrap());
    assert_eq!(p.items[1].range, TraceTimeRange::event(50, 250).unwrap());
    assert!(p.items[2].is_instant());
    assert!(
        p.items[3..]
            .iter()
            .all(|v| v.is_open_ended && v.range.end_ns() == 1000)
    );
    assert!(!p.truncated);
    assert_eq!(
        count(&p, QualityCategory::ClampedValue, "callstack.ts"),
        Some(1)
    );
}
#[test]
fn duration_threshold_uses_full_trace_normalized_range_and_checked_extremes() {
    let (conn, inspection) = fixture(
        "DELETE FROM callstack;INSERT INTO callstack VALUES(1,1900,9223372036854775807,-11,'overflow'),(2,900,200,-11,'before'),(3,900,NULL,-11,'open');",
    );
    let mut q = query(950, 1000, 20);
    q.minimum_duration_ns = Some(100);
    let p = slices(&conn, &inspection, &q).unwrap();
    assert_eq!(
        p.items.iter().map(|v| v.key.row_id).collect::<Vec<_>>(),
        [3, 1]
    );
    assert_eq!(p.items[1].range, TraceTimeRange::event(900, 1000).unwrap());
    q.minimum_duration_ns = Some(101);
    assert_eq!(
        slices(&conn, &inspection, &q)
            .unwrap()
            .items
            .iter()
            .map(|v| v.key.row_id)
            .collect::<Vec<_>>(),
        [3]
    );
    q = query(0, 1, 20);
    q.minimum_duration_ns = Some(100);
    assert_eq!(
        slices(&conn, &inspection, &q)
            .unwrap()
            .items
            .iter()
            .map(|v| v.key.row_id)
            .collect::<Vec<_>>(),
        [2, 3]
    );
    q.minimum_duration_ns = Some(1000);
    assert_eq!(
        slices(&conn, &inspection, &q).unwrap().items[0].key.row_id,
        3
    );
    for (start, end, ts, dur, a, b) in [
        (i64::MIN, i64::MIN + 1000, i64::MIN + 10, 20, 10, 30),
        (i64::MAX - 1000, i64::MAX, i64::MAX - 100, 200, 900, 1000),
    ] {
        let (conn, mut inspection) = fixture(&format!(
            "DELETE FROM callstack;INSERT INTO callstack VALUES(1,{ts},{dur},-11,'extreme')"
        ));
        inspection.trace_start_ts = start;
        inspection.trace_end_ts = end;
        let mut q = query(0, 1000, 2);
        q.minimum_duration_ns = Some(b - a);
        assert_eq!(
            slices(&conn, &inspection, &q).unwrap().items[0].range,
            TraceTimeRange::event(a, b).unwrap()
        );
    }
}
#[test]
fn named_filters_escape_like_preserve_empty_name_and_use_internal_identities() {
    let (conn, inspection) = fixture(
        "DELETE FROM callstack;INSERT INTO callstack VALUES(1,1100,10,-11,'A%_\\中文-tail'),(2,1100,10,-11,'AXX中文-tail'),(3,1100,10,0,'prefix-A%_\\中文'),(4,1100,10,NULL,'');",
    );
    let mut q = query(0, 1000, 20);
    q.name = Some("a%_\\中文".into());
    q.name_match = DirectoryNameMatch::Prefix;
    assert_eq!(
        slices(&conn, &inspection, &q).unwrap().items[0].key.row_id,
        1
    );
    q.name_match = DirectoryNameMatch::Contains;
    assert_eq!(
        slices(&conn, &inspection, &q)
            .unwrap()
            .items
            .iter()
            .map(|v| v.key.row_id)
            .collect::<Vec<_>>(),
        [1, 3]
    );
    q.name_match = DirectoryNameMatch::Exact;
    assert!(slices(&conn, &inspection, &q).unwrap().items.is_empty());
    q.name = Some(String::new());
    assert_eq!(
        slices(&conn, &inspection, &q).unwrap().items[0].key.row_id,
        4
    );
    q = query(0, 1000, 20);
    q.process_key = Some(-10);
    q.thread_key = Some(-11);
    q.pid = Some(900);
    q.tid = Some(901);
    assert_eq!(slices(&conn, &inspection, &q).unwrap().items.len(), 2);
    q.event_key = Some(EventKey {
        table: EventTable::Callstack,
        row_id: 2,
    });
    assert_eq!(
        slices(&conn, &inspection, &q).unwrap().items[0].name,
        "AXX中文-tail"
    );
    q = query(0, 1000, 20);
    q.name = Some("' OR 1=1 --".into());
    assert!(slices(&conn, &inspection, &q).unwrap().items.is_empty());
}
#[test]
fn optional_parent_cookie_depth_and_arguments_keep_distinct_sentinel_rules() {
    let (conn, inspection) = fixture(
        "ALTER TABLE callstack ADD COLUMN depth INTEGER;ALTER TABLE callstack ADD COLUMN cat TEXT;ALTER TABLE callstack ADD COLUMN parent_id INTEGER;ALTER TABLE callstack ADD COLUMN cookie INTEGER;ALTER TABLE callstack ADD COLUMN argsetid INTEGER;DELETE FROM callstack;INSERT INTO callstack VALUES(1,1100,10,-11,'one',-3,'io',4294967295,-1,5),(2,1101,10,-11,'two',3,NULL,1,0,0),(3,1102,10,0,'three',NULL,NULL,0,NULL,-1),(4,1103,10,NULL,'four',NULL,NULL,-1,NULL,NULL);",
    );
    let mut q = query(0, 1000, 20);
    let p = slices(&conn, &inspection, &q).unwrap();
    assert_eq!(
        p.items
            .iter()
            .map(|v| v.parent_event_key.map(|k| k.row_id))
            .collect::<Vec<_>>(),
        [None, Some(1), None, None]
    );
    assert!(p.items[0].is_async);
    assert!(!p.items[1].is_async);
    assert_eq!(p.items[0].depth, Some(-3));
    assert_eq!(p.items[0].category.as_deref(), Some("io"));
    assert!(p.items.iter().all(|v| v.arg_set_id.is_none()));
    assert!(
        p.items[2..]
            .iter()
            .all(|v| v.thread_key.is_none() && v.process_key.is_none())
    );
    q.includes_argument_set = true;
    assert_eq!(
        slices(&conn, &inspection, &q)
            .unwrap()
            .items
            .iter()
            .map(|v| v.arg_set_id)
            .collect::<Vec<_>>(),
        [Some(5), Some(0), Some(-1), None]
    );
    q.depth = Some(3);
    assert_eq!(
        slices(&conn, &inspection, &q).unwrap().items[0].key.row_id,
        2
    );
}
#[test]
fn dropped_name_never_refills_and_lookahead_identity_does_not_fail_the_page() {
    let (conn, inspection) = fixture(
        "DELETE FROM callstack;INSERT INTO callstack VALUES(1,1100,10,-11,X'FF'),(2,1101,10,-11,'valid'),('bad-id',1102,10,-11,'lookahead');",
    );
    let p = slices(&conn, &inspection, &query(0, 1000, 1)).unwrap();
    assert!(p.items.is_empty() && p.truncated);
    assert_eq!(
        count(&p, QualityCategory::DroppedValue, "callstack.value"),
        Some(1)
    );
    let p = slices(&conn, &inspection, &query(0, 1000, 2)).unwrap();
    assert_eq!(p.items[0].key.row_id, 2);
    assert_eq!(p.items.len(), 1);
    assert_eq!(
        slices(&conn, &inspection, &query(0, 1000, 3)),
        Err(StoreError::InvalidIdentity)
    );
}
#[test]
fn optional_storage_degrades_once_and_utf8_validation_preserves_empty_text() {
    let (conn, inspection) = fixture(
        "ALTER TABLE callstack ADD COLUMN depth INTEGER;ALTER TABLE callstack ADD COLUMN cat TEXT;ALTER TABLE callstack ADD COLUMN parent_id INTEGER;ALTER TABLE callstack ADD COLUMN cookie INTEGER;UPDATE callstack SET name='',depth='bad',cat=CAST(X'80' AS TEXT),parent_id='bad',cookie='bad';UPDATE process SET pid='bad',name=CAST(X'80' AS TEXT);UPDATE thread SET tid=1.5,name=CAST(X'80' AS TEXT);",
    );
    let p = slices(&conn, &inspection, &query(0, 1000, 20)).unwrap();
    assert_eq!(p.items.len(), 1);
    let row = &p.items[0];
    assert_eq!(row.name, "");
    assert!(
        row.category.is_none()
            && row.process_name.is_none()
            && row.thread_name.is_none()
            && row.depth.is_none()
            && row.parent_event_key.is_none()
    );
    assert!(!row.is_async);
    assert_eq!(
        count(&p, QualityCategory::DroppedValue, "callstack.value"),
        Some(5)
    );
    assert!(p.truncated);
}
#[test]
fn missing_depth_and_unavailable_capability_have_separate_contracts() {
    let (conn, mut inspection) = fixture("");
    let mut q = query(0, 1000, 20);
    q.depth = Some(0);
    assert_eq!(
        slices(&conn, &inspection, &q),
        Err(StoreError::NamedSliceDepthUnavailable)
    );
    inspection.capabilities.named_slices = false;
    q.range = TraceTimeRange::query(0, 1001).unwrap();
    let p = slices(&conn, &inspection, &q).unwrap();
    assert!(!p.capability_available && !p.truncated && p.items.is_empty());
    q.limit = 0;
    assert_eq!(
        slices(&conn, &inspection, &q),
        Err(StoreError::InvalidQuery)
    );
}
#[test]
fn missing_thread_reference_and_absent_identity_remain_distinct() {
    let (conn, inspection) = fixture(
        "DELETE FROM callstack;INSERT INTO callstack VALUES(1,1100,10,-12,'missing'),(2,1101,10,0,'zero'),(3,1102,10,NULL,'null');ALTER TABLE callstack ADD COLUMN argsetid INTEGER;UPDATE callstack SET argsetid='bad';",
    );
    let p = slices(
        &conn,
        &inspection,
        &TraceSliceQuery {
            includes_argument_set: true,
            ..query(0, 1000, 20)
        },
    )
    .unwrap();
    assert_eq!(p.items.len(), 3);
    assert_eq!(p.items[0].thread_key, Some(ThreadKey { itid: -12 }));
    assert!(p.items[1..].iter().all(|s| s.thread_key.is_none()));
    assert!(
        p.items
            .iter()
            .all(|s| s.process_key.is_none() && s.arg_set_id.is_none())
    );
    assert_eq!(
        count(
            &p,
            QualityCategory::ReferentialIntegrity,
            "callstack.identity"
        ),
        Some(1)
    );
    assert_eq!(
        count(&p, QualityCategory::DroppedValue, "callstack.value"),
        None
    );
}
#[test]
fn named_request_cancellation_and_bad_bounds_do_not_poison_next_request() {
    let (conn, inspection) = fixture("");
    let q = query(0, 1000, 20);
    let expected = slices(&conn, &inspection, &q).unwrap();
    let b = budget();
    b.cancellation.cancel();
    assert!(matches!(
        Database::borrow_readonly(&conn, &b),
        Err(StoreError::Cancelled)
    ));
    let mut bad = q.clone();
    bad.name = Some("界".repeat(1366));
    assert_eq!(
        slices(&conn, &inspection, &bad),
        Err(StoreError::InvalidQuery)
    );
    assert_eq!(slices(&conn, &inspection, &q).unwrap(), expected);
}
