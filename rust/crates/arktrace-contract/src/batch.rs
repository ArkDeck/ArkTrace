use crate::{
    ContractError, CounterQuery, CounterSeries, CounterSeriesDescriptor, CounterSeriesQuery,
    CpuSlice, CpuSliceQuery, DirectoryPage, EventPage, ProcessKey, ThreadKey, ThreadQuery,
    ThreadStateInterval, ThreadStateQuery, TraceDensityQuery, TraceDensityResult, TraceSlice,
    TraceSliceQuery, TraceThread,
};
use serde::{Deserialize, Serialize};

/// The existing seven-family repository batch. Resource policy is supplied
/// by Engine; it is never an extra filter in the serialized query contract.
#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase", deny_unknown_fields)]
pub struct TraceRepositoryEventBatch {
    pub cpu_slices: Vec<CpuSliceQuery>,
    pub thread_states: Vec<ThreadStateQuery>,
    pub slices: Vec<TraceSliceQuery>,
    pub counters: Vec<CounterQuery>,
    pub counter_series: Vec<CounterSeriesQuery>,
    pub densities: Vec<TraceDensityQuery>,
    pub threads: Vec<ThreadQuery>,
}
impl TraceRepositoryEventBatch {
    pub const MAXIMUM_QUERY_COUNT: usize = 32;

    pub fn query_count(&self) -> usize {
        [
            self.cpu_slices.len(),
            self.thread_states.len(),
            self.slices.len(),
            self.counters.len(),
            self.counter_series.len(),
            self.densities.len(),
            self.threads.len(),
        ]
        .into_iter()
        .fold(0, usize::saturating_add)
    }

    pub fn validate(&self) -> Result<(), ContractError> {
        if !(1..=Self::MAXIMUM_QUERY_COUNT).contains(&self.query_count()) {
            return Err(ContractError::InvalidEventQuery);
        }
        for query in &self.cpu_slices {
            query.validate()?;
        }
        for query in &self.thread_states {
            query.validate()?;
        }
        for query in &self.slices {
            query.validate()?;
        }
        for query in &self.counters {
            query.validate()?;
        }
        for query in &self.counter_series {
            query.validate()?;
        }
        for query in &self.densities {
            query.validate()?;
        }
        for query in &self.threads {
            query.validate()?;
        }
        Ok(())
    }
}

/// Each array has exactly its input query count and order; no partial batch is
/// published on failure. Empty and unavailable pages keep their typed facts.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TraceRepositoryEventBatchResult {
    pub cpu_slices: Vec<EventPage<CpuSlice>>,
    pub thread_states: Vec<EventPage<ThreadStateInterval>>,
    pub slices: Vec<EventPage<TraceSlice>>,
    pub counters: Vec<EventPage<CounterSeries>>,
    pub counter_series: Vec<EventPage<CounterSeriesDescriptor>>,
    pub densities: Vec<TraceDensityResult>,
    pub threads: Vec<DirectoryPage<TraceRepositoryThread>>,
}

/// Repository/SDK model identity, matching the Swift model Codable shape.
/// The existing CLI directory projection carries scalar identity fields.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TraceRepositoryThread {
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
impl From<TraceThread> for TraceRepositoryThread {
    fn from(thread: TraceThread) -> Self {
        Self {
            key: ThreadKey { itid: thread.key },
            process_key: thread.process_key.map(|ipid| ProcessKey { ipid }),
            tid: thread.tid,
            pid: thread.pid,
            name: thread.name,
            process_name: thread.process_name,
            start_ns: thread.start_ns,
            end_ns: thread.end_ns,
            is_main_thread: thread.is_main_thread,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{DirectoryNameMatch, TraceTimeRange};

    #[test]
    fn seven_family_batch_enforces_total_count_and_each_query_contract() {
        let query = CounterSeriesQuery {
            range: TraceTimeRange::query(0, 10).unwrap(),
            limit: 1,
        };
        let thread = ThreadQuery {
            process_key: None,
            pid: None,
            thread_key: None,
            tid: None,
            name: None,
            name_match: DirectoryNameMatch::Exact,
            limit: 1,
        };
        let mut batch = TraceRepositoryEventBatch::default();
        assert!(batch.validate().is_err());
        batch.counter_series = vec![query; 31];
        batch.threads.push(thread);
        batch.validate().unwrap();
        assert_eq!(batch.query_count(), 32);
        batch.threads.push(batch.threads[0].clone());
        assert!(batch.validate().is_err());
        batch.threads.pop();
        batch.counter_series[17].limit = 0;
        assert!(batch.validate().is_err());
        assert!(
            serde_json::from_str::<TraceRepositoryEventBatch>(r#"{"sql":"SELECT 1"}"#).is_err()
        );
        assert_eq!(
            serde_json::from_str::<TraceRepositoryEventBatch>("{}").unwrap(),
            TraceRepositoryEventBatch::default()
        );
    }
}
