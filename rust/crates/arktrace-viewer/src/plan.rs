use crate::{
    Check, DetailPreference, MAXIMUM_DEPTH_ROWS, RULER_HEIGHT, TrackDescriptor, ViewerError,
    Viewport, checkpoint, finite, machine, track_height,
};
use arktrace_contract::{EventKey, TraceDensityQuery, TraceDensityResult, TraceDensitySource};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
pub const MAXIMUM_TRACKS: usize = 10_000;
pub const MAXIMUM_PRIMITIVES: usize = 20_000;
pub const MAXIMUM_PIXEL_WIDTH: usize = 100_000;
pub const MAXIMUM_DENSITY_BATCH: usize = 32;
pub const VERTICAL_OVERSCAN_SCREENS: f64 = 0.5;
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ViewportRequest {
    pub viewport: Viewport,
    pub tracks: Vec<TrackDescriptor>,
    pub pixel_width: usize,
    pub generation: u64,
    pub preference: DetailPreference,
    pub maximum_primitives: Option<usize>,
    /// Query host must prepend/deduplicate the focused real event in its
    /// bounded detail page. This pure module does not fetch search results.
    pub focused_event_key: Option<EventKey>,
}
impl ViewportRequest {
    pub fn effective_budget(&self) -> Result<usize, ViewerError> {
        if self.pixel_width == 0
            || self.pixel_width > MAXIMUM_PIXEL_WIDTH
            || self.generation != self.viewport.generation()
            || self.tracks.len() > MAXIMUM_TRACKS
        {
            return Err(ViewerError::InvalidRequest);
        }
        let default = detail_budget(self.pixel_width);
        let requested = self.maximum_primitives.unwrap_or(default);
        if !(1..=MAXIMUM_PRIMITIVES).contains(&requested) {
            return Err(ViewerError::InvalidRequest);
        }
        Ok(requested.min(default))
    }
}
pub fn detail_budget(pixel_width: usize) -> usize {
    pixel_width
        .saturating_mul(8)
        .clamp(2000, MAXIMUM_PRIMITIVES)
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CachedDepth {
    pub track_id: String,
    pub rows: usize,
}
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LanePlan {
    pub expanded_index: usize,
    pub request_index: usize,
    pub track_id: String,
    pub source: TraceDensitySource,
    pub y: f64,
    pub height: f64,
    pub depth_row_count: usize,
    pub queried: bool,
}
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QueryPlan {
    pub maximum_primitives: usize,
    pub lanes: Vec<LanePlan>,
    pub queried_indices: Vec<usize>,
    pub fair_budget: usize,
    pub density_prefetch: Vec<TraceDensityQuery>,
    pub density_batches: Vec<Vec<usize>>,
}
impl QueryPlan {
    /// Host passes actual returned counts while walking lanes in plan order.
    /// An unused share never raises a later lane above the initial fair ceiling.
    pub fn lane_budget(
        &self,
        remaining: usize,
        queried_remaining: usize,
    ) -> Result<usize, ViewerError> {
        if remaining > self.maximum_primitives || queried_remaining > self.queried_indices.len() {
            return Err(ViewerError::InvalidRequest);
        }
        if remaining == 0 || queried_remaining == 0 {
            return Ok(0);
        }
        Ok(self
            .fair_budget
            .max(1)
            .min((remaining / queried_remaining.max(1)).max(1)))
    }
}
pub fn plan(
    request: &ViewportRequest,
    cached_depths: &[CachedDepth],
    check: &mut Check<'_>,
) -> Result<QueryPlan, ViewerError> {
    check()?;
    let maximum_primitives = request.effective_budget()?;
    if cached_depths.len() > MAXIMUM_TRACKS {
        return Err(ViewerError::InputBudgetExceeded);
    }
    let mut cached = BTreeMap::new();
    for (i, entry) in cached_depths.iter().enumerate() {
        checkpoint(i, check)?;
        if entry.track_id.len() > 256
            || !(1..=MAXIMUM_DEPTH_ROWS).contains(&entry.rows)
            || cached.insert(entry.track_id.as_str(), entry.rows).is_some()
        {
            return Err(ViewerError::InvalidEvidence);
        }
    }
    let viewport = &request.viewport;
    let body_start = (viewport.vertical_offset_points() - RULER_HEIGHT).max(0.0);
    let body_end =
        body_start.max(viewport.vertical_offset_points() + viewport.height_points() - RULER_HEIGHT);
    let overscan = viewport.height_points() * VERTICAL_OVERSCAN_SCREENS;
    let query_start = (body_start - overscan).max(0.0);
    let query_end = body_end + overscan;
    finite(query_end)?;
    let mut y = 0.0;
    let mut lanes = Vec::new();
    let mut queried_indices = Vec::new();
    for (request_index, track) in request.tracks.iter().enumerate() {
        checkpoint(request_index, check)?;
        if track.is_collapsed {
            continue;
        }
        let track_id = track.id();
        let rows = cached
            .get(track_id.as_str())
            .copied()
            .unwrap_or(track.default_depth_rows());
        let height = track_height(rows)?;
        let expanded_index = lanes.len();
        let queried = request.preference == DetailPreference::Detail
            || (y + height >= query_start && y <= query_end);
        if queried {
            queried_indices.push(expanded_index);
        }
        lanes.push(LanePlan {
            expanded_index,
            request_index,
            track_id,
            source: track.source.clone(),
            y,
            height,
            depth_row_count: rows,
            queried,
        });
        y = finite(y + height)?;
    }
    let fair_budget = if queried_indices.is_empty() {
        0
    } else {
        maximum_primitives / queried_indices.len()
    };
    let mut density_prefetch = Vec::new();
    if fair_budget >= 1 && request.preference != DetailPreference::Detail {
        let bucket_count = density_bucket_limit(request.pixel_width, fair_budget)?;
        for (i, index) in queried_indices.iter().enumerate() {
            checkpoint(i, check)?;
            density_prefetch.push(TraceDensityQuery {
                range: viewport.range(),
                source: lanes[*index].source.clone(),
                bucket_count,
            });
        }
    }
    let density_batches = (0..density_prefetch.len())
        .collect::<Vec<_>>()
        .chunks(MAXIMUM_DENSITY_BATCH)
        .map(|c| c.to_vec())
        .collect();
    check()?;
    Ok(QueryPlan {
        maximum_primitives,
        lanes,
        queried_indices,
        fair_budget,
        density_prefetch,
        density_batches,
    })
}
pub fn density_bucket_limit(pixel_width: usize, budget: usize) -> Result<usize, ViewerError> {
    if pixel_width == 0
        || pixel_width > MAXIMUM_PIXEL_WIDTH
        || !(1..=MAXIMUM_PRIMITIVES).contains(&budget)
    {
        return Err(ViewerError::InvalidRequest);
    }
    Ok((pixel_width / 16).max(1).min(budget).max(1))
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Lod {
    Detail,
    Density,
    Unavailable,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LodDecision {
    pub lod: Lod,
    pub estimated_count: Option<i64>,
    pub bucket_limit: usize,
    pub detail_limit: usize,
}
/// Explicit detail skips the density query. Automatic requires a bounded
/// existing Store density result; this crate never recomputes aggregates.
pub fn choose_lod(
    preference: DetailPreference,
    pixel_width: usize,
    budget: usize,
    density: Option<&TraceDensityResult>,
    check: &mut Check<'_>,
) -> Result<LodDecision, ViewerError> {
    check()?;
    let bucket_limit = density_bucket_limit(pixel_width, budget)?;
    if preference == DetailPreference::Detail {
        return Ok(LodDecision {
            lod: Lod::Detail,
            estimated_count: None,
            bucket_limit,
            detail_limit: budget,
        });
    }
    let density = density.ok_or(ViewerError::InvalidEvidence)?;
    machine(&density.data_quality)?;
    if density.buckets.len() > TraceDensityQuery::MAXIMUM_BUCKET_COUNT {
        return Err(ViewerError::InputBudgetExceeded);
    }
    if !density.capability_available {
        if !density.buckets.is_empty() {
            return Err(ViewerError::InvalidEvidence);
        }
        return Ok(LodDecision {
            lod: Lod::Unavailable,
            estimated_count: None,
            bucket_limit,
            detail_limit: budget,
        });
    }
    let mut count = 0_i64;
    for (i, bucket) in density.buckets.iter().enumerate() {
        checkpoint(i, check)?;
        if bucket.event_count < 0 {
            return Err(ViewerError::InvalidEvidence);
        }
        count = count
            .checked_add(bucket.event_count)
            .ok_or(ViewerError::ArithmeticOverflow)?;
    }
    check()?;
    let lod = if preference == DetailPreference::Density || count > budget as i64 {
        Lod::Density
    } else {
        Lod::Detail
    };
    Ok(LodDecision {
        lod,
        estimated_count: Some(count),
        bucket_limit,
        detail_limit: budget,
    })
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DepthLayout {
    pub rows: usize,
    pub observed_depth: i64,
    pub truncated: bool,
}
pub fn depth_layout(
    depths: impl IntoIterator<Item = i64>,
    check: &mut Check<'_>,
) -> Result<DepthLayout, ViewerError> {
    check()?;
    let mut observed = 0;
    for (i, depth) in depths.into_iter().enumerate() {
        if i >= MAXIMUM_PRIMITIVES {
            return Err(ViewerError::InputBudgetExceeded);
        }
        checkpoint(i, check)?;
        observed = observed.max(depth.max(0));
    }
    check()?;
    Ok(DepthLayout {
        rows: if observed >= MAXIMUM_DEPTH_ROWS as i64 {
            MAXIMUM_DEPTH_ROWS
        } else {
            (observed + 1) as usize
        },
        observed_depth: observed,
        truncated: observed >= MAXIMUM_DEPTH_ROWS as i64,
    })
}
