use crate::{EngineError, EngineFailure, EngineStage};
use arktrace_contract::{Code, PublicError, Stage};
use arktrace_platform::{HostError, ProcessError};
use arktrace_store::StoreError;

impl EngineError {
    pub fn public_error(self) -> PublicError {
        let stage = match self.stage {
            EngineStage::SourceSnapshot => Stage::Hashing,
            EngineStage::ParserIdentity => Stage::Preparing,
            EngineStage::Parsing => Stage::Parsing,
            EngineStage::Indexing => Stage::Indexing,
            EngineStage::Validating => Stage::Validating,
            EngineStage::Publishing | EngineStage::Closing => Stage::OpeningDatabase,
            EngineStage::Recovering => Stage::CacheLookup,
            EngineStage::Querying => Stage::Querying,
            EngineStage::Analyzing => Stage::Analyzing,
        };
        let make = |code| PublicError::new(code, stage);
        let cleanup = || PublicError::cleanup(stage, self.stage == EngineStage::Closing);
        let host = |error| match error {
            HostError::Cancelled => make(Code::Cancelled),
            HostError::DeadlineExceeded => make(Code::QueryTimeout),
            HostError::CleanupFailed => cleanup(),
            HostError::NotFound if self.stage == EngineStage::SourceSnapshot => {
                make(Code::TraceFileNotFound)
            }
            _ if self.stage == EngineStage::SourceSnapshot => make(Code::TraceFileUnreadable),
            _ if self.stage == EngineStage::Querying => make(Code::QueryFailed),
            _ if self.stage == EngineStage::Analyzing => make(Code::InternalError),
            _ => make(Code::TraceParseFailed),
        };
        match self.failure {
            EngineFailure::Analysis(error) => match error {
                crate::AnalysisFailure::InvalidBounds => make(Code::InvalidArgument),
                crate::AnalysisFailure::InputBudgetExceeded => make(Code::QueryLimitExceeded),
                crate::AnalysisFailure::InvalidEvidence
                | crate::AnalysisFailure::InvalidQuality => make(Code::InternalError),
            },
            EngineFailure::CleanupFailed => cleanup(),
            EngineFailure::Host(error) => host(error),
            EngineFailure::InvalidBudget => make(Code::InvalidArgument),
            EngineFailure::InvalidIdentity | EngineFailure::ParserVersionMismatch => {
                make(Code::TraceStreamerIdentityMismatch)
            }
            EngineFailure::InvalidMetadata if self.stage == EngineStage::SourceSnapshot => {
                make(Code::TraceFormatUnsupported)
            }
            EngineFailure::InvalidMetadata => make(Code::TraceDatabaseInvalid),
            EngineFailure::ParserExit { .. } => make(Code::TraceParseFailed),
            EngineFailure::Process(error) => match error {
                ProcessError::Cancelled => make(Code::Cancelled),
                ProcessError::DeadlineExceeded => make(Code::QueryTimeout),
                ProcessError::Host(error) => host(error),
                ProcessError::CleanupFailed => cleanup(),
                ProcessError::DigestMismatch
                | ProcessError::SignatureInvalid
                | ProcessError::TrustRejected
                | ProcessError::InvalidExecutable => make(Code::TraceStreamerIdentityMismatch),
                ProcessError::TrustUnavailable | ProcessError::LaunchFailed { .. } => {
                    make(Code::TraceStreamerUnavailable)
                }
                _ => make(Code::TraceParseFailed),
            },
            EngineFailure::Store(error) => match error {
                StoreError::NamedSliceDepthUnavailable => PublicError::missing_named_slice_depth(),
                StoreError::CounterSampleIdentityUnavailable(table) => {
                    PublicError::missing_counter_sample_identity(
                        table == arktrace_store::CounterSampleTable::ProcessMeasure,
                    )
                }
                StoreError::CounterQueryFailed => make(Code::QueryFailed),
                StoreError::InvalidFrameIdentity => PublicError::invalid_frame_identity(),
                StoreError::Host(error) => host(error),
                StoreError::Cancelled => make(Code::Cancelled),
                StoreError::DeadlineExceeded => make(Code::QueryTimeout),
                StoreError::CleanupFailed => cleanup(),
                StoreError::InvalidQuery => make(Code::InvalidArgument),
                StoreError::SchemaUnsupported | StoreError::SchemaBudgetExceeded => {
                    make(Code::TraceSchemaUnsupported)
                }
                StoreError::VmBudgetExceeded if self.stage == EngineStage::Querying => {
                    make(Code::QueryLimitExceeded)
                }
                StoreError::SQLite { .. } if self.stage == EngineStage::Querying => {
                    make(Code::QueryFailed)
                }
                _ => make(Code::TraceDatabaseInvalid),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn malformed_admitted_frame_identity_keeps_swift_closed_table_details() {
        let value = serde_json::to_value(
            EngineError {
                stage: EngineStage::Querying,
                failure: EngineFailure::Store(StoreError::InvalidFrameIdentity),
            }
            .public_error(),
        )
        .unwrap();
        assert_eq!(value["code"], "TRACE_DATABASE_INVALID");
        assert_eq!(value["stage"], "querying");
        assert_eq!(value["details"], serde_json::json!({"table":"frame_slice"}));
        assert_eq!(value["retryable"], false);
    }
    #[test]
    fn counter_identity_and_query_failures_have_closed_public_details() {
        for (table, name) in [
            (arktrace_store::CounterSampleTable::Measure, "measure"),
            (
                arktrace_store::CounterSampleTable::ProcessMeasure,
                "process_measure",
            ),
        ] {
            let value = serde_json::to_value(
                EngineError {
                    stage: EngineStage::Querying,
                    failure: EngineFailure::Store(StoreError::CounterSampleIdentityUnavailable(
                        table,
                    )),
                }
                .public_error(),
            )
            .unwrap();
            assert_eq!(value["code"], "TRACE_SCHEMA_UNSUPPORTED");
            assert_eq!(value["stage"], "querying");
            assert_eq!(
                value["details"],
                serde_json::json!({"missingCapability":"counterSampleIdentity","table":name})
            );
        }
        assert_eq!(
            EngineError {
                stage: EngineStage::Querying,
                failure: EngineFailure::Store(StoreError::CounterQueryFailed)
            }
            .public_error()
            .code(),
            Code::QueryFailed
        );
    }
    #[test]
    fn missing_named_depth_is_a_path_free_capability_error() {
        let error = EngineError {
            stage: EngineStage::Querying,
            failure: EngineFailure::Store(StoreError::NamedSliceDepthUnavailable),
        }
        .public_error();
        assert_eq!(error.code(), Code::TraceSchemaUnsupported);
        assert_eq!(error.stage(), Stage::Querying);
        let value = serde_json::to_value(error).unwrap();
        assert_eq!(
            value["details"],
            serde_json::json!({"missingCapability":"namedSliceDepth"})
        );
        assert_eq!(value["retryable"], false);
    }
    #[test]
    fn analysis_failures_keep_closed_codes_and_cancel_deadline_stage() {
        for (error, code, stage) in [
            (
                EngineFailure::Host(HostError::Cancelled),
                Code::Cancelled,
                Stage::Analyzing,
            ),
            (
                EngineFailure::Host(HostError::DeadlineExceeded),
                Code::QueryTimeout,
                Stage::Analyzing,
            ),
            (
                EngineFailure::Analysis(crate::AnalysisFailure::InvalidBounds),
                Code::InvalidArgument,
                Stage::Request,
            ),
            (
                EngineFailure::Analysis(crate::AnalysisFailure::InvalidEvidence),
                Code::InternalError,
                Stage::Analyzing,
            ),
            (
                EngineFailure::Analysis(crate::AnalysisFailure::InvalidQuality),
                Code::InternalError,
                Stage::Analyzing,
            ),
            (
                EngineFailure::Analysis(crate::AnalysisFailure::InputBudgetExceeded),
                Code::QueryLimitExceeded,
                Stage::Querying,
            ),
        ] {
            let value = EngineError {
                stage: EngineStage::Analyzing,
                failure: error,
            }
            .public_error();
            assert_eq!(value.code(), code);
            assert_eq!(value.stage(), stage);
        }
    }
    #[test]
    fn nested_budget_errors_keep_their_code_and_cleanup_has_priority() {
        for failure in [
            EngineFailure::Host(HostError::Cancelled),
            EngineFailure::Process(ProcessError::Host(HostError::Cancelled)),
            EngineFailure::Store(StoreError::Cancelled),
        ] {
            let error = EngineError {
                stage: EngineStage::Querying,
                failure,
            }
            .public_error();
            assert_eq!(error.code(), Code::Cancelled);
            assert_eq!(error.stage(), Stage::Querying);
        }
        let timeout = EngineError {
            stage: EngineStage::Indexing,
            failure: EngineFailure::Store(StoreError::DeadlineExceeded),
        }
        .public_error();
        assert_eq!(timeout.code(), Code::QueryTimeout);
        assert_eq!(timeout.stage(), Stage::Parsing);
        assert!(
            EngineError {
                stage: EngineStage::Closing,
                failure: EngineFailure::CleanupFailed
            }
            .public_error()
            .is_cleanup_failure()
        );
    }
}
