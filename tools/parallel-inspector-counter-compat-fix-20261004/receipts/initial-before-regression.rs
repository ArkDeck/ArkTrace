use arktrace_contract::*;
use arktrace_viewer::*;
use serde_json::{Value, json};
const CANONICAL: &str = r###"[{"id":"legacy-process-measure-single","queryRange":{"endNs":200,"startNs":100},"series":[{"cpu":null,"filterID":20,"name":"legacy","pid":700,"processKey":{"ipid":1},"processName":"进程🚀","samples":[{"durationNs":20,"key":{"rowID":1,"table":"measure"},"timestampNs":100,"value":999}],"scope":"process","unit":null}],"swiftFacts":[{"category":"process","cpu":null,"isInstant":false,"isOpenEnded":false,"key":{"rowID":1,"table":"measure"},"kind":"counter","name":"legacy","pid":700,"priority":null,"processKey":{"ipid":1},"processName":"进程🚀","range":{"endNs":120,"startNs":100},"semanticDurationNs":20,"state":null,"threadKey":null,"threadName":null,"tid":null,"unit":null,"value":999}],"producerInput":"minimal-valid-rust-output.json","canonicalInput":"minimal-valid-swift-output.json"},{"id":"cpu-counter-predecessor-nil-duration","queryRange":{"endNs":200,"startNs":100},"series":[{"cpu":0,"filterID":10,"name":"频率🚀","pid":null,"processKey":null,"processName":null,"samples":[{"durationNs":200,"key":{"rowID":10,"table":"measure"},"timestampNs":0,"value":7},{"durationNs":0,"key":{"rowID":11,"table":"measure"},"timestampNs":140,"value":8},{"durationNs":null,"key":{"rowID":12,"table":"measure"},"timestampNs":150,"value":9}],"scope":"cpu","unit":"MHz"}],"swiftFacts":[{"category":"cpu","cpu":0,"isInstant":false,"isOpenEnded":false,"key":{"rowID":10,"table":"measure"},"kind":"counter","name":"频率🚀","pid":null,"priority":null,"processKey":null,"processName":null,"range":{"endNs":200,"startNs":0},"semanticDurationNs":200,"state":null,"threadKey":null,"threadName":null,"tid":null,"unit":"MHz","value":7},{"category":"cpu","cpu":0,"isInstant":true,"isOpenEnded":false,"key":{"rowID":11,"table":"measure"},"kind":"counter","name":"频率🚀","pid":null,"priority":null,"processKey":null,"processName":null,"range":{"endNs":140,"startNs":140},"semanticDurationNs":0,"state":null,"threadKey":null,"threadName":null,"tid":null,"unit":"MHz","value":8},{"category":"cpu","cpu":0,"isInstant":false,"isOpenEnded":true,"key":{"rowID":12,"table":"measure"},"kind":"counter","name":"频率🚀","pid":null,"priority":null,"processKey":null,"processName":null,"range":{"endNs":200,"startNs":150},"semanticDurationNs":null,"state":null,"threadKey":null,"threadName":null,"tid":null,"unit":"MHz","value":9}],"producerInput":"bounded-sealed-rust-output.json","canonicalInput":"bounded-swift-output.json"},{"id":"cpu-counter-left-bound-instant","queryRange":{"endNs":150,"startNs":140},"series":[{"cpu":0,"filterID":10,"name":"频率🚀","pid":null,"processKey":null,"processName":null,"samples":[{"durationNs":200,"key":{"rowID":10,"table":"measure"},"timestampNs":0,"value":7},{"durationNs":0,"key":{"rowID":11,"table":"measure"},"timestampNs":140,"value":8}],"scope":"cpu","unit":"MHz"}],"swiftFacts":[{"category":"cpu","cpu":0,"isInstant":false,"isOpenEnded":false,"key":{"rowID":10,"table":"measure"},"kind":"counter","name":"频率🚀","pid":null,"priority":null,"processKey":null,"processName":null,"range":{"endNs":200,"startNs":0},"semanticDurationNs":200,"state":null,"threadKey":null,"threadName":null,"tid":null,"unit":"MHz","value":7},{"category":"cpu","cpu":0,"isInstant":true,"isOpenEnded":false,"key":{"rowID":11,"table":"measure"},"kind":"counter","name":"频率🚀","pid":null,"priority":null,"processKey":null,"processName":null,"range":{"endNs":140,"startNs":140},"semanticDurationNs":0,"state":null,"threadKey":null,"threadName":null,"tid":null,"unit":"MHz","value":8}],"producerInput":"bounded-sealed-rust-output.json","canonicalInput":"bounded-swift-output.json"},{"id":"native-process-counter-nil-duration","queryRange":{"endNs":200,"startNs":100},"series":[{"cpu":null,"filterID":20,"name":"legacy","pid":700,"processKey":{"ipid":1},"processName":"进程🚀","samples":[{"durationNs":20,"key":{"rowID":1,"table":"process_measure"},"timestampNs":100,"value":99},{"durationNs":null,"key":{"rowID":2,"table":"process_measure"},"timestampNs":150,"value":100}],"scope":"process","unit":null}],"swiftFacts":[{"category":"process","cpu":null,"isInstant":false,"isOpenEnded":false,"key":{"rowID":1,"table":"process_measure"},"kind":"counter","name":"legacy","pid":700,"priority":null,"processKey":{"ipid":1},"processName":"进程🚀","range":{"endNs":120,"startNs":100},"semanticDurationNs":20,"state":null,"threadKey":null,"threadName":null,"tid":null,"unit":null,"value":99},{"category":"process","cpu":null,"isInstant":false,"isOpenEnded":true,"key":{"rowID":2,"table":"process_measure"},"kind":"counter","name":"legacy","pid":700,"priority":null,"processKey":{"ipid":1},"processName":"进程🚀","range":{"endNs":200,"startNs":150},"semanticDurationNs":null,"state":null,"threadKey":null,"threadName":null,"tid":null,"unit":null,"value":100}],"producerInput":"bounded-sealed-rust-output.json","canonicalInput":"bounded-swift-output.json"},{"id":"native-process-counter-nullable-metadata","queryRange":{"endNs":200,"startNs":100},"series":[{"cpu":null,"filterID":21,"name":"process2","pid":700,"processKey":{"ipid":2},"processName":null,"samples":[{"durationNs":20,"key":{"rowID":4,"table":"process_measure"},"timestampNs":100,"value":99}],"scope":"process","unit":""}],"swiftFacts":[{"category":"process","cpu":null,"isInstant":false,"isOpenEnded":false,"key":{"rowID":4,"table":"process_measure"},"kind":"counter","name":"process2","pid":700,"priority":null,"processKey":{"ipid":2},"processName":null,"range":{"endNs":120,"startNs":100},"semanticDurationNs":20,"state":null,"threadKey":null,"threadName":null,"tid":null,"unit":"","value":99}],"producerInput":"bounded-sealed-rust-output.json","canonicalInput":"bounded-swift-output.json"},{"id":"merged-physical-table-rowid-collision","queryRange":{"endNs":200,"startNs":100},"series":[{"cpu":null,"filterID":20,"name":"legacy","pid":700,"processKey":{"ipid":1},"processName":"进程🚀","samples":[{"durationNs":20,"key":{"rowID":1,"table":"measure"},"timestampNs":100,"value":999},{"durationNs":20,"key":{"rowID":1,"table":"process_measure"},"timestampNs":100,"value":99}],"scope":"process","unit":null}],"swiftFacts":[{"category":"process","cpu":null,"isInstant":false,"isOpenEnded":false,"key":{"rowID":1,"table":"measure"},"kind":"counter","name":"legacy","pid":700,"priority":null,"processKey":{"ipid":1},"processName":"进程🚀","range":{"endNs":120,"startNs":100},"semanticDurationNs":20,"state":null,"threadKey":null,"threadName":null,"tid":null,"unit":null,"value":999},{"category":"process","cpu":null,"isInstant":false,"isOpenEnded":false,"key":{"rowID":1,"table":"process_measure"},"kind":"counter","name":"legacy","pid":700,"priority":null,"processKey":{"ipid":1},"processName":"进程🚀","range":{"endNs":120,"startNs":100},"semanticDurationNs":20,"state":null,"threadKey":null,"threadName":null,"tid":null,"unit":null,"value":99}],"producerInput":"bounded-sealed-rust-output.json","canonicalInput":"bounded-swift-output.json"}]
"###;
fn observe(batch: &InspectorProjectionBatch) -> Value {
    Value::Array(batch.records().iter().map(|record| {
        let f=record.as_ref().unwrap();
        json!({"key":f.key(),"kind":f.kind(),"name":batch.text(f.name()),"range":f.range(),"semanticDurationNs":f.semantic_duration_ns(),"isOpenEnded":f.is_open_ended(),"isInstant":f.is_instant(),"processKey":f.process_key(),"threadKey":f.thread_key(),"pid":f.pid(),"tid":f.tid(),"cpu":f.cpu(),"processName":batch.text(f.process_name()),"threadName":batch.text(f.thread_name()),"category":batch.text(f.category()),"state":batch.text(f.state()),"value":f.value(),"unit":batch.text(f.unit()),"priority":f.priority()})
    }).collect())
}
fn verify_case(case: &Value) {
    let query_range: TraceTimeRange = serde_json::from_value(case["queryRange"].clone()).unwrap();
    let rows: Vec<CounterSeries> = serde_json::from_value(case["series"].clone()).unwrap();
    let descriptors: Vec<_> = rows
        .iter()
        .map(|r| CounterSeriesDescriptor {
            filter_id: r.filter_id,
            name: r.name.clone(),
            scope: r.scope,
            cpu: r.cpu,
            process_key: r.process_key,
            pid: r.pid,
            process_name: r.process_name.clone(),
            unit: r.unit.clone(),
        })
        .collect();
    let inputs: Vec<_> = rows
        .iter()
        .zip(&descriptors)
        .flat_map(|(row, series)| {
            row.samples
                .iter()
                .map(move |sample| InspectorProjectionInput::Counter {
                    series,
                    sample,
                    query_range,
                })
        })
        .collect();
    let result = project_inspectors(1, &inputs, Default::default(), &mut || Ok(()));
    assert!(
        result.is_ok(),
        "{} legitimate repository DTO rejected: {:?}",
        case["id"],
        result.as_ref().err()
    );
    let batch = result.unwrap();
    let actual = observe(&batch);
    assert_eq!(
        actual, case["swiftFacts"],
        "{} all 19 actual Swift facts",
        case["id"]
    );
    println!("canonical {} {}", case["id"], actual);
}
fn cases() -> Vec<Value> {
    serde_json::from_str(CANONICAL).unwrap()
}
#[test]
fn inherited_legacy_process_measure_matches_actual_swift_facts() {
    verify_case(
        &cases()
            .into_iter()
            .find(|c| c["id"] == "legacy-process-measure-single")
            .unwrap(),
    );
}
#[test]
fn inherited_merged_same_rowid_keeps_both_physical_tables_and_values() {
    let case = cases()
        .into_iter()
        .find(|c| c["id"] == "merged-physical-table-rowid-collision")
        .unwrap();
    assert_eq!(
        case["swiftFacts"][0]["key"]["rowID"],
        case["swiftFacts"][1]["key"]["rowID"]
    );
    assert_ne!(
        case["swiftFacts"][0]["key"]["table"],
        case["swiftFacts"][1]["key"]["table"]
    );
    assert_ne!(
        case["swiftFacts"][0]["value"],
        case["swiftFacts"][1]["value"]
    );
    verify_case(&case);
}
#[test]
fn inherited_cpu_temporal_and_native_process_facts_remain_exact() {
    for case in cases() {
        if case["id"] != "legacy-process-measure-single"
            && case["id"] != "merged-physical-table-rowid-collision"
        {
            verify_case(&case);
        }
    }
}
#[test]
fn every_scope_table_pair_accepts_only_actual_schema_sources_and_preserves_key() {
    let row: CounterSeries = serde_json::from_value(cases()[0]["series"][0].clone()).unwrap();
    let mut series = CounterSeriesDescriptor {
        filter_id: row.filter_id,
        name: row.name,
        scope: row.scope,
        cpu: row.cpu,
        process_key: row.process_key,
        pid: row.pid,
        process_name: row.process_name,
        unit: row.unit,
    };
    let mut sample = row.samples[0].clone();
    let tables = [
        EventTable::SchedSlice,
        EventTable::ThreadState,
        EventTable::Callstack,
        EventTable::Measure,
        EventTable::ProcessMeasure,
        EventTable::FrameSlice,
    ];
    for scope in [CounterScope::Cpu, CounterScope::Process] {
        series.scope = scope;
        for table in tables {
            sample.key.table = table;
            let actual = project_inspectors(
                1,
                &[InspectorProjectionInput::Counter {
                    series: &series,
                    sample: &sample,
                    query_range: TraceTimeRange::query(100, 200).unwrap(),
                }],
                Default::default(),
                &mut || Ok(()),
            );
            let allowed = table == EventTable::Measure
                || (scope == CounterScope::Process && table == EventTable::ProcessMeasure);
            println!("guard {scope:?} {table:?} {:?}", actual.as_ref().err());
            if allowed {
                assert_eq!(actual.unwrap().records()[0].unwrap().key(), sample.key);
            } else {
                assert_eq!(
                    actual.unwrap_err(),
                    InspectorProjectionError::InvalidEventKey
                );
            }
        }
    }
}
