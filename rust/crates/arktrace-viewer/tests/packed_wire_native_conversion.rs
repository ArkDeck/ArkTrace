#![recursion_limit = "256"]

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
    std::env::var_os("ARKTRACE_N22_FIXTURES")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("tests/fixtures/packed-wire-native-conversion")
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
                RepositoryDetailPage::Frame(frame_page(self.0.frames.clone()))
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

fn frame_page<T>(items: Vec<T>) -> EventPage<T> {
    let mut p = page(items);
    p.data_quality = DataQuality::machine(
        QualityStatus::Warnings,
        vec![QualityIssue {
            category: QualityCategory::InvalidValue,
            scope: Some("timeline.frame".into()),
            count: Some(0),
            message: None,
        }],
    )
    .expect("legal typed quality input");
    p
}
fn export_viewportrecord(value: &ViewportRecord) -> Value {
    json!({"start_ns": value.start_ns,"end_ns": value.end_ns,"ns_per_point_bits": value.ns_per_point.to_bits().to_string(),"width_points_bits": value.width_points.to_bits().to_string(),"height_points_bits": value.height_points.to_bits().to_string(),"vertical_offset_points_bits": value.vertical_offset_points.to_bits().to_string(),"generation": value.generation,"source_generation": value.source_generation,"backing_scale_bits": value.backing_scale.to_bits().to_string()})
}
fn export_trackrecord(value: &TrackRecord) -> Value {
    json!({"source_kind": value.source_kind,"flags": value.flags,"source_value": value.source_value,"filter_id": value.filter_id,"owner_value": value.owner_value,"id_offset": value.id_offset,"id_length": value.id_length,"y_bits": value.y.to_bits().to_string(),"height_bits": value.height.to_bits().to_string(),"depth_rows": value.depth_rows,"primitive_start": value.primitive_start,"primitive_count": value.primitive_count,"reserved": value.reserved})
}
fn export_primitiverecord(value: &PrimitiveRecord) -> Value {
    json!({"kind": value.kind,"flags": value.flags,"track_index": value.track_index,"event_table": value.event_table,"style": value.style,"reserved_header": value.reserved_header,"depth": value.depth,"row_id": value.row_id,"start_ns": value.start_ns,"end_ns": value.end_ns,"x_bits": value.x.to_bits().to_string(),"y_bits": value.y.to_bits().to_string(),"width_bits": value.width.to_bits().to_string(),"height_bits": value.height.to_bits().to_string(),"event_count": value.event_count,"occupied_ns": value.occupied_ns,"utilization_bits": value.utilization.to_bits().to_string(),"dominant_kind": value.dominant_kind,"text_offset": value.text_offset,"text_length": value.text_length,"reserved": value.reserved,"dominant_value": value.dominant_value,"event_kind": value.event_kind,"color_rgb": value.color_rgb,"jank_tag": value.jank_tag,"semantic_duration_ns": value.semantic_duration_ns,"process_key": value.process_key,"thread_key": value.thread_key,"pid": value.pid,"tid": value.tid,"cpu": value.cpu,"value": value.value,"priority": value.priority,"label_offset": value.label_offset,"label_length": value.label_length,"category_offset": value.category_offset,"category_length": value.category_length,"name_offset": value.name_offset,"name_length": value.name_length,"process_name_offset": value.process_name_offset,"process_name_length": value.process_name_length,"thread_name_offset": value.thread_name_offset,"thread_name_length": value.thread_name_length,"inspector_category_offset": value.inspector_category_offset,"inspector_category_length": value.inspector_category_length,"state_offset": value.state_offset,"state_length": value.state_length,"unit_offset": value.unit_offset,"unit_length": value.unit_length})
}
fn export_qualityrecord(value: &QualityRecord) -> Value {
    json!({"category": value.category,"flags": value.flags,"scope_offset": value.scope_offset,"scope_length": value.scope_length,"count": value.count})
}

fn wire(scene: &HotSnapshot) -> Value {
    for p in &scene.primitives {
        assert_ne!(p.flags & WIRE_FLAG_COLOR, 0);
        if p.kind == WIRE_PRIMITIVE_DETAIL {
            assert_ne!(p.flags & WIRE_FLAG_RENDER_FACTS, 0);
        } else {
            assert_eq!(
                (p.kind, p.event_table, p.row_id),
                (WIRE_PRIMITIVE_DENSITY, 0, 0)
            );
        }
    }
    json!({"qualityStatus":scene.quality_status,"viewport":export_viewportrecord(&scene.viewport),
        "tracks":scene.tracks.iter().map(export_trackrecord).collect::<Vec<_>>(),
        "primitives":scene.primitives.iter().map(export_primitiverecord).collect::<Vec<_>>(),
        "quality":scene.quality.iter().map(export_qualityrecord).collect::<Vec<_>>(),"strings":scene.strings})
}
fn export(name: &str) -> TestResult {
    let end = Instant::now() + Duration::from_secs(8);
    let raw = fs::read(directory().join(format!("{name}-input.json")))?;
    let input: Input = serde_json::from_slice(&raw)?;
    assert_eq!(input.group, name);
    let detail = packed(&input, false);
    let mut scenes = vec![json!({"variant":"detail","wire":wire(&detail)})];
    let mut calls = 1;
    if name == "frames" {
        assert_eq!(detail.quality.len(), 1);
        assert_eq!(detail.quality[0].count, 0);
    }
    if name == "named-slices" {
        let density = packed(&input, true);
        assert_eq!(density.primitives.len(), 1);
        scenes.push(json!({"variant":"density","wire":wire(&density)}));
        calls += 1;
        let mut clipped = input.clone();
        clipped.slices = input.slices[1..].to_vec();
        clipped.viewport = Viewport::new(
            TraceTimeRange::query(
                input.viewport.range().start_ns() + 30,
                input.viewport.range().end_ns(),
            )
            .expect("valid bounded clipped fixture"),
            input.viewport.width_points(),
            input.viewport.height_points(),
            input.viewport.vertical_offset_points(),
            input.viewport.generation(),
        )?;
        let clipped = packed(&clipped, false);
        assert_eq!(clipped.primitives.len(), 2);
        assert_eq!(clipped.primitives[0].x.to_bits(), 0.0_f64.to_bits());
        assert!(clipped.primitives[0].start_ns < clipped.viewport.start_ns);
        scenes.push(json!({"variant":"clipped","wire":wire(&clipped)}));
        calls += 1;
    }
    let result = json!({"schema":"N22PackedWire1","group":name,"actualEntries":["ViewportLoader.load","map_detail_page","assemble","HotSnapshot.pack"],"actualRustPackerCalls":calls,"scenes":scenes,"actualFFISDKControllerAppCases":0});
    let expected: Value =
        serde_json::from_slice(&fs::read(directory().join(format!("{name}-packed.json")))?)?;
    assert_eq!(result, expected, "actual packed records drifted: {name}");
    let data = serde_json::to_vec(&result)?;
    assert!(data.len() <= 65536);
    if let Some(root) = std::env::var_os("ARKTRACE_N22_RUST_OUTPUT") {
        fs::write(
            PathBuf::from(root).join(format!("{name}-packed.json")),
            &data,
        )?;
    }
    assert!(Instant::now() < end);
    println!("N22_ACTUAL_PACKED_WIRE {name} {calls} {}", data.len());
    Ok(())
}
#[test]
fn named_slices_actual_packed_records() -> TestResult {
    export("named-slices")
}
#[test]
fn frames_actual_packed_records() -> TestResult {
    export("frames")
}
#[test]
fn counters_actual_packed_records() -> TestResult {
    export("counters")
}
