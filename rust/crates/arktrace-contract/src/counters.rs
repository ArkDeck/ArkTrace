use crate::{ContractError, DirectoryNameMatch, EventKey, ProcessKey, TraceTimeRange};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CounterQuery {
    pub range: TraceTimeRange,
    #[serde(rename = "filterID")]
    pub filter_id: Option<i64>,
    pub cpu: Option<i64>,
    pub process_key: Option<i64>,
    pub pid: Option<i64>,
    pub name: Option<String>,
    pub name_match: DirectoryNameMatch,
    pub limit: usize,
}
impl CounterQuery {
    pub fn validate(&self) -> Result<(), ContractError> {
        if self.range.is_instant()
            || !(1..=100_000).contains(&self.limit)
            || (self.cpu.is_some() && (self.process_key.is_some() || self.pid.is_some()))
            || self
                .name
                .as_ref()
                .is_some_and(|n| n.is_empty() || n.len() > 256)
            || (self.name.is_none() && self.name_match != DirectoryNameMatch::Exact)
        {
            return Err(ContractError::InvalidEventQuery);
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CounterSeriesQuery {
    pub range: TraceTimeRange,
    pub limit: usize,
}
impl CounterSeriesQuery {
    pub fn validate(&self) -> Result<(), ContractError> {
        if self.range.is_instant() || !(1..=100_000).contains(&self.limit) {
            return Err(ContractError::InvalidEventQuery);
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CounterScope {
    Cpu,
    Process,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CounterSample {
    pub key: EventKey,
    pub timestamp_ns: i64,
    pub value: i64,
    pub duration_ns: Option<i64>,
}

/// Swift's synthesized descriptor Codable omits absent metadata. Sample and
/// Agent documents below explicitly encode those fields as null instead.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CounterSeriesDescriptor {
    #[serde(rename = "filterID")]
    pub filter_id: i64,
    pub name: String,
    pub scope: CounterScope,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cpu: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub process_key: Option<ProcessKey>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pid: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub process_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub unit: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CounterSeries {
    #[serde(rename = "filterID")]
    pub filter_id: i64,
    pub name: String,
    pub scope: CounterScope,
    pub cpu: Option<i64>,
    pub process_key: Option<ProcessKey>,
    pub pid: Option<i64>,
    pub process_name: Option<String>,
    pub unit: Option<String>,
    pub samples: Vec<CounterSample>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TraceAgentCounterEvent {
    #[serde(rename = "filterID")]
    pub filter_id: i64,
    pub name: String,
    pub scope: CounterScope,
    pub cpu: Option<i64>,
    pub process_key: Option<ProcessKey>,
    pub pid: Option<i64>,
    pub process_name: Option<String>,
    pub unit: Option<String>,
    pub sample: CounterSample,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::EventTable;
    #[test]
    fn counter_documents_preserve_int64_nulls_and_descriptor_omissions() {
        let sample = CounterSample {
            key: EventKey {
                table: EventTable::ProcessMeasure,
                row_id: -7,
            },
            timestamp_ns: i64::MAX,
            value: i64::MIN,
            duration_ns: None,
        };
        let value = serde_json::to_value(&sample).unwrap();
        assert_eq!(value["value"].as_i64(), Some(i64::MIN));
        assert_eq!(value["timestampNs"].as_i64(), Some(i64::MAX));
        assert!(value["durationNs"].is_null());
        assert_eq!(
            serde_json::from_value::<CounterSample>(value).unwrap(),
            sample
        );
        let descriptor = CounterSeriesDescriptor {
            filter_id: 0,
            name: "".into(),
            scope: CounterScope::Process,
            cpu: None,
            process_key: None,
            pid: None,
            process_name: None,
            unit: None,
        };
        let value = serde_json::to_value(&descriptor).unwrap();
        assert_eq!(value.as_object().unwrap().len(), 3);
        assert_eq!(
            serde_json::from_value::<CounterSeriesDescriptor>(value).unwrap(),
            descriptor
        );
        let agent = TraceAgentCounterEvent {
            filter_id: 0,
            name: "".into(),
            scope: CounterScope::Process,
            cpu: None,
            process_key: None,
            pid: None,
            process_name: None,
            unit: None,
            sample,
        };
        let mut value = serde_json::to_value(&agent).unwrap();
        assert_eq!(value.as_object().unwrap().len(), 9);
        assert_eq!(value["filterID"], 0);
        assert!(!value.as_object().unwrap().contains_key("filterId"));
        for field in ["cpu", "processKey", "pid", "processName", "unit"] {
            assert!(value.as_object().unwrap().get(field).unwrap().is_null());
        }
        value["sql"] = serde_json::json!("SELECT 1");
        assert!(serde_json::from_value::<TraceAgentCounterEvent>(value).is_err());
    }
    #[test]
    fn counter_query_bounds_scope_and_utf8_are_closed() {
        let q = CounterQuery {
            range: TraceTimeRange::event(0, 1).unwrap(),
            filter_id: Some(-1),
            cpu: Some(-1),
            process_key: None,
            pid: None,
            name: Some(format!("{}a", "界".repeat(85))),
            name_match: DirectoryNameMatch::Contains,
            limit: 100_000,
        };
        q.validate().unwrap();
        for bad in [
            CounterQuery {
                name: Some(format!("{}aa", "界".repeat(85))),
                ..q.clone()
            },
            CounterQuery {
                name: Some("".into()),
                ..q.clone()
            },
            CounterQuery {
                name: None,
                ..q.clone()
            },
            CounterQuery {
                process_key: Some(1),
                ..q.clone()
            },
            CounterQuery {
                pid: Some(1),
                ..q.clone()
            },
            CounterQuery {
                limit: 0,
                ..q.clone()
            },
            CounterQuery {
                limit: 100_001,
                ..q.clone()
            },
            CounterQuery {
                range: TraceTimeRange::event(0, 0).unwrap(),
                ..q
            },
        ] {
            assert!(bad.validate().is_err());
        }
    }
}
