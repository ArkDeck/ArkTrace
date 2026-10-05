//! Bounded adapters from actual repository DTOs to renderer inputs.
//! No SQL, clocks, event-key synthesis or changes to stored event ranges.
use crate::{
    Check, DetailInput, DetailStyle, MAXIMUM_PRIMITIVES, ViewerError, checkpoint, machine,
};
use arktrace_contract::*;

#[derive(Clone, Debug)]
pub enum RepositoryDetailPage {
    Cpu(EventPage<CpuSlice>),
    ThreadState(EventPage<ThreadStateInterval>),
    NamedSlice(EventPage<TraceSlice>),
    Counter(EventPage<CounterSeries>),
    Frame(EventPage<TraceFrame>),
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RepositoryDetailQuery {
    Cpu(CpuSliceQuery),
    ThreadState(ThreadStateQuery),
    NamedSlice(TraceSliceQuery),
    Counter(CounterQuery),
    Frame(TraceFrameQuery),
}
/// Constructs only typed repository filters, including the pre-limit scope
/// for unattributed slices. No frontend supplies SQL or interpretation rules.
pub fn detail_query(
    source: &TraceDensitySource,
    range: TraceTimeRange,
    limit: usize,
) -> Result<RepositoryDetailQuery, ViewerError> {
    if range.is_instant() || !(1..=MAXIMUM_PRIMITIVES).contains(&limit) {
        return Err(ViewerError::InvalidRequest);
    }
    Ok(match source {
        TraceDensitySource::Cpu { cpu } => RepositoryDetailQuery::Cpu(CpuSliceQuery {
            range,
            cpu: Some(*cpu),
            process_key: None,
            pid: None,
            thread_key: None,
            tid: None,
            limit,
        }),
        TraceDensitySource::ThreadState { thread } => {
            RepositoryDetailQuery::ThreadState(ThreadStateQuery {
                range,
                cpu: None,
                process_key: None,
                pid: None,
                thread_key: Some(thread.itid),
                tid: None,
                raw_state: None,
                state: None,
                limit,
            })
        }
        TraceDensitySource::NamedSlice { thread } => {
            RepositoryDetailQuery::NamedSlice(TraceSliceQuery {
                range,
                event_key: None,
                process_key: None,
                pid: None,
                thread_key: thread.map(|t| t.itid),
                tid: None,
                unattributed_only: thread.is_none(),
                name: None,
                name_match: DirectoryNameMatch::Exact,
                minimum_duration_ns: None,
                depth: None,
                includes_argument_set: false,
                limit,
            })
        }
        TraceDensitySource::Frame { process_key } => {
            RepositoryDetailQuery::Frame(TraceFrameQuery {
                range,
                process_key: process_key.map(|p| p.ipid),
                limit,
            })
        }
        TraceDensitySource::CpuCounter { filter_id, cpu } => {
            RepositoryDetailQuery::Counter(CounterQuery {
                range,
                scope: Some(CounterScope::Cpu),
                filter_id: Some(*filter_id),
                cpu: *cpu,
                process_key: None,
                pid: None,
                name: None,
                name_match: DirectoryNameMatch::Exact,
                limit,
            })
        }
        TraceDensitySource::ProcessCounter {
            filter_id,
            process_key,
        } => RepositoryDetailQuery::Counter(CounterQuery {
            range,
            scope: Some(CounterScope::Process),
            filter_id: Some(*filter_id),
            cpu: None,
            process_key: process_key.map(|p| p.ipid),
            pid: None,
            name: None,
            name_match: DirectoryNameMatch::Exact,
            limit,
        }),
    })
}

/// Preserve source quality and truncation for the later complete snapshot.
/// Counter DTOs count samples, rather than series, against the input cap.
pub fn map_detail_page(
    source: &TraceDensitySource,
    query_range: TraceTimeRange,
    limit: usize,
    page: RepositoryDetailPage,
    check: &mut Check<'_>,
) -> Result<EventPage<DetailInput>, ViewerError> {
    check()?;
    if query_range.is_instant() || !(1..=MAXIMUM_PRIMITIVES).contains(&limit) {
        return Err(ViewerError::InvalidRequest);
    }
    macro_rules! map {
        ($page:expr, $mapper:expr) => {{
            let page = $page;
            validate_page(&page, page.items.len(), limit)?;
            let mut items = Vec::with_capacity(page.items.len());
            for (index, item) in page.items.into_iter().enumerate() {
                checkpoint(index, check)?;
                items.push(($mapper)(item)?);
            }
            EventPage {
                items,
                truncated: page.truncated,
                capability_available: page.capability_available,
                data_quality: page.data_quality,
            }
        }};
    }
    let facts = crate::render_facts::project_render_page(&page, query_range, check)?;
    let mut output = match (source, page) {
        (TraceDensitySource::Cpu { cpu }, RepositoryDetailPage::Cpu(page)) => {
            map!(page, |event: CpuSlice| {
                if event.cpu != *cpu {
                    return Err(ViewerError::InvalidEvidence);
                }
                input(
                    event.key,
                    EventTable::SchedSlice,
                    event.range,
                    0,
                    DetailStyle::Running,
                    event.is_open_ended,
                )
            })
        }
        (TraceDensitySource::ThreadState { thread }, RepositoryDetailPage::ThreadState(page)) => {
            map!(page, |event: ThreadStateInterval| {
                if event.thread_key != *thread {
                    return Err(ViewerError::InvalidEvidence);
                }
                let style = match event.normalized_state {
                    Some(TraceThreadState::Running) => DetailStyle::Running,
                    Some(TraceThreadState::Runnable) => DetailStyle::Runnable,
                    Some(TraceThreadState::Blocked) => DetailStyle::Blocked,
                    Some(TraceThreadState::Sleeping) => DetailStyle::Sleeping,
                    _ => DetailStyle::Accent,
                };
                input(
                    event.key,
                    EventTable::ThreadState,
                    event.range,
                    0,
                    style,
                    event.is_open_ended,
                )
            })
        }
        (TraceDensitySource::NamedSlice { thread }, RepositoryDetailPage::NamedSlice(page)) => {
            map!(page, |event: TraceSlice| {
                if event.thread_key != *thread {
                    return Err(ViewerError::InvalidEvidence);
                }
                input(
                    event.key,
                    EventTable::Callstack,
                    event.range,
                    event.depth.unwrap_or(0).max(0),
                    DetailStyle::from_category(event.category.as_deref()),
                    event.is_open_ended,
                )
            })
        }
        (TraceDensitySource::Frame { process_key }, RepositoryDetailPage::Frame(page)) => {
            map!(page, |event: TraceFrame| {
                if process_key.is_some() && event.process_key != *process_key {
                    return Err(ViewerError::InvalidEvidence);
                }
                input(
                    event.key,
                    EventTable::FrameSlice,
                    event.range,
                    if event.kind == TraceFrameKind::Expected {
                        0
                    } else {
                        1
                    },
                    DetailStyle::Accent,
                    event.is_open_ended,
                )
            })
        }
        (
            TraceDensitySource::CpuCounter { filter_id, .. }
            | TraceDensitySource::ProcessCounter { filter_id, .. },
            RepositoryDetailPage::Counter(page),
        ) => {
            if page.items.len() > limit {
                return Err(ViewerError::InputBudgetExceeded);
            }
            let count = page
                .items
                .iter()
                .try_fold(0_usize, |count, series| {
                    count.checked_add(series.samples.len())
                })
                .ok_or(ViewerError::InputBudgetExceeded)?;
            validate_page(&page, count, limit)?;
            let mut items = Vec::with_capacity(count);
            for (index, series) in page.items.into_iter().enumerate() {
                checkpoint(index, check)?;
                let expected = match source {
                    TraceDensitySource::CpuCounter { .. } => {
                        (CounterScope::Cpu, EventTable::Measure)
                    }
                    _ => (CounterScope::Process, EventTable::ProcessMeasure),
                };
                if series.filter_id != *filter_id || series.scope != expected.0 {
                    return Err(ViewerError::InvalidEvidence);
                }
                match source {
                    TraceDensitySource::CpuCounter { cpu: Some(cpu), .. }
                        if series.cpu != Some(*cpu) =>
                    {
                        return Err(ViewerError::InvalidEvidence);
                    }
                    TraceDensitySource::ProcessCounter {
                        process_key: Some(process),
                        ..
                    } if series.process_key != Some(*process) => {
                        return Err(ViewerError::InvalidEvidence);
                    }
                    _ => {}
                }
                for sample in series.samples {
                    checkpoint(items.len(), check)?;
                    let end = match sample.duration_ns {
                        Some(duration) if duration >= 0 => sample
                            .timestamp_ns
                            .checked_add(duration)
                            .ok_or(ViewerError::ArithmeticOverflow)?,
                        Some(_) => return Err(ViewerError::InvalidEvidence),
                        None => query_range.end_ns().max(sample.timestamp_ns),
                    };
                    let range = TraceTimeRange::event(sample.timestamp_ns, end)
                        .map_err(|_| ViewerError::InvalidEvidence)?;
                    if sample.key.table != expected.1
                        && !(series.scope == CounterScope::Process
                            && sample.key.table == EventTable::Measure)
                    {
                        return Err(ViewerError::InvalidEvidence);
                    }
                    items.push(input(
                        sample.key,
                        sample.key.table,
                        range,
                        0,
                        DetailStyle::Counter,
                        sample.duration_ns.is_none(),
                    )?);
                }
            }
            EventPage {
                items,
                truncated: page.truncated,
                capability_available: page.capability_available,
                data_quality: page.data_quality,
            }
        }
        _ => return Err(ViewerError::InvalidEvidence),
    };
    if output.items.len() != facts.len() {
        return Err(ViewerError::InvalidEvidence);
    }
    for (detail, fact) in output.items.iter_mut().zip(facts) {
        check()?;
        if detail.event_key != fact.inspector().key() || detail.range != fact.inspector().range() {
            return Err(ViewerError::InvalidEvidence);
        }
        detail.render_facts = Some(fact);
    }
    check()?;
    Ok(output)
}
fn validate_page<T>(page: &EventPage<T>, count: usize, limit: usize) -> Result<(), ViewerError> {
    if count > limit {
        return Err(ViewerError::InputBudgetExceeded);
    }
    if !page.capability_available && (count != 0 || page.truncated) {
        return Err(ViewerError::InvalidEvidence);
    }
    machine(&page.data_quality)?;
    Ok(())
}
fn input(
    key: EventKey,
    table: EventTable,
    range: TraceTimeRange,
    depth: i64,
    style: DetailStyle,
    is_open_ended: bool,
) -> Result<DetailInput, ViewerError> {
    if key.table != table {
        return Err(ViewerError::InvalidEvidence);
    }
    Ok(DetailInput {
        event_key: key,
        range,
        depth,
        style,
        is_open_ended,
        render_facts: None,
    })
}
