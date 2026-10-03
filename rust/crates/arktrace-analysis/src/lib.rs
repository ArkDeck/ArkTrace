//! Bounded pure reductions shared by the future CLI, SDK and App adapters.
//!
//! Inputs are independently bounded, already filtered repository pages. This
//! crate never executes queries or infers capabilities. Nanoseconds saturate
//! on checked overflow, matching the Swift analysis oracle. Fractions are
//! binary64 division without decimal rounding (percentages are fractions).
mod hot;
mod reduce;
mod scheduling;
mod search;
mod types;

pub use hot::{CONTEXT_SWITCH_WEIGHT_NS, hot_intervals};
pub use reduce::{cpu_utilization, state_distribution, top_processes, top_threads};
pub use scheduling::scheduling_latency;
pub use search::{SearchError, SearchRepository, search};
pub use types::*;

use arktrace_contract::{
    ContractError, DataQuality, EventPage, QualityCategory, QualityIssue, QualityStatus,
};

pub type Check<'a> = dyn FnMut() -> Result<(), AnalysisError> + 'a;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AnalysisError {
    InvalidBounds,
    InputBudgetExceeded,
    InvalidEvidence,
    Cancelled,
    DeadlineReached,
    Quality(ContractError),
}
impl From<ContractError> for AnalysisError {
    fn from(value: ContractError) -> Self {
        Self::Quality(value)
    }
}
impl std::fmt::Display for AnalysisError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for AnalysisError {}

pub(crate) fn checkpoint(index: usize, check: &mut Check<'_>) -> Result<(), AnalysisError> {
    if index.is_multiple_of(256) {
        check()?;
    }
    Ok(())
}
pub(crate) fn validate_range(
    range: arktrace_contract::TraceTimeRange,
) -> Result<(), AnalysisError> {
    if range.is_instant() {
        Err(AnalysisError::InvalidBounds)
    } else {
        Ok(())
    }
}
pub(crate) fn validate_page<T>(page: &EventPage<T>, maximum: usize) -> Result<(), AnalysisError> {
    if !(1..=100_000).contains(&maximum) {
        return Err(AnalysisError::InvalidBounds);
    }
    if page.items.len() > maximum {
        return Err(AnalysisError::InputBudgetExceeded);
    }
    if !page.capability_available && (!page.items.is_empty() || page.truncated) {
        return Err(AnalysisError::InvalidEvidence);
    }
    // Validate at the public boundary even when the caller constructed the DTO.
    DataQuality::machine(page.data_quality.status, page.data_quality.warnings.clone())?;
    Ok(())
}
pub(crate) fn validate_items(count: usize) -> Result<(), AnalysisError> {
    if count > 100_000 {
        Err(AnalysisError::InputBudgetExceeded)
    } else {
        Ok(())
    }
}
pub(crate) fn validate_limit(limit: usize) -> Result<(), AnalysisError> {
    if (1..=1_000).contains(&limit) {
        Ok(())
    } else {
        Err(AnalysisError::InvalidBounds)
    }
}
pub(crate) fn sat_add(a: i64, b: i64) -> i64 {
    a.checked_add(b).unwrap_or(i64::MAX)
}
pub(crate) fn sat_mul(a: i64, b: i64) -> i64 {
    a.checked_mul(b).unwrap_or(i64::MAX)
}
pub(crate) fn table_name(table: arktrace_contract::EventTable) -> &'static str {
    use arktrace_contract::EventTable::*;
    match table {
        SchedSlice => "sched_slice",
        ThreadState => "thread_state",
        Callstack => "callstack",
        Measure => "measure",
        ProcessMeasure => "process_measure",
        FrameSlice => "frame_slice",
    }
}
pub(crate) fn event_order(key: arktrace_contract::EventKey) -> (&'static str, i64) {
    (table_name(key.table), key.row_id)
}

