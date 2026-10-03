use crate::{DetailInput, Point, PrimitiveInput, Rect, TrackInput, ViewerError, Viewport, finite};
use arktrace_contract::TraceTimeRange;
pub const RULER_HEIGHT: f64 = 22.0;
pub const TRACK_VERTICAL_INSET: f64 = 3.0;
pub const DEPTH_ROW_SPAN: f64 = 22.0;
pub const MAXIMUM_DEPTH_ROWS: usize = 32;
pub const SELECTION_TARGET_POINTS: f64 = 24.0;
pub fn track_height(depth_rows: usize) -> Result<f64, ViewerError> {
    if !(1..=MAXIMUM_DEPTH_ROWS).contains(&depth_rows) {
        return Err(ViewerError::InvalidGeometry);
    }
    Ok(2.0 * TRACK_VERTICAL_INSET + depth_rows as f64 * DEPTH_ROW_SPAN)
}
impl Viewport {
    /// Subtract locally in Int64 before any floating-point conversion.
    pub fn x(&self, time_ns: i64) -> f64 {
        let delta = if time_ns <= self.range.start_ns() {
            0
        } else if time_ns >= self.range.end_ns() {
            self.range.duration_ns()
        } else {
            time_ns - self.range.start_ns()
        };
        delta as f64 / self.range.duration_ns() as f64 * self.width_points
    }
    /// Inclusive endpoint clamp, with floor and a duration-1 interior bound.
    pub fn time(&self, x: f64) -> Result<i64, ViewerError> {
        finite(x)?;
        let x = x.max(0.0).min(self.width_points);
        if x <= 0.0 {
            return Ok(self.range.start_ns());
        }
        if x >= self.width_points {
            return Ok(self.range.end_ns());
        }
        let scaled = (x / self.width_points * self.range.duration_ns() as f64).floor();
        let max_delta = self.range.duration_ns() - 1;
        let delta = if !scaled.is_finite() || scaled <= 0.0 {
            0
        } else if scaled >= max_delta as f64 {
            max_delta
        } else {
            scaled as i64
        };
        Ok(self
            .range
            .start_ns()
            .checked_add(delta)
            .unwrap_or(self.range.end_ns())
            .min(self.range.end_ns()))
    }
    /// Finite point inputs only; a finite multiplication overflow saturates.
    /// Swift accepts infinite inputs and treats NaN as no pan; the stricter
    /// request boundary is explicit, tested and recorded as a difference.
    pub fn nanosecond_delta(&self, points: f64) -> Result<i64, ViewerError> {
        finite(points)?;
        let raw = points * self.ns_per_point;
        if raw >= i64::MAX as f64 {
            return Ok(i64::MAX);
        }
        if raw <= i64::MIN as f64 {
            return Ok(i64::MIN);
        }
        Ok(raw.round() as i64)
    }
}
/// Inclusive visual visibility freezes current Swift stale-viewport behavior;
/// it is deliberately different from contract's half-open query intersection.
pub fn is_visible(range: TraceTimeRange, viewport: &Viewport) -> bool {
    range.end_ns() >= viewport.range.start_ns() && range.start_ns() <= viewport.range.end_ns()
}
pub fn band_frame(
    range: TraceTimeRange,
    track: &TrackInput,
    viewport: &Viewport,
    backing_scale: f64,
) -> Result<Rect, ViewerError> {
    validate_track_geometry(track)?;
    validate_scale(backing_scale)?;
    let start = viewport.x(range.start_ns());
    let end = viewport.x(range.end_ns());
    let result = Rect {
        x: start,
        y: RULER_HEIGHT + track.y + TRACK_VERTICAL_INSET,
        width: (end - start).max(1.0 / backing_scale.max(1.0)),
        height: (track.height - 2.0 * TRACK_VERTICAL_INSET).max(1.0),
    };
    result.validate()?;
    Ok(result)
}
pub fn detail_frame(
    detail: &DetailInput,
    track: &TrackInput,
    viewport: &Viewport,
    backing_scale: f64,
) -> Result<Rect, ViewerError> {
    validate_track_geometry(track)?;
    validate_scale(backing_scale)?;
    let span =
        ((track.height - 2.0 * TRACK_VERTICAL_INSET) / track.depth_row_count as f64).max(1.0);
    let row = detail.depth.max(0).min(track.depth_row_count as i64 - 1);
    let start = viewport.x(detail.range.start_ns());
    let end = viewport.x(detail.range.end_ns());
    let result = Rect {
        x: start,
        y: RULER_HEIGHT + track.y + TRACK_VERTICAL_INSET + row as f64 * span,
        width: (end - start).max(1.0 / backing_scale.max(1.0)),
        height: span.max(1.0),
    };
    result.validate()?;
    Ok(result)
}
pub fn primitive_frame(
    primitive: &PrimitiveInput,
    track: &TrackInput,
    viewport: &Viewport,
    backing_scale: f64,
) -> Result<Rect, ViewerError> {
    match primitive {
        PrimitiveInput::Detail { detail } => detail_frame(detail, track, viewport, backing_scale),
        PrimitiveInput::Density { bucket } => {
            band_frame(bucket.range, track, viewport, backing_scale)
        }
    }
}
pub(crate) fn validate_scale(scale: f64) -> Result<(), ViewerError> {
    if !scale.is_finite() || scale <= 0.0 {
        Err(ViewerError::InvalidGeometry)
    } else {
        Ok(())
    }
}
pub(crate) fn validate_track_geometry(track: &TrackInput) -> Result<(), ViewerError> {
    if !track.y.is_finite()
        || track.y < 0.0
        || !track.height.is_finite()
        || track.height <= 0.0
        || !(1..=MAXIMUM_DEPTH_ROWS).contains(&track.depth_row_count)
    {
        return Err(ViewerError::InvalidGeometry);
    }
    finite(RULER_HEIGHT + track.y + track.height)?;
    Ok(())
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SelectionEndpoint {
    Start,
    End,
}
pub fn selection_endpoint(
    point: Point,
    selection: TraceTimeRange,
    viewport: &Viewport,
) -> Result<Option<SelectionEndpoint>, ViewerError> {
    point.validate()?;
    if point.y < RULER_HEIGHT {
        return Ok(None);
    }
    let start = viewport.x(selection.start_ns());
    let end = viewport.x(selection.end_ns());
    let reach = SELECTION_TARGET_POINTS / 2.0;
    let (start_region, end_region) = if end - start >= SELECTION_TARGET_POINTS {
        ((start - reach, start + reach), (end - reach, end + reach))
    } else {
        let middle = (start + end) / 2.0;
        (
            (middle - 2.0 * reach, middle),
            (middle, middle + 2.0 * reach),
        )
    };
    if start_region.0 <= point.x && point.x <= start_region.1 {
        return Ok(Some(SelectionEndpoint::Start));
    }
    if end_region.0 <= point.x && point.x <= end_region.1 {
        return Ok(Some(SelectionEndpoint::End));
    }
    Ok(None)
}
