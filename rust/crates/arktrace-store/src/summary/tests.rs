use super::*;
use crate::ValidationBudget;
use arktrace_platform::CancellationToken;
use rusqlite::Connection;
use serde_json::Value;
use std::time::{Duration, Instant};

fn budget() -> ValidationBudget {
    ValidationBudget {
        maximum_database_bytes: 256 * 1024 * 1024,
        deadline: Instant::now() + Duration::from_secs(10),
        cancellation: CancellationToken::default(),
    }
}
fn query() -> TraceSummaryQuery {
    TraceSummaryQuery {
        range: None,
        maximum_rows_per_section: 100_000,
        maximum_events_per_section: 100_000,
    }
}
fn connection(sql: &str) -> Connection {
    let conn = Connection::open_in_memory().unwrap();
    conn.execute_batch(sql).unwrap();
    conn
}
const TEMPORAL: &str = include_str!("../../tests/fixtures/summary-temporal.sql");
const EMPTY: &str = include_str!("../../tests/fixtures/summary-empty.sql");

#[test]
fn independent_original_swift_summary_counts_and_ordered_quality_match() {
    let golden: Value = serde_json::from_str(include_str!(
        "../../tests/fixtures/swift-summary-facts.json"
    ))
    .unwrap();
    let mut matched = 0;
    for record in golden["records"].as_array().unwrap() {
        let Some(facts) = record.get("facts") else {
            continue;
        };
        let fixture = record["request"]["fixture"].as_str().unwrap();
        let sql = match fixture {
            "temporal" => TEMPORAL,
            "empty-absent" => EMPTY,
            _ => continue,
        };
        let conn = connection(sql);
        let budget = budget();
        let inspection = Database::borrow_writable(&conn, &budget)
            .unwrap()
            .inspect()
            .unwrap();
        let db = Database::borrow_readonly(&conn, &budget).unwrap();
        let mut request = record["request"].clone();
        let map = request.as_object_mut().unwrap();
        map.retain(|key, _| {
            ["range", "maximumRowsPerSection", "maximumEventsPerSection"].contains(&key.as_str())
        });
        let request: TraceSummaryQuery = serde_json::from_value(request).unwrap();
        let actual = SummarySchema::read(&db, &inspection)
            .unwrap()
            .facts(
                &db,
                &inspection,
                &CounterSchema::read(&db, &inspection).unwrap(),
                &request,
            )
            .unwrap();
        let mut expected = facts.clone();
        let map = expected.as_object_mut().unwrap();
        map.remove("warnings");
        let mut issues = map.remove("qualityIssues").unwrap();
        for issue in issues.as_array_mut().unwrap() {
            issue["message"] = Value::Null;
        }
        map.insert("dataQualityIssues".into(), issues);
        assert_eq!(
            serde_json::to_value(actual).unwrap(),
            expected,
            "{}",
            record["id"]
        );
        matched += 1;
    }
    assert_eq!(matched, 5);
}

#[test]
fn vm_budget_interrupts_sql_and_short_statements_share_credit_without_poisoning_connection() {
    let conn = connection(EMPTY);
    let budget = budget();
    let db = Database::borrow_readonly(&conn, &budget).unwrap();
    let bounded = db.summary_request(50).unwrap();
    let expensive = "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10000) SELECT COUNT(*) FROM n";
    assert_eq!(
        bounded.query(expensive, [], 1, DEFAULT_VM_BUDGET, |r| integer(r, 0)),
        Err(StoreError::VmBudgetExceeded)
    );
    assert_eq!(
        db.query("SELECT 7", [], 1, DEFAULT_VM_BUDGET, |r| integer(r, 0))
            .unwrap(),
        [7]
    );
    let bounded = db.summary_request(12).unwrap();
    bounded
        .query("SELECT 1", [], 1, DEFAULT_VM_BUDGET, |r| integer(r, 0))
        .unwrap();
    bounded
        .query("SELECT 2", [], 1, DEFAULT_VM_BUDGET, |r| integer(r, 0))
        .unwrap();
    assert_eq!(
        bounded.query("SELECT 3", [], 1, DEFAULT_VM_BUDGET, |r| integer(r, 0)),
        Err(StoreError::VmBudgetExceeded)
    );
    assert_eq!(
        db.query("SELECT 9", [], 1, DEFAULT_VM_BUDGET, |r| integer(r, 0))
            .unwrap(),
        [9]
    );
}

