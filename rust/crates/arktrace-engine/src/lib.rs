//! Shared composition root. Native lifecycle remains behind host ports.
#[cfg(target_os = "macos")]
mod async_runtime;
mod metadata;
mod query_deadlines;
mod view_state;
mod view_state_migration;
#[cfg(target_os = "macos")]
pub use async_runtime::{
    AsyncEngine, CacheRequest, DrainStatus, MAXIMUM_RETAINED_VIEW_STATE_INPUT_BYTES, OpenTicket,
    RepositoryRequest, RequestState, RequestStatus, RuntimeConfiguration, RuntimeFailure,
    RuntimeLimits, SessionState, SessionStatus, ViewStateRequest, WorkerBoundary,
};
pub use query_deadlines::{
    BatchQueryDeadlines, DeadlineBatch, DeadlineQuery, DeadlineRepositoryQuery, QueryClock,
};
pub use view_state::{
    MAXIMUM_VIEW_STATE_BYTES, MAXIMUM_VIEW_STATE_RECORDS, ViewStateDocument, ViewStateEncodeError,
    ViewStateRead, ViewStateWrite,
};
pub use view_state_migration::{
    LegacyViewStateIssue, LegacyViewStateMigrationReport, LegacyViewStateMigrationStatus,
    LegacyViewStateSource, MAXIMUM_LEGACY_BACKUP_FILE_BYTES, MAXIMUM_LEGACY_BACKUP_SCAN_BYTES,
    MAXIMUM_LEGACY_VIEW_STATE_ENTRIES,
};
mod handles;
#[cfg(any(target_os = "macos", test))]
mod owned_input;
#[cfg(any(target_os = "macos", test))]
mod owned_result;
#[cfg(target_os = "macos")]
pub use arktrace_platform::CodeTrustPolicy;
pub use handles::{HandleError, RuntimeHandle};
#[cfg(target_os = "macos")]
pub use owned_result::OwnedResult;
#[cfg(target_os = "macos")]
mod no_cache;
#[cfg(target_os = "macos")]
mod public_error;
pub use arktrace_analysis::{
    AnalysisRequest as BoundedAnalysisRequest, AnalysisResult as BoundedAnalysisResult,
};
use arktrace_contract::{ContractError, TraceTimeRange};
use arktrace_platform::{NativeHost, native_host};
pub use arktrace_store::ReadPoolLimits;
#[cfg(target_os = "macos")]
pub use arktrace_store::{ReadPoolOutput, ReadPoolStatistics};
pub use metadata::CacheMetadata;
#[cfg(target_os = "macos")]
mod cache_maintenance;
#[cfg(target_os = "macos")]
pub use cache_maintenance::{
    CacheInventory, CacheMaintenance, CacheMaintenanceReport, CacheWatermarks,
};
#[cfg(target_os = "macos")]
pub use no_cache::{
    AnalysisFailure, AnalysisScope, EngineBudget, EngineError, EngineFailure, EngineProgress,
    EngineSession, EngineStage, LegacyViewStateMigration, NoCacheRecoveryOutcome,
    NoCacheRecoveryRow, NoCacheSession, ParserTools, SourceFormat, ViewerFailure, open_cached,
    open_no_cache, recover_no_cache,
};

pub fn contract_smoke() -> Result<(Option<NativeHost>, i64), ContractError> {
    let range = TraceTimeRange::query(i64::MAX - 1, i64::MAX)?;
    Ok((native_host(), range.duration_ns()))
}
