use crate::ContractError;
use serde::{Deserialize, Deserializer, Serialize};

/// Trace-relative nanoseconds. An instant belongs to [query.start, query.end).
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TraceTimeRange {
    start_ns: i64,
    end_ns: i64,
}

impl TraceTimeRange {
    pub fn event(start_ns: i64, end_ns: i64) -> Result<Self, ContractError> {
        if start_ns < 0 || start_ns > end_ns {
            return Err(ContractError::InvalidTimeRange);
        }
        Ok(Self { start_ns, end_ns })
    }

    pub fn query(start_ns: i64, end_ns: i64) -> Result<Self, ContractError> {
        if start_ns >= end_ns {
            return Err(ContractError::DegenerateQueryRange);
        }
        Self::event(start_ns, end_ns)
    }

    pub fn start_ns(self) -> i64 {
        self.start_ns
    }
    pub fn end_ns(self) -> i64 {
        self.end_ns
    }
    pub fn duration_ns(self) -> i64 {
        self.end_ns - self.start_ns
    }
    pub fn is_instant(self) -> bool {
        self.start_ns == self.end_ns
    }

    pub fn intersects(self, query: Self) -> bool {
        if self.is_instant() {
            query.start_ns <= self.start_ns && self.start_ns < query.end_ns
        } else {
            self.start_ns < query.end_ns && self.end_ns > query.start_ns
        }
    }

    pub fn clipped_overlap_ns(self, range: Self) -> i64 {
        (self.end_ns.min(range.end_ns) - self.start_ns.max(range.start_ns)).max(0)
    }
}

impl<'de> Deserialize<'de> for TraceTimeRange {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct Input {
            start_ns: i64,
            end_ns: i64,
        }
        let input = Input::deserialize(deserializer)?;
        Self::event(input.start_ns, input.end_ns)
            .map_err(|_| serde::de::Error::custom("invalid trace-relative time range"))
    }
}
