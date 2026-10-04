use crate::{
    DatabaseInspection, IndexedDatabaseInspection, StoreError, ValidationBudget,
    arguments::ArgumentSchema, counters::CounterSchema, database::Database,
    directory::DirectorySchema, events::EventSchema, frames::FrameSchema, indexes,
    open_snapshot_connection, slices::SliceSchema, summary::SummarySchema,
};
use arktrace_contract::{
    CounterQuery, CounterSeries, CounterSeriesDescriptor, CounterSeriesQuery, CpuSlice,
    CpuSliceQuery, DirectoryPage, EventPage, ProcessQuery, ThreadQuery, ThreadStateInterval,
    ThreadStateQuery, TraceArgumentQuery, TraceEventArgument, TraceFrame, TraceFrameQuery,
    TraceProcess, TraceSlice, TraceSliceQuery, TraceThread,
};
use arktrace_platform::{ContinuousDeadline, HeldFile};
use std::{cell::Cell, marker::PhantomData, rc::Rc, sync::Arc};

/// One immutable snapshot and one private SQLite connection, owned by the
/// calling worker. A connection cannot move between threads or expose SQL.
pub struct StoreReader {
    connection: rusqlite::Connection,
    snapshot: Arc<HeldFile>,
    inspection: IndexedDatabaseInspection,
    directory: DirectorySchema,
    events: EventSchema,
    slices: SliceSchema,
    counters: CounterSchema,
    frames: FrameSchema,
    arguments: ArgumentSchema,
    summary: SummarySchema,
    _worker: PhantomData<Rc<()>>,
    resources: Option<Arc<crate::query_resources::QueryResources>>,
    query_deadline: Cell<Option<ContinuousDeadline>>,
}
impl StoreReader {
    #[cfg(test)]
    pub(crate) fn snapshot_for_test(&self) -> Arc<HeldFile> {
        self.snapshot.clone()
    }
    pub fn open(snapshot: Arc<HeldFile>, budget: &ValidationBudget) -> Result<Self, StoreError> {
        Self::open_bounded(snapshot, budget, None)
    }
    pub(crate) fn open_bounded(
        snapshot: Arc<HeldFile>,
        budget: &ValidationBudget,
        resources: Option<Arc<crate::query_resources::QueryResources>>,
    ) -> Result<Self, StoreError> {
        let connection = open_snapshot_connection(&snapshot, budget)?;
        let prepared = (|| {
            let db =
                Database::borrow_readonly(&connection, budget)?.with_resources(resources.clone());
            let inspection = IndexedDatabaseInspection {
                inspection: db.inspect()?,
                applicable_index_names: indexes::validate(&db)?,
            };
            let directory = DirectorySchema::read(&db)?;
            let events = EventSchema::read(&db)?;
            let slices = SliceSchema::read(&db)?;
            let counters = CounterSchema::read(&db, &inspection.inspection)?;
            let frames = FrameSchema::read(&db)?;
            let arguments = ArgumentSchema::read(&db)?;
            let summary = SummarySchema::read(&db, &inspection.inspection)?;
            snapshot.readonly_database_path()?;
            budget.check()?;
            Ok((
                inspection, directory, events, slices, counters, frames, arguments, summary,
            ))
        })();
        let (inspection, directory, events, slices, counters, frames, arguments, summary) =
            match prepared {
                Ok(value) => value,
                Err(error) => {
                    connection.close().map_err(|_| StoreError::CleanupFailed)?;
                    return Err(error);
                }
            };
        Ok(Self {
            connection,
            snapshot,
            inspection,
            directory,
            events,
            slices,
            counters,
            frames,
            arguments,
            summary,
            _worker: PhantomData,
            resources,
            query_deadline: Cell::new(None),
        })
    }
    pub fn inspection(&self) -> &DatabaseInspection {
        &self.inspection.inspection
    }
    pub fn indexed_inspection(&self) -> &IndexedDatabaseInspection {
        &self.inspection
    }
    pub fn verify(&self, budget: &ValidationBudget) -> Result<(), StoreError> {
        self.with_database(budget, |db| {
            if db.inspect()? != self.inspection.inspection
                || indexes::validate(db)? != self.inspection.applicable_index_names
            {
                return Err(StoreError::InvalidDatabase);
            }
            Ok(())
        })
    }
    pub fn processes(
        &self,
        query: &ProcessQuery,
        budget: &ValidationBudget,
    ) -> Result<DirectoryPage<TraceProcess>, StoreError> {
        self.with_database(budget, |db| {
            self.directory.processes(db, self.inspection(), query)
        })
    }
    pub fn threads(
        &self,
        query: &ThreadQuery,
        budget: &ValidationBudget,
    ) -> Result<DirectoryPage<TraceThread>, StoreError> {
        self.with_database(budget, |db| {
            self.directory.threads(db, self.inspection(), query)
        })
    }
    pub fn cpu_slices(
        &self,
        query: &CpuSliceQuery,
        budget: &ValidationBudget,
    ) -> Result<EventPage<CpuSlice>, StoreError> {
        self.with_database(budget, |db| {
            self.events.cpu_slices(db, self.inspection(), query)
        })
    }
    pub fn thread_states(
        &self,
        query: &ThreadStateQuery,
        budget: &ValidationBudget,
    ) -> Result<EventPage<ThreadStateInterval>, StoreError> {
        self.with_database(budget, |db| {
            self.events.thread_states(db, self.inspection(), query)
        })
    }
    pub fn slices(
        &self,
        query: &TraceSliceQuery,
        budget: &ValidationBudget,
    ) -> Result<EventPage<TraceSlice>, StoreError> {
        self.with_database(budget, |db| {
            self.slices.slices(db, self.inspection(), query)
        })
    }
    pub fn counters(
        &self,
        query: &CounterQuery,
        budget: &ValidationBudget,
    ) -> Result<EventPage<CounterSeries>, StoreError> {
        self.with_database(budget, |db| {
            self.counters.counters(db, self.inspection(), query)
        })
    }
    pub fn counter_series(
        &self,
        query: &CounterSeriesQuery,
        budget: &ValidationBudget,
    ) -> Result<EventPage<CounterSeriesDescriptor>, StoreError> {
        self.with_database(budget, |db| {
            self.counters.series(db, self.inspection(), query)
        })
    }
    pub fn frames(
        &self,
        query: &TraceFrameQuery,
        budget: &ValidationBudget,
    ) -> Result<EventPage<TraceFrame>, StoreError> {
        self.with_database(budget, |db| {
            self.frames.frames(db, self.inspection(), query)
        })
    }
    pub fn arguments(
        &self,
        query: &TraceArgumentQuery,
        budget: &ValidationBudget,
    ) -> Result<EventPage<TraceEventArgument>, StoreError> {
        self.with_database(budget, |db| self.arguments.arguments(db, query))
    }
    pub fn density(
        &self,
        query: &arktrace_contract::TraceDensityQuery,
        budget: &ValidationBudget,
    ) -> Result<arktrace_contract::TraceDensityResult, StoreError> {
        self.with_database(budget, |db| {
            crate::density::density(db, self.inspection(), &self.counters, self.frames, query)
        })
    }
    pub fn summary_facts(
        &self,
        query: &arktrace_contract::TraceSummaryQuery,
        budget: &ValidationBudget,
    ) -> Result<arktrace_contract::TraceSummaryFacts, StoreError> {
        self.with_database(budget, |db| {
            self.summary
                .facts(db, self.inspection(), &self.counters, query)
        })
    }
    /// Request-scoped bounded pool. Its connections are created, reused for
    /// this batch and explicitly closed on their owning worker threads. All
    /// workers drain before either a complete result or an error is returned.
    pub fn event_batch(
        &self,
        batch: &arktrace_contract::TraceRepositoryEventBatch,
        budget: &ValidationBudget,
        limits: crate::ReadPoolLimits,
    ) -> Result<crate::ReadPoolOutput, StoreError> {
        batch.validate().map_err(|_| StoreError::InvalidQuery)?;
        limits.validate()?;
        self.with_database(budget, |_| {
            crate::read_pool::run(
                self.snapshot.clone(),
                &self.inspection,
                batch,
                budget,
                limits,
            )
        })
    }
    pub fn event_batch_with_deadlines(
        &self,
        batch: &arktrace_contract::TraceRepositoryEventBatch,
        deadlines: &[Option<ContinuousDeadline>],
        budget: &ValidationBudget,
        limits: crate::ReadPoolLimits,
    ) -> Result<crate::ReadPoolOutput, StoreError> {
        self.with_database(budget, |_| {
            crate::read_pool::run_with_deadlines(
                self.snapshot.clone(),
                &self.inspection,
                batch,
                deadlines,
                budget,
                limits,
            )
        })
    }
    /// Scoped same-host query policy. It does not replace the caller's whole
    /// operation budget, nor recheck a completed value during serialization.
    pub fn with_query_deadline<T>(
        &self,
        deadline: Option<ContinuousDeadline>,
        body: impl FnOnce() -> Result<T, StoreError>,
    ) -> Result<T, StoreError> {
        if deadline.is_some_and(|value| !value.is_valid()) {
            return Err(StoreError::InvalidBudget);
        }
        struct Restore<'a>(
            &'a Cell<Option<ContinuousDeadline>>,
            Option<ContinuousDeadline>,
        );
        impl Drop for Restore<'_> {
            fn drop(&mut self) {
                self.0.set(self.1);
            }
        }
        let restore = Restore(&self.query_deadline, self.query_deadline.replace(deadline));
        let result = body();
        drop(restore);
        result
    }
    pub(crate) fn with_database<T>(
        &self,
        budget: &ValidationBudget,
        body: impl FnOnce(&Database<'_>) -> Result<T, StoreError>,
    ) -> Result<T, StoreError> {
        budget.check()?;
        if self.snapshot.snapshot().byte_count > budget.maximum_database_bytes {
            return Err(StoreError::Host(
                arktrace_platform::HostError::LimitExceeded,
            ));
        }
        self.snapshot.readonly_database_path()?;
        let db = Database::borrow_readonly(&self.connection, budget)?
            .with_resources(self.resources.clone())
            .with_query_deadline(self.query_deadline.get());
        let result = body(&db);
        let revalidation = self.snapshot.readonly_database_path();
        // A concurrent caller cancellation must not hide a fatal worker or
        // cleanup failure from Engine's Session state. Still revalidate the
        // held snapshot on every exit, including these terminal failures.
        if matches!(
            result,
            Err(StoreError::CleanupFailed | StoreError::WorkerFailed)
        ) {
            return result;
        }
        revalidation?;
        budget.check()?;
        result
    }
    pub fn close(self) -> Result<(), StoreError> {
        self.connection
            .close()
            .map_err(|_| StoreError::CleanupFailed)
    }
}
