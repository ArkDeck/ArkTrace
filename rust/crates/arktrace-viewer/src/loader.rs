use crate::{
    AssembledSnapshot, CachedDepth, Check, DetailInput, DetailPreference, LanePages, Lod,
    MAXIMUM_DENSITY_BATCH, MAXIMUM_PRIMITIVES, MAXIMUM_TRACKS, QueryPlan, ViewerError,
    ViewportRequest, assemble, choose_lod, density_bucket_limit, machine, plan, validate_scale,
};
use arktrace_contract::{
    EventKey, EventPage, TraceDensityIdentity, TraceDensityQuery, TraceDensityResult,
    TraceDensitySource, TraceTimeRange,
};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, VecDeque},
    mem::size_of,
    sync::Arc,
};

pub const MAXIMUM_CACHED_DENSITIES: usize = 64;
pub const MAXIMUM_CACHED_DENSITY_BUCKETS: usize = 200_000;
pub const MAXIMUM_CACHED_DENSITY_BYTES: usize = 64 * 1024 * 1024;

/// Host-owned typed queries. Implementations retain their connection and error
/// identity; the Viewer contains no database, filesystem or executor.
pub trait ViewportQueries {
    type Error;
    fn density_batch(
        &mut self,
        queries: &[TraceDensityQuery],
    ) -> Result<Vec<TraceDensityResult>, Self::Error>;
    fn density(&mut self, query: &TraceDensityQuery) -> Result<TraceDensityResult, Self::Error>;
    fn details(
        &mut self,
        source: &TraceDensitySource,
        range: TraceTimeRange,
        limit: usize,
        focused: Option<EventKey>,
    ) -> Result<EventPage<DetailInput>, Self::Error>;
}

