use crate::metadata::{
    CacheMetadata, MAXIMUM_METADATA_BYTES, MetadataPreparation, utc_from_unix_seconds,
};
use arktrace_contract::{
    CounterQuery, CounterSeries, CounterSeriesDescriptor, CounterSeriesQuery, CpuSlice,
    CpuSliceQuery, DirectoryPage, EventPage, ProcessQuery, ThreadQuery, ThreadStateInterval,
    ThreadStateQuery, TraceAgentCounterEvent, TraceArgumentQuery, TraceCacheKey,
    TraceEventArgument, TraceFrame, TraceFrameQuery, TraceParserIdentity, TraceProcess,
    TraceSearchRequest, TraceSearchResults, TraceSlice, TraceSliceQuery, TraceThread,
};
use arktrace_platform::{
    CancellationToken, EphemeralLease, HeldDirectory, HeldFile, HostError, IoBudget, Lease,
    LeaseMode, OwnedDirectory, OwnerKind, OwnerRecoveryOutcome, OwnerStore, ProcessBudget,
    ProcessError, ProcessOutputFileBudget, VerifiedExecutable, run_supervised,
};
use arktrace_store::{
    DatabaseInspection, IndexProgress, StoreError, StoreReader, ValidationBudget,
    inspect_indexed_snapshot, prepare_snapshot,
};
use serde::Serialize;
use std::{
    cell::{Cell, RefCell},
    ffi::OsString,
    sync::Arc,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
mod viewer;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub enum EngineStage {
    SourceSnapshot,
    ParserIdentity,
    Parsing,
    Indexing,
    Validating,
    Publishing,
    Closing,
    Recovering,
    Querying,
    Analyzing,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub enum EngineFailure {
    InvalidBudget,
    InvalidIdentity,
    InvalidMetadata,
    ParserVersionMismatch,
    ParserExit {
        exit_code: Option<i32>,
        signal: Option<i32>,
    },
    Host(HostError),
    Process(ProcessError),
    Store(StoreError),
    Analysis(AnalysisFailure),
    Viewer(ViewerFailure),
    CleanupFailed,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub struct EngineError {
    pub stage: EngineStage,
    pub failure: EngineFailure,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub enum AnalysisFailure {
    InvalidBounds,
    InputBudgetExceeded,
    InvalidEvidence,
    InvalidQuality,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub enum ViewerFailure {
    InvalidBounds,
    InputBudgetExceeded,
    InvalidEvidence,
    InvalidQuality,
}
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, serde::Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AnalysisScope {
    pub process_key: Option<i64>,
    pub pid: Option<i64>,
    pub thread_key: Option<i64>,
    pub tid: Option<i64>,
}
impl AnalysisScope {
    pub(crate) fn validate(self) -> Result<(), EngineError> {
        if self.process_key == Some(0)
            || self.thread_key == Some(0)
            || self.pid.is_some_and(|v| v < 0)
            || self.tid.is_some_and(|v| v < 0)
            || (self.process_key.is_some() && self.pid.is_some())
            || (self.thread_key.is_some() && self.tid.is_some())
        {
            return Err(analysis_error(
                arktrace_analysis::AnalysisError::InvalidBounds,
            ));
        }
        Ok(())
    }
}
fn analysis_error(error: arktrace_analysis::AnalysisError) -> EngineError {
    use arktrace_analysis::AnalysisError::*;
    failure(
        EngineStage::Analyzing,
        match error {
            Cancelled => EngineFailure::Host(HostError::Cancelled),
            DeadlineReached => EngineFailure::Host(HostError::DeadlineExceeded),
            InvalidBounds => EngineFailure::Analysis(AnalysisFailure::InvalidBounds),
            InputBudgetExceeded => EngineFailure::Analysis(AnalysisFailure::InputBudgetExceeded),
            InvalidEvidence => EngineFailure::Analysis(AnalysisFailure::InvalidEvidence),
            Quality(_) => EngineFailure::Analysis(AnalysisFailure::InvalidQuality),
        },
    )
}
impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:?}", self)
    }
}
impl std::error::Error for EngineError {}
fn host(stage: EngineStage, error: HostError) -> EngineError {
    EngineError {
        stage,
        failure: EngineFailure::Host(error),
    }
}
fn failure(stage: EngineStage, failure: EngineFailure) -> EngineError {
    EngineError { stage, failure }
}

#[derive(Clone, Debug)]
pub struct EngineBudget {
    pub maximum_source_bytes: u64,
    pub maximum_database_bytes: u64,
    pub deadline: Instant,
    pub cancellation: CancellationToken,
}
impl EngineBudget {
    fn io(&self, maximum_bytes: u64) -> IoBudget {
        IoBudget {
            maximum_bytes,
            deadline: self.deadline,
            cancellation: self.cancellation.clone(),
        }
    }
    fn check(&self) -> Result<(), EngineError> {
        if self.maximum_source_bytes == 0
            || self.maximum_database_bytes == 0
            || self.maximum_source_bytes > i64::MAX as u64
            || self.maximum_database_bytes > i64::MAX as u64
        {
            return Err(failure(
                EngineStage::SourceSnapshot,
                EngineFailure::InvalidBudget,
            ));
        }
        self.io(self.maximum_source_bytes)
            .check()
            .map_err(|e| host(EngineStage::SourceSnapshot, e))
    }
    fn process(&self) -> ProcessBudget {
        ProcessBudget {
            deadline: self.deadline,
            cancellation: self.cancellation.clone(),
            stdout_bytes: 65_536,
            stderr_bytes: 65_536,
            termination_grace: Duration::from_millis(500),
            output_files: Vec::new(),
        }
    }
    fn validation(&self) -> ValidationBudget {
        ValidationBudget {
            maximum_database_bytes: self.maximum_database_bytes,
            deadline: self.deadline,
            cancellation: self.cancellation.clone(),
        }
    }
    fn cleanup(&self) -> IoBudget {
        IoBudget {
            maximum_bytes: self
                .maximum_source_bytes
                .max(self.maximum_database_bytes)
                .max(MAXIMUM_METADATA_BYTES as u64),
            deadline: Instant::now() + Duration::from_secs(5),
            cancellation: CancellationToken::default(),
        }
    }
}
pub struct ParserTools<'a> {
    pub helper: &'a VerifiedExecutable,
    pub parser: &'a VerifiedExecutable,
    pub identity: TraceParserIdentity,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SourceFormat {
    Htrace,
    Systrace,
}
impl SourceFormat {
    fn name(self) -> &'static str {
        match self {
            Self::Htrace => "source.htrace",
            Self::Systrace => "source.systrace",
        }
    }
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub enum EngineProgress {
    SourceSnapshot,
    ParserIdentity,
    Parsing,
    Indexing(IndexProgress),
    Validating,
    Publishing,
    OpeningDatabase,
    Ready,
}

/// Ephemeral Ready only; persistent cache lookup/eviction is a separate API.
/// Drop releases handles and retains owner proof. Explicit close performs IO.
#[must_use = "close the session explicitly; Drop retains proof for recovery"]
pub struct NoCacheSession {
    owner: OwnedDirectory,
    lease: EphemeralLease,
    database: Option<Arc<HeldFile>>,
    reader: Option<StoreReader>,
    metadata_file: Option<HeldFile>,
    metadata: CacheMetadata,
    inspection: DatabaseInspection,
    cleanup_bytes: u64,
    query_worker_failed: Cell<bool>,
    viewer: RefCell<arktrace_viewer::ViewportLoader>,
}
impl NoCacheSession {
    /// Worker-owned bounded Store-to-Viewer detail operation. Focused-event
    /// inclusion, snapshot planning and cache/generation stay separate.
    pub fn viewer_details(
        &self,
        source: &arktrace_contract::TraceDensitySource,
        range: arktrace_contract::TraceTimeRange,
        limit: usize,
        budget: &EngineBudget,
    ) -> Result<EventPage<arktrace_viewer::DetailInput>, EngineError> {
        use arktrace_viewer::{RepositoryDetailPage as P, RepositoryDetailQuery as Q};
        let query = arktrace_viewer::detail_query(source, range, limit).map_err(viewer_error)?;
        let raw = match query {
            Q::Cpu(q) => P::Cpu(self.cpu_slices(&q, budget)?),
            Q::ThreadState(q) => P::ThreadState(self.thread_states(&q, budget)?),
            Q::NamedSlice(q) => P::NamedSlice(self.slices(&q, budget)?),
            Q::Counter(q) => P::Counter(self.counters(&q, budget)?),
            Q::Frame(q) => P::Frame(self.frames(&q, budget)?),
        };
        let mut check = || {
            budget.check().map_err(|e| match e.failure {
                EngineFailure::Host(HostError::Cancelled) => {
                    arktrace_viewer::ViewerError::Cancelled
                }
                EngineFailure::Host(HostError::DeadlineExceeded) => {
                    arktrace_viewer::ViewerError::DeadlineReached
                }
                _ => arktrace_viewer::ViewerError::InvalidRequest,
            })
        };
        let result = arktrace_viewer::map_detail_page(source, range, limit, raw, &mut check)
            .map_err(viewer_error);
        self.query_reader(budget)?;
        result
    }
    /// Shared Viewer search over this immutable session's bounded raw queries.
    /// The caller supplies its deadline; thirty seconds is the upper bound.
    pub fn search(
        &self,
        request: &TraceSearchRequest,
        budget: &EngineBudget,
    ) -> Result<TraceSearchResults, EngineError> {
        let mut budget = budget.clone();
        budget.deadline = budget
            .deadline
            .min(Instant::now() + Duration::from_secs(30));
        let repository = SessionSearch {
            session: self,
            budget: &budget,
        };
        let mut check = || {
            budget.check().map_err(|e| match e.failure {
                EngineFailure::Host(HostError::Cancelled) => {
                    arktrace_analysis::AnalysisError::Cancelled
                }
                EngineFailure::Host(HostError::DeadlineExceeded) => {
                    arktrace_analysis::AnalysisError::DeadlineReached
                }
                _ => arktrace_analysis::AnalysisError::InvalidBounds,
            })
        };
        let result = arktrace_analysis::search(&repository, request, &mut check)
            .map_err(|error| match error {
                arktrace_analysis::SearchError::Analysis(e) => analysis_error(e),
                arktrace_analysis::SearchError::Repository(e) => e,
            })
            .and_then(|result| self.query_reader(&budget).map(|_| result));
        // Swift remaps task cancellation even if it interrupted a Store call.
        if result.is_err() && budget.cancellation.is_cancelled() {
            return Err(host(EngineStage::Analyzing, HostError::Cancelled));
        }
        result
    }
    pub fn metadata(&self) -> &CacheMetadata {
        &self.metadata
    }
    pub fn inspection(&self) -> &DatabaseInspection {
        &self.inspection
    }
    pub fn verify(&self, budget: &EngineBudget) -> Result<(), EngineError> {
        if self.query_worker_failed.get() {
            return Err(failure(
                EngineStage::Validating,
                EngineFailure::Store(StoreError::WorkerFailed),
            ));
        }
        self.lease
            .revalidate()
            .map_err(|e| host(EngineStage::Validating, e))?;
        let reader = self
            .reader
            .as_ref()
            .ok_or_else(|| failure(EngineStage::Validating, EngineFailure::InvalidMetadata))?;
        reader
            .verify(&budget.validation())
            .map_err(|e| failure(EngineStage::Validating, EngineFailure::Store(e)))?;
        if reader.inspection() != &self.inspection {
            return Err(failure(
                EngineStage::Validating,
                EngineFailure::InvalidMetadata,
            ));
        }
        self.metadata_file
            .as_ref()
            .ok_or_else(|| failure(EngineStage::Validating, EngineFailure::InvalidMetadata))?
            .verify()
            .map_err(|e| host(EngineStage::Validating, e))?;
        Ok(())
    }
    pub fn processes(
        &self,
        query: &ProcessQuery,
        budget: &EngineBudget,
    ) -> Result<DirectoryPage<TraceProcess>, EngineError> {
        let result = self
            .query_reader(budget)?
            .processes(query, &budget.validation())
            .map_err(|e| failure(EngineStage::Querying, EngineFailure::Store(e)));
        self.query_reader(budget)?;
        result
    }
    pub fn threads(
        &self,
        query: &ThreadQuery,
        budget: &EngineBudget,
    ) -> Result<DirectoryPage<TraceThread>, EngineError> {
        let result = self
            .query_reader(budget)?
            .threads(query, &budget.validation())
            .map_err(|e| failure(EngineStage::Querying, EngineFailure::Store(e)));
        self.query_reader(budget)?;
        result
    }
    pub fn cpu_slices(
        &self,
        query: &CpuSliceQuery,
        budget: &EngineBudget,
    ) -> Result<EventPage<CpuSlice>, EngineError> {
        let result = self
            .query_reader(budget)?
            .cpu_slices(query, &budget.validation())
            .map_err(|e| failure(EngineStage::Querying, EngineFailure::Store(e)));
        self.query_reader(budget)?;
        result
    }
    pub fn thread_states(
        &self,
        query: &ThreadStateQuery,
        budget: &EngineBudget,
    ) -> Result<EventPage<ThreadStateInterval>, EngineError> {
        let result = self
            .query_reader(budget)?
            .thread_states(query, &budget.validation())
            .map_err(|e| failure(EngineStage::Querying, EngineFailure::Store(e)));
        self.query_reader(budget)?;
        result
    }
    pub fn slices(
        &self,
        query: &TraceSliceQuery,
        budget: &EngineBudget,
    ) -> Result<EventPage<TraceSlice>, EngineError> {
        let result = self
            .query_reader(budget)?
            .slices(query, &budget.validation())
            .map_err(|e| failure(EngineStage::Querying, EngineFailure::Store(e)));
        self.query_reader(budget)?;
        result
    }
    pub fn arguments(
        &self,
        query: &TraceArgumentQuery,
        budget: &EngineBudget,
    ) -> Result<EventPage<TraceEventArgument>, EngineError> {
        let result = self
            .query_reader(budget)?
            .arguments(query, &budget.validation())
            .map_err(|e| failure(EngineStage::Querying, EngineFailure::Store(e)));
        self.query_reader(budget)?;
        result
    }
    pub fn frames(
        &self,
        query: &TraceFrameQuery,
        budget: &EngineBudget,
    ) -> Result<EventPage<TraceFrame>, EngineError> {
        let result = self
            .query_reader(budget)?
            .frames(query, &budget.validation())
            .map_err(|e| failure(EngineStage::Querying, EngineFailure::Store(e)));
        self.query_reader(budget)?;
        result
    }
    pub fn density(
        &self,
        query: &arktrace_contract::TraceDensityQuery,
        budget: &EngineBudget,
    ) -> Result<arktrace_contract::TraceDensityResult, EngineError> {
        let result = self
            .query_reader(budget)?
            .density(query, &budget.validation())
            .map_err(|e| failure(EngineStage::Querying, EngineFailure::Store(e)));
        self.query_reader(budget)?;
        result
    }
    pub fn counters(
        &self,
        query: &CounterQuery,
        budget: &EngineBudget,
    ) -> Result<EventPage<CounterSeries>, EngineError> {
        let result = self
            .query_reader(budget)?
            .counters(query, &budget.validation())
            .map_err(|e| failure(EngineStage::Querying, EngineFailure::Store(e)));
        self.query_reader(budget)?;
        result
    }
    pub fn counter_series(
        &self,
        query: &CounterSeriesQuery,
        budget: &EngineBudget,
    ) -> Result<EventPage<CounterSeriesDescriptor>, EngineError> {
        let result = self
            .query_reader(budget)?
            .counter_series(query, &budget.validation())
            .map_err(|e| failure(EngineStage::Querying, EngineFailure::Store(e)));
        self.query_reader(budget)?;
        result
    }
    /// Blocking repository operation for the host's background executor.
    /// Borrowing this worker-owned session retains Ready/lease authority until
    /// the bounded read pool has drained and closed every connection.
    pub fn event_batch(
        &self,
        batch: &arktrace_contract::TraceRepositoryEventBatch,
        budget: &EngineBudget,
        limits: crate::ReadPoolLimits,
    ) -> Result<crate::ReadPoolOutput, EngineError> {
        let result = self
            .query_reader(budget)?
            .event_batch(batch, &budget.validation(), limits);
        if matches!(result, Err(StoreError::WorkerFailed)) {
            self.query_worker_failed.set(true);
        }
        if matches!(result, Err(StoreError::CleanupFailed)) {
            return Err(failure(
                EngineStage::Querying,
                EngineFailure::Store(StoreError::CleanupFailed),
            ));
        }
        self.query_reader(budget)?;
        result.map_err(|error| failure(EngineStage::Querying, EngineFailure::Store(error)))
    }
    pub fn query_counters(
        &self,
        query: &CounterQuery,
        budget: &EngineBudget,
    ) -> Result<EventPage<TraceAgentCounterEvent>, EngineError> {
        self.query_reader(budget)?;
        validate_event_request(
            query.range,
            query.limit,
            query.process_key,
            None,
            None,
            self.inspection.duration_ns,
        )?;
        let page = compose_counter_page(
            self.counters(query, budget)?,
            &self.inspection,
            query.limit,
            budget,
        )?;
        self.query_reader(budget)?;
        Ok(page)
    }
    pub fn query_slices(
        &self,
        query: &TraceSliceQuery,
        budget: &EngineBudget,
    ) -> Result<EventPage<TraceSlice>, EngineError> {
        self.query_reader(budget)?;
        validate_event_request(
            query.range,
            query.limit,
            query.process_key,
            query.thread_key,
            None,
            self.inspection.duration_ns,
        )?;
        validate_named_agent_filters(query)?;
        let page = self.slices(query, budget)?;
        let page = compose_event_page(page, &self.inspection, budget, |v| {
            (v.range.start_ns(), v.key.row_id)
        })?;
        self.query_reader(budget)?;
        Ok(page)
    }
    /// Agent-facing composition used by CLI/App consumers: unlike the raw
    /// repository Page, even an unavailable view carries trace-wide quality.
    /// Sort by normalized time after clamping, as Swift TraceAgentQueryEngine.
    pub fn query_cpu_slices(
        &self,
        query: &CpuSliceQuery,
        budget: &EngineBudget,
    ) -> Result<EventPage<CpuSlice>, EngineError> {
        self.query_reader(budget)?;
        validate_event_request(
            query.range,
            query.limit,
            query.process_key,
            query.thread_key,
            None,
            self.inspection.duration_ns,
        )?;
        let page = self.cpu_slices(query, budget)?;
        let page = compose_event_page(page, &self.inspection, budget, |v| {
            (v.range.start_ns(), v.key.row_id)
        })?;
        self.query_reader(budget)?;
        Ok(page)
    }
    pub fn query_thread_states(
        &self,
        query: &ThreadStateQuery,
        budget: &EngineBudget,
    ) -> Result<EventPage<ThreadStateInterval>, EngineError> {
        self.query_reader(budget)?;
        validate_event_request(
            query.range,
            query.limit,
            query.process_key,
            query.thread_key,
            query.raw_state.as_deref(),
            self.inspection.duration_ns,
        )?;
        let page = self.thread_states(query, budget)?;
        let page = compose_event_page(page, &self.inspection, budget, |v| {
            (v.range.start_ns(), v.key.row_id)
        })?;
        self.query_reader(budget)?;
        Ok(page)
    }
    /// Migration-only six-section composition. It is not the complete public
    /// analysis envelope: long slices and adapter attestation
    /// remain pending. Exact identity filters apply to every independent page.
    pub fn analyze_bounded(
        &self,
        request: &arktrace_analysis::AnalysisRequest,
        scope: AnalysisScope,
        budget: &EngineBudget,
    ) -> Result<arktrace_analysis::AnalysisResult, EngineError> {
        budget.check().map_err(|mut error| {
            error.stage = EngineStage::Analyzing;
            error
        })?;
        request.validate().map_err(analysis_error)?;
        scope.validate()?;
        if request.range.end_ns() > self.inspection.duration_ns {
            return Err(analysis_error(
                arktrace_analysis::AnalysisError::InvalidBounds,
            ));
        }
        self.query_reader(budget)?;
        let mut cpu_pages = std::collections::BTreeMap::new();
        for limit in [
            request.maximum_cpu_slices,
            request.maximum_process_slices,
            request.maximum_thread_slices,
            request.maximum_scheduling_events,
            request.maximum_hot_events,
        ] {
            if let std::collections::btree_map::Entry::Vacant(entry) = cpu_pages.entry(limit) {
                let query = CpuSliceQuery {
                    range: request.range,
                    cpu: None,
                    process_key: scope.process_key,
                    pid: scope.pid,
                    thread_key: scope.thread_key,
                    tid: scope.tid,
                    limit,
                };
                entry.insert(self.cpu_slices(&query, budget)?);
            }
        }
        let state_query = ThreadStateQuery {
            range: request.range,
            cpu: None,
            process_key: scope.process_key,
            pid: scope.pid,
            thread_key: scope.thread_key,
            tid: scope.tid,
            raw_state: None,
            state: None,
            limit: request.maximum_state_intervals,
        };
        let states = self.thread_states(&state_query, budget)?;
        let runnable = self.thread_states(
            &ThreadStateQuery {
                state: Some(arktrace_contract::TraceThreadState::Runnable),
                limit: request.maximum_scheduling_events,
                ..state_query
            },
            budget,
        )?;
        let named = self.slices(
            &TraceSliceQuery {
                range: request.range,
                event_key: None,
                process_key: scope.process_key,
                pid: scope.pid,
                thread_key: scope.thread_key,
                tid: scope.tid,
                name: None,
                name_match: arktrace_contract::DirectoryNameMatch::Exact,
                minimum_duration_ns: Some(request.minimum_long_slice_duration_ns),
                depth: None,
                unattributed_only: false,
                includes_argument_set: false,
                limit: request.maximum_hot_events,
            },
            budget,
        )?;
        let mut check = || {
            if budget.cancellation.is_cancelled() {
                Err(arktrace_analysis::AnalysisError::Cancelled)
            } else if Instant::now() >= budget.deadline {
                Err(arktrace_analysis::AnalysisError::DeadlineReached)
            } else {
                Ok(())
            }
        };
        let result = (|| {
            let mut named_items = Vec::with_capacity(named.items.len());
            for (index, slice) in named.items.into_iter().enumerate() {
                if index.is_multiple_of(256) {
                    check()?;
                }
                named_items.push(arktrace_analysis::NamedDurationEvidence {
                    key: slice.key,
                    range: slice.range,
                });
            }
            let named = EventPage {
                items: named_items,
                truncated: named.truncated,
                capability_available: named.capability_available,
                data_quality: named.data_quality,
            };
            arktrace_analysis::analyze(
                request,
                arktrace_analysis::AnalysisInput {
                    cpu: &cpu_pages[&request.maximum_cpu_slices],
                    processes: &cpu_pages[&request.maximum_process_slices],
                    threads: &cpu_pages[&request.maximum_thread_slices],
                    states: &states,
                    scheduling_cpu: &cpu_pages[&request.maximum_scheduling_events],
                    scheduling_states: &runnable,
                    // The normalized enum alone does not attest pinned upstream
                    // Runnable waiting semantics. Never accept caller-made proof.
                    runnable_semantics: arktrace_analysis::RunnableSemantics::Unproven,
                    hot_cpu: &cpu_pages[&request.maximum_hot_events],
                    hot_named: Some(&named),
                    named_slices_available: self.inspection.capabilities.named_slices,
                    trace_quality: &self.inspection.data_quality,
                },
                &mut check,
            )
        })()
        .map_err(analysis_error);
        // Always recheck retained database/metadata/entry authority after pure
        // work, including a failed or cancelled reduction.
        self.verify(budget).map_err(|mut error| {
            if matches!(
                error.failure,
                EngineFailure::Host(HostError::Cancelled | HostError::DeadlineExceeded)
                    | EngineFailure::Store(StoreError::Cancelled | StoreError::DeadlineExceeded)
            ) {
                error.stage = EngineStage::Analyzing;
            }
            error
        })?;
        result
    }
    fn query_reader(&self, budget: &EngineBudget) -> Result<&StoreReader, EngineError> {
        if self.query_worker_failed.get() {
            return Err(failure(
                EngineStage::Querying,
                EngineFailure::Store(StoreError::WorkerFailed),
            ));
        }
        budget
            .check()
            .map_err(|e| failure(EngineStage::Querying, e.failure))?;
        self.lease
            .revalidate()
            .map_err(|e| host(EngineStage::Querying, e))?;
        self.metadata_file
            .as_ref()
            .ok_or_else(|| failure(EngineStage::Querying, EngineFailure::InvalidMetadata))?
            .verify()
            .map_err(|e| host(EngineStage::Querying, e))?;
        self.reader
            .as_ref()
            .ok_or_else(|| failure(EngineStage::Querying, EngineFailure::InvalidMetadata))
    }
    pub fn close(mut self) -> Result<(), EngineError> {
        let budget = IoBudget {
            maximum_bytes: self.cleanup_bytes,
            deadline: Instant::now() + Duration::from_secs(5),
            cancellation: CancellationToken::default(),
        };
        self.lease
            .revalidate()
            .map_err(|e| host(EngineStage::Closing, e))?;
        if let Some(reader) = self.reader.take() {
            reader
                .close()
                .map_err(|e| failure(EngineStage::Closing, EngineFailure::Store(e)))?;
        }
        self.database.take();
        self.metadata_file.take();
        self.owner
            .cleanup(&budget)
            .map_err(|_| failure(EngineStage::Closing, EngineFailure::CleanupFailed))?;
        self.owner
            .finish_ephemeral_cleanup(self.lease, &budget)
            .map_err(|_| failure(EngineStage::Closing, EngineFailure::CleanupFailed))
    }
}
fn viewer_error(error: arktrace_viewer::ViewerError) -> EngineError {
    use arktrace_viewer::ViewerError::*;
    let cause = match error {
        Cancelled => EngineFailure::Host(HostError::Cancelled),
        DeadlineReached => EngineFailure::Host(HostError::DeadlineExceeded),
        InvalidViewport | InvalidGeometry | InvalidRequest => {
            EngineFailure::Viewer(ViewerFailure::InvalidBounds)
        }
        InputBudgetExceeded => EngineFailure::Viewer(ViewerFailure::InputBudgetExceeded),
        InvalidEvidence | ArithmeticOverflow => {
            EngineFailure::Viewer(ViewerFailure::InvalidEvidence)
        }
        Quality(_) => EngineFailure::Viewer(ViewerFailure::InvalidQuality),
    };
    failure(EngineStage::Querying, cause)
}
struct SessionSearch<'a> {
    session: &'a NoCacheSession,
    budget: &'a EngineBudget,
}
impl arktrace_analysis::SearchRepository for SessionSearch<'_> {
    type Error = EngineError;
    fn duration_ns(&self) -> Result<i64, EngineError> {
        self.session.query_reader(self.budget)?;
        Ok(self.session.inspection.duration_ns)
    }
    fn processes(&self, query: &ProcessQuery) -> Result<DirectoryPage<TraceProcess>, EngineError> {
        self.session.processes(query, self.budget)
    }
    fn threads(&self, query: &ThreadQuery) -> Result<DirectoryPage<TraceThread>, EngineError> {
        self.session.threads(query, self.budget)
    }
    fn slices(&self, query: &TraceSliceQuery) -> Result<EventPage<TraceSlice>, EngineError> {
        self.session.slices(query, self.budget)
    }
}
fn compose_counter_page(
    page: EventPage<CounterSeries>,
    inspection: &DatabaseInspection,
    limit: usize,
    budget: &EngineBudget,
) -> Result<EventPage<TraceAgentCounterEvent>, EngineError> {
    let check = || {
        budget
            .check()
            .map_err(|e| failure(EngineStage::Querying, e.failure))
    };
    check()?;
    let mut items = Vec::new();
    for (index, series) in page.items.into_iter().enumerate() {
        if index.is_multiple_of(256) {
            check()?;
        }
        for sample in series.samples {
            items.push(TraceAgentCounterEvent {
                filter_id: series.filter_id,
                name: series.name.clone(),
                scope: series.scope,
                cpu: series.cpu,
                process_key: series.process_key,
                pid: series.pid,
                process_name: series.process_name.clone(),
                unit: series.unit.clone(),
                sample,
            });
        }
    }
    items.sort_by_key(|v| {
        (
            v.sample.timestamp_ns,
            if v.sample.key.table == arktrace_contract::EventTable::Measure {
                0
            } else {
                1
            },
            v.sample.key.row_id,
        )
    });
    check()?;
    let truncated = page.truncated || items.len() > limit;
    items.truncate(limit);
    // An available Store page already includes the immutable trace's issues.
    // Swift deduplicates original human issues before Machine projection:
    // open-time and query-time clamps can project to identical machine facts
    // while remaining two independent observations. Preserve that multiplicity.
    let data_quality = if page.capability_available {
        page.data_quality
    } else {
        inspection.data_quality.clone()
    };
    Ok(EventPage {
        items,
        truncated,
        capability_available: page.capability_available,
        data_quality,
    })
}
fn validate_named_agent_filters(query: &TraceSliceQuery) -> Result<(), EngineError> {
    if query
        .name
        .as_ref()
        .is_some_and(|n| n.is_empty() || n.len() > 256)
        || (query.name.is_none()
            && query.name_match != arktrace_contract::DirectoryNameMatch::Exact)
        || query.pid.is_some_and(|v| v < 0)
        || query.tid.is_some_and(|v| v < 0)
        || (query.process_key.is_some() && query.pid.is_some())
        || (query.thread_key.is_some() && query.tid.is_some())
    {
        return Err(failure(
            EngineStage::Querying,
            EngineFailure::Store(StoreError::InvalidQuery),
        ));
    }
    Ok(())
}

