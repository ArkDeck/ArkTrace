use arktrace_analysis::*;
use arktrace_contract::*;
use serde::Deserialize;
use serde_json::Value;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Vector {
    name: String,
    request: AnalysisRequest,
    duration_ns: i64,
    cpu_available: bool,
    state_available: bool,
    named_available: bool,
    cpu_rows: Vec<CpuSlice>,
    state_rows: Vec<ThreadStateInterval>,
    named_rows: Vec<NamedDurationEvidence>,
}
fn empty_quality() -> DataQuality {
    DataQuality::machine(QualityStatus::Ok, vec![]).unwrap()
}
fn page<T: Clone>(
    rows: &[T],
    limit: usize,
    available: bool,
    matches: impl Fn(&T) -> bool,
) -> EventPage<T> {
    let selected: Vec<_> = rows.iter().filter(|r| matches(r)).collect();
    EventPage {
        items: if available {
            selected.iter().take(limit).map(|r| (*r).clone()).collect()
        } else {
            vec![]
        },
        truncated: available && selected.len() > limit,
        capability_available: available,
        data_quality: empty_quality(),
    }
}
/// Compare JSON recursively while preserving integer exactness and accepting
/// only the equivalent integer-vs-float spelling for binary64 metric fields.
fn compare(actual: &Value, expected: &Value, path: &str) {
    match (actual, expected) {
        (Value::Array(a), Value::Array(b)) => {
            assert_eq!(a.len(), b.len(), "{path}: array length");
            for (i, (a, b)) in a.iter().zip(b).enumerate() {
                compare(a, b, &format!("{path}[{i}]"));
            }
        }
        (Value::Object(a), Value::Object(b)) => {
            assert_eq!(
                a.keys().collect::<Vec<_>>(),
                b.keys().collect::<Vec<_>>(),
                "{path}: field set"
            );
            for (key, a) in a {
                compare(a, &b[key], &format!("{path}.{key}"));
            }
        }
        (Value::Number(a), Value::Number(b)) => {
            if let (Some(a), Some(b)) = (a.as_i64(), b.as_i64()) {
                assert_eq!(a, b, "{path}: exact integer");
            } else {
                assert_eq!(
                    a.as_f64().unwrap().to_bits(),
                    b.as_f64().unwrap().to_bits(),
                    "{path}: binary64"
                );
            }
        }
        _ => assert_eq!(actual, expected, "{path}"),
    }
}
#[test]
fn replay_23_actual_swift_engine_results_field_by_field() {
    replay(
        include_str!("fixtures/inputs.json"),
        include_str!("fixtures/swift-oracle.json"),
    );
}
#[test]
fn replay_current_swift_canonical_state_and_observed_scheduling_results() {
    replay(
        include_str!("fixtures/mainline-inputs.json"),
        include_str!("fixtures/swift-mainline.json"),
    );
}
fn replay(inputs: &str, outputs: &str) {
    let vectors: Vec<Vector> = serde_json::from_str(inputs).unwrap();
    let oracle: Value = serde_json::from_str(outputs).unwrap();
    let outputs = oracle.as_array().unwrap();
    assert_eq!(vectors.len(), outputs.len());
    for (vector, expected) in vectors.iter().zip(outputs) {
        assert_eq!(expected["name"], vector.name);
        assert!(vector.request.range.end_ns() <= vector.duration_ns);
        let r = &vector.request;
        let cpu_page = |limit| {
            page(&vector.cpu_rows, limit, vector.cpu_available, |c| {
                c.range.intersects(r.range)
            })
        };
        let cpu = cpu_page(r.maximum_cpu_slices);
        let processes = cpu_page(r.maximum_process_slices);
        let threads = cpu_page(r.maximum_thread_slices);
        let scheduling_cpu = cpu_page(r.maximum_scheduling_events);
        let hot_cpu = cpu_page(r.maximum_hot_events);
        let states = page(
            &vector.state_rows,
            r.maximum_state_intervals,
            vector.state_available,
            |s| s.range.intersects(r.range),
        );
        let scheduling_states = page(
            &vector.state_rows,
            r.maximum_scheduling_events,
            vector.state_available,
            |s| {
                s.range.intersects(r.range)
                    && s.normalized_state == Some(TraceThreadState::Runnable)
            },
        );
        let named = page(
            &vector.named_rows,
            r.maximum_hot_events,
            vector.named_available,
            |s| {
                s.range.intersects(r.range)
                    && s.range.duration_ns() >= r.minimum_long_slice_duration_ns
            },
        );
        let trace_quality = empty_quality();
        let result = analyze(
            r,
            AnalysisInput {
                cpu: &cpu,
                processes: &processes,
                threads: &threads,
                states: &states,
                scheduling_cpu: &scheduling_cpu,
                scheduling_states: &scheduling_states,
                runnable_semantics: RunnableSemantics::ProvenNormalizedIntervals,
                hot_cpu: &hot_cpu,
                hot_named: Some(&named),
                named_slices_available: vector.named_available,
                trace_quality: &trace_quality,
            },
            &mut || Ok(()),
        )
        .unwrap();
        let actual = serde_json::to_value(result).unwrap();
        let expected = &expected["result"];
        for field in [
            "range",
            "cpuUtilization",
            "topProcesses",
            "topThreads",
            "threadStateDistribution",
            "schedulingLatency",
            "hotIntervals",
        ] {
            compare(
                &actual[field],
                &expected[field],
                &format!("{}.{}", vector.name, field),
            );
        }
        for section in [
            "cpuUtilization",
            "topProcesses",
            "topThreads",
            "threadStateDistribution",
            "schedulingLatency",
            "hotIntervals",
        ] {
            for fact in ["returnedCount", "matchedCount", "truncated"] {
                compare(
                    &actual["sections"][section][fact],
                    &expected["sections"][section][fact],
                    &format!("{}.sections.{}.{}", vector.name, section, fact),
                );
            }
        }
        // Swift analysis issues are human DTOs; compare only structured facts.
        // Machine conversion itself is exercised through the existing contract
        // API and regressions, not a handwritten replacement Swift formula.
        let facts = |issues: &Value| {
            issues
                .as_array()
                .unwrap()
                .iter()
                .map(|i| {
                    (
                        i["category"].clone(),
                        i["scope"].clone(),
                        i["count"].clone(),
                    )
                })
                .collect::<Vec<_>>()
        };
        assert_eq!(
            facts(&actual["dataQuality"]["warnings"]),
            facts(&expected["dataQuality"]["issues"]),
            "{}.quality facts",
            vector.name
        );
    }
}
