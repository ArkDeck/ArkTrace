use arktrace_contract::{ContractError, TraceRepositoryEventBatch};
use arktrace_platform::ContinuousDeadline;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "operation",
    content = "query",
    rename_all = "camelCase",
    deny_unknown_fields
)]
pub enum DeadlineRepositoryQuery {
    CpuCatalog(arktrace_contract::CpuCatalogQuery),
    Processes(arktrace_contract::ProcessQuery),
    SummaryFacts(arktrace_contract::TraceSummaryQuery),
    Frames(arktrace_contract::TraceFrameQuery),
    Arguments(arktrace_contract::TraceArgumentQuery),
}
impl DeadlineRepositoryQuery {
    pub fn validate(&self) -> Result<(), ContractError> {
        match self {
            Self::CpuCatalog(q) => q.validate(),
            Self::Processes(q) => q.validate(),
            Self::SummaryFacts(q) => q.validate(),
            Self::Frames(q) => q.validate(),
            Self::Arguments(q) => q.validate(),
        }
    }
}
fn required_deadline<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Option<ContinuousDeadline>, D::Error> {
    Option::deserialize(deserializer)
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DeadlineQuery {
    pub clock: QueryClock,
    // A null processes deadline is explicit; missing policy is not inferred.
    #[serde(deserialize_with = "required_deadline")]
    pub deadline: Option<ContinuousDeadline>,
    pub query: DeadlineRepositoryQuery,
}
impl DeadlineQuery {
    pub fn validate(&self) -> Result<(), ContractError> {
        if self.deadline.is_some_and(|d| !d.is_valid())
            || (self.deadline.is_none()
                && !matches!(self.query, DeadlineRepositoryQuery::Processes(_)))
        {
            return Err(ContractError::InvalidEventQuery);
        }
        self.query.validate()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum QueryClock {
    HostContinuousEpochV1,
}

/// Host resource policy kept outside domain query filters. Absolute epochs
/// survive frontend encoding, admission retries and native worker queueing.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BatchQueryDeadlines {
    pub clock: QueryClock,
    pub cpu_slices: Vec<ContinuousDeadline>,
    pub thread_states: Vec<ContinuousDeadline>,
    pub slices: Vec<ContinuousDeadline>,
    pub counters: Vec<ContinuousDeadline>,
    pub counter_series: Vec<ContinuousDeadline>,
    pub densities: Vec<ContinuousDeadline>,
    pub threads: Vec<Option<ContinuousDeadline>>,
}
impl BatchQueryDeadlines {
    pub fn validate(&self, batch: &TraceRepositoryEventBatch) -> Result<(), ContractError> {
        batch.validate()?;
        if [
            self.cpu_slices.len(),
            self.thread_states.len(),
            self.slices.len(),
            self.counters.len(),
            self.counter_series.len(),
            self.densities.len(),
            self.threads.len(),
        ] != [
            batch.cpu_slices.len(),
            batch.thread_states.len(),
            batch.slices.len(),
            batch.counters.len(),
            batch.counter_series.len(),
            batch.densities.len(),
            batch.threads.len(),
        ] || self
            .cpu_slices
            .iter()
            .chain(&self.thread_states)
            .chain(&self.slices)
            .chain(&self.counters)
            .chain(&self.counter_series)
            .chain(&self.densities)
            .chain(self.threads.iter().flatten())
            .any(|deadline| !deadline.is_valid())
        {
            return Err(ContractError::InvalidEventQuery);
        }
        Ok(())
    }
    pub fn ordered(
        &self,
        batch: &TraceRepositoryEventBatch,
    ) -> Result<Vec<Option<ContinuousDeadline>>, ContractError> {
        self.validate(batch)?;
        Ok(self
            .cpu_slices
            .iter()
            .chain(&self.thread_states)
            .chain(&self.slices)
            .chain(&self.counters)
            .chain(&self.counter_series)
            .chain(&self.densities)
            .copied()
            .map(Some)
            .chain(self.threads.iter().copied())
            .collect())
    }
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DeadlineBatch {
    pub batch: TraceRepositoryEventBatch,
    pub deadlines: BatchQueryDeadlines,
}
impl DeadlineBatch {
    pub fn validate(&self) -> Result<(), ContractError> {
        self.deadlines.validate(&self.batch)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};
    #[test]
    fn scalar_resource_policy_is_explicit_and_only_processes_may_have_nil() {
        for (operation, query) in [
            (
                "cpuCatalog",
                json!({"range":{"startNs":0,"endNs":1},"limit":4096,"activityLimit":20000}),
            ),
            ("processes", json!({"nameMatch":"exact","limit":1})),
            (
                "summaryFacts",
                json!({"range":null,"maximumRowsPerSection":1,"maximumEventsPerSection":2}),
            ),
            ("frames", json!({"range":{"startNs":0,"endNs":1},"limit":1})),
            ("arguments", json!({"argSetID":i64::MIN,"limit":64})),
        ] {
            let value = json!({"clock":"hostContinuousEpochV1","deadline":{"seconds":i64::MAX,"attoseconds":1},"query":{"operation":operation,"query":query}});
            let request: DeadlineQuery = serde_json::from_value(value.clone()).unwrap();
            request.validate().unwrap();
            let mut nil = value.clone();
            nil["deadline"] = Value::Null;
            let request: DeadlineQuery = serde_json::from_value(nil).unwrap();
            assert_eq!(request.validate().is_ok(), operation == "processes");
            let mut missing = value.clone();
            missing.as_object_mut().unwrap().remove("deadline");
            assert!(serde_json::from_value::<DeadlineQuery>(missing).is_err());
            let mut malformed = value;
            malformed["query"]["query"]["rawSQL"] = json!("SELECT 1");
            assert!(serde_json::from_value::<DeadlineQuery>(malformed).is_err());
        }
    }
    #[test]
    fn scalar_deadline_envelope_cannot_recurse_or_accept_unknown_clocks_or_float_parts() {
        let original = json!({"clock":"hostContinuousEpochV1","deadline":{"seconds":0,"attoseconds":1},"query":{"operation":"processes","query":{"nameMatch":"exact","limit":1}}});
        for op in [
            "queryWithDeadline",
            "batchDetailsWithDeadlines",
            "threads",
            "cpuSlices",
            "search",
        ] {
            let mut value = original.clone();
            value["query"]["operation"] = json!(op);
            assert!(serde_json::from_value::<DeadlineQuery>(value).is_err());
        }
        for malformed in [
            json!({"seconds":1.0,"attoseconds":0}),
            json!({"seconds":0,"attoseconds":0,"relativeMilliseconds":1}),
        ] {
            let mut value = original.clone();
            value["deadline"] = malformed;
            assert!(serde_json::from_value::<DeadlineQuery>(value).is_err());
        }
        let mut value = original.clone();
        value["clock"] = json!("wall");
        assert!(serde_json::from_value::<DeadlineQuery>(value).is_err());
        let mut value = original;
        value["deadline"] = json!({"seconds":-1,"attoseconds":1});
        assert!(
            serde_json::from_value::<DeadlineQuery>(value)
                .unwrap()
                .validate()
                .is_err()
        );
    }
    fn fixture() -> DeadlineBatch {
        serde_json::from_value(json!({
            "batch": {
                "cpuSlices": [{"range":{"startNs":0,"endNs":9},"limit":1}],
                "threadStates": [{"range":{"startNs":0,"endNs":9},"limit":2}],
                "slices": [{"range":{"startNs":0,"endNs":9},"limit":3,"nameMatch":"exact","includesArgumentSet":false}],
                "counters": [{"range":{"startNs":0,"endNs":9},"limit":4,"nameMatch":"exact"}],
                "counterSeries": [{"range":{"startNs":0,"endNs":9},"limit":5}],
                "densities": [{"range":{"startNs":0,"endNs":9},"source":{"cpu":{"_0":0}},"bucketCount":6}],
                "threads": [{"limit":7,"nameMatch":"exact"},{"limit":8,"nameMatch":"exact"}]
            },
            "deadlines": {"clock":"hostContinuousEpochV1", "cpuSlices":[{"seconds":0,"attoseconds":1}],
                "threadStates":[{"seconds":0,"attoseconds":2}], "slices":[{"seconds":0,"attoseconds":3}],
                "counters":[{"seconds":0,"attoseconds":4}], "counterSeries":[{"seconds":0,"attoseconds":5}],
                "densities":[{"seconds":0,"attoseconds":6}], "threads":[null,{"seconds":0,"attoseconds":8}]}
        })).unwrap()
    }
    #[test]
    fn all_seven_families_preserve_slot_order_optional_thread_and_exact_epoch() {
        let mut value = fixture();
        let ordered = value.deadlines.ordered(&value.batch).unwrap();
        assert_eq!(
            ordered
                .iter()
                .map(|v| v.map(|d| d.attoseconds))
                .collect::<Vec<_>>(),
            [
                Some(1),
                Some(2),
                Some(3),
                Some(4),
                Some(5),
                Some(6),
                None,
                Some(8)
            ]
        );
        value.deadlines.cpu_slices[0] = ContinuousDeadline {
            seconds: i64::MIN,
            attoseconds: -999_999_999_999_999_999,
        };
        value.deadlines.threads[1] = Some(ContinuousDeadline {
            seconds: i64::MAX,
            attoseconds: 999_999_999_999_999_999,
        });
        let encoded = serde_json::to_string(&value).unwrap();
        assert_eq!(
            serde_json::from_str::<DeadlineBatch>(&encoded).unwrap(),
            value
        );
        value.validate().unwrap();
    }
    #[test]
    fn deadline_counts_are_paired_by_family_instead_of_only_total() {
        let mut value = fixture();
        let shifted = value.deadlines.cpu_slices.pop().unwrap();
        value.deadlines.thread_states.push(shifted);
        assert!(value.validate().is_err());
        let mut value = fixture();
        value.deadlines.slices[0].attoseconds = 1_000_000_000_000_000_000;
        assert!(value.validate().is_err());
        value.deadlines.slices[0] = ContinuousDeadline {
            seconds: -1,
            attoseconds: 1,
        };
        assert!(value.validate().is_err());
    }
    #[test]
    fn bounds_accept_one_and_32_slots_and_reject_zero_and_33() {
        let original = fixture();
        for count in [0, 1, 32, 33] {
            let batch = TraceRepositoryEventBatch {
                threads: vec![original.batch.threads[0].clone(); count],
                ..Default::default()
            };
            let deadlines = BatchQueryDeadlines {
                clock: QueryClock::HostContinuousEpochV1,
                cpu_slices: vec![],
                thread_states: vec![],
                slices: vec![],
                counters: vec![],
                counter_series: vec![],
                densities: vec![],
                threads: vec![None; count],
            };
            assert_eq!(
                deadlines.validate(&batch).is_ok(),
                count == 1 || count == 32
            );
        }
    }
    #[test]
    fn wire_requires_known_clock_and_complete_closed_integer_slots() {
        let original = serde_json::to_value(fixture()).unwrap();
        for path in ["clock", "cpuSlices", "threads"] {
            let mut value = original.clone();
            value["deadlines"].as_object_mut().unwrap().remove(path);
            assert!(serde_json::from_value::<DeadlineBatch>(value).is_err());
        }
        for replacement in [json!("wall"), json!(null), json!(1)] {
            let mut value = original.clone();
            value["deadlines"]["clock"] = replacement;
            assert!(serde_json::from_value::<DeadlineBatch>(value).is_err());
        }
        for replacement in [
            Value::Null,
            json!({"seconds":1.0,"attoseconds":0}),
            json!({"seconds":0,"attoseconds":0,"timeout":30}),
        ] {
            let mut value = original.clone();
            value["deadlines"]["cpuSlices"][0] = replacement;
            assert!(serde_json::from_value::<DeadlineBatch>(value).is_err());
        }
        let mut value = original;
        value["unbounded"] = json!(true);
        assert!(serde_json::from_value::<DeadlineBatch>(value).is_err());
    }
}
