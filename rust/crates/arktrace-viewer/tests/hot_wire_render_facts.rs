//! Current Swift loader facts joined to current real public Viewer/HotSnapshot.
//! Compares actual current Swift display facts against actual mapper/loader/ABI2 wire.
use arktrace_contract::*;
use arktrace_viewer::*;
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    error::Error,
    fs,
    path::PathBuf,
    time::{Duration, Instant},
};
type TestResult = Result<(), Box<dyn Error>>;
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Input {
    group: String,
    viewport: Viewport,
    backing_scale: f64,
    slices: Vec<TraceSlice>,
    frames: Vec<TraceFrame>,
    counters: Vec<CounterSeries>,
    density_buckets: Vec<TraceDensityBucket>,
}
fn directory() -> PathBuf {
    std::env::var_os("ARKTRACE_N21R1_FIXTURES")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/hot-wire-render-facts")
        })
}
fn descriptors(input: &Input) -> Vec<TrackDescriptor> {
    let sources = match input.group.as_str() {
        "named-slices" => vec![TraceDensitySource::NamedSlice {
            thread: Some(ThreadKey { itid: 0 }),
        }],
        "frames" => vec![TraceDensitySource::Frame {
            process_key: Some(ProcessKey { ipid: 0 }),
        }],
        _ => vec![
            TraceDensitySource::CpuCounter {
                filter_id: 0,
                cpu: Some(0),
            },
            TraceDensitySource::ProcessCounter {
                filter_id: 0,
                process_key: Some(ProcessKey { ipid: 0 }),
            },
        ],
    };
    sources
        .into_iter()
        .map(|source| TrackDescriptor {
            source,
            is_collapsed: false,
            shows_nested_depth: true,
        })
        .collect()
}
fn page<T>(items: Vec<T>) -> EventPage<T> {
    EventPage {
        items,
        truncated: false,
        capability_available: true,
        data_quality: DataQuality::machine(QualityStatus::Ok, Vec::new())
            .expect("valid empty machine quality"),
    }
}
struct Repository<'a>(&'a Input);
impl ViewportQueries for Repository<'_> {
    type Error = ViewerError;
    fn density_batch(
        &mut self,
        q: &[TraceDensityQuery],
    ) -> Result<Vec<TraceDensityResult>, ViewerError> {
        q.iter().map(|q| self.density(q)).collect()
    }
    fn density(&mut self, _q: &TraceDensityQuery) -> Result<TraceDensityResult, ViewerError> {
        Ok(TraceDensityResult {
            buckets: self.0.density_buckets.clone(),
            capability_available: true,
            data_quality: DataQuality::machine(QualityStatus::Ok, Vec::new())
                .expect("valid empty machine quality"),
        })
    }
    fn details(
        &mut self,
        source: &TraceDensitySource,
        range: TraceTimeRange,
        limit: usize,
        _focused: Option<EventKey>,
    ) -> Result<EventPage<DetailInput>, ViewerError> {
        let page = match source {
            TraceDensitySource::NamedSlice { .. } => {
                RepositoryDetailPage::NamedSlice(page(self.0.slices.clone()))
            }
            TraceDensitySource::Frame { .. } => {
                RepositoryDetailPage::Frame(page(self.0.frames.clone()))
            }
            _ => RepositoryDetailPage::Counter(page(
                self.0
                    .counters
                    .iter()
                    .filter(|s| {
                        matches!(
                            (source, s.scope),
                            (TraceDensitySource::CpuCounter { .. }, CounterScope::Cpu)
                                | (
                                    TraceDensitySource::ProcessCounter { .. },
                                    CounterScope::Process
                                )
                        )
                    })
                    .cloned()
                    .collect(),
            )),
        };
        map_detail_page(source, range, limit, page, &mut || Ok(()))
    }
}
fn packed(input: &Input, density: bool) -> HotSnapshot {
    let request = ViewportRequest {
        viewport: input.viewport.clone(),
        tracks: descriptors(input),
        pixel_width: 174,
        generation: input.viewport.generation(),
        preference: if density {
            DetailPreference::Density
        } else {
            DetailPreference::Detail
        },
        maximum_primitives: Some(8),
        focused_event_key: None,
    };
    let loaded = ViewportLoader::default()
        .load(
            &request,
            input.backing_scale,
            &mut Repository(input),
            &mut || Ok(()),
        )
        .expect("actual bounded Viewer loader")
        .expect("current generation");
    HotSnapshot::pack(&loaded.snapshot, 1048576, &mut || Ok(())).expect("actual bounded hot packer")
}

