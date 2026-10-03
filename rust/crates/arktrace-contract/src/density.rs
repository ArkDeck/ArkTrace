use crate::{ContractError, DataQuality, ProcessKey, ThreadKey, TraceTimeRange};
use serde::{Deserialize, Serialize};

/// Swift's synthesized associated-value coding. None means unassociated
/// slices for namedSlice, and all processes/CPUs for frame/counter scopes.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub enum TraceDensitySource {
    Cpu {
        #[serde(rename = "_0")]
        cpu: i64,
    },
    ThreadState {
        #[serde(rename = "_0")]
        thread: ThreadKey,
    },
    NamedSlice {
        #[serde(rename = "_0", skip_serializing_if = "Option::is_none")]
        thread: Option<ThreadKey>,
    },
    CpuCounter {
        #[serde(rename = "filterID")]
        filter_id: i64,
        #[serde(skip_serializing_if = "Option::is_none")]
        cpu: Option<i64>,
    },
    ProcessCounter {
        #[serde(rename = "filterID")]
        filter_id: i64,
        #[serde(rename = "processKey", skip_serializing_if = "Option::is_none")]
        process_key: Option<ProcessKey>,
    },
    Frame {
        #[serde(rename = "processKey", skip_serializing_if = "Option::is_none")]
        process_key: Option<ProcessKey>,
    },
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TraceDensityQuery {
    pub range: TraceTimeRange,
    pub source: TraceDensitySource,
    pub bucket_count: usize,
}
impl TraceDensityQuery {
    pub const MAXIMUM_BUCKET_COUNT: usize = 40_000;
    pub fn validate(&self) -> Result<(), ContractError> {
        if self.range.is_instant() || !(1..=Self::MAXIMUM_BUCKET_COUNT).contains(&self.bucket_count)
        {
            return Err(ContractError::InvalidEventQuery);
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub enum TraceDensityIdentity {
    ProcessOrThread {
        #[serde(rename = "_0")]
        identity: i64,
    },
    Name {
        #[serde(rename = "_0")]
        name: String,
    },
    ThreadState {
        #[serde(rename = "_0")]
        state: String,
    },
    Jank {
        #[serde(rename = "_0")]
        flag: i64,
    },
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TraceDensityBucket {
    pub range: TraceTimeRange,
    pub event_count: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub occupied_ns: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub utilization: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dominant: Option<TraceDensityIdentity>,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TraceDensityResult {
    pub buckets: Vec<TraceDensityBucket>,
    pub capability_available: bool,
    pub data_quality: DataQuality,
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn density_bounds_and_associated_values_keep_swift_coding() {
        let q = TraceDensityQuery {
            range: TraceTimeRange::query(0, i64::MAX).unwrap(),
            source: TraceDensitySource::NamedSlice { thread: None },
            bucket_count: 40_000,
        };
        q.validate().unwrap();
        assert_eq!(
            serde_json::to_value(&q.source).unwrap(),
            serde_json::json!({"namedSlice":{}})
        );
        for bucket_count in [0, 40_001, usize::MAX] {
            assert!(
                TraceDensityQuery {
                    bucket_count,
                    ..q.clone()
                }
                .validate()
                .is_err()
            );
        }
        assert!(
            TraceDensityQuery {
                range: TraceTimeRange::event(0, 0).unwrap(),
                ..q
            }
            .validate()
            .is_err()
        );
        let value =
            serde_json::json!({"processCounter":{"filterID":i64::MIN,"processKey":{"ipid":0}}});
        assert_eq!(
            serde_json::to_value(
                serde_json::from_value::<TraceDensitySource>(value.clone()).unwrap()
            )
            .unwrap(),
            value
        );
        assert!(
            serde_json::from_value::<TraceDensitySource>(
                serde_json::json!({"cpu":{"_0":0,"sql":"x"}})
            )
            .is_err()
        );
        assert_eq!(
            serde_json::to_value(TraceDensityIdentity::Jank { flag: -99 }).unwrap(),
            serde_json::json!({"jank":{"_0":-99}})
        );
    }
}
