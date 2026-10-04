//! Pure Viewer geometry, bounded query planning and immutable hit projection.
//! No renderer, database, clock or IO. Session-owned loading uses typed host
//! query callbacks; asynchronous admission and generation publication stay in Engine.
//! Coordinates are logical points; only minimum visual width uses backing scale.
mod detail;
mod geometry;
mod hot_snapshot;
mod interaction;
mod loader;
mod navigation;
mod plan;
mod snapshot;
mod track_tree;
mod types;
mod view_actions;
mod wire_records;

pub use detail::*;
pub use geometry::*;
pub use hot_snapshot::*;
pub use interaction::*;
pub use loader::*;
pub use navigation::*;
pub use plan::*;
pub use snapshot::*;
pub use track_tree::*;
pub use types::*;
pub use view_actions::*;
pub use wire_records::*;

use arktrace_contract::{ContractError, DataQuality};
pub const VIEWER_API_VERSION: u32 = 1;
// Stage input cap matches the frozen contract machine-quality budget.
const MAXIMUM_SOURCE_QUALITY_ISSUES: usize = 4096;
pub type Check<'a> = dyn FnMut() -> Result<(), ViewerError> + 'a;
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ViewerError {
    InvalidViewport,
    InvalidGeometry,
    InvalidRequest,
    InvalidEvidence,
    InputBudgetExceeded,
    ArithmeticOverflow,
    Cancelled,
    DeadlineReached,
    Quality(ContractError),
}
impl From<ContractError> for ViewerError {
    fn from(value: ContractError) -> Self {
        Self::Quality(value)
    }
}
impl std::fmt::Display for ViewerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for ViewerError {}
pub(crate) fn checkpoint(i: usize, check: &mut Check<'_>) -> Result<(), ViewerError> {
    if i.is_multiple_of(256) {
        check()?;
    }
    Ok(())
}
pub(crate) fn finite(value: f64) -> Result<f64, ViewerError> {
    if value.is_finite() {
        Ok(value)
    } else {
        Err(ViewerError::InvalidGeometry)
    }
}
pub(crate) fn machine(quality: &DataQuality) -> Result<DataQuality, ViewerError> {
    if quality.warnings.len() > MAXIMUM_SOURCE_QUALITY_ISSUES {
        return Err(ViewerError::Quality(
            ContractError::QualityItemBudgetExceeded,
        ));
    }
    Ok(DataQuality::machine(
        quality.status,
        quality.warnings.clone(),
    )?)
}

/// Full source identity is deduplicated before message redaction, like Swift.
/// Different human messages may legitimately become identical machine facts.
pub(crate) type QualityKey = (
    arktrace_contract::QualityCategory,
    Option<String>,
    Option<i64>,
    Option<String>,
);
pub(crate) fn merge_quality(
    issues: &mut Vec<arktrace_contract::QualityIssue>,
    seen: &mut std::collections::BTreeSet<QualityKey>,
    quality: &DataQuality,
    check: &mut Check<'_>,
) -> Result<(), ViewerError> {
    machine(quality)?;
    for (i, issue) in quality.warnings.iter().enumerate() {
        checkpoint(i, check)?;
        let key = (
            issue.category,
            issue.scope.clone(),
            issue.count,
            issue.message.clone(),
        );
        if !seen.contains(&key) {
            if issues.len() >= MAXIMUM_SOURCE_QUALITY_ISSUES {
                return Err(ViewerError::Quality(
                    ContractError::QualityItemBudgetExceeded,
                ));
            }
            seen.insert(key);
            issues.push(issue.clone());
        }
    }
    Ok(())
}

mod palette;
mod presentation;
pub use palette::*;
pub use presentation::*;

mod annotations;
pub use annotations::*;
