//! Pure immutable event facts. No queries, disk IO, args, colors, formatting,
//! selection, or host layout. Identity is ipid/itid, never PID/TID inference.
use crate::{frame_label, jank_state_text};
use arktrace_contract::{
    CounterSample, CounterScope, CounterSeriesDescriptor, CpuSlice, EventKey, EventTable,
    ProcessKey, ThreadKey, ThreadStateInterval, TraceFrame, TraceSlice, TraceThreadState,
    TraceTimeRange,
};
use serde::Serialize;
use std::{collections::BTreeMap, mem::size_of};

pub const INSPECTOR_PROJECTION_API_VERSION: u32 = 1;
pub const MAXIMUM_INSPECTOR_RECORDS: u32 = 4096;
pub const MAXIMUM_INSPECTOR_TEXT_BYTES: u32 = 4096;
pub const MAXIMUM_INSPECTOR_INPUT_STRING_BYTES: u32 = 4 * 1024 * 1024;
pub const MAXIMUM_INSPECTOR_RETAINED_STRING_BYTES: u32 = 4 * 1024 * 1024;
pub const MAXIMUM_INSPECTOR_RETAINED_BYTES: u32 = 8 * 1024 * 1024;
#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum InspectorProjectionError {
    UnsupportedVersion = 1,
    InvalidRequest = 2,
    InvalidEventKey = 3,
    InputBudgetExceeded = 4,
    RetainedBudgetExceeded = 5,
    ArithmeticOverflow = 6,
    Cancelled = 7,
    DeadlineReached = 8,
}
impl std::fmt::Display for InspectorProjectionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for InspectorProjectionError {}
pub type InspectorProjectionCheck<'a> = dyn FnMut() -> Result<(), InspectorProjectionError> + 'a;
#[derive(Clone, Copy, Debug)]
pub struct InspectorProjectionBudget {
    pub maximum_records: u32,
    pub maximum_input_string_bytes: u32,
    pub maximum_retained_string_bytes: u32,
    pub maximum_retained_bytes: u32,
}
impl Default for InspectorProjectionBudget {
    fn default() -> Self {
        Self {
            maximum_records: MAXIMUM_INSPECTOR_RECORDS,
            maximum_input_string_bytes: MAXIMUM_INSPECTOR_INPUT_STRING_BYTES,
            maximum_retained_string_bytes: MAXIMUM_INSPECTOR_RETAINED_STRING_BYTES,
            maximum_retained_bytes: MAXIMUM_INSPECTOR_RETAINED_BYTES,
        }
    }
}
impl InspectorProjectionBudget {
    fn validate(self) -> Result<(), InspectorProjectionError> {
        if self.maximum_records > MAXIMUM_INSPECTOR_RECORDS
            || self.maximum_input_string_bytes > MAXIMUM_INSPECTOR_INPUT_STRING_BYTES
            || self.maximum_retained_string_bytes > MAXIMUM_INSPECTOR_RETAINED_STRING_BYTES
            || self.maximum_retained_bytes > MAXIMUM_INSPECTOR_RETAINED_BYTES
        {
            Err(InspectorProjectionError::InvalidRequest)
        } else {
            Ok(())
        }
    }
}
#[derive(Clone, Copy, Debug)]
pub enum InspectorProjectionInput<'a> {
    CpuSlice(&'a CpuSlice),
    ThreadState(&'a ThreadStateInterval),
    NamedSlice(&'a TraceSlice),
    Frame(&'a TraceFrame),
    Counter {
        series: &'a CounterSeriesDescriptor,
        sample: &'a CounterSample,
        query_range: TraceTimeRange,
    },
    /// Density has no source detail DTO and no EventKey/Inspector. Keeps row alignment.
    DensityBand,
}
#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum InspectorEventKind {
    CpuSlice = 1,
    ThreadState = 2,
    NamedSlice = 3,
    Counter = 4,
    Frame = 5,
}
/// Scalars and indices are immutable. Resolve text through the owning batch.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InspectorFacts {
    key: EventKey,
    kind: InspectorEventKind,
    range: TraceTimeRange,
    semantic_duration_ns: Option<i64>,
    is_open_ended: bool,
    process_key: Option<ProcessKey>,
    thread_key: Option<ThreadKey>,
    pid: Option<i64>,
    tid: Option<i64>,
    cpu: Option<i64>,
    name: Option<u32>,
    process_name: Option<u32>,
    thread_name: Option<u32>,
    category: Option<u32>,
    state: Option<u32>,
    value: Option<i64>,
    unit: Option<u32>,
    priority: Option<i64>,
}
impl InspectorFacts {
    pub const fn key(self) -> EventKey {
        self.key
    }
    pub const fn kind(self) -> InspectorEventKind {
        self.kind
    }
    pub const fn range(self) -> TraceTimeRange {
        self.range
    }
    pub const fn semantic_duration_ns(self) -> Option<i64> {
        self.semantic_duration_ns
    }
    pub const fn is_open_ended(self) -> bool {
        self.is_open_ended
    }
    pub const fn process_key(self) -> Option<ProcessKey> {
        self.process_key
    }
    pub const fn thread_key(self) -> Option<ThreadKey> {
        self.thread_key
    }
    pub const fn pid(self) -> Option<i64> {
        self.pid
    }
    pub const fn tid(self) -> Option<i64> {
        self.tid
    }
    pub const fn cpu(self) -> Option<i64> {
        self.cpu
    }
    pub const fn name(self) -> Option<u32> {
        self.name
    }
    pub const fn process_name(self) -> Option<u32> {
        self.process_name
    }
    pub const fn thread_name(self) -> Option<u32> {
        self.thread_name
    }
    pub const fn category(self) -> Option<u32> {
        self.category
    }
    pub const fn state(self) -> Option<u32> {
        self.state
    }
    pub const fn value(self) -> Option<i64> {
        self.value
    }
    pub const fn unit(self) -> Option<u32> {
        self.unit
    }
    pub const fn priority(self) -> Option<i64> {
        self.priority
    }

    pub fn is_instant(self) -> bool {
        self.semantic_duration_ns == Some(0) && !self.is_open_ended
    }
    fn base(
        key: EventKey,
        kind: InspectorEventKind,
        range: TraceTimeRange,
        is_open_ended: bool,
    ) -> Self {
        Self {
            key,
            kind,
            range,
            semantic_duration_ns: if is_open_ended {
                None
            } else {
                Some(range.duration_ns())
            },
            is_open_ended,
            process_key: None,
            thread_key: None,
            pid: None,
            tid: None,
            cpu: None,
            name: None,
            process_name: None,
            thread_name: None,
            category: None,
            state: None,
            value: None,
            unit: None,
            priority: None,
        }
    }
}
/// Each output position is Some(facts) or None for a density band. Nil text and
/// empty text have distinct representations. No callers can grow/edit buffers.
/// ```compile_fail
/// use arktrace_viewer::InspectorProjectionBatch;
/// fn grow(batch: &mut InspectorProjectionBatch) { batch.strings.reserve(9_000_000); }
/// ```
/// ```compile_fail
/// use arktrace_viewer::InspectorProjectionBatch;
/// fn edit(batch: &mut InspectorProjectionBatch) { batch.strings()[0].push_str("edit"); }
/// ```
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InspectorProjectionBatch {
    api_version: u32,
    strings: Vec<String>,
    records: Vec<Option<InspectorFacts>>,
    input_string_bytes: u64,
}
impl InspectorProjectionBatch {
    pub fn api_version(&self) -> u32 {
        self.api_version
    }
    pub fn strings(&self) -> &[String] {
        &self.strings
    }
    pub fn records(&self) -> &[Option<InspectorFacts>] {
        &self.records
    }
    pub fn text(&self, index: Option<u32>) -> Option<&str> {
        index
            .and_then(|index| self.strings.get(index as usize))
            .map(String::as_str)
    }
    pub fn input_string_bytes(&self) -> u64 {
        self.input_string_bytes
    }
    pub fn retained_string_bytes(&self) -> u64 {
        self.strings.iter().map(|s| s.capacity() as u64).sum()
    }
    /// Current allocations, including spare Vec slots and String capacity.
    /// Excludes allocator headers, borrowed inputs, index scratch and encoding.
    pub fn retained_bytes(&self) -> u64 {
        (size_of::<Self>()
            + self.records.capacity() * size_of::<Option<InspectorFacts>>()
            + self.strings.capacity() * size_of::<String>()) as u64
            + self.retained_string_bytes()
    }
}
struct Builder {
    strings: BTreeMap<String, u32>,
    string_capacity: usize,
    fixed_bytes: usize,
    budget: InspectorProjectionBudget,
}
impl Builder {
    fn intern(
        &mut self,
        text: Option<&str>,
        check: &mut InspectorProjectionCheck<'_>,
    ) -> Result<Option<u32>, InspectorProjectionError> {
        check()?;
        let Some(text) = text else { return Ok(None) };
        if text.len() > MAXIMUM_INSPECTOR_TEXT_BYTES as usize {
            return Err(InspectorProjectionError::InputBudgetExceeded);
        }
        if let Some(index) = self.strings.get(text) {
            return Ok(Some(*index));
        }
        let mut value = String::new();
        value
            .try_reserve_exact(text.len())
            .map_err(|_| InspectorProjectionError::RetainedBudgetExceeded)?;
        value.push_str(text);
        let capacity = self
            .string_capacity
            .checked_add(value.capacity())
            .ok_or(InspectorProjectionError::RetainedBudgetExceeded)?;
        if capacity > self.budget.maximum_retained_string_bytes as usize
            || self.fixed_bytes + capacity > self.budget.maximum_retained_bytes as usize
        {
            return Err(InspectorProjectionError::RetainedBudgetExceeded);
        }
        check()?;
        let index = self.strings.len() as u32;
        self.strings.insert(value, index);
        self.string_capacity = capacity;
        Ok(Some(index))
    }
}
fn input_texts(input: InspectorProjectionInput<'_>) -> [Option<&str>; 4] {
    match input {
        InspectorProjectionInput::CpuSlice(e) => [
            e.thread_name.as_deref(),
            e.process_name.as_deref(),
            e.end_state.as_deref(),
            None,
        ],
        InspectorProjectionInput::ThreadState(e) => [
            Some(e.state.as_str()),
            e.process_name.as_deref(),
            e.thread_name.as_deref(),
            None,
        ],
        InspectorProjectionInput::NamedSlice(e) => [
            Some(e.name.as_str()),
            e.process_name.as_deref(),
            e.thread_name.as_deref(),
            e.category.as_deref(),
        ],
        InspectorProjectionInput::Frame(e) => [e.process_name.as_deref(), None, None, None],
        InspectorProjectionInput::Counter { series, .. } => [
            Some(series.name.as_str()),
            series.process_name.as_deref(),
            series.unit.as_deref(),
            None,
        ],
        InspectorProjectionInput::DensityBand => [None; 4],
    }
}
fn state_text(state: TraceThreadState) -> &'static str {
    match state {
        TraceThreadState::Running => "running",
        TraceThreadState::Runnable => "runnable",
        TraceThreadState::Sleeping => "sleeping",
        TraceThreadState::Blocked => "blocked",
        TraceThreadState::Stopped => "stopped",
    }
}
fn event_key(key: EventKey, table: EventTable) -> Result<(), InspectorProjectionError> {
    if key.table == table {
        Ok(())
    } else {
        Err(InspectorProjectionError::InvalidEventKey)
    }
}
/// Transactional publication: on any error no partial batch escapes. Inputs are
/// borrowed only for this call. Separate owners must admit simultaneous copies,
/// index scratch and wire encoding against their aggregate budget.
pub fn project_inspectors(
    api_version: u32,
    inputs: &[InspectorProjectionInput<'_>],
    budget: InspectorProjectionBudget,
    check: &mut InspectorProjectionCheck<'_>,
) -> Result<InspectorProjectionBatch, InspectorProjectionError> {
    check()?;
    if api_version != INSPECTOR_PROJECTION_API_VERSION {
        return Err(InspectorProjectionError::UnsupportedVersion);
    }
    budget.validate()?;
    if inputs.len() > budget.maximum_records as usize {
        return Err(InspectorProjectionError::InputBudgetExceeded);
    }
    let mut input_bytes = 0usize;
    for input in inputs {
        check()?;
        for text in input_texts(*input).into_iter().flatten() {
            if text.len() > MAXIMUM_INSPECTOR_TEXT_BYTES as usize {
                return Err(InspectorProjectionError::InputBudgetExceeded);
            }
            input_bytes = input_bytes
                .checked_add(text.len())
                .ok_or(InspectorProjectionError::InputBudgetExceeded)?;
            if input_bytes > budget.maximum_input_string_bytes as usize {
                return Err(InspectorProjectionError::InputBudgetExceeded);
            }
        }
    }
    let mut batch = InspectorProjectionBatch {
        api_version: INSPECTOR_PROJECTION_API_VERSION,
        strings: Vec::new(),
        records: Vec::new(),
        input_string_bytes: input_bytes as u64,
    };
    let slot_count = inputs.len() * 6;
    let minimum = size_of::<InspectorProjectionBatch>()
        + inputs.len() * size_of::<Option<InspectorFacts>>()
        + slot_count * size_of::<String>();
    if minimum > budget.maximum_retained_bytes as usize {
        return Err(InspectorProjectionError::RetainedBudgetExceeded);
    }
    batch
        .records
        .try_reserve_exact(inputs.len())
        .map_err(|_| InspectorProjectionError::RetainedBudgetExceeded)?;
    batch
        .strings
        .try_reserve_exact(slot_count)
        .map_err(|_| InspectorProjectionError::RetainedBudgetExceeded)?;
    let fixed = batch.retained_bytes() as usize;
    if fixed > budget.maximum_retained_bytes as usize {
        return Err(InspectorProjectionError::RetainedBudgetExceeded);
    }
    let mut builder = Builder {
        strings: BTreeMap::new(),
        string_capacity: 0,
        fixed_bytes: fixed,
        budget,
    };
    for input in inputs {
        check()?;
        let record = match *input {
            InspectorProjectionInput::DensityBand => None,
            InspectorProjectionInput::CpuSlice(e) => {
                event_key(e.key, EventTable::SchedSlice)?;
                let mut fact = InspectorFacts::base(
                    e.key,
                    InspectorEventKind::CpuSlice,
                    e.range,
                    e.is_open_ended,
                );
                fact.process_key = e.process_key;
                fact.thread_key = e.thread_key;
                fact.pid = e.pid;
                fact.tid = e.tid;
                fact.cpu = Some(e.cpu);
                fact.priority = e.priority;
                fact.name = builder.intern(e.thread_name.as_deref(), check)?;
                fact.process_name = builder.intern(e.process_name.as_deref(), check)?;
                fact.thread_name = builder.intern(e.thread_name.as_deref(), check)?;
                fact.category = builder.intern(Some("cpu"), check)?;
                fact.state = builder.intern(e.end_state.as_deref(), check)?;
                Some(fact)
            }
            InspectorProjectionInput::ThreadState(e) => {
                event_key(e.key, EventTable::ThreadState)?;
                let mut fact = InspectorFacts::base(
                    e.key,
                    InspectorEventKind::ThreadState,
                    e.range,
                    e.is_open_ended,
                );
                fact.process_key = e.process_key;
                fact.thread_key = Some(e.thread_key);
                fact.pid = e.pid;
                fact.tid = e.tid;
                fact.cpu = e.cpu;
                fact.process_name = builder.intern(e.process_name.as_deref(), check)?;
                fact.thread_name = builder.intern(e.thread_name.as_deref(), check)?;
                fact.category = builder.intern(e.normalized_state.map(state_text), check)?;
                fact.state = builder.intern(Some(&e.state), check)?;
                Some(fact)
            }
            InspectorProjectionInput::NamedSlice(e) => {
                event_key(e.key, EventTable::Callstack)?;
                let mut fact = InspectorFacts::base(
                    e.key,
                    InspectorEventKind::NamedSlice,
                    e.range,
                    e.is_open_ended,
                );
                fact.process_key = e.process_key;
                fact.thread_key = e.thread_key;
                fact.pid = e.pid;
                fact.tid = e.tid;
                fact.name = builder.intern(Some(&e.name), check)?;
                fact.process_name = builder.intern(e.process_name.as_deref(), check)?;
                fact.thread_name = builder.intern(e.thread_name.as_deref(), check)?;
                fact.category = builder.intern(e.category.as_deref(), check)?;
                Some(fact)
            }
            InspectorProjectionInput::Frame(e) => {
                event_key(e.key, EventTable::FrameSlice)?;
                let mut fact = InspectorFacts::base(
                    e.key,
                    InspectorEventKind::Frame,
                    e.range,
                    e.is_open_ended,
                );
                fact.process_key = e.process_key;
                fact.thread_key = e.thread_key;
                fact.pid = e.pid;
                fact.value = Some(e.vsync);
                let tag = TraceFrame::jank_tag(e.flag);
                let name = frame_label(e, tag);
                fact.name = builder.intern(Some(&name), check)?;
                fact.process_name = builder.intern(e.process_name.as_deref(), check)?;
                fact.category = builder.intern(Some("frame"), check)?;
                fact.state = builder.intern(Some(jank_state_text(tag)), check)?;
                fact.unit = builder.intern(Some("vsync"), check)?;
                Some(fact)
            }
            InspectorProjectionInput::Counter {
                series,
                sample,
                query_range,
            } => {
                if query_range.is_instant()
                    || sample.timestamp_ns < 0
                    || sample.duration_ns.is_some_and(|d| d < 0)
                {
                    return Err(InspectorProjectionError::InvalidRequest);
                }
                let valid_table = sample.key.table == EventTable::Measure
                    || (series.scope == CounterScope::Process
                        && sample.key.table == EventTable::ProcessMeasure);
                if !valid_table {
                    return Err(InspectorProjectionError::InvalidEventKey);
                }
                let end = match sample.duration_ns {
                    Some(d) => sample
                        .timestamp_ns
                        .checked_add(d)
                        .ok_or(InspectorProjectionError::ArithmeticOverflow)?,
                    None => query_range.end_ns(),
                };
                let range =
                    TraceTimeRange::event(sample.timestamp_ns, end.max(sample.timestamp_ns))
                        .map_err(|_| InspectorProjectionError::InvalidRequest)?;
                let mut fact = InspectorFacts::base(
                    sample.key,
                    InspectorEventKind::Counter,
                    range,
                    sample.duration_ns.is_none(),
                );
                fact.semantic_duration_ns = sample.duration_ns;
                fact.process_key = series.process_key;
                fact.pid = series.pid;
                fact.cpu = series.cpu;
                fact.value = Some(sample.value);
                fact.name = builder.intern(Some(&series.name), check)?;
                fact.process_name = builder.intern(series.process_name.as_deref(), check)?;
                fact.category = builder.intern(
                    Some(if series.scope == CounterScope::Cpu {
                        "cpu"
                    } else {
                        "process"
                    }),
                    check,
                )?;
                fact.unit = builder.intern(series.unit.as_deref(), check)?;
                Some(fact)
            }
        };
        batch.records.push(record);
    }
    batch
        .strings
        .resize_with(builder.strings.len(), String::new);
    for (value, index) in builder.strings {
        check()?;
        batch.strings[index as usize] = value;
    }
    if batch.retained_bytes() > u64::from(budget.maximum_retained_bytes)
        || batch.retained_string_bytes() > u64::from(budget.maximum_retained_string_bytes)
    {
        return Err(InspectorProjectionError::RetainedBudgetExceeded);
    }
    check()?;
    Ok(batch)
}
