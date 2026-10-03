#[allow(dead_code)]
mod common;
use arktrace_contract::*;
use arktrace_viewer::*;
use std::collections::VecDeque;

#[derive(Default)]
struct Repository {
    batches: Vec<Vec<TraceDensityQuery>>,
    scalar: Vec<TraceDensityQuery>,
    calls: Vec<(TraceDensitySource, TraceTimeRange, usize, Option<EventKey>)>,
    pages: VecDeque<EventPage<DetailInput>>,
    unavailable: bool,
    malformed_batch: bool,
    cancel_after_query: Option<std::sync::Arc<std::sync::atomic::AtomicBool>>,
}
fn page(items: Vec<DetailInput>) -> EventPage<DetailInput> {
    EventPage {
        items,
        truncated: false,
        capability_available: true,
        data_quality: common::quality(),
    }
}
impl ViewportQueries for Repository {
    type Error = &'static str;
    fn density_batch(
        &mut self,
        queries: &[TraceDensityQuery],
    ) -> Result<Vec<TraceDensityResult>, Self::Error> {
        self.batches.push(queries.to_vec());
        if let Some(flag) = &self.cancel_after_query {
            flag.store(true, std::sync::atomic::Ordering::Relaxed);
        }
        if self.malformed_batch {
            return Ok(vec![]);
        }
        Ok(queries
            .iter()
            .map(|q| TraceDensityResult {
                buckets: if self.unavailable {
                    vec![]
                } else {
                    vec![common::bucket(q.range.start_ns(), q.range.end_ns(), 10)]
                },
                capability_available: !self.unavailable,
                data_quality: common::quality(),
            })
            .collect())
    }
    fn density(&mut self, query: &TraceDensityQuery) -> Result<TraceDensityResult, Self::Error> {
        self.scalar.push(query.clone());
        Ok(TraceDensityResult {
            buckets: vec![common::bucket(
                query.range.start_ns(),
                query.range.end_ns(),
                10,
            )],
            capability_available: true,
            data_quality: common::quality(),
        })
    }
    fn details(
        &mut self,
        source: &TraceDensitySource,
        range: TraceTimeRange,
        limit: usize,
        focused: Option<EventKey>,
    ) -> Result<EventPage<DetailInput>, Self::Error> {
        self.calls.push((source.clone(), range, limit, focused));
        Ok(self.pages.pop_front().unwrap_or_else(|| page(vec![])))
    }
}
fn generation(request: &mut ViewportRequest, generation: u64, height: f64, offset: f64) {
    request.generation = generation;
    request.viewport = Viewport::new(
        request.viewport.range(),
        request.viewport.width_points(),
        height,
        offset,
        generation,
    )
    .unwrap();
}
#[test]
fn repeated_viewport_reuses_density_but_range_source_and_bucket_count_do_not_alias() {
    let mut loader = ViewportLoader::default();
    let mut repo = Repository::default();
    let mut request = common::request(1, 100, DetailPreference::Density);
    loader
        .load(&request, 2.0, &mut repo, &mut || Ok(()))
        .unwrap();
    generation(&mut request, 2, 80.0, 0.0);
    loader
        .load(&request, 2.0, &mut repo, &mut || Ok(()))
        .unwrap();
    assert_eq!(repo.batches.len(), 1);
    request.pixel_width = 1600;
    loader
        .load(&request, 2.0, &mut repo, &mut || Ok(()))
        .unwrap();
    request.tracks[0] = common::descriptor(1);
    loader
        .load(&request, 2.0, &mut repo, &mut || Ok(()))
        .unwrap();
    request.viewport = Viewport::new(common::range(1, 1001), 200.0, 80.0, 0.0, 2).unwrap();
    loader
        .load(&request, 2.0, &mut repo, &mut || Ok(()))
        .unwrap();
    assert_eq!(repo.batches.len(), 4);
    assert_eq!(loader.cache_usage().density_entries, 4);
}
#[test]
fn warm_hits_are_removed_before_misses_are_chunked_and_lru_is_bounded() {
    let mut loader = ViewportLoader::default();
    let mut repo = Repository::default();
    let mut request = common::request(30, 20_000, DetailPreference::Density);
    request.pixel_width = 160;
    generation(&mut request, 1, 10_000.0, 0.0);
    loader
        .load(&request, 1.0, &mut repo, &mut || Ok(()))
        .unwrap();
    repo.batches.clear();
    request.tracks = (0..70).map(common::descriptor).collect();
    generation(&mut request, 2, 10_000.0, 0.0);
    loader
        .load(&request, 1.0, &mut repo, &mut || Ok(()))
        .unwrap();
    assert_eq!(
        repo.batches.iter().map(Vec::len).collect::<Vec<_>>(),
        [32, 8]
    );
    assert_eq!(
        repo.batches[0][0].source,
        TraceDensitySource::Cpu { cpu: 30 }
    );
    assert_eq!(loader.cache_usage().density_entries, 64);
}
#[test]
fn unsupported_density_is_cacheable_and_never_dispatches_detail() {
    let mut loader = ViewportLoader::default();
    let mut repo = Repository {
        unavailable: true,
        ..Default::default()
    };
    let mut request = common::request(1, 16, DetailPreference::Automatic);
    let first = loader
        .load(&request, 2.0, &mut repo, &mut || Ok(()))
        .unwrap()
        .unwrap();
    generation(&mut request, 2, 80.0, 0.0);
    loader
        .load(&request, 2.0, &mut repo, &mut || Ok(()))
        .unwrap();
    assert_eq!(repo.batches.len(), 1);
    assert!(repo.calls.is_empty());
    assert!(first.snapshot.tracks()[0].primitives.is_empty());
}
#[test]
fn stale_generation_and_reset_preserve_generation_arbitration_without_queries() {
    let mut loader = ViewportLoader::default();
    let mut repo = Repository::default();
    let request = common::request(1, 16, DetailPreference::Density);
    loader.invalidate(2);
    loader.reset_layout_cache();
    assert!(
        loader
            .load(&request, 1.0, &mut repo, &mut || Ok(()))
            .unwrap()
            .is_none()
    );
    assert!(repo.batches.is_empty());
    assert_eq!(loader.cache_usage().depth_entries, 0);
}
#[test]
fn cancelled_batch_never_enters_cache_and_backend_failure_keeps_its_identity() {
    use std::sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    };
    let flag = Arc::new(AtomicBool::new(false));
    let mut loader = ViewportLoader::default();
    let mut repo = Repository {
        cancel_after_query: Some(flag.clone()),
        ..Default::default()
    };
    let request = common::request(1, 16, DetailPreference::Density);
    let result = loader.load(&request, 1.0, &mut repo, &mut || {
        if flag.load(Ordering::Relaxed) {
            Err(ViewerError::Cancelled)
        } else {
            Ok(())
        }
    });
    assert!(matches!(
        result,
        Err(ViewportFailure::Viewer(ViewerError::Cancelled))
    ));
    assert_eq!(loader.cache_usage().density_entries, 0);
    assert_eq!(loader.cache_usage().depth_entries, 0);
    struct Failing;
    impl ViewportQueries for Failing {
        type Error = &'static str;
        fn density_batch(
            &mut self,
            _: &[TraceDensityQuery],
        ) -> Result<Vec<TraceDensityResult>, Self::Error> {
            Err("store-closed")
        }
        fn density(&mut self, _: &TraceDensityQuery) -> Result<TraceDensityResult, Self::Error> {
            Err("store-closed")
        }
        fn details(
            &mut self,
            _: &TraceDensitySource,
            _: TraceTimeRange,
            _: usize,
            _: Option<EventKey>,
        ) -> Result<EventPage<DetailInput>, Self::Error> {
            Err("store-closed")
        }
    }
    assert!(matches!(
        loader.load(&request, 1.0, &mut Failing, &mut || Ok(())),
        Err(ViewportFailure::Repository("store-closed"))
    ));
}
#[test]
fn short_batch_is_rejected_and_zero_fair_share_uses_bounded_scalar_queries() {
    let mut loader = ViewportLoader::default();
    let mut repo = Repository {
        malformed_batch: true,
        ..Default::default()
    };
    let request = common::request(1, 16, DetailPreference::Density);
    assert!(matches!(
        loader.load(&request, 1.0, &mut repo, &mut || Ok(())),
        Err(ViewportFailure::Viewer(ViewerError::InvalidEvidence))
    ));
    let mut repo = Repository::default();
    let mut request = common::request(10, 2, DetailPreference::Density);
    generation(&mut request, 2, 10_000.0, 0.0);
    let result = loader
        .load(&request, 1.0, &mut repo, &mut || Ok(()))
        .unwrap()
        .unwrap();
    assert!(repo.batches.is_empty());
    assert_eq!(repo.scalar.len(), 2);
    assert!(repo.scalar.iter().all(|q| q.bucket_count == 1));
    assert_eq!(
        result
            .snapshot
            .tracks()
            .iter()
            .map(|t| t.primitives.len())
            .sum::<usize>(),
        2
    );
}
#[test]
fn nested_depth_survives_offscreen_and_reset_removes_its_height() {
    let mut loader = ViewportLoader::default();
    let mut repo = Repository::default();
    let mut request = common::request(2, 16, DetailPreference::Detail);
    repo.pages.push_back(page(vec![common::detail(
        1,
        0,
        500,
        4,
        DetailStyle::Accent,
    )]));
    let first = loader
        .load(&request, 2.0, &mut repo, &mut || Ok(()))
        .unwrap()
        .unwrap();
    assert_eq!(first.snapshot.tracks()[0].depth_row_count, 5);
    generation(&mut request, 2, 20.0, 10_000.0);
    let offscreen = loader
        .load(&request, 2.0, &mut repo, &mut || Ok(()))
        .unwrap()
        .unwrap();
    assert_eq!(
        offscreen.snapshot.tracks()[0].height,
        first.snapshot.tracks()[0].height
    );
    assert_eq!(repo.calls.len(), 2); // no offscreen SQL
    loader.reset_layout_cache();
    let reset = loader
        .load(&request, 2.0, &mut repo, &mut || Ok(()))
        .unwrap()
        .unwrap();
    assert_eq!(reset.snapshot.tracks()[0].depth_row_count, 1);
}
#[test]
fn focus_prefix_deduplicates_and_keeps_the_original_quality_and_truncation() {
    let a = common::detail(7, 0, 800, 2, DetailStyle::Accent);
    let b = common::detail(8, 5, 20, 0, DetailStyle::Accent);
    let c = common::detail(9, 10, 30, 0, DetailStyle::Accent);
    let mut original = page(vec![b.clone(), a.clone(), c]);
    original.truncated = true;
    let quality = original.data_quality.clone();
    let result = include_focused_detail(original, Some(a.clone()), 2);
    assert_eq!(result.unwrap_err(), ViewerError::InputBudgetExceeded);
    let mut original = page(vec![b, a.clone()]);
    original.truncated = true;
    let result = include_focused_detail(original, Some(a), 2).unwrap();
    assert_eq!(
        result
            .items
            .iter()
            .map(|d| d.event_key.row_id)
            .collect::<Vec<_>>(),
        [7, 8]
    );
    assert!(result.truncated);
    assert_eq!(result.data_quality, quality);
}
#[test]
fn density_press_prefers_covering_then_fallback_with_canonical_rank_and_query_caps() {
    let request = DensityResolutionRequest {
        source: TraceDensitySource::Cpu { cpu: 0 },
        bucket: common::range(0, 1000),
        time_ns: 300,
    };
    let mut repo = Repository::default();
    repo.pages.push_back(page(vec![
        common::detail(9, 250, 500, 0, DetailStyle::Running),
        common::detail(8, 0, 900, 0, DetailStyle::Running),
        common::detail(7, 0, 900, 0, DetailStyle::Running),
    ]));
    let chosen = resolve_density_event(&request, &mut repo, &mut || Ok(()))
        .unwrap()
        .unwrap();
    assert_eq!(chosen.event_key.row_id, 7);
    assert_eq!(repo.calls.len(), 1);
    assert_eq!(
        (repo.calls[0].1, repo.calls[0].2),
        (common::range(300, 301), 64)
    );
    let mut repo = Repository::default();
    repo.pages.push_back(page(vec![]));
    repo.pages.push_back(page(vec![
        common::detail(1, 250, 290, 0, DetailStyle::Running),
        common::detail(2, 310, 700, 0, DetailStyle::Running),
    ]));
    assert_eq!(
        resolve_density_event(&request, &mut repo, &mut || Ok(()))
            .unwrap()
            .unwrap()
            .event_key
            .row_id,
        2
    );
    assert_eq!((repo.calls[1].1, repo.calls[1].2), (request.bucket, 512));
    assert!(repo.calls.iter().all(|c| c.3.is_none()));
}
#[test]
fn density_press_at_int64_max_skips_overflowed_covering_query_and_rejects_bad_pages() {
    let request = DensityResolutionRequest {
        source: TraceDensitySource::Cpu { cpu: 0 },
        bucket: common::range(i64::MAX - 100, i64::MAX),
        time_ns: i64::MAX,
    };
    let mut repo = Repository::default();
    repo.pages.push_back(page(vec![common::detail(
        3,
        i64::MAX - 100,
        i64::MAX,
        0,
        DetailStyle::Running,
    )]));
    assert_eq!(
        resolve_density_event(&request, &mut repo, &mut || Ok(()))
            .unwrap()
            .unwrap()
            .event_key
            .row_id,
        3
    );
    assert_eq!(repo.calls.len(), 1);
    assert_eq!(repo.calls[0].2, 512);
    let mut repo = Repository::default();
    let mut bad = page(vec![common::detail(3, 0, 1, 0, DetailStyle::Running)]);
    bad.capability_available = false;
    repo.pages.push_back(bad);
    assert!(matches!(
        resolve_density_event(&request, &mut repo, &mut || Ok(())),
        Err(ViewportFailure::Viewer(ViewerError::InvalidEvidence))
    ));
    let mut repo = Repository::default();
    repo.pages.push_back(page(vec![
        common::detail(3, 0, 1, 0, DetailStyle::Running);
        513
    ]));
    assert!(matches!(
        resolve_density_event(&request, &mut repo, &mut || Ok(())),
        Err(ViewportFailure::Viewer(ViewerError::InputBudgetExceeded))
    ));
}
