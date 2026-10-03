use crate::{AnalysisError, validate_limit, validate_range};
use arktrace_contract::{
    CpuSlice, DataQuality, EventKey, EventPage, ProcessKey, ThreadKey, ThreadStateInterval,
    TraceThreadState, TraceTimeRange,
};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AnalysisRequest {
    pub range: TraceTimeRange,
    #[serde(rename = "maximumCPUSlices")]
    pub maximum_cpu_slices: usize,
    pub maximum_process_slices: usize,
    pub maximum_thread_slices: usize,
    pub maximum_state_intervals: usize,
    pub maximum_scheduling_events: usize,
    pub maximum_hot_events: usize,
    pub top_process_limit: usize,
    pub top_thread_limit: usize,
    pub scheduling_sample_limit: usize,
    pub hot_interval_limit: usize,
    pub hot_bucket_count: usize,
    pub minimum_long_slice_duration_ns: i64,
    pub maximum_output_rows: usize,
}
impl AnalysisRequest {
    pub fn new(range: TraceTimeRange) -> Self {
        Self {
            range,
            maximum_cpu_slices: 20_000,
            maximum_process_slices: 20_000,
            maximum_thread_slices: 20_000,
            maximum_state_intervals: 20_000,
            maximum_scheduling_events: 20_000,
            maximum_hot_events: 20_000,
            top_process_limit: 10,
            top_thread_limit: 10,
            scheduling_sample_limit: 20,
            hot_interval_limit: 20,
            hot_bucket_count: 100,
            minimum_long_slice_duration_ns: 0,
            maximum_output_rows: 100_000,
        }
    }
    pub fn validate(&self) -> Result<(), AnalysisError> {
        validate_range(self.range)?;
        for bound in [
            self.maximum_cpu_slices,
            self.maximum_process_slices,
            self.maximum_thread_slices,
            self.maximum_state_intervals,
            self.maximum_scheduling_events,
            self.maximum_hot_events,
        ] {
            if !(1..=100_000).contains(&bound) {
                return Err(AnalysisError::InvalidBounds);
            }
        }
        for limit in [
            self.top_process_limit,
            self.top_thread_limit,
            self.scheduling_sample_limit,
            self.hot_interval_limit,
        ] {
            validate_limit(limit)?;
        }
        if !(1..=10_000).contains(&self.hot_bucket_count)
            || self.minimum_long_slice_duration_ns < 0
            || self.maximum_output_rows > 100_000
        {
            return Err(AnalysisError::InvalidBounds);
        }
        Ok(())
    }
}

/// Explicit adapter attestation that normalized Runnable describes runnable
/// waiting time. Unknown raw states are never promoted to Runnable here.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RunnableSemantics {
    Unproven,
    ProvenNormalizedIntervals,
}

/// Minimal projection for the hot formula; not a replacement named-slice DTO.
/// The adapter must supply actual table-qualified identities and full ranges
/// from its typed named query. No synthetic buckets become event identities.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NamedDurationEvidence {
    pub key: EventKey,
    pub range: TraceTimeRange,
}

