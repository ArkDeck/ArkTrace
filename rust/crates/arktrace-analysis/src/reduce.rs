use crate::{
    AnalysisError, Check, CpuUtilization, Ranked, RunningProcess, RunningThread, StateDistribution,
    checked_sort, checkpoint, sat_add, validate_items, validate_limit, validate_range,
};
use arktrace_contract::{
    CpuSlice, ProcessKey, ThreadKey, ThreadStateInterval, TraceThreadState, TraceTimeRange,
};
use std::collections::BTreeMap;
use unicode_normalization::UnicodeNormalization;

pub fn cpu_utilization(
    slices: &[CpuSlice],
    range: TraceTimeRange,
    check: &mut Check<'_>,
) -> Result<Vec<CpuUtilization>, AnalysisError> {
    check()?;
    validate_range(range)?;
    validate_items(slices.len())?;
    let mut values = BTreeMap::<i64, (i64, usize)>::new();
    for (i, slice) in slices.iter().enumerate() {
        checkpoint(i, check)?;
        let value = values.entry(slice.cpu).or_default();
        value.0 = sat_add(value.0, slice.range.clipped_overlap_ns(range));
        value.1 += 1;
    }
    check()?;
    Ok(values
        .into_iter()
        .map(|(cpu, (raw, count))| {
            let occupied = raw.min(range.duration_ns());
            CpuUtilization {
                cpu,
                raw_running_ns: raw,
                occupied_ns: occupied,
                slice_count: count,
                utilization: occupied as f64 / range.duration_ns() as f64,
            }
        })
        .collect())
}
pub fn top_processes(
    slices: &[CpuSlice],
    range: TraceTimeRange,
    limit: usize,
    check: &mut Check<'_>,
) -> Result<Ranked<RunningProcess>, AnalysisError> {
    check()?;
    validate_range(range)?;
    validate_items(slices.len())?;
    validate_limit(limit)?;
    let mut values = BTreeMap::<i64, RunningProcess>::new();
    for (i, slice) in slices.iter().enumerate() {
        checkpoint(i, check)?;
        let Some(key) = slice.process_key else {
            continue;
        };
        let value = values.entry(key.ipid).or_insert(RunningProcess {
            process_key: key,
            pid: None,
            name: None,
            running_ns: 0,
            share_of_one_cpu: 0.0,
            slice_count: 0,
        });
        value.pid = value.pid.or(slice.pid);
        if value.name.is_none() {
            value.name.clone_from(&slice.process_name);
        }
        value.running_ns = sat_add(value.running_ns, slice.range.clipped_overlap_ns(range));
        value.slice_count += 1;
    }
    let mut rows: Vec<_> = values.into_values().collect();
    for (i, value) in rows.iter_mut().enumerate() {
        checkpoint(i, check)?;
        value.share_of_one_cpu = value.running_ns as f64 / range.duration_ns() as f64;
    }
    checked_sort(
        &mut rows,
        |a, b| {
            (std::cmp::Reverse(a.running_ns), a.process_key.ipid)
                .cmp(&(std::cmp::Reverse(b.running_ns), b.process_key.ipid))
        },
        check,
    )?;
    check()?;
    let matched_count = rows.len();
    rows.truncate(limit);
    Ok(Ranked {
        items: rows,
        matched_count,
    })
}
pub fn top_threads(
    slices: &[CpuSlice],
    range: TraceTimeRange,
    limit: usize,
    check: &mut Check<'_>,
) -> Result<Ranked<RunningThread>, AnalysisError> {
    check()?;
    validate_range(range)?;
    validate_items(slices.len())?;
    validate_limit(limit)?;
    let mut values = BTreeMap::<i64, RunningThread>::new();
    for (i, slice) in slices.iter().enumerate() {
        checkpoint(i, check)?;
        let Some(key) = slice.thread_key else {
            continue;
        };
        let value = values.entry(key.itid).or_insert(RunningThread {
            thread_key: key,
            process_key: None,
            tid: None,
            pid: None,
            name: None,
            process_name: None,
            running_ns: 0,
            share_of_one_cpu: 0.0,
            slice_count: 0,
        });
        value.process_key = value.process_key.or(slice.process_key);
        value.tid = value.tid.or(slice.tid);
        value.pid = value.pid.or(slice.pid);
        if value.name.is_none() {
            value.name.clone_from(&slice.thread_name);
        }
        if value.process_name.is_none() {
            value.process_name.clone_from(&slice.process_name);
        }
        value.running_ns = sat_add(value.running_ns, slice.range.clipped_overlap_ns(range));
        value.slice_count += 1;
    }
    let mut rows: Vec<_> = values.into_values().collect();
    for (i, value) in rows.iter_mut().enumerate() {
        checkpoint(i, check)?;
        value.share_of_one_cpu = value.running_ns as f64 / range.duration_ns() as f64;
    }
    checked_sort(
        &mut rows,
        |a, b| {
            (std::cmp::Reverse(a.running_ns), a.thread_key.itid)
                .cmp(&(std::cmp::Reverse(b.running_ns), b.thread_key.itid))
        },
        check,
    )?;
    check()?;
    let matched_count = rows.len();
    rows.truncate(limit);
    Ok(Ranked {
        items: rows,
        matched_count,
    })
}
fn state_name(state: TraceThreadState) -> &'static str {
    match state {
        TraceThreadState::Running => "running",
        TraceThreadState::Runnable => "runnable",
        TraceThreadState::Sleeping => "sleeping",
        TraceThreadState::Blocked => "blocked",
        TraceThreadState::Stopped => "stopped",
    }
}
#[derive(Eq, Ord, PartialEq, PartialOrd)]
struct StateKey(
    i64,
    Option<i64>,
    Option<i64>,
    Option<i64>,
    String,
    Option<&'static str>,
);
pub fn state_distribution(
    intervals: &[ThreadStateInterval],
    range: TraceTimeRange,
    check: &mut Check<'_>,
) -> Result<Vec<StateDistribution>, AnalysisError> {
    check()?;
    validate_range(range)?;
    validate_items(intervals.len())?;
    let mut values = BTreeMap::<StateKey, StateDistribution>::new();
    for (i, interval) in intervals.iter().enumerate() {
        checkpoint(i, check)?;
        if interval.state.len() > 256 {
            return Err(AnalysisError::InvalidEvidence);
        }
        let key = StateKey(
            interval.thread_key.itid,
            interval.process_key.map(|p| p.ipid),
            interval.tid,
            interval.pid,
            // Swift String equality is canonical-equivalent. Normalize only
            // the grouping key; report the first source label byte for byte.
            interval.state.nfc().collect(),
            interval.normalized_state.map(state_name),
        );
        let value = values.entry(key).or_insert_with(|| StateDistribution {
            thread_key: ThreadKey {
                itid: interval.thread_key.itid,
            },
            process_key: interval.process_key.map(|p| ProcessKey { ipid: p.ipid }),
            tid: interval.tid,
            pid: interval.pid,
            raw_state: interval.state.clone(),
            normalized_state: interval.normalized_state,
            duration_ns: 0,
            percentage_of_range: 0.0,
            interval_count: 0,
        });
        value.duration_ns = sat_add(value.duration_ns, interval.range.clipped_overlap_ns(range));
        value.interval_count += 1;
    }
    check()?;
    let mut rows: Vec<_> = values
        .into_values()
        .map(|mut value| {
            value.percentage_of_range = value.duration_ns as f64 / range.duration_ns() as f64;
            value
        })
        .collect();
    // Swift orders reported raw UTF-8 labels, not their normalized keys.
    checked_sort(
        &mut rows,
        |a, b| {
            (
                a.thread_key.itid,
                a.process_key.map(|p| p.ipid),
                a.tid,
                a.pid,
                a.raw_state.as_bytes(),
                a.normalized_state.map(state_name),
            )
                .cmp(&(
                    b.thread_key.itid,
                    b.process_key.map(|p| p.ipid),
                    b.tid,
                    b.pid,
                    b.raw_state.as_bytes(),
                    b.normalized_state.map(state_name),
                ))
        },
        check,
    )?;
    Ok(rows)
}
