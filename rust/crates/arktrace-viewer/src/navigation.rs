//! Real-event projections and explicit navigation intents; no repository IO.
use crate::{Check, MAXIMUM_PRIMITIVES, MAXIMUM_TRACKS, ViewerError, checkpoint};
use arktrace_contract::{EventKey, EventTable, TraceDensitySource, TraceTimeRange};
use serde::{Deserialize, Serialize};
pub const NAVIGATION_API_VERSION: u32 = 1;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ViewIdentity {
    pub session_id: u64,
    pub generation: u64,
}

/// Overflow-safe extension of the current revealRange. Swift traps on
/// duration*4 overflow; the mathematical capped padding is representable.
pub fn reveal_range(
    event: TraceTimeRange,
    bounds: TraceTimeRange,
) -> Result<Option<TraceTimeRange>, ViewerError> {
    if bounds.is_instant() {
        return Ok(None);
    }
    let padding = (bounds.duration_ns() / 20)
        .min(event.duration_ns().saturating_mul(4).max(1))
        .max(1);
    let start = bounds
        .start_ns()
        .max(event.start_ns() - event.start_ns().min(padding));
    let end = bounds.end_ns().min(event.end_ns().saturating_add(padding));
    if start >= end {
        Ok(None)
    } else {
        Ok(Some(TraceTimeRange::query(start, end)?))
    }
}

