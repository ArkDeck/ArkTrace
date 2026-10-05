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
    std::env::var_os("ARKTRACE_N27_FIXTURES")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/hot-snapshot-hit")
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

fn frame_page<T>(items: Vec<T>) -> EventPage<T> {
    page(items)
}
fn common(hit: &Option<HitIntent>) -> Value {
    match hit {
        Some(HitIntent::Detail { event_key }) => json!({"kind":"detail","eventKey":event_key}),
        Some(HitIntent::Density { intent }) => {
            json!({"kind":"density","trackID":intent.track_id,"source":intent.source,"bucket":intent.bucket,"timeNs":intent.time_ns})
        }
        None => Value::Null,
    }
}
fn copy_scene(s: &HotSnapshot) -> HotSnapshot {
    HotSnapshot {
        quality_status: s.quality_status,
        viewport: s.viewport,
        tracks: s.tracks.clone(),
        primitives: s.primitives.clone(),
        quality: s.quality.clone(),
        strings: s.strings.clone(),
    }
}
#[test]
fn retained_packed_hits_current_swift_and_projected() -> TestResult {
    let started = Instant::now();
    let deadline = started + Duration::from_secs(12);
    let mut check = || {
        if Instant::now() < deadline {
            Ok(())
        } else {
            Err(ViewerError::DeadlineReached)
        }
    };
    let mut points = 0;
    let mut loaders = 0;
    let mut records = Vec::new();
    let mut negative_count = 0;
    for name in ["named-slices", "frames", "counters"] {
        let input: Input =
            serde_json::from_slice(&fs::read(directory().join(format!("{name}-input.json")))?)?;
        let oracle: Value =
            serde_json::from_slice(&fs::read(directory().join(format!("{name}-swift.json")))?)?;
        for scene in oracle["scenes"].as_array().ok_or("scenes")? {
            let variant = scene["variant"].as_str().ok_or("variant")?;
            let mut actual = input.clone();
            if variant == "clipped" {
                let v = &input.viewport;
                actual.viewport = Viewport::new(
                    TraceTimeRange::query(v.range().start_ns() + 30, v.range().end_ns())
                        .map_err(ViewerError::from)?,
                    v.width_points(),
                    v.height_points(),
                    v.vertical_offset_points(),
                    v.generation(),
                )?;
                actual.slices.retain(|s| {
                    s.range.end_ns() >= actual.viewport.range().start_ns()
                        && s.range.start_ns() <= actual.viewport.range().end_ns()
                });
            }
            let request = ViewportRequest {
                viewport: actual.viewport.clone(),
                tracks: descriptors(&actual),
                pixel_width: 174,
                generation: actual.viewport.generation(),
                preference: if variant == "density" {
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
                    actual.backing_scale,
                    &mut Repository(&actual),
                    &mut check,
                )
                .map_err(|error| format!("actual loader: {error:?}"))?
                .ok_or("loaded")?;
            loaders += 1;
            let packed = HotSnapshot::pack(&loaded.snapshot, 1048576, &mut check)?;
            let display_scale = if variant == "stale" {
                1.0_f64
            } else {
                actual.backing_scale
            };
            assert_eq!(
                scene["backingScaleBits"],
                display_scale.to_bits().to_string()
            );
            let display: Viewport = scene
                .get("displayViewport")
                .map(|value| serde_json::from_value(value.clone()))
                .transpose()?
                .unwrap_or_else(|| actual.viewport.clone());
            let retained_tracks: Vec<TrackInput> = loaded
                .snapshot
                .tracks()
                .iter()
                .map(|t| TrackInput {
                    descriptor: t.descriptor.clone(),
                    y: t.y,
                    height: t.height,
                    depth_row_count: t.depth_row_count,
                    primitives: t.primitives.iter().map(|p| p.input.clone()).collect(),
                })
                .collect();
            let displayed = project(
                &display,
                loaded.snapshot.source_generation(),
                &retained_tracks,
                display_scale,
                loaded.snapshot.data_quality(),
                &mut check,
            )?;
            let actual_frames: Vec<Vec<String>> = retained_tracks
                .iter()
                .flat_map(|t| t.primitives.iter().map(move |p| (t, p)))
                .map(|(t, p)| {
                    let f = primitive_frame(p, t, &display, display_scale).expect("valid frame");
                    [f.x, f.y, f.width, f.height]
                        .map(|v| v.to_bits().to_string())
                        .to_vec()
                })
                .collect();
            assert_eq!(
                serde_json::to_value(actual_frames)?,
                scene["frames"],
                "{name}/{variant} real frames"
            );
            for row in scene["points"].as_array().ok_or("points")? {
                let point = Point {
                    x: row["x"].as_f64().ok_or("x")?,
                    y: row["y"].as_f64().ok_or("y")?,
                };
                assert_eq!(
                    json!([point.x.to_bits().to_string(), point.y.to_bits().to_string()]),
                    row["pointBits"]
                );
                let got = hot_snapshot_hit_in(
                    &packed,
                    &display,
                    display_scale,
                    point,
                    HotSnapshotHitMode::Any,
                    HotSnapshotHitBudget::default(),
                    &mut check,
                )?;
                let projected = displayed.hit(point, &mut check)?;
                let detail = hot_snapshot_hit_in(
                    &packed,
                    &display,
                    display_scale,
                    point,
                    HotSnapshotHitMode::Detail,
                    HotSnapshotHitBudget::default(),
                    &mut check,
                )?;
                assert_eq!(
                    detail,
                    displayed
                        .detail_hit(point, &mut check)?
                        .map(|event_key| HitIntent::Detail { event_key })
                );
                let density = hot_snapshot_hit_in(
                    &packed,
                    &display,
                    display_scale,
                    point,
                    HotSnapshotHitMode::Density,
                    HotSnapshotHitBudget::default(),
                    &mut check,
                )?;
                assert_eq!(
                    density,
                    displayed
                        .density_hit(point, &mut check)?
                        .map(|intent| HitIntent::Density { intent })
                );
                if variant != "stale" {
                    assert_eq!(
                        got,
                        hot_snapshot_hit(
                            &packed,
                            point,
                            HotSnapshotHitBudget::default(),
                            &mut check
                        )?
                    );
                }
                assert_eq!(
                    got, projected,
                    "{name}/{variant} {point:?} full typed Rust intent"
                );
                assert_eq!(
                    common(&got),
                    row["hit"],
                    "{name}/{variant} {point:?} actual current Swift"
                );
                records
                    .push(json!({"group":name,"variant":variant,"point":point,"fullIntent":got}));
                points += 1;
            }
            if name == "named-slices" && variant == "detail" {
                let p = scene["points"][0].clone();
                let point = Point {
                    x: p["x"].as_f64().unwrap(),
                    y: p["y"].as_f64().unwrap(),
                };
                assert_eq!(
                    hot_snapshot_hit(
                        &packed,
                        Point {
                            x: f64::NAN,
                            y: point.y
                        },
                        HotSnapshotHitBudget::default(),
                        &mut check
                    ),
                    Err(ViewerError::InvalidGeometry)
                );
                negative_count += 1;
                let mut bad = copy_scene(&packed);
                bad.viewport.ns_per_point = f64::INFINITY;
                assert!(
                    hot_snapshot_hit(&bad, point, HotSnapshotHitBudget::default(), &mut check)
                        .is_err()
                );
                negative_count += 1;
                let mut bad = copy_scene(&packed);
                bad.primitives[0].width = f64::INFINITY;
                assert_eq!(
                    hot_snapshot_hit(&bad, point, HotSnapshotHitBudget::default(), &mut check),
                    Err(ViewerError::InvalidGeometry)
                );
                negative_count += 1;
                let mut bad = copy_scene(&packed);
                bad.primitives.last_mut().unwrap().kind = u32::MAX;
                assert_eq!(
                    hot_snapshot_hit(&bad, point, HotSnapshotHitBudget::default(), &mut check),
                    Err(ViewerError::InvalidEvidence)
                );
                negative_count += 1;
                let mut bad = copy_scene(&packed);
                bad.tracks[0].primitive_start = u32::MAX;
                assert_eq!(
                    hot_snapshot_hit(&bad, point, HotSnapshotHitBudget::default(), &mut check),
                    Err(ViewerError::InvalidEvidence)
                );
                negative_count += 1;
                let mut bad = copy_scene(&packed);
                bad.primitives[0].label_offset = u32::MAX;
                bad.primitives[0].label_length = 8;
                assert_eq!(
                    hot_snapshot_hit(&bad, point, HotSnapshotHitBudget::default(), &mut check),
                    Err(ViewerError::InvalidEvidence)
                );
                negative_count += 1;
                for budget in [
                    HotSnapshotHitBudget {
                        maximum_primitives: 0,
                        ..Default::default()
                    },
                    HotSnapshotHitBudget {
                        maximum_string_bytes: 0,
                        ..Default::default()
                    },
                    HotSnapshotHitBudget {
                        maximum_output_bytes: 0,
                        ..Default::default()
                    },
                    HotSnapshotHitBudget {
                        maximum_referenced_string_bytes: 0,
                        ..Default::default()
                    },
                ] {
                    assert_eq!(
                        hot_snapshot_hit(&packed, point, budget, &mut check),
                        Err(ViewerError::InputBudgetExceeded)
                    );
                    negative_count += 1;
                }
                for error in [ViewerError::Cancelled, ViewerError::DeadlineReached] {
                    let mut checks = 0;
                    assert_eq!(
                        hot_snapshot_hit(
                            &packed,
                            point,
                            HotSnapshotHitBudget::default(),
                            &mut || {
                                checks += 1;
                                if checks >= 4 { Err(error) } else { Ok(()) }
                            }
                        ),
                        Err(error)
                    );
                    assert_eq!(checks, 4);
                    negative_count += 1;
                }
            }
        }
    }
    assert_eq!(loaders, 6);
    assert_eq!(points, 54);
    assert_eq!(negative_count, 12);
    let result = json!({"actualProductionLoaderCalls":loaders,"actualPackCalls":loaders,"threeWayPointCount":points,"negativeCases":negative_count,"fullIntents":records});
    if let Some(path) = std::env::var_os("ARKTRACE_N27_RUST_OUTPUT") {
        fs::write(path, serde_json::to_vec(&result)?)?;
    }
    assert!(Instant::now() < deadline);
    println!(
        "N27_RUST loaders={loaders} packs={loaders} three-way={points} negatives={negative_count}"
    );
    Ok(())
}

#[test]
fn retained_hit_reprojects_visibility_scale_and_keeps_density_mode() -> Result<(), ViewerError> {
    let source = TraceDensitySource::NamedSlice {
        thread: Some(ThreadKey { itid: 0 }),
    };
    let detail = |start, end, row_id| PrimitiveInput::Detail {
        detail: DetailInput {
            event_key: EventKey {
                table: EventTable::Callstack,
                row_id,
            },
            range: TraceTimeRange::event(start, end).expect("valid event"),
            depth: 0,
            style: DetailStyle::Accent,
            is_open_ended: false,
            render_facts: None,
        },
    };
    let tracks = vec![TrackInput {
        descriptor: TrackDescriptor {
            source,
            is_collapsed: false,
            shows_nested_depth: true,
        },
        y: 0.0,
        height: 28.0,
        depth_row_count: 1,
        primitives: vec![
            detail(110, 115, 1),
            detail(250, 250, 2),
            PrimitiveInput::Density {
                bucket: TraceDensityBucket {
                    range: TraceTimeRange::query(240, 260)?,
                    event_count: 2,
                    occupied_ns: None,
                    utilization: None,
                    dominant: None,
                },
            },
        ],
    }];
    let quality = DataQuality::machine(QualityStatus::Ok, Vec::new())?;
    let original = Viewport::new(TraceTimeRange::query(100, 200)?, 100.0, 100.0, 0.0, 1)?;
    let retained = HotSnapshot::pack(
        &project(&original, 1, &tracks, 2.0, &quality, &mut || Ok(()))?,
        65536,
        &mut || Ok(()),
    )?;
    let display = Viewport::new(TraceTimeRange::query(200, 300)?, 100.0, 120.0, 10.0, 2)?;
    let point = Point { x: 51.75, y: 30.0 };
    assert_eq!(
        hot_snapshot_hit(&retained, point, Default::default(), &mut || Ok(()))?,
        None
    );
    for scale in [1.0, 2.0] {
        let projected = project(&display, 1, &tracks, scale, &quality, &mut || Ok(()))?;
        for point in [point, Point { x: 0.1, y: 30.0 }, Point { x: 60.0, y: 30.0 }] {
            let hit = |mode| {
                hot_snapshot_hit_in(
                    &retained,
                    &display,
                    scale,
                    point,
                    mode,
                    Default::default(),
                    &mut || Ok(()),
                )
            };
            assert_eq!(
                hit(HotSnapshotHitMode::Any)?,
                projected.hit(point, &mut || Ok(()))?
            );
            assert_eq!(
                hit(HotSnapshotHitMode::Detail)?,
                projected
                    .detail_hit(point, &mut || Ok(()))?
                    .map(|event_key| HitIntent::Detail { event_key })
            );
            assert_eq!(
                hit(HotSnapshotHitMode::Density)?,
                projected
                    .density_hit(point, &mut || Ok(()))?
                    .map(|intent| HitIntent::Density { intent })
            );
        }
    }
    assert!(matches!(
        hot_snapshot_hit_in(
            &retained,
            &display,
            1.0,
            point,
            HotSnapshotHitMode::Detail,
            Default::default(),
            &mut || Ok(())
        )?,
        Some(HitIntent::Detail {
            event_key: EventKey { row_id: 2, .. }
        })
    ));
    assert_eq!(
        hot_snapshot_hit_in(
            &retained,
            &display,
            2.0,
            point,
            HotSnapshotHitMode::Detail,
            Default::default(),
            &mut || Ok(())
        )?,
        None
    );
    assert!(matches!(
        hot_snapshot_hit_in(
            &retained,
            &display,
            1.0,
            point,
            HotSnapshotHitMode::Density,
            Default::default(),
            &mut || Ok(())
        )?,
        Some(HitIntent::Density { .. })
    ));
    Ok(())
}