#[test]
fn stat_preserves_raw_utf8_source_identity_and_rejects_overflow_without_partial_result() {
    let conn = connection(TEMPORAL);
    conn.execute_batch("DELETE FROM stat; INSERT INTO stat VALUES('a','received',1,'info','é'); INSERT INTO stat VALUES('a','received',2,'info','é'); INSERT INTO stat VALUES('a','received',3,'info',CAST(x'610062' AS TEXT)); INSERT INTO stat VALUES('a','received',4,'info',CAST(x'ff' AS TEXT));").unwrap();
    let budget = budget();
    let inspection = Database::borrow_writable(&conn, &budget)
        .unwrap()
        .inspect()
        .unwrap();
    let db = Database::borrow_readonly(&conn, &budget).unwrap();
    let schema = SummarySchema::read(&db, &inspection).unwrap();
    let counters = CounterSchema::read(&db, &inspection).unwrap();
    let facts = schema.facts(&db, &inspection, &counters, &query()).unwrap();
    let sources = facts.event_count_by_source.unwrap();
    assert!(sources.truncated);
    assert_eq!(
        sources
            .items
            .iter()
            .map(|v| (v.source.as_str(), v.count))
            .collect::<Vec<_>>(),
        [("a\0b", 3), ("é", 2), ("é", 1)]
    );
    assert_eq!(
        facts.data_quality_issues.last().unwrap().scope.as_deref(),
        Some("stat.source")
    );
    drop(db);
    Database::borrow_writable(&conn, &budget).unwrap();
    conn.execute_batch("DELETE FROM stat; INSERT INTO stat VALUES('a','received',9223372036854775807,'info','trace'); INSERT INTO stat VALUES('b','received',1,'info','trace');").unwrap();
    let db = Database::borrow_readonly(&conn, &budget).unwrap();
    assert_eq!(
        schema.facts(&db, &inspection, &counters, &query()),
        Err(StoreError::SummaryQueryFailed)
    );
    assert_eq!(
        db.query("SELECT 1", [], 1, DEFAULT_VM_BUDGET, |r| integer(r, 0))
            .unwrap(),
        [1]
    );
}

#[test]
fn invalid_query_deadline_and_cancellation_leave_next_summary_usable() {
    let conn = connection(TEMPORAL);
    let good = budget();
    let inspection = Database::borrow_writable(&conn, &good)
        .unwrap()
        .inspect()
        .unwrap();
    let db = Database::borrow_readonly(&conn, &good).unwrap();
    let schema = SummarySchema::read(&db, &inspection).unwrap();
    let counters = CounterSchema::read(&db, &inspection).unwrap();
    for request in [
        TraceSummaryQuery {
            maximum_rows_per_section: 0,
            ..query()
        },
        TraceSummaryQuery {
            range: Some(arktrace_contract::TraceTimeRange::query(0, 1001).unwrap()),
            ..query()
        },
    ] {
        assert_eq!(
            schema.facts(&db, &inspection, &counters, &request),
            Err(StoreError::InvalidSummaryQuery)
        );
    }
    drop(db);
    let cancelled = budget();
    let db = Database::borrow_readonly(&conn, &cancelled).unwrap();
    cancelled.cancellation.cancel();
    assert_eq!(
        schema.facts(&db, &inspection, &counters, &query()),
        Err(StoreError::Cancelled)
    );
    drop(db);
    let mut expired = budget();
    let db = Database::borrow_readonly(&conn, &expired).unwrap();
    // Do not mutate a borrowed deadline; a fresh expired admission is rejected.
    drop(db);
    expired.deadline = Instant::now() - Duration::from_secs(1);
    assert!(matches!(
        Database::borrow_readonly(&conn, &expired),
        Err(StoreError::DeadlineExceeded)
    ));
    let db = Database::borrow_readonly(&conn, &good).unwrap();
    assert_eq!(
        schema
            .facts(&db, &inspection, &counters, &query())
            .unwrap()
            .cpu_count
            .unwrap()
            .value,
        5
    );
}

#[test]
fn without_rowid_and_shadowed_aliases_sample_physical_storage_before_lifecycle_filter() {
    for replacement in [
        "CREATE TABLE process(ipid INTEGER PRIMARY KEY DESC,pid INTEGER,name TEXT,start_ts INTEGER,end_ts INTEGER) WITHOUT ROWID",
        "CREATE TABLE process(ipid INTEGER,pid INTEGER,name TEXT,start_ts INTEGER,end_ts INTEGER,rowid INTEGER,_rowid_ INTEGER,oid INTEGER)",
    ] {
        let conn = connection(TEMPORAL);
        conn.execute_batch(&format!("DROP TABLE process;{replacement};INSERT INTO process(ipid,pid,name,start_ts,end_ts) VALUES(1,1,'out',1500,1900),(2,2,'in',1200,1300);")).unwrap();
        let budget = budget();
        // This checks the sampler against existing admitted inspection. Required
        // relationships are not weakened to manufacture an alternate Ready DB.
        let baseline = connection(TEMPORAL);
        let inspection = Database::borrow_writable(&baseline, &budget)
            .unwrap()
            .inspect()
            .unwrap();
        let db = Database::borrow_readonly(&conn, &budget).unwrap();
        let schema = SummarySchema::read(&db, &inspection).unwrap();
        let mut issues = Vec::new();
        let count = schema
            .directory(
                &db,
                "process",
                "ipid",
                Window {
                    start: 1200,
                    end: 1400,
                    final_timestamp: false,
                },
                1,
                &mut issues,
            )
            .unwrap();
        assert!(count.truncated);
        assert_eq!(
            count.value,
            if replacement.contains("WITHOUT ROWID") {
                1
            } else {
                0
            }
        );
        assert_eq!(issues[0].category, QualityCategory::ProbeTruncated);
    }
}
