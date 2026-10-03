//! Closed public error vocabulary shared by CLI and future SDK adapters.
use serde::Serialize;
use std::collections::BTreeMap;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum Code {
    InvalidArgument,
    TraceFileNotFound,
    TraceFileUnreadable,
    TraceFormatUnsupported,
    TraceStreamerUnavailable,
    TraceStreamerIdentityMismatch,
    TraceParseFailed,
    TraceSchemaUnsupported,
    TraceDatabaseInvalid,
    TraceCacheCorrupt,
    QueryFailed,
    QueryTimeout,
    QueryLimitExceeded,
    OutputLimitExceeded,
    AnalysisUnsupported,
    Cancelled,
    InternalError,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Stage {
    Request,
    Preparing,
    Hashing,
    CacheLookup,
    Parsing,
    Validating,
    Indexing,
    OpeningDatabase,
    Querying,
    Analyzing,
    Encoding,
}
impl Code {
    pub fn message(self) -> &'static str {
        match self {
            Self::InvalidArgument => "The request arguments are invalid.",
            Self::TraceFileNotFound => "The trace file was not found.",
            Self::TraceFileUnreadable => "The trace file is not readable.",
            Self::TraceFormatUnsupported => "The trace format is not supported.",
            Self::TraceStreamerUnavailable => "The pinned trace parser is unavailable.",
            Self::TraceStreamerIdentityMismatch => "The trace parser identity is invalid.",
            Self::TraceParseFailed => "The trace could not be parsed.",
            Self::TraceSchemaUnsupported => "The parsed trace schema is not supported.",
            Self::TraceDatabaseInvalid => "The parsed trace database is invalid.",
            Self::TraceCacheCorrupt => "The trace cache entry is invalid.",
            Self::QueryFailed => "The trace query failed.",
            Self::QueryTimeout => "The trace operation reached its deadline.",
            Self::QueryLimitExceeded => "The trace query exceeded its row budget.",
            Self::OutputLimitExceeded => "The machine output exceeded its byte budget.",
            Self::AnalysisUnsupported => "The requested analysis is not supported.",
            Self::Cancelled => "The trace operation was cancelled.",
            Self::InternalError => "ArkTrace encountered an internal error.",
        }
    }
    pub fn exit_status(self) -> i32 {
        match self {
            Self::InvalidArgument => 2,
            Self::TraceFileNotFound | Self::TraceFileUnreadable | Self::TraceFormatUnsupported => 3,
            Self::TraceStreamerUnavailable
            | Self::TraceStreamerIdentityMismatch
            | Self::TraceParseFailed => 4,
            Self::TraceSchemaUnsupported | Self::TraceDatabaseInvalid | Self::TraceCacheCorrupt => {
                5
            }
            Self::QueryFailed | Self::AnalysisUnsupported => 6,
            Self::QueryTimeout | Self::QueryLimitExceeded | Self::OutputLimitExceeded => 7,
            Self::Cancelled => 8,
            Self::InternalError => 9,
        }
    }
    fn stages(self) -> &'static [Stage] {
        use Stage::*;
        match self {
            Self::InvalidArgument => &[Request, Preparing, CacheLookup],
            Self::TraceFileNotFound => &[Preparing],
            Self::TraceFileUnreadable => &[Preparing, Hashing],
            Self::TraceFormatUnsupported => &[Parsing],
            Self::TraceStreamerUnavailable => &[Preparing, Parsing],
            Self::TraceStreamerIdentityMismatch => &[Preparing],
            Self::TraceParseFailed => &[Preparing, Parsing, Indexing, OpeningDatabase],
            Self::TraceSchemaUnsupported => &[Validating, Querying],
            Self::TraceDatabaseInvalid => &[Validating, Indexing, OpeningDatabase, Querying],
            Self::TraceCacheCorrupt => &[CacheLookup],
            Self::QueryFailed | Self::QueryLimitExceeded => &[Querying],
            Self::QueryTimeout => &[Request, Parsing, Querying, Analyzing, Encoding],
            Self::OutputLimitExceeded => &[Encoding],
            Self::AnalysisUnsupported => &[Analyzing],
            Self::Cancelled | Self::InternalError => &[
                Request,
                Preparing,
                Hashing,
                CacheLookup,
                Parsing,
                Validating,
                Indexing,
                OpeningDatabase,
                Querying,
                Analyzing,
                Encoding,
            ],
        }
    }
    fn retryable(self) -> bool {
        matches!(
            self,
            Self::TraceStreamerUnavailable
                | Self::TraceCacheCorrupt
                | Self::QueryTimeout
                | Self::QueryLimitExceeded
                | Self::OutputLimitExceeded
                | Self::Cancelled
        )
    }
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct PublicError {
    code: Code,
    message: &'static str,
    retryable: bool,
    stage: Stage,
    details: BTreeMap<&'static str, &'static str>,
}
impl PublicError {
    pub fn new(code: Code, stage: Stage) -> Self {
        let stage = if code.stages().contains(&stage) {
            stage
        } else if code == Code::QueryTimeout && stage != Stage::Request {
            Stage::Parsing
        } else {
            code.stages()[0]
        };
        Self {
            code,
            message: code.message(),
            retryable: code.retryable(),
            stage,
            details: BTreeMap::new(),
        }
    }
    pub fn cleanup(stage: Stage, session: bool) -> Self {
        let mut value = Self::new(Code::TraceParseFailed, stage);
        value.retryable = true;
        value.details.insert(
            "reason",
            if session {
                "sessionCleanupFailed"
            } else {
                "stagingCleanupFailed"
            },
        );
        value
    }
    pub fn missing_named_slice_depth() -> Self {
        let mut value = Self::new(Code::TraceSchemaUnsupported, Stage::Querying);
        value.details.insert("missingCapability", "namedSliceDepth");
        value
    }
    pub fn invalid_frame_identity() -> Self {
        let mut value = Self::new(Code::TraceDatabaseInvalid, Stage::Querying);
        value.details.insert("table", "frame_slice");
        value
    }
    pub fn missing_counter_sample_identity(process_measure: bool) -> Self {
        let mut value = Self::new(Code::TraceSchemaUnsupported, Stage::Querying);
        value
            .details
            .insert("missingCapability", "counterSampleIdentity");
        value.details.insert(
            "table",
            if process_measure {
                "process_measure"
            } else {
                "measure"
            },
        );
        value
    }
    pub fn code(&self) -> Code {
        self.code
    }
    pub fn stage(&self) -> Stage {
        self.stage
    }
    pub fn is_cleanup_failure(&self) -> bool {
        self.code == Code::TraceParseFailed && self.retryable
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn errors_cannot_publish_invalid_stage_retryability_or_unbounded_details() {
        let codes = [
            Code::InvalidArgument,
            Code::TraceFileNotFound,
            Code::TraceFileUnreadable,
            Code::TraceFormatUnsupported,
            Code::TraceStreamerUnavailable,
            Code::TraceStreamerIdentityMismatch,
            Code::TraceParseFailed,
            Code::TraceSchemaUnsupported,
            Code::TraceDatabaseInvalid,
            Code::TraceCacheCorrupt,
            Code::QueryFailed,
            Code::QueryTimeout,
            Code::QueryLimitExceeded,
            Code::OutputLimitExceeded,
            Code::AnalysisUnsupported,
            Code::Cancelled,
            Code::InternalError,
        ];
        let stages = [
            Stage::Request,
            Stage::Preparing,
            Stage::Hashing,
            Stage::CacheLookup,
            Stage::Parsing,
            Stage::Validating,
            Stage::Indexing,
            Stage::OpeningDatabase,
            Stage::Querying,
            Stage::Analyzing,
            Stage::Encoding,
        ];
        for code in codes {
            for stage in stages {
                let error = PublicError::new(code, stage);
                assert!(code.stages().contains(&error.stage));
                assert_eq!(error.retryable, code.retryable());
                assert!(error.details.is_empty());
                let json = serde_json::to_value(error).unwrap();
                assert_eq!(json.as_object().unwrap().len(), 5);
                assert_eq!(json["message"], code.message());
            }
        }
        let cleanup = PublicError::cleanup(Stage::Encoding, true);
        assert_eq!(cleanup.stage(), Stage::Preparing);
        assert!(cleanup.is_cleanup_failure());
        assert_eq!(
            serde_json::to_value(cleanup).unwrap()["details"]["reason"],
            "sessionCleanupFailed"
        );
    }
}
