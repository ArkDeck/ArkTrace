use crate::{ContractError, QualityIssue};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DirectoryNameMatch {
    Exact,
    Prefix,
    Contains,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ProcessQuery {
    pub process_key: Option<i64>,
    pub pid: Option<i64>,
    pub name: Option<String>,
    pub name_match: DirectoryNameMatch,
    pub limit: usize,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ThreadQuery {
    pub process_key: Option<i64>,
    pub pid: Option<i64>,
    pub thread_key: Option<i64>,
    pub tid: Option<i64>,
    pub name: Option<String>,
    pub name_match: DirectoryNameMatch,
    pub limit: usize,
}
fn validate(name: Option<&str>, limit: usize) -> Result<(), ContractError> {
    if !(1..=100_000).contains(&limit) || name.is_some_and(|n| n.is_empty() || n.len() > 4096) {
        return Err(ContractError::InvalidDirectoryQuery);
    }
    Ok(())
}
impl ProcessQuery {
    pub fn validate(&self) -> Result<(), ContractError> {
        validate(self.name.as_deref(), self.limit)
    }
}
impl ThreadQuery {
    pub fn validate(&self) -> Result<(), ContractError> {
        validate(self.name.as_deref(), self.limit)
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TraceProcess {
    pub key: i64,
    pub pid: i64,
    pub name: Option<String>,
    pub start_ns: Option<i64>,
    pub end_ns: Option<i64>,
    pub thread_count: Option<i64>,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TraceThread {
    pub key: i64,
    pub process_key: Option<i64>,
    pub tid: i64,
    pub pid: Option<i64>,
    pub name: Option<String>,
    pub process_name: Option<String>,
    pub start_ns: Option<i64>,
    pub end_ns: Option<i64>,
    pub is_main_thread: Option<bool>,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DirectoryPage<T> {
    pub items: Vec<T>,
    pub truncated: bool,
    pub data_quality_issues: Vec<QualityIssue>,
}
