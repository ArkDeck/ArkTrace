//! Swift `TraceDeterministicAnalysisEngine` (the CLI `analyze` batch): the
//! seven sections, their exact status semantics, the effective parameter
//! block and the command-global row retention, over independently bounded
//! repository pages. Reductions reuse this crate's oracle-checked formulas.
use crate::{
    AnalysisError, Check, CpuUtilization, HotInterval, NamedDurationEvidence, RunnableSemantics,
    RunningProcess, RunningThread, SchedulingResult, SchedulingUnsupportedReason,
    StateDistribution, checked_sort, checkpoint, cpu_utilization, event_order, hot_intervals,
    scheduling_latency, state_distribution, top_processes, top_threads,
};
use arktrace_contract::{
    CpuSlice, DataQuality, EventKey, EventPage, ProcessKey, QualityCategory, QualityIssue,
    QualityStatus, ThreadKey, ThreadStateInterval, TraceSlice, TraceTimeRange,
};
use serde::{Serialize, Serializer, ser::SerializeMap};

/// The exact identity filters `analyze` accepts (Swift rejects every other
/// agent filter before the request exists).
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct IdentityFilters {
    pub process_key: Option<i64>,
    pub pid: Option<i64>,
    pub thread_key: Option<i64>,
    pub tid: Option<i64>,
}
/// Swift `TraceAgentQueryFilters` Codable: all twelve keys, stable keys nested.
impl Serialize for IdentityFilters {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut map = serializer.serialize_map(Some(12))?;
        map.serialize_entry("cpu", &None::<i64>)?;
        map.serialize_entry(
            "processKey",
            &self.process_key.map(|ipid| ProcessKey { ipid }),
        )?;
        map.serialize_entry("pid", &self.pid)?;
        map.serialize_entry("threadKey", &self.thread_key.map(|itid| ThreadKey { itid }))?;
        map.serialize_entry("tid", &self.tid)?;
        map.serialize_entry("rawState", &None::<String>)?;
        map.serialize_entry("normalizedState", &None::<String>)?;
        map.serialize_entry("name", &None::<String>)?;
        map.serialize_entry("nameMatch", "exact")?;
        map.serialize_entry("minimumDurationNs", &None::<i64>)?;
        map.serialize_entry("depth", &None::<i64>)?;
        map.serialize_entry("counterFilterID", &None::<i64>)?;
        map.end()
    }
}

/// Swift `TraceDeterministicAnalysisRequest`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DeterministicRequest {
    pub range: TraceTimeRange,
    pub filters: IdentityFilters,
    pub maximum_cpu_slices: usize,
    pub maximum_process_slices: usize,
    pub maximum_thread_slices: usize,
    pub maximum_state_intervals: usize,
    pub maximum_named_slices: usize,
    pub maximum_scheduling_events: usize,
    pub maximum_hot_events: usize,
    pub top_process_limit: usize,
    pub top_thread_limit: usize,
    pub long_slice_limit: usize,
    pub scheduling_sample_limit: usize,
    pub hot_interval_limit: usize,
    pub hot_bucket_count: usize,
    pub minimum_long_slice_duration_ns: i64,
    pub timeout_ms: u64,
}
impl DeterministicRequest {
    /// The CLI shape: one event budget and one output limit for every section.
    pub fn cli(
        range: TraceTimeRange,
        filters: IdentityFilters,
        event_budget: usize,
        limit: usize,
        threshold_ns: i64,
        timeout_ms: u64,
    ) -> Self {
        Self {
            range,
            filters,
            maximum_cpu_slices: event_budget,
            maximum_process_slices: event_budget,
            maximum_thread_slices: event_budget,
            maximum_state_intervals: event_budget,
            maximum_named_slices: event_budget,
            maximum_scheduling_events: event_budget,
            maximum_hot_events: event_budget,
            top_process_limit: limit,
            top_thread_limit: limit,
            long_slice_limit: limit,
            scheduling_sample_limit: limit,
            hot_interval_limit: limit,
            hot_bucket_count: 100,
            minimum_long_slice_duration_ns: threshold_ns,
            timeout_ms,
        }
    }
    pub fn validate(&self) -> Result<(), AnalysisError> {
        let budgets = [
            self.maximum_cpu_slices,
            self.maximum_process_slices,
            self.maximum_thread_slices,
            self.maximum_state_intervals,
            self.maximum_named_slices,
            self.maximum_scheduling_events,
            self.maximum_hot_events,
        ];
        let limits = [
            self.top_process_limit,
            self.top_thread_limit,
            self.long_slice_limit,
            self.scheduling_sample_limit,
            self.hot_interval_limit,
        ];
        if self.range.is_instant()
            || budgets.iter().any(|v| !(1..=100_000).contains(v))
            || limits.iter().any(|v| !(1..=1_000).contains(v))
            || !(1..=10_000).contains(&self.hot_bucket_count)
            || self.minimum_long_slice_duration_ns < 0
            || !(100..=120_000).contains(&self.timeout_ms)
        {
            return Err(AnalysisError::InvalidBounds);
        }
        Ok(())
    }
}

