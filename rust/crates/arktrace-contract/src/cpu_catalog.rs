use crate::{ContractError, EventPage, ProcessKey, TraceTimeRange};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CpuCatalogQuery {
    pub range: TraceTimeRange,
    pub limit: usize,
    pub activity_limit: usize,
}
impl CpuCatalogQuery {
    pub fn validate(&self) -> Result<(), ContractError> {
        if self.range.is_instant()
            || !(1..=4096).contains(&self.limit)
            || !(1..=20_000).contains(&self.activity_limit)
        {
            return Err(ContractError::InvalidEventQuery);
        }
        Ok(())
    }
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CpuIdentity {
    pub cpu: i64,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CpuActivity {
    pub process_key: Option<ProcessKey>,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CpuCatalog {
    pub cpus: EventPage<CpuIdentity>,
    pub activity: EventPage<CpuActivity>,
}
