//! Shared composition root. Native lifecycle remains behind host ports.
mod metadata;
#[cfg(target_os = "macos")]
mod no_cache;
#[cfg(target_os = "macos")]
mod public_error;
pub use arktrace_analysis::{
    AnalysisRequest as BoundedAnalysisRequest, AnalysisResult as BoundedAnalysisResult,
};
use arktrace_contract::{ContractError, TraceTimeRange};
use arktrace_platform::{NativeHost, native_host};
pub use metadata::CacheMetadata;
#[cfg(target_os = "macos")]
pub use no_cache::{
    AnalysisFailure, AnalysisScope, EngineBudget, EngineError, EngineFailure, EngineProgress,
    EngineStage, NoCacheRecoveryOutcome, NoCacheRecoveryRow, NoCacheSession, ParserTools,
    SourceFormat, open_no_cache, recover_no_cache,
};

pub fn contract_smoke() -> Result<(Option<NativeHost>, i64), ContractError> {
    let range = TraceTimeRange::query(i64::MAX - 1, i64::MAX)?;
    Ok((native_host(), range.duration_ns()))
}
