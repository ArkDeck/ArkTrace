use crate::{abi_records::*, model::*};
#[cfg(target_os = "macos")]
use arktrace_engine::{
    AsyncEngine, DrainStatus, OwnedResult, RequestState, RuntimeFailure, RuntimeHandle,
};
#[cfg(target_os = "macos")]
use std::sync::Weak;
use std::sync::{
    Arc, LazyLock, Mutex, MutexGuard, TryLockError,
    atomic::{AtomicBool, Ordering},
};

pub(crate) struct Host {
    pub poisoned: AtomicBool,
    #[cfg(target_os = "macos")]
    pub engine: AsyncEngine,
}
#[derive(Clone)]
pub(crate) struct ResultOwner {
    pub kind: u32,
    #[cfg(target_os = "macos")]
    pub data: OwnedResult,
    #[cfg(target_os = "macos")]
    pub producer: Weak<Host>,
}
enum Record {
    Engine(Arc<Host>),
    Result(ResultOwner),
}
struct Registry {
    next: u64,
    records: Vec<(u64, Record)>,
}
static REGISTRY: LazyLock<Mutex<Registry>> = LazyLock::new(|| {
    Mutex::new(Registry {
        next: 1,
        records: Vec::new(),
    })
});
fn lock() -> Result<MutexGuard<'static, Registry>, u32> {
    REGISTRY.try_lock().map_err(|e| match e {
        TryLockError::WouldBlock => STATUS_BUSY,
        TryLockError::Poisoned(_) => STATUS_INTERNAL,
    })
}
impl Registry {
    fn insert(&mut self, record: Record) -> Result<u64, u32> {
        let is_engine = matches!(record, Record::Engine(_));
        let count = self
            .records
            .iter()
            .filter(|(_, r)| matches!(r, Record::Engine(_)) == is_engine)
            .count();
        if count
            >= if is_engine {
                MAXIMUM_ENGINES as usize
            } else {
                MAXIMUM_RESULT_OWNERS as usize
            }
        {
            return Err(STATUS_CAPACITY);
        }
        let id = self.next;
        self.next = self.next.checked_add(1).ok_or(STATUS_CAPACITY)?;
        self.records.push((id, record));
        Ok(id)
    }
    fn remove(&mut self, id: u64, engine: bool) -> Result<Record, u32> {
        let i = self
            .records
            .iter()
            .position(|(handle, _)| *handle == id)
            .ok_or(STATUS_INVALID_HANDLE)?;
        if matches!(self.records[i].1, Record::Engine(_)) != engine {
            return Err(STATUS_INVALID_HANDLE);
        }
        Ok(self.records.swap_remove(i).1)
    }
}
pub(crate) fn host(id: u64) -> Result<Arc<Host>, u32> {
    let registry = lock()?;
    match registry.records.iter().find(|(h, _)| *h == id) {
        Some((_, Record::Engine(h))) => Ok(h.clone()),
        _ => Err(STATUS_INVALID_HANDLE),
    }
}
pub(crate) fn owner(id: u64) -> Result<ResultOwner, u32> {
    let registry = lock()?;
    match registry.records.iter().find(|(h, _)| *h == id) {
        Some((_, Record::Result(r))) => Ok(r.clone()),
        _ => Err(STATUS_INVALID_HANDLE),
    }
}
pub(crate) fn retain(owner: ResultOwner) -> Result<u64, u32> {
    lock()?.insert(Record::Result(owner))
}
pub(crate) fn release_owner(id: u64) -> Result<(), u32> {
    let record = lock()?.remove(id, false)?;
    drop(record);
    Ok(())
}
pub(crate) fn create(config: EngineConfig, fixture: bool) -> Result<u64, u32> {
    config.validate(fixture)?;
    if fixture && !cfg!(feature = "process-fixtures") {
        return Err(STATUS_UNSUPPORTED_OPERATION);
    }
    // Capacity check precedes thread creation. Keep the short front-end
    // lock through insertion so concurrent creates cannot oversubscribe.
    let mut registry = lock()?;
    if registry
        .records
        .iter()
        .filter(|(_, r)| matches!(r, Record::Engine(_)))
        .count()
        >= MAXIMUM_ENGINES as usize
    {
        return Err(STATUS_CAPACITY);
    }
    registry.insert(Record::Engine(Arc::new(Host::create(config, fixture)?)))
}
pub(crate) fn release_engine(id: u64) -> Result<(), u32> {
    let mut registry = lock()?;
    let h = match registry.records.iter().find(|(h, _)| *h == id) {
        Some((_, Record::Engine(h))) => h,
        _ => return Err(STATUS_INVALID_HANDLE),
    };
    #[cfg(target_os = "macos")]
    if h.engine.drain_status() != DrainStatus::Drained {
        return Err(STATUS_BUSY);
    }
    #[cfg(not(target_os = "macos"))]
    let _ = h;
    let record = registry.remove(id, true)?;
    drop(registry);
    drop(record);
    Ok(())
}
pub(crate) fn poison(host: &Host) {
    host.poisoned.store(true, Ordering::Release);
    #[cfg(target_os = "macos")]
    host.engine.start_drain();
}
impl Host {
    fn create(config: EngineConfig, fixture: bool) -> Result<Self, u32> {
        #[cfg(target_os = "macos")]
        {
            Ok(Self {
                poisoned: AtomicBool::new(false),
                engine: AsyncEngine::create(config.native(fixture)?).map_err(failure)?,
            })
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (config, fixture);
            Err(STATUS_UNSUPPORTED_HOST)
        }
    }
    pub fn active(&self) -> Result<(), u32> {
        if self.poisoned.load(Ordering::Acquire) {
            Err(STATUS_POISONED)
        } else {
            Ok(())
        }
    }
    #[cfg(target_os = "macos")]
    pub fn acquire(self: &Arc<Self>, request: u64) -> Result<ResultOwner, u32> {
        let handle = RuntimeHandle::from_raw(request);
        let status = self.engine.poll(handle).map_err(failure)?;
        if status.state == RequestState::Failed {
            Ok(ResultOwner {
                kind: RESULT_FAILURE,
                data: self.engine.acquire_error_result(handle).map_err(failure)?,
                producer: Arc::downgrade(self),
            })
        } else {
            Ok(ResultOwner {
                kind: RESULT_SUCCESS,
                data: self.engine.acquire_result(handle).map_err(failure)?,
                producer: Arc::downgrade(self),
            })
        }
    }
}
#[cfg(target_os = "macos")]
pub(crate) fn failure(error: RuntimeFailure) -> u32 {
    match error {
        RuntimeFailure::InvalidHandle => STATUS_INVALID_HANDLE,
        RuntimeFailure::Busy => STATUS_BUSY,
        RuntimeFailure::Capacity => STATUS_CAPACITY,
        RuntimeFailure::InvalidRequest => STATUS_INVALID_INPUT,
        RuntimeFailure::Closed => STATUS_CLOSED,
        RuntimeFailure::Cancelled => STATUS_CANCELLED,
        RuntimeFailure::OutputLimit => STATUS_OUTPUT_LIMIT,
        RuntimeFailure::WorkerPanicked | RuntimeFailure::Engine(_) => STATUS_INTERNAL,
    }
}
#[cfg(target_os = "macos")]
pub(crate) fn public_fields(error: Option<RuntimeFailure>) -> (u32, u32, u32, u32) {
    use arktrace_contract::{Code, Stage};
    let Some(e) = error.and_then(RuntimeFailure::public_error) else {
        return (0, 0, 0, 0);
    };
    let code = match e.code() {
        Code::InvalidArgument => CODE_INVALID_ARGUMENT,
        Code::TraceFileNotFound => CODE_TRACE_FILE_NOT_FOUND,
        Code::TraceFileUnreadable => CODE_TRACE_FILE_UNREADABLE,
        Code::TraceFormatUnsupported => CODE_TRACE_FORMAT_UNSUPPORTED,
        Code::TraceStreamerUnavailable => CODE_TRACE_STREAMER_UNAVAILABLE,
        Code::TraceStreamerIdentityMismatch => CODE_TRACE_STREAMER_IDENTITY_MISMATCH,
        Code::TraceParseFailed => CODE_TRACE_PARSE_FAILED,
        Code::TraceSchemaUnsupported => CODE_TRACE_SCHEMA_UNSUPPORTED,
        Code::TraceDatabaseInvalid => CODE_TRACE_DATABASE_INVALID,
        Code::TraceCacheCorrupt => CODE_TRACE_CACHE_CORRUPT,
        Code::QueryFailed => CODE_QUERY_FAILED,
        Code::QueryTimeout => CODE_QUERY_TIMEOUT,
        Code::QueryLimitExceeded => CODE_QUERY_LIMIT_EXCEEDED,
        Code::OutputLimitExceeded => CODE_OUTPUT_LIMIT_EXCEEDED,
        Code::AnalysisUnsupported => CODE_ANALYSIS_UNSUPPORTED,
        Code::Cancelled => CODE_CANCELLED,
        Code::InternalError => CODE_INTERNAL_ERROR,
    };
    let stage = match e.stage() {
        Stage::Request => STAGE_REQUEST,
        Stage::Preparing => STAGE_PREPARING,
        Stage::Hashing => STAGE_HASHING,
        Stage::CacheLookup => STAGE_CACHE_LOOKUP,
        Stage::Parsing => STAGE_PARSING,
        Stage::Validating => STAGE_VALIDATING,
        Stage::Indexing => STAGE_INDEXING,
        Stage::OpeningDatabase => STAGE_OPENING_DATABASE,
        Stage::Querying => STAGE_QUERYING,
        Stage::Analyzing => STAGE_ANALYZING,
        Stage::Encoding => STAGE_ENCODING,
    };
    (1, code, stage, u32::from(e.retryable()))
}