/// Swift `TraceDeterministicAnalysisParameters`: every effective value.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeterministicParameters {
    pub filters: IdentityFilters,
    #[serde(rename = "maximumCPUSlices")]
    pub maximum_cpu_slices: usize,
    pub maximum_process_slices: usize,
    pub maximum_thread_slices: usize,
    pub maximum_state_intervals: usize,
    pub maximum_named_slices: usize,
    pub maximum_scheduling_events: usize,
    pub maximum_hot_events: usize,
    pub top_process_limit: usize,
    pub top_thread_limit: usize,
    pub long_slice_limit: usize,
    pub scheduling_sample_limit: usize,
    pub hot_interval_limit: usize,
    pub hot_bucket_count: usize,
    pub minimum_long_slice_duration_ns: i64,
    /// Swift `Duration.components` of the millisecond timeout.
    pub timeout_seconds: i64,
    pub timeout_attoseconds: i64,
}

/// Swift `TraceLongSlice`: explicit nulls for absent metadata.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LongSlice {
    pub key: EventKey,
    pub range: TraceTimeRange,
    pub name: String,
    pub category: Option<String>,
    pub process_key: Option<ProcessKey>,
    pub thread_key: Option<ThreadKey>,
    pub pid: Option<i64>,
    pub tid: Option<i64>,
    pub process_name: Option<String>,
    pub thread_name: Option<String>,
}

/// Swift `TraceAnalysisSectionStatus`.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeterministicSectionStatus {
    pub returned_count: usize,
    pub matched_count: Option<usize>,
    pub truncated: bool,
}
impl DeterministicSectionStatus {
    fn retained(self, returned_count: usize) -> Self {
        Self {
            returned_count,
            matched_count: self.matched_count,
            truncated: self.truncated || returned_count < self.returned_count,
        }
    }
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeterministicSections {
    pub cpu_utilization: DeterministicSectionStatus,
    pub top_processes: DeterministicSectionStatus,
    pub top_threads: DeterministicSectionStatus,
    pub long_slices: DeterministicSectionStatus,
    pub thread_state_distribution: DeterministicSectionStatus,
    pub scheduling_latency: DeterministicSectionStatus,
    pub hot_intervals: DeterministicSectionStatus,
}
impl DeterministicSections {
    /// Swift `analysisTruncationSections`, in its fixed append order.
    pub fn truncated_names(&self) -> Vec<&'static str> {
        [
            ("cpuUtilization", self.cpu_utilization),
            ("topProcesses", self.top_processes),
            ("topThreads", self.top_threads),
            ("longSlices", self.long_slices),
            ("threadStateDistribution", self.thread_state_distribution),
            ("schedulingLatency", self.scheduling_latency),
            ("hotIntervals", self.hot_intervals),
        ]
        .into_iter()
        .filter(|(_, status)| status.truncated)
        .map(|(name, _)| name)
        .collect()
    }
}

