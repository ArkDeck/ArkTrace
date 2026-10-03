use crate::ContractError;
use serde::{Deserialize, Serialize};

/// Path-free identity fields shared with the existing Swift metadata format.
/// Native signature/binary verification is separate from this value's shape.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TraceParserIdentity {
    pub name: String,
    pub reported_version: String,
    #[serde(rename = "binarySHA256")]
    pub binary_sha256: String,
    pub upstream_repository: String,
    pub upstream_revision: String,
    pub architecture: String,
    pub adapter_version: String,
    pub build_recipe_version: String,
}
impl TraceParserIdentity {
    pub fn validate(&self) -> Result<(), ContractError> {
        let token = |s: &str, bound: usize| {
            !s.is_empty()
                && s.len() <= bound
                && s.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"._-+".contains(&b))
        };
        let digest = |s: &str| {
            s.len() == 64
                && s.bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        };
        if !token(&self.name, 128)
            || !token(&self.reported_version, 128)
            || !digest(&self.binary_sha256)
            || !token(&self.upstream_revision, 256)
            || !token(&self.architecture, 64)
            || !token(&self.adapter_version, 64)
            || !token(&self.build_recipe_version, 128)
            || !self.upstream_repository.starts_with("https://")
            || self.upstream_repository.len() > 1024
            || self.upstream_repository[8..].is_empty()
            || self
                .upstream_repository
                .bytes()
                .any(|b| b <= 32 || b >= 127 || b == b'\\')
        {
            return Err(ContractError::InvalidParserIdentity);
        }
        Ok(())
    }
}