fn text(scene: &HotSnapshot, offset: u32, length: u32) -> &str {
    let start = offset as usize;
    let end = start
        .checked_add(length as usize)
        .expect("bounded wire string");
    std::str::from_utf8(scene.strings.get(start..end).expect("actual wire span"))
        .expect("exact UTF8")
}
fn rgb(p: &PrimitiveRecord) -> Value {
    assert_ne!(p.flags & WIRE_FLAG_COLOR, 0);
    json!({"red":(p.color_rgb>>16)&255,"green":(p.color_rgb>>8)&255,"blue":p.color_rgb&255})
}
fn optional_text(
    scene: &HotSnapshot,
    p: &PrimitiveRecord,
    flag: u32,
    offset: u32,
    length: u32,
) -> Value {
    if p.flags & flag == 0 {
        Value::Null
    } else {
        json!(text(scene, offset, length))
    }
}
fn scalar(p: &PrimitiveRecord, flag: u32, value: i64) -> Value {
    if p.flags & flag == 0 {
        Value::Null
    } else {
        json!(value)
    }
}
fn key(p: &PrimitiveRecord) -> EventKey {
    let table = match p.event_table {
        WIRE_TABLE_CALLSTACK => EventTable::Callstack,
        WIRE_TABLE_FRAME_SLICE => EventTable::FrameSlice,
        WIRE_TABLE_MEASURE => EventTable::Measure,
        WIRE_TABLE_PROCESS_MEASURE => EventTable::ProcessMeasure,
        _ => panic!("unexpected physical table"),
    };
    EventKey {
        table,
        row_id: p.row_id,
    }
}
fn inspector(scene: &HotSnapshot, p: &PrimitiveRecord) -> Value {
    assert_ne!(
        p.flags & WIRE_FLAG_RENDER_FACTS,
        0,
        "current mapper retained real facts"
    );
    let kind = match p.event_kind {
        3 => "namedSlice",
        4 => "counter",
        5 => "frame",
        _ => panic!("source kind"),
    };
    let owner = |flag: u32, value: i64, field: &str| {
        if p.flags & flag == 0 {
            Value::Null
        } else {
            json!({field:value})
        }
    };
    json!({"key":key(p),"type":kind,
        "name":optional_text(scene,p,WIRE_FLAG_NAME,p.name_offset,p.name_length),
        "range":{"startNs":p.start_ns,"endNs":p.end_ns},
        "semanticDurationNs":scalar(p,WIRE_FLAG_SEMANTIC_DURATION,p.semantic_duration_ns),
        "isOpenEnded":p.flags&WIRE_FLAG_OPEN_ENDED!=0,
        "isInstant":p.flags&WIRE_FLAG_SEMANTIC_DURATION!=0 && p.semantic_duration_ns==0,
        "processKey":owner(WIRE_FLAG_PROCESS_KEY,p.process_key,"ipid"),
        "threadKey":owner(WIRE_FLAG_THREAD_KEY,p.thread_key,"itid"),
        "pid":scalar(p,WIRE_FLAG_PID,p.pid),"tid":scalar(p,WIRE_FLAG_TID,p.tid),
        "cpu":scalar(p,WIRE_FLAG_CPU,p.cpu),"value":scalar(p,WIRE_FLAG_VALUE,p.value),
        "priority":scalar(p,WIRE_FLAG_PRIORITY,p.priority),
        "processName":optional_text(scene,p,WIRE_FLAG_PROCESS_NAME,p.process_name_offset,p.process_name_length),
        "threadName":optional_text(scene,p,WIRE_FLAG_THREAD_NAME,p.thread_name_offset,p.thread_name_length),
        "category":optional_text(scene,p,WIRE_FLAG_INSPECTOR_CATEGORY,p.inspector_category_offset,p.inspector_category_length),
        "state":optional_text(scene,p,WIRE_FLAG_STATE,p.state_offset,p.state_length),
        "unit":optional_text(scene,p,WIRE_FLAG_UNIT,p.unit_offset,p.unit_length)})
}
fn layouts(scene: &HotSnapshot) -> Value {
    json!(
        scene
            .tracks
            .iter()
            .map(|t| json!({"trackID":text(scene,t.id_offset,t.id_length),
        "y":t.y,"height":t.height,"depthRows":t.depth_rows,
        "layoutDoubleBits":[t.y.to_bits().to_string(),t.height.to_bits().to_string()]}))
            .collect::<Vec<_>>()
    )
}
fn facts(scene: &HotSnapshot) -> Value {
    json!(scene.primitives.iter().map(|p| {
        assert_ne!(p.flags&WIRE_FLAG_FRAME,0,"actual projected frame");
        let t=&scene.tracks[p.track_index as usize];
        let mut value=json!({"trackID":text(scene,t.id_offset,t.id_length),
            "selectableEventKey":if p.kind==WIRE_PRIMITIVE_DETAIL { json!(key(p)) } else { Value::Null },
            "isVisible":p.flags&WIRE_FLAG_VISIBLE!=0,
            "frameDoubleBits":([p.x,p.y,p.width,p.height].map(|x| x.to_bits().to_string())),
            "colorRGB":rgb(p)});
        if p.kind==WIRE_PRIMITIVE_DETAIL {
            value.as_object_mut().unwrap().extend(json!({"kind":"detail","eventKey":key(p),
                "range":{"startNs":p.start_ns,"endNs":p.end_ns},
                "label":optional_text(scene,p,WIRE_FLAG_LABEL,p.label_offset,p.label_length),
                "category":optional_text(scene,p,WIRE_FLAG_CATEGORY,p.category_offset,p.category_length),
                "depth":p.depth,"jankTag":p.jank_tag,"inspector":inspector(scene,p)}).as_object().unwrap().clone());
        } else {
            assert_eq!(p.kind,WIRE_PRIMITIVE_DENSITY);
            assert_eq!((p.event_table,p.row_id),(0,0),"density never has physical selection");
            let mut b=json!({"range":{"startNs":p.start_ns,"endNs":p.end_ns},"eventCount":p.event_count});
            let m=b.as_object_mut().unwrap();
            if p.flags&WIRE_FLAG_OCCUPANCY!=0 {m.insert("occupiedNs".into(),json!(p.occupied_ns));}
            if p.flags&WIRE_FLAG_UTILIZATION!=0 {m.insert("utilization".into(),json!(p.utilization));}
            match p.dominant_kind {
                WIRE_DOMINANT_NAME=>{m.insert("dominant".into(),json!({"name":{"_0":text(scene,p.text_offset,p.text_length)}}));}
                0=>{}, _=>panic!("original named density input"),
            }
            value.as_object_mut().unwrap().extend(json!({"kind":"density","bucket":b}).as_object().unwrap().clone());
        }
        value
    }).collect::<Vec<_>>())
}
fn compare(
    path: &str,
    actual: &Value,
    expected: &Value,
    matched: &mut Vec<String>,
    missing: &mut Vec<Value>,
) {
    match (actual, expected) {
        (Value::Object(a), Value::Object(b)) => {
            let keys: std::collections::BTreeSet<_> = a.keys().chain(b.keys()).collect();
            for k in keys {
                let next = format!("{path}.{k}");
                match (a.get(k), b.get(k)) {
                    (Some(a), Some(b)) => compare(&next, a, b, matched, missing),
                    (a, b) => missing.push(
                        json!({"path":next,"actual":a,"expected":b,"reason":"field missing"}),
                    ),
                }
            }
        }
        (Value::Array(a), Value::Array(b)) => {
            if a.len() != b.len() {
                missing.push(json!({"path":path,"actualCount":a.len(),"expectedCount":b.len()}));
            }
            for (i, (a, b)) in a.iter().zip(b).enumerate() {
                compare(&format!("{path}[{i}]"), a, b, matched, missing);
            }
        }
        (Value::Number(a), Value::Number(b))
            if matches!(
                path.rsplit('.').next(),
                Some(
                    "y" | "height"
                        | "nsPerPoint"
                        | "widthPoints"
                        | "heightPoints"
                        | "verticalOffsetPoints"
                )
            ) && a
                .as_f64()
                .zip(b.as_f64())
                .is_some_and(|(a, b)| a.to_bits() == b.to_bits()) =>
        {
            matched.push(path.to_owned())
        }
        _ if actual == expected => matched.push(path.to_owned()),
        _ => missing.push(json!({"path":path,"actual":actual,"expected":expected})),
    }
}
fn canonical(name: &str) -> TestResult {
    let end = Instant::now() + Duration::from_secs(8);
    let input_bytes = fs::read(directory().join(format!("{name}-input.json")))?;
    let input: Input = serde_json::from_slice(&input_bytes)?;
    assert_eq!(input.group, name);
    let swift_dir = std::env::var_os("ARKTRACE_N21R1_SWIFT_OUTPUT")
        .map(PathBuf::from)
        .unwrap_or_else(directory);
    let swift_path = if std::env::var_os("ARKTRACE_N21R1_SWIFT_OUTPUT").is_some() {
        swift_dir.join(format!("{name}.json"))
    } else {
        swift_dir.join(format!("{name}-swift.json"))
    };
    let swift_bytes = fs::read(swift_path)?;
    assert!(swift_bytes.len() <= 32768);
    let swift: Value = serde_json::from_slice(&swift_bytes)?;
    let wire = packed(&input, false);
    assert_eq!(
        wire.primitives.len(),
        if name == "counters" { 4 } else { 3 }
    );
    let vp = wire.viewport;
    let actual_viewport = json!({"range":{"startNs":vp.start_ns,"endNs":vp.end_ns},"nsPerPoint":vp.ns_per_point,
        "widthPoints":vp.width_points,"heightPoints":vp.height_points,"verticalOffsetPoints":vp.vertical_offset_points,"generation":vp.generation});
    let mut actual = json!({"detailFacts":facts(&wire),"trackLayout":layouts(&wire),"viewport":actual_viewport,
        "viewportDoubleBits":([vp.ns_per_point,vp.width_points,vp.height_points,vp.vertical_offset_points].map(|x|x.to_bits().to_string())),
        "densityFacts":[],"densityTrackLayout":[]});
    let mut packer_calls = 1;
    let mut primitive_count = wire.primitives.len();
    if name == "named-slices" {
        let density = packed(&input, true);
        assert_eq!(density.primitives.len(), 1);
        actual["densityFacts"] = facts(&density);
        actual["densityTrackLayout"] = layouts(&density);
        primitive_count += density.primitives.len();
        packer_calls += 1;
    }
    assert!(primitive_count <= 8);
    let mut matched = Vec::new();
    let mut missing = Vec::new();
    for field in [
        "detailFacts",
        "trackLayout",
        "viewport",
        "viewportDoubleBits",
        "densityFacts",
        "densityTrackLayout",
    ] {
        compare(
            field,
            &actual[field],
            &swift[field],
            &mut matched,
            &mut missing,
        );
    }
    assert_eq!(swift["actualCpuCatalogCalls"], 0);
    let report = json!({"group":name,"actualEntryChain":["ViewportLoader.load","map_detail_page","assemble","HotSnapshot.pack"],
        "currentABI":2,"actualRustPackerCalls":packer_calls,"actualSwiftLoaderCalls":swift["actualLoaderCalls"],
        "actualCpuCatalogCalls":0,"primitiveCountIncludingDensity":primitive_count,
        "inputBytes":input_bytes.len(),"swiftOutputBytes":swift_bytes.len(),
        "matchedFieldCount":matched.len(),"matchedFields":matched,"missingFieldCount":missing.len(),"missingFields":missing,
        "actualWireDisplayFacts":actual,"actualFFISDKControllerAppCases":0});
    let bytes = serde_json::to_vec(&report)?;
    assert!(bytes.len() <= 65536);
    if let Some(root) = std::env::var_os("ARKTRACE_N21R1_RUST_OUTPUT") {
        fs::write(PathBuf::from(root).join(format!("{name}.json")), bytes)?;
    }
    assert!(Instant::now() < end);
    assert!(
        missing.is_empty(),
        "actual current canonical mismatch: {}",
        serde_json::to_string(&missing)?
    );
    println!(
        "N21R1_ACTUAL_DISPLAY_CANONICAL {name} {primitive_count} {}",
        matched.len()
    );
    Ok(())
}
#[test]
fn named_slice_current_abi2_display_matches_swift_loader() -> TestResult {
    canonical("named-slices")
}
#[test]
fn frame_current_abi2_display_matches_swift_loader() -> TestResult {
    canonical("frames")
}
#[test]
fn counters_current_abi2_display_matches_swift_loader() -> TestResult {
    canonical("counters")
}
