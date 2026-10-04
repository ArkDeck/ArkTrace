//! Bounded semantic labels/colors. These facts are not an invented inspector.
//! Host keeps repository pages and quality provenance; no diagnostics/paths API.
use crate::*;
use arktrace_contract::*;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
pub const MAXIMUM_PRESENTATION_INPUT_BYTES: usize = 8 * 1024 * 1024;
pub const MAXIMUM_PRESENTATION_RETAINED_STRING_BYTES: usize = 4 * 1024 * 1024;
pub const MAXIMUM_PRESENTATION_RETAINED_BYTES: usize = 16 * 1024 * 1024;
pub const MAXIMUM_PRESENTATION_LABEL_BYTES: usize = 2 * MAXIMUM_PALETTE_INPUT_BYTES + 64;
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PresentationKind {
    CpuSlice,
    ThreadState,
    NamedSlice,
    Counter,
    Frame,
}
#[derive(Clone, Copy, Debug, Default)]
pub struct DetailColorInput<'a> {
    pub kind: Option<PresentationKind>,
    pub label: Option<&'a str>,
    pub category: Option<&'a str>,
    pub name: Option<&'a str>,
    pub state: Option<&'a str>,
    pub pid: Option<i64>,
    pub tid: Option<i64>,
    pub jank_tag: i64,
}
fn normalized(category: Option<&str>) -> Option<TraceThreadState> {
    match category {
        Some("running") => Some(TraceThreadState::Running),
        Some("runnable") => Some(TraceThreadState::Runnable),
        Some("sleeping") => Some(TraceThreadState::Sleeping),
        Some("blocked") => Some(TraceThreadState::Blocked),
        Some("stopped") => Some(TraceThreadState::Stopped),
        _ => None,
    }
}
pub fn detail_color(
    input: DetailColorInput<'_>,
    check: &mut Check<'_>,
) -> Result<ResolvedColor, ViewerError> {
    check()?;
    for text in [input.label, input.category, input.name, input.state]
        .into_iter()
        .flatten()
    {
        if text.len() > MAXIMUM_PRESENTATION_LABEL_BYTES {
            return Err(ViewerError::InputBudgetExceeded);
        }
    }
    match input.kind {
        Some(PresentationKind::CpuSlice) => process_thread_color(input.pid, input.tid, check),
        Some(PresentationKind::ThreadState) => {
            state_color(input.state.or(input.label), normalized(input.category))
        }
        Some(PresentationKind::Frame) => Ok(jank_color(input.jank_tag)),
        None if input.category == Some("cpu") => process_thread_color(None, None, check),
        None if normalized(input.category).is_some() => {
            state_color(input.label, normalized(input.category))
        }
        _ => match input.kind.and(input.name).or(input.label) {
            Some(name) if !name.is_empty() => slice_name_color(name, 0, check),
            _ => Ok(grey_color()),
        },
    }
}
pub fn cpu_slice_label(
    process_name: Option<&str>,
    thread_name: Option<&str>,
    tid: Option<i64>,
) -> Result<Option<String>, ViewerError> {
    for name in [process_name, thread_name].into_iter().flatten() {
        palette_string(name)?;
    }
    let names: Vec<_> = [process_name, thread_name]
        .into_iter()
        .flatten()
        .filter(|n| !n.is_empty())
        .collect();
    if names.is_empty() {
        return Ok(tid.map(|tid| format!("TID {tid}")));
    }
    let suffix = tid.map(|tid| format!(" [{tid}]")).unwrap_or_default();
    Ok(Some(names.join(" · ") + &suffix))
}
pub fn frame_label(frame: &TraceFrame, jank_tag: i64) -> String {
    format!(
        "vsync {} {}{}",
        frame.vsync,
        if frame.kind == TraceFrameKind::Expected {
            "expected"
        } else {
            "actual"
        },
        if jank_tag != 0 { " · jank" } else { "" }
    )
}
pub fn jank_state_text(tag: i64) -> &'static str {
    match tag {
        1 => "jank",
        3 => "jank (deadline missed)",
        _ => "on time",
    }
}
fn state_name(state: TraceThreadState) -> &'static str {
    match state {
        TraceThreadState::Running => "running",
        TraceThreadState::Runnable => "runnable",
        TraceThreadState::Sleeping => "sleeping",
        TraceThreadState::Blocked => "blocked",
        TraceThreadState::Stopped => "stopped",
    }
}
#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PresentationBudget {
    pub maximum_primitives: usize,
    pub maximum_input_string_bytes: usize,
    pub maximum_retained_string_bytes: usize,
    pub maximum_retained_bytes: usize,
}
impl Default for PresentationBudget {
    fn default() -> Self {
        Self {
            maximum_primitives: MAXIMUM_PRIMITIVES,
            maximum_input_string_bytes: MAXIMUM_PRESENTATION_INPUT_BYTES,
            maximum_retained_string_bytes: MAXIMUM_PRESENTATION_RETAINED_STRING_BYTES,
            maximum_retained_bytes: MAXIMUM_PRESENTATION_RETAINED_BYTES,
        }
    }
}
impl PresentationBudget {
    fn validate(self) -> Result<(), ViewerError> {
        if self.maximum_primitives > MAXIMUM_PRIMITIVES
            || self.maximum_input_string_bytes > MAXIMUM_PRESENTATION_INPUT_BYTES
            || self.maximum_retained_string_bytes > MAXIMUM_PRESENTATION_RETAINED_STRING_BYTES
            || self.maximum_retained_bytes > MAXIMUM_PRESENTATION_RETAINED_BYTES
        {
            Err(ViewerError::InvalidRequest)
        } else {
            Ok(())
        }
    }
}
#[derive(Clone, Copy, Debug)]
pub enum PresentationInput<'a> {
    Cpu(&'a CpuSlice),
    ThreadState(&'a ThreadStateInterval),
    NamedSlice {
        event: &'a TraceSlice,
        shows_nested_depth: bool,
    },
    Frame(&'a TraceFrame),
    Counter {
        series: &'a CounterSeries,
        sample_index: usize,
        query_range: TraceTimeRange,
    },
    Density {
        bucket: &'a TraceDensityBucket,
        track: &'a TrackDescriptor,
    },
}
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PresentationIdentity {
    pub process_key: Option<ProcessKey>,
    pub thread_key: Option<ThreadKey>,
    pub pid: Option<i64>,
    pub tid: Option<i64>,
}
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DetailPresentation {
    pub event_key: EventKey,
    pub kind: PresentationKind,
    pub range: TraceTimeRange,
    pub is_open_ended: bool,
    pub is_instant: bool,
    pub depth: i64,
    pub jank_tag: i64,
    pub identity: PresentationIdentity,
    pub label: Option<u32>,
    pub category: Option<u32>,
    pub state: Option<u32>,
    pub style: DetailStyle,
    pub color: ResolvedColor,
}
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DensityPresentation {
    pub range: TraceTimeRange,
    pub event_count: i64,
    pub color: ResolvedColor,
    pub intensity: u8,
    pub height_fraction: f64,
    pub uses_track_fallback: bool,
}
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum PrimitivePresentation {
    Detail { detail: DetailPresentation },
    Density { density: DensityPresentation },
}
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PresentationBatch {
    strings: Vec<String>,
    primitives: Vec<PrimitivePresentation>,
    input_string_bytes: usize,
    retained_string_bytes: usize,
    retained_bytes: usize,
}
impl PresentationBatch {
    pub fn strings(&self) -> &[String] {
        &self.strings
    }
    pub fn primitives(&self) -> &[PrimitivePresentation] {
        &self.primitives
    }
    pub fn input_string_bytes(&self) -> usize {
        self.input_string_bytes
    }
    pub fn retained_string_bytes(&self) -> usize {
        self.retained_string_bytes
    }
    pub fn retained_bytes(&self) -> usize {
        self.retained_bytes
    }
    pub fn text(&self, index: Option<u32>) -> Option<&str> {
        index.and_then(|i| self.strings.get(i as usize).map(String::as_str))
    }
}
struct Builder {
    strings: BTreeMap<String, u32>,
    retained: usize,
    budget: PresentationBudget,
    fixed_bytes: usize,
}
impl Builder {
    fn intern(&mut self, text: Option<&str>) -> Result<Option<u32>, ViewerError> {
        let Some(text) = text else {
            return Ok(None);
        };
        if text.len() > MAXIMUM_PRESENTATION_LABEL_BYTES {
            return Err(ViewerError::InputBudgetExceeded);
        }
        if let Some(index) = self.strings.get(text) {
            return Ok(Some(*index));
        }
        let retained = self
            .retained
            .checked_add(text.len())
            .ok_or(ViewerError::InputBudgetExceeded)?;
        if retained > self.budget.maximum_retained_string_bytes
            || self.strings.len() >= 3 * MAXIMUM_PRIMITIVES
        {
            return Err(ViewerError::InputBudgetExceeded);
        }
        let total = self
            .fixed_bytes
            .checked_add(retained)
            .and_then(|n| n.checked_add((self.strings.len() + 1) * std::mem::size_of::<String>()))
            .ok_or(ViewerError::InputBudgetExceeded)?;
        if total > self.budget.maximum_retained_bytes {
            return Err(ViewerError::InputBudgetExceeded);
        }
        let index = self.strings.len() as u32;
        self.strings.insert(text.to_owned(), index);
        self.retained = retained;
        Ok(Some(index))
    }
    fn detail(
        &mut self,
        primitive: DetailInput,
        kind: PresentationKind,
        text: (Option<&str>, Option<&str>, Option<&str>),
        identity: PresentationIdentity,
        jank_tag: i64,
        check: &mut Check<'_>,
    ) -> Result<PrimitivePresentation, ViewerError> {
        let (label, category, state) = text;
        let color = detail_color(
            DetailColorInput {
                kind: Some(kind),
                label,
                category,
                state,
                pid: identity.pid,
                tid: identity.tid,
                jank_tag,
                ..Default::default()
            },
            check,
        )?;
        Ok(PrimitivePresentation::Detail {
            detail: DetailPresentation {
                event_key: primitive.event_key,
                kind,
                range: primitive.range,
                is_open_ended: primitive.is_open_ended,
                is_instant: primitive.is_instant(),
                depth: primitive.depth,
                jank_tag,
                identity,
                label: self.intern(label)?,
                category: self.intern(category)?,
                state: self.intern(state)?,
                style: primitive.style,
                color,
            },
        })
    }
}
fn input_texts(input: PresentationInput<'_>) -> Vec<&str> {
    match input {
        PresentationInput::Cpu(e) => [
            e.process_name.as_deref(),
            e.thread_name.as_deref(),
            e.end_state.as_deref(),
        ]
        .into_iter()
        .flatten()
        .collect(),
        PresentationInput::ThreadState(e) => [
            Some(e.state.as_str()),
            e.process_name.as_deref(),
            e.thread_name.as_deref(),
        ]
        .into_iter()
        .flatten()
        .collect(),
        PresentationInput::NamedSlice { event: e, .. } => [
            Some(e.name.as_str()),
            e.category.as_deref(),
            e.process_name.as_deref(),
            e.thread_name.as_deref(),
        ]
        .into_iter()
        .flatten()
        .collect(),
        PresentationInput::Frame(e) => e.process_name.as_deref().into_iter().collect(),
        PresentationInput::Counter { series, .. } => [
            Some(series.name.as_str()),
            series.process_name.as_deref(),
            series.unit.as_deref(),
        ]
        .into_iter()
        .flatten()
        .collect(),
        PresentationInput::Density { bucket, .. } => match &bucket.dominant {
            Some(TraceDensityIdentity::Name { name }) => vec![name],
            Some(TraceDensityIdentity::ThreadState { state }) => vec![state],
            _ => vec![],
        },
    }
}
fn primitive(
    key: EventKey,
    expected: EventTable,
    range: TraceTimeRange,
    depth: i64,
    style: DetailStyle,
    is_open_ended: bool,
) -> Result<DetailInput, ViewerError> {
    if key.table != expected {
        return Err(ViewerError::InvalidEvidence);
    }
    Ok(DetailInput {
        event_key: key,
        range,
        depth,
        style,
        is_open_ended,
    })
}
/// Counts every referenced source-string occurrence (not unique strings), then
/// retains each label/category/state once in first-occurrence pool order.
/// No whole source DTO/string is cloned; all-or-error publication.
pub fn present(
    inputs: &[PresentationInput<'_>],
    budget: PresentationBudget,
    check: &mut Check<'_>,
) -> Result<PresentationBatch, ViewerError> {
    check()?;
    budget.validate()?;
    if inputs.len() > budget.maximum_primitives {
        return Err(ViewerError::InputBudgetExceeded);
    }
    let mut input_bytes = 0_usize;
    for (i, input) in inputs.iter().enumerate() {
        checkpoint(i, check)?;
        for text in input_texts(*input) {
            palette_string(text)?;
            input_bytes = input_bytes
                .checked_add(text.len())
                .ok_or(ViewerError::InputBudgetExceeded)?;
            if input_bytes > budget.maximum_input_string_bytes {
                return Err(ViewerError::InputBudgetExceeded);
            }
        }
    }
    let fixed_bytes = std::mem::size_of::<PresentationBatch>()
        .checked_add(inputs.len() * std::mem::size_of::<PrimitivePresentation>())
        .ok_or(ViewerError::InputBudgetExceeded)?;
    if fixed_bytes > budget.maximum_retained_bytes {
        return Err(ViewerError::InputBudgetExceeded);
    }
    let mut builder = Builder {
        strings: BTreeMap::new(),
        retained: 0,
        budget,
        fixed_bytes,
    };
    let mut output = Vec::with_capacity(inputs.len());
    for (i, input) in inputs.iter().enumerate() {
        checkpoint(i, check)?;
        let result = match *input {
            PresentationInput::Cpu(e) => {
                let label =
                    cpu_slice_label(e.process_name.as_deref(), e.thread_name.as_deref(), e.tid)?;
                builder.detail(
                    primitive(
                        e.key,
                        EventTable::SchedSlice,
                        e.range,
                        0,
                        DetailStyle::Running,
                        e.is_open_ended,
                    )?,
                    PresentationKind::CpuSlice,
                    (label.as_deref(), Some("cpu"), None),
                    PresentationIdentity {
                        process_key: e.process_key,
                        thread_key: e.thread_key,
                        pid: e.pid,
                        tid: e.tid,
                    },
                    0,
                    check,
                )?
            }
            PresentationInput::ThreadState(e) => {
                let category = e.normalized_state.map(state_name).unwrap_or("unknown");
                builder.detail(
                    primitive(
                        e.key,
                        EventTable::ThreadState,
                        e.range,
                        0,
                        DetailStyle::from_category(Some(category)),
                        e.is_open_ended,
                    )?,
                    PresentationKind::ThreadState,
                    (
                        Some(e.state.as_str()),
                        Some(category),
                        Some(e.state.as_str()),
                    ),
                    PresentationIdentity {
                        process_key: e.process_key,
                        thread_key: Some(e.thread_key),
                        pid: e.pid,
                        tid: e.tid,
                    },
                    0,
                    check,
                )?
            }
            PresentationInput::NamedSlice {
                event: e,
                shows_nested_depth,
            } => builder.detail(
                primitive(
                    e.key,
                    EventTable::Callstack,
                    e.range,
                    if shows_nested_depth {
                        e.depth.unwrap_or(0).max(0)
                    } else {
                        0
                    },
                    DetailStyle::from_category(e.category.as_deref()),
                    e.is_open_ended,
                )?,
                PresentationKind::NamedSlice,
                (Some(e.name.as_str()), e.category.as_deref(), None),
                PresentationIdentity {
                    process_key: e.process_key,
                    thread_key: e.thread_key,
                    pid: e.pid,
                    tid: e.tid,
                },
                0,
                check,
            )?,
            PresentationInput::Frame(e) => {
                let tag = TraceFrame::jank_tag(e.flag);
                let label = frame_label(e, tag);
                builder.detail(
                    primitive(
                        e.key,
                        EventTable::FrameSlice,
                        e.range,
                        if e.kind == TraceFrameKind::Expected {
                            0
                        } else {
                            1
                        },
                        DetailStyle::Accent,
                        e.is_open_ended,
                    )?,
                    PresentationKind::Frame,
                    (
                        Some(label.as_str()),
                        Some("frame"),
                        Some(jank_state_text(tag)),
                    ),
                    PresentationIdentity {
                        process_key: e.process_key,
                        thread_key: e.thread_key,
                        pid: e.pid,
                        tid: None,
                    },
                    tag,
                    check,
                )?
            }
            PresentationInput::Counter {
                series,
                sample_index,
                query_range,
            } => {
                let sample = series
                    .samples
                    .get(sample_index)
                    .ok_or(ViewerError::InvalidEvidence)?;
                let end = match sample.duration_ns {
                    Some(n) if n >= 0 => sample
                        .timestamp_ns
                        .checked_add(n)
                        .ok_or(ViewerError::ArithmeticOverflow)?,
                    Some(_) => return Err(ViewerError::InvalidEvidence),
                    None => query_range.end_ns().max(sample.timestamp_ns),
                };
                let range = TraceTimeRange::event(sample.timestamp_ns, end)?;
                let table = if series.scope == CounterScope::Cpu {
                    EventTable::Measure
                } else {
                    EventTable::ProcessMeasure
                };
                builder.detail(
                    primitive(
                        sample.key,
                        table,
                        range,
                        0,
                        DetailStyle::Counter,
                        sample.duration_ns.is_none(),
                    )?,
                    PresentationKind::Counter,
                    (Some(series.name.as_str()), Some("counter"), None),
                    PresentationIdentity {
                        process_key: series.process_key,
                        pid: series.pid,
                        ..Default::default()
                    },
                    0,
                    check,
                )?
            }
            PresentationInput::Density { bucket, track } => {
                if bucket.range.is_instant() || bucket.event_count < 0 {
                    return Err(ViewerError::InvalidEvidence);
                }
                let intensity = density_intensity(bucket.event_count);
                PrimitivePresentation::Density {
                    density: DensityPresentation {
                        range: bucket.range,
                        event_count: bucket.event_count,
                        color: density_color(bucket.dominant.as_ref(), track, check)?,
                        intensity,
                        height_fraction: density_height_fraction(intensity as i64),
                        uses_track_fallback: bucket.dominant.is_none(),
                    },
                }
            }
        };
        output.push(result);
    }
    check()?;
    let mut strings = vec![String::new(); builder.strings.len()];
    for (i, (text, index)) in builder.strings.into_iter().enumerate() {
        checkpoint(i, check)?;
        strings[index as usize] = text;
    }
    let retained_bytes = std::mem::size_of::<PresentationBatch>()
        + output.capacity() * std::mem::size_of::<PrimitivePresentation>()
        + strings.capacity() * std::mem::size_of::<String>()
        + strings.iter().map(String::capacity).sum::<usize>();
    if retained_bytes > budget.maximum_retained_bytes {
        return Err(ViewerError::InputBudgetExceeded);
    }
    check()?;
    Ok(PresentationBatch {
        strings,
        primitives: output,
        input_string_bytes: input_bytes,
        retained_string_bytes: builder.retained,
        retained_bytes,
    })
}
