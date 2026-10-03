use super::*;
use serde_json::{Value, json};
use std::{cell::RefCell, collections::VecDeque};

/// Replay only the actual Swift repository's typed source pages. Each call
/// must consume the next exact typed query; excluded domains cannot be queried.
struct Replay(RefCell<VecDeque<Value>>);
impl Replay {
    fn from_record(record: &Value) -> Self {
        Self(RefCell::new(
            record["steps"]
                .as_array()
                .unwrap()
                .iter()
                .cloned()
                .collect(),
        ))
    }
    fn next(&self, kind: &str) -> (Value, Value) {
        let step = self
            .0
            .borrow_mut()
            .pop_front()
            .expect("unexpected source read");
        assert_eq!(step["kind"], kind);
        (
            serde_json::from_str(step["query"].as_str().unwrap()).unwrap(),
            serde_json::from_str(step["result"].as_str().unwrap()).unwrap(),
        )
    }
}
fn clean_quality() -> arktrace_contract::DataQuality {
    arktrace_contract::DataQuality::machine(arktrace_contract::QualityStatus::Ok, Vec::new())
        .unwrap()
}
impl SearchRepository for Replay {
    type Error = ();
    fn duration_ns(&self) -> Result<i64, ()> {
        Ok(self.next("metadata").1["durationNs"].as_i64().unwrap())
    }
    fn processes(&self, q: &ProcessQuery) -> Result<DirectoryPage<TraceProcess>, ()> {
        let (query, mut page) = self.next("processes");
        assert_eq!(serde_json::from_value::<ProcessQuery>(query).unwrap(), *q);
        for item in page["items"].as_array_mut().unwrap() {
            item["key"] = item["key"]["ipid"].clone();
        }
        Ok(DirectoryPage {
            items: serde_json::from_value(page["items"].clone()).unwrap(),
            truncated: page["truncated"].as_bool().unwrap(),
            data_quality_issues: Vec::new(),
        })
    }
    fn threads(&self, q: &ThreadQuery) -> Result<DirectoryPage<TraceThread>, ()> {
        let (query, mut page) = self.next("threads");
        assert_eq!(serde_json::from_value::<ThreadQuery>(query).unwrap(), *q);
        for item in page["items"].as_array_mut().unwrap() {
            item["key"] = item["key"]["itid"].clone();
            item["processKey"] = item["processKey"]
                .get("ipid")
                .cloned()
                .unwrap_or(Value::Null);
        }
        Ok(DirectoryPage {
            items: serde_json::from_value(page["items"].clone()).unwrap(),
            truncated: page["truncated"].as_bool().unwrap(),
            data_quality_issues: Vec::new(),
        })
    }
    fn slices(&self, q: &TraceSliceQuery) -> Result<EventPage<TraceSlice>, ()> {
        let (query, page) = self.next("slices");
        assert_eq!(
            serde_json::from_value::<TraceSliceQuery>(query).unwrap(),
            *q
        );
        Ok(EventPage {
            items: serde_json::from_value(page["items"].clone()).unwrap(),
            truncated: page["truncated"].as_bool().unwrap(),
            capability_available: page["capabilityAvailable"].as_bool().unwrap(),
            data_quality: clean_quality(),
        })
    }
}
fn input() -> Value {
    serde_json::from_str(include_str!(
        "../../../arktrace-store/tests/fixtures/search-pages-input.json"
    ))
    .unwrap()
}
fn records() -> Vec<Value> {
    serde_json::from_str(include_str!(
        "../../../arktrace-store/tests/fixtures/swift-search-pages.json"
    ))
    .unwrap()
}
fn request(case: &Value) -> TraceSearchRequest {
    serde_json::from_value(case["query"].clone()).unwrap()
}

#[test]
fn actual_swift_search_outputs_and_every_typed_source_call_match() {
    let input = input();
    let records = records();
    assert_eq!(input["cases"].as_array().unwrap().len(), 138);
    assert_eq!(records.len(), 138);
    let mut positives = 0;
    for case in input["cases"].as_array().unwrap() {
        let expected = records.iter().find(|v| v["id"] == case["id"]).unwrap();
        let replay = Replay::from_record(expected);
        match search(&replay, &request(case), &mut || Ok(())) {
            Ok(results) => {
                assert_eq!(
                    serde_json::to_value(&results).unwrap(),
                    expected["results"],
                    "{}",
                    case["id"]
                );
                positives += usize::from(!results.items.is_empty());
            }
            Err(SearchError::Analysis(AnalysisError::InvalidBounds)) => {
                assert_eq!(
                    expected["error"],
                    json!({"code":"INVALID_ARGUMENT","stage":"request","details":{}}),
                    "{}",
                    case["id"]
                );
            }
            other => panic!("{}: {other:?}", case["id"]),
        }
        assert!(
            replay.0.borrow().is_empty(),
            "unconsumed queries: {}",
            case["id"]
        );
    }
    assert!(positives >= 30);
}

#[test]
fn cancellation_after_metadata_prevents_all_source_queries() {
    let records = records();
    let replay = Replay::from_record(&records[0]);
    let case = &input()["cases"][0];
    let original = replay.0.borrow().len();
    let mut calls = 0;
    assert_eq!(
        search(&replay, &request(case), &mut || {
            calls += 1;
            if calls == 2 {
                Err(AnalysisError::Cancelled)
            } else {
                Ok(())
            }
        }),
        Err(SearchError::Analysis(AnalysisError::Cancelled))
    );
    assert_eq!(replay.0.borrow().len(), original - 1);
}

#[test]
fn cancellation_during_merge_stops_before_next_query_and_returns_no_partial_result() {
    let records = records();
    let replay = Replay::from_record(&records[0]);
    let case = &input()["cases"][0];
    let mut calls = 0;
    assert_eq!(
        search(&replay, &request(case), &mut || {
            calls += 1;
            if calls == 3 {
                Err(AnalysisError::DeadlineReached)
            } else {
                Ok(())
            }
        }),
        Err(SearchError::Analysis(AnalysisError::DeadlineReached))
    );
    assert_eq!(replay.0.borrow().front().unwrap()["kind"], "threads");
}

#[test]
fn a_repository_cannot_overrun_per_kind_input_budget() {
    let mut records = records();
    let record = &mut records[0];
    let step = &mut record["steps"][1];
    let mut page: Value = serde_json::from_str(step["result"].as_str().unwrap()).unwrap();
    let one = page["items"][0].clone();
    page["items"] = Value::Array(vec![one; 22]);
    step["result"] = json!(serde_json::to_string(&page).unwrap());
    let replay = Replay::from_record(record);
    assert_eq!(
        search(&replay, &request(&input()["cases"][0]), &mut || Ok(())),
        Err(SearchError::Analysis(AnalysisError::InputBudgetExceeded))
    );
    assert_eq!(replay.0.borrow().front().unwrap()["kind"], "threads");
}

#[test]
fn cancellation_inside_final_sort_discards_output() {
    let record = records()
        .into_iter()
        .find(|r| r["id"] == "search-full/search/06")
        .unwrap();
    let replay = Replay::from_record(&record);
    let mut calls = 0;
    let case = input()["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["id"] == record["id"])
        .unwrap()
        .clone();
    let result = search(&replay, &request(&case), &mut || {
        calls += 1;
        if calls == 9 {
            Err(AnalysisError::Cancelled)
        } else {
            Ok(())
        }
    });
    assert_eq!(result, Err(SearchError::Analysis(AnalysisError::Cancelled)));
    assert!(replay.0.borrow().is_empty());
}
