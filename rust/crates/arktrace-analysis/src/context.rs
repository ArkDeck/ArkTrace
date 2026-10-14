//! Swift `TraceContextBuilder`: deterministic candidate ranking, referenced
//! directory probing within the row budget, referential closure, and the
//! byte-bounded retention search. Loading and byte measurement are supplied
//! by the host; this module performs no IO and no encoding of its own.
use crate::{
    AnalysisError, Check, checked_sort, checkpoint, deterministic::merged_quality, event_order,
};
use arktrace_contract::{
    CounterSample, CounterScope, CounterSeries, CpuSlice, DataQuality, DirectoryNameMatch,
    DirectoryPage, EventKey, EventPage, ProcessKey, QualityCategory, QualityIssue, ThreadKey,
    ThreadStateInterval, TraceAgentCounterEvent, TraceProcess, TraceSlice, TraceThread,
    TraceThreadState, TraceTimeRange,
};
use serde::{Serialize, Serializer, ser::SerializeMap};
use std::collections::{BTreeMap, HashMap, HashSet};

/// Swift `TraceAgentQueryFilters` as a context request carries them.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentFilters {
    pub cpu: Option<i64>,
    pub process_key: Option<i64>,
    pub pid: Option<i64>,
    pub thread_key: Option<i64>,
    pub tid: Option<i64>,
    pub raw_state: Option<String>,
    pub normalized_state: Option<TraceThreadState>,
    pub name: Option<String>,
    pub name_match: DirectoryNameMatch,
    pub minimum_duration_ns: Option<i64>,
    pub depth: Option<i64>,
    pub counter_filter_id: Option<i64>,
}
impl Default for AgentFilters {
    fn default() -> Self {
        Self {
            cpu: None,
            process_key: None,
            pid: None,
            thread_key: None,
            tid: None,
            raw_state: None,
            normalized_state: None,
            name: None,
            name_match: DirectoryNameMatch::Exact,
            minimum_duration_ns: None,
            depth: None,
            counter_filter_id: None,
        }
    }
}
impl AgentFilters {
    /// Swift `TraceAgentQueryFilters.init` validation.
    pub fn validate(&self) -> Result<(), AnalysisError> {
        let text = |v: &Option<String>| v.as_ref().is_some_and(|v| v.is_empty() || v.len() > 256);
        if text(&self.raw_state)
            || text(&self.name)
            || (self.name.is_none() && self.name_match != DirectoryNameMatch::Exact)
            || self.minimum_duration_ns.is_some_and(|v| v < 0)
            || self.depth.is_some_and(|v| v < 0)
            || self.process_key == Some(0)
            || self.thread_key == Some(0)
        {
            return Err(AnalysisError::InvalidBounds);
        }
        Ok(())
    }
}
impl Serialize for AgentFilters {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut map = serializer.serialize_map(Some(12))?;
        map.serialize_entry("cpu", &self.cpu)?;
        map.serialize_entry(
            "processKey",
            &self.process_key.map(|ipid| ProcessKey { ipid }),
        )?;
        map.serialize_entry("pid", &self.pid)?;
        map.serialize_entry("threadKey", &self.thread_key.map(|itid| ThreadKey { itid }))?;
        map.serialize_entry("tid", &self.tid)?;
        map.serialize_entry("rawState", &self.raw_state)?;
        map.serialize_entry("normalizedState", &self.normalized_state)?;
        map.serialize_entry("name", &self.name)?;
        map.serialize_entry("nameMatch", &self.name_match)?;
        map.serialize_entry("minimumDurationNs", &self.minimum_duration_ns)?;
        map.serialize_entry("depth", &self.depth)?;
        map.serialize_entry("counterFilterID", &self.counter_filter_id)?;
        map.end()
    }
}

