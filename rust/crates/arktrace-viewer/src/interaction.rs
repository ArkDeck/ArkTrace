use crate::{ViewerError, Viewport, finite};
use arktrace_contract::TraceTimeRange;
fn bounded(range: TraceTimeRange, bounds: TraceTimeRange) -> Result<(), ViewerError> {
    if range.is_instant()
        || bounds.is_instant()
        || range.start_ns() < bounds.start_ns()
        || range.end_ns() > bounds.end_ns()
    {
        Err(ViewerError::InvalidRequest)
    } else {
        Ok(())
    }
}
pub fn pan(
    range: TraceTimeRange,
    delta_ns: i64,
    bounds: TraceTimeRange,
) -> Result<TraceTimeRange, ViewerError> {
    bounded(range, bounds)?;
    let maximum_start = bounds.end_ns() - range.duration_ns();
    let candidate = range
        .start_ns()
        .checked_add(delta_ns)
        .unwrap_or(if delta_ns < 0 {
            bounds.start_ns()
        } else {
            maximum_start
        });
    let start = candidate.max(bounds.start_ns()).min(maximum_start);
    Ok(TraceTimeRange::query(start, start + range.duration_ns())?)
}
pub fn pan_points(
    viewport: &Viewport,
    points: f64,
    bounds: TraceTimeRange,
) -> Result<TraceTimeRange, ViewerError> {
    pan(viewport.range(), viewport.nanosecond_delta(points)?, bounds)
}
pub fn zoom(
    range: TraceTimeRange,
    anchor_ns: i64,
    scale: f64,
    bounds: TraceTimeRange,
) -> Result<TraceTimeRange, ViewerError> {
    bounded(range, bounds)?;
    finite(scale)?;
    if scale <= 0.0 {
        return Err(ViewerError::InvalidRequest);
    }
    let proposed = range.duration_ns() as f64 * scale.clamp(0.05, 20.0);
    let new_duration = if !proposed.is_finite() || proposed >= bounds.duration_ns() as f64 {
        bounds.duration_ns()
    } else {
        (proposed.round() as i64).max(1)
    };
    if new_duration >= bounds.duration_ns() {
        return Ok(bounds);
    }
    let anchor = anchor_ns.max(range.start_ns()).min(range.end_ns());
    let fraction = (anchor - range.start_ns()) as f64 / range.duration_ns() as f64;
    let offset_double = fraction * new_duration as f64;
    let offset = if offset_double >= i64::MAX as f64 {
        i64::MAX
    } else {
        (offset_double.floor() as i64).max(0)
    };
    let start = anchor
        .checked_sub(offset)
        .unwrap_or(bounds.start_ns())
        .max(bounds.start_ns())
        .min(bounds.end_ns() - new_duration);
    Ok(TraceTimeRange::query(start, start + new_duration)?)
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SelectionDrag {
    NewRange,
    Endpoint,
}
/// Degenerate new drag clears selection; endpoint collapse keeps the last
/// nondegenerate selection. Crossing the anchor switches ordered endpoints.
pub fn selection_drag(
    viewport: &Viewport,
    anchor_ns: i64,
    pointer_x: f64,
    mode: SelectionDrag,
    previous: Option<TraceTimeRange>,
) -> Result<Option<TraceTimeRange>, ViewerError> {
    if anchor_ns < viewport.range().start_ns()
        || anchor_ns > viewport.range().end_ns()
        || previous.is_some_and(|r| r.is_instant())
    {
        return Err(ViewerError::InvalidRequest);
    }
    let moved = viewport.time(pointer_x)?;
    if moved == anchor_ns {
        return Ok(if mode == SelectionDrag::NewRange {
            None
        } else {
            previous
        });
    }
    Ok(Some(TraceTimeRange::query(
        anchor_ns.min(moved),
        anchor_ns.max(moved),
    )?))
}