#[derive(Debug)]
pub enum ViewportFailure<E> {
    Viewer(ViewerError),
    Repository(E),
}
impl<E> From<ViewerError> for ViewportFailure<E> {
    fn from(value: ViewerError) -> Self {
        Self::Viewer(value)
    }
}
#[derive(Clone, Debug)]
struct CacheEntry {
    query: TraceDensityQuery,
    result: Arc<TraceDensityResult>,
    bytes: usize,
}
/// One instance belongs to one immutable trace session. UI callers do not
/// supply depth/cache contents, and replacing a session replaces this state.
#[derive(Default, Debug)]
pub struct ViewportLoader {
    latest_generation: u64,
    depths: BTreeMap<String, usize>,
    densities: VecDeque<CacheEntry>,
    cached_buckets: usize,
    cached_bytes: usize,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ViewportCacheUsage {
    pub depth_entries: usize,
    pub density_entries: usize,
    pub density_buckets: usize,
    pub density_bytes: usize,
}
impl ViewportLoader {
    pub fn invalidate(&mut self, generation: u64) {
        self.latest_generation = self.latest_generation.max(generation);
    }
    pub fn reset_layout_cache(&mut self) {
        self.depths.clear();
        self.densities.clear();
        self.cached_buckets = 0;
        self.cached_bytes = 0;
    }
    pub fn cache_usage(&self) -> ViewportCacheUsage {
        ViewportCacheUsage {
            depth_entries: self.depths.len(),
            density_entries: self.densities.len(),
            density_buckets: self.cached_buckets,
            density_bytes: self.cached_bytes,
        }
    }
    pub fn load<R: ViewportQueries>(
        &mut self,
        request: &ViewportRequest,
        backing_scale: f64,
        repository: &mut R,
        check: &mut Check<'_>,
    ) -> Result<Option<AssembledSnapshot>, ViewportFailure<R::Error>> {
        check()?;
        validate_scale(backing_scale)?;
        request.effective_budget()?;
        self.invalidate(request.generation);
        if request.generation != self.latest_generation {
            return Ok(None);
        }
        let depths = self
            .depths
            .iter()
            .map(|(track_id, rows)| CachedDepth {
                track_id: track_id.clone(),
                rows: *rows,
            })
            .collect::<Vec<_>>();
        let plan = plan(request, &depths, check)?;
        let prefetched = self.prefetch(&plan.density_prefetch, repository, check)?;
        let result = execute(
            request,
            &depths,
            &plan,
            prefetched,
            backing_scale,
            repository,
            check,
        )?;
        check()?;
        for entry in &result.updated_depths {
            self.depths.insert(entry.track_id.clone(), entry.rows);
        }
        // Request tracks are bounded, but a client can cycle arbitrary IDs
        // over a session lifetime. Active offscreen heights survive pruning.
        if self.depths.len() > MAXIMUM_TRACKS {
            let active = request
                .tracks
                .iter()
                .map(|t| t.id())
                .collect::<std::collections::BTreeSet<_>>();
            self.depths.retain(|id, _| active.contains(id));
        }
        Ok(Some(result))
    }
    fn lookup(&mut self, query: &TraceDensityQuery) -> Option<Arc<TraceDensityResult>> {
        let index = self.densities.iter().position(|e| e.query == *query)?;
        let entry = self.densities.remove(index)?;
        let result = entry.result.clone();
        self.densities.push_back(entry);
        Some(result)
    }
    fn cache(&mut self, query: TraceDensityQuery, result: Arc<TraceDensityResult>) {
        let Some(bytes) = retained_bytes(&result) else {
            return;
        };
        if result.buckets.len() > MAXIMUM_CACHED_DENSITY_BUCKETS
            || bytes > MAXIMUM_CACHED_DENSITY_BYTES
        {
            return;
        }
        if let Some(index) = self.densities.iter().position(|e| e.query == query) {
            let old = self.densities.remove(index).expect("located cache entry");
            self.cached_buckets -= old.result.buckets.len();
            self.cached_bytes -= old.bytes;
        }
        self.cached_buckets += result.buckets.len();
        self.cached_bytes += bytes;
        self.densities.push_back(CacheEntry {
            query,
            result,
            bytes,
        });
        while self.densities.len() > MAXIMUM_CACHED_DENSITIES
            || self.cached_buckets > MAXIMUM_CACHED_DENSITY_BUCKETS
            || self.cached_bytes > MAXIMUM_CACHED_DENSITY_BYTES
        {
            if let Some(old) = self.densities.pop_front() {
                self.cached_buckets -= old.result.buckets.len();
                self.cached_bytes -= old.bytes;
            }
        }
    }
    fn prefetch<R: ViewportQueries>(
        &mut self,
        queries: &[TraceDensityQuery],
        repository: &mut R,
        check: &mut Check<'_>,
    ) -> Result<Vec<Arc<TraceDensityResult>>, ViewportFailure<R::Error>> {
        let mut ordered = vec![None; queries.len()];
        let mut misses = Vec::new();
        for (i, query) in queries.iter().enumerate() {
            crate::checkpoint(i, check)?;
            if let Some(hit) = self.lookup(query) {
                ordered[i] = Some(hit);
            } else {
                misses.push((i, query.clone()));
            }
        }
        for chunk in misses.chunks(MAXIMUM_DENSITY_BATCH) {
            check()?;
            let batch = chunk.iter().map(|(_, q)| q.clone()).collect::<Vec<_>>();
            let results = repository
                .density_batch(&batch)
                .map_err(ViewportFailure::Repository)?;
            check()?;
            if results.len() != chunk.len() {
                return Err(ViewerError::InvalidEvidence.into());
            }
            for (offset, ((index, query), result)) in chunk.iter().zip(results).enumerate() {
                crate::checkpoint(offset, check)?;
                validate_density(query, &result)?;
                let result = Arc::new(result);
                self.cache(query.clone(), result.clone());
                ordered[*index] = Some(result);
            }
        }
        ordered
            .into_iter()
            .map(|v| v.ok_or(ViewerError::InvalidEvidence.into()))
            .collect()
    }
}
fn retained_bytes(result: &TraceDensityResult) -> Option<usize> {
    let mut bytes = size_of::<TraceDensityResult>().checked_add(
        result
            .buckets
            .capacity()
            .checked_mul(size_of::<arktrace_contract::TraceDensityBucket>())?,
    )?;
    bytes = bytes.checked_add(
        result
            .data_quality
            .warnings
            .capacity()
            .checked_mul(size_of::<arktrace_contract::QualityIssue>())?,
    )?;
    for bucket in &result.buckets {
        if let Some(
            TraceDensityIdentity::Name { name } | TraceDensityIdentity::ThreadState { state: name },
        ) = &bucket.dominant
        {
            bytes = bytes.checked_add(name.capacity())?;
        }
    }
    for issue in &result.data_quality.warnings {
        bytes = bytes
            .checked_add(issue.scope.as_ref().map_or(0, String::capacity))?
            .checked_add(issue.message.as_ref().map_or(0, String::capacity))?;
    }
    Some(bytes)
}
fn validate_density(
    query: &TraceDensityQuery,
    result: &TraceDensityResult,
) -> Result<(), ViewerError> {
    if result.buckets.len() > query.bucket_count
        || (!result.capability_available && !result.buckets.is_empty())
    {
        return Err(ViewerError::InvalidEvidence);
    }
    machine(&result.data_quality)?;
    for bucket in &result.buckets {
        if bucket.range.is_instant()
            || bucket.range.start_ns() < query.range.start_ns()
            || bucket.range.end_ns() > query.range.end_ns()
            || bucket.event_count < 0
        {
            return Err(ViewerError::InvalidEvidence);
        }
    }
    Ok(())
}
fn execute<R: ViewportQueries>(
    request: &ViewportRequest,
    depths: &[CachedDepth],
    plan: &QueryPlan,
    prefetched: Vec<Arc<TraceDensityResult>>,
    scale: f64,
    repository: &mut R,
    check: &mut Check<'_>,
) -> Result<AssembledSnapshot, ViewportFailure<R::Error>> {
    let mut densities = plan
        .queried_indices
        .iter()
        .zip(prefetched)
        .map(|(index, result)| (*index, result))
        .collect::<BTreeMap<_, _>>();
    let mut details = BTreeMap::new();
    let mut fact_batches = std::collections::BTreeSet::new();
    let mut fact_bytes = 0;
    let mut remaining = plan.maximum_primitives;
    let mut queried_remaining = plan.queried_indices.len();
    let mut budgets = Vec::with_capacity(plan.lanes.len());
    for (index, lane) in plan.lanes.iter().enumerate() {
        crate::checkpoint(index, check)?;
        let budget = if lane.queried {
            plan.lane_budget(remaining, queried_remaining)?
        } else {
            0
        };
        budgets.push(budget);
        let mut count = 0;
        if budget > 0 {
            if request.preference != DetailPreference::Detail && !densities.contains_key(&index) {
                let query = TraceDensityQuery {
                    source: lane.source.clone(),
                    range: request.viewport.range(),
                    bucket_count: density_bucket_limit(request.pixel_width, budget)?,
                };
                let density = repository
                    .density(&query)
                    .map_err(ViewportFailure::Repository)?;
                check()?;
                validate_density(&query, &density)?;
                densities.insert(index, Arc::new(density));
            }
            let decision = choose_lod(
                request.preference,
                request.pixel_width,
                budget,
                densities.get(&index).map(|v| v.as_ref()),
                check,
            )?;
            match decision.lod {
                Lod::Unavailable => {}
                Lod::Density => {
                    count = densities[&index].buckets.len().min(decision.bucket_limit);
                }
                Lod::Detail => {
                    let page = repository
                        .details(
                            &lane.source,
                            request.viewport.range(),
                            budget,
                            request.focused_event_key,
                        )
                        .map_err(ViewportFailure::Repository)?;
                    if page.items.len() > budget {
                        return Err(ViewerError::InputBudgetExceeded.into());
                    }
                    count = page.items.len();
                    crate::render_facts::charge_render_facts(
                        page.items.iter(),
                        &mut fact_batches,
                        &mut fact_bytes,
                    )?;
                    details.insert(index, page);
                }
            }
        }
        remaining = remaining
            .checked_sub(count)
            .ok_or(ViewerError::InvalidEvidence)?;
        if lane.queried {
            queried_remaining -= 1;
        }
    }
    let pages = plan
        .queried_indices
        .iter()
        .map(|index| LanePages {
            expanded_index: *index,
            detail: details.get(index),
            density: densities.get(index).map(|v| v.as_ref()),
        })
        .collect::<Vec<_>>();
    let result = assemble(request, depths, &pages, scale, check)?;
    if result.budgets != budgets {
        return Err(ViewerError::InvalidEvidence.into());
    }
    Ok(result)
}

/// Prefix the independently queried focused row and remove duplicates while
/// keeping the original page's source truncation/quality, as the Swift loader.
pub fn include_focused_detail(
    mut page: EventPage<DetailInput>,
    focused: Option<DetailInput>,
    limit: usize,
) -> Result<EventPage<DetailInput>, ViewerError> {
    if !(1..=MAXIMUM_PRIMITIVES).contains(&limit) || page.items.len() > limit {
        return Err(ViewerError::InputBudgetExceeded);
    }
    if let Some(focused) = focused {
        page.items.retain(|d| d.event_key != focused.event_key);
        page.items.insert(0, focused);
        page.items.truncate(limit);
    }
    Ok(page)
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DensityResolutionRequest {
    pub source: TraceDensitySource,
    pub bucket: TraceTimeRange,
    pub time_ns: i64,
}
impl DensityResolutionRequest {
    pub fn validate(&self) -> Result<(), ViewerError> {
        if self.bucket.is_instant()
            || self.time_ns < self.bucket.start_ns()
            || self.time_ns > self.bucket.end_ns()
        {
            return Err(ViewerError::InvalidRequest);
        }
        Ok(())
    }
}
/// Press-only bounded lookup. Hover/hit geometry stays on the retained
/// immutable snapshot and never invokes this repository operation.
pub fn resolve_density_event<R: ViewportQueries>(
    request: &DensityResolutionRequest,
    repository: &mut R,
    check: &mut Check<'_>,
) -> Result<Option<DetailInput>, ViewportFailure<R::Error>> {
    request.validate()?;
    check()?;
    let mut selected = None;
    if let Some(end) = request.time_ns.checked_add(1) {
        let range =
            TraceTimeRange::query(request.time_ns, end).map_err(|_| ViewerError::InvalidRequest)?;
        let page = repository
            .details(&request.source, range, 64, None)
            .map_err(ViewportFailure::Repository)?;
        validate_resolution_page(&page, 64)?;
        if let Some(key) = crate::resolve_candidate(request.time_ns, &page.items, check)? {
            selected = page.items.into_iter().find(|i| i.event_key == key);
        }
    }
    if selected.is_none() {
        let page = repository
            .details(&request.source, request.bucket, 512, None)
            .map_err(ViewportFailure::Repository)?;
        validate_resolution_page(&page, 512)?;
        if let Some(key) = crate::resolve_candidate(request.time_ns, &page.items, check)? {
            selected = page.items.into_iter().find(|i| i.event_key == key);
        }
    }
    check()?;
    Ok(selected)
}
fn validate_resolution_page(
    page: &EventPage<DetailInput>,
    limit: usize,
) -> Result<(), ViewerError> {
    if page.items.len() > limit {
        return Err(ViewerError::InputBudgetExceeded);
    }
    if !page.capability_available && (!page.items.is_empty() || page.truncated) {
        return Err(ViewerError::InvalidEvidence);
    }
    machine(&page.data_quality)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use arktrace_contract::{DataQuality, QualityStatus, TraceDensityBucket};
    fn query(cpu: i64) -> TraceDensityQuery {
        TraceDensityQuery {
            source: TraceDensitySource::Cpu { cpu },
            range: TraceTimeRange::query(0, 1).unwrap(),
            bucket_count: 1,
        }
    }
    fn result(capacity: usize, name_capacity: usize) -> Arc<TraceDensityResult> {
        let mut name = String::new();
        name.reserve_exact(name_capacity);
        let mut buckets = Vec::with_capacity(capacity);
        buckets.push(TraceDensityBucket {
            range: TraceTimeRange::query(0, 1).unwrap(),
            event_count: 1,
            occupied_ns: None,
            utilization: None,
            dominant: Some(TraceDensityIdentity::Name { name }),
        });
        Arc::new(TraceDensityResult {
            buckets,
            capability_available: true,
            data_quality: DataQuality::machine(QualityStatus::Ok, vec![]).unwrap(),
        })
    }
    #[test]
    fn cache_bounds_charge_retained_vector_and_string_capacity_and_use_lru() {
        let mut loader = ViewportLoader::default();
        loader.cache(query(0), result(1, 24 * 1024 * 1024));
        loader.cache(query(1), result(1, 24 * 1024 * 1024));
        assert!(loader.lookup(&query(0)).is_some());
        loader.cache(query(2), result(1, 24 * 1024 * 1024));
        assert!(loader.cache_usage().density_bytes <= MAXIMUM_CACHED_DENSITY_BYTES);
        assert!(loader.lookup(&query(0)).is_some());
        assert!(loader.lookup(&query(1)).is_none());
        assert_eq!(loader.cache_usage().density_entries, 2);
        // Short logical length does not hide a huge retained vector capacity.
        loader.cache(query(3), result(1_000_000, 0));
        assert!(loader.lookup(&query(3)).is_none());
        loader.reset_layout_cache();
        assert_eq!(loader.cache_usage().density_bytes, 0);
        assert_eq!(loader.cache_usage().density_buckets, 0);
    }
    #[test]
    fn cache_total_bucket_limit_applies_before_the_entry_limit() {
        let mut loader = ViewportLoader::default();
        for cpu in 0..33 {
            let mut value = (*result(1, 0)).clone();
            value.buckets = vec![value.buckets[0].clone(); 6250];
            loader.cache(query(cpu), Arc::new(value));
        }
        assert_eq!(loader.cache_usage().density_entries, 32);
        assert_eq!(loader.cache_usage().density_buckets, 200_000);
        assert!(loader.lookup(&query(0)).is_none());
        assert!(loader.lookup(&query(32)).is_some());
    }
}
