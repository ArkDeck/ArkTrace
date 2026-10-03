use crate::{
    AnalysisError, Check, HotInterval, HotIntervalScore, NamedDurationEvidence, checked_sort,
    checkpoint, sat_add, sat_mul, validate_items, validate_range,
};
use arktrace_contract::{CpuSlice, TraceTimeRange};

pub const CONTEXT_SWITCH_WEIGHT_NS: i64 = 1_000_000;
#[derive(Clone, Default)]
struct Bucket {
    busy: i64,
    cpu_count: usize,
    switches: usize,
    named: i64,
    named_count: usize,
}

/// Same quotient/remainder buckets and score as Swift. Boundary buckets use
/// clipped overlap; a difference array handles interior full coverage in
/// O(events log buckets + buckets), avoiding an events × buckets scan.
pub fn hot_intervals(
    cpu: &[CpuSlice],
    named: &[NamedDurationEvidence],
    range: TraceTimeRange,
    bucket_count: usize,
    minimum_long_slice_duration_ns: i64,
    check: &mut Check<'_>,
) -> Result<Vec<HotInterval>, AnalysisError> {
    check()?;
    validate_range(range)?;
    validate_items(cpu.len())?;
    validate_items(named.len())?;
    if !(1..=10_000).contains(&bucket_count) || minimum_long_slice_duration_ns < 0 {
        return Err(AnalysisError::InvalidBounds);
    }
    let actual = bucket_count.min(range.duration_ns() as usize);
    let quotient = range.duration_ns() / actual as i64;
    let remainder = range.duration_ns() % actual as i64;
    let mut start = range.start_ns();
    let mut buckets = Vec::with_capacity(actual);
    for i in 0..actual {
        checkpoint(i, check)?;
        let width = quotient + i64::from((i as i64) < remainder);
        let end = start
            .checked_add(width)
            .ok_or(AnalysisError::InvalidEvidence)?;
        buckets.push(TraceTimeRange::query(start, end)?);
        start = end;
    }
    let mut values = vec![Bucket::default(); actual];
    let mut cpu_coverage = vec![0_i64; actual + 1];
    let mut named_coverage = vec![0_i64; actual + 1];
    for (i, slice) in cpu.iter().enumerate() {
        checkpoint(i, check)?;
        add(slice.range, &buckets, &mut values, &mut cpu_coverage, false);
        if let Some(index) = bucket_index(slice.range.start_ns(), &buckets) {
            values[index].switches += 1;
        }
    }
    for (i, slice) in named.iter().enumerate() {
        checkpoint(i, check)?;
        if slice.range.duration_ns() >= minimum_long_slice_duration_ns {
            add(
                slice.range,
                &buckets,
                &mut values,
                &mut named_coverage,
                true,
            );
        }
    }
    let mut active_cpu = 0_i64;
    let mut active_named = 0_i64;
    let mut output = Vec::new();
    for (i, (range, mut value)) in buckets.into_iter().zip(values).enumerate() {
        checkpoint(i, check)?;
        active_cpu += cpu_coverage[i];
        active_named += named_coverage[i];
        value.busy = sat_add(value.busy, sat_mul(range.duration_ns(), active_cpu));
        value.named = sat_add(value.named, sat_mul(range.duration_ns(), active_named));
        value.cpu_count += active_cpu as usize;
        value.named_count += active_named as usize;
        if value.cpu_count == 0 && value.named_count == 0 {
            continue;
        }
        let switch_score = sat_mul(value.switches as i64, CONTEXT_SWITCH_WEIGHT_NS);
        output.push(HotInterval {
            range,
            score: HotIntervalScore {
                cpu_busy_ns: value.busy,
                context_switch_count: value.switches,
                context_switch_score_ns: switch_score,
                long_slice_ns: value.named,
                total: sat_add(sat_add(value.busy, switch_score), value.named),
            },
            cpu_slice_count: value.cpu_count,
            named_slice_count: value.named_count,
        });
    }
    checked_sort(
        &mut output,
        |a, b| {
            (std::cmp::Reverse(a.score.total), a.range.start_ns())
                .cmp(&(std::cmp::Reverse(b.score.total), b.range.start_ns()))
        },
        check,
    )?;
    check()?;
    Ok(output)
}
fn bucket_index(timestamp: i64, buckets: &[TraceTimeRange]) -> Option<usize> {
    if timestamp < buckets[0].start_ns() || timestamp >= buckets[buckets.len() - 1].end_ns() {
        return None;
    }
    Some(buckets.partition_point(|bucket| bucket.end_ns() <= timestamp))
}
fn add(
    event: TraceTimeRange,
    buckets: &[TraceTimeRange],
    values: &mut [Bucket],
    coverage: &mut [i64],
    named: bool,
) {
    let span = if event.is_instant() {
        bucket_index(event.start_ns(), buckets).map(|i| (i, i))
    } else {
        let start = event.start_ns().max(buckets[0].start_ns());
        let end = event.end_ns().min(buckets[buckets.len() - 1].end_ns());
        if start < end {
            bucket_index(start, buckets).zip(bucket_index(end - 1, buckets))
        } else {
            None
        }
    };
    let Some((first, last)) = span else { return };
    let mut boundary = |i: usize| {
        let overlap = event.clipped_overlap_ns(buckets[i]);
        if named {
            values[i].named = sat_add(values[i].named, overlap);
            values[i].named_count += 1;
        } else {
            values[i].busy = sat_add(values[i].busy, overlap);
            values[i].cpu_count += 1;
        }
    };
    boundary(first);
    if last != first {
        boundary(last);
    }
    if first + 1 < last {
        coverage[first + 1] += 1;
        coverage[last] -= 1;
    }
}
