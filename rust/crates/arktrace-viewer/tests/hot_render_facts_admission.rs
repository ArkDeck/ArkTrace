//! Real DTO -> session-origin RenderDetailFacts -> loader/project -> ABI2 pack.
//! No private batch constructors, alternate accounting, density or Swift oracle.
use arktrace_contract::*;
use arktrace_viewer::*;

fn range() -> TraceTimeRange {
    TraceTimeRange::query(0, 1000).unwrap()
}
fn source() -> TraceDensitySource {
    TraceDensitySource::NamedSlice { thread: None }
}
fn quality() -> DataQuality {
    DataQuality::machine(QualityStatus::Ok, vec![]).unwrap()
}
fn descriptor() -> TrackDescriptor {
    TrackDescriptor {
        source: source(),
        is_collapsed: false,
        shows_nested_depth: false,
    }
}
fn dto(index: usize, name: String, other_text: Option<&str>) -> TraceSlice {
    TraceSlice {
        key: EventKey {
            table: EventTable::Callstack,
            row_id: index as i64 + 1,
        },
        range: TraceTimeRange::event(1, 10).unwrap(),
        thread_key: None,
        process_key: None,
        pid: None,
        tid: None,
        process_name: other_text.map(str::to_owned),
        thread_name: other_text.map(str::to_owned),
        name,
        category: other_text.map(str::to_owned),
        depth: Some(0),
        parent_event_key: None,
        is_async: false,
        is_open_ended: false,
        arg_set_id: None,
    }
}
fn repository_page(items: Vec<TraceSlice>) -> RepositoryDetailPage {
    RepositoryDetailPage::NamedSlice(EventPage {
        items,
        truncated: false,
        capability_available: true,
        data_quality: quality(),
    })
}
fn mapped(
    page: RepositoryDetailPage,
    check: &mut Check<'_>,
) -> Result<EventPage<DetailInput>, ViewerError> {
    map_detail_page(&source(), range(), MAXIMUM_PRIMITIVES, page, check)
}
fn tiny_page() -> RepositoryDetailPage {
    repository_page(
        (0..3)
            .map(|i| dto(i, "绘制🦀".into(), Some("绘制🦀")))
            .collect(),
    )
}
fn request(tracks: usize, generation: u64) -> ViewportRequest {
    ViewportRequest {
        viewport: Viewport::new(range(), 200.0, 1000.0, 0.0, generation).unwrap(),
        tracks: vec![descriptor(); tracks],
        pixel_width: 2000,
        generation,
        preference: DetailPreference::Detail,
        maximum_primitives: Some(MAXIMUM_PRIMITIVES),
        focused_event_key: None,
    }
}
// Typed host cache: values were produced exclusively by map_detail_page. Reuse
// clones actual Arc facts; independent projections retain independent Arcs.
struct Backend {
    pages: Vec<EventPage<DetailInput>>,
    calls: usize,
}
impl ViewportQueries for Backend {
    type Error = ViewerError;
    fn density_batch(
        &mut self,
        _: &[TraceDensityQuery],
    ) -> Result<Vec<TraceDensityResult>, Self::Error> {
        panic!("detail-only regression must not query density")
    }
    fn density(&mut self, _: &TraceDensityQuery) -> Result<TraceDensityResult, Self::Error> {
        panic!("detail-only regression must not query density")
    }
    fn details(
        &mut self,
        requested: &TraceDensitySource,
        requested_range: TraceTimeRange,
        limit: usize,
        _: Option<EventKey>,
    ) -> Result<EventPage<DetailInput>, Self::Error> {
        assert_eq!(requested, &source());
        assert_eq!(requested_range, range());
        let page = self.pages[self.calls % self.pages.len()].clone();
        self.calls += 1;
        assert!(page.items.len() <= limit);
        Ok(page)
    }
}
fn load(
    pages: &[EventPage<DetailInput>],
) -> (
    Result<Option<AssembledSnapshot>, ViewportFailure<ViewerError>>,
    usize,
) {
    let mut backend = Backend {
        pages: pages.to_vec(),
        calls: 0,
    };
    let result =
        ViewportLoader::default().load(&request(pages.len(), 1), 1.0, &mut backend, &mut || Ok(()));
    (result, backend.calls)
}
fn project_page(
    page: &EventPage<DetailInput>,
    check: &mut Check<'_>,
) -> Result<ProjectedSnapshot, ViewerError> {
    let track = TrackInput {
        descriptor: descriptor(),
        y: 0.0,
        height: 28.0,
        depth_row_count: 1,
        primitives: page
            .items
            .iter()
            .cloned()
            .map(|detail| PrimitiveInput::Detail { detail })
            .collect(),
    };
    project(&request(1, 1).viewport, 1, &[track], 1.0, &quality(), check)
}
fn report(value: serde_json::Value) {
    println!("A25CASE {}", value);
}

