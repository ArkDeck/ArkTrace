//! Shared SQLite semantics. SQL and connection state are private. Native ports
//! bind immutable snapshots; Engine retains lifetime and publication authority.
//! Successful inspection alone does not establish an indexed Ready entry.
#[cfg(any(target_os = "macos", test))]
mod arguments;
#[cfg(any(target_os = "macos", test))]
mod counters;
#[cfg(any(target_os = "macos", test))]
mod database;
#[cfg(any(target_os = "macos", test))]
mod density;
#[cfg(any(target_os = "macos", test))]
mod directory;
#[cfg(any(target_os = "macos", test))]
mod events;
#[cfg(any(target_os = "macos", test))]
mod frames;
#[cfg(any(target_os = "macos", test))]
mod indexes;
#[cfg(target_os = "macos")]
mod reader;
#[cfg(any(target_os = "macos", test))]
mod schema;
#[cfg(any(target_os = "macos", test))]
mod slices;
#[cfg(target_os = "macos")]
pub use reader::StoreReader;
#[cfg(test)]
mod argument_oracle_tests;
#[cfg(test)]
mod density_oracle_tests;
#[cfg(test)]
mod event_oracle_tests;
#[cfg(test)]
mod tests;

use arktrace_contract::DataQuality;
pub use arktrace_contract::TraceCapabilities;
use arktrace_platform::{CancellationToken, HostError};
use serde::Serialize;
use std::time::Instant;

pub const SQLITE_VERSION: &str = "3.53.2";
pub const SQLITE_SOURCE_ID: &str =
    "2026-06-03 19:12:13 d6e03d8c777cfa2d35e3b60d8ec3e0187f3e9f99d8e2ee9cac695fd6fcdf1a24";
pub const RELATIONSHIP_VM_BUDGET: u64 = 250_000;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SQLiteRuntimeFacts {
    pub version: String,
    pub source_id: String,
    pub compile_options: Vec<String>,
    pub file_stat_function_available: bool,
}

#[cfg(target_os = "macos")]
pub fn sqlite_runtime_facts(budget: &ValidationBudget) -> Result<SQLiteRuntimeFacts, StoreError> {
    let connection = rusqlite::Connection::open_in_memory().map_err(database::sqlite_error)?;
    database::Database::new(connection, budget)?.runtime_facts()
}

#[derive(Clone, Debug)]
pub struct ValidationBudget {
    pub maximum_database_bytes: u64,
    pub deadline: Instant,
    pub cancellation: CancellationToken,
}
impl ValidationBudget {
    #[cfg(any(target_os = "macos", test))]
    pub(crate) fn check(&self) -> Result<(), StoreError> {
        if self.maximum_database_bytes == 0 || self.maximum_database_bytes > i64::MAX as u64 {
            return Err(StoreError::InvalidBudget);
        }
        if self.cancellation.is_cancelled() {
            return Err(StoreError::Cancelled);
        }
        if Instant::now() >= self.deadline {
            return Err(StoreError::DeadlineExceeded);
        }
        Ok(())
    }
}

/// Closed facts only: no SQLite diagnostic prose, SQL, or user path.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub enum StoreError {
    InvalidBudget,
    InvalidQuery,
    Host(HostError),
    Cancelled,
    DeadlineExceeded,
    VmBudgetExceeded,
    SchemaBudgetExceeded,
    SchemaUnsupported,
    NamedSliceDepthUnavailable,
    CounterSampleIdentityUnavailable(CounterSampleTable),
    CounterQueryFailed,
    InvalidDatabase,
    InvalidIdentity,
    InvalidFrameIdentity,
    BrokenRelationship,
    AmbiguousCounterIdentity,
    SQLite { code: i32 },
    SQLiteRuntimeMismatch,
    InvalidQualityContract,
    InvalidIndexContract,
    InvalidReadyIndexes,
    CleanupFailed,
}
impl From<HostError> for StoreError {
    fn from(value: HostError) -> Self {
        match value {
            HostError::Cancelled => Self::Cancelled,
            HostError::DeadlineExceeded => Self::DeadlineExceeded,
            value => Self::Host(value),
        }
    }
}
impl std::fmt::Display for StoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for StoreError {}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize)]
pub enum CounterSampleTable {
    #[serde(rename = "measure")]
    Measure,
    #[serde(rename = "process_measure")]
    ProcessMeasure,
}
impl CounterSampleTable {
    #[cfg(any(target_os = "macos", test))]
    pub(crate) fn name(self) -> &'static str {
        match self {
            Self::Measure => "measure",
            Self::ProcessMeasure => "process_measure",
        }
    }
}

/// Absolute parser timestamps stay internal to the Store/Engine composition.
/// Consumers will receive trace-relative Int64 values through typed queries.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DatabaseInspection {
    pub capabilities: TraceCapabilities,
    pub schema_fingerprint: String,
    pub trace_start_ts: i64,
    pub trace_end_ts: i64,
    pub duration_ns: i64,
    pub data_quality: DataQuality,
    pub event_source_counts_available: bool,
    pub cpu_counter_sample_tables: Vec<CounterSampleTable>,
    pub process_counter_sample_tables: Vec<CounterSampleTable>,
}

