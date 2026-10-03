use crate::ContractError;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TraceArgumentQuery {
    #[serde(rename = "argSetID")]
    pub arg_set_id: i64,
    pub limit: usize,
}
impl TraceArgumentQuery {
    pub const MAXIMUM_LIMIT: usize = 64;
    pub fn validate(&self) -> Result<(), ContractError> {
        if !(1..=Self::MAXIMUM_LIMIT).contains(&self.limit) {
            return Err(ContractError::InvalidEventQuery);
        }
        Ok(())
    }
}

/// Resolved Inspector argument, matching Swift's synthesized optional omission.
/// The datatype branch belongs to Store; no consumer interprets raw SQL values.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TraceEventArgument {
    pub key: String,
    pub value: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub type_name: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn argument_query_preserves_signed_set_identity_and_closed_limits() {
        for id in [i64::MIN, -1, 0, 1, i64::MAX] {
            let q = TraceArgumentQuery {
                arg_set_id: id,
                limit: 64,
            };
            q.validate().unwrap();
            let value = serde_json::to_value(&q).unwrap();
            assert_eq!(value["argSetID"].as_i64(), Some(id));
            assert_eq!(
                serde_json::from_value::<TraceArgumentQuery>(value).unwrap(),
                q
            );
            for limit in [0, 65, usize::MAX] {
                assert!(
                    TraceArgumentQuery { limit, ..q.clone() }
                        .validate()
                        .is_err()
                );
            }
        }
        assert!(
            serde_json::from_value::<TraceArgumentQuery>(
                serde_json::json!({"argSetID":1,"limit":1,"sql":"SELECT *"})
            )
            .is_err()
        );
    }
    #[test]
    fn resolved_argument_keeps_empty_string_value_and_optional_type_omission() {
        let a = TraceEventArgument {
            key: "name".into(),
            value: String::new(),
            type_name: None,
        };
        let value = serde_json::to_value(&a).unwrap();
        assert_eq!(value, serde_json::json!({"key":"name","value":""}));
        assert_eq!(
            serde_json::from_value::<TraceEventArgument>(value).unwrap(),
            a
        );
    }
}