/// Swift `TraceDeterministicAnalysis` in its Machine (`CLIMachine...Result`)
/// shape: quality is the machine projection, `kind` is `deterministicBatch`.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeterministicAnalysis {
    pub kind: &'static str,
    pub parameters: DeterministicParameters,
    pub range: TraceTimeRange,
    pub cpu_utilization: Vec<CpuUtilization>,
    pub top_processes: Vec<RunningProcess>,
    pub top_threads: Vec<RunningThread>,
    pub long_slices: Vec<LongSlice>,
    pub thread_state_distribution: Vec<StateDistribution>,
    pub scheduling_latency: SchedulingResult,
    pub hot_intervals: Vec<HotInterval>,
    pub sections: DeterministicSections,
    pub data_quality: DataQuality,
}
impl DeterministicAnalysis {
    /// Swift `retainingRows(maximumRows:)`: one command-global row budget
    /// across the seven sections in a fixed semantic priority.
    pub fn retain_rows(&mut self, maximum: usize) {
        let mut remaining = maximum;
        fn retain<T>(rows: &mut Vec<T>, remaining: &mut usize) -> usize {
            let count = rows.len().min(*remaining);
            *remaining -= count;
            rows.truncate(count);
            count
        }
        let sections = &mut self.sections;
        let n = retain(&mut self.cpu_utilization, &mut remaining);
        sections.cpu_utilization = sections.cpu_utilization.retained(n);
        let n = retain(&mut self.top_processes, &mut remaining);
        sections.top_processes = sections.top_processes.retained(n);
        let n = retain(&mut self.top_threads, &mut remaining);
        sections.top_threads = sections.top_threads.retained(n);
        let n = retain(&mut self.long_slices, &mut remaining);
        sections.long_slices = sections.long_slices.retained(n);
        let n = retain(&mut self.thread_state_distribution, &mut remaining);
        sections.thread_state_distribution = sections.thread_state_distribution.retained(n);
        let original = self.scheduling_latency.top_samples.len();
        let n = retain(&mut self.scheduling_latency.top_samples, &mut remaining);
        self.scheduling_latency.truncated |= n < original;
        sections.scheduling_latency = sections.scheduling_latency.retained(n);
        let n = retain(&mut self.hot_intervals, &mut remaining);
        sections.hot_intervals = sections.hot_intervals.retained(n);
    }
}

/// Independently bounded raw repository pages, one per distinct Swift query.
/// Pages whose Swift query is identical may be the same page.
pub struct DeterministicInput<'a> {
    pub cpu: &'a EventPage<CpuSlice>,
    pub processes: &'a EventPage<CpuSlice>,
    pub threads: &'a EventPage<CpuSlice>,
    pub states: &'a EventPage<ThreadStateInterval>,
    pub named: &'a EventPage<TraceSlice>,
    pub scheduling_cpu: &'a EventPage<CpuSlice>,
    pub scheduling_states: &'a EventPage<ThreadStateInterval>,
    pub hot_cpu: &'a EventPage<CpuSlice>,
    pub hot_named: &'a EventPage<TraceSlice>,
    /// Trace metadata `cpuScheduling && threadStates` capabilities.
    pub scheduling_capable: bool,
    pub trace_quality: &'a [QualityIssue],
}

fn long_slice_order(a: &TraceSlice, b: &TraceSlice) -> std::cmp::Ordering {
    (std::cmp::Reverse(a.range.duration_ns()), event_order(a.key))
        .cmp(&(std::cmp::Reverse(b.range.duration_ns()), event_order(b.key)))
}