#[test]
fn shared_batches_charge_once_and_independent_batches_reach_real_cap() {
    let mut pages = Vec::new();
    // Each real batch retains at least 1000 distinct 1024-byte labels in both
    // presentation and Inspector. Only two selected details keep that entire
    // immutable batch alive; ten independent batches exceed 16MiB on text alone.
    for _ in 0..10 {
        let raw = repository_page(
            (0..1000)
                .map(|i| dto(i, format!("{i:04}{}", "x".repeat(1020)), None))
                .collect(),
        );
        let full = mapped(raw, &mut || Ok(())).unwrap();
        assert!(full.items.iter().all(|d| d.render_facts.is_some()));
        let page = EventPage {
            items: full.items.into_iter().take(2).collect(),
            truncated: false,
            capability_available: true,
            data_quality: full.data_quality,
        };
        pages.push(page);
    }
    let fact = pages[0].items[0].render_facts.as_ref().unwrap();
    let clone = pages[0].clone();
    assert!(std::ptr::eq(
        fact.presentation(),
        clone.items[0].render_facts.as_ref().unwrap().presentation()
    ));
    assert!(!std::ptr::eq(
        fact.presentation(),
        pages[1].items[0]
            .render_facts
            .as_ref()
            .unwrap()
            .presentation()
    ));
    assert_eq!(fact, pages[1].items[0].render_facts.as_ref().unwrap());
    let shared = vec![pages[0].clone(); 10];
    let (shared_result, shared_calls) = load(&shared);
    let shared_snapshot = shared_result.unwrap().unwrap().snapshot;
    assert_eq!(shared_calls, 10);
    let packed =
        HotSnapshot::pack(&shared_snapshot, MAXIMUM_RENDER_FACT_BYTES, &mut || Ok(())).unwrap();
    assert_eq!(packed.primitives.len(), 20);
    let mut first_rejected = None;
    let mut admitted = 0;
    for count in 1..=10 {
        let (result, calls) = load(&pages[..count]);
        assert_eq!(calls, count);
        match result {
            Ok(Some(snapshot)) => {
                assert!(first_rejected.is_none());
                admitted = count;
                HotSnapshot::pack(
                    &snapshot.snapshot,
                    MAXIMUM_RENDER_FACT_BYTES,
                    &mut || Ok(()),
                )
                .unwrap();
            }
            Err(ViewportFailure::Viewer(ViewerError::InputBudgetExceeded)) => {
                first_rejected = Some(count);
                break;
            }
            other => panic!("unexpected actual loader result: {other:?}"),
        }
    }
    let rejected = first_rejected.expect("ten independent actual batches must exceed cap");
    assert_eq!(rejected, admitted + 1);
    assert!(rejected > 1 && rejected <= 10);
    assert_eq!(fact.label().unwrap().len(), 1024);
    report(
        serde_json::json!({"group":"batch_identity", "shared_tracks":10, "shared_details":20,
        "distinct_batches_last_admitted":admitted, "distinct_batches_first_rejected":rejected,
        "real_batch_source_records":1000, "label_utf8_bytes":1024, "shared_hot_retained_bytes":packed.retained_bytes().unwrap(),
        "render_fact_cap":MAXIMUM_RENDER_FACT_BYTES, "backend_handles":0}),
    );
}

