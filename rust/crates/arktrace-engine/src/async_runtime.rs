//! Nonblocking host front end; all parser, SQLite and cleanup work stays on
//! a fixed set of owner threads. This is the actual no-cache Engine path,
//! not an SDK ABI or persistent-cache implementation.
use crate::{
    EngineBudget, EngineError, EngineFailure, EngineProgress, EngineStage, HandleError,
    NoCacheSession, OwnedResult, ParserTools, ReadPoolLimits, RuntimeHandle, SourceFormat,
    handles::HandleTable,
    open_no_cache,
    owned_result::{self, ResultBudget},
    recover_no_cache,
};
use arktrace_contract::*;
use arktrace_platform::{
    CancellationToken, CodeTrustPolicy, HeldDirectory, HeldFile, IoBudget, OwnedDirectory,
    OwnerKind, OwnerRecoveryOutcome, OwnerStore, VerifiedExecutable,
};
use serde::Serialize;
use std::{
    collections::HashMap,
    panic::{AssertUnwindSafe, catch_unwind},
    path::PathBuf,
    sync::{
        Arc, Mutex, MutexGuard, TryLockError,
        atomic::{AtomicBool, AtomicUsize, Ordering},
        mpsc::{self, Receiver, SyncSender, TrySendError},
    },
    thread,
    time::{Duration, Instant},
};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub enum RuntimeFailure {
    InvalidHandle,
    Busy,
    Capacity,
    InvalidRequest,
    Closed,
    Cancelled,
    WorkerPanicked,
    OutputLimit,
    Engine(EngineError),
}
impl From<HandleError> for RuntimeFailure {
    fn from(e: HandleError) -> Self {
        match e {
            HandleError::Invalid => Self::InvalidHandle,
            HandleError::Exhausted => Self::Capacity,
        }
    }
}
impl std::fmt::Display for RuntimeFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for RuntimeFailure {}
impl RuntimeFailure {
    /// Busy/Capacity are typed front-end admission outcomes. They have no
    /// terminal machine error; the future ABI must preserve that distinction.
    pub fn public_error(self) -> Option<PublicError> {
        Some(match self {
            Self::Busy | Self::Capacity => return None,
            Self::Engine(e) => e.public_error(),
            Self::Cancelled => PublicError::new(Code::Cancelled, Stage::Request),
            Self::WorkerPanicked => PublicError::new(Code::InternalError, Stage::Request),
            Self::OutputLimit => PublicError::new(Code::OutputLimitExceeded, Stage::Encoding),
            _ => PublicError::new(Code::InvalidArgument, Stage::Request),
        })
    }
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub enum SessionState {
    Opening,
    Ready,
    Cancelling,
    Closing,
    Failed,
    Closed,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub enum RequestState {
    Queued,
    Running,
    Cancelling,
    Succeeded,
    Failed,
}
impl RequestState {
    fn terminal(self) -> bool {
        matches!(self, Self::Succeeded | Self::Failed)
    }
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RequestStatus {
    pub session: RuntimeHandle,
    pub state: RequestState,
    pub progress: Option<EngineProgress>,
    pub failure: Option<RuntimeFailure>,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionStatus {
    pub state: SessionState,
    pub resources_closed: bool,
    pub close_failure: Option<RuntimeFailure>,
    pub residue_owner: Option<String>,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct OpenTicket {
    pub session: RuntimeHandle,
    pub request: RuntimeHandle,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DrainStatus {
    Running,
    Draining,
    Drained,
}

#[derive(Clone, Copy, Debug)]
pub struct RuntimeLimits {
    pub workers: usize,
    pub sessions: usize,
    pub requests: usize,
    pub queue_per_worker: usize,
    pub maximum_result_bytes: usize,
    pub maximum_retained_result_bytes: usize,
    pub maximum_source_bytes: u64,
    pub maximum_database_bytes: u64,
}
impl Default for RuntimeLimits {
    fn default() -> Self {
        Self {
            workers: 2,
            sessions: 8,
            requests: 64,
            queue_per_worker: 16,
            maximum_result_bytes: 16 * 1024 * 1024,
            maximum_retained_result_bytes: 128 * 1024 * 1024,
            maximum_source_bytes: 2 * 1024 * 1024 * 1024,
            maximum_database_bytes: 2 * 1024 * 1024 * 1024,
        }
    }
}
impl RuntimeLimits {
    fn validate(self) -> Result<(), RuntimeFailure> {
        if !(1..=4).contains(&self.workers)
            || !(1..=8).contains(&self.sessions)
            || !(1..=128).contains(&self.requests)
            || !(1..=64).contains(&self.queue_per_worker)
            || !(1..=16 * 1024 * 1024).contains(&self.maximum_result_bytes)
            || !(1..=256 * 1024 * 1024).contains(&self.maximum_retained_result_bytes)
            || self.maximum_source_bytes == 0
            || self.maximum_database_bytes == 0
            || self.maximum_source_bytes > i64::MAX as u64
            || self.maximum_database_bytes > i64::MAX as u64
        {
            return Err(RuntimeFailure::InvalidRequest);
        }
        Ok(())
    }
}
/// Fixed product/engine configuration, never supplied in a repository request.
#[derive(Clone)]
pub struct RuntimeConfiguration {
    pub namespace: PathBuf,
    pub helper: PathBuf,
    pub parser: PathBuf,
    pub helper_sha256: String,
    pub parser_identity: TraceParserIdentity,
    pub trust: CodeTrustPolicy,
    pub limits: RuntimeLimits,
    #[cfg(feature = "process-fixtures")]
    fault: Option<Arc<dyn Fn(WorkerBoundary) + Send + Sync>>,
}
impl RuntimeConfiguration {
    pub fn new(
        namespace: PathBuf,
        helper: PathBuf,
        parser: PathBuf,
        helper_sha256: String,
        parser_identity: TraceParserIdentity,
        trust: CodeTrustPolicy,
    ) -> Self {
        Self {
            namespace,
            helper,
            parser,
            helper_sha256,
            parser_identity,
            trust,
            limits: RuntimeLimits::default(),
            #[cfg(feature = "process-fixtures")]
            fault: None,
        }
    }
    #[cfg(feature = "process-fixtures")]
    #[doc(hidden)]
    pub fn observe_worker_for_fixture(
        mut self,
        observer: Arc<dyn Fn(WorkerBoundary) + Send + Sync>,
    ) -> Self {
        self.fault = Some(observer);
        self
    }
    fn validate(&self) -> Result<(), RuntimeFailure> {
        self.limits.validate()?;
        self.parser_identity
            .validate()
            .map_err(|_| RuntimeFailure::InvalidRequest)?;
        for path in [&self.namespace, &self.helper, &self.parser] {
            validate_path(path)?;
        }
        if self.helper_sha256.len() != 64
            || !self
                .helper_sha256
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(RuntimeFailure::InvalidRequest);
        }
        Ok(())
    }
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WorkerBoundary {
    Opening,
    Opened,
    OpeningDrained,
    Querying,
    Closing,
}
fn observe(config: &RuntimeConfiguration, boundary: WorkerBoundary) {
    #[cfg(feature = "process-fixtures")]
    if let Some(observer) = &config.fault {
        observer(boundary);
    }
    #[cfg(not(feature = "process-fixtures"))]
    let _ = (config, boundary);
}
fn validate_path(path: &std::path::Path) -> Result<(), RuntimeFailure> {
    if !path.is_absolute() || path.as_os_str().as_encoded_bytes().len() > 4096 {
        Err(RuntimeFailure::InvalidRequest)
    } else {
        Ok(())
    }
}
/// Existing bounded typed operations; no SQL, callbacks or storage/tool paths.
#[derive(Clone, Debug)]
pub enum RepositoryRequest {
    Processes(ProcessQuery),
    Threads(ThreadQuery),
    CpuSlices(CpuSliceQuery),
    ThreadStates(ThreadStateQuery),
    Slices(TraceSliceQuery),
    Counters(CounterQuery),
    CounterSeries(CounterSeriesQuery),
    Frames(TraceFrameQuery),
    Arguments(TraceArgumentQuery),
    Density(TraceDensityQuery),
    ViewerDetails {
        source: arktrace_contract::TraceDensitySource,
        range: arktrace_contract::TraceTimeRange,
        limit: usize,
    },
    Batch(TraceRepositoryEventBatch),
    Search(TraceSearchRequest),
    Analyze {
        request: crate::BoundedAnalysisRequest,
        scope: crate::AnalysisScope,
    },
}
impl RepositoryRequest {
    fn validate(&self) -> Result<(), RuntimeFailure> {
        let value = match self {
            Self::Processes(q) => q.validate(),
            Self::Threads(q) => q.validate(),
            Self::CpuSlices(q) => q.validate(),
            Self::ThreadStates(q) => q.validate(),
            Self::Slices(q) => q.validate(),
            Self::Counters(q) => q.validate(),
            Self::CounterSeries(q) => q.validate(),
            Self::Frames(q) => q.validate(),
            Self::Arguments(q) => q.validate(),
            Self::Density(q) => q.validate(),
            Self::ViewerDetails {
                source,
                range,
                limit,
            } => {
                return arktrace_viewer::detail_query(source, *range, *limit)
                    .map(|_| ())
                    .map_err(|_| RuntimeFailure::InvalidRequest);
            }
            Self::Batch(q) => q.validate(),
            Self::Search(q) => q.validate(),
            Self::Analyze { request, scope } => {
                return request
                    .validate()
                    .map_err(|_| RuntimeFailure::InvalidRequest)
                    .and_then(|()| scope.validate().map_err(|_| RuntimeFailure::InvalidRequest));
            }
        };
        value.map_err(|_| RuntimeFailure::InvalidRequest)
    }
}
struct SessionRecord {
    worker: usize,
    status: SessionStatus,
    close_queued: bool,
}
struct RequestRecord {
    status: RequestStatus,
    token: CancellationToken,
    result: Option<OwnedResult>,
}
enum Record {
    Session(SessionRecord),
    Request(RequestRecord),
}
struct Registry {
    table: HandleTable<Record>,
    queued: Vec<usize>,
    next_worker: usize,
}
struct Shared {
    registry: Mutex<Registry>,
    stopping: AtomicBool,
    alive: AtomicUsize,
    result_budget: Arc<ResultBudget>,
}
struct Command {
    session: RuntimeHandle,
    request: Option<RuntimeHandle>,
    budget: EngineBudget,
    operation: Operation,
}
enum Operation {
    Open {
        source: PathBuf,
        format: SourceFormat,
    },
    Query(Box<RepositoryRequest>),
    Close,
}
/// All front-end methods use try-lock/try-send; they never wait for IO, SQL,
/// worker completion or a publication lock. Explicit drain is polled. Drop
/// only signals fallback shutdown; owner threads perform cleanup.
pub struct AsyncEngine {
    shared: Arc<Shared>,
    senders: Vec<SyncSender<Command>>,
    limits: RuntimeLimits,
}
impl AsyncEngine {
    pub fn create(configuration: RuntimeConfiguration) -> Result<Self, RuntimeFailure> {
        configuration.validate()?;
        let limits = configuration.limits;
        let shared = Arc::new(Shared {
            registry: Mutex::new(Registry {
                table: HandleTable::new(limits.requests + limits.sessions)?,
                queued: vec![0; limits.workers],
                next_worker: 0,
            }),
            stopping: AtomicBool::new(false),
            alive: AtomicUsize::new(0),
            result_budget: ResultBudget::new(limits.maximum_retained_result_bytes),
        });
        let mut senders = Vec::new();
        for index in 0..limits.workers {
            let (sender, receiver) = mpsc::sync_channel(limits.queue_per_worker + limits.sessions);
            shared.alive.fetch_add(1, Ordering::AcqRel);
            let worker_shared = shared.clone();
            let worker_configuration = configuration.clone();
            if thread::Builder::new()
                .name(format!("arktrace-session-{index}"))
                .spawn(move || run_worker(receiver, worker_shared, worker_configuration, index))
                .is_err()
            {
                shared.alive.fetch_sub(1, Ordering::AcqRel);
                shared.stopping.store(true, Ordering::Release);
                return Err(RuntimeFailure::WorkerPanicked);
            }
            senders.push(sender);
        }
        Ok(Self {
            shared,
            senders,
            limits,
        })
    }
    fn registry(&self) -> Result<MutexGuard<'_, Registry>, RuntimeFailure> {
        match self.shared.registry.try_lock() {
            Ok(registry) => Ok(registry),
            Err(TryLockError::WouldBlock) => Err(RuntimeFailure::Busy),
            Err(TryLockError::Poisoned(_)) => Err(RuntimeFailure::WorkerPanicked),
        }
    }
    fn check_running(&self) -> Result<(), RuntimeFailure> {
        if self.shared.stopping.load(Ordering::Acquire) {
            Err(RuntimeFailure::Closed)
        } else {
            Ok(())
        }
    }
    fn budget(&self, timeout: Duration) -> Result<EngineBudget, RuntimeFailure> {
        if timeout.is_zero() || timeout > Duration::from_secs(300) {
            return Err(RuntimeFailure::InvalidRequest);
        }
        Ok(EngineBudget {
            maximum_source_bytes: self.limits.maximum_source_bytes,
            maximum_database_bytes: self.limits.maximum_database_bytes,
            deadline: Instant::now()
                .checked_add(timeout)
                .ok_or(RuntimeFailure::InvalidRequest)?,
            cancellation: CancellationToken::default(),
        })
    }
    pub fn open(
        &self,
        source: PathBuf,
        format: SourceFormat,
        timeout: Duration,
    ) -> Result<OpenTicket, RuntimeFailure> {
        validate_path(&source)?;
        self.check_running()?;
        let budget = self.budget(timeout)?;
        let mut registry = self.registry()?;
        self.check_running()?;
        if registry
            .table
            .values()
            .filter(|r| matches!(r, Record::Session(_)))
            .count()
            >= self.limits.sessions
        {
            return Err(RuntimeFailure::Capacity);
        }
        let worker = registry.next_worker;
        if registry.queued[worker] >= self.limits.queue_per_worker {
            return Err(RuntimeFailure::Capacity);
        }
        let session = registry.table.insert(Record::Session(SessionRecord {
            worker,
            status: SessionStatus {
                state: SessionState::Opening,
                resources_closed: false,
                close_failure: None,
                residue_owner: None,
            },
            close_queued: false,
        }))?;
        let request = match self.enqueue(
            &mut registry,
            worker,
            session,
            budget,
            Operation::Open { source, format },
        ) {
            Ok(request) => request,
            Err(e) => {
                registry.table.remove(session)?;
                return Err(e);
            }
        };
        registry.next_worker = (worker + 1) % self.limits.workers;
        Ok(OpenTicket { session, request })
    }
    fn enqueue(
        &self,
        registry: &mut Registry,
        worker: usize,
        session: RuntimeHandle,
        budget: EngineBudget,
        operation: Operation,
    ) -> Result<RuntimeHandle, RuntimeFailure> {
        if registry
            .table
            .values()
            .filter(|r| matches!(r, Record::Request(_)))
            .count()
            >= self.limits.requests
        {
            return Err(RuntimeFailure::Capacity);
        }
        let request = registry.table.insert(Record::Request(RequestRecord {
            status: RequestStatus {
                session,
                state: RequestState::Queued,
                progress: None,
                failure: None,
            },
            token: budget.cancellation.clone(),
            result: None,
        }))?;
        match self.senders[worker].try_send(Command {
            session,
            request: Some(request),
            budget,
            operation,
        }) {
            Ok(()) => {
                registry.queued[worker] += 1;
                Ok(request)
            }
            Err(error) => {
                registry.table.remove(request)?;
                Err(match error {
                    TrySendError::Full(_) => RuntimeFailure::Capacity,
                    TrySendError::Disconnected(_) => RuntimeFailure::WorkerPanicked,
                })
            }
        }
    }
    pub fn submit(
        &self,
        session: RuntimeHandle,
        request: RepositoryRequest,
        timeout: Duration,
    ) -> Result<RuntimeHandle, RuntimeFailure> {
        request.validate()?;
        self.check_running()?;
        let budget = self.budget(timeout)?;
        let mut registry = self.registry()?;
        self.check_running()?;
        let worker = match registry.table.get(session)? {
            Record::Session(s) if s.status.state == SessionState::Ready => s.worker,
            Record::Session(_) => return Err(RuntimeFailure::Closed),
            _ => return Err(RuntimeFailure::InvalidHandle),
        };
        if registry.queued[worker] >= self.limits.queue_per_worker {
            return Err(RuntimeFailure::Capacity);
        }
        self.enqueue(
            &mut registry,
            worker,
            session,
            budget,
            Operation::Query(Box::new(request)),
        )
    }
    pub fn poll(&self, request: RuntimeHandle) -> Result<RequestStatus, RuntimeFailure> {
        let registry = self.registry()?;
        match registry.table.get(request)? {
            Record::Request(r) => Ok(r.status.clone()),
            _ => Err(RuntimeFailure::InvalidHandle),
        }
    }
    pub fn session_status(&self, session: RuntimeHandle) -> Result<SessionStatus, RuntimeFailure> {
        let registry = self.registry()?;
        match registry.table.get(session)? {
            Record::Session(s) => Ok(s.status.clone()),
            _ => Err(RuntimeFailure::InvalidHandle),
        }
    }
    pub fn acquire_result(&self, request: RuntimeHandle) -> Result<OwnedResult, RuntimeFailure> {
        let registry = self.registry()?;
        match registry.table.get(request)? {
            Record::Request(r) => r
                .result
                .clone()
                .ok_or_else(|| r.status.failure.unwrap_or(RuntimeFailure::Busy)),
            _ => Err(RuntimeFailure::InvalidHandle),
        }
    }
    pub fn cancel(&self, request: RuntimeHandle) -> Result<(), RuntimeFailure> {
        let mut registry = self.registry()?;
        match registry.table.get_mut(request)? {
            Record::Request(r) => {
                if r.status.state.terminal() {
                    return Ok(());
                }
                if !r.token.try_cancel() {
                    return Err(RuntimeFailure::Busy);
                }
                r.status.state = RequestState::Cancelling;
                Ok(())
            }
            _ => Err(RuntimeFailure::InvalidHandle),
        }
    }
    /// Schedules resource cleanup using reserved control capacity. No request
    /// handle or result allocation is needed. Poll `session_status` until
    /// `resources_closed`; inspect `close_failure` before releasing the handle.
    pub fn close(&self, session: RuntimeHandle) -> Result<(), RuntimeFailure> {
        let budget = self.budget(Duration::from_secs(30))?;
        let mut registry = self.registry()?;
        let worker = match registry.table.get(session)? {
            Record::Session(s) if s.status.resources_closed => {
                let Record::Session(s) = registry.table.get_mut(session)? else {
                    return Err(RuntimeFailure::InvalidHandle);
                };
                if s.status.close_failure.is_none() {
                    s.status.state = SessionState::Closed;
                }
                return Ok(());
            }
            Record::Session(s) if s.close_queued => return Ok(()),
            Record::Session(s) => s.worker,
            _ => return Err(RuntimeFailure::InvalidHandle),
        };
        if !self.shared.stopping.load(Ordering::Acquire) {
            self.senders[worker]
                .try_send(Command {
                    session,
                    request: None,
                    budget,
                    operation: Operation::Close,
                })
                .map_err(|e| match e {
                    TrySendError::Full(_) => RuntimeFailure::Capacity,
                    TrySendError::Disconnected(_) => RuntimeFailure::WorkerPanicked,
                })?;
        }
        let Record::Session(s) = registry.table.get_mut(session)? else {
            return Err(RuntimeFailure::InvalidHandle);
        };
        s.close_queued = true;
        s.status.state = if s.status.state == SessionState::Opening {
            SessionState::Cancelling
        } else {
            SessionState::Closing
        };
        for record in registry.table.values_mut() {
            if let Record::Request(r) = record
                && r.status.session == session
                && !r.status.state.terminal()
            {
                r.token.try_cancel();
                r.status.state = RequestState::Cancelling;
            }
        }
        Ok(())
    }
    pub fn release_request(&self, request: RuntimeHandle) -> Result<(), RuntimeFailure> {
        let mut registry = self.registry()?;
        match registry.table.get(request)? {
            Record::Request(r) if r.status.state.terminal() => {}
            Record::Request(_) => return Err(RuntimeFailure::Busy),
            _ => return Err(RuntimeFailure::InvalidHandle),
        };
        registry.table.remove(request)?;
        Ok(())
    }
    pub fn release_session(&self, session: RuntimeHandle) -> Result<(), RuntimeFailure> {
        let mut registry = self.registry()?;
        match registry.table.get(session)? {
            Record::Session(s) if s.status.resources_closed && !s.close_queued => {}
            Record::Session(_) => return Err(RuntimeFailure::Busy),
            _ => return Err(RuntimeFailure::InvalidHandle),
        };
        registry.table.remove(session)?;
        Ok(())
    }
    pub fn start_drain(&self) {
        self.shared.stopping.store(true, Ordering::Release);
        if let Ok(mut registry) = self.shared.registry.try_lock() {
            for record in registry.table.values_mut() {
                match record {
                    Record::Request(r) if !r.status.state.terminal() => {
                        r.token.try_cancel();
                        r.status.state = RequestState::Cancelling;
                    }
                    Record::Session(s) if !s.status.resources_closed => {
                        s.status.state = if s.status.state == SessionState::Opening {
                            SessionState::Cancelling
                        } else {
                            SessionState::Closing
                        };
                    }
                    _ => {}
                }
            }
        }
    }
    pub fn drain_status(&self) -> DrainStatus {
        if !self.shared.stopping.load(Ordering::Acquire) {
            DrainStatus::Running
        } else if self.shared.alive.load(Ordering::Acquire) == 0 {
            DrainStatus::Drained
        } else {
            DrainStatus::Draining
        }
    }
    pub fn retained_result_bytes(&self) -> usize {
        self.shared.result_budget.used()
    }
}
impl Drop for AsyncEngine {
    fn drop(&mut self) {
        self.start_drain();
    }
}

struct ActorSession {
    scope: OwnedDirectory,
    session: Option<NoCacheSession>,
}
struct Tools {
    helper: VerifiedExecutable,
    parser: VerifiedExecutable,
    identity: TraceParserIdentity,
    owners: OwnerStore,
}
fn engine_failure(stage: EngineStage, failure: EngineFailure) -> RuntimeFailure {
    RuntimeFailure::Engine(EngineError { stage, failure })
}
fn load_tools(
    config: &RuntimeConfiguration,
    budget: &EngineBudget,
) -> Result<Tools, RuntimeFailure> {
    let io = IoBudget {
        maximum_bytes: 256 * 1024 * 1024,
        deadline: budget.deadline,
        cancellation: budget.cancellation.clone(),
    };
    let namespace = HeldDirectory::open_private(&config.namespace)
        .map_err(|e| engine_failure(EngineStage::SourceSnapshot, EngineFailure::Host(e)))?;
    let actors = namespace
        .ensure_private_child(".actors")
        .map_err(|e| engine_failure(EngineStage::SourceSnapshot, EngineFailure::Host(e)))?;
    let owners = OwnerStore::open(&actors, &namespace)
        .map_err(|e| engine_failure(EngineStage::SourceSnapshot, EngineFailure::Host(e)))?;
    let tool = |path: &std::path::Path, pin: &str| {
        let parent =
            HeldDirectory::open_private(path.parent().ok_or(RuntimeFailure::InvalidRequest)?)
                .map_err(|e| engine_failure(EngineStage::ParserIdentity, EngineFailure::Host(e)))?;
        let file = parent
            .open_file(
                path.file_name()
                    .and_then(|s| s.to_str())
                    .ok_or(RuntimeFailure::InvalidRequest)?,
            )
            .map_err(|e| engine_failure(EngineStage::ParserIdentity, EngineFailure::Host(e)))?;
        VerifiedExecutable::verify(file, pin, config.trust.clone(), &io)
            .map_err(|e| engine_failure(EngineStage::ParserIdentity, EngineFailure::Process(e)))
    };
    Ok(Tools {
        helper: tool(&config.helper, &config.helper_sha256)?,
        parser: tool(&config.parser, &config.parser_identity.binary_sha256)?,
        identity: config.parser_identity.clone(),
        owners,
    })
}
fn background_registry(shared: &Shared) -> MutexGuard<'_, Registry> {
    shared.registry.lock().unwrap_or_else(|p| p.into_inner())
}
fn is_closing(shared: &Shared, session: RuntimeHandle) -> bool {
    shared.stopping.load(Ordering::Acquire)
        || matches!(background_registry(shared).table.get(session),Ok(Record::Session(s)) if matches!(s.status.state,SessionState::Cancelling|SessionState::Closing|SessionState::Closed))
}
fn report(shared: &Shared, command: &Command, progress: EngineProgress) {
    if is_closing(shared, command.session) {
        command.budget.cancellation.cancel();
    }
    let mut registry = background_registry(shared);
    if let Some(request) = command.request
        && let Ok(Record::Request(r)) = registry.table.get_mut(request)
    {
        r.status.progress = Some(progress);
    }
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Envelope<'a, T: Serialize> {
    format_version: u32,
    session: RuntimeHandle,
    request: RuntimeHandle,
    body: &'a T,
}
fn response<T: Serialize>(
    value: &T,
    command: &Command,
    shared: &Shared,
    config: &RuntimeConfiguration,
) -> Result<OwnedResult, RuntimeFailure> {
    if command.budget.cancellation.is_cancelled() {
        return Err(RuntimeFailure::Cancelled);
    }
    owned_result::encode(
        &Envelope {
            format_version: 1,
            session: command.session,
            request: command.request.ok_or(RuntimeFailure::InvalidRequest)?,
            body: value,
        },
        shared.result_budget.clone(),
        config.limits.maximum_result_bytes,
    )
    .map_err(|_| RuntimeFailure::OutputLimit)
}
fn query(
    session: &NoCacheSession,
    query: &RepositoryRequest,
    command: &Command,
    shared: &Shared,
    config: &RuntimeConfiguration,
) -> Result<OwnedResult, RuntimeFailure> {
    macro_rules! read {
        ($call:expr) => {
            response(
                &$call.map_err(RuntimeFailure::Engine)?,
                command,
                shared,
                config,
            )
        };
    }
    let b = &command.budget;
    match query {
        RepositoryRequest::Processes(q) => read!(session.processes(q, b)),
        RepositoryRequest::Threads(q) => read!(session.threads(q, b)),
        RepositoryRequest::CpuSlices(q) => read!(session.cpu_slices(q, b)),
        RepositoryRequest::ThreadStates(q) => read!(session.thread_states(q, b)),
        RepositoryRequest::Slices(q) => read!(session.slices(q, b)),
        RepositoryRequest::Counters(q) => read!(session.counters(q, b)),
        RepositoryRequest::CounterSeries(q) => read!(session.counter_series(q, b)),
        RepositoryRequest::Frames(q) => read!(session.frames(q, b)),
        RepositoryRequest::Arguments(q) => read!(session.arguments(q, b)),
        RepositoryRequest::Density(q) => read!(session.density(q, b)),
        RepositoryRequest::ViewerDetails {
            source,
            range,
            limit,
        } => read!(session.viewer_details(source, *range, *limit, b)),
        RepositoryRequest::Batch(q) => read!(
            session
                .event_batch(q, b, ReadPoolLimits::default())
                .map(|r| r.result)
        ),
        RepositoryRequest::Search(q) => read!(session.search(q, b)),
        RepositoryRequest::Analyze { request, scope } => {
            read!(session.analyze_bounded(request, *scope, b))
        }
    }
}
fn close_actor(
    mut actor: ActorSession,
    limits: RuntimeLimits,
) -> (Option<RuntimeFailure>, Option<String>) {
    let identifier = actor.scope.identifier().to_owned();
    let mut error = actor
        .session
        .take()
        .and_then(|session| session.close().err().map(RuntimeFailure::Engine));
    let budget = EngineBudget {
        maximum_source_bytes: limits.maximum_source_bytes,
        maximum_database_bytes: limits.maximum_database_bytes,
        deadline: Instant::now() + Duration::from_secs(5),
        cancellation: CancellationToken::default(),
    };
    let recovered = recover_no_cache(actor.scope.directory(), &budget);
    let safe = matches!(&recovered,Ok(rows) if rows.iter().all(|r|matches!(r.outcome,crate::NoCacheRecoveryOutcome::Owner(OwnerRecoveryOutcome::Removed|OwnerRecoveryOutcome::NotFound))));
    if safe {
        let io = IoBudget {
            maximum_bytes: limits
                .maximum_source_bytes
                .max(limits.maximum_database_bytes),
            deadline: budget.deadline,
            cancellation: CancellationToken::default(),
        };
        if actor.scope.cleanup(&io).is_err() {
            error = Some(engine_failure(
                EngineStage::Closing,
                EngineFailure::CleanupFailed,
            ));
            return (error, Some(identifier));
        }
        (error, None)
    } else {
        (
            Some(engine_failure(
                EngineStage::Closing,
                EngineFailure::CleanupFailed,
            )),
            Some(identifier),
        )
    }
}
fn update_closed(
    shared: &Shared,
    session: RuntimeHandle,
    error: Option<RuntimeFailure>,
    residue: Option<String>,
) {
    let mut registry = background_registry(shared);
    if let Ok(Record::Session(s)) = registry.table.get_mut(session) {
        s.close_queued = false;
        s.status.resources_closed = true;
        s.status.state = if error.is_some() {
            SessionState::Failed
        } else {
            SessionState::Closed
        };
        s.status.close_failure = error;
        s.status.residue_owner = residue;
    }
}
fn process(
    command: &Command,
    shared: &Shared,
    config: &RuntimeConfiguration,
    tools: &mut Option<Tools>,
    sessions: &mut HashMap<RuntimeHandle, ActorSession>,
) -> Result<Option<OwnedResult>, RuntimeFailure> {
    if !matches!(command.operation, Operation::Close) && is_closing(shared, command.session) {
        command.budget.cancellation.cancel();
    }
    match &command.operation {
        Operation::Open { source, format } => {
            if command.budget.cancellation.is_cancelled() {
                return Err(RuntimeFailure::Cancelled);
            }
            if tools.is_none() {
                *tools = Some(load_tools(config, &command.budget)?);
            }
            let tools = tools.as_ref().ok_or(RuntimeFailure::WorkerPanicked)?;
            let io = IoBudget {
                maximum_bytes: config.limits.maximum_source_bytes,
                deadline: command.budget.deadline,
                cancellation: command.budget.cancellation.clone(),
            };
            let scope = tools
                .owners
                .create(OwnerKind::Session, &io)
                .map_err(|e| engine_failure(EngineStage::SourceSnapshot, EngineFailure::Host(e)))?;
            sessions.insert(
                command.session,
                ActorSession {
                    scope,
                    session: None,
                },
            );
            observe(config, WorkerBoundary::Opening);
            let source = HeldFile::open_explicit_source(source)
                .map_err(|e| engine_failure(EngineStage::SourceSnapshot, EngineFailure::Host(e)))?;
            let actor = sessions
                .get_mut(&command.session)
                .ok_or(RuntimeFailure::WorkerPanicked)?;
            actor.session = Some(
                open_no_cache(
                    &source,
                    *format,
                    &ParserTools {
                        helper: &tools.helper,
                        parser: &tools.parser,
                        identity: tools.identity.clone(),
                    },
                    actor.scope.directory(),
                    &command.budget,
                    |progress| report(shared, command, progress),
                )
                .map_err(RuntimeFailure::Engine)?,
            );
            observe(config, WorkerBoundary::Opened);
            let session = actor
                .session
                .as_ref()
                .ok_or(RuntimeFailure::WorkerPanicked)?;
            response(&serde_json::json!({"metadata":session.metadata(),"inspection":session.inspection()}),command,shared,config).map(Some)
        }
        Operation::Query(q) => {
            if !matches!(background_registry(shared).table.get(command.session),Ok(Record::Session(s)) if s.status.state==SessionState::Ready)
            {
                return Err(RuntimeFailure::Closed);
            }
            let session = sessions
                .get(&command.session)
                .and_then(|actor| actor.session.as_ref())
                .ok_or(RuntimeFailure::Closed)?;
            session
                .verify(&command.budget)
                .map_err(RuntimeFailure::Engine)?;
            observe(config, WorkerBoundary::Querying);
            query(session, q, command, shared, config).map(Some)
        }
        Operation::Close => {
            observe(config, WorkerBoundary::Closing);
            let (error, residue) =
                cleanup_session(sessions.remove(&command.session), config.limits);
            update_closed(shared, command.session, error, residue);
            if let Some(error) = error {
                return Err(error);
            }
            Ok(None)
        }
    }
}
fn fatal(error: RuntimeFailure) -> bool {
    matches!(
        error,
        RuntimeFailure::WorkerPanicked
            | RuntimeFailure::Engine(EngineError {
                failure: EngineFailure::CleanupFailed
                    | EngineFailure::InvalidMetadata
                    | EngineFailure::InvalidIdentity
                    | EngineFailure::Host(
                        arktrace_platform::HostError::Changed
                            | arktrace_platform::HostError::IdentityMismatch
                            | arktrace_platform::HostError::InvalidEvidence
                    )
                    | EngineFailure::Store(
                        arktrace_store::StoreError::WorkerFailed
                            | arktrace_store::StoreError::CleanupFailed
                    ),
                ..
            })
    )
}
/// Preserve owner identity if cleanup itself panics; handles still drop on
/// the owning worker and the identity-bound residue remains recoverable.
fn cleanup_session(
    actor: Option<ActorSession>,
    limits: RuntimeLimits,
) -> (Option<RuntimeFailure>, Option<String>) {
    let Some(actor) = actor else {
        return (None, None);
    };
    let owner = actor.scope.identifier().to_owned();
    catch_unwind(AssertUnwindSafe(|| close_actor(actor, limits)))
        .unwrap_or((Some(RuntimeFailure::WorkerPanicked), Some(owner)))
}
fn cancelled_result(
    result: Result<Option<OwnedResult>, RuntimeFailure>,
    cancelled: bool,
) -> Result<Option<OwnedResult>, RuntimeFailure> {
    if cancelled && !result.as_ref().err().is_some_and(|e| fatal(*e)) {
        Err(RuntimeFailure::Cancelled)
    } else {
        result
    }
}
fn publish(
    registry: &mut Registry,
    request: RuntimeHandle,
    result: Result<Option<OwnedResult>, RuntimeFailure>,
) {
    if let Ok(Record::Request(r)) = registry.table.get_mut(request) {
        match result {
            Ok(Some(result)) => {
                r.result = Some(result);
                r.status.state = RequestState::Succeeded;
                r.status.failure = None;
            }
            Ok(None) => {
                r.status.state = RequestState::Failed;
                r.status.failure = Some(RuntimeFailure::WorkerPanicked);
            }
            Err(error) => {
                r.status.state = RequestState::Failed;
                r.status.failure = Some(error);
            }
        }
    }
}
fn finish_command(
    shared: &Shared,
    command: &Command,
    config: &RuntimeConfiguration,
    sessions: &mut HashMap<RuntimeHandle, ActorSession>,
    result: Result<Option<OwnedResult>, RuntimeFailure>,
) {
    let Some(request) = command.request else {
        if let Err(error) = result {
            let (cleanup, residue) =
                cleanup_session(sessions.remove(&command.session), config.limits);
            update_closed(shared, command.session, cleanup.or(Some(error)), residue);
        }
        return;
    };
    let mut registry = background_registry(shared);
    let cancelled = shared.stopping.load(Ordering::Acquire)
        || matches!(registry.table.get(command.session),Ok(Record::Session(s)) if matches!(s.status.state,SessionState::Cancelling|SessionState::Closing|SessionState::Closed))
        || command.budget.cancellation.is_cancelled();
    let mut result = cancelled_result(result, cancelled);
    if matches!(command.operation, Operation::Open { .. }) && result.is_err() {
        // Cleanup precedes terminal opening state; close/drain must not report
        // success while a parser, staging owner, lease or DB is still held.
        drop(registry);
        let (cleanup, residue) = cleanup_session(sessions.remove(&command.session), config.limits);
        if let Some(error) = cleanup {
            result = Err(error);
        }
        observe(config, WorkerBoundary::OpeningDrained);
        registry = background_registry(shared);
        let cancelled = shared.stopping.load(Ordering::Acquire)
            || command.budget.cancellation.is_cancelled()
            || matches!(registry.table.get(command.session),Ok(Record::Session(s)) if matches!(s.status.state,SessionState::Cancelling|SessionState::Closing|SessionState::Closed));
        result = cancelled_result(result, cancelled);
        let opening_failed = result
            .as_ref()
            .err()
            .is_some_and(|e| *e != RuntimeFailure::Cancelled);
        if let Ok(Record::Session(s)) = registry.table.get_mut(command.session) {
            s.status.resources_closed = true;
            s.status.state = if opening_failed {
                SessionState::Failed
            } else {
                SessionState::Closed
            };
            s.status.close_failure = cleanup;
            s.status.residue_owner = residue;
            // A previously queued close still owns its reserved channel slot.
            // Keep its session handle until that control command is consumed.
        }
    } else if let Ok(Record::Session(s)) = registry.table.get_mut(command.session) {
        if matches!(command.operation, Operation::Open { .. }) && result.is_ok() {
            s.status.state = SessionState::Ready;
        }
        if result.as_ref().err().is_some_and(|e| fatal(*e)) {
            s.status.state = SessionState::Failed;
        }
    }
    // Cancellation and result publication share the registry lock. A caller
    // cannot cancel an accepted request between this check and its terminal state.
    publish(&mut registry, request, result);
}
struct WorkerExit(Arc<Shared>);
impl Drop for WorkerExit {
    fn drop(&mut self) {
        self.0.alive.fetch_sub(1, Ordering::Release);
    }
}
fn run_worker(
    receiver: Receiver<Command>,
    shared: Arc<Shared>,
    config: RuntimeConfiguration,
    index: usize,
) {
    let _exit = WorkerExit(shared.clone());
    let mut tools = None;
    let mut sessions = HashMap::new();
    let crashed = catch_unwind(AssertUnwindSafe(|| {
        while !shared.stopping.load(Ordering::Acquire) {
            let command = match receiver.recv_timeout(Duration::from_millis(10)) {
                Ok(command) => command,
                Err(mpsc::RecvTimeoutError::Timeout) => continue,
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            };
            if let Some(request) = command.request {
                let mut registry = background_registry(&shared);
                if let Ok(Record::Request(r)) = registry.table.get_mut(request)
                    && r.status.state != RequestState::Cancelling
                {
                    r.status.state = RequestState::Running;
                }
                registry.queued[index] -= 1;
            }
            let result = catch_unwind(AssertUnwindSafe(|| {
                process(&command, &shared, &config, &mut tools, &mut sessions)
            }))
            .unwrap_or(Err(RuntimeFailure::WorkerPanicked));
            finish_command(&shared, &command, &config, &mut sessions, result);
        }
    }))
    .is_err();
    if crashed {
        shared.stopping.store(true, Ordering::Release);
    }
    // Synchronize with producers before collecting the final queue. Front-end
    // enqueue checks stopping while holding this same registry lock.
    let pending = {
        let _registry = background_registry(&shared);
        receiver.try_iter().collect::<Vec<_>>()
    };
    let closed = sessions
        .into_iter()
        .map(|(session, actor)| {
            let (error, residue) = cleanup_session(Some(actor), config.limits);
            (session, error, residue)
        })
        .collect::<Vec<_>>();
    {
        let mut registry = background_registry(&shared);
        registry.queued[index] = 0;
        for (session, error, residue) in closed {
            if let Ok(Record::Session(s)) = registry.table.get_mut(session) {
                s.close_queued = false;
                s.status.resources_closed = true;
                s.status.state = if error.is_some() {
                    SessionState::Failed
                } else {
                    SessionState::Closed
                };
                s.status.close_failure = error;
                s.status.residue_owner = residue;
            }
        }

        for record in registry.table.values_mut() {
            if let Record::Session(s) = record
                && s.worker == index
                && !s.status.resources_closed
            {
                s.close_queued = false;
                s.status.resources_closed = true;
                s.status.state = if crashed {
                    SessionState::Failed
                } else {
                    SessionState::Closed
                };
                if crashed {
                    s.status.close_failure = Some(RuntimeFailure::WorkerPanicked);
                }
            }
        }
        if crashed {
            let worker_sessions = registry
                .table
                .values()
                .filter_map(|r| match r {
                    Record::Request(r) if !r.status.state.terminal() => Some(r.status.session),
                    _ => None,
                })
                .filter(
                    |h| matches!(registry.table.get(*h),Ok(Record::Session(s)) if s.worker==index),
                )
                .collect::<Vec<_>>();
            for record in registry.table.values_mut() {
                if let Record::Request(r) = record
                    && !r.status.state.terminal()
                    && worker_sessions.contains(&r.status.session)
                {
                    r.status.state = RequestState::Failed;
                    r.status.failure = Some(RuntimeFailure::WorkerPanicked);
                }
            }
        }
        for command in pending {
            if command.request.is_none()
                && let Ok(Record::Session(s)) = registry.table.get_mut(command.session)
            {
                s.close_queued = false;
            }
            if let Some(request) = command.request {
                publish(
                    &mut registry,
                    request,
                    Err(if crashed {
                        RuntimeFailure::WorkerPanicked
                    } else {
                        RuntimeFailure::Cancelled
                    }),
                );
            }
        }
    }
    drop(tools); // release executable/directory descriptors before Drained
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn viewer_frontend_rejects_invalid_bounds_before_worker_dispatch() {
        use arktrace_contract::{TraceDensitySource, TraceTimeRange};
        let source = TraceDensitySource::NamedSlice { thread: None };
        let range = TraceTimeRange::query(0, 10).unwrap();
        for limit in [0, 20_001, usize::MAX] {
            assert_eq!(
                RepositoryRequest::ViewerDetails {
                    source: source.clone(),
                    range,
                    limit
                }
                .validate(),
                Err(RuntimeFailure::InvalidRequest)
            );
        }
        assert_eq!(
            RepositoryRequest::ViewerDetails {
                source,
                range: TraceTimeRange::event(0, 0).unwrap(),
                limit: 1
            }
            .validate(),
            Err(RuntimeFailure::InvalidRequest)
        );
    }
    #[test]
    fn cancellation_cannot_hide_fatal_worker_or_cleanup_failures() {
        let failures = [
            RuntimeFailure::WorkerPanicked,
            engine_failure(EngineStage::Closing, EngineFailure::CleanupFailed),
            engine_failure(
                EngineStage::Querying,
                EngineFailure::Store(arktrace_store::StoreError::WorkerFailed),
            ),
        ];
        for failure in failures {
            assert!(matches!(cancelled_result(Err(failure),true),Err(actual) if actual==failure));
        }
        assert!(matches!(
            cancelled_result(Err(RuntimeFailure::OutputLimit), true),
            Err(RuntimeFailure::Cancelled)
        ));
    }
    #[test]
    fn front_end_returns_busy_instead_of_waiting_for_registry() {
        let limits = RuntimeLimits::default();
        let shared = Arc::new(Shared {
            registry: Mutex::new(Registry {
                table: HandleTable::new(1).unwrap(),
                queued: vec![0],
                next_worker: 0,
            }),
            stopping: AtomicBool::new(false),
            alive: AtomicUsize::new(0),
            result_budget: ResultBudget::new(128),
        });
        let engine = AsyncEngine {
            shared: shared.clone(),
            senders: Vec::new(),
            limits,
        };
        let _held = shared.registry.lock().unwrap();
        assert_eq!(
            engine.poll(RuntimeHandle::from_raw(0)),
            Err(RuntimeFailure::Busy)
        );
        engine.start_drain();
        assert_eq!(engine.drain_status(), DrainStatus::Drained);
    }
    #[test]
    fn closed_handles_still_reserve_session_capacity_until_control_is_consumed() {
        let limits = RuntimeLimits {
            workers: 1,
            sessions: 1,
            requests: 2,
            queue_per_worker: 1,
            ..RuntimeLimits::default()
        };
        let shared = Arc::new(Shared {
            registry: Mutex::new(Registry {
                table: HandleTable::new(3).unwrap(),
                queued: vec![0],
                next_worker: 0,
            }),
            stopping: AtomicBool::new(false),
            alive: AtomicUsize::new(0),
            result_budget: ResultBudget::new(128),
        });
        let (sender, _receiver) = mpsc::sync_channel(2);
        let engine = AsyncEngine {
            shared: shared.clone(),
            senders: vec![sender],
            limits,
        };
        let session = background_registry(&shared)
            .table
            .insert(Record::Session(SessionRecord {
                worker: 0,
                status: SessionStatus {
                    state: SessionState::Closed,
                    resources_closed: true,
                    close_failure: None,
                    residue_owner: None,
                },
                close_queued: true,
            }))
            .unwrap();
        assert_eq!(
            engine.open(
                PathBuf::from("/private/tmp/source.htrace"),
                SourceFormat::Htrace,
                Duration::from_secs(1)
            ),
            Err(RuntimeFailure::Capacity)
        );
        assert_eq!(engine.release_session(session), Err(RuntimeFailure::Busy));
        if let Record::Session(s) = background_registry(&shared).table.get_mut(session).unwrap() {
            s.close_queued = false;
        }
        assert_eq!(engine.release_session(session), Ok(()));
    }
    #[test]
    fn close_uses_reserved_control_capacity_with_full_handle_and_result_tables() {
        let limits = RuntimeLimits {
            workers: 1,
            sessions: 1,
            requests: 1,
            queue_per_worker: 1,
            maximum_retained_result_bytes: 1,
            ..RuntimeLimits::default()
        };
        let shared = Arc::new(Shared {
            registry: Mutex::new(Registry {
                table: HandleTable::new(2).unwrap(),
                queued: vec![1],
                next_worker: 0,
            }),
            stopping: AtomicBool::new(false),
            alive: AtomicUsize::new(0),
            result_budget: ResultBudget::new(1),
        });
        let (sender, receiver) = mpsc::sync_channel(2);
        let engine = AsyncEngine {
            shared: shared.clone(),
            senders: vec![sender],
            limits,
        };
        let session;
        let request;
        {
            let mut registry = background_registry(&shared);
            session = registry
                .table
                .insert(Record::Session(SessionRecord {
                    worker: 0,
                    status: SessionStatus {
                        state: SessionState::Ready,
                        resources_closed: false,
                        close_failure: None,
                        residue_owner: None,
                    },
                    close_queued: false,
                }))
                .unwrap();
            request = registry
                .table
                .insert(Record::Request(RequestRecord {
                    status: RequestStatus {
                        session,
                        state: RequestState::Queued,
                        progress: None,
                        failure: None,
                    },
                    token: CancellationToken::default(),
                    result: None,
                }))
                .unwrap();
        }
        engine.senders[0]
            .try_send(Command {
                session,
                request: Some(request),
                budget: engine.budget(Duration::from_secs(1)).unwrap(),
                operation: Operation::Query(Box::new(RepositoryRequest::Batch(
                    TraceRepositoryEventBatch::default(),
                ))),
            })
            .unwrap();
        assert_eq!(engine.close(session), Ok(()));
        assert_eq!(engine.close(session), Ok(()));
        assert!(receiver.try_recv().unwrap().request.is_some());
        assert!(receiver.try_recv().unwrap().request.is_none());
        assert!(receiver.try_recv().is_err());
        assert_eq!(
            engine.poll(request).unwrap().state,
            RequestState::Cancelling
        );
        assert_eq!(
            engine.session_status(session).unwrap().state,
            SessionState::Closing
        );
    }
}
