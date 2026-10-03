use crate::{ContractError, EventKey, ProcessKey, ThreadKey, TraceTimeRange};
use serde::{Deserialize, Serialize};

/// Swift's OptionSet bits. Unknown nonzero bits answer no known domain;
/// signed values retain the existing OptionSet semantics.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct SearchDomains(pub i64);
impl SearchDomains {
    pub const PROCESS: Self = Self(1);
    pub const THREAD: Self = Self(2);
    pub const SLICE: Self = Self(4);
    pub const ALL: Self = Self(7);
    pub const TOOLBAR: Self = Self(6);
    pub fn contains(self, domain: Self) -> bool {
        self.0 & domain.0 == domain.0
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TraceSearchRequest {
    pub text: String,
    pub limit: usize,
    pub domains: SearchDomains,
}
impl TraceSearchRequest {
    /// Timeout and cancellation belong to the request budget, as for raw
    /// repository queries. The host caps search at thirty seconds.
    pub fn validate(&self) -> Result<(), ContractError> {
        if self.text.is_empty()
            || self.text.len() > 256
            || !(1..=1_000).contains(&self.limit)
            || self.domains.0 == 0
        {
            return Err(ContractError::InvalidEventQuery);
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TraceSearchResultKind {
    Process,
    Thread,
    Slice,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TraceSearchResult {
    pub kind: TraceSearchResultKind,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subtitle: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub process_key: Option<ProcessKey>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thread_key: Option<ThreadKey>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub event_key: Option<EventKey>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub range: Option<TraceTimeRange>,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TraceSearchResults {
    pub items: Vec<TraceSearchResult>,
    pub truncated: bool,
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn signed_domain_bits_utf8_and_limits_preserve_search_admission() {
        let q = TraceSearchRequest {
            text: "中".repeat(85) + "a",
            limit: 1000,
            domains: SearchDomains(-1),
        };
        assert!(q.validate().is_ok());
        assert!(q.domains.contains(SearchDomains::ALL));
        for bad in [
            TraceSearchRequest {
                text: q.text.clone() + "a",
                ..q.clone()
            },
            TraceSearchRequest {
                limit: 0,
                ..q.clone()
            },
            TraceSearchRequest {
                limit: 1001,
                ..q.clone()
            },
            TraceSearchRequest {
                domains: SearchDomains(0),
                ..q.clone()
            },
        ] {
            assert!(bad.validate().is_err());
        }
        assert!(!SearchDomains(8).contains(SearchDomains::PROCESS));
        assert!(
            serde_json::from_str::<TraceSearchRequest>(
                r#"{"text":"a","limit":1,"domains":6,"sql":"x"}"#
            )
            .is_err()
        );
    }
    #[test]
    fn optional_search_fields_are_omitted_like_swift_codable() {
        let row = TraceSearchResult {
            kind: TraceSearchResultKind::Thread,
            title: "a".into(),
            subtitle: None,
            process_key: None,
            thread_key: None,
            event_key: None,
            range: None,
        };
        assert_eq!(
            serde_json::to_value(row).unwrap(),
            serde_json::json!({"kind":"thread","title":"a"})
        );
    }
}
