use super::*;
use crate::ValidationBudget;
use arktrace_contract::DirectoryNameMatch;
use arktrace_platform::CancellationToken;
use rusqlite::Connection;
use std::time::{Duration, Instant};

const SCHEMA: &str = "CREATE TABLE trace_range(start_ts INTEGER,end_ts INTEGER);INSERT INTO trace_range VALUES(1000,2000);
CREATE TABLE process(ipid INTEGER,pid INTEGER,name TEXT,start_ts INTEGER);INSERT INTO process VALUES(-10,900,'process',1000);
CREATE TABLE thread(itid INTEGER,tid INTEGER,name TEXT,start_ts INTEGER,ipid INTEGER);INSERT INTO thread VALUES(-11,901,'thread',1000,-10);
CREATE TABLE sched_slice(id INTEGER,ts INTEGER,dur INTEGER,cpu INTEGER,itid INTEGER,ipid INTEGER);
CREATE TABLE thread_state(id INTEGER,ts INTEGER,dur INTEGER,itid INTEGER,state TEXT);
CREATE TABLE callstack(id INTEGER,ts INTEGER,dur INTEGER,callid INTEGER,name TEXT);
CREATE TABLE cpu_measure_filter(id INTEGER,name TEXT,cpu INTEGER,unit TEXT);INSERT INTO cpu_measure_filter VALUES(10,'cpu',0,'Hz');
CREATE TABLE process_measure_filter(id INTEGER,name TEXT,ipid INTEGER,unit TEXT);INSERT INTO process_measure_filter VALUES(20,'process',-10,'bytes');
CREATE TABLE measure(ts INTEGER,value INTEGER,filter_id INTEGER,dur INTEGER);INSERT INTO measure VALUES(1000,1,10,0);
CREATE TABLE process_measure(ts INTEGER,value INTEGER,filter_id INTEGER,dur INTEGER);INSERT INTO process_measure VALUES(1000,1,20,0);";
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
fn query(start: i64, end: i64, limit: usize) -> CounterQuery {
    CounterQuery {
        range: TraceTimeRange::event(start, end).unwrap(),
        scope: None,
        filter_id: None,
        cpu: None,
        process_key: None,
        pid: None,
        name: None,
        name_match: DirectoryNameMatch::Exact,
        limit,
    }
}
fn counters(
    conn: &Connection,
    inspection: &DatabaseInspection,
    q: &CounterQuery,
) -> Result<EventPage<CounterSeries>, StoreError> {
    let b = budget();
    let db = Database::borrow_readonly(conn, &b)?;
    CounterSchema::read(&db, inspection)?.counters(&db, inspection, q)
}
fn series(
    conn: &Connection,
    inspection: &DatabaseInspection,
    limit: usize,
) -> Result<EventPage<CounterSeriesDescriptor>, StoreError> {
    let b = budget();
    let db = Database::borrow_readonly(conn, &b)?;
    CounterSchema::read(&db, inspection)?.series(
        &db,
        inspection,
        &CounterSeriesQuery {
            range: TraceTimeRange::event(0, 1000).unwrap(),
            limit,
        },
    )
}
fn count<T>(page: &EventPage<T>, category: QualityCategory, scope: &str) -> Option<i64> {
    page.data_quality
        .warnings
        .iter()
        .find(|w| w.category == category && w.scope.as_deref() == Some(scope))
        .and_then(|w| w.count)
}