fn text(snapshot: &HotSnapshot, offset: u32, length: u32) -> &str {
    std::str::from_utf8(&snapshot.strings[offset as usize..offset as usize + length as usize])
        .unwrap()
}
#[test]
fn unicode_detail_text_deduplicates_and_exact_pack_budget_is_enforced() {
    let unicode = "绘制🦀";
    let distinct = "绘制🦀β";
    assert!(unicode.len() > unicode.chars().count());
    let repeated = mapped(
        repository_page(vec![
            dto(0, unicode.into(), Some(unicode)),
            dto(1, unicode.into(), Some(unicode)),
        ]),
        &mut || Ok(()),
    )
    .unwrap();
    let added = mapped(
        repository_page(vec![
            dto(0, unicode.into(), Some(unicode)),
            dto(1, distinct.into(), Some(unicode)),
        ]),
        &mut || Ok(()),
    )
    .unwrap();
    let repeated_snapshot = project_page(&repeated, &mut || Ok(())).unwrap();
    let snapshot = project_page(&added, &mut || Ok(())).unwrap();
    let repeat_wire = HotSnapshot::pack(&repeated_snapshot, 65536, &mut || Ok(())).unwrap();
    let wire = HotSnapshot::pack(&snapshot, 65536, &mut || Ok(())).unwrap();
    let id_bytes = descriptor().id().len();
    assert_eq!(repeat_wire.strings.len(), id_bytes + unicode.len());
    assert_eq!(
        wire.strings.len(),
        id_bytes + unicode.len() + distinct.len()
    );
    assert_eq!(
        wire.strings.len() - repeat_wire.strings.len(),
        distinct.len()
    );
    let a = wire.primitives[0];
    let b = wire.primitives[1];
    assert_eq!(text(&wire, a.label_offset, a.label_length), unicode);
    assert_eq!(text(&wire, b.label_offset, b.label_length), distinct);
    assert_eq!(a.label_length as usize, unicode.len());
    assert_eq!(b.label_length as usize, distinct.len());
    assert_eq!(
        (a.label_offset, a.label_length),
        (a.name_offset, a.name_length)
    );
    assert_eq!(
        (a.label_offset, a.label_length),
        (a.category_offset, a.category_length)
    );
    assert_eq!(
        (a.label_offset, a.label_length),
        (a.process_name_offset, a.process_name_length)
    );
    assert_eq!(
        (a.label_offset, a.label_length),
        (a.thread_name_offset, a.thread_name_length)
    );
    assert_eq!(
        (a.label_offset, a.label_length),
        (b.inspector_category_offset, b.inspector_category_length)
    );
    let bytes = wire.retained_bytes().unwrap();
    assert!(bytes > wire.strings.len());
    assert_eq!(
        HotSnapshot::pack(&snapshot, bytes, &mut || Ok(()))
            .unwrap()
            .retained_bytes(),
        Some(bytes)
    );
    assert_eq!(
        HotSnapshot::pack(&snapshot, bytes - 1, &mut || Ok(())).unwrap_err(),
        ViewerError::InputBudgetExceeded
    );
    let wide = "界".repeat(1366);
    assert!(wide.chars().count() < 4096 && wide.len() > 4096);
    assert_eq!(
        mapped(repository_page(vec![dto(0, wide, None)]), &mut || Ok(())).unwrap_err(),
        ViewerError::InputBudgetExceeded
    );
    assert!(
        mapped(
            repository_page(vec![dto(0, "x".repeat(1366), None)]),
            &mut || Ok(())
        )
        .is_ok()
    );
    report(
        serde_json::json!({"group":"utf8_exact_budget", "repeated_utf8_bytes":unicode.len(),"distinct_utf8_bytes":distinct.len(),
        "repeated_wire_strings":repeat_wire.strings.len(),"distinct_wire_strings":wire.strings.len(),"exact_hot_retained_bytes":bytes,
        "exact_limit_passed":true,"exact_minus_one":"InputBudgetExceeded", "unicode_source_byte_cap":"InputBudgetExceeded",
        "retained_scope":"HotSnapshot struct and actual Vec capacities; RenderBatch/Arc belongs to loader's separate 16MiB facts cap"}),
    );
}

