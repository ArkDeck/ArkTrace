#[allow(dead_code)]
mod common;
use arktrace_contract::*;
use arktrace_viewer::*;
use serde_json::{Value, json};

fn page<T>(item: T) -> EventPage<T> {
    EventPage {
        items: vec![item],
        truncated: false,
        capability_available: true,
        data_quality: common::quality(),
    }
}
fn wire(case: &Value, event: &Value) -> HotSnapshot {
    let range: TraceTimeRange = serde_json::from_value(case["queryRange"].clone()).unwrap();
    let (source, raw) = match case["kind"].as_str().unwrap() {
        "cpuSlice" => {
            let e: CpuSlice = serde_json::from_value(event.clone()).unwrap();
            (
                TraceDensitySource::Cpu { cpu: e.cpu },
                RepositoryDetailPage::Cpu(page(e)),
            )
        }
        "threadState" => {
            let e: ThreadStateInterval = serde_json::from_value(event.clone()).unwrap();
            (
                TraceDensitySource::ThreadState {
                    thread: e.thread_key,
                },
                RepositoryDetailPage::ThreadState(page(e)),
            )
        }
        "namedSlice" => {
            let e: TraceSlice = serde_json::from_value(event.clone()).unwrap();
            (
                TraceDensitySource::NamedSlice {
                    thread: e.thread_key,
                },
                RepositoryDetailPage::NamedSlice(page(e)),
            )
        }
        "frame" => {
            let e: TraceFrame = serde_json::from_value(event.clone()).unwrap();
            (
                TraceDensitySource::Frame {
                    process_key: e.process_key,
                },
                RepositoryDetailPage::Frame(page(e)),
            )
        }
        "counter" => {
            let mut v = case["series"].clone();
            v["samples"] = json!([event]);
            let e: CounterSeries = serde_json::from_value(v).unwrap();
            let source = match e.scope {
                CounterScope::Cpu => TraceDensitySource::CpuCounter {
                    filter_id: e.filter_id,
                    cpu: e.cpu,
                },
                CounterScope::Process => TraceDensitySource::ProcessCounter {
                    filter_id: e.filter_id,
                    process_key: e.process_key,
                },
            };
            (source, RepositoryDetailPage::Counter(page(e)))
        }
        other => panic!("unsupported {other}"),
    };
    let mapped = map_detail_page(&source, range, 10, raw, &mut || Ok(())).unwrap();
    let request = ViewportRequest {
        viewport: Viewport::new(range, 200.0, 1000.0, 0.0, 1).unwrap(),
        tracks: vec![TrackDescriptor {
            source,
            is_collapsed: false,
            shows_nested_depth: true,
        }],
        pixel_width: 400,
        generation: 1,
        preference: DetailPreference::Detail,
        maximum_primitives: Some(10),
        focused_event_key: None,
    };
    let assembled = assemble(
        &request,
        &[],
        &[LanePages {
            expanded_index: 0,
            detail: Some(&mapped),
            density: None,
        }],
        2.0,
        &mut || Ok(()),
    )
    .unwrap();
    HotSnapshot::pack(&assembled.snapshot, 16 * 1024 * 1024, &mut || Ok(())).unwrap()
}
fn facts(scene: &HotSnapshot) -> Value {
    assert_eq!(scene.primitives.len(), 1);
    let p = scene.primitives[0];
    assert!(p.flags & WIRE_FLAG_RENDER_FACTS != 0);
    assert!(p.flags & WIRE_FLAG_COLOR != 0);
    let string = |flag, offset: u32, length: u32| {
        if p.flags & flag == 0 {
            Value::Null
        } else {
            json!(
                std::str::from_utf8(&scene.strings[offset as usize..(offset + length) as usize])
                    .unwrap()
            )
        }
    };
    let scalar = |flag, value: i64| {
        if p.flags & flag == 0 {
            Value::Null
        } else {
            json!(value)
        }
    };
    let owner = |flag, value: i64, field: &str| {
        if p.flags & flag == 0 {
            Value::Null
        } else {
            json!({field:value})
        }
    };
    let kind = match p.event_kind {
        1 => "cpuSlice",
        2 => "threadState",
        3 => "namedSlice",
        4 => "counter",
        5 => "frame",
        _ => panic!("event kind"),
    };
    let table = match p.event_table {
        WIRE_TABLE_SCHED_SLICE => "sched_slice",
        WIRE_TABLE_THREAD_STATE => "thread_state",
        WIRE_TABLE_CALLSTACK => "callstack",
        WIRE_TABLE_MEASURE => "measure",
        WIRE_TABLE_PROCESS_MEASURE => "process_measure",
        WIRE_TABLE_FRAME_SLICE => "frame_slice",
        _ => panic!("table"),
    };
    json!({"key":{"table":table,"rowID":p.row_id},"kind":kind,
        "name":string(WIRE_FLAG_NAME,p.name_offset,p.name_length),
        "range":{"startNs":p.start_ns,"endNs":p.end_ns},
        "semanticDurationNs":scalar(WIRE_FLAG_SEMANTIC_DURATION,p.semantic_duration_ns),
        "isOpenEnded":p.flags & WIRE_FLAG_OPEN_ENDED != 0,
        "isInstant":p.flags & WIRE_FLAG_SEMANTIC_DURATION != 0 && p.semantic_duration_ns == 0,
        "processKey":owner(WIRE_FLAG_PROCESS_KEY,p.process_key,"ipid"),"threadKey":owner(WIRE_FLAG_THREAD_KEY,p.thread_key,"itid"),
        "pid":scalar(WIRE_FLAG_PID,p.pid),"tid":scalar(WIRE_FLAG_TID,p.tid),"cpu":scalar(WIRE_FLAG_CPU,p.cpu),
        "processName":string(WIRE_FLAG_PROCESS_NAME,p.process_name_offset,p.process_name_length),
        "threadName":string(WIRE_FLAG_THREAD_NAME,p.thread_name_offset,p.thread_name_length),
        "category":string(WIRE_FLAG_INSPECTOR_CATEGORY,p.inspector_category_offset,p.inspector_category_length),
        "state":string(WIRE_FLAG_STATE,p.state_offset,p.state_length),"value":scalar(WIRE_FLAG_VALUE,p.value),
        "unit":string(WIRE_FLAG_UNIT,p.unit_offset,p.unit_length),"priority":scalar(WIRE_FLAG_PRIORITY,p.priority)})
}
#[test]
fn repository_mapper_geometry_and_abi2_keep_actual_swift_inspector_vectors() {
    let input: Value =
        serde_json::from_str(include_str!("fixtures/inspector-projection-inputs.json")).unwrap();
    let expected: Value =
        serde_json::from_str(include_str!("fixtures/inspector-projection-swift.json")).unwrap();
    let mut records = 0;
    for (case, expected) in input["cases"]
        .as_array()
        .unwrap()
        .iter()
        .zip(expected["cases"].as_array().unwrap())
    {
        if case["kind"] == "densityBand" {
            continue;
        }
        for (event, expected) in case["events"]
            .as_array()
            .unwrap()
            .iter()
            .zip(expected["facts"].as_array().unwrap())
        {
            common::compare(
                &facts(&wire(case, event)),
                expected,
                case["id"].as_str().unwrap(),
            );
            records += 1;
        }
    }
    assert_eq!(records, 392);
}
