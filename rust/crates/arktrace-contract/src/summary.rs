use crate::{ContractError, QualityIssue, TraceTimeRange};
use serde::{Deserialize, Serialize};

/// Result and source-prefix limits. SQL execution has a separate native policy.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TraceSummaryQuery {
    pub range: Option<TraceTimeRange>,
    pub maximum_rows_per_section: usize,
    pub maximum_events_per_section: usize,
}
impl TraceSummaryQuery {
    pub fn validate(&self) -> Result<(), ContractError> {
        if self.range.is_some_and(|r| r.is_instant())
            || !(1..=1_000_000).contains(&self.maximum_rows_per_section)
            || !(1..=1_000_000).contains(&self.maximum_events_per_section)
        {
            return Err(ContractError::InvalidSummaryQuery);
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TraceBoundedCount {
    pub value: i64,
    pub truncated: bool,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TraceEventSourceCount {
    pub source: String,
    pub count: i64,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TraceEventSourceCounts {
    pub items: Vec<TraceEventSourceCount>,
    pub truncated: bool,
}

/// Query quality preserves repository order. Human warning text belongs to the
/// presentation adapter; absent capabilities are explicit nulls on this wire.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TraceSummaryFacts {
    pub cpu_count: Option<TraceBoundedCount>,
    pub process_count: TraceBoundedCount,
    pub thread_count: TraceBoundedCount,
    pub cpu_slice_count: Option<TraceBoundedCount>,
    pub thread_state_count: Option<TraceBoundedCount>,
    pub named_slice_count: Option<TraceBoundedCount>,
    pub counter_series_count: Option<TraceBoundedCount>,
    pub event_count_by_source: Option<TraceEventSourceCounts>,
    pub data_quality_issues: Vec<QualityIssue>,
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn summary_accepts_entire_trace_but_rejects_empty_ranges_and_bad_limits() {
        let valid = TraceSummaryQuery {
            range: None,
            maximum_rows_per_section: 1,
            maximum_events_per_section: 1_000_000,
        };
        valid.validate().unwrap();
        for limit in [0, 1_000_001] {
            assert!(
                TraceSummaryQuery {
                    maximum_rows_per_section: limit,
                    ..valid.clone()
                }
                .validate()
                .is_err()
            );
            assert!(
                TraceSummaryQuery {
                    maximum_events_per_section: limit,
                    ..valid.clone()
                }
                .validate()
                .is_err()
            );
        }
        assert!(
            TraceSummaryQuery {
                range: Some(TraceTimeRange::event(0, 0).unwrap()),
                ..valid
            }
            .validate()
            .is_err()
        );
    }
}