fn all_checkpoints<T: std::fmt::Debug>(
    mut run: impl FnMut(&mut Check<'_>) -> Result<T, ViewerError>,
) -> (usize, usize) {
    let mut total = 0;
    run(&mut || {
        total += 1;
        Ok(())
    })
    .unwrap();
    assert!(total > 0 && total <= 4096);
    let mut failures = 0;
    for error in [ViewerError::Cancelled, ViewerError::DeadlineReached] {
        for point in 1..=total {
            let mut calls = 0;
            let result = run(&mut || {
                calls += 1;
                if calls == point { Err(error) } else { Ok(()) }
            });
            assert_eq!(result.unwrap_err(), error);
            assert_eq!(calls, point);
            failures += 1;
            run(&mut || Ok(())).unwrap();
        }
    }
    (total, failures)
}
#[test]
fn every_new_facts_projection_and_pack_checkpoint_is_transactional_and_recovers() {
    let page = mapped(tiny_page(), &mut || Ok(())).unwrap();
    let original = project_page(&page, &mut || Ok(())).unwrap();
    let retained = HotSnapshot::pack(&original, 65536, &mut || Ok(())).unwrap();
    let original_text = retained.strings.clone();
    let map_counts = all_checkpoints(|check| mapped(tiny_page(), check));
    let project_counts = all_checkpoints(|check| project_page(&page, check));
    let pack_counts = all_checkpoints(|check| HotSnapshot::pack(&original, 65536, check));
    let mut baseline_loader = ViewportLoader::default();
    let mut baseline_backend = Backend {
        pages: vec![page.clone()],
        calls: 0,
    };
    baseline_loader
        .load(&request(1, 1), 1.0, &mut baseline_backend, &mut || Ok(()))
        .unwrap();
    let mut load_checkpoints = 0;
    baseline_loader
        .load(&request(1, 2), 1.0, &mut baseline_backend, &mut || {
            load_checkpoints += 1;
            Ok(())
        })
        .unwrap();
    assert!(load_checkpoints > 0 && load_checkpoints <= 4096);
    let mut loader_failures = 0;
    let mut backend_calls = 0;
    for error in [ViewerError::Cancelled, ViewerError::DeadlineReached] {
        for point in 1..=load_checkpoints {
            let mut loader = ViewportLoader::default();
            let mut backend = Backend {
                pages: vec![page.clone()],
                calls: 0,
            };
            let old = loader
                .load(&request(1, 1), 1.0, &mut backend, &mut || Ok(()))
                .unwrap()
                .unwrap();
            let mut calls = 0;
            let failed = loader.load(&request(1, 2), 1.0, &mut backend, &mut || {
                calls += 1;
                if calls == point { Err(error) } else { Ok(()) }
            });
            assert!(matches!(failed, Err(ViewportFailure::Viewer(e)) if e == error));
            assert_eq!(calls, point);
            let fresh = loader
                .load(&request(1, 3), 1.0, &mut backend, &mut || Ok(()))
                .unwrap()
                .unwrap();
            assert_eq!(fresh.snapshot.viewport().generation(), 3);
            let old_wire = HotSnapshot::pack(&old.snapshot, 65536, &mut || Ok(())).unwrap();
            assert_eq!(old_wire.strings, original_text);
            assert_eq!(retained.strings, original_text);
            assert_eq!(
                page.items[0].render_facts.as_ref().unwrap().label(),
                Some("绘制🦀")
            );
            backend_calls += backend.calls;
            loader_failures += 1;
        }
    }
    assert_eq!(retained.strings, original_text);
    report(
        serde_json::json!({"group":"cancel_deadline", "map_checkpoints":map_counts.0,"map_failures":map_counts.1,
        "project_checkpoints":project_counts.0,"project_failures":project_counts.1,"pack_checkpoints":pack_counts.0,"pack_failures":pack_counts.1,
        "loader_checkpoints":load_checkpoints,"loader_failures":loader_failures,"actual_backend_calls":backend_calls,
        "each_failure_recovered_with_fresh_request":true,"old_facts_and_wire_still_readable":true,"repository_handles":0}),
    );
}
