use crate::{
    DatabaseInspection, IndexedDatabaseInspection, StoreError, ValidationBudget,
    arguments::ArgumentSchema, counters::CounterSchema, database::Database,
    directory::DirectorySchema, events::EventSchema, frames::FrameSchema, indexes,
    open_snapshot_connection, slices::SliceSchema,
};
use arktrace_contract::{
    CounterQuery, CounterSeries, CounterSeriesDescriptor, CounterSeriesQuery, CpuSlice,
    CpuSliceQuery, DirectoryPage, EventPage, ProcessQuery, ThreadQuery, ThreadStateInterval,
    ThreadStateQuery, TraceArgumentQuery, TraceEventArgument, TraceFrame, TraceFrameQuery,
    TraceProcess, TraceSlice, TraceSliceQuery, TraceThread,
};
use arktrace_platform::HeldFile;
use std::{marker::PhantomData, rc::Rc, sync::Arc};

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
    _worker: PhantomData<Rc<()>>,
}
impl StoreReader {
    pub fn open(snapshot: Arc<HeldFile>, budget: &ValidationBudget) -> Result<Self, StoreError> {
        let connection = open_snapshot_connection(&snapshot, budget)?;
        let db = Database::borrow_readonly(&connection, budget)?;
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
        snapshot.readonly_database_path()?;
        budget.check()?;
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
            _worker: PhantomData,
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
    fn with_database<T>(
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
        let db = Database::borrow_readonly(&self.connection, budget)?;
        let result = body(&db);
        self.snapshot.readonly_database_path()?;
        budget.check()?;
        result
    }
    pub fn close(self) -> Result<(), StoreError> {
        self.connection
            .close()
            .map_err(|_| StoreError::CleanupFailed)
    }
}
