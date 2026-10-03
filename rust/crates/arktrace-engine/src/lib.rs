//! Shared composition root. Native lifecycle remains behind host ports.
#[cfg(target_os = "macos")]
mod async_runtime;
mod metadata;
#[cfg(target_os = "macos")]
pub use async_runtime::{
    AsyncEngine, DrainStatus, OpenTicket, RepositoryRequest, RequestState, RequestStatus,
    RuntimeConfiguration, RuntimeFailure, RuntimeLimits, SessionState, SessionStatus,
    WorkerBoundary,
};
mod handles;
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
pub use no_cache::{
    AnalysisFailure, AnalysisScope, EngineBudget, EngineError, EngineFailure, EngineProgress,
    EngineStage, NoCacheRecoveryOutcome, NoCacheRecoveryRow, NoCacheSession, ParserTools,
    SourceFormat, ViewerFailure, open_no_cache, recover_no_cache,
};

pub fn contract_smoke() -> Result<(Option<NativeHost>, i64), ContractError> {
    let range = TraceTimeRange::query(i64::MAX - 1, i64::MAX)?;
    Ok((native_host(), range.duration_ns()))
}
