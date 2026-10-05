use crate::{
    Check, DetailInput, MAXIMUM_PRIMITIVES, MAXIMUM_TRACKS, Point, PrimitiveInput, RULER_HEIGHT,
    Rect, TrackDescriptor, TrackInput, ViewerError, Viewport, checkpoint, is_visible, machine,
    primitive_frame, validate_scale, validate_track_geometry,
};
use arktrace_contract::{DataQuality, EventKey, TraceDensitySource, TraceTimeRange};
use serde::Serialize;
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectedPrimitive {
    pub input: PrimitiveInput,
    pub visible: bool,
    pub frame: Option<Rect>,
}
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectedTrack {
    pub descriptor: TrackDescriptor,
    pub y: f64,
    pub height: f64,
    pub depth_row_count: usize,
    pub primitives: Vec<ProjectedPrimitive>,
}
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectedSnapshot {
    viewport: Viewport,
    source_generation: u64,
    backing_scale: f64,
    tracks: Vec<ProjectedTrack>,
    data_quality: DataQuality,
}
impl ProjectedSnapshot {
    pub fn viewport(&self) -> &Viewport {
        &self.viewport
    }
    pub fn tracks(&self) -> &[ProjectedTrack] {
        &self.tracks
    }
    pub fn data_quality(&self) -> &DataQuality {
        &self.data_quality
    }
    pub fn source_generation(&self) -> u64 {
        self.source_generation
    }
    pub fn backing_scale(&self) -> f64 {
        self.backing_scale
    }
    pub fn visible_frames(&self) -> impl Iterator<Item = &Rect> {
        self.tracks
            .iter()
            .flat_map(|t| &t.primitives)
            .filter_map(|p| p.frame.as_ref())
    }
    /// Exact Swift detail priority: closed style z-order, then later input
    /// primitive. Time duration/rowID are not the detail pixel-hit tiebreaker.
    pub fn detail_hit(
        &self,
        point: Point,
        check: &mut Check<'_>,
    ) -> Result<Option<EventKey>, ViewerError> {
        check()?;
        point.validate()?;
        let mut candidate: Option<(u8, usize, EventKey)> = None;
        let mut order = 0;
        for (i, track) in self.tracks.iter().enumerate() {
            checkpoint(i, check)?;
            if !track_contains(track, point) {
                continue;
            }
            for projected in &track.primitives {
                checkpoint(order, check)?;
                let index = order;
                order += 1;
                let PrimitiveInput::Detail { detail } = &projected.input else {
                    continue;
                };
                let Some(frame) = projected.frame else {
                    continue;
                };
                if !frame.expanded(1.0).contains(point) {
                    continue;
                }
                let rank = (detail.style.z_order(), index);
                if candidate.is_none_or(|(style, index, _)| rank > (style, index)) {
                    candidate = Some((rank.0, rank.1, detail.event_key));
                }
            }
        }
        check()?;
        Ok(candidate.map(|c| c.2))
    }
    /// Density hit uses the whole track row and inclusive domain endpoints,
    /// in original bucket order, including its current Swift boundary quirk.
    pub fn density_hit(
        &self,
        point: Point,
        check: &mut Check<'_>,
    ) -> Result<Option<DensityHitIntent>, ViewerError> {
        check()?;
        point.validate()?;
        let time = self.viewport.time(point.x)?;
        for (i, track) in self.tracks.iter().enumerate() {
            checkpoint(i, check)?;
            if !track_contains(track, point) {
                continue;
            }
            for (j, projected) in track.primitives.iter().enumerate() {
                checkpoint(j, check)?;
                let PrimitiveInput::Density { bucket } = &projected.input else {
                    continue;
                };
                if projected.visible
                    && bucket.range.start_ns() <= time
                    && time <= bucket.range.end_ns()
                {
                    check()?;
                    return Ok(Some(DensityHitIntent::new(
                        track.descriptor.id(),
                        track.descriptor.source.clone(),
                        bucket.range,
                        time,
                    )?));
                }
            }
        }
        check()?;
        Ok(None)
    }
    pub fn hit(
        &self,
        point: Point,
        check: &mut Check<'_>,
    ) -> Result<Option<HitIntent>, ViewerError> {
        if let Some(event_key) = self.detail_hit(point, check)? {
            return Ok(Some(HitIntent::Detail { event_key }));
        }
        Ok(self
            .density_hit(point, check)?
            .map(|intent| HitIntent::Density { intent }))
    }
}
fn track_contains(track: &ProjectedTrack, point: Point) -> bool {
    point.x >= 0.0
        && point.x < f64::MAX
        && point.y >= RULER_HEIGHT + track.y
        && point.y < RULER_HEIGHT + track.y + track.height
}
/// Reprojects retained primitives into an explicitly supplied display viewport.
/// Source generation is provenance only; asynchronous stale-commit rejection
/// stays in the host loader, outside this pure rendering layer.
pub fn project(
    viewport: &Viewport,
    source_generation: u64,
    tracks: &[TrackInput],
    backing_scale: f64,
    data_quality: &DataQuality,
    check: &mut Check<'_>,
) -> Result<ProjectedSnapshot, ViewerError> {
    check()?;
    validate_scale(backing_scale)?;
    let data_quality = machine(data_quality)?;
    if tracks.len() > MAXIMUM_TRACKS {
        return Err(ViewerError::InputBudgetExceeded);
    }
    let count = tracks
        .iter()
        .try_fold(0_usize, |total, track| {
            total.checked_add(track.primitives.len())
        })
        .ok_or(ViewerError::InputBudgetExceeded)?;
    if count > MAXIMUM_PRIMITIVES {
        return Err(ViewerError::InputBudgetExceeded);
    }
    let mut output = Vec::new();
    let mut scanned = 0;
    for track in tracks {
        checkpoint(scanned, check)?;
        validate_track_geometry(track)?;
        if track.descriptor.is_collapsed {
            return Err(ViewerError::InvalidEvidence);
        }
        let mut primitives = Vec::with_capacity(track.primitives.len());
        for input in &track.primitives {
            checkpoint(scanned, check)?;
            scanned += 1;
            if let PrimitiveInput::Density { bucket } = input
                && (bucket.range.is_instant()
                    || bucket.event_count < 0
                    || bucket.occupied_ns.is_some_and(|n| n < 0)
                    || bucket
                        .utilization
                        .is_some_and(|v| !v.is_finite() || v < 0.0))
            {
                return Err(ViewerError::InvalidEvidence);
            }
            let visible = is_visible(input.range(), viewport);
            let frame = if visible {
                Some(primitive_frame(input, track, viewport, backing_scale)?)
            } else {
                None
            };
            primitives.push(ProjectedPrimitive {
                input: input.clone(),
                visible,
                frame,
            });
        }
        output.push(ProjectedTrack {
            descriptor: track.descriptor.clone(),
            y: track.y,
            height: track.height,
            depth_row_count: track.depth_row_count,
            primitives,
        });
    }
    check()?;
    Ok(ProjectedSnapshot {
        viewport: viewport.clone(),
        source_generation,
        backing_scale,
        tracks: output,
        data_quality,
    })
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolutionQuery {
    pub range: TraceTimeRange,
    pub limit: usize,
}
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DensityHitIntent {
    pub track_id: String,
    pub source: TraceDensitySource,
    pub bucket: TraceTimeRange,
    pub time_ns: i64,
    pub covering: Option<ResolutionQuery>,
    pub fallback: ResolutionQuery,
}
impl DensityHitIntent {
    pub(crate) fn new(
        track_id: String,
        source: TraceDensitySource,
        bucket: TraceTimeRange,
        time_ns: i64,
    ) -> Result<Self, ViewerError> {
        if bucket.is_instant() || time_ns < bucket.start_ns() || time_ns > bucket.end_ns() {
            return Err(ViewerError::InvalidEvidence);
        }
        let covering = time_ns
            .checked_add(1)
            .and_then(|end| TraceTimeRange::query(time_ns, end).ok())
            .map(|range| ResolutionQuery { range, limit: 64 });
        Ok(Self {
            track_id,
            source,
            bucket,
            time_ns,
            covering,
            fallback: ResolutionQuery {
                range: bucket,
                limit: 512,
            },
        })
    }
    pub fn density_source(&self) -> &TraceDensitySource {
        &self.source
    }
}
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum HitIntent {
    Detail {
        #[serde(rename = "eventKey")]
        event_key: EventKey,
    },
    Density {
        intent: DensityHitIntent,
    },
}
/// After the host executes a bounded resolution query, choose the same real
/// event as Swift: nearest domain interval, then longest, then lowest rowID.
/// Domain end is inclusive for distance, preserving current resolution rules.
pub fn resolve_candidate(
    time_ns: i64,
    details: &[DetailInput],
    check: &mut Check<'_>,
) -> Result<Option<EventKey>, ViewerError> {
    check()?;
    if time_ns < 0 || details.len() > 512 {
        return Err(ViewerError::InputBudgetExceeded);
    }
    let mut best: Option<(i64, std::cmp::Reverse<i64>, i64, EventKey)> = None;
    for (i, detail) in details.iter().enumerate() {
        checkpoint(i, check)?;
        let range = detail.range;
        let distance = if range.start_ns() <= time_ns && time_ns <= range.end_ns() {
            0
        } else if time_ns < range.start_ns() {
            range.start_ns().checked_sub(time_ns).unwrap_or(i64::MAX)
        } else {
            time_ns.checked_sub(range.end_ns()).unwrap_or(i64::MAX)
        };
        let rank = (
            distance,
            std::cmp::Reverse(range.duration_ns()),
            detail.event_key.row_id,
        );
        if best.is_none_or(|b| rank < (b.0, b.1, b.2)) {
            best = Some((rank.0, rank.1, rank.2, detail.event_key));
        }
    }
    check()?;
    Ok(best.map(|b| b.3))
}

/// Independently bounded typed pages prepared by the host according to plan.
/// No page is fetched here; a missing page for a selected LOD is an error.
pub struct LanePages<'a> {
    pub expanded_index: usize,
    pub detail: Option<&'a arktrace_contract::EventPage<DetailInput>>,
    pub density: Option<&'a arktrace_contract::TraceDensityResult>,
}
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AssembledSnapshot {
    pub snapshot: ProjectedSnapshot,
    pub updated_depths: Vec<crate::CachedDepth>,
    pub budgets: Vec<usize>,
    pub lods: Vec<Option<crate::Lod>>,
    pub source_truncated: Vec<bool>,
    pub quality_facts: Vec<ViewerQualityFact>,
}
/// Pure sequential LOD/layout assembly. `ViewportLoader` supplies cached
/// depths and typed host query pages; Engine arbitrates async publication.
/// Final output uses one immutable snapshot.
pub fn assemble(
    request: &crate::ViewportRequest,
    cached_depths: &[crate::CachedDepth],
    pages: &[LanePages<'_>],
    backing_scale: f64,
    check: &mut Check<'_>,
) -> Result<AssembledSnapshot, ViewerError> {
    use crate::{CachedDepth, Lod, PrimitiveInput, choose_lod, depth_layout, plan, track_height};
    use arktrace_contract::{QualityCategory, QualityStatus};
    check()?;
    let plan = plan(request, cached_depths, check)?;
    if pages.len() > MAXIMUM_TRACKS {
        return Err(ViewerError::InputBudgetExceeded);
    }
    let mut indexed = std::collections::BTreeMap::new();
    let mut input_count = 0_usize;
    for (i, page) in pages.iter().enumerate() {
        checkpoint(i, check)?;
        if page.expanded_index >= plan.lanes.len()
            || indexed.insert(page.expanded_index, page).is_some()
        {
            return Err(ViewerError::InvalidEvidence);
        }
        input_count = input_count
            .checked_add(page.detail.map_or(0, |p| p.items.len()))
            .and_then(|v| v.checked_add(page.density.map_or(0, |p| p.buckets.len())))
            .ok_or(ViewerError::InputBudgetExceeded)?;
    }
    // Detail and density candidates can coexist before a LOD decision. Both
    // retain independent bounded input allowance, never unbounded raw rows.
    if input_count > 2 * MAXIMUM_PRIMITIVES {
        return Err(ViewerError::InputBudgetExceeded);
    }
    let mut remaining = plan.maximum_primitives;
    let mut queried_remaining = plan.queried_indices.len();
    let mut tracks = Vec::new();
    let mut y = 0.0;
    let mut issues = Vec::new();
    let mut seen_source_issues = std::collections::BTreeSet::new();
    let mut quality_facts = Vec::new();
    let mut updated_depths = Vec::new();
    let mut budgets = Vec::new();
    let mut lods = Vec::new();
    let mut truncated = Vec::new();
    for (i, lane) in plan.lanes.iter().enumerate() {
        checkpoint(i, check)?;
        let descriptor = request.tracks[lane.request_index].clone();
        let mut primitives = Vec::new();
        let mut source_truncated = false;
        let budget = if lane.queried {
            plan.lane_budget(remaining, queried_remaining)?
        } else {
            0
        };
        let mut selected = None;
        if budget > 0 {
            let pages = indexed.get(&i).ok_or(ViewerError::InvalidEvidence)?;
            let decision = choose_lod(
                request.preference,
                request.pixel_width,
                budget,
                pages.density,
                check,
            )?;
            selected = Some(decision.lod);
            if request.preference != crate::DetailPreference::Detail {
                crate::merge_quality(
                    &mut issues,
                    &mut seen_source_issues,
                    &pages
                        .density
                        .ok_or(ViewerError::InvalidEvidence)?
                        .data_quality,
                    check,
                )?;
            }
            match decision.lod {
                Lod::Unavailable => {}
                Lod::Density => {
                    let density = pages.density.ok_or(ViewerError::InvalidEvidence)?;
                    for (j, bucket) in density
                        .buckets
                        .iter()
                        .take(decision.bucket_limit)
                        .enumerate()
                    {
                        checkpoint(j, check)?;
                        primitives.push(PrimitiveInput::Density {
                            bucket: bucket.clone(),
                        });
                    }
                }
                Lod::Detail => {
                    let detail = pages.detail.ok_or(ViewerError::InvalidEvidence)?;
                    if detail.items.len() > budget {
                        return Err(ViewerError::InputBudgetExceeded);
                    }
                    if !detail.capability_available
                        && (!detail.items.is_empty() || detail.truncated)
                    {
                        return Err(ViewerError::InvalidEvidence);
                    }
                    crate::merge_quality(
                        &mut issues,
                        &mut seen_source_issues,
                        &detail.data_quality,
                        check,
                    )?;
                    source_truncated = detail.truncated;
                    if source_truncated {
                        let scope = match descriptor.source {
                            TraceDensitySource::Cpu { .. } => ViewerQualityScope::Cpu,
                            TraceDensitySource::ThreadState { .. } => {
                                ViewerQualityScope::ThreadState
                            }
                            TraceDensitySource::NamedSlice { .. } => ViewerQualityScope::NamedSlice,
                            TraceDensitySource::Frame { .. } => ViewerQualityScope::Frame,
                            _ => ViewerQualityScope::Counter,
                        };
                        quality_facts.push(ViewerQualityFact {
                            category: QualityCategory::ProbeTruncated,
                            scope,
                            count: None,
                        });
                    }
                    for (j, item) in detail.items.iter().enumerate() {
                        checkpoint(j, check)?;
                        let mut detail = item.clone();
                        detail.depth = detail.depth.max(0);
                        if matches!(descriptor.source, TraceDensitySource::NamedSlice { .. })
                            && !descriptor.shows_nested_depth
                        {
                            detail.depth = 0;
                        }
                        primitives.push(PrimitiveInput::Detail { detail });
                    }
                }
            }
        }
        let rows = if lane.queried {
            let observed = depth_layout(
                primitives.iter().filter_map(|p| {
                    if let PrimitiveInput::Detail { detail } = p {
                        Some(detail.depth)
                    } else {
                        None
                    }
                }),
                check,
            )?;
            if observed.truncated {
                quality_facts.push(ViewerQualityFact {
                    category: QualityCategory::ProbeTruncated,
                    scope: ViewerQualityScope::NamedSliceDepth,
                    count: None,
                });
            }
            updated_depths.push(CachedDepth {
                track_id: descriptor.id(),
                rows: observed.rows,
            });
            observed.rows
        } else {
            lane.depth_row_count
        };
        let height = track_height(rows)?;
        remaining = remaining
            .checked_sub(primitives.len())
            .ok_or(ViewerError::InvalidEvidence)?;
        if lane.queried {
            queried_remaining = queried_remaining.saturating_sub(1);
        }
        tracks.push(TrackInput {
            descriptor,
            y,
            height,
            depth_row_count: rows,
            primitives,
        });
        y = crate::finite(y + height)?;
        budgets.push(budget);
        lods.push(selected);
        truncated.push(source_truncated);
    }
    // TraceDataQuality keeps the first occurrence of an identical issue.
    let mut seen_facts = std::collections::BTreeSet::new();
    quality_facts.retain(|fact| seen_facts.insert(fact.clone()));
    if !quality_facts.is_empty() {
        let derived_quality = DataQuality {
            status: QualityStatus::Warnings,
            warnings: quality_facts
                .iter()
                .map(|fact| arktrace_contract::QualityIssue {
                    category: fact.category,
                    scope: Some(fact.scope.as_str().into()),
                    count: fact.count,
                    message: None,
                })
                .collect(),
        };
        crate::merge_quality(
            &mut issues,
            &mut seen_source_issues,
            &derived_quality,
            check,
        )?;
    }
    let status = if issues.is_empty() {
        QualityStatus::Ok
    } else {
        QualityStatus::Warnings
    };
    let data_quality = DataQuality::machine(status, issues)?;
    let snapshot = project(
        &request.viewport,
        request.generation,
        &tracks,
        backing_scale,
        &data_quality,
        check,
    )?;
    Ok(AssembledSnapshot {
        snapshot,
        updated_depths,
        budgets,
        lods,
        source_truncated: truncated,
        quality_facts,
    })
}

/// Derived Viewer facts also contribute to the snapshot's machine quality.
/// Their scopes use the shared closed vocabulary, with the same total budget.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize)]
pub enum ViewerQualityScope {
    #[serde(rename = "timeline.cpu")]
    Cpu,
    #[serde(rename = "timeline.threadState")]
    ThreadState,
    #[serde(rename = "timeline.namedSlice")]
    NamedSlice,
    #[serde(rename = "timeline.frame")]
    Frame,
    #[serde(rename = "timeline.counter")]
    Counter,
    #[serde(rename = "timeline.namedSlice.depth")]
    NamedSliceDepth,
}
impl ViewerQualityScope {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Cpu => "timeline.cpu",
            Self::ThreadState => "timeline.threadState",
            Self::NamedSlice => "timeline.namedSlice",
            Self::Frame => "timeline.frame",
            Self::Counter => "timeline.counter",
            Self::NamedSliceDepth => "timeline.namedSlice.depth",
        }
    }
}
#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize)]
pub struct ViewerQualityFact {
    pub category: arktrace_contract::QualityCategory,
    pub scope: ViewerQualityScope,
    pub count: Option<i64>,
}
