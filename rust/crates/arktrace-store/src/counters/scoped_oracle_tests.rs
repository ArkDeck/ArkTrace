use super::*;
use crate::{ValidationBudget, database::Database};
use arktrace_platform::CancellationToken;
use rusqlite::Connection;
use serde_json::{Value, json};
use std::time::{Duration, Instant};

#[test]
fn physical_family_scope_is_applied_before_sample_limit_without_optional_owners() {
    let input: Value = serde_json::from_str(include_str!(
        "../../../arktrace-viewer/tests/fixtures/scoped-counters-inputs.json"
    ))
    .unwrap();
    let swift: Vec<Value> = serde_json::from_str(include_str!(
        "../../../arktrace-viewer/tests/fixtures/swift-scoped-counters.json"
    ))
    .unwrap();
    let conn = Connection::open_in_memory().unwrap();
    conn.execute_batch(input["sql"].as_str().unwrap()).unwrap();
    let budget = ValidationBudget {
        maximum_database_bytes: 256 * 1024 * 1024,
        deadline: Instant::now() + Duration::from_secs(10),
        cancellation: CancellationToken::default(),
    };
    let db = Database::borrow_readonly(&conn, &budget).unwrap();
    let inspection = db.inspect().unwrap();
    let schema = CounterSchema::read(&db, &inspection).unwrap();
    for (index, scope) in [None, Some(CounterScope::Cpu), Some(CounterScope::Process)]
        .into_iter()
        .enumerate()
    {
        let query = CounterQuery {
            range: TraceTimeRange::query(0, 1000).unwrap(),
            scope,
            filter_id: None,
            cpu: None,
            process_key: None,
            pid: None,
            name: None,
            name_match: arktrace_contract::DirectoryNameMatch::Exact,
            limit: 1,
        };
        let page = schema.counters(&db, &inspection, &query).unwrap();
        let mut expected = swift[index]["result"].clone();
        assert_eq!(
            expected["dataQuality"],
            json!({"issues":[],"warnings":[],"status":"ok"})
        );
        expected["dataQuality"] =
            serde_json::to_value(DataQuality::machine(QualityStatus::Ok, vec![]).unwrap()).unwrap();
        assert_eq!(
            serde_json::to_value(&page).unwrap(),
            expected,
            "{}",
            swift[index]["name"]
        );
        if let Some(scope) = scope {
            assert!(page.items.iter().all(|s| s.scope == scope));
        }
        assert!(page.truncated);
    }
    for (scope, id, vector) in [
        (CounterScope::Cpu, 0, 3),
        (CounterScope::Process, 1, 4),
        (CounterScope::Cpu, 1, 5),
        (CounterScope::Process, 0, 6),
    ] {
        let query = CounterQuery {
            range: TraceTimeRange::query(0, 1000).unwrap(),
            scope: Some(scope),
            filter_id: Some(id),
            cpu: None,
            process_key: None,
            pid: None,
            name: None,
            name_match: arktrace_contract::DirectoryNameMatch::Exact,
            limit: 1,
        };
        let page = schema.counters(&db, &inspection, &query).unwrap();
        let samples = page
            .items
            .iter()
            .flat_map(|s| &s.samples)
            .collect::<Vec<_>>();
        let expected = swift[vector]["result"]["tracks"][0]["primitives"]
            .as_array()
            .unwrap();
        assert_eq!(samples.len(), expected.len());
        for (sample, expected) in samples.iter().zip(expected) {
            assert_eq!(
                serde_json::to_value(sample.key).unwrap(),
                expected["detail"]["_0"]["eventKey"]
            );
            assert_eq!(
                sample.timestamp_ns,
                expected["detail"]["_0"]["range"]["startNs"]
            );
        }
    }
}
