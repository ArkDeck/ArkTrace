use arktrace_contract::{
    CounterQuery, CpuSliceQuery, ThreadStateQuery, TraceSliceQuery, TraceTimeRange,
};
#[cfg(target_os = "macos")]
use std::collections::BTreeMap;

/// Closed migration views. Each carries only its applicable typed filters.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum EventQuery {
    CpuSlices(CpuSliceQuery),
    ThreadStates(ThreadStateQuery),
    Slices(TraceSliceQuery),
    Counters(CounterQuery),
}
impl EventQuery {
    pub fn cli_view(&self) -> &'static str {
        match self {
            Self::CpuSlices(_) => "cpu-slices",
            Self::ThreadStates(_) => "thread-states",
            Self::Slices(_) => "slices",
            Self::Counters(_) => "counters",
        }
    }
    pub fn range(&self) -> TraceTimeRange {
        match self {
            Self::CpuSlices(q) => q.range,
            Self::ThreadStates(q) => q.range,
            Self::Slices(q) => q.range,
            Self::Counters(q) => q.range,
        }
    }
    pub fn limit(&self) -> usize {
        match self {
            Self::CpuSlices(q) => q.limit,
            Self::ThreadStates(q) => q.limit,
            Self::Slices(q) => q.limit,
            Self::Counters(q) => q.limit,
        }
    }
    /// Request identities use scalars; result filters use the existing
    /// nested stable-key Codable shape. Keys below are fixed contract fields.
    #[cfg(target_os = "macos")]
    pub(crate) fn filters(&self, nested_keys: bool) -> BTreeMap<&'static str, serde_json::Value> {
        let (cpu, process, pid, thread, tid, raw, state) = match self {
            Self::CpuSlices(q) => (q.cpu, q.process_key, q.pid, q.thread_key, q.tid, None, None),
            Self::ThreadStates(q) => (
                q.cpu,
                q.process_key,
                q.pid,
                q.thread_key,
                q.tid,
                q.raw_state.as_deref(),
                q.state,
            ),
            Self::Slices(q) => (None, q.process_key, q.pid, q.thread_key, q.tid, None, None),
            Self::Counters(q) => (q.cpu, q.process_key, q.pid, None, None, None, None),
        };
        let process = process.map(|key| {
            if nested_keys {
                serde_json::json!({"ipid":key})
            } else {
                serde_json::json!(key)
            }
        });
        let thread = thread.map(|key| {
            if nested_keys {
                serde_json::json!({"itid":key})
            } else {
                serde_json::json!(key)
            }
        });
        let mut filters = BTreeMap::from([
            ("cpu", serde_json::json!(cpu)),
            ("processKey", serde_json::json!(process)),
            ("pid", serde_json::json!(pid)),
            ("threadKey", serde_json::json!(thread)),
            ("tid", serde_json::json!(tid)),
            ("rawState", serde_json::json!(raw)),
            ("normalizedState", serde_json::json!(state)),
            ("name", serde_json::Value::Null),
            ("nameMatch", serde_json::json!("exact")),
            ("minimumDurationNs", serde_json::Value::Null),
            ("depth", serde_json::Value::Null),
            ("counterFilterID", serde_json::Value::Null),
        ]);
        if let Self::Slices(q) = self {
            filters.extend([
                ("name", serde_json::json!(q.name)),
                ("nameMatch", serde_json::json!(q.name_match)),
                (
                    "minimumDurationNs",
                    serde_json::json!(q.minimum_duration_ns),
                ),
                ("depth", serde_json::json!(q.depth)),
            ]);
        }
        filters.extend(match self {
            Self::Counters(q) => BTreeMap::from([
                ("name", serde_json::json!(q.name)),
                ("nameMatch", serde_json::json!(q.name_match)),
                ("counterFilterID", serde_json::json!(q.filter_id)),
            ]),
            _ => BTreeMap::new(),
        });
        filters
    }
    #[cfg(target_os = "macos")]
    pub(crate) fn parameters(&self) -> BTreeMap<&'static str, serde_json::Value> {
        let mut result = self.filters(false);
        result.extend([
            ("view", serde_json::json!(self.cli_view())),
            ("startNs", serde_json::json!(self.range().start_ns())),
            ("endNs", serde_json::json!(self.range().end_ns())),
            ("limit", serde_json::json!(self.limit())),
        ]);
        result
    }
}