pub struct AnalysisInput<'a> {
    pub cpu: &'a EventPage<CpuSlice>,
    pub processes: &'a EventPage<CpuSlice>,
    pub threads: &'a EventPage<CpuSlice>,
    pub states: &'a EventPage<ThreadStateInterval>,
    pub scheduling_cpu: &'a EventPage<CpuSlice>,
    pub scheduling_states: &'a EventPage<ThreadStateInterval>,
    pub runnable_semantics: RunnableSemantics,
    pub hot_cpu: &'a EventPage<CpuSlice>,
    pub hot_named: Option<&'a EventPage<NamedDurationEvidence>>,
    pub named_slices_available: bool,
    pub trace_quality: &'a DataQuality,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CpuUtilization {
    pub cpu: i64,
    pub raw_running_ns: i64,
    pub occupied_ns: i64,
    pub slice_count: usize,
    pub utilization: f64,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RunningProcess {
    pub process_key: ProcessKey,
    pub pid: Option<i64>,
    pub name: Option<String>,
    pub running_ns: i64,
    #[serde(rename = "shareOfOneCPU")]
    pub share_of_one_cpu: f64,
    pub slice_count: usize,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RunningThread {
    pub thread_key: ThreadKey,
    pub process_key: Option<ProcessKey>,
    pub tid: Option<i64>,
    pub pid: Option<i64>,
    pub name: Option<String>,
    pub process_name: Option<String>,
    pub running_ns: i64,
    #[serde(rename = "shareOfOneCPU")]
    pub share_of_one_cpu: f64,
    pub slice_count: usize,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StateDistribution {
    pub thread_key: ThreadKey,
    pub process_key: Option<ProcessKey>,
    pub tid: Option<i64>,
    pub pid: Option<i64>,
    pub raw_state: String,
    pub normalized_state: Option<TraceThreadState>,
    pub duration_ns: i64,
    pub percentage_of_range: f64,
    pub interval_count: usize,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Ranked<T> {
    pub items: Vec<T>,
    pub matched_count: usize,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Percentiles {
    pub p50_ns: i64,
    pub p90_ns: i64,
    pub p95_ns: i64,
    pub p99_ns: i64,
    pub max_ns: i64,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SchedulingSample {
    pub thread_key: ThreadKey,
    pub runnable_event_key: EventKey,
    pub running_event_key: EventKey,
    pub runnable_end_ns: i64,
    pub running_start_ns: i64,
    pub latency_ns: i64,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SchedulingUnsupportedReason {
    CapabilityUnavailable,
    NoProvableRunnableTransitions,
    RunnableSemanticsUnproven,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SchedulingResult {
    pub supported: bool,
    pub unsupported_reason: Option<SchedulingUnsupportedReason>,
    pub count: usize,
    pub percentiles: Option<Percentiles>,
    pub top_samples: Vec<SchedulingSample>,
    pub truncated: bool,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct HotIntervalScore {
    pub cpu_busy_ns: i64,
    pub context_switch_count: usize,
    pub context_switch_score_ns: i64,
    pub long_slice_ns: i64,
    pub total: i64,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct HotInterval {
    pub range: TraceTimeRange,
    pub score: HotIntervalScore,
    pub cpu_slice_count: usize,
    pub named_slice_count: usize,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SectionStatus {
    pub returned_count: usize,
    pub matched_count: Option<usize>,
    pub truncated: bool,
    /// A truncated source page makes aggregate metrics lower bounds.
    pub sampled: bool,
    pub supported: bool,
}
impl SectionStatus {
    pub(crate) fn new(returned: usize, matched: usize, sampled: bool, supported: bool) -> Self {
        Self {
            returned_count: returned,
            matched_count: if sampled { None } else { Some(matched) },
            truncated: sampled || returned < matched,
            sampled,
            supported,
        }
    }
    fn retain(&mut self, count: usize) {
        self.truncated |= count < self.returned_count;
        self.returned_count = count;
    }
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AnalysisSections {
    pub cpu_utilization: SectionStatus,
    pub top_processes: SectionStatus,
    pub top_threads: SectionStatus,
    pub thread_state_distribution: SectionStatus,
    pub scheduling_latency: SectionStatus,
    pub hot_intervals: SectionStatus,
}
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AnalysisResult {
    pub kind: String,
    pub parameters: AnalysisRequest,
    pub range: TraceTimeRange,
    pub cpu_utilization: Vec<CpuUtilization>,
    pub top_processes: Vec<RunningProcess>,
    pub top_threads: Vec<RunningThread>,
    pub thread_state_distribution: Vec<StateDistribution>,
    pub scheduling_latency: SchedulingResult,
    pub hot_intervals: Vec<HotInterval>,
    pub hot_intervals_unsupported_reason: Option<String>,
    pub sections: AnalysisSections,
    pub data_quality: DataQuality,
}
impl AnalysisResult {
    /// Fixed section priority matches the implemented subsequence of Swift's
    /// global projection. Sampling facts and percentiles survive output trims.
    pub fn retain_rows(&mut self, maximum: usize) {
        fn retain<T>(rows: &mut Vec<T>, section: &mut SectionStatus, remaining: &mut usize) {
            let count = rows.len().min(*remaining);
            *remaining -= count;
            rows.truncate(count);
            section.retain(count);
        }
        let mut remaining = maximum;
        retain(
            &mut self.cpu_utilization,
            &mut self.sections.cpu_utilization,
            &mut remaining,
        );
        retain(
            &mut self.top_processes,
            &mut self.sections.top_processes,
            &mut remaining,
        );
        retain(
            &mut self.top_threads,
            &mut self.sections.top_threads,
            &mut remaining,
        );
        retain(
            &mut self.thread_state_distribution,
            &mut self.sections.thread_state_distribution,
            &mut remaining,
        );
        let original = self.scheduling_latency.top_samples.len();
        retain(
            &mut self.scheduling_latency.top_samples,
            &mut self.sections.scheduling_latency,
            &mut remaining,
        );
        self.scheduling_latency.truncated |= original > self.scheduling_latency.top_samples.len();
        retain(
            &mut self.hot_intervals,
            &mut self.sections.hot_intervals,
            &mut remaining,
        );
    }
}