fn validate_event_request(
    range: arktrace_contract::TraceTimeRange,
    limit: usize,
    process_key: Option<i64>,
    thread_key: Option<i64>,
    raw_state: Option<&str>,
    duration_ns: i64,
) -> Result<(), EngineError> {
    if range.is_instant()
        || range.end_ns() > duration_ns
        || !(1..=100_000).contains(&limit)
        || process_key == Some(0)
        || thread_key == Some(0)
        || raw_state.is_some_and(|s| s.is_empty() || s.len() > 256)
    {
        return Err(failure(
            EngineStage::Querying,
            EngineFailure::Store(StoreError::InvalidQuery),
        ));
    }
    Ok(())
}
fn compose_event_page<T, K: Ord>(
    mut page: EventPage<T>,
    inspection: &DatabaseInspection,
    budget: &EngineBudget,
    key: impl Fn(&T) -> K,
) -> Result<EventPage<T>, EngineError> {
    budget
        .check()
        .map_err(|e| failure(EngineStage::Querying, e.failure))?;
    page.items.sort_by_key(key);
    // Available Store pages already carry trace-wide observations. Swift
    // deduplicates original issues (including their human message) before
    // machine projection, where distinct clamp observations can be identical.
    // Preserve that multiplicity, as for counters. Unavailable raw pages have
    // no trace facts and receive the immutable inspection quality here.
    if !page.capability_available {
        page.data_quality = inspection.data_quality.clone();
    }
    budget
        .check()
        .map_err(|e| failure(EngineStage::Querying, e.failure))?;
    Ok(page)
}