/// Validate through the contract's single machine-safe conversion. Exact
/// repeated source issues are removed before conversion, like Swift's Set.
/// Distinct human messages may become repeated structured warnings, also like
/// Swift; messages never influence formulas or escape into the result.
fn quality(
    pages: &[&DataQuality],
    overlap_count: usize,
    check: &mut Check<'_>,
) -> Result<DataQuality, AnalysisError> {
    let mut issues = Vec::new();
    let mut seen = std::collections::BTreeSet::new();
    let mut scanned = 0;
    for page in pages {
        DataQuality::machine(page.status, page.warnings.clone())?;
        for issue in &page.warnings {
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
    if overlap_count > 0 {
        issues.push(QualityIssue {
            category: QualityCategory::InvalidValue,
            scope: Some("sched_slice.overlap".into()),
            count: Some(overlap_count as i64),
            message: None,
        });
    }
    let status = if issues.is_empty() {
        QualityStatus::Ok
    } else {
        QualityStatus::Warnings
    };
    Ok(DataQuality::machine(status, issues)?)
}

/// Reduces independent query pages; input bounds are enforced rather than
/// silently slicing pages and claiming that a complete query was sampled.
/// Missing named DTO/query wiring is represented explicitly. A host must
/// materialize exact filters, trace-range normalization, provenance and byte
/// limits before exposing this as the versioned machine envelope.
pub fn analyze(
    request: &AnalysisRequest,
    input: AnalysisInput<'_>,
    check: &mut Check<'_>,
) -> Result<AnalysisResult, AnalysisError> {
    check()?;
    request.validate()?;
    for (page, budget) in [
        (input.cpu, request.maximum_cpu_slices),
        (input.processes, request.maximum_process_slices),
        (input.threads, request.maximum_thread_slices),
        (input.scheduling_cpu, request.maximum_scheduling_events),
        (input.hot_cpu, request.maximum_hot_events),
    ] {
        validate_page(page, budget)?;
    }
    validate_page(input.states, request.maximum_state_intervals)?;
    validate_page(input.scheduling_states, request.maximum_scheduling_events)?;
    if let Some(named) = input.hot_named {
        validate_page(named, request.maximum_hot_events)?;
        if named.capability_available != input.named_slices_available {
            return Err(AnalysisError::InvalidEvidence);
        }
    }
    // Pages must represent the requested half-open range, not arbitrary raw
    // records. Zero-duration events at the exclusive end are rejected.
    for page in [
        input.cpu,
        input.processes,
        input.threads,
        input.scheduling_cpu,
        input.hot_cpu,
    ] {
        for (i, item) in page.items.iter().enumerate() {
            checkpoint(i, check)?;
            if !item.range.intersects(request.range)
                || item.key.table != arktrace_contract::EventTable::SchedSlice
            {
                return Err(AnalysisError::InvalidEvidence);
            }
        }
    }
    for page in [input.states, input.scheduling_states] {
        for (i, item) in page.items.iter().enumerate() {
            checkpoint(i, check)?;
            if !item.range.intersects(request.range)
                || item.key.table != arktrace_contract::EventTable::ThreadState
            {
                return Err(AnalysisError::InvalidEvidence);
            }
        }
    }
    if let Some(page) = input.hot_named {
        for (i, item) in page.items.iter().enumerate() {
            checkpoint(i, check)?;
            if !item.range.intersects(request.range)
                || item.range.duration_ns() < request.minimum_long_slice_duration_ns
                || item.key.table != arktrace_contract::EventTable::Callstack
            {
                return Err(AnalysisError::InvalidEvidence);
            }
        }
    }
    let cpu = cpu_utilization(&input.cpu.items, request.range, check)?;
    let processes = top_processes(
        &input.processes.items,
        request.range,
        request.top_process_limit,
        check,
    )?;
    let threads = top_threads(
        &input.threads.items,
        request.range,
        request.top_thread_limit,
        check,
    )?;
    let states = state_distribution(&input.states.items, request.range, check)?;
    let scheduling = scheduling_latency(
        input.scheduling_cpu,
        input.scheduling_states,
        input.runnable_semantics,
        request.scheduling_sample_limit,
        check,
    )?;
    let named_ready = input.hot_named.is_some() || !input.named_slices_available;
    let hot = if named_ready {
        hot_intervals(
            &input.hot_cpu.items,
            input
                .hot_named
                .map(|p| p.items.as_slice())
                .unwrap_or_default(),
            request.range,
            request.hot_bucket_count,
            request.minimum_long_slice_duration_ns,
            check,
        )?
    } else {
        Vec::new()
    };
    let hot_matched = hot.len();
    let hot_items: Vec<_> = hot.into_iter().take(request.hot_interval_limit).collect();
    let mut pages = vec![
        input.trace_quality,
        &input.cpu.data_quality,
        &input.processes.data_quality,
        &input.threads.data_quality,
        &input.states.data_quality,
        &input.scheduling_cpu.data_quality,
        &input.scheduling_states.data_quality,
        &input.hot_cpu.data_quality,
    ];
    if let Some(page) = input.hot_named {
        pages.push(&page.data_quality);
    }
    let data_quality = quality(
        &pages,
        cpu.iter()
            .filter(|c| c.raw_running_ns > request.range.duration_ns())
            .count(),
        check,
    )?;
    let hot_sampled = input.hot_cpu.truncated || input.hot_named.is_some_and(|p| p.truncated);
    let mut sections = AnalysisSections {
        cpu_utilization: SectionStatus::new(
            cpu.len(),
            input.cpu.items.len(),
            input.cpu.truncated,
            input.cpu.capability_available,
        ),
        top_processes: SectionStatus::new(
            processes.items.len(),
            processes.matched_count,
            input.processes.truncated,
            input.processes.capability_available,
        ),
        top_threads: SectionStatus::new(
            threads.items.len(),
            threads.matched_count,
            input.threads.truncated,
            input.threads.capability_available,
        ),
        thread_state_distribution: SectionStatus::new(
            states.len(),
            input.states.items.len(),
            input.states.truncated,
            input.states.capability_available,
        ),
        scheduling_latency: SectionStatus::new(
            scheduling.top_samples.len(),
            scheduling.count,
            input.scheduling_cpu.truncated || input.scheduling_states.truncated,
            scheduling.supported,
        ),
        hot_intervals: SectionStatus::new(
            hot_items.len(),
            hot_matched,
            hot_sampled,
            named_ready
                && (input.hot_cpu.capability_available
                    || input.hot_named.is_some_and(|p| p.capability_available)),
        ),
    };
    // CPU/state matchedCount counts source events rather than reduced rows.
    // Fewer aggregate rows do not imply output truncation.
    sections.cpu_utilization.truncated = input.cpu.truncated;
    sections.thread_state_distribution.truncated = input.states.truncated;
    sections.scheduling_latency.truncated = scheduling.truncated;
    if !named_ready {
        sections.hot_intervals.matched_count = None;
    }
    check()?;
    let mut result = AnalysisResult {
        kind: "boundedPureAnalysis".into(),
        parameters: request.clone(),
        range: request.range,
        cpu_utilization: cpu,
        top_processes: processes.items,
        top_threads: threads.items,
        thread_state_distribution: states,
        scheduling_latency: scheduling,
        hot_intervals: hot_items,
        hot_intervals_unsupported_reason: if named_ready {
            None
        } else {
            Some("namedSliceInputMissing".into())
        },
        sections,
        data_quality,
    };
    result.retain_rows(request.maximum_output_rows);
    Ok(result)
}

/// Fallible stable merge sort checks the caller between bounded comparison
/// batches. Unlike sort_by with a latched error, cancellation stops the work.
/// Sorting indices avoids cloning DTO strings on every merge pass.
pub(crate) fn checked_sort<T>(
    values: &mut Vec<T>,
    mut compare: impl FnMut(&T, &T) -> std::cmp::Ordering,
    check: &mut Check<'_>,
) -> Result<(), AnalysisError> {
    check()?;
    let count = values.len();
    let mut source: Vec<_> = (0..count).collect();
    let mut target = vec![0; count];
    let mut width = 1;
    let mut operations = 0;
    while width < count {
        for lower in (0..count).step_by(width * 2) {
            let middle = (lower + width).min(count);
            let upper = (middle + width).min(count);
            let (mut left, mut right) = (lower, middle);
            for output in &mut target[lower..upper] {
                checkpoint(operations, check)?;
                operations += 1;
                if right >= upper
                    || (left < middle
                        && compare(&values[source[left]], &values[source[right]])
                            != std::cmp::Ordering::Greater)
                {
                    *output = source[left];
                    left += 1;
                } else {
                    *output = source[right];
                    right += 1;
                }
            }
        }
        std::mem::swap(&mut source, &mut target);
        width *= 2;
    }
    check()?;
    let mut original: Vec<_> = std::mem::take(values).into_iter().map(Some).collect();
    *values = source
        .into_iter()
        .map(|index| original[index].take().expect("unique sort index"))
        .collect();
    Ok(())
}