#[test]
fn samples_keep_full_intervals_open_ends_and_int64_values() {
    let (conn, i) = fixture(
        "DELETE FROM measure;DELETE FROM process_measure;INSERT INTO measure(rowid,ts,value,filter_id,dur) VALUES(-2,900,-9223372036854775808,10,300),(2,1050,9223372036854775807,10,200),(3,1150,7,10,0),(4,1160,8,10,NULL),(5,1170,9,10,-1),(6,1200,10,10,0),(7,1100,11,10,50),(8,1165,12,10,'bad');",
    );
    let page = counters(&conn, &i, &query(150, 200, 20)).unwrap();
    let samples = &page.items[0].samples;
    assert_eq!(
        samples.iter().map(|s| s.key.row_id).collect::<Vec<_>>(),
        [-2, 2, 3, 4, 8, 5]
    );
    assert_eq!(samples[0].value, i64::MIN);
    assert_eq!(samples[0].timestamp_ns, 0);
    assert_eq!(samples[0].duration_ns, Some(200));
    assert_eq!(samples[1].value, i64::MAX);
    assert_eq!(samples[1].duration_ns, Some(200));
    assert_eq!(samples[2].duration_ns, Some(0));
    assert_eq!(samples[3].duration_ns, None);
    assert_eq!(samples[4].duration_ns, Some(0));
    assert_eq!(samples[5].duration_ns, None);
    assert!(page.truncated);
    assert_eq!(
        count(&page, QualityCategory::DroppedValue, "measure.optional"),
        Some(1)
    );
    assert_eq!(
        count(&page, QualityCategory::ClampedValue, "measure.ts"),
        Some(1)
    );
    assert_eq!(
        count(&page, QualityCategory::ClampedValue, "measure.dur"),
        Some(1)
    );
}
#[test]
fn global_sample_budget_uses_timestamp_physical_table_and_rowid() {
    let (conn, mut i) = fixture(
        "DELETE FROM measure;DELETE FROM process_measure;INSERT INTO measure(rowid,ts,value,filter_id,dur) VALUES(8,1000,8,10,0),(3,1000,3,20,0),(9,1001,9,10,0);INSERT INTO process_measure(rowid,ts,value,filter_id,dur) VALUES(-9,1000,-9,20,0),(2,1002,2,20,0);",
    );
    i.process_counter_sample_tables
        .push(CounterSampleTable::Measure);
    let page = counters(&conn, &i, &query(0, 1000, 3)).unwrap();
    assert!(page.truncated);
    assert_eq!(page.items.len(), 2);
    assert_eq!(page.items[0].samples[0].key.row_id, 8);
    assert_eq!(
        page.items[1]
            .samples
            .iter()
            .map(|s| (s.key.table, s.key.row_id))
            .collect::<Vec<_>>(),
        [(EventTable::Measure, 3), (EventTable::ProcessMeasure, -9)]
    );
    assert_eq!(page.items[1].process_key, Some(ProcessKey { ipid: -10 }));
    assert_eq!(page.items[1].pid, Some(900));
}
#[test]
fn series_directory_is_independent_of_crowded_sample_pages() {
    let (conn, i) = fixture(
        "INSERT INTO cpu_measure_filter VALUES(11,'late',9,NULL);INSERT INTO measure VALUES(1500,10,11,0),(1001,2,10,0),(1002,3,10,0);",
    );
    let page = counters(
        &conn,
        &i,
        &CounterQuery {
            cpu: Some(0),
            ..query(0, 1000, 1)
        },
    )
    .unwrap();
    assert_eq!(page.items.len(), 1);
    assert!(page.truncated);
    let descriptors = series(&conn, &i, 10).unwrap();
    assert_eq!(
        descriptors
            .items
            .iter()
            .map(|s| s.filter_id)
            .collect::<Vec<_>>(),
        [10, 11, 20]
    );
    assert!(!descriptors.truncated);
    let descriptors = series(&conn, &i, 1).unwrap();
    assert_eq!(descriptors.items[0].filter_id, 10);
    assert!(descriptors.truncated);
}
#[test]
fn malformed_optional_metadata_is_retained_and_attributed_to_physical_table() {
    let (conn, i) = fixture(
        "UPDATE process SET pid='bad',name=CAST(x'ff' AS TEXT);UPDATE process_measure_filter SET unit=zeroblob(3);UPDATE process_measure SET dur='bad';UPDATE cpu_measure_filter SET unit=CAST(x'ff' AS TEXT);",
    );
    let page = counters(&conn, &i, &query(0, 1000, 20)).unwrap();
    assert_eq!(page.items.len(), 2);
    assert!(page.truncated);
    assert_eq!(page.items[0].unit, None);
    assert_eq!(page.items[1].unit, None);
    assert_eq!(page.items[1].pid, None);
    assert_eq!(page.items[1].process_name, None);
    assert_eq!(
        count(
            &page,
            QualityCategory::DroppedValue,
            "process_measure.optional"
        ),
        Some(3)
    );
    assert_eq!(
        count(&page, QualityCategory::DroppedValue, "measure.optional"),
        None
    );
    let descriptors = series(&conn, &i, 20).unwrap();
    assert!(!descriptors.truncated);
    assert_eq!(
        count(
            &descriptors,
            QualityCategory::DroppedValue,
            "timeline.counter"
        ),
        Some(2)
    );
}
#[test]
fn scope_pid_filter_identity_and_like_literals_stay_parameterized() {
    let (conn, i) = fixture("UPDATE cpu_measure_filter SET name='CPU%_\\中文';");
    let q = query(0, 1000, 20);
    for change in [
        CounterQuery {
            cpu: Some(0),
            ..q.clone()
        },
        CounterQuery {
            filter_id: Some(10),
            ..q.clone()
        },
        CounterQuery {
            name: Some("%_\\中".into()),
            name_match: DirectoryNameMatch::Contains,
            ..q.clone()
        },
        CounterQuery {
            name: Some("cpu".into()),
            name_match: DirectoryNameMatch::Prefix,
            ..q.clone()
        },
    ] {
        assert_eq!(
            counters(&conn, &i, &change).unwrap().items[0].scope,
            CounterScope::Cpu
        );
    }
    for change in [
        CounterQuery {
            process_key: Some(-10),
            ..q.clone()
        },
        CounterQuery {
            pid: Some(900),
            ..q.clone()
        },
        CounterQuery {
            filter_id: Some(20),
            ..q.clone()
        },
    ] {
        let page = counters(&conn, &i, &change).unwrap();
        assert_eq!(page.items.len(), 1);
        assert_eq!(page.items[0].scope, CounterScope::Process);
    }
    assert!(
        counters(
            &conn,
            &i,
            &CounterQuery {
                name: Some("' OR 1=1 --".into()),
                ..q.clone()
            }
        )
        .unwrap()
        .items
        .is_empty()
    );
    assert_eq!(
        counters(
            &conn,
            &i,
            &CounterQuery {
                cpu: Some(0),
                process_key: Some(-10),
                ..q
            }
        ),
        Err(StoreError::InvalidQuery)
    );
}
#[test]
fn sample_identity_uses_unshadowed_alias_and_rejects_without_rowid() {
    let (conn, i) =
        fixture("ALTER TABLE measure ADD COLUMN RoWiD INTEGER;UPDATE measure SET RoWiD=999;");
    assert_eq!(
        counters(&conn, &i, &query(0, 1000, 20)).unwrap().items[0].samples[0]
            .key
            .row_id,
        1
    );
    let (conn, i) = fixture(
        "ALTER TABLE measure ADD COLUMN RoWiD INTEGER;ALTER TABLE measure ADD COLUMN _rowid_ INTEGER;ALTER TABLE measure ADD COLUMN oid INTEGER;",
    );
    assert_eq!(
        counters(
            &conn,
            &i,
            &CounterQuery {
                process_key: Some(-10),
                ..query(0, 1000, 20)
            }
        ),
        Err(StoreError::CounterSampleIdentityUnavailable(
            CounterSampleTable::Measure
        ))
    );
    assert_eq!(series(&conn, &i, 20).unwrap().items.len(), 2);
    let (conn, i) = fixture(
        "DROP TABLE measure;CREATE TABLE measure(ts INTEGER PRIMARY KEY,value INTEGER,filter_id INTEGER,dur INTEGER) WITHOUT ROWID;INSERT INTO measure VALUES(1000,1,10,0);",
    );
    assert_eq!(
        counters(&conn, &i, &query(0, 1000, 20)),
        Err(StoreError::CounterSampleIdentityUnavailable(
            CounterSampleTable::Measure
        ))
    );
    assert_eq!(series(&conn, &i, 20).unwrap().items.len(), 2);
}
#[test]
fn incompatible_required_utf8_and_duplicate_sample_identity_fail_closed() {
    let (conn, i) = fixture("UPDATE cpu_measure_filter SET name=CAST(x'ff' AS TEXT);");
    assert_eq!(
        counters(&conn, &i, &query(0, 1000, 20)),
        Err(StoreError::CounterQueryFailed)
    );
    assert_eq!(series(&conn, &i, 20), Err(StoreError::CounterQueryFailed));
    let (conn, mut i) = fixture("");
    i.cpu_counter_sample_tables
        .push(CounterSampleTable::Measure);
    assert_eq!(
        counters(&conn, &i, &query(0, 1000, 20)),
        Err(StoreError::CounterQueryFailed)
    );
}
#[test]
fn absent_duration_and_invalid_duration_do_not_acquire_open_ended_semantics() {
    let (conn, i) = fixture(
        "DROP TABLE measure;CREATE TABLE measure(ts INTEGER,value INTEGER,filter_id INTEGER);INSERT INTO measure VALUES(1100,1,10),(1200,2,10);DELETE FROM process_measure;",
    );
    let p = counters(&conn, &i, &query(100, 200, 20)).unwrap();
    assert_eq!(p.items[0].samples.len(), 1);
    assert_eq!(p.items[0].samples[0].duration_ns, Some(0));
    assert!(!p.truncated);
}
#[test]
fn unavailable_scope_and_cancellation_do_not_mutate_following_queries() {
    let (conn, mut i) = fixture("");
    i.capabilities.cpu_counters = false;
    i.cpu_counter_sample_tables.clear();
    assert!(
        !counters(
            &conn,
            &i,
            &CounterQuery {
                cpu: Some(0),
                ..query(0, 1000, 20)
            }
        )
        .unwrap()
        .capability_available
    );
    let q = query(0, 1000, 20);
    let before = counters(&conn, &i, &q).unwrap();
    let b = budget();
    let db = Database::borrow_readonly(&conn, &b).unwrap();
    let schema = CounterSchema::read(&db, &i).unwrap();
    b.cancellation.cancel();
    assert_eq!(schema.counters(&db, &i, &q), Err(StoreError::Cancelled));
    assert_eq!(counters(&conn, &i, &q).unwrap(), before);
}
#[test]
fn extreme_duration_and_zero_scope_keep_physical_identity_and_clamp_evidence() {
    let (conn, i) = fixture(
        "DELETE FROM measure;DELETE FROM process_measure;UPDATE process_measure_filter SET id=0,ipid=0;INSERT INTO process_measure(rowid,ts,value,filter_id,dur) VALUES(0,1990,-9223372036854775808,0,9223372036854775807),(-1,900,7,0,NULL),(3,1500,1.5,0,0);",
    );
    let p = counters(
        &conn,
        &i,
        &CounterQuery {
            filter_id: Some(0),
            ..query(0, 1000, 20)
        },
    )
    .unwrap();
    assert_eq!(p.items.len(), 1);
    assert_eq!(p.items[0].process_key, None);
    assert_eq!(
        p.items[0]
            .samples
            .iter()
            .map(|s| s.key.row_id)
            .collect::<Vec<_>>(),
        [-1, 0]
    );
    assert_eq!(p.items[0].samples[0].timestamp_ns, 0);
    assert_eq!(p.items[0].samples[0].duration_ns, None);
    assert_eq!(p.items[0].samples[1].duration_ns, Some(10));
    assert_eq!(p.items[0].samples[1].value, i64::MIN);
    assert_eq!(
        count(&p, QualityCategory::ClampedValue, "process_measure.ts"),
        Some(1)
    );
    assert_eq!(
        count(&p, QualityCategory::ClampedValue, "process_measure.dur"),
        Some(1)
    );
    assert_eq!(
        count(
            &p,
            QualityCategory::ReferentialIntegrity,
            "process_measure_filter.ipid"
        ),
        None
    );
    assert!(!p.truncated);
}
#[test]
fn series_uses_its_own_deadline_and_bounded_range_before_samples() {
    let (conn, i) = fixture("");
    let b = budget();
    let db = Database::borrow_readonly(&conn, &b).unwrap();
    let schema = CounterSchema::read(&db, &i).unwrap();
    let q = CounterSeriesQuery {
        range: TraceTimeRange::event(0, 1000).unwrap(),
        limit: 1,
    };
    let before = schema.series(&db, &i, &q).unwrap();
    b.cancellation.cancel();
    assert_eq!(schema.series(&db, &i, &q), Err(StoreError::Cancelled));
    assert_eq!(series(&conn, &i, 1).unwrap(), before);
    let b = ValidationBudget {
        deadline: Instant::now() - Duration::from_millis(1),
        ..budget()
    };
    assert!(matches!(
        Database::borrow_readonly(&conn, &b),
        Err(StoreError::DeadlineExceeded)
    ));
    for q in [
        CounterSeriesQuery {
            limit: 0,
            ..q.clone()
        },
        CounterSeriesQuery {
            range: TraceTimeRange::event(0, 1001).unwrap(),
            ..q
        },
    ] {
        let b = budget();
        let db = Database::borrow_readonly(&conn, &b).unwrap();
        assert_eq!(schema.series(&db, &i, &q), Err(StoreError::InvalidQuery));
    }
}