/// Swift `stableQuality` over every source page plus the overlap fact, then
/// the machine projection (messages dropped, raw-key order).
pub(crate) fn merged_quality(
    sources: &[&[QualityIssue]],
    extra: Vec<QualityIssue>,
    check: &mut Check<'_>,
) -> Result<DataQuality, AnalysisError> {
    let mut seen = std::collections::BTreeSet::new();
    let mut issues = Vec::new();
    let mut scanned = 0;
    for source in sources {
        for issue in source.iter() {
            checkpoint(scanned, check)?;
            scanned += 1;
            let key = (
                issue.category,
                issue.scope.clone(),
                issue.count,
                issue.message.clone(),
            );
            if seen.insert(key) {
                issues.push(issue.clone());
            }
        }
    }
    for issue in extra {
        let key = (
            issue.category,
            issue.scope.clone(),
            issue.count,
            issue.message.clone(),
        );
        if seen.insert(key) {
            issues.push(issue);
        }
    }
    let status = if issues.is_empty() {
        QualityStatus::Ok
    } else {
        QualityStatus::Warnings
    };
    Ok(DataQuality::machine(status, issues)?)
}

pub fn deterministic_analysis(
    request: &DeterministicRequest,
    input: DeterministicInput<'_>,
    check: &mut Check<'_>,
) -> Result<DeterministicAnalysis, AnalysisError> {
    check()?;
    request.validate()?;
    for (page, maximum) in [
        (input.cpu, request.maximum_cpu_slices),
        (input.processes, request.maximum_process_slices),
        (input.threads, request.maximum_thread_slices),
        (input.scheduling_cpu, request.maximum_scheduling_events),
        (input.hot_cpu, request.maximum_hot_events),
    ] {
        crate::validate_page(page, maximum)?;
    }
    crate::validate_page(input.states, request.maximum_state_intervals)?;
    crate::validate_page(input.scheduling_states, request.maximum_scheduling_events)?;
    crate::validate_page(input.named, request.maximum_named_slices)?;
    crate::validate_page(input.hot_named, request.maximum_hot_events)?;
    let range = request.range;

    let cpu = cpu_utilization(&input.cpu.items, range, check)?;
    let processes = top_processes(
        &input.processes.items,
        range,
        request.top_process_limit,
        check,
    )?;
    let threads = top_threads(&input.threads.items, range, request.top_thread_limit, check)?;
    let states = state_distribution(&input.states.items, range, check)?;

    let mut long_candidates: Vec<&TraceSlice> = input.named.items.iter().collect();
    checked_sort(&mut long_candidates, |a, b| long_slice_order(a, b), check)?;
    let long_slices: Vec<LongSlice> = long_candidates
        .iter()
        .take(request.long_slice_limit)
        .map(|value| LongSlice {
            key: value.key,
            range: value.range,
            name: value.name.clone(),
            category: value.category.clone(),
            process_key: value.process_key,
            thread_key: value.thread_key,
            pid: value.pid,
            tid: value.tid,
            process_name: value.process_name.clone(),
            thread_name: value.thread_name.clone(),
        })
        .collect();

    // Swift proves a transition only with both trace capabilities and both
    // pages available; normalized Runnable with an observed (not open-ended)
    // end exactly at the same thread's next scheduled start is the proof.
    let scheduling = if input.scheduling_capable
        && input.scheduling_cpu.capability_available
        && input.scheduling_states.capability_available
    {
        scheduling_latency(
            input.scheduling_cpu,
            input.scheduling_states,
            RunnableSemantics::ProvenNormalizedIntervals,
            request.scheduling_sample_limit,
            check,
        )?
    } else {
        SchedulingResult {
            supported: false,
            unsupported_reason: Some(SchedulingUnsupportedReason::CapabilityUnavailable),
            count: 0,
            percentiles: None,
            top_samples: Vec::new(),
            truncated: false,
        }
    };

    let mut named_evidence = Vec::with_capacity(input.hot_named.items.len());
    for (index, slice) in input.hot_named.items.iter().enumerate() {
        checkpoint(index, check)?;
        named_evidence.push(NamedDurationEvidence {
            key: slice.key,
            range: slice.range,
        });
    }
    let hot_candidates = hot_intervals(
        &input.hot_cpu.items,
        &named_evidence,
        range,
        request.hot_bucket_count,
        request.minimum_long_slice_duration_ns,
        check,
    )?;
    let hot_matched = hot_candidates.len();
    let hot: Vec<_> = hot_candidates
        .into_iter()
        .take(request.hot_interval_limit)
        .collect();

    let overlap = cpu
        .iter()
        .filter(|value| value.raw_running_ns > range.duration_ns())
        .count();
    let extra = if overlap > 0 {
        vec![QualityIssue {
            category: QualityCategory::InvalidValue,
            scope: Some("sched_slice.overlap".into()),
            count: Some(overlap as i64),
            message: Some("Raw scheduled time exceeded the selected range".into()),
        }]
    } else {
        Vec::new()
    };
    let data_quality = merged_quality(
        &[
            input.trace_quality,
            &input.cpu.data_quality.warnings,
            &input.processes.data_quality.warnings,
            &input.threads.data_quality.warnings,
            &input.states.data_quality.warnings,
            &input.named.data_quality.warnings,
            &input.scheduling_cpu.data_quality.warnings,
            &input.scheduling_states.data_quality.warnings,
            &input.hot_cpu.data_quality.warnings,
            &input.hot_named.data_quality.warnings,
        ],
        extra,
        check,
    )?;

    let status = |returned, matched: Option<usize>, truncated| DeterministicSectionStatus {
        returned_count: returned,
        matched_count: matched,
        truncated,
    };
    let unless = |truncated: bool, value: usize| (!truncated).then_some(value);
    let scheduling_sampled = input.scheduling_cpu.truncated || input.scheduling_states.truncated;
    let hot_sampled = input.hot_cpu.truncated || input.hot_named.truncated;
    let sections = DeterministicSections {
        cpu_utilization: status(
            cpu.len(),
            unless(input.cpu.truncated, input.cpu.items.len()),
            input.cpu.truncated,
        ),
        top_processes: status(
            processes.items.len(),
            unless(input.processes.truncated, processes.matched_count),
            input.processes.truncated || processes.matched_count > processes.items.len(),
        ),
        top_threads: status(
            threads.items.len(),
            unless(input.threads.truncated, threads.matched_count),
            input.threads.truncated || threads.matched_count > threads.items.len(),
        ),
        long_slices: status(
            long_slices.len(),
            unless(input.named.truncated, long_candidates.len()),
            input.named.truncated || long_candidates.len() > long_slices.len(),
        ),
        thread_state_distribution: status(
            states.len(),
            unless(input.states.truncated, input.states.items.len()),
            input.states.truncated,
        ),
        scheduling_latency: status(
            scheduling.top_samples.len(),
            unless(scheduling_sampled, scheduling.count),
            scheduling.truncated,
        ),
        hot_intervals: status(
            hot.len(),
            unless(hot_sampled, hot_matched),
            hot_sampled || hot_matched > hot.len(),
        ),
    };
    check()?;
    Ok(DeterministicAnalysis {
        kind: "deterministicBatch",
        parameters: DeterministicParameters {
            filters: request.filters,
            maximum_cpu_slices: request.maximum_cpu_slices,
            maximum_process_slices: request.maximum_process_slices,
            maximum_thread_slices: request.maximum_thread_slices,
            maximum_state_intervals: request.maximum_state_intervals,
            maximum_named_slices: request.maximum_named_slices,
            maximum_scheduling_events: request.maximum_scheduling_events,
            maximum_hot_events: request.maximum_hot_events,
            top_process_limit: request.top_process_limit,
            top_thread_limit: request.top_thread_limit,
            long_slice_limit: request.long_slice_limit,
            scheduling_sample_limit: request.scheduling_sample_limit,
            hot_interval_limit: request.hot_interval_limit,
            hot_bucket_count: request.hot_bucket_count,
            minimum_long_slice_duration_ns: request.minimum_long_slice_duration_ns,
            timeout_seconds: (request.timeout_ms / 1_000) as i64,
            timeout_attoseconds: (request.timeout_ms % 1_000) as i64 * 1_000_000_000_000_000,
        },
        range,
        cpu_utilization: cpu,
        top_processes: processes.items,
        top_threads: threads.items,
        long_slices,
        thread_state_distribution: states,
        scheduling_latency: scheduling,
        hot_intervals: hot,
        sections,
        data_quality,
    })
}
