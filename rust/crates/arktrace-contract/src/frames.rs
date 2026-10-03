use crate::{ContractError, EventKey, ProcessKey, ThreadKey, TraceTimeRange};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TraceFrameQuery {
    pub range: TraceTimeRange,
    pub process_key: Option<i64>,
    pub limit: usize,
}
impl TraceFrameQuery {
    pub const MAXIMUM_LIMIT: usize = 20_000;
    pub fn validate(&self) -> Result<(), ContractError> {
        if !(1..=Self::MAXIMUM_LIMIT).contains(&self.limit) {
            return Err(ContractError::InvalidEventQuery);
        }
        Ok(())
    }
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(into = "i64", try_from = "i64")]
pub enum TraceFrameKind {
    Actual,
    Expected,
}
impl From<TraceFrameKind> for i64 {
    fn from(kind: TraceFrameKind) -> Self {
        match kind {
            TraceFrameKind::Actual => 0,
            TraceFrameKind::Expected => 1,
        }
    }
}
impl TryFrom<i64> for TraceFrameKind {
    type Error = &'static str;
    fn try_from(value: i64) -> Result<Self, Self::Error> {
        match value {
            0 => Ok(Self::Actual),
            1 => Ok(Self::Expected),
            _ => Err("invalid frame kind"),
        }
    }
}
/// Complete Swift frame coded shape, including its synthesized omission of
/// absent optional fields. Computed jank semantics do not alter raw flags.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TraceFrame {
    pub key: EventKey,
    pub range: TraceTimeRange,
    pub kind: TraceFrameKind,
    pub vsync: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub process_key: Option<ProcessKey>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thread_key: Option<ThreadKey>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pid: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub process_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub flag: Option<i64>,
    pub is_open_ended: bool,
}
impl TraceFrame {
    pub fn jank_tag(flag: Option<i64>) -> i64 {
        match flag {
            Some(1) => 1,
            Some(3) => 3,
            _ => 0,
        }
    }
    pub fn is_jank(&self) -> bool {
        Self::jank_tag(self.flag) != 0
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::EventTable;
    #[test]
    fn frame_coding_keeps_integer_kind_raw_flag_and_optional_omissions() {
        let frame = TraceFrame {
            key: EventKey {
                table: EventTable::FrameSlice,
                row_id: i64::MIN,
            },
            range: TraceTimeRange::event(0, i64::MAX).unwrap(),
            kind: TraceFrameKind::Expected,
            vsync: i64::MAX,
            process_key: None,
            thread_key: None,
            pid: None,
            process_name: None,
            flag: Some(2),
            is_open_ended: false,
        };
        let value = serde_json::to_value(&frame).unwrap();
        assert_eq!(value["kind"], 1);
        assert_eq!(value["vsync"].as_i64(), Some(i64::MAX));
        assert_eq!(value["key"]["rowID"].as_i64(), Some(i64::MIN));
        assert_eq!(value.as_object().unwrap().len(), 6);
        assert!(!value.as_object().unwrap().contains_key("threadKey"));
        assert!(!frame.is_jank());
        assert_eq!(serde_json::from_value::<TraceFrame>(value).unwrap(), frame);
        for value in [-1, 2, i64::MAX] {
            assert!(serde_json::from_value::<TraceFrameKind>(serde_json::json!(value)).is_err());
        }
        for flag in [None, Some(0), Some(2), Some(-1), Some(i64::MAX)] {
            assert_eq!(TraceFrame::jank_tag(flag), 0);
        }
        assert_eq!(TraceFrame::jank_tag(Some(1)), 1);
        assert_eq!(TraceFrame::jank_tag(Some(3)), 3);
    }
    #[test]
    fn frame_query_limit_does_not_invent_agent_range_or_identity_guards() {
        let q = TraceFrameQuery {
            range: TraceTimeRange::event(0, 0).unwrap(),
            process_key: Some(0),
            limit: 20_000,
        };
        q.validate().unwrap();
        for limit in [0, 20_001, usize::MAX] {
            assert!(TraceFrameQuery { limit, ..q.clone() }.validate().is_err());
        }
    }
}