#[test]
fn unindexed_series_discovery_does_not_rescan_samples_for_each_empty_filter() {
    let (conn, inspection) = fixture(
        "WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<30000)
         INSERT INTO process_measure SELECT 1001,7,20,0 FROM n;
         WITH RECURSIVE n(i) AS (VALUES(21) UNION ALL SELECT i+1 FROM n WHERE i<120)
         INSERT INTO process_measure_filter SELECT i,'empty',-10,'bytes' FROM n;",
    );
    // Do not let an implicit temporary index conceal the repeated scan. The
    // production query also has to fit when no filter-prefix seek is present.
    conn.pragma_update(None, "automatic_index", false).unwrap();
    let unindexed = series(&conn, &inspection, 2000).unwrap();
    assert_eq!(unindexed.items.len(), 2);
    assert!(!unindexed.truncated);
    conn.pragma_update(None, "query_only", false).unwrap();
    conn.execute_batch("CREATE INDEX filter_seek ON process_measure(filter_id,ts)")
        .unwrap();
    assert_eq!(series(&conn, &inspection, 2000).unwrap(), unindexed);
}
#[test]
fn fresh_inspection_and_query_clamps_remain_separate_machine_observations() {
    let (conn, _) = fixture("INSERT INTO measure VALUES(900,7,10,300);");
    let b = budget();
    let inspection = Database::borrow_writable(&conn, &b)
        .unwrap()
        .inspect()
        .unwrap();
    let page = counters(&conn, &inspection, &query(0, 1000, 20)).unwrap();
    // Actual unchanged Swift CounterOracle controlled/clamped-ts raw page.
    assert_eq!(
        serde_json::to_value(&page.data_quality).unwrap(),
        serde_json::json!({"status":"warnings","warnings":[{"category":"clampedValue","scope":"measure.dur","count":1,"message":null},{"category":"clampedValue","scope":"measure.ts","count":1,"message":null},{"category":"clampedValue","scope":"measure.ts","count":1,"message":null}]})
    );
    assert_eq!(page.items[0].samples[0].timestamp_ns, 0);
    assert!(!page.truncated);
}
#[test]
fn series_counts_missing_references_without_marking_optional_drops_as_truncation() {
    let (conn, i) = fixture("UPDATE process_measure_filter SET ipid=-99,unit=zeroblob(257);");
    let p = counters(&conn, &i, &query(0, 1000, 20)).unwrap();
    assert_eq!(p.items[1].process_key, Some(ProcessKey { ipid: -99 }));
    assert!(p.truncated);
    assert_eq!(
        count(
            &p,
            QualityCategory::ReferentialIntegrity,
            "process_measure_filter.ipid"
        ),
        Some(1)
    );
    let p = series(&conn, &i, 20).unwrap();
    assert!(!p.truncated);
    assert_eq!(
        count(
            &p,
            QualityCategory::ReferentialIntegrity,
            "process_measure_filter.ipid"
        ),
        Some(1)
    );
    assert_eq!(
        count(&p, QualityCategory::DroppedValue, "timeline.counter"),
        Some(1)
    );
}