/// Swift `TraceContextTimeSelection`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ContextTime {
    Timestamp {
        timestamp_ns: i64,
        window_before_ns: i64,
        window_after_ns: i64,
    },
    Range(TraceTimeRange),
}
impl ContextTime {
    /// Swift `TraceContextRequest` time validation.
    pub fn validate(self) -> Result<(), AnalysisError> {
        match self {
            Self::Timestamp {
                timestamp_ns,
                window_before_ns,
                window_after_ns,
            } if timestamp_ns < 0
                || window_before_ns < 0
                || window_after_ns < 0
                || (window_before_ns == 0 && window_after_ns == 0) =>
            {
                Err(AnalysisError::InvalidBounds)
            }
            Self::Range(range) if range.is_instant() => Err(AnalysisError::InvalidBounds),
            _ => Ok(()),
        }
    }
    /// Swift `normalized(_:durationNs:)`: the range and an optional center.
    pub fn normalized(
        self,
        duration_ns: i64,
    ) -> Result<(TraceTimeRange, Option<i64>), AnalysisError> {
        match self {
            Self::Range(range) => {
                if range.end_ns() > duration_ns {
                    return Err(AnalysisError::InvalidBounds);
                }
                Ok((range, None))
            }
            Self::Timestamp {
                timestamp_ns,
                window_before_ns,
                window_after_ns,
            } => {
                if timestamp_ns > duration_ns {
                    return Err(AnalysisError::InvalidBounds);
                }
                let start = if timestamp_ns >= window_before_ns {
                    timestamp_ns - window_before_ns
                } else {
                    0
                };
                let end = duration_ns.min(
                    timestamp_ns
                        .checked_add(window_after_ns)
                        .unwrap_or(i64::MAX),
                );
                if start >= end {
                    return Err(AnalysisError::InvalidBounds);
                }
                Ok((
                    TraceTimeRange::query(start, end).map_err(|_| AnalysisError::InvalidBounds)?,
                    Some(timestamp_ns),
                ))
            }
        }
    }
}

/// Swift core `TraceProcess` Codable (stable key nested, explicit nulls).
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ContextProcess {
    pub key: ProcessKey,
    pub pid: i64,
    pub name: Option<String>,
    pub start_ns: Option<i64>,
    pub end_ns: Option<i64>,
    pub thread_count: Option<i64>,
}
impl From<&TraceProcess> for ContextProcess {
    fn from(v: &TraceProcess) -> Self {
        Self {
            key: ProcessKey { ipid: v.key },
            pid: v.pid,
            name: v.name.clone(),
            start_ns: v.start_ns,
            end_ns: v.end_ns,
            thread_count: v.thread_count,
        }
    }
}
/// Swift core `TraceThread` Codable.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ContextThread {
    pub key: ThreadKey,
    pub process_key: Option<ProcessKey>,
    pub tid: i64,
    pub pid: Option<i64>,
    pub name: Option<String>,
    pub process_name: Option<String>,
    pub start_ns: Option<i64>,
    pub end_ns: Option<i64>,
    pub is_main_thread: Option<bool>,
}
impl From<&TraceThread> for ContextThread {
    fn from(v: &TraceThread) -> Self {
        Self {
            key: ThreadKey { itid: v.key },
            process_key: v.process_key.map(|ipid| ProcessKey { ipid }),
            tid: v.tid,
            pid: v.pid,
            name: v.name.clone(),
            process_name: v.process_name.clone(),
            start_ns: v.start_ns,
            end_ns: v.end_ns,
            is_main_thread: v.is_main_thread,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ContextSectionStatus {
    pub returned_count: usize,
    pub matched_count: Option<usize>,
    pub truncated: bool,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ContextTruncation {
    pub processes: ContextSectionStatus,
    pub threads: ContextSectionStatus,
    pub cpu_slices: ContextSectionStatus,
    pub thread_states: ContextSectionStatus,
    pub slices: ContextSectionStatus,
    pub counters: ContextSectionStatus,
    pub summary: ContextSectionStatus,
    pub reference_omitted_by_budget: bool,
}
impl ContextTruncation {
    pub fn truncated(&self) -> bool {
        self.reference_omitted_by_budget
            || [
                self.processes,
                self.threads,
                self.cpu_slices,
                self.thread_states,
                self.slices,
                self.counters,
                self.summary,
            ]
            .iter()
            .any(|v| v.truncated)
    }
    /// Swift `contextTruncationSections`, in its fixed append order.
    pub fn truncated_names(&self) -> Vec<&'static str> {
        let mut names: Vec<&'static str> = [
            ("processes", self.processes),
            ("threads", self.threads),
            ("cpuSlices", self.cpu_slices),
            ("threadStates", self.thread_states),
            ("slices", self.slices),
            ("counters", self.counters),
            ("summary", self.summary),
        ]
        .into_iter()
        .filter(|(_, v)| v.truncated)
        .map(|(name, _)| name)
        .collect();
        if self.reference_omitted_by_budget {
            names.push("references");
        }
        names
    }
}

/// `TraceContext` in its Machine shape; `S` is the host's summary document.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ContextDocument<'a, S: Serialize> {
    pub range: TraceTimeRange,
    pub filters: &'a AgentFilters,
    pub processes: Vec<ContextProcess>,
    pub threads: Vec<ContextThread>,
    pub cpu_slices: Vec<CpuSlice>,
    pub thread_states: Vec<ThreadStateInterval>,
    pub slices: Vec<TraceSlice>,
    pub counters: Vec<CounterSeries>,
    pub summary: &'a S,
    pub data_quality: DataQuality,
    pub truncation: ContextTruncation,
}
impl<S: Serialize> ContextDocument<'_, S> {
    pub fn event_count(&self) -> usize {
        self.cpu_slices.len()
            + self.thread_states.len()
            + self.slices.len()
            + self.counters.iter().map(|v| v.samples.len()).sum::<usize>()
    }
}

