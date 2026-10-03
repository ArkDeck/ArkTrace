//! Independent Swift repository goldens; SQL inputs are rebuilt with bundled
//! SQLite, so the test exercises schema inspection and actual Rust row mapping.
use crate::{
    StoreError, ValidationBudget, arguments::ArgumentSchema, database::Database,
    slices::SliceSchema,
};
use arktrace_contract::{DirectoryNameMatch, PublicError, TraceArgumentQuery, TraceSliceQuery};
use arktrace_platform::CancellationToken;
use rusqlite::Connection;
use serde_json::{Value, json};
use std::time::{Duration, Instant};

#[test]
fn actual_swift_argument_pages_match_all_controlled_rows_handles_and_closed_errors() {
    let input: Value =
        serde_json::from_str(include_str!("../tests/fixtures/argument-pages-input.json")).unwrap();
    let expected: Vec<Value> =
        serde_json::from_str(include_str!("../tests/fixtures/swift-argument-pages.json")).unwrap();
    let cases = input["cases"].as_array().unwrap();
    assert_eq!(cases.len(), 84);
    assert_eq!(expected.len(), cases.len());
    for case in cases {
        let fixture = input["fixtures"]
            .as_array()
            .unwrap()
            .iter()
            .find(|v| v["id"] == case["fixture"])
            .unwrap();
        let connection = Connection::open_in_memory().unwrap();
        connection
            .execute_batch(input["schemaSQL"].as_str().unwrap())
            .unwrap();
        connection
            .execute_batch(fixture["sql"].as_str().unwrap())
            .unwrap();
        let budget = ValidationBudget {
            maximum_database_bytes: 256 * 1024 * 1024,
            deadline: Instant::now() + Duration::from_secs(10),
            cancellation: CancellationToken::default(),
        };
        let inspection = Database::borrow_writable(&connection, &budget)
            .unwrap()
            .inspect()
            .unwrap();
        let db = Database::borrow_readonly(&connection, &budget).unwrap();
        let q: TraceArgumentQuery = serde_json::from_value(case["query"].clone()).unwrap();
        let expected = expected.iter().find(|v| v["id"] == case["id"]).unwrap();
        if let Some(lookup) = case["lookup"].as_object() {
            let query = TraceSliceQuery {
                range: serde_json::from_value(lookup["range"].clone()).unwrap(),
                event_key: Some(serde_json::from_value(lookup["eventKey"].clone()).unwrap()),
                process_key: None,
                pid: None,
                thread_key: None,
                tid: None,
                name: None,
                name_match: DirectoryNameMatch::Exact,
                minimum_duration_ns: None,
                depth: None,
                includes_argument_set: false,
                limit: 1,
            };
            let plain = SliceSchema::read(&db)
                .unwrap()
                .slices(&db, &inspection, &query)
                .unwrap();
            let selected = SliceSchema::read(&db)
                .unwrap()
                .slices(
                    &db,
                    &inspection,
                    &TraceSliceQuery {
                        includes_argument_set: true,
                        ..query
                    },
                )
                .unwrap();
            assert_eq!(
                serde_json::to_value(plain.items.iter().map(|v| v.arg_set_id).collect::<Vec<_>>())
                    .unwrap(),
                expected["unrequestedHandles"],
                "{}",
                case["id"]
            );
            assert_eq!(
                serde_json::to_value(
                    selected
                        .items
                        .iter()
                        .map(|v| v.arg_set_id)
                        .collect::<Vec<_>>()
                )
                .unwrap(),
                expected["requestedHandles"],
                "{}",
                case["id"]
            );
            assert_eq!(selected.items[0].arg_set_id, Some(q.arg_set_id));
        }
        match ArgumentSchema::read(&db).unwrap().arguments(&db, &q) {
            Ok(page) => {
                assert!(expected.get("error").is_none(), "{}", case["id"]);
                assert_eq!(
                    serde_json::to_value(page).unwrap(),
                    expected["page"],
                    "{}",
                    case["id"]
                );
            }
            Err(StoreError::InvalidQuery) => {
                let value = serde_json::to_value(PublicError::new(
                    arktrace_contract::Code::InvalidArgument,
                    arktrace_contract::Stage::Request,
                ))
                .unwrap();
                assert_eq!(
                    json!({"code":value["code"],"stage":value["stage"],"details":value["details"]}),
                    expected["error"],
                    "{}",
                    case["id"]
                );
            }
            Err(e) => panic!("unexpected {:?}: {}", e, case["id"]),
        }
    }
}
