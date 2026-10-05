//! Bounded, cancellable hit testing of the retained packed scene.
//! No IO or snapshot reconstruction; validation completes before any result.
use crate::*;
use arktrace_contract::{
    EventKey, EventTable, ProcessKey, ThreadKey, TraceDensitySource, TraceTimeRange,
};
use std::mem::size_of;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HotSnapshotHitMode {
    Detail,
    Density,
    Any,
}

/// Caps apply to the entire input, referenced UTF-8 work, and retained output.
#[derive(Clone, Copy, Debug)]
pub struct HotSnapshotHitBudget {
    pub maximum_tracks: usize,
    pub maximum_primitives: usize,
    pub maximum_quality: usize,
    pub maximum_string_bytes: usize,
    pub maximum_referenced_string_bytes: usize,
    pub maximum_output_bytes: usize,
}
impl Default for HotSnapshotHitBudget {
    fn default() -> Self {
        Self {
            maximum_tracks: MAXIMUM_TRACKS,
            maximum_primitives: MAXIMUM_PRIMITIVES,
            maximum_quality: 4096,
            maximum_string_bytes: 16 * 1024 * 1024,
            maximum_referenced_string_bytes: 16 * 1024 * 1024,
            maximum_output_bytes: 65536,
        }
    }
}
fn text<'a>(
    scene: &'a HotSnapshot,
    offset: u32,
    length: u32,
    work: &mut usize,
    budget: HotSnapshotHitBudget,
    check: &mut Check<'_>,
) -> Result<&'a str, ViewerError> {
    check()?;
    let start = usize::try_from(offset).map_err(|_| ViewerError::ArithmeticOverflow)?;
    let length = usize::try_from(length).map_err(|_| ViewerError::ArithmeticOverflow)?;
    let end = start
        .checked_add(length)
        .ok_or(ViewerError::ArithmeticOverflow)?;
    let bytes = scene
        .strings
        .get(start..end)
        .ok_or(ViewerError::InvalidEvidence)?;
    *work = work
        .checked_add(length)
        .ok_or(ViewerError::ArithmeticOverflow)?;
    if *work > budget.maximum_referenced_string_bytes.min(16 * 1024 * 1024) {
        return Err(ViewerError::InputBudgetExceeded);
    }
    // Check every bounded UTF-8 chunk as well as before decoding the field.
    for chunk in bytes.chunks(4096) {
        let _ = chunk;
        check()?;
    }
    std::str::from_utf8(bytes).map_err(|_| ViewerError::InvalidEvidence)
}
fn source(t: &TrackRecord) -> Result<TraceDensitySource, ViewerError> {
    let owner = t.flags & WIRE_TRACK_OWNER != 0;
    Ok(match t.source_kind {
        WIRE_SOURCE_CPU if !owner && t.filter_id == 0 && t.owner_value == 0 => {
            TraceDensitySource::Cpu {
                cpu: t.source_value,
            }
        }
        WIRE_SOURCE_THREAD_STATE if !owner && t.filter_id == 0 && t.owner_value == 0 => {
            TraceDensitySource::ThreadState {
                thread: ThreadKey {
                    itid: t.source_value,
                },
            }
        }
        WIRE_SOURCE_NAMED_SLICE
            if t.filter_id == 0 && t.owner_value == 0 && (owner || t.source_value == 0) =>
        {
            TraceDensitySource::NamedSlice {
                thread: owner.then_some(ThreadKey {
                    itid: t.source_value,
                }),
            }
        }
        WIRE_SOURCE_CPU_COUNTER if t.source_value == 0 && (owner || t.owner_value == 0) => {
            TraceDensitySource::CpuCounter {
                filter_id: t.filter_id,
                cpu: owner.then_some(t.owner_value),
            }
        }
        WIRE_SOURCE_PROCESS_COUNTER if t.source_value == 0 && (owner || t.owner_value == 0) => {
            TraceDensitySource::ProcessCounter {
                filter_id: t.filter_id,
                process_key: owner.then_some(ProcessKey {
                    ipid: t.owner_value,
                }),
            }
        }
        WIRE_SOURCE_FRAME
            if t.source_value == 0 && t.filter_id == 0 && (owner || t.owner_value == 0) =>
        {
            TraceDensitySource::Frame {
                process_key: owner.then_some(ProcessKey {
                    ipid: t.owner_value,
                }),
            }
        }
        _ => return Err(ViewerError::InvalidEvidence),
    })
}
fn table(tag: u32) -> Result<EventTable, ViewerError> {
    Ok(match tag {
        1 => EventTable::SchedSlice,
        2 => EventTable::ThreadState,
        3 => EventTable::Callstack,
        4 => EventTable::Measure,
        5 => EventTable::ProcessMeasure,
        6 => EventTable::FrameSlice,
        _ => return Err(ViewerError::InvalidEvidence),
    })
}
fn style(tag: u32) -> Result<DetailStyle, ViewerError> {
    Ok(match tag {
        1 => DetailStyle::Running,
        2 => DetailStyle::Runnable,
        3 => DetailStyle::Blocked,
        4 => DetailStyle::Sleeping,
        5 => DetailStyle::Counter,
        6 => DetailStyle::Accent,
        _ => return Err(ViewerError::InvalidEvidence),
    })
}
fn frame(p: &PrimitiveRecord) -> Rect {
    Rect {
        x: p.x,
        y: p.y,
        width: p.width,
        height: p.height,
    }
}
fn row_contains(t: &TrackRecord, point: Point) -> bool {
    point.x >= 0.0
        && point.x < f64::MAX
        && point.y >= RULER_HEIGHT + t.y
        && point.y < RULER_HEIGHT + t.y + t.height
}
/// Logical point and backing scale come from the same retained viewport.
/// All malformed records are rejected even when an earlier primitive would hit.
pub fn hot_snapshot_hit(
    scene: &HotSnapshot,
    point: Point,
    budget: HotSnapshotHitBudget,
    check: &mut Check<'_>,
) -> Result<Option<HitIntent>, ViewerError> {
    check()?;
    let v = scene.viewport;
    let display = Viewport::new(
        TraceTimeRange::query(v.start_ns, v.end_ns)?,
        v.width_points,
        v.height_points,
        v.vertical_offset_points,
        v.generation,
    )?;
    hot_snapshot_hit_in(
        scene,
        &display,
        v.backing_scale,
        point,
        HotSnapshotHitMode::Any,
        budget,
        check,
    )
}