/// Everything Swift `load(_:deadline:)` gathers: agent-composed event pages
/// over the normalized range, the first directory pages and the summary.
pub struct ContextLoaded<'a, S: Serialize> {
    pub range: TraceTimeRange,
    pub center: Option<i64>,
    pub filters: &'a AgentFilters,
    pub processes: DirectoryPage<TraceProcess>,
    pub threads: DirectoryPage<TraceThread>,
    pub cpu: EventPage<CpuSlice>,
    pub states: EventPage<ThreadStateInterval>,
    pub slices: EventPage<TraceSlice>,
    pub counters: EventPage<TraceAgentCounterEvent>,
    pub summary: &'a S,
    pub summary_quality: &'a [QualityIssue],
    pub summary_truncated: bool,
}

/// One-row identity probes for referenced directory rows (Swift
/// `repository.processes/threads(... limit: 1)`).
pub trait ContextDirectory {
    fn process(&mut self, key: i64) -> Result<Option<TraceProcess>, AnalysisError>;
    fn thread(&mut self, key: i64) -> Result<Option<TraceThread>, AnalysisError>;
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ContextError {
    Analysis(AnalysisError),
    /// A directory page returned the same identity twice.
    DuplicateDirectoryIdentity,
    /// Even the minimum context does not fit; Swift `outputLimitExceeded`.
    OutputLimitExceeded {
        maximum: usize,
        required: usize,
    },
    /// A directory lower bound that previously fit no longer does.
    Inconsistent,
}
impl From<AnalysisError> for ContextError {
    fn from(value: AnalysisError) -> Self {
        Self::Analysis(value)
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
enum Entity {
    Process(i64),
    Thread(i64),
}
#[derive(Clone, Copy, Debug)]
struct Candidate {
    key: EventKey,
    start: i64,
    duration: i64,
    explicit: bool,
    distance: Option<i64>,
    process: Option<i64>,
    thread: Option<i64>,
}
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
struct CounterIdentity {
    scope: &'static str,
    filter_id: i64,
    cpu: (bool, i64),
    process_key: (bool, i64),
    pid: (bool, i64),
    name: Vec<u8>,
    process_name: Option<Vec<u8>>,
    unit: Option<Vec<u8>>,
}

fn scope_raw(scope: CounterScope) -> &'static str {
    match scope {
        CounterScope::Cpu => "cpu",
        CounterScope::Process => "process",
    }
}
/// Swift `optionalIntPrecedes`: nil first, then ascending.
fn optional(value: Option<i64>) -> (bool, i64) {
    (value.is_some(), value.unwrap_or(0))
}

struct Prepared<'l, 'a, S: Serialize> {
    loaded: &'l ContextLoaded<'a, S>,
    candidates: Vec<Candidate>,
    process_by_key: HashMap<i64, TraceProcess>,
    thread_by_key: HashMap<i64, TraceThread>,
    budget_omitted: HashSet<Entity>,
    missing: usize,
}

fn unique<T: Clone>(
    items: &[T],
    key: impl Fn(&T) -> i64,
    check: &mut Check<'_>,
) -> Result<HashMap<i64, T>, ContextError> {
    let mut map = HashMap::with_capacity(items.len());
    for (index, item) in items.iter().enumerate() {
        checkpoint(index, check)?;
        if map.insert(key(item), item.clone()).is_some() {
            return Err(ContextError::DuplicateDirectoryIdentity);
        }
    }
    Ok(map)
}

fn candidates<S: Serialize>(
    loaded: &ContextLoaded<'_, S>,
    check: &mut Check<'_>,
) -> Result<Vec<Candidate>, AnalysisError> {
    let f = loaded.filters;
    let cpu_explicit = f.cpu.is_some()
        || f.process_key.is_some()
        || f.pid.is_some()
        || f.thread_key.is_some()
        || f.tid.is_some();
    let state_explicit = cpu_explicit || f.raw_state.is_some() || f.normalized_state.is_some();
    let slice_explicit = f.process_key.is_some()
        || f.pid.is_some()
        || f.thread_key.is_some()
        || f.tid.is_some()
        || f.name.is_some()
        || f.minimum_duration_ns.is_some()
        || f.depth.is_some();
    let counter_explicit = f.counter_filter_id.is_some()
        || f.cpu.is_some()
        || f.process_key.is_some()
        || f.pid.is_some();
    let center = loaded.center;
    let distance = |start: i64, duration: i64| {
        center.map(|center| {
            let midpoint = start.checked_add(duration / 2).unwrap_or(i64::MAX);
            if midpoint >= center {
                midpoint - center
            } else {
                center - midpoint
            }
        })
    };
    let mut values = Vec::with_capacity(
        loaded.cpu.items.len()
            + loaded.states.items.len()
            + loaded.slices.items.len()
            + loaded.counters.items.len(),
    );
    let mut index = 0;
    for v in &loaded.cpu.items {
        checkpoint(index, check)?;
        index += 1;
        let (start, duration) = (v.range.start_ns(), v.range.duration_ns());
        values.push(Candidate {
            key: v.key,
            start,
            duration,
            explicit: cpu_explicit,
            distance: distance(start, duration),
            process: v.process_key.map(|k| k.ipid),
            thread: v.thread_key.map(|k| k.itid),
        });
    }
    for v in &loaded.states.items {
        checkpoint(index, check)?;
        index += 1;
        let (start, duration) = (v.range.start_ns(), v.range.duration_ns());
        values.push(Candidate {
            key: v.key,
            start,
            duration,
            explicit: state_explicit,
            distance: distance(start, duration),
            process: v.process_key.map(|k| k.ipid),
            thread: Some(v.thread_key.itid),
        });
    }
    for v in &loaded.slices.items {
        checkpoint(index, check)?;
        index += 1;
        let (start, duration) = (v.range.start_ns(), v.range.duration_ns());
        values.push(Candidate {
            key: v.key,
            start,
            duration,
            explicit: slice_explicit,
            distance: distance(start, duration),
            process: v.process_key.map(|k| k.ipid),
            thread: v.thread_key.map(|k| k.itid),
        });
    }
    let (range_start, range_end) = (loaded.range.start_ns(), loaded.range.end_ns());
    for event in &loaded.counters.items {
        checkpoint(index, check)?;
        index += 1;
        let sample = &event.sample;
        let overlap_start = sample.timestamp_ns.max(range_start);
        let available = (range_end - overlap_start).max(0);
        let effective = match sample.duration_ns {
            Some(duration) if duration >= 0 => {
                let end = range_end.min(
                    sample
                        .timestamp_ns
                        .checked_add(duration)
                        .unwrap_or(i64::MAX),
                );
                (end - overlap_start).max(0)
            }
            _ => available,
        };
        values.push(Candidate {
            key: sample.key,
            start: sample.timestamp_ns,
            duration: effective,
            explicit: counter_explicit,
            distance: distance(overlap_start, effective),
            process: event.process_key.map(|k| k.ipid),
            thread: None,
        });
    }
    checked_sort(
        &mut values,
        |a, b| {
            use std::cmp::Ordering;
            if a.explicit != b.explicit {
                return if a.explicit {
                    Ordering::Less
                } else {
                    Ordering::Greater
                };
            }
            if let (Some(x), Some(y)) = (a.distance, b.distance)
                && x != y
            {
                return x.cmp(&y);
            }
            if center.is_none() && a.start != b.start {
                return a.start.cmp(&b.start);
            }
            if a.duration != b.duration {
                return b.duration.cmp(&a.duration);
            }
            event_order(a.key).cmp(&event_order(b.key))
        },
        check,
    )?;
    Ok(values)
}

fn probe_references<S: Serialize>(
    prepared: &mut Prepared<'_, '_, S>,
    maximum: usize,
    directory: &mut dyn ContextDirectory,
    check: &mut Check<'_>,
) -> Result<(), ContextError> {
    let mut ordered = Vec::new();
    let mut scheduled = HashSet::new();
    for (index, candidate) in prepared.candidates.iter().enumerate() {
        checkpoint(index, check)?;
        if let Some(key) = candidate.process
            && scheduled.insert(Entity::Process(key))
        {
            ordered.push(Entity::Process(key));
        }
        if let Some(key) = candidate.thread
            && scheduled.insert(Entity::Thread(key))
        {
            ordered.push(Entity::Thread(key));
        }
    }
    let (mut probes, mut index) = (0, 0);
    while index < ordered.len() {
        check()?;
        let entity = ordered[index];
        index += 1;
        match entity {
            Entity::Process(key) if prepared.process_by_key.contains_key(&key) => continue,
            Entity::Thread(key) if prepared.thread_by_key.contains_key(&key) => {
                if let Some(process) = prepared.thread_by_key[&key].process_key
                    && scheduled.insert(Entity::Process(process))
                {
                    ordered.insert(index, Entity::Process(process));
                }
                continue;
            }
            _ => {}
        }
        if probes >= maximum {
            prepared.budget_omitted.insert(entity);
            continue;
        }
        probes += 1;
        match entity {
            Entity::Process(key) => match directory.process(key)? {
                Some(value) => {
                    prepared.process_by_key.insert(key, value);
                }
                None => prepared.missing += 1,
            },
            Entity::Thread(key) => match directory.thread(key)? {
                Some(value) => {
                    if let Some(process) = value.process_key
                        && scheduled.insert(Entity::Process(process))
                    {
                        ordered.insert(index, Entity::Process(process));
                    }
                    prepared.thread_by_key.insert(key, value);
                }
                None => prepared.missing += 1,
            },
        }
    }
    Ok(())
}

fn process_order(a: &TraceProcess, b: &TraceProcess) -> std::cmp::Ordering {
    (a.pid, a.key).cmp(&(b.pid, b.key))
}
fn thread_order(a: &TraceThread, b: &TraceThread) -> std::cmp::Ordering {
    (optional(a.pid), a.tid, a.key).cmp(&(optional(b.pid), b.tid, b.key))
}

struct Assembly<'a, S: Serialize> {
    document: ContextDocument<'a, S>,
    required_directories: usize,
}

fn assemble<'a, S: Serialize>(
    prepared: &Prepared<'_, 'a, S>,
    event_count: usize,
    directory_limit: usize,
    include_extra: bool,
    check: &mut Check<'_>,
) -> Result<Assembly<'a, S>, ContextError> {
    check()?;
    let loaded = prepared.loaded;
    let retained = &prepared.candidates[..event_count.min(prepared.candidates.len())];
    let keys: HashSet<(&str, i64)> = retained.iter().map(|c| event_order(c.key)).collect();
    let cpu: Vec<_> = loaded
        .cpu
        .items
        .iter()
        .filter(|v| keys.contains(&event_order(v.key)))
        .cloned()
        .collect();
    let states: Vec<_> = loaded
        .states
        .items
        .iter()
        .filter(|v| keys.contains(&event_order(v.key)))
        .cloned()
        .collect();
    let slices: Vec<_> = loaded
        .slices
        .items
        .iter()
        .filter(|v| keys.contains(&event_order(v.key)))
        .cloned()
        .collect();
    let mut grouped: BTreeMap<CounterIdentity, (TraceAgentCounterEvent, Vec<CounterSample>)> =
        BTreeMap::new();
    for (index, event) in loaded.counters.items.iter().enumerate() {
        checkpoint(index, check)?;
        if !keys.contains(&event_order(event.sample.key)) {
            continue;
        }
        // Swift `counterIdentityPrecedes`: scope raw, filter ID, cpu, process
        // key, pid (nil first), name/process name/unit as UTF-8 (nil first).
        let identity = CounterIdentity {
            scope: scope_raw(event.scope),
            filter_id: event.filter_id,
            cpu: optional(event.cpu),
            process_key: optional(event.process_key.map(|k| k.ipid)),
            pid: optional(event.pid),
            name: event.name.as_bytes().to_vec(),
            process_name: event.process_name.as_ref().map(|v| v.as_bytes().to_vec()),
            unit: event.unit.as_ref().map(|v| v.as_bytes().to_vec()),
        };
        grouped
            .entry(identity)
            .or_insert_with(|| (event.clone(), Vec::new()))
            .1
            .push(event.sample.clone());
    }
    let mut counters = Vec::with_capacity(grouped.len());
    for (_, (event, mut samples)) in grouped {
        check()?;
        checked_sort(
            &mut samples,
            |a, b| (a.timestamp_ns, event_order(a.key)).cmp(&(b.timestamp_ns, event_order(b.key))),
            check,
        )?;
        counters.push(CounterSeries {
            filter_id: event.filter_id,
            name: event.name,
            scope: event.scope,
            cpu: event.cpu,
            process_key: event.process_key,
            pid: event.pid,
            process_name: event.process_name,
            unit: event.unit,
            samples,
        });
    }

    let mut required = Vec::new();
    let mut seen = HashSet::new();
    for (index, candidate) in retained.iter().enumerate() {
        checkpoint(index, check)?;
        if let Some(process) = candidate.process
            && seen.insert(Entity::Process(process))
        {
            required.push(Entity::Process(process));
        }
        if let Some(thread) = candidate.thread {
            if seen.insert(Entity::Thread(thread)) {
                required.push(Entity::Thread(thread));
            }
            if let Some(process) = prepared
                .thread_by_key
                .get(&thread)
                .and_then(|v| v.process_key)
                && seen.insert(Entity::Process(process))
            {
                required.push(Entity::Process(process));
            }
        }
    }
    let present = |entity: &Entity| match entity {
        Entity::Process(key) => prepared.process_by_key.contains_key(key),
        Entity::Thread(key) => prepared.thread_by_key.contains_key(key),
    };
    let available: Vec<Entity> = required.iter().copied().filter(present).collect();
    let mut selected: Vec<Entity> = available.iter().copied().take(directory_limit).collect();
    if include_extra && selected.len() < directory_limit {
        let mut processes: Vec<&TraceProcess> = loaded.processes.items.iter().collect();
        checked_sort(&mut processes, |a, b| process_order(a, b), check)?;
        let mut threads: Vec<&TraceThread> = loaded.threads.items.iter().collect();
        checked_sort(&mut threads, |a, b| thread_order(a, b), check)?;
        let extras = processes
            .iter()
            .map(|v| Entity::Process(v.key))
            .chain(threads.iter().map(|v| Entity::Thread(v.key)));
        for value in extras {
            if selected.len() >= directory_limit {
                break;
            }
            if seen.insert(value) {
                selected.push(value);
            }
        }
    }
    let selected_set: HashSet<Entity> = selected.iter().copied().collect();
    let mut processes: Vec<&TraceProcess> = selected
        .iter()
        .filter_map(|v| match v {
            Entity::Process(key) => prepared.process_by_key.get(key),
            Entity::Thread(_) => None,
        })
        .collect();
    checked_sort(&mut processes, |a, b| process_order(a, b), check)?;
    let mut threads: Vec<&TraceThread> = selected
        .iter()
        .filter_map(|v| match v {
            Entity::Thread(key) => prepared.thread_by_key.get(key),
            Entity::Process(_) => None,
        })
        .collect();
    checked_sort(&mut threads, |a, b| thread_order(a, b), check)?;
    let omitted_reference = required
        .iter()
        .any(|v| !selected_set.contains(v) && (prepared.budget_omitted.contains(v) || present(v)));

    let retained_counters: usize = counters.iter().map(|v| v.samples.len()).sum();
    let source_counters = loaded.counters.items.len();
    let mut extra = Vec::new();
    if prepared.missing > 0 {
        extra.push(QualityIssue {
            category: QualityCategory::ReferentialIntegrity,
            scope: None,
            count: Some(prepared.missing as i64),
            message: Some("Referenced directory identity is unavailable".into()),
        });
    }
    if !prepared.budget_omitted.is_empty() {
        extra.push(QualityIssue {
            category: QualityCategory::ProbeTruncated,
            scope: None,
            count: None,
            message: Some("Directory reference probing reached its row budget".into()),
        });
    }
    let data_quality = merged_quality(
        &[
            loaded.summary_quality,
            &loaded.cpu.data_quality.warnings,
            &loaded.states.data_quality.warnings,
            &loaded.slices.data_quality.warnings,
            &loaded.counters.data_quality.warnings,
            &loaded.processes.data_quality_issues,
            &loaded.threads.data_quality_issues,
        ],
        extra,
        check,
    )?;
    let status = |returned: usize, source: usize, truncated: bool| ContextSectionStatus {
        returned_count: returned,
        matched_count: (!truncated).then_some(source),
        truncated: truncated || returned < source,
    };
    let truncation = ContextTruncation {
        processes: status(
            processes.len(),
            loaded.processes.items.len(),
            loaded.processes.truncated,
        ),
        threads: status(
            threads.len(),
            loaded.threads.items.len(),
            loaded.threads.truncated,
        ),
        cpu_slices: status(cpu.len(), loaded.cpu.items.len(), loaded.cpu.truncated),
        thread_states: status(
            states.len(),
            loaded.states.items.len(),
            loaded.states.truncated,
        ),
        slices: status(
            slices.len(),
            loaded.slices.items.len(),
            loaded.slices.truncated,
        ),
        counters: status(
            retained_counters,
            source_counters,
            loaded.counters.truncated,
        ),
        summary: ContextSectionStatus {
            returned_count: 1,
            matched_count: Some(1),
            truncated: loaded.summary_truncated,
        },
        reference_omitted_by_budget: omitted_reference,
    };
    check()?;
    Ok(Assembly {
        document: ContextDocument {
            range: loaded.range,
            filters: loaded.filters,
            processes: processes.into_iter().map(ContextProcess::from).collect(),
            threads: threads.into_iter().map(ContextThread::from).collect(),
            cpu_slices: cpu,
            thread_states: states,
            slices,
            counters,
            summary: loaded.summary,
            data_quality,
            truncation,
        },
        required_directories: available.len(),
    })
}

