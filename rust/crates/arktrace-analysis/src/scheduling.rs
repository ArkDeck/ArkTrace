use crate::{
    AnalysisError, Check, Percentiles, RunnableSemantics, SchedulingResult, SchedulingSample,
    SchedulingUnsupportedReason, checked_sort, checkpoint, event_order, validate_limit,
    validate_page,
};
use arktrace_contract::{CpuSlice, EventPage, ThreadStateInterval, TraceThreadState};
use std::collections::BTreeMap;

/// Exact same-thread Runnable-end / Running-start boundary is the proof.
/// A nearest later slice, a reused TID or an unknown raw state is insufficient.
/// Open-ended Runnable ranges have no observed end and cannot prove a boundary.
pub fn scheduling_latency(
    cpu: &EventPage<CpuSlice>,
    states: &EventPage<ThreadStateInterval>,
    semantics: RunnableSemantics,
    sample_limit: usize,
    check: &mut Check<'_>,
) -> Result<SchedulingResult, AnalysisError> {
    check()?;
    validate_limit(sample_limit)?;
    validate_page(cpu, 100_000)?;
    validate_page(states, 100_000)?;
    let unsupported = |reason, truncated| SchedulingResult {
        supported: false,
        unsupported_reason: Some(reason),
        count: 0,
        percentiles: None,
        top_samples: Vec::new(),
        truncated,
    };
    if !cpu.capability_available || !states.capability_available {
        return Ok(unsupported(
            SchedulingUnsupportedReason::CapabilityUnavailable,
            false,
        ));
    }
    let sampled = cpu.truncated || states.truncated;
    if semantics == RunnableSemantics::Unproven {
        return Ok(unsupported(
            SchedulingUnsupportedReason::RunnableSemanticsUnproven,
            sampled,
        ));
    }
    let mut running = BTreeMap::<(i64, i64), &CpuSlice>::new();
    for (i, slice) in cpu.items.iter().enumerate() {
        checkpoint(i, check)?;
        let Some(thread) = slice.thread_key else {
            continue;
        };
        let value = running
            .entry((thread.itid, slice.range.start_ns()))
            .or_insert(slice);
        if event_order(slice.key) < event_order(value.key) {
            *value = slice;
        }
    }
    let mut samples = Vec::new();
    for (i, state) in states.items.iter().enumerate() {
        checkpoint(i, check)?;
        if state.normalized_state != Some(TraceThreadState::Runnable) || state.is_open_ended {
            continue;
        }
        let Some(next) = running.get(&(state.thread_key.itid, state.range.end_ns())) else {
            continue;
        };
        samples.push(SchedulingSample {
            thread_key: state.thread_key,
            runnable_event_key: state.key,
            running_event_key: next.key,
            runnable_end_ns: state.range.end_ns(),
            running_start_ns: next.range.start_ns(),
            latency_ns: state.range.duration_ns(),
        });
    }
    if samples.is_empty() {
        return Ok(unsupported(
            SchedulingUnsupportedReason::NoProvableRunnableTransitions,
            sampled,
        ));
    }
    let mut durations: Vec<_> = samples.iter().map(|s| s.latency_ns).collect();
    checked_sort(&mut durations, i64::cmp, check)?;
    check()?;
    // nearest rank ceil(n * percentile / 100) - 1; n <= 100,000.
    let percentile = |p: usize| durations[(p * durations.len()).div_ceil(100).max(1) - 1];
    let percentiles = Percentiles {
        p50_ns: percentile(50),
        p90_ns: percentile(90),
        p95_ns: percentile(95),
        p99_ns: percentile(99),
        max_ns: durations[durations.len() - 1],
    };
    checked_sort(
        &mut samples,
        |a, b| {
            (
                std::cmp::Reverse(a.latency_ns),
                a.thread_key.itid,
                event_order(a.runnable_event_key),
            )
                .cmp(&(
                    std::cmp::Reverse(b.latency_ns),
                    b.thread_key.itid,
                    event_order(b.runnable_event_key),
                ))
        },
        check,
    )?;
    check()?;
    let count = samples.len();
    samples.truncate(sample_limit);
    Ok(SchedulingResult {
        supported: true,
        unsupported_reason: None,
        count,
        percentiles: Some(percentiles),
        truncated: sampled || count > samples.len(),
        top_samples: samples,
    })
}
