//! Independent Swift repository goldens; SQL inputs are rebuilt with bundled
//! SQLite, so the test exercises schema inspection and actual Rust row mapping.
use crate::{
    StoreError, ValidationBudget, database::Database, events::EventSchema, frames::FrameSchema,
    slices::SliceSchema,
};
use arktrace_contract::{
    CpuSliceQuery, DirectoryNameMatch, PublicError, ThreadStateQuery, TraceFrame, TraceFrameQuery,
    TraceSliceQuery, TraceTimeRange,
};
use arktrace_platform::CancellationToken;
use rusqlite::Connection;
use serde_json::{Value, json};
use std::time::{Duration, Instant};

#[test]
fn actual_swift_event_pages_match_all_controlled_rows_quality_and_closed_errors() {
    let input: Value =
        serde_json::from_str(include_str!("../tests/fixtures/event-pages-input.json")).unwrap();
    let expected: Vec<Value> =
        serde_json::from_str(include_str!("../tests/fixtures/swift-event-pages.json")).unwrap();
    let cases = input["cases"].as_array().unwrap();
    assert_eq!(cases.len(), 62);
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
        let q = &case["query"];
        let range: TraceTimeRange = serde_json::from_value(q["range"].clone()).unwrap();
        let process_key = q["processKey"].as_i64();
        let limit = q["limit"].as_u64().unwrap() as usize;
        let mut jank = None;
        let result =
            match case["view"].as_str().unwrap() {
                "frames" => FrameSchema::read(&db)
                    .unwrap()
                    .frames(
                        &db,
                        &inspection,
                        &TraceFrameQuery {
                            range,
                            process_key,
                            limit,
                        },
                    )
                    .map(|p| {
                        jank = Some(Value::Array(p.items.iter().map(|f: &TraceFrame| json!({
                        "isJank": f.is_jank(), "jankTag": TraceFrame::jank_tag(f.flag)
                    })).collect()));
                        serde_json::to_value(p).unwrap()
                    }),
                "cpuSlices" => EventSchema::read(&db)
                    .unwrap()
                    .cpu_slices(
                        &db,
                        &inspection,
                        &CpuSliceQuery {
                            range,
                            process_key,
                            limit,
                            cpu: None,
                            pid: None,
                            thread_key: None,
                            tid: None,
                        },
                    )
                    .map(|p| serde_json::to_value(p).unwrap()),
                "threadStates" => EventSchema::read(&db)
                    .unwrap()
                    .thread_states(
                        &db,
                        &inspection,
                        &ThreadStateQuery {
                            range,
                            process_key,
                            limit,
                            cpu: None,
                            pid: None,
                            thread_key: None,
                            tid: None,
                            raw_state: None,
                            state: None,
                        },
                    )
                    .map(|p| serde_json::to_value(p).unwrap()),
                "slices" => SliceSchema::read(&db)
                    .unwrap()
                    .slices(
                        &db,
                        &inspection,
                        &TraceSliceQuery {
                            range,
                            process_key,
                            limit,
                            event_key: None,
                            pid: None,
                            thread_key: None,
                            tid: None,
                            name: None,
                            name_match: DirectoryNameMatch::Exact,
                            minimum_duration_ns: None,
                            depth: None,
                            includes_argument_set: false,
                        },
                    )
                    .map(|p| serde_json::to_value(p).unwrap()),
                _ => panic!("unexpected view"),
            };
        let expected = expected.iter().find(|v| v["id"] == case["id"]).unwrap();
        match result {
            Ok(page) => {
                assert!(expected.get("error").is_none(), "{}", case["id"]);
                assert_eq!(page, expected["page"], "{}", case["id"]);
                if let Some(jank) = jank {
                    assert_eq!(jank, expected["jank"], "{}", case["id"]);
                }
            }
            Err(error) => {
                let public = match error {
                    StoreError::InvalidFrameIdentity => PublicError::invalid_frame_identity(),
                    StoreError::InvalidQuery => PublicError::new(
                        arktrace_contract::Code::InvalidArgument,
                        arktrace_contract::Stage::Request,
                    ),
                    _ => panic!("unexpected error {:?}: {}", error, case["id"]),
                };
                let value = serde_json::to_value(public).unwrap();
                assert_eq!(
                    json!({"code":value["code"], "stage":value["stage"], "details":value["details"]}),
                    expected["error"],
                    "{}",
                    case["id"]
                );
            }
        }
    }
}
