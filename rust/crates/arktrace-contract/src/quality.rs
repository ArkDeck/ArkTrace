use crate::ContractError;
use serde::{Deserialize, Serialize};

const ALLOWED_SCOPES: &[&str] = include!(concat!(env!("OUT_DIR"), "/quality-scopes.rs"));
pub const MAX_QUALITY_ISSUES: usize = 4096;

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum QualityCategory {
    ProbeTruncated,
    InvalidValue,
    ClampedValue,
    DroppedValue,
    ReferentialIntegrity,
    UnavailableValue,
    Unclassified,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct QualityIssue {
    pub category: QualityCategory,
    pub scope: Option<String>,
    pub count: Option<i64>,
    pub message: Option<String>,
}

impl QualityIssue {
    /// Messages are human diagnostics. Only structured facts establish safety.
    pub fn into_machine(mut self) -> Result<Self, ContractError> {
        if self.category == QualityCategory::Unclassified
            || self
                .scope
                .as_deref()
                .is_some_and(|s| ALLOWED_SCOPES.binary_search(&s).is_err())
            || self.count.is_some_and(|count| count < 0)
        {
            return Err(ContractError::DataQualityNotMachineSafe);
        }
        self.message = None;
        Ok(self)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum QualityStatus {
    Ok,
    Warnings,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DataQuality {
    pub status: QualityStatus,
    pub warnings: Vec<QualityIssue>,
}

impl DataQuality {
    pub fn machine(
        status: QualityStatus,
        issues: Vec<QualityIssue>,
    ) -> Result<Self, ContractError> {
        if issues.len() > MAX_QUALITY_ISSUES {
            return Err(ContractError::QualityItemBudgetExceeded);
        }
        if (status == QualityStatus::Ok) != issues.is_empty() {
            return Err(ContractError::DataQualityStatusMismatch);
        }
        let mut warnings: Vec<_> = issues
            .into_iter()
            .map(QualityIssue::into_machine)
            .collect::<Result<_, _>>()?;
        // Match the Machine JSON category's raw string order, not enum order.
        warnings.sort_by_cached_key(|issue| {
            (
                issue.category.raw(),
                issue.scope.clone().unwrap_or_default(),
                issue.count.unwrap_or(i64::MIN),
            )
        });
        Ok(Self { status, warnings })
    }
}

impl QualityCategory {
    fn raw(self) -> &'static str {
        match self {
            Self::ProbeTruncated => "probeTruncated",
            Self::InvalidValue => "invalidValue",
            Self::ClampedValue => "clampedValue",
            Self::DroppedValue => "droppedValue",
            Self::ReferentialIntegrity => "referentialIntegrity",
            Self::UnavailableValue => "unavailableValue",
            Self::Unclassified => "unclassified",
        }
    }
}
