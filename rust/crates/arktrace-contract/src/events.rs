use crate::{ContractError, DataQuality, TraceTimeRange};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProcessKey {
    pub ipid: i64,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ThreadKey {
    pub itid: i64,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum EventTable {
    #[serde(rename = "sched_slice")]
    SchedSlice,
    #[serde(rename = "thread_state")]
    ThreadState,
    #[serde(rename = "callstack")]
    Callstack,
    #[serde(rename = "measure")]
    Measure,
    #[serde(rename = "process_measure")]
    ProcessMeasure,
    #[serde(rename = "frame_slice")]
    FrameSlice,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EventKey {
    pub table: EventTable,
    #[serde(rename = "rowID")]
    pub row_id: i64,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TraceThreadState {
    Running,
    Runnable,
    Sleeping,
    Blocked,
    Stopped,
}

/// Per-request time/cancellation live in the Engine budget, never in JSON.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CpuSliceQuery {
    pub range: TraceTimeRange,
    pub cpu: Option<i64>,
    pub process_key: Option<i64>,
    pub pid: Option<i64>,
    pub thread_key: Option<i64>,
    pub tid: Option<i64>,
    pub limit: usize,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ThreadStateQuery {
    pub range: TraceTimeRange,
    pub cpu: Option<i64>,
    pub process_key: Option<i64>,
    pub pid: Option<i64>,
    pub thread_key: Option<i64>,
    pub tid: Option<i64>,
    pub raw_state: Option<String>,
    pub state: Option<TraceThreadState>,
    pub limit: usize,
}
fn validate(range: TraceTimeRange, limit: usize) -> Result<(), ContractError> {
    if range.is_instant() || !(1..=100_000).contains(&limit) {
        return Err(ContractError::InvalidEventQuery);
    }
    Ok(())
}
impl CpuSliceQuery {
    pub fn validate(&self) -> Result<(), ContractError> {
        validate(self.range, self.limit)
    }
}
impl ThreadStateQuery {
    pub fn validate(&self) -> Result<(), ContractError> {
        validate(self.range, self.limit)?;
        if self.raw_state.as_ref().is_some_and(|s| s.len() > 256) {
            return Err(ContractError::InvalidEventQuery);
        }
        Ok(())
    }
}

/// Codable shape matches the existing Swift event DTOs, including explicit
/// nulls, table-qualified row IDs, stable internal keys and full event ranges.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CpuSlice {
    pub key: EventKey,
    pub range: TraceTimeRange,
    pub cpu: i64,
    pub thread_key: Option<ThreadKey>,
    pub process_key: Option<ProcessKey>,
    pub tid: Option<i64>,
    pub pid: Option<i64>,
    pub thread_name: Option<String>,
    pub process_name: Option<String>,
    pub end_state: Option<String>,
    pub priority: Option<i64>,
    pub is_open_ended: bool,
}
impl CpuSlice {
    pub fn is_instant(&self) -> bool {
        self.range.is_instant() && !self.is_open_ended
    }
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ThreadStateInterval {
    pub key: EventKey,
    pub range: TraceTimeRange,
    pub thread_key: ThreadKey,
    pub process_key: Option<ProcessKey>,
    pub state: String,
    pub normalized_state: Option<TraceThreadState>,
    pub cpu: Option<i64>,
    pub tid: Option<i64>,
    pub pid: Option<i64>,
    pub process_name: Option<String>,
    pub thread_name: Option<String>,
    pub is_open_ended: bool,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EventPage<T> {
    pub items: Vec<T>,
    pub truncated: bool,
    pub capability_available: bool,
    pub data_quality: DataQuality,
}