#[cfg(test)]
mod event_composition_tests {
    use super::*;
    use arktrace_contract::{
        DataQuality, QualityCategory, QualityIssue, QualityStatus, TraceCapabilities,
        TraceTimeRange,
    };
    #[test]
    fn actual_swift_agent_pages_preserve_distinct_clamp_observations_and_order() {
        fn decode_page<T: serde::de::DeserializeOwned>(value: serde_json::Value) -> EventPage<T> {
            #[derive(serde::Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct Page<T> {
                items: Vec<T>,
                truncated: bool,
                capability_available: bool,
                data_quality: DataQuality,
            }
            let p: Page<T> = serde_json::from_value(value).unwrap();
            EventPage {
                items: p.items,
                truncated: p.truncated,
                capability_available: p.capability_available,
                data_quality: p.data_quality,
            }
        }
        let records: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../arktrace-store/tests/fixtures/swift-event-pages.json"
        ))
        .unwrap();
        let mut compared = 0;
        for record in records.iter().filter(|v| v.get("agentPage").is_some()) {
            let name = record["id"].as_str().unwrap();
            let view = name.split('/').nth(1).unwrap();
            let empty = records
                .iter()
                .find(|r| r["id"] == format!("event-clamps/{view}/empty-scope"))
                .unwrap();
            let mut inspection = inspection();
            inspection.data_quality =
                serde_json::from_value(empty["page"]["dataQuality"].clone()).unwrap();
            let value = match view {
                "cpuSlices" => {
                    let raw: EventPage<CpuSlice> = decode_page(record["page"].clone());
                    serde_json::to_value(
                        compose_event_page(raw, &inspection, &budget(), |v| {
                            (v.range.start_ns(), v.key.row_id)
                        })
                        .unwrap(),
                    )
                    .unwrap()
                }
                "threadStates" => {
                    let raw: EventPage<ThreadStateInterval> = decode_page(record["page"].clone());
                    serde_json::to_value(
                        compose_event_page(raw, &inspection, &budget(), |v| {
                            (v.range.start_ns(), v.key.row_id)
                        })
                        .unwrap(),
                    )
                    .unwrap()
                }
                "slices" => {
                    let raw: EventPage<TraceSlice> = decode_page(record["page"].clone());
                    serde_json::to_value(
                        compose_event_page(raw, &inspection, &budget(), |v| {
                            (v.range.start_ns(), v.key.row_id)
                        })
                        .unwrap(),
                    )
                    .unwrap()
                }
                _ => panic!("unexpected Agent view"),
            };
            assert_eq!(value, record["agentPage"], "{name}");
            compared += 1;
        }
        assert_eq!(compared, 12);
    }
    #[test]
    fn counter_agent_preserves_two_swift_clamp_observations_after_machine_projection() {
        let fact = QualityIssue {
            category: QualityCategory::ClampedValue,
            scope: Some("measure.ts".into()),
            count: Some(1),
            message: None,
        };
        let trace = DataQuality::machine(QualityStatus::Warnings, vec![fact.clone()]).unwrap();
        let inspection = DatabaseInspection {
            capabilities: TraceCapabilities {
                cpu_scheduling: false,
                thread_states: false,
                named_slices: false,
                cpu_counters: true,
                process_counters: false,
            },
            schema_fingerprint: "0".repeat(64),
            trace_start_ts: 1000,
            trace_end_ts: 2000,
            duration_ns: 1000,
            data_quality: trace.clone(),
            event_source_counts_available: false,
            cpu_counter_sample_tables: vec![arktrace_store::CounterSampleTable::Measure],
            process_counter_sample_tables: vec![],
        };
        let raw = EventPage {
            items: vec![CounterSeries {
                filter_id: 10,
                name: "cpu".into(),
                scope: arktrace_contract::CounterScope::Cpu,
                cpu: Some(0),
                process_key: None,
                pid: None,
                process_name: None,
                unit: None,
                samples: vec![arktrace_contract::CounterSample {
                    key: arktrace_contract::EventKey {
                        table: arktrace_contract::EventTable::Measure,
                        row_id: 2,
                    },
                    timestamp_ns: 0,
                    value: 7,
                    duration_ns: Some(200),
                }],
            }],
            truncated: false,
            capability_available: true,
            data_quality: DataQuality::machine(
                QualityStatus::Warnings,
                vec![
                    QualityIssue {
                        category: QualityCategory::ClampedValue,
                        scope: Some("measure.dur".into()),
                        count: Some(1),
                        message: None,
                    },
                    fact.clone(),
                    fact,
                ],
            )
            .unwrap(),
        };
        let b = EngineBudget {
            maximum_source_bytes: 1,
            maximum_database_bytes: 1,
            deadline: Instant::now() + Duration::from_secs(10),
            cancellation: CancellationToken::default(),
        };
        let page = compose_counter_page(raw, &inspection, 20, &b).unwrap();
        // Actual unchanged Swift CounterOracle controlled/clamped-ts output.
        assert_eq!(
            serde_json::to_value(&page.data_quality).unwrap(),
            serde_json::json!({"status":"warnings","warnings":[{"category":"clampedValue","scope":"measure.dur","count":1,"message":null},{"category":"clampedValue","scope":"measure.ts","count":1,"message":null},{"category":"clampedValue","scope":"measure.ts","count":1,"message":null}]})
        );
        assert_eq!(page.items[0].sample.timestamp_ns, 0);
        assert!(!page.truncated);
        let unavailable = compose_counter_page(
            EventPage {
                items: vec![],
                truncated: false,
                capability_available: false,
                data_quality: DataQuality::machine(QualityStatus::Ok, vec![]).unwrap(),
            },
            &inspection,
            20,
            &b,
        )
        .unwrap();
        assert_eq!(unavailable.data_quality, trace);
    }
    #[test]
    fn named_agent_filter_budget_is_distinct_from_raw_store_name_budget() {
        let q = TraceSliceQuery {
            range: TraceTimeRange::query(0, 1000).unwrap(),
            event_key: None,
            process_key: None,
            pid: None,
            thread_key: None,
            tid: None,
            name: Some(format!("{}a", "界".repeat(85))),
            name_match: arktrace_contract::DirectoryNameMatch::Contains,
            minimum_duration_ns: None,
            depth: None,
            unattributed_only: false,
            includes_argument_set: false,
            limit: 1,
        };
        validate_named_agent_filters(&q).unwrap();
        let mut too_long = q.clone();
        too_long.name.as_mut().unwrap().push('a');
        too_long.validate().unwrap();
        assert_eq!(
            validate_named_agent_filters(&too_long).unwrap_err().failure,
            EngineFailure::Store(StoreError::InvalidQuery)
        );
        for change in 0..6 {
            let mut bad = q.clone();
            match change {
                0 => bad.name = None,
                1 => bad.name = Some(String::new()),
                2 => bad.pid = Some(-1),
                3 => bad.tid = Some(-1),
                4 => {
                    bad.pid = Some(2);
                    bad.process_key = Some(-10);
                }
                _ => {
                    bad.tid = Some(3);
                    bad.thread_key = Some(-11);
                }
            }
            assert!(validate_named_agent_filters(&bad).is_err());
        }
        let raw = TraceSliceQuery {
            name: Some("é".repeat(2048)),
            ..q.clone()
        };
        raw.validate().unwrap();
        assert!(validate_named_agent_filters(&raw).is_err());
        validate_named_agent_filters(&TraceSliceQuery {
            name: None,
            name_match: arktrace_contract::DirectoryNameMatch::Exact,
            ..q
        })
        .unwrap();
    }
    #[test]
    fn analysis_scope_preserves_stable_keys_and_rejects_property_conflicts() {
        AnalysisScope {
            process_key: Some(-9_007_199_254_740_993),
            thread_key: Some(i64::MAX),
            ..AnalysisScope::default()
        }
        .validate()
        .unwrap();
        for scope in [
            AnalysisScope {
                process_key: Some(0),
                ..AnalysisScope::default()
            },
            AnalysisScope {
                thread_key: Some(0),
                ..AnalysisScope::default()
            },
            AnalysisScope {
                pid: Some(-1),
                ..AnalysisScope::default()
            },
            AnalysisScope {
                tid: Some(-1),
                ..AnalysisScope::default()
            },
            AnalysisScope {
                process_key: Some(1),
                pid: Some(1),
                ..AnalysisScope::default()
            },
            AnalysisScope {
                thread_key: Some(1),
                tid: Some(1),
                ..AnalysisScope::default()
            },
        ] {
            assert_eq!(
                scope.validate().unwrap_err().public_error().code(),
                arktrace_contract::Code::InvalidArgument
            );
        }
        assert!(serde_json::from_str::<AnalysisScope>(r#"{"cpu":1}"#).is_err());
    }

    fn budget() -> EngineBudget {
        EngineBudget {
            maximum_source_bytes: 1024,
            maximum_database_bytes: 1024,
            deadline: Instant::now() + Duration::from_secs(5),
            cancellation: CancellationToken::default(),
        }
    }
    fn inspection() -> DatabaseInspection {
        DatabaseInspection {
            capabilities: TraceCapabilities {
                cpu_scheduling: true,
                thread_states: true,
                named_slices: false,
                cpu_counters: false,
                process_counters: false,
            },
            schema_fingerprint: "0".repeat(64),
            trace_start_ts: 1000,
            trace_end_ts: 2000,
            duration_ns: 1000,
            data_quality: DataQuality::machine(
                QualityStatus::Warnings,
                vec![QualityIssue {
                    category: QualityCategory::ProbeTruncated,
                    scope: Some("sched_slice.ts".to_owned()),
                    count: None,
                    message: None,
                }],
            )
            .unwrap(),
            event_source_counts_available: false,
            cpu_counter_sample_tables: Vec::new(),
            process_counter_sample_tables: Vec::new(),
        }
    }
    #[test]
    fn agent_composition_orders_clamped_times_and_retains_store_quality() {
        let inspection = inspection();
        let page = EventPage {
            items: vec![(0_i64, 5_i64), (0, 2), (100, 1)],
            truncated: true,
            capability_available: true,
            data_quality: inspection.data_quality.clone(),
        };
        let result = compose_event_page(page, &inspection, &budget(), |v| *v).unwrap();
        assert_eq!(result.items, [(0, 2), (0, 5), (100, 1)]);
        assert_eq!(result.data_quality, inspection.data_quality);
        assert!(result.truncated && result.capability_available);
        let page = EventPage::<(i64, i64)> {
            items: Vec::new(),
            truncated: false,
            capability_available: false,
            data_quality: DataQuality::machine(QualityStatus::Ok, Vec::new()).unwrap(),
        };
        let result = compose_event_page(page, &inspection, &budget(), |v| *v).unwrap();
        assert_eq!(result.data_quality, inspection.data_quality);
        assert!(!result.truncated && !result.capability_available);
    }
    #[test]
    fn agent_request_bounds_apply_even_when_view_unavailable() {
        let range = TraceTimeRange::query(0, 1000).unwrap();
        for (range, limit, process, thread, raw) in [
            (TraceTimeRange::event(0, 0).unwrap(), 1, None, None, None),
            (TraceTimeRange::query(0, 1001).unwrap(), 1, None, None, None),
            (range, usize::MAX, None, None, None),
            (range, 1, Some(0), None, None),
            (range, 1, None, Some(0), None),
            (range, 1, None, None, Some("")),
        ] {
            assert_eq!(
                validate_event_request(range, limit, process, thread, raw, 1000)
                    .unwrap_err()
                    .failure,
                EngineFailure::Store(StoreError::InvalidQuery)
            );
        }
        validate_event_request(range, 1, Some(-10), Some(-11), Some("R"), 1000).unwrap();
        let page = EventPage::<(i64, i64)> {
            items: Vec::new(),
            truncated: false,
            capability_available: false,
            data_quality: DataQuality::machine(QualityStatus::Ok, Vec::new()).unwrap(),
        };
        let request = budget();
        request.cancellation.cancel();
        assert_eq!(
            compose_event_page(page, &inspection(), &request, |v| *v)
                .unwrap_err()
                .failure,
            EngineFailure::Host(HostError::Cancelled)
        );
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub enum NoCacheRecoveryOutcome {
    Owner(OwnerRecoveryOutcome),
    Rejected(EngineFailure),
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NoCacheRecoveryRow {
    pub owner_identifier: String,
    pub outcome: NoCacheRecoveryOutcome,
}

/// Explicit recovery for the isolated temporary namespace. Live key/entry/owner
/// locks never block this maintenance call; their entries are retained. Invalid
/// metadata and unresolved identities retain proof and yield closed outcomes.
/// This does not implement persistent-cache eviction or legacy Swift recovery.
pub fn recover_no_cache(
    namespace: &HeldDirectory,
    budget: &EngineBudget,
) -> Result<Vec<NoCacheRecoveryRow>, EngineError> {
    budget.check().map_err(|error| EngineError {
        stage: EngineStage::Recovering,
        ..error
    })?;
    let io = budget.io(budget.maximum_database_bytes);
    let stage = namespace
        .ensure_private_child(".staging")
        .map_err(|e| host(EngineStage::Recovering, e))?;
    let locks = namespace
        .ensure_private_child(".locks")
        .map_err(|e| host(EngineStage::Recovering, e))?;
    let owners =
        OwnerStore::open(&stage, namespace).map_err(|e| host(EngineStage::Recovering, e))?;
    let mut identifiers = owners
        .identifiers(&io)
        .map_err(|e| host(EngineStage::Recovering, e))?;
    identifiers.sort();
    let mut rows = Vec::with_capacity(identifiers.len());
    for identifier in identifiers {
        io.check().map_err(|e| host(EngineStage::Recovering, e))?;
        let result = (|| -> Result<OwnerRecoveryOutcome, EngineFailure> {
            let Some(published) = owners
                .published_evidence(&identifier, &io)
                .map_err(EngineFailure::Host)?
            else {
                return owners
                    .recover_stale(&identifier, &io)
                    .map_err(EngineFailure::Host);
            };
            let mut metadata_file = None;
            let key_identifier = if published.requires_metadata() {
                let Some(directory) = owners
                    .locate_published(&published, &io)
                    .map_err(EngineFailure::Host)?
                else {
                    return Ok(OwnerRecoveryOutcome::IdentityUnresolved);
                };
                directory
                    .require_file_membership(&["trace.db", "metadata.json"], &io)
                    .map_err(EngineFailure::Host)?;
                let file = directory
                    .open_file("metadata.json")
                    .map_err(EngineFailure::Host)?;
                let encoded = file
                    .read_bounded(&budget.io(MAXIMUM_METADATA_BYTES as u64))
                    .map_err(EngineFailure::Host)?;
                let metadata =
                    CacheMetadata::decode(&encoded).map_err(|_| EngineFailure::InvalidMetadata)?;
                let key = metadata.cache_key.entry_identifier();
                if published
                    .key_identifier()
                    .is_some_and(|expected| expected != key)
                {
                    return Err(EngineFailure::InvalidMetadata);
                }
                metadata_file = Some(file);
                key
            } else {
                published
                    .key_identifier()
                    .ok_or(EngineFailure::InvalidMetadata)?
                    .into()
            };
            let Some(key_lease) = Lease::try_acquire(
                &locks,
                &format!("{key_identifier}.lock"),
                LeaseMode::Exclusive,
                false,
            )
            .map_err(EngineFailure::Host)?
            else {
                return Ok(OwnerRecoveryOutcome::Active);
            };
            owners
                .recover_ephemeral_ready(&published, &key_lease, metadata_file.as_ref(), &io)
                .map_err(EngineFailure::Host)
        })();
        rows.push(NoCacheRecoveryRow {
            owner_identifier: identifier,
            outcome: match result {
                Ok(outcome) => NoCacheRecoveryOutcome::Owner(outcome),
                Err(error) => NoCacheRecoveryOutcome::Rejected(error),
            },
        });
    }
    Ok(rows)
}

/// Native temporary namespace must be private and isolated from old writers.
/// Each no-cache Ready gets a fresh session name and exclusive active lease;
/// parallel sessions never share their output or publication name.
pub fn open_no_cache(
    source: &HeldFile,
    format: SourceFormat,
    tools: &ParserTools<'_>,
    temporary_namespace: &HeldDirectory,
    budget: &EngineBudget,
    mut report: impl FnMut(EngineProgress),
) -> Result<NoCacheSession, EngineError> {
    budget.check()?;
    tools
        .identity
        .validate()
        .map_err(|_| failure(EngineStage::ParserIdentity, EngineFailure::InvalidIdentity))?;
    if tools.identity.binary_sha256 != tools.parser.sha256()
        || tools.identity.adapter_version != arktrace_contract::PARSER_ADAPTER_VERSION
        || tools.identity.architecture != "arm64"
    {
        return Err(failure(
            EngineStage::ParserIdentity,
            EngineFailure::InvalidIdentity,
        ));
    }
    let source_io = budget.io(budget.maximum_source_bytes);
    report(EngineProgress::SourceSnapshot);
    let original = source
        .facts(&source_io)
        .map_err(|e| host(EngineStage::SourceSnapshot, e))?;
    if original.byte_count == 0 {
        return Err(failure(
            EngineStage::SourceSnapshot,
            EngineFailure::InvalidMetadata,
        ));
    }
    let key = TraceCacheKey::new(
        &original.sha256,
        &tools.identity.binary_sha256,
        &tools.identity.upstream_revision,
        arktrace_contract::SCHEMA_ADAPTER_VERSION,
        i64::from(arktrace_contract::INDEX_SCHEMA_VERSION),
    )
    .map_err(|_| failure(EngineStage::SourceSnapshot, EngineFailure::InvalidIdentity))?;
    let setup = |name| {
        temporary_namespace
            .ensure_private_child(name)
            .map_err(|e| host(EngineStage::SourceSnapshot, e))
    };
    let stage = setup(".staging")?;
    let ready = setup(".ready")?;
    let locks = setup(".locks")?;
    let leases = setup(".leases")?;
    let owners = OwnerStore::open(&stage, temporary_namespace)
        .map_err(|e| host(EngineStage::SourceSnapshot, e))?;
    let key_lock = Lease::acquire(
        &locks,
        &format!("{}.lock", key.entry_identifier()),
        LeaseMode::Exclusive,
        &source_io,
    )
    .map_err(|e| host(EngineStage::SourceSnapshot, e))?;
    let mut input = owners
        .create(OwnerKind::Session, &source_io)
        .map_err(|e| host(EngineStage::SourceSnapshot, e))?;
    // The private input session allocates the unique no-cache lease name. The
    // candidate owner's lock is taken only after key and entry authority exist.
    let mut active_lease = None::<EphemeralLease>;
    let mut building = None::<OwnedDirectory>;
    let result = (|| {
        active_lease = Some(
            EphemeralLease::acquire(
                &leases,
                &format!("{}.lease", input.identifier()),
                &source_io,
            )
            .map_err(|e| host(EngineStage::SourceSnapshot, e))?,
        );
        let lease = active_lease
            .as_ref()
            .ok_or_else(|| failure(EngineStage::SourceSnapshot, EngineFailure::CleanupFailed))?;
        building = Some(
            owners
                .create(OwnerKind::Building, &source_io)
                .map_err(|e| host(EngineStage::SourceSnapshot, e))?,
        );
        building
            .as_mut()
            .ok_or_else(|| failure(EngineStage::SourceSnapshot, EngineFailure::CleanupFailed))?
            .bind_ephemeral(lease, &key_lock, &source_io)
            .map_err(|e| host(EngineStage::SourceSnapshot, e))?;
        let directory = input.directory();
        let (snapshot, copied) = directory
            .copy_snapshot(source, format.name(), false, &source_io)
            .map_err(|e| host(EngineStage::SourceSnapshot, e))?;
        if copied != original {
            return Err(failure(
                EngineStage::SourceSnapshot,
                EngineFailure::InvalidIdentity,
            ));
        }
        report(EngineProgress::ParserIdentity);
        let version = run_supervised(
            tools.helper,
            tools.parser,
            directory,
            &[OsString::from("--version")],
            &budget.process(),
        )
        .map_err(|e| failure(EngineStage::ParserIdentity, EngineFailure::Process(e)))?;
        let version_text =
            String::from_utf8([version.stdout, version.stderr].concat()).map_err(|_| {
                failure(
                    EngineStage::ParserIdentity,
                    EngineFailure::ParserVersionMismatch,
                )
            })?;
        let words = version_text.split_whitespace().collect::<Vec<_>>();
        if version.exit_code != Some(1)
            || version.signal.is_some()
            || !words
                .windows(2)
                .any(|w| w[0] == "version" && w[1] == tools.identity.reported_version)
        {
            return Err(failure(
                EngineStage::ParserIdentity,
                EngineFailure::ParserVersionMismatch,
            ));
        }
        let mut process = budget.process();
        process.output_files = vec![
            ProcessOutputFileBudget {
                name: "partial.db".into(),
                maximum_bytes: budget.maximum_database_bytes,
            },
            ProcessOutputFileBudget {
                name: "partial.db.ohos.ts".into(),
                maximum_bytes: 65_536,
            },
            ProcessOutputFileBudget {
                name: "ts_tmp/unzlib_file.txt".into(),
                maximum_bytes: budget.maximum_source_bytes,
            },
        ];
        report(EngineProgress::Parsing);
        let outcome = run_supervised(
            tools.helper,
            tools.parser,
            directory,
            &[
                snapshot.path().into_os_string(),
                "-e".into(),
                directory.path().join("partial.db").into_os_string(),
                "-nm".into(),
            ],
            &process,
        )
        .map_err(|e| failure(EngineStage::Parsing, EngineFailure::Process(e)))?;
        if outcome.exit_code != Some(0) || outcome.signal.is_some() {
            return Err(failure(
                EngineStage::Parsing,
                EngineFailure::ParserExit {
                    exit_code: outcome.exit_code,
                    signal: outcome.signal,
                },
            ));
        }
        snapshot
            .verify()
            .map_err(|e| host(EngineStage::Validating, e))?;
        let mut expected = vec![format.name(), "partial.db"];
        match directory.open_file("partial.db.ohos.ts") {
            Ok(file) => {
                file.verify()
                    .map_err(|e| host(EngineStage::Validating, e))?;
                expected.push("partial.db.ohos.ts");
            }
            Err(HostError::NotFound) => {}
            Err(e) => return Err(host(EngineStage::Validating, e)),
        }
        let mut auxiliary = Vec::new();
        match directory.open_private_child("ts_tmp") {
            Ok(temporary) => {
                temporary
                    .require_file_membership(&["unzlib_file.txt"], &source_io)
                    .map_err(|e| host(EngineStage::Validating, e))?;
                temporary
                    .open_file("unzlib_file.txt")
                    .map_err(|e| host(EngineStage::Validating, e))?
                    .facts(&source_io)
                    .map_err(|e| host(EngineStage::Validating, e))?;
                auxiliary.push("ts_tmp");
            }
            Err(HostError::NotFound) => {}
            Err(e) => return Err(host(EngineStage::Validating, e)),
        }
        directory
            .require_private_membership(
                &expected,
                &auxiliary,
                &budget.io(budget.maximum_database_bytes),
            )
            .map_err(|e| host(EngineStage::Validating, e))?;
        let partial = directory
            .open_file("partial.db")
            .map_err(|e| host(EngineStage::Validating, e))?;
        let (export, _) = directory
            .copy_snapshot(
                &partial,
                "export.db",
                false,
                &budget.io(budget.maximum_database_bytes),
            )
            .map_err(|e| host(EngineStage::Validating, e))?;
        let candidate = building
            .as_ref()
            .ok_or_else(|| failure(EngineStage::Indexing, EngineFailure::CleanupFailed))?
            .directory()
            .clone();
        let prepared = prepare_snapshot(
            &export,
            &candidate,
            "trace.db",
            &budget.validation(),
            |event| report(EngineProgress::Indexing(event)),
        )
        .map_err(|e| failure(EngineStage::Indexing, EngineFailure::Store(e)))?;
        let preparation = &prepared.preparation;
        let timestamp = utc_from_unix_seconds(
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_err(|_| failure(EngineStage::Validating, EngineFailure::InvalidMetadata))?
                .as_secs(),
        )
        .map_err(|_| failure(EngineStage::Validating, EngineFailure::InvalidMetadata))?;
        let metadata = CacheMetadata {
            format_version: 1,
            cache_key: key.clone(),
            parser: tools.identity.clone(),
            trace_sha256: original.sha256.clone(),
            source_sha256: original.sha256.clone(),
            source_byte_count: original.byte_count as i64,
            schema_fingerprint: preparation.inspection.schema_fingerprint.clone(),
            schema_adapter_version: preparation.schema_adapter_version.clone(),
            index_schema_version: preparation.index_schema_version,
            database_preparation: MetadataPreparation {
                schema_adapter_version: preparation.schema_adapter_version.clone(),
                schema_fingerprint: preparation.inspection.schema_fingerprint.clone(),
                index_version: preparation.index_schema_version,
                upstream_database_sha256: preparation.upstream_database_sha256.clone(),
                upstream_database_byte_count: preparation.upstream_database_byte_count as i64,
            },
            database_byte_count: preparation.prepared_database_byte_count as i64,
            created_at: timestamp.clone(),
            last_accessed_at: timestamp,
        };
        let bytes = metadata
            .encode()
            .map_err(|_| failure(EngineStage::Validating, EngineFailure::InvalidMetadata))?;
        let metadata_snapshot = candidate
            .write_new_readonly(
                "metadata.json",
                &bytes,
                &budget.io(MAXIMUM_METADATA_BYTES as u64),
            )
            .map_err(|e| host(EngineStage::Validating, e))?;
        report(EngineProgress::Validating);
        let inspection = inspect_indexed_snapshot(&prepared.snapshot, &budget.validation())
            .map_err(|e| failure(EngineStage::Validating, EngineFailure::Store(e)))?;
        if inspection.inspection != preparation.inspection
            || inspection.applicable_index_names != preparation.applicable_index_names
        {
            return Err(failure(
                EngineStage::Validating,
                EngineFailure::InvalidMetadata,
            ));
        }
        candidate
            .require_file_membership(
                &["trace.db", "metadata.json"],
                &budget.io(budget.maximum_database_bytes),
            )
            .map_err(|e| host(EngineStage::Validating, e))?;
        let aggregate = budget
            .maximum_database_bytes
            .checked_add(MAXIMUM_METADATA_BYTES as u64)
            .ok_or_else(|| failure(EngineStage::Publishing, EngineFailure::InvalidBudget))?;
        let publication_io = budget.io(aggregate);
        let sealed = candidate
            .seal_readonly_directory(&publication_io)
            .map_err(|e| host(EngineStage::Publishing, e))?;
        report(EngineProgress::Publishing);
        key_lock
            .revalidate()
            .map_err(|e| host(EngineStage::Publishing, e))?;
        lease
            .revalidate()
            .map_err(|e| host(EngineStage::Publishing, e))?;
        building
            .as_mut()
            .ok_or_else(|| failure(EngineStage::Publishing, EngineFailure::CleanupFailed))?
            .prepare_ephemeral_publication(&ready, input.identifier(), &publication_io)
            .map_err(|e| host(EngineStage::Publishing, e))?;
        let published = stage
            .promote_sealed_directory_noreplace(
                &sealed,
                &ready,
                input.identifier(),
                &publication_io,
            )
            .map_err(|e| host(EngineStage::Publishing, e))?;
        building
            .as_mut()
            .ok_or_else(|| failure(EngineStage::Publishing, EngineFailure::CleanupFailed))?
            .record_published_location(&published, &publication_io)
            .map_err(|e| host(EngineStage::Publishing, e))?;
        report(EngineProgress::OpeningDatabase);
        let database = published
            .open_file("trace.db")
            .map_err(|e| host(EngineStage::Validating, e))?;
        let metadata_file = published
            .open_file("metadata.json")
            .map_err(|e| host(EngineStage::Validating, e))?;
        if database.snapshot() != prepared.snapshot.snapshot()
            || metadata_file.snapshot() != metadata_snapshot.snapshot()
        {
            return Err(failure(
                EngineStage::Validating,
                EngineFailure::InvalidMetadata,
            ));
        }
        let loaded = CacheMetadata::decode(
            &metadata_file
                .read_bounded(&budget.io(MAXIMUM_METADATA_BYTES as u64))
                .map_err(|e| host(EngineStage::Validating, e))?,
        )
        .map_err(|_| failure(EngineStage::Validating, EngineFailure::InvalidMetadata))?;
        if loaded != metadata
            || database
                .facts(&budget.io(budget.maximum_database_bytes))
                .map_err(|e| host(EngineStage::Validating, e))?
                .sha256
                != preparation.prepared_database_sha256
            || source
                .facts(&source_io)
                .map_err(|e| host(EngineStage::Validating, e))?
                != original
        {
            return Err(failure(
                EngineStage::Validating,
                EngineFailure::InvalidMetadata,
            ));
        }
        let database = Arc::new(database);
        let reader = StoreReader::open(database.clone(), &budget.validation())
            .map_err(|e| failure(EngineStage::Validating, EngineFailure::Store(e)))?;
        if reader.indexed_inspection() != &inspection {
            return Err(failure(
                EngineStage::Validating,
                EngineFailure::InvalidMetadata,
            ));
        }
        input
            .cleanup(&budget.cleanup())
            .map_err(|_| failure(EngineStage::Closing, EngineFailure::CleanupFailed))?;
        database
            .verify()
            .map_err(|e| host(EngineStage::Publishing, e))?;
        metadata_file
            .verify()
            .map_err(|e| host(EngineStage::Publishing, e))?;
        key_lock
            .revalidate()
            .map_err(|e| host(EngineStage::Publishing, e))?;
        lease
            .revalidate()
            .map_err(|e| host(EngineStage::Publishing, e))?;
        publication_io
            .check()
            .map_err(|e| host(EngineStage::Publishing, e))?;
        let owner = building
            .take()
            .ok_or_else(|| failure(EngineStage::Publishing, EngineFailure::CleanupFailed))?;
        // No suspensions/IO after final cancellation and identity check. Report
        // is outside the transaction; a caller panic retains recoverable proof.
        Ok(NoCacheSession {
            owner,
            lease: active_lease
                .take()
                .ok_or_else(|| failure(EngineStage::Publishing, EngineFailure::CleanupFailed))?,
            database: Some(database),
            reader: Some(reader),
            metadata_file: Some(metadata_file),
            metadata,
            inspection: inspection.inspection,
            cleanup_bytes: aggregate,
            query_worker_failed: Cell::new(false),
            viewer: RefCell::default(),
        })
    })();
    match result {
        Ok(session) => {
            drop(key_lock);
            report(EngineProgress::Ready);
            Ok(session)
        }
        Err(error) => {
            let cleanup = budget.cleanup();
            let candidate_cleanup = building
                .as_mut()
                .map_or(Ok(()), |owner| owner.cleanup(&cleanup));
            let input_cleanup = input.cleanup(&cleanup);
            if candidate_cleanup.is_err() || input_cleanup.is_err() {
                return Err(failure(error.stage, EngineFailure::CleanupFailed));
            }
            let lease_cleanup = match (active_lease.take(), building.as_mut()) {
                (Some(lease), Some(owner)) => owner.finish_ephemeral_cleanup(lease, &cleanup),
                (Some(lease), None) => lease.remove(),
                (None, _) => Ok(()),
            };
            if lease_cleanup.is_err() {
                return Err(failure(error.stage, EngineFailure::CleanupFailed));
            }
            Err(error)
        }
    }
}
