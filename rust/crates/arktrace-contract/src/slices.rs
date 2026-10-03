use crate::{
    ContractError, DirectoryNameMatch, EventKey, EventTable, ProcessKey, ThreadKey, TraceTimeRange,
};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TraceSliceQuery {
    pub range: TraceTimeRange,
    pub event_key: Option<EventKey>,
    pub process_key: Option<i64>,
    pub pid: Option<i64>,
    pub thread_key: Option<i64>,
    pub tid: Option<i64>,
    /// Same absent/zero callid scope as an unattributed named-slice lane.
    /// False preserves existing general queries and their serialized shape.
    #[serde(default, skip_serializing_if = "is_false")]
    pub unattributed_only: bool,
    pub name: Option<String>,
    pub name_match: DirectoryNameMatch,
    pub minimum_duration_ns: Option<i64>,
    pub depth: Option<i64>,
    pub includes_argument_set: bool,
    pub limit: usize,
}
impl TraceSliceQuery {
    pub fn validate(&self) -> Result<(), ContractError> {
        if self.range.is_instant()
            || !(1..=100_000).contains(&self.limit)
            || self
                .event_key
                .is_some_and(|k| k.table != EventTable::Callstack)
            || self.minimum_duration_ns.is_some_and(|v| v < 0)
            || self.depth.is_some_and(|v| v < 0)
            || self.name.as_ref().is_some_and(|v| v.len() > 4096)
            || (self.unattributed_only
                && [self.process_key, self.pid, self.thread_key, self.tid]
                    .iter()
                    .any(Option::is_some))
        {
            return Err(ContractError::InvalidEventQuery);
        }
        Ok(())
    }
}
fn is_false(value: &bool) -> bool {
    !value
}

/// Swift's complete slice coded shape. The inspector-only argument-set handle
/// is deliberately omitted from Machine JSON and restored as None on decode.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TraceSlice {
    pub key: EventKey,
    pub range: TraceTimeRange,
    pub thread_key: Option<ThreadKey>,
    pub process_key: Option<ProcessKey>,
    pub pid: Option<i64>,
    pub tid: Option<i64>,
    pub process_name: Option<String>,
    pub thread_name: Option<String>,
    pub name: String,
    pub category: Option<String>,
    pub depth: Option<i64>,
    pub parent_event_key: Option<EventKey>,
    pub is_async: bool,
    pub is_open_ended: bool,
    #[serde(skip)]
    pub arg_set_id: Option<i64>,
}
impl TraceSlice {
    pub fn is_instant(&self) -> bool {
        self.range.is_instant() && !self.is_open_ended
    }
}
