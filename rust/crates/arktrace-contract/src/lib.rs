//! Platform-independent migration contracts. No filesystem, SQL or device IO.
mod arguments;
mod batch;
mod cache;
mod counters;
mod density;
mod directory;
mod error;
mod events;
mod frames;
mod parser;
mod quality;
mod search;
mod slices;
mod time;

pub use arguments::{TraceArgumentQuery, TraceEventArgument};
pub use batch::{
    TraceRepositoryEventBatch, TraceRepositoryEventBatchResult, TraceRepositoryThread,
};
pub use cache::{TraceCacheKey, WINDOWS_LEASE_LENGTH, WINDOWS_LEASE_OFFSET};
pub use counters::{
    CounterQuery, CounterSample, CounterScope, CounterSeries, CounterSeriesDescriptor,
    CounterSeriesQuery, TraceAgentCounterEvent,
};
pub use density::{
    TraceDensityBucket, TraceDensityIdentity, TraceDensityQuery, TraceDensityResult,
    TraceDensitySource,
};
pub use directory::{
    DirectoryNameMatch, DirectoryPage, ProcessQuery, ThreadQuery, TraceProcess, TraceThread,
};
pub use error::{Code, PublicError, Stage};
pub use events::{
    CpuSlice, CpuSliceQuery, EventKey, EventPage, EventTable, ProcessKey, ThreadKey,
    ThreadStateInterval, ThreadStateQuery, TraceThreadState,
};
pub use frames::{TraceFrame, TraceFrameKind, TraceFrameQuery};
pub use parser::TraceParserIdentity;
pub use quality::{DataQuality, QualityCategory, QualityIssue, QualityStatus};
pub use search::{
    SearchDomains, TraceSearchRequest, TraceSearchResult, TraceSearchResultKind, TraceSearchResults,
};
pub use slices::{TraceSlice, TraceSliceQuery};
pub use time::TraceTimeRange;

pub const MACHINE_JSON_VERSION: &str = "1.0";
pub const PARSER_ADAPTER_VERSION: &str = "1";
pub const SCHEMA_ADAPTER_VERSION: &str = "2";
pub const INDEX_SCHEMA_VERSION: u32 = 3;

#[derive(Clone, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TraceCapabilities {
    pub cpu_scheduling: bool,
    pub thread_states: bool,
    pub named_slices: bool,
    pub cpu_counters: bool,
    pub process_counters: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ContractError {
    InvalidTimeRange,
    DegenerateQueryRange,
    DataQualityNotMachineSafe,
    DataQualityStatusMismatch,
    QualityItemBudgetExceeded,
    InvalidCacheIdentity,
    InvalidParserIdentity,
    InvalidDirectoryQuery,
    InvalidEventQuery,
}
