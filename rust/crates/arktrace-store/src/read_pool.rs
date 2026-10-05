use crate::{
    ReadPoolLimits, StoreError, StoreReader, ValidationBudget, query_resources::QueryResources,
    reader::VerifiedReadSnapshot,
};
use arktrace_contract::*;
use arktrace_platform::ContinuousDeadline;
use serde::Serialize;
use std::{
    panic::{AssertUnwindSafe, catch_unwind},
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
};

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReadPoolStatistics {
    pub workers_opened: usize,
    pub peak_active_queries: usize,
    pub completed_queries: usize,
    pub connections_closed: usize,
    /// Conservative allocation credit, not measured heap/RSS.
    pub allocation_credit_bytes: u64,
}
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReadPoolOutput {
    pub result: TraceRepositoryEventBatchResult,
    pub statistics: ReadPoolStatistics,
}

enum Query<'a> {
    Cpu(&'a CpuSliceQuery),
    State(&'a ThreadStateQuery),
    Slice(&'a TraceSliceQuery),
    Counter(&'a CounterQuery),
    Series(&'a CounterSeriesQuery),
    Density(&'a TraceDensityQuery),
    Thread(&'a ThreadQuery),
}
enum Item {
    Cpu(EventPage<CpuSlice>),
    State(EventPage<ThreadStateInterval>),
    Slice(EventPage<TraceSlice>),
    Counter(EventPage<CounterSeries>),
    Series(EventPage<CounterSeriesDescriptor>),
    Density(TraceDensityResult),
    Thread(DirectoryPage<TraceThread>),
}
impl Query<'_> {
    fn execute(&self, reader: &StoreReader, budget: &ValidationBudget) -> Result<Item, StoreError> {
        match self {
            Self::Cpu(q) => reader.cpu_slices(q, budget).map(Item::Cpu),
            Self::State(q) => reader.thread_states(q, budget).map(Item::State),
            Self::Slice(q) => reader.slices(q, budget).map(Item::Slice),
            Self::Counter(q) => reader.counters(q, budget).map(Item::Counter),
            Self::Series(q) => reader.counter_series(q, budget).map(Item::Series),
            Self::Density(q) => reader.density(q, budget).map(Item::Density),
            Self::Thread(q) => reader.threads(q, budget).map(Item::Thread),
        }
    }
}
struct Counters {
    opened: AtomicUsize,
    closed: AtomicUsize,
    active: AtomicUsize,
    peak: AtomicUsize,
    completed: AtomicUsize,
}
struct Active<'a>(&'a Counters);
impl<'a> Active<'a> {
    fn enter(counters: &'a Counters) -> Self {
        let active = counters.active.fetch_add(1, Ordering::Relaxed) + 1;
        counters.peak.fetch_max(active, Ordering::Relaxed);
        Self(counters)
    }
}
impl Drop for Active<'_> {
    fn drop(&mut self) {
        self.0.active.fetch_sub(1, Ordering::Relaxed);
    }
}

pub(crate) fn run(
    snapshot: VerifiedReadSnapshot<'_>,
    batch: &TraceRepositoryEventBatch,
    budget: &ValidationBudget,
    limits: ReadPoolLimits,
) -> Result<ReadPoolOutput, StoreError> {
    run_inner(snapshot, batch, budget, limits, &|_| {})
}

// Observer is private and used by fault tests; product query requests never
// supply executable code, raw SQL, paths or worker policy in their JSON.
pub(crate) fn run_inner(
    snapshot: VerifiedReadSnapshot<'_>,
    batch: &TraceRepositoryEventBatch,
    budget: &ValidationBudget,
    limits: ReadPoolLimits,
    observer: &(impl Fn(usize) + Sync),
) -> Result<ReadPoolOutput, StoreError> {
    run_inner_with_deadlines(snapshot, batch, None, budget, limits, observer)
}
pub(crate) fn run_with_deadlines(
    snapshot: VerifiedReadSnapshot<'_>,
    batch: &TraceRepositoryEventBatch,
    deadlines: &[Option<ContinuousDeadline>],
    budget: &ValidationBudget,
    limits: ReadPoolLimits,
) -> Result<ReadPoolOutput, StoreError> {
    run_inner_with_deadlines(snapshot, batch, Some(deadlines), budget, limits, &|_| {})
}
pub(crate) fn run_inner_with_deadlines(
    snapshot: VerifiedReadSnapshot<'_>,
    batch: &TraceRepositoryEventBatch,
    deadlines: Option<&[Option<ContinuousDeadline>]>,
    budget: &ValidationBudget,
    limits: ReadPoolLimits,
    observer: &(impl Fn(usize) + Sync),
) -> Result<ReadPoolOutput, StoreError> {
    batch.validate().map_err(|_| StoreError::InvalidQuery)?;
    if let Some(deadlines) = deadlines
        && (deadlines.len() != batch.query_count()
            || deadlines
                .iter()
                .flatten()
                .any(|deadline| !deadline.is_valid()))
    {
        return Err(StoreError::InvalidBudget);
    }
    limits.validate()?;
    budget.check()?;
    let resources = Arc::new(QueryResources::new(limits)?);
    let mut queries = Vec::with_capacity(batch.query_count());
    queries.extend(batch.cpu_slices.iter().map(Query::Cpu));
    queries.extend(batch.thread_states.iter().map(Query::State));
    queries.extend(batch.slices.iter().map(Query::Slice));
    queries.extend(batch.counters.iter().map(Query::Counter));
    queries.extend(batch.counter_series.iter().map(Query::Series));
    queries.extend(batch.densities.iter().map(Query::Density));
    queries.extend(batch.threads.iter().map(Query::Thread));
    let next = AtomicUsize::new(0);
    let output = Mutex::new(
        (0..queries.len())
            .map(|_| None)
            .collect::<Vec<Option<Item>>>(),
    );
    let counters = Counters {
        opened: AtomicUsize::new(0),
        closed: AtomicUsize::new(0),
        active: AtomicUsize::new(0),
        peak: AtomicUsize::new(0),
        completed: AtomicUsize::new(0),
    };
    let errors = std::thread::scope(|scope| {
        let mut handles = Vec::with_capacity(limits.maximum_workers);
        let mut errors = Vec::new();
        for worker in 0..limits.maximum_workers.min(queries.len()) {
            let snapshot = snapshot.clone();
            let resources = resources.clone();
            let queries = &queries;
            let output = &output;
            let counters = &counters;
            let next = &next;
            let shared_resources = resources.clone();
            match std::thread::Builder::new()
                .name(format!("arktrace-read-{worker}"))
                .spawn_scoped(scope, move || {
                    let mut reader = None;
                    let work = catch_unwind(AssertUnwindSafe(|| {
                        resources.reserve(1024 * 1024)?;
                        reader = Some(snapshot.open_worker(budget, resources.clone())?);
                        counters.opened.fetch_add(1, Ordering::Relaxed);
                        let reader = reader.as_ref().ok_or(StoreError::WorkerFailed)?;
                        loop {
                            budget.check()?;
                            resources.check()?;
                            let index = next.fetch_add(1, Ordering::Relaxed);
                            let Some(query) = queries.get(index) else {
                                break;
                            };
                            // Page quality, temporary grouping and headers have
                            // fixed credit in addition to charged row payloads.
                            resources.reserve(2 * 1024 * 1024)?;
                            let active = Active::enter(counters);
                            observer(index);
                            let deadline = deadlines.and_then(|values| values[index]);
                            let result = reader
                                .with_query_deadline(deadline, || query.execute(reader, budget))?;
                            output.lock().map_err(|_| StoreError::WorkerFailed)?[index] =
                                Some(result);
                            counters.completed.fetch_add(1, Ordering::Relaxed);
                            drop(active);
                        }
                        Ok(())
                    }))
                    .unwrap_or(Err(StoreError::WorkerFailed));
                    if work.is_err() {
                        resources.abort.cancel();
                    }
                    // Even panic/cancellation closes the connection here, on
                    // its owner thread. Cleanup failure has priority.
                    if let Some(reader) = reader {
                        if reader.close().is_err() {
                            resources.abort.cancel();
                            return Err(StoreError::CleanupFailed);
                        }
                        counters.closed.fetch_add(1, Ordering::Relaxed);
                    }
                    work
                }) {
                Ok(handle) => handles.push(handle),
                Err(_) => {
                    shared_resources.abort.cancel();
                    errors.push(StoreError::WorkerFailed);
                    break;
                }
            }
        }
        for handle in handles {
            if let Err(error) = handle.join().unwrap_or(Err(StoreError::WorkerFailed)) {
                errors.push(error);
            }
        }
        errors
    });
    if errors.contains(&StoreError::CleanupFailed) {
        return Err(StoreError::CleanupFailed);
    }
    if errors.contains(&StoreError::WorkerFailed) {
        return Err(StoreError::WorkerFailed);
    }
    budget.check()?;
    if let Some(error) = errors
        .iter()
        .find(|e| **e != StoreError::Cancelled)
        .or(errors.first())
    {
        return Err(*error);
    }
    let mut result = TraceRepositoryEventBatchResult::default();
    for item in output.into_inner().map_err(|_| StoreError::WorkerFailed)? {
        match item.ok_or(StoreError::WorkerFailed)? {
            Item::Cpu(page) => result.cpu_slices.push(page),
            Item::State(page) => result.thread_states.push(page),
            Item::Slice(page) => result.slices.push(page),
            Item::Counter(page) => result.counters.push(page),
            Item::Series(page) => result.counter_series.push(page),
            Item::Density(page) => result.densities.push(page),
            Item::Thread(page) => result.threads.push(DirectoryPage {
                items: page
                    .items
                    .into_iter()
                    .map(TraceRepositoryThread::from)
                    .collect(),
                truncated: page.truncated,
                data_quality_issues: page.data_quality_issues,
            }),
        }
    }
    let statistics = ReadPoolStatistics {
        workers_opened: counters.opened.load(Ordering::Relaxed),
        peak_active_queries: counters.peak.load(Ordering::Relaxed),
        completed_queries: counters.completed.load(Ordering::Relaxed),
        connections_closed: counters.closed.load(Ordering::Relaxed),
        allocation_credit_bytes: resources.used(),
    };
    if statistics.workers_opened != statistics.connections_closed
        || statistics.completed_queries != batch.query_count()
    {
        return Err(StoreError::WorkerFailed);
    }
    Ok(ReadPoolOutput { result, statistics })
}
