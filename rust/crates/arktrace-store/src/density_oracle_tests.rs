//! Actual Swift goldens against bundled SQLite, not reimplemented expectations.
use crate::{
    StoreError, ValidationBudget, counters::CounterSchema, database::Database, density::density,
    frames::FrameSchema,
};
use arktrace_contract::TraceDensityQuery;
use arktrace_platform::CancellationToken;
use rusqlite::Connection;
use serde_json::{Value, json};
use std::time::{Duration, Instant};

#[test]
fn actual_swift_density_results_match_every_controlled_source_bucket_identity_quality_and_error() {
    let input: Value =
        serde_json::from_str(include_str!("../tests/fixtures/density-pages-input.json")).unwrap();
    let expected: Vec<Value> =
        serde_json::from_str(include_str!("../tests/fixtures/swift-density-pages.json")).unwrap();
    assert_eq!(expected.len(), 190);
    let mut checked = 0;
    for fixture in input["fixtures"].as_array().unwrap() {
        let connection = Connection::open_in_memory().unwrap();
        connection
            .execute_batch(input["schemaSQL"].as_str().unwrap())
            .unwrap();
        connection
            .execute_batch(fixture["sql"].as_str().unwrap())
            .unwrap();
        let budget = ValidationBudget {
            maximum_database_bytes: 256 * 1024 * 1024,
            deadline: Instant::now() + Duration::from_secs(60),
            cancellation: CancellationToken::default(),
        };
        let inspection = Database::borrow_writable(&connection, &budget)
            .unwrap()
            .inspect()
            .unwrap();
        let db = Database::borrow_readonly(&connection, &budget).unwrap();
        let counters = CounterSchema::read(&db, &inspection).unwrap();
        let frames = FrameSchema::read(&db).unwrap();
        for case in input["cases"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|v| v["fixture"] == fixture["id"])
        {
            let query: TraceDensityQuery = serde_json::from_value(case["query"].clone()).unwrap();
            let record = expected.iter().find(|v| v["id"] == case["id"]).unwrap();
            assert_eq!(
                serde_json::to_value(&query.source).unwrap(),
                record["source"],
                "{}",
                case["id"]
            );
            match density(&db, &inspection, &counters, frames, &query) {
                Ok(result) => {
                    assert!(record.get("error").is_none(), "{}", case["id"]);
                    assert_eq!(
                        serde_json::to_value(result).unwrap(),
                        record["result"],
                        "{}",
                        case["id"]
                    );
                }
                Err(StoreError::InvalidQuery) => assert_eq!(
                    record["error"],
                    json!({"code":"INVALID_ARGUMENT","stage":"request","details":{}}),
                    "{}",
                    case["id"]
                ),
                Err(e) => panic!("unexpected {e:?}: {}", case["id"]),
            }
            checked += 1;
        }
        let case = input["cases"]
            .as_array()
            .unwrap()
            .iter()
            .find(|v| v["fixture"] == fixture["id"])
            .unwrap();
        let query: TraceDensityQuery = serde_json::from_value(case["query"].clone()).unwrap();
        budget.cancellation.cancel();
        assert_eq!(
            density(&db, &inspection, &counters, frames, &query).unwrap_err(),
            StoreError::Cancelled
        );
    }
    assert_eq!(checked, 190);
}