/// First/last admission and nonwrapping search cursor behavior. A stale
/// out-of-range cursor is rejected instead of overflowing integer arithmetic.
pub fn step_search_index(count: usize, selection: Option<usize>, delta: i64) -> Option<usize> {
    if count == 0 || delta == 0 {
        return None;
    }
    match selection {
        None => Some(if delta > 0 { 0 } else { count - 1 }),
        Some(index) if index < count => {
            let target = i128::try_from(index).ok()? + i128::from(delta);
            usize::try_from(target).ok().filter(|t| *t < count)
        }
        _ => None,
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NavigationEvent {
    pub key: EventKey,
    pub range: TraceTimeRange,
    pub is_open_ended: bool,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NavigationLane {
    #[serde(rename = "trackID")]
    pub track_id: String,
    pub events: Vec<NavigationEvent>,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EventFocus {
    #[serde(rename = "trackID")]
    pub track_id: String,
    pub key: EventKey,
}
fn table_order(table: EventTable) -> &'static str {
    match table {
        EventTable::SchedSlice => "sched_slice",
        EventTable::ThreadState => "thread_state",
        EventTable::Callstack => "callstack",
        EventTable::Measure => "measure",
        EventTable::ProcessMeasure => "process_measure",
        EventTable::FrameSlice => "frame_slice",
    }
}
/// Native moveEvent sorts the displayed real details within the current lane.
/// Density buckets must not be passed as events. Moving changes focus only;
/// selecting that focus is a separate host action.
pub fn step_displayed_event(
    lanes: &[NavigationLane],
    focused: Option<&EventFocus>,
    selected: Option<EventKey>,
    delta: i64,
    check: &mut Check<'_>,
) -> Result<Option<EventFocus>, ViewerError> {
    check()?;
    if lanes.len() > MAXIMUM_TRACKS {
        return Err(ViewerError::InputBudgetExceeded);
    }
    let mut retained = 0;
    if let Some(focused) = focused {
        crate::track_tree::id_budget(&focused.track_id, &mut retained)?;
    }
    crate::track_tree::logical_budget::<NavigationLane>(lanes.len(), &mut retained)?;
    let mut count = 0;
    for (i, lane) in lanes.iter().enumerate() {
        checkpoint(i, check)?;
        crate::track_tree::id_budget(&lane.track_id, &mut retained)?;
        count += lane.events.len();
        if count > MAXIMUM_PRIMITIVES {
            return Err(ViewerError::InputBudgetExceeded);
        }
        crate::track_tree::logical_budget::<NavigationEvent>(lane.events.len(), &mut retained)?;
        for j in 0..lane.events.len() {
            checkpoint(j, check)?;
        }
    }
    let key = focused.map(|f| f.key).or(selected);
    // Canonical currentFocusLocation searches EventKey in original lane order,
    // even when the key appears in multiple CPU lanes; track hint is not used.
    let current = key.and_then(|key| {
        lanes
            .iter()
            .enumerate()
            .find_map(|(i, l)| l.events.iter().find(|e| e.key == key).map(|e| (i, e)))
    });
    let lane_index = current
        .map(|(i, _)| i)
        .or_else(|| lanes.iter().position(|l| !l.events.is_empty()));
    let Some(lane_index) = lane_index else {
        return Ok(None);
    };
    let lane = &lanes[lane_index];
    let mut events: Vec<_> = lane.events.iter().collect();
    events.sort_by_key(|e| (e.range.start_ns(), table_order(e.key.table), e.key.row_id));
    check()?;
    let index = current
        .and_then(|(_, e)| events.iter().position(|p| p.key == e.key))
        .map(|i| i as i128)
        .unwrap_or(if delta < 0 { events.len() as i128 } else { -1 });
    let target = (index + i128::from(delta)).clamp(0, events.len() as i128 - 1) as usize;
    let candidate = EventFocus {
        track_id: lane.track_id.clone(),
        key: events[target].key,
    };
    check()?;
    Ok(if focused == Some(&candidate) {
        None
    } else {
        Some(candidate)
    })
}

/// Native moveTrack skips empty/density-only lanes in the requested direction
/// and chooses the nearest real start, keeping sorted order for equal distance.
pub fn step_displayed_track(
    lanes: &[NavigationLane],
    focused: Option<&EventFocus>,
    selected: Option<EventKey>,
    viewport: TraceTimeRange,
    delta: i64,
    check: &mut Check<'_>,
) -> Result<Option<EventFocus>, ViewerError> {
    // Reuse bounded projection validation, without treating its answer as a move.
    let _ = step_displayed_event(lanes, focused, selected, 0, check)?;
    let key = focused.map(|f| f.key).or(selected);
    let current = key.and_then(|key| {
        lanes
            .iter()
            .enumerate()
            .find_map(|(i, l)| l.events.iter().find(|e| e.key == key).map(|e| (i, e)))
    });
    let origin =
        current
            .map(|(i, _)| i as i128)
            .unwrap_or(if delta < 0 { lanes.len() as i128 } else { -1 });
    let mut candidate = origin + i128::from(delta);
    let mut scanned = 0;
    while candidate >= 0 && candidate < lanes.len() as i128 {
        checkpoint(scanned, check)?;
        scanned += 1;
        let lane = &lanes[candidate as usize];
        if !lane.events.is_empty() {
            let anchor = current
                .map(|(_, e)| e.range.start_ns())
                .unwrap_or(viewport.start_ns());
            let mut events: Vec<_> = lane.events.iter().collect();
            events.sort_by_key(|e| (e.range.start_ns(), table_order(e.key.table), e.key.row_id));
            check()?;
            let event = events
                .into_iter()
                .min_by_key(|e| e.range.start_ns().abs_diff(anchor))
                .unwrap();
            let next = EventFocus {
                track_id: lane.track_id.clone(),
                key: event.key,
            };
            return Ok(if focused == Some(&next) {
                None
            } else {
                Some(next)
            });
        }
        candidate += i128::from(delta);
    }
    check()?;
    Ok(None)
}

/// The WASD pointer anchor differs from +/-: selection, real focus, center
/// remain the fallback chain. Pointer coordinates are resolved by geometry.
pub fn navigation_zoom_anchor(
    viewport: TraceTimeRange,
    selection: Option<TraceTimeRange>,
    focused_event: Option<TraceTimeRange>,
    pointer_ns: Option<i64>,
    uses_pointer: bool,
) -> i64 {
    if uses_pointer && let Some(pointer) = pointer_ns {
        return pointer;
    }
    if let Some(selection) = selection {
        return selection.start_ns() + selection.duration_ns() / 2;
    }
    if let Some(focused) = focused_event {
        return focused.start_ns();
    }
    viewport.start_ns() + viewport.duration_ns() / 2
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EventNavigationDirection {
    Previous,
    Next,
}
/// Proposal for repository stepping beyond displayed detail. This is a query
/// intent, not evidence that any adjacent event exists. Engine owns bounded
/// execution, cancellation, session validation and genuine result admission.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EventNavigationQueryIntent {
    pub identity: ViewIdentity,
    pub source: TraceDensitySource,
    pub anchor_ns: i64,
    pub after_event: Option<EventKey>,
    pub direction: EventNavigationDirection,
    pub limit: usize,
}
impl EventNavigationQueryIntent {
    pub fn validate(&self) -> Result<(), ViewerError> {
        if self.anchor_ns < 0 || !(1..=1_000).contains(&self.limit) {
            Err(ViewerError::InvalidRequest)
        } else if self.after_event.is_some_and(|key| {
            key.table
                != match self.source {
                    TraceDensitySource::Cpu { .. } => EventTable::SchedSlice,
                    TraceDensitySource::ThreadState { .. } => EventTable::ThreadState,
                    TraceDensitySource::NamedSlice { .. } => EventTable::Callstack,
                    TraceDensitySource::CpuCounter { .. } => EventTable::Measure,
                    TraceDensitySource::ProcessCounter { .. } => EventTable::ProcessMeasure,
                    TraceDensitySource::Frame { .. } => EventTable::FrameSlice,
                }
        }) {
            Err(ViewerError::InvalidEvidence)
        } else {
            Ok(())
        }
    }
}