#[cfg(target_os = "macos")]
pub use indexes::{IndexPhase, IndexProgress};
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DatabasePreparation {
    pub schema_adapter_version: String,
    pub index_schema_version: u32,
    pub inspection: DatabaseInspection,
    pub applicable_index_names: Vec<String>,
    pub upstream_database_sha256: String,
    pub upstream_database_byte_count: u64,
    pub prepared_database_sha256: String,
    pub prepared_database_byte_count: u64,
}
#[cfg(target_os = "macos")]
pub struct PreparedDatabase {
    pub snapshot: arktrace_platform::HeldFile,
    pub preparation: DatabasePreparation,
}
#[cfg(target_os = "macos")]
pub fn prepare_snapshot(
    source: &arktrace_platform::HeldFile,
    destination: &arktrace_platform::HeldDirectory,
    name: &str,
    budget: &ValidationBudget,
    progress: impl FnMut(IndexProgress),
) -> Result<PreparedDatabase, StoreError> {
    budget.check()?;
    // Validate the source's standalone header without doing semantic probes
    // before the bootstrap indexes exist. Never mutate this source snapshot.
    source.readonly_database_path()?;
    let io = arktrace_platform::IoBudget {
        maximum_bytes: budget.maximum_database_bytes,
        deadline: budget.deadline,
        cancellation: budget.cancellation.clone(),
    };
    let header = source.read_prefix(100, &io)?;
    if header.len() != 100
        || &header[..16] != b"SQLite format 3\0"
        || header[18] != 1
        || header[19] != 1
    {
        return Err(StoreError::InvalidDatabase);
    }
    let (writable, upstream) = destination.copy_writable_candidate(source, name, &io)?;
    let (inspection, names) = writable.with_sqlite_connection(&io, |connection| {
        let mut db = database::Database::borrow_writable(connection, budget)?;
        db.bind_writable(writable.clone())?;
        indexes::prepare(&db, progress)
    })?;
    source.verify()?;
    let writable = std::sync::Arc::try_unwrap(writable).map_err(|_| StoreError::CleanupFailed)?;
    let snapshot = writable.seal_readonly(&io)?;
    let prepared = snapshot.facts(&io)?;
    budget.check()?;
    Ok(PreparedDatabase {
        snapshot,
        preparation: DatabasePreparation {
            schema_adapter_version: arktrace_contract::SCHEMA_ADAPTER_VERSION.to_owned(),
            index_schema_version: arktrace_contract::INDEX_SCHEMA_VERSION,
            inspection,
            applicable_index_names: names,
            upstream_database_sha256: upstream.sha256,
            upstream_database_byte_count: upstream.byte_count,
            prepared_database_sha256: prepared.sha256,
            prepared_database_byte_count: prepared.byte_count,
        },
    })
}

#[cfg(target_os = "macos")]
pub fn inspect_snapshot(
    source: &arktrace_platform::HeldFile,
    budget: &ValidationBudget,
) -> Result<DatabaseInspection, StoreError> {
    with_readonly_snapshot(source, budget, |db| db.inspect())
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IndexedDatabaseInspection {
    pub inspection: DatabaseInspection,
    pub applicable_index_names: Vec<String>,
}

#[cfg(target_os = "macos")]
pub fn inspect_indexed_snapshot(
    source: &arktrace_platform::HeldFile,
    budget: &ValidationBudget,
) -> Result<IndexedDatabaseInspection, StoreError> {
    with_readonly_snapshot(source, budget, |db| {
        Ok(IndexedDatabaseInspection {
            inspection: db.inspect()?,
            applicable_index_names: indexes::validate(db)?,
        })
    })
}

#[cfg(target_os = "macos")]
fn with_readonly_snapshot<T>(
    source: &arktrace_platform::HeldFile,
    budget: &ValidationBudget,
    body: impl FnOnce(&database::Database<'_>) -> Result<T, StoreError>,
) -> Result<T, StoreError> {
    let connection = open_snapshot_connection(source, budget)?;
    let result = body(&database::Database::new(connection, budget)?);
    source.readonly_database_path()?;
    budget.check()?;
    result
}

#[cfg(target_os = "macos")]
fn open_snapshot_connection(
    source: &arktrace_platform::HeldFile,
    budget: &ValidationBudget,
) -> Result<rusqlite::Connection, StoreError> {
    budget.check()?;
    let path = source.readonly_database_path()?;
    let header = source.read_prefix(
        100,
        &arktrace_platform::IoBudget {
            maximum_bytes: budget.maximum_database_bytes,
            deadline: budget.deadline,
            cancellation: budget.cancellation.clone(),
        },
    )?;
    // A standalone immutable snapshot cannot depend on a WAL/hot journal that
    // lives outside this held descriptor. Engine must finish/checkpoint first.
    if header.len() != 100
        || &header[..16] != b"SQLite format 3\0"
        || header[18] != 1
        || header[19] != 1
    {
        return Err(StoreError::InvalidDatabase);
    }
    let connection = database::open_readonly(&path)?;
    // The HeldFile borrow outlives the connection. Check binding after SQLite's
    // native open and again after all work, including failed validation.
    source.readonly_database_path()?;
    Ok(connection)
}