/// Reuses retained domains and rows while the host displays a new viewport.
/// Generation is provenance; publication and stale-result rejection stay in the host.
pub fn hot_snapshot_hit_in(
    scene: &HotSnapshot,
    display: &Viewport,
    backing_scale: f64,
    point: Point,
    mode: HotSnapshotHitMode,
    budget: HotSnapshotHitBudget,
    check: &mut Check<'_>,
) -> Result<Option<HitIntent>, ViewerError> {
    check()?;
    point.validate()?;
    validate_scale(backing_scale)?;
    if scene.tracks.len() > budget.maximum_tracks.min(MAXIMUM_TRACKS)
        || scene.primitives.len() > budget.maximum_primitives.min(MAXIMUM_PRIMITIVES)
        || scene.quality.len() > budget.maximum_quality.min(4096)
        || scene.strings.len() > budget.maximum_string_bytes.min(16 * 1024 * 1024)
    {
        return Err(ViewerError::InputBudgetExceeded);
    }
    let v = scene.viewport;
    let viewport = Viewport::new(
        TraceTimeRange::query(v.start_ns, v.end_ns)?,
        v.width_points,
        v.height_points,
        v.vertical_offset_points,
        v.generation,
    )?;
    validate_scale(v.backing_scale)?;
    if v.ns_per_point.to_bits() != viewport.ns_per_point().to_bits()
        || !matches!(
            scene.quality_status,
            WIRE_QUALITY_STATUS_OK | WIRE_QUALITY_STATUS_WARNINGS
        )
    {
        return Err(ViewerError::InvalidEvidence);
    }
    let mut work = 0;
    let mut expected_start = 0usize;
    for (ti, t) in scene.tracks.iter().enumerate() {
        checkpoint(ti, check)?;
        if t.flags & !7 != 0
            || t.reserved != 0
            || !t.y.is_finite()
            || t.y < 0.0
            || !t.height.is_finite()
            || t.height <= 0.0
            || !(RULER_HEIGHT + t.y + t.height).is_finite()
            || !(1..=MAXIMUM_DEPTH_ROWS as u32).contains(&t.depth_rows)
        {
            return Err(ViewerError::InvalidGeometry);
        }
        let start =
            usize::try_from(t.primitive_start).map_err(|_| ViewerError::ArithmeticOverflow)?;
        let end = start
            .checked_add(
                usize::try_from(t.primitive_count).map_err(|_| ViewerError::ArithmeticOverflow)?,
            )
            .ok_or(ViewerError::ArithmeticOverflow)?;
        if start != expected_start || end > scene.primitives.len() {
            return Err(ViewerError::InvalidEvidence);
        }
        expected_start = end;
        if t.id_length > 128 {
            return Err(ViewerError::InputBudgetExceeded);
        }
        let typed_source = source(t)?;
        if text(scene, t.id_offset, t.id_length, &mut work, budget, check)?
            != source_id(&typed_source)
        {
            return Err(ViewerError::InvalidEvidence);
        }
        for (pi, p) in scene.primitives[start..end].iter().enumerate() {
            checkpoint(pi, check)?;
            if usize::try_from(p.track_index).ok() != Some(ti)
                || p.flags & !((1 << 23) - 1) != 0
                || p.reserved != 0
                || p.reserved_header != 0
            {
                return Err(ViewerError::InvalidEvidence);
            }
            let range = TraceTimeRange::event(p.start_ns, p.end_ns)?;
            if (p.flags & WIRE_FLAG_VISIBLE != 0) != is_visible(range, &viewport)
                || (p.flags & WIRE_FLAG_FRAME != 0) != (p.flags & WIRE_FLAG_VISIBLE != 0)
            {
                return Err(ViewerError::InvalidEvidence);
            }
            if p.flags & WIRE_FLAG_FRAME != 0 {
                frame(p).validate()?;
                frame(p).expanded(1.0).validate()?;
            } else if [p.x, p.y, p.width, p.height].iter().any(|x| !x.is_finite()) {
                return Err(ViewerError::InvalidGeometry);
            }
            match p.kind {
                WIRE_PRIMITIVE_DETAIL => {
                    table(p.event_table)?;
                    style(p.style)?;
                    if p.flags & (WIRE_FLAG_OCCUPANCY | WIRE_FLAG_UTILIZATION) != 0 {
                        return Err(ViewerError::InvalidEvidence);
                    }
                    if p.flags & WIRE_FLAG_RENDER_FACTS != 0 && !(1..=6).contains(&p.event_kind) {
                        return Err(ViewerError::InvalidEvidence);
                    }
                }
                WIRE_PRIMITIVE_DENSITY => {
                    if range.is_instant()
                        || p.event_count < 0
                        || p.event_table != 0
                        || p.style != 0
                        || p.flags
                            & !(WIRE_FLAG_VISIBLE
                                | WIRE_FLAG_FRAME
                                | WIRE_FLAG_OCCUPANCY
                                | WIRE_FLAG_UTILIZATION
                                | WIRE_FLAG_COLOR)
                            != 0
                        || p.dominant_kind > 4
                        || (p.flags & WIRE_FLAG_OCCUPANCY != 0 && p.occupied_ns < 0)
                        || (p.flags & WIRE_FLAG_UTILIZATION != 0
                            && (!p.utilization.is_finite() || p.utilization < 0.0))
                    {
                        return Err(ViewerError::InvalidEvidence);
                    }
                }
                _ => return Err(ViewerError::InvalidEvidence),
            }
            for (o, l) in [
                (p.text_offset, p.text_length),
                (p.label_offset, p.label_length),
                (p.category_offset, p.category_length),
                (p.name_offset, p.name_length),
                (p.process_name_offset, p.process_name_length),
                (p.thread_name_offset, p.thread_name_length),
                (p.inspector_category_offset, p.inspector_category_length),
                (p.state_offset, p.state_length),
                (p.unit_offset, p.unit_length),
            ] {
                text(scene, o, l, &mut work, budget, check)?;
            }
        }
    }
    if expected_start != scene.primitives.len() {
        return Err(ViewerError::InvalidEvidence);
    }
    for (i, q) in scene.quality.iter().enumerate() {
        checkpoint(i, check)?;
        if !(1..=7).contains(&q.category)
            || q.flags & !3 != 0
            || (q.flags & WIRE_QUALITY_COUNT != 0 && q.count < 0)
        {
            return Err(ViewerError::InvalidEvidence);
        }
        text(
            scene,
            q.scope_offset,
            q.scope_length,
            &mut work,
            budget,
            check,
        )?;
    }
    let mut detail: Option<(u8, usize, EventKey)> = None;
    let mut density: Option<(usize, usize, i64)> = None;
    let time = display.time(point.x)?;
    let reuse_frames = viewport.range() == display.range()
        && viewport.width_points() == display.width_points()
        && viewport.height_points() == display.height_points()
        && viewport.vertical_offset_points() == display.vertical_offset_points()
        && v.backing_scale == backing_scale;
    for (i, p) in scene.primitives.iter().enumerate() {
        checkpoint(i, check)?;
        let t = &scene.tracks[p.track_index as usize];
        if !row_contains(t, point) {
            continue;
        }
        let range = TraceTimeRange::event(p.start_ns, p.end_ns)?;
        if !is_visible(range, display) {
            continue;
        }
        if p.kind == WIRE_PRIMITIVE_DETAIL && mode != HotSnapshotHitMode::Density {
            let rectangle = if reuse_frames {
                frame(p)
            } else {
                detail_frame_for(
                    range,
                    p.depth,
                    t.y,
                    t.height,
                    t.depth_rows as usize,
                    display,
                    backing_scale,
                )?
            };
            if !rectangle.expanded(1.0).contains(point) {
                continue;
            }
            let rank = (style(p.style)?.z_order(), i);
            if detail.is_none_or(|(s, n, _)| rank > (s, n)) {
                detail = Some((
                    rank.0,
                    rank.1,
                    EventKey {
                        table: table(p.event_table)?,
                        row_id: p.row_id,
                    },
                ));
            }
        } else if p.kind == WIRE_PRIMITIVE_DENSITY
            && mode != HotSnapshotHitMode::Detail
            && density.is_none()
            && p.start_ns <= time
            && time <= p.end_ns
        {
            density = Some((p.track_index as usize, i, time));
        }
    }
    check()?;
    let output = if let Some((_, _, event_key)) = detail {
        Some(HitIntent::Detail { event_key })
    } else if let Some((ti, pi, time_ns)) = density {
        let t = &scene.tracks[ti];
        let p = &scene.primitives[pi];
        let required = size_of::<HitIntent>()
            .checked_add(t.id_length as usize)
            .ok_or(ViewerError::ArithmeticOverflow)?;
        if required > budget.maximum_output_bytes.min(65536) {
            return Err(ViewerError::InputBudgetExceeded);
        }
        let id = text(scene, t.id_offset, t.id_length, &mut work, budget, check)?;
        let mut track_id = String::new();
        track_id
            .try_reserve_exact(id.len())
            .map_err(|_| ViewerError::InputBudgetExceeded)?;
        track_id.push_str(id);
        let bucket = TraceTimeRange::query(p.start_ns, p.end_ns)?;
        Some(HitIntent::Density {
            intent: DensityHitIntent::new(track_id, source(t)?, bucket, time_ns)?,
        })
    } else {
        None
    };
    if output.is_some() && size_of::<HitIntent>() > budget.maximum_output_bytes.min(65536) {
        return Err(ViewerError::InputBudgetExceeded);
    }
    check()?;
    Ok(output)
}
