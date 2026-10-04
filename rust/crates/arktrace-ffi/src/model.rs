use crate::abi_records::*;
use arktrace_contract::*;
use serde::Deserialize;
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct EngineConfig {
    pub abi_version: u32,
    pub contract_digest: String,
    pub cache_policy: String,
    pub namespace: String,
    pub helper: String,
    pub parser: String,
    #[serde(rename = "helperSHA256")]
    pub helper_sha256: String,
    pub parser_identity: TraceParserIdentity,
    pub publisher: Option<Publisher>,
    #[serde(default)]
    pub limits: Limits,
}
/// Immutable product signing expectations, separate from every query.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Publisher {
    team_identifier: String,
    helper_code_identifier: String,
    parser_code_identifier: String,
}
impl Publisher {
    fn validate(&self) -> Result<(), u32> {
        if self.team_identifier.len() != 10
            || !self
                .team_identifier
                .bytes()
                .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit())
            || [&self.helper_code_identifier, &self.parser_code_identifier]
                .into_iter()
                .any(|s| {
                    s.is_empty()
                        || s.len() > 256
                        || !s
                            .bytes()
                            .all(|b| b.is_ascii_alphanumeric() || b".-_".contains(&b))
                })
        {
            return Err(STATUS_INVALID_INPUT);
        }
        Ok(())
    }
}
#[derive(Deserialize)]
#[serde(default, rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Limits {
    workers: usize,
    sessions: usize,
    requests: usize,
    queue_per_worker: usize,
    maximum_result_bytes: usize,
    maximum_retained_result_bytes: usize,
    maximum_source_bytes: u64,
    maximum_database_bytes: u64,
}
impl Default for Limits {
    fn default() -> Self {
        Self {
            workers: 2,
            sessions: 8,
            requests: 64,
            queue_per_worker: 16,
            maximum_result_bytes: 16 * 1024 * 1024,
            maximum_retained_result_bytes: 128 * 1024 * 1024,
            maximum_source_bytes: 2 * 1024 * 1024 * 1024,
            maximum_database_bytes: 2 * 1024 * 1024 * 1024,
        }
    }
}
impl EngineConfig {
    pub fn validate(&self, fixture: bool) -> Result<(), u32> {
        if self.abi_version != ABI_VERSION || self.contract_digest != CONTRACT_DIGEST_HEX {
            return Err(STATUS_ABI_MISMATCH);
        }
        if self.cache_policy != "ephemeral" {
            return Err(STATUS_UNSUPPORTED_OPERATION);
        }
        if let Some(publisher) = &self.publisher {
            publisher.validate()?;
        } else if !fixture {
            return Err(STATUS_INVALID_INPUT);
        }
        if [&self.namespace, &self.helper, &self.parser]
            .into_iter()
            .any(|s| s.is_empty() || s.len() > MAXIMUM_PATH_BYTES as usize || s.contains('\0'))
            || self.helper_sha256.len() != 64
            || !self
                .helper_sha256
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            || self.parser_identity.validate().is_err()
        {
            return Err(STATUS_INVALID_INPUT);
        }
        let l = &self.limits;
        if !(1..=4).contains(&l.workers)
            || !(1..=8).contains(&l.sessions)
            || !(1..=128).contains(&l.requests)
            || !(1..=64).contains(&l.queue_per_worker)
            || !(1..=16 * 1024 * 1024).contains(&l.maximum_result_bytes)
            || !(1..=256 * 1024 * 1024).contains(&l.maximum_retained_result_bytes)
            || l.maximum_source_bytes == 0
            || l.maximum_database_bytes == 0
            || l.maximum_source_bytes > i64::MAX as u64
            || l.maximum_database_bytes > i64::MAX as u64
        {
            return Err(STATUS_INVALID_INPUT);
        }
        Ok(())
    }
    #[cfg(target_os = "macos")]
    pub fn native(self, fixture: bool) -> Result<arktrace_engine::RuntimeConfiguration, u32> {
        use arktrace_engine::{CodeTrustPolicy, RuntimeConfiguration, RuntimeLimits};
        let (helper_trust, parser_trust) = if fixture {
            (
                CodeTrustPolicy::DevelopmentPinned,
                CodeTrustPolicy::DevelopmentPinned,
            )
        } else {
            let p = self.publisher.ok_or(STATUS_INVALID_INPUT)?;
            (
                CodeTrustPolicy::DeveloperId {
                    team_identifier: p.team_identifier.clone(),
                    code_identifier: p.helper_code_identifier,
                },
                CodeTrustPolicy::DeveloperId {
                    team_identifier: p.team_identifier,
                    code_identifier: p.parser_code_identifier,
                },
            )
        };
        let mut c = RuntimeConfiguration::new(
            self.namespace.into(),
            self.helper.into(),
            self.parser.into(),
            self.helper_sha256,
            self.parser_identity,
            parser_trust,
        );
        c.helper_trust = helper_trust;
        let l = self.limits;
        c.limits = RuntimeLimits {
            workers: l.workers,
            sessions: l.sessions,
            requests: l.requests,
            queue_per_worker: l.queue_per_worker,
            maximum_result_bytes: l.maximum_result_bytes,
            maximum_retained_result_bytes: l.maximum_retained_result_bytes,
            maximum_source_bytes: l.maximum_source_bytes,
            maximum_database_bytes: l.maximum_database_bytes,
        };
        Ok(c)
    }
}
#[derive(Deserialize)]
#[serde(
    tag = "operation",
    content = "query",
    rename_all = "camelCase",
    deny_unknown_fields
)]
pub(crate) enum Operation {
    SummaryFacts(TraceSummaryQuery),
    Processes(ProcessQuery),
    Threads(ThreadQuery),
    CpuSlices(CpuSliceQuery),
    ThreadStates(ThreadStateQuery),
    Slices(TraceSliceQuery),
    SliceDetails(TraceSliceQuery),
    Counters(CounterQuery),
    CounterSeries(CounterSeriesQuery),
    Frames(TraceFrameQuery),
    Arguments(TraceArgumentQuery),
    Density(TraceDensityQuery),
    ViewerDetails(Details),
    Viewport(ViewportInput),
    ResolveDensity(arktrace_viewer::DensityResolutionRequest),
    Batch(TraceRepositoryEventBatch),
    BatchDetails(TraceRepositoryEventBatch),
    BatchDetailsWithDeadlines(arktrace_engine::DeadlineBatch),
    Search(TraceSearchRequest),
    Analyze(Analyze),
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Details {
    source: TraceDensitySource,
    range: TraceTimeRange,
    limit: usize,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ViewportInput {
    request: Box<arktrace_viewer::ViewportRequest>,
    backing_scale: f64,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Analyze {
    request: arktrace_engine::BoundedAnalysisRequest,
    #[serde(default)]
    scope: Scope,
}
#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Scope {
    process_key: Option<i64>,
    pid: Option<i64>,
    thread_key: Option<i64>,
    tid: Option<i64>,
}
impl Operation {
    pub fn validate(&self) -> Result<(), u32> {
        let result = match self {
            Self::SummaryFacts(q) => q.validate(),
            Self::Processes(q) => q.validate(),
            Self::Threads(q) => q.validate(),
            Self::CpuSlices(q) => q.validate(),
            Self::ThreadStates(q) => q.validate(),
            Self::Slices(q) | Self::SliceDetails(q) => q.validate(),
            Self::Counters(q) => q.validate(),
            Self::CounterSeries(q) => q.validate(),
            Self::Frames(q) => q.validate(),
            Self::Arguments(q) => q.validate(),
            Self::Density(q) => q.validate(),
            Self::Batch(q) | Self::BatchDetails(q) => q.validate(),
            Self::BatchDetailsWithDeadlines(q) => q.validate(),
            Self::Search(q) => q.validate(),
            Self::ViewerDetails(q) => {
                return arktrace_viewer::detail_query(&q.source, q.range, q.limit)
                    .map(|_| ())
                    .map_err(|_| STATUS_INVALID_INPUT);
            }
            Self::Viewport(q) => {
                return q
                    .request
                    .effective_budget()
                    .map_err(|_| STATUS_INVALID_INPUT)
                    .and_then(|_| {
                        if q.backing_scale.is_finite() && q.backing_scale > 0.0 {
                            Ok(())
                        } else {
                            Err(STATUS_INVALID_INPUT)
                        }
                    });
            }
            Self::ResolveDensity(q) => return q.validate().map_err(|_| STATUS_INVALID_INPUT),
            Self::Analyze(q) => {
                q.request.validate().map_err(|_| STATUS_INVALID_INPUT)?;
                let s = &q.scope;
                if s.process_key == Some(0)
                    || s.thread_key == Some(0)
                    || s.pid.is_some_and(|v| v < 0)
                    || s.tid.is_some_and(|v| v < 0)
                    || (s.process_key.is_some() && s.pid.is_some())
                    || (s.thread_key.is_some() && s.tid.is_some())
                {
                    return Err(STATUS_INVALID_INPUT);
                }
                return Ok(());
            }
        };
        result.map_err(|_| STATUS_INVALID_INPUT)
    }
    #[cfg(target_os = "macos")]
    pub fn native(self) -> arktrace_engine::RepositoryRequest {
        use arktrace_engine::RepositoryRequest as Q;
        match self {
            Self::SummaryFacts(q) => Q::SummaryFacts(q),
            Self::Processes(q) => Q::Processes(q),
            Self::Threads(q) => Q::Threads(q),
            Self::CpuSlices(q) => Q::CpuSlices(q),
            Self::ThreadStates(q) => Q::ThreadStates(q),
            Self::Slices(q) => Q::Slices(q),
            Self::SliceDetails(q) => Q::SliceDetails(q),
            Self::Counters(q) => Q::Counters(q),
            Self::CounterSeries(q) => Q::CounterSeries(q),
            Self::Frames(q) => Q::Frames(q),
            Self::Arguments(q) => Q::Arguments(q),
            Self::Density(q) => Q::Density(q),
            Self::ViewerDetails(q) => Q::ViewerDetails {
                source: q.source,
                range: q.range,
                limit: q.limit,
            },
            Self::Viewport(q) => Q::ViewerViewport {
                request: q.request,
                backing_scale: q.backing_scale,
            },
            Self::ResolveDensity(q) => Q::ViewerResolveDensity(q),
            Self::Batch(q) => Q::Batch(q),
            Self::BatchDetails(q) => Q::BatchDetails(q),
            Self::BatchDetailsWithDeadlines(q) => Q::BatchDetailsWithDeadlines(q),
            Self::Search(q) => Q::Search(q),
            Self::Analyze(q) => Q::Analyze {
                request: q.request,
                scope: arktrace_engine::AnalysisScope {
                    process_key: q.scope.process_key,
                    pid: q.scope.pid,
                    thread_key: q.scope.thread_key,
                    tid: q.scope.tid,
                },
            },
        }
    }
}
pub(crate) fn decode<T: serde::de::DeserializeOwned>(bytes: &[u8]) -> Result<T, u32> {
    serde_json::from_slice(bytes).map_err(|_| STATUS_INVALID_INPUT)
}

#[cfg(test)]
mod sdk_slice_tests {
    use super::*;

    #[test]
    fn timed_detail_batch_admission_requires_paired_closed_absolute_deadlines() {
        let thread = serde_json::json!({"nameMatch":"exact","limit":1});
        let input = serde_json::json!({"operation":"batchDetailsWithDeadlines", "query": {
            "batch":{"threads":[thread]}, "deadlines":{"clock":"hostContinuousEpochV1",
                "cpuSlices":[],"threadStates":[],"slices":[],"counters":[],"counterSeries":[],"densities":[],"threads":[null]}}});
        let value: Operation = decode(&serde_json::to_vec(&input).unwrap()).unwrap();
        value.validate().unwrap();
        let mut mismatched = input.clone();
        mismatched["query"]["deadlines"]["threads"] = serde_json::json!([]);
        let value: Operation = decode(&serde_json::to_vec(&mismatched).unwrap()).unwrap();
        assert_eq!(value.validate(), Err(STATUS_INVALID_INPUT));
        let mut noncanonical = input.clone();
        noncanonical["query"]["deadlines"]["threads"][0] =
            serde_json::json!({"seconds":1,"attoseconds":-1});
        let value: Operation = decode(&serde_json::to_vec(&noncanonical).unwrap()).unwrap();
        assert_eq!(value.validate(), Err(STATUS_INVALID_INPUT));
        for (path, replacement) in [
            ("clock", serde_json::json!("wall")),
            (
                "threads",
                serde_json::json!([{"seconds":0,"attoseconds":1.5}]),
            ),
        ] {
            let mut value = input.clone();
            value["query"]["deadlines"][path] = replacement;
            assert!(decode::<Operation>(&serde_json::to_vec(&value).unwrap()).is_err());
        }
        let mut value = input;
        value["query"]["sql"] = serde_json::json!("SELECT 1");
        assert!(decode::<Operation>(&serde_json::to_vec(&value).unwrap()).is_err());
    }

    #[test]
    fn detail_batch_keeps_legacy_batch_bounds_and_closed_queries() {
        let thread = serde_json::json!({"processKey":null,"pid":null,"threadKey":null,"tid":null,"name":null,"nameMatch":"exact","limit":1});
        for name in ["batchDetails", "batch"] {
            for count in [1, 32] {
                let input = serde_json::json!({"operation":name,"query":{"threads":vec![thread.clone();count]}});
                let valid: Operation = decode(&serde_json::to_vec(&input).unwrap()).unwrap();
                valid.validate().unwrap();
            }
            for count in [0, 33] {
                let input = serde_json::json!({"operation":name,"query":{"threads":vec![thread.clone();count]}});
                let invalid: Operation = decode(&serde_json::to_vec(&input).unwrap()).unwrap();
                assert_eq!(invalid.validate(), Err(STATUS_INVALID_INPUT));
            }
            let mut input =
                serde_json::json!({"operation":name,"query":{"threads":[thread.clone()]}});
            input["query"]["threads"][0]["sql"] = "SELECT 1".into();
            assert!(decode::<Operation>(&serde_json::to_vec(&input).unwrap()).is_err());
        }
    }

    #[test]
    fn detail_operation_reuses_slice_admission_and_keeps_legacy_operation() {
        let query = serde_json::json!({
            "range": {"startNs": 0, "endNs": 1}, "eventKey": null,
            "processKey": null, "pid": null, "threadKey": null, "tid": null,
            "name": null, "nameMatch": "exact", "minimumDurationNs": null,
            "depth": null, "includesArgumentSet": true, "limit": 1
        });
        for name in ["sliceDetails", "slices"] {
            let operation = serde_json::json!({"operation": name, "query": query});
            let valid: Operation = decode(&serde_json::to_vec(&operation).unwrap()).unwrap();
            valid.validate().unwrap();
            for limit in [0, 100_001] {
                let mut invalid = operation.clone();
                invalid["query"]["limit"] = limit.into();
                let value: Operation = decode(&serde_json::to_vec(&invalid).unwrap()).unwrap();
                assert_eq!(value.validate(), Err(STATUS_INVALID_INPUT));
            }
            let mut invalid = operation;
            invalid["query"]["sql"] = "SELECT 1".into();
            assert!(decode::<Operation>(&serde_json::to_vec(&invalid).unwrap()).is_err());
        }
    }
}
