#[allow(dead_code)]
mod common;
use arktrace_contract::*;
use arktrace_viewer::*;
use serde_json::{Value, json};
fn observe(batch: &InspectorProjectionBatch) -> Value {
    let facts:Vec<_>=batch.records().iter().map(|record|match record {
        None=>Value::Null,
        Some(f)=>json!({"key":f.key(),"kind":f.kind(),"name":batch.text(f.name()),"range":f.range(),"semanticDurationNs":f.semantic_duration_ns(),"isOpenEnded":f.is_open_ended(),"isInstant":f.is_instant(),"processKey":f.process_key(),"threadKey":f.thread_key(),"pid":f.pid(),"tid":f.tid(),"cpu":f.cpu(),"processName":batch.text(f.process_name()),"threadName":batch.text(f.thread_name()),"category":batch.text(f.category()),"state":batch.text(f.state()),"value":f.value(),"unit":batch.text(f.unit()),"priority":f.priority()})
    }).collect();
    json!(facts)
}
#[test]
fn actual_swift_loader_inspector_all_fields_match_exactly() {
    let input: Value =
        serde_json::from_str(include_str!("fixtures/inspector-projection-inputs.json")).unwrap();
    let expected: Value =
        serde_json::from_str(include_str!("fixtures/inspector-projection-swift.json")).unwrap();
    let mut cases = Vec::new();
    assert_eq!(input["cases"].as_array().unwrap().len(), 362);
    for case in input["cases"].as_array().unwrap() {
        let cpu: Vec<CpuSlice>;
        let states: Vec<ThreadStateInterval>;
        let named: Vec<TraceSlice>;
        let frames: Vec<TraceFrame>;
        let samples: Vec<CounterSample>;
        let series: CounterSeriesDescriptor;
        let inputs: Vec<_> = match case["kind"].as_str().unwrap() {
            "cpuSlice" => {
                cpu = serde_json::from_value(case["events"].clone()).unwrap();
                cpu.iter().map(InspectorProjectionInput::CpuSlice).collect()
            }
            "threadState" => {
                states = serde_json::from_value(case["events"].clone()).unwrap();
                states
                    .iter()
                    .map(InspectorProjectionInput::ThreadState)
                    .collect()
            }
            "namedSlice" => {
                named = serde_json::from_value(case["events"].clone()).unwrap();
                named
                    .iter()
                    .map(InspectorProjectionInput::NamedSlice)
                    .collect()
            }
            "frame" => {
                frames = serde_json::from_value(case["events"].clone()).unwrap();
                frames.iter().map(InspectorProjectionInput::Frame).collect()
            }
            "counter" => {
                samples = serde_json::from_value(case["events"].clone()).unwrap();
                series = serde_json::from_value(case["series"].clone()).unwrap();
                let query_range = serde_json::from_value(case["queryRange"].clone()).unwrap();
                samples
                    .iter()
                    .map(|sample| InspectorProjectionInput::Counter {
                        series: &series,
                        sample,
                        query_range,
                    })
                    .collect()
            }
            "densityBand" => vec![InspectorProjectionInput::DensityBand],
            other => panic!("unexpected input domain {other}"),
        };
        let batch = project_inspectors(
            1,
            &inputs,
            InspectorProjectionBudget::default(),
            &mut || Ok(()),
        )
        .unwrap();
        assert_eq!(batch.api_version(), INSPECTOR_PROJECTION_API_VERSION);
        assert_eq!(batch.records().len(), inputs.len());
        assert!(batch.retained_bytes() <= u64::from(MAXIMUM_INSPECTOR_RETAINED_BYTES));
        cases.push(json!({"id":case["id"],"facts":observe(&batch)}));
    }
    common::compare(
        &json!({"schemaVersion":1,"cases":cases}),
        &expected,
        "actual Swift loader full Inspector",
    );
}