/// Measures the exact encoded byte count of one candidate document, or any
/// value above `maximum` once that bound is exceeded.
pub type ContextMeasure<'m, 'a, S> =
    dyn FnMut(&ContextDocument<'a, S>, usize) -> Result<usize, AnalysisError> + 'm;

/// The loaded state after candidate ranking and reference probing; retention
/// may be re-run against tighter byte budgets without reloading.
pub struct PreparedContext<'l, 'a, S: Serialize>(Prepared<'l, 'a, S>);

pub fn prepare_context<'l, 'a, S: Serialize>(
    loaded: &'l ContextLoaded<'a, S>,
    maximum_rows: usize,
    directory: &mut dyn ContextDirectory,
    check: &mut Check<'_>,
) -> Result<PreparedContext<'l, 'a, S>, ContextError> {
    check()?;
    loaded.filters.validate()?;
    let process_by_key = unique(&loaded.processes.items, |v| v.key, check)?;
    let thread_by_key = unique(&loaded.threads.items, |v| v.key, check)?;
    let candidates = candidates(loaded, check)?;
    let mut prepared = Prepared {
        loaded,
        candidates,
        process_by_key,
        thread_by_key,
        budget_omitted: HashSet::new(),
        missing: 0,
    };
    probe_references(&mut prepared, maximum_rows, directory, check)?;
    Ok(PreparedContext(prepared))
}

/// Swift `build(_:deadline:)` retention over a prepared context.
pub fn retain_context<'a, S: Serialize>(
    prepared: &PreparedContext<'_, 'a, S>,
    maximum_events: usize,
    maximum_rows: usize,
    maximum_bytes: usize,
    measure: &mut ContextMeasure<'_, 'a, S>,
    check: &mut Check<'_>,
) -> Result<ContextDocument<'a, S>, ContextError> {
    fn fits<'a, S: Serialize>(
        document: &ContextDocument<'a, S>,
        maximum_bytes: usize,
        measure: &mut ContextMeasure<'_, 'a, S>,
        check: &mut Check<'_>,
    ) -> Result<bool, ContextError> {
        check()?;
        Ok(measure(document, maximum_bytes)? <= maximum_bytes)
    }
    let prepared = &prepared.0;
    let full_count = maximum_events.min(prepared.candidates.len());
    let full = assemble(prepared, full_count, maximum_rows, true, check)?;
    if fits(&full.document, maximum_bytes, measure, check)? {
        return Ok(full.document);
    }
    // Drop unrelated directory rows before removing retained events and
    // their referential closure.
    let closure = assemble(prepared, full_count, maximum_rows, false, check)?;
    let (event_count, lower_bound) = if fits(&closure.document, maximum_bytes, measure, check)? {
        (full_count, closure.required_directories)
    } else {
        // Swift binary search over [0, fullCount - 1] with an inclusive upper.
        let (mut lower, mut upper) = (0_i64, full_count as i64 - 1);
        let mut best: Option<Assembly<'a, S>> = None;
        while lower <= upper {
            check()?;
            let middle = lower + (upper - lower) / 2;
            let value = assemble(prepared, middle as usize, maximum_rows, false, check)?;
            if fits(&value.document, maximum_bytes, measure, check)? {
                best = Some(value);
                lower = middle + 1;
            } else {
                upper = middle - 1;
            }
        }
        let Some(best) = best else {
            let minimum = assemble(prepared, 0, 0, false, check)?.document;
            check()?;
            let required = measure(&minimum, usize::MAX)?;
            if required <= maximum_bytes {
                return Ok(minimum);
            }
            return Err(ContextError::OutputLimitExceeded {
                maximum: maximum_bytes,
                required,
            });
        };
        (best.document.event_count(), best.required_directories)
    };
    // Swift `maximizeDirectories`.
    let mut lower = lower_bound.min(maximum_rows) as i64;
    let mut upper = maximum_rows as i64;
    let mut best = assemble(prepared, event_count, lower as usize, true, check)?.document;
    if !fits(&best, maximum_bytes, measure, check)? {
        return Err(ContextError::Inconsistent);
    }
    while lower <= upper {
        check()?;
        let middle = lower + (upper - lower) / 2;
        let value = assemble(prepared, event_count, middle as usize, true, check)?.document;
        if fits(&value, maximum_bytes, measure, check)? {
            best = value;
            lower = middle + 1;
        } else {
            upper = middle - 1;
        }
    }
    check()?;
    Ok(best)
}
