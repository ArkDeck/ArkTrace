use crate::ContractError;
use serde::{Deserialize, Serialize, de::Error};
use sha2::{Digest, Sha256};

/// Existing ArkTrace/ArkDeck lease byte. Windows native admission remains a
/// separate host test; encoding a constant is not that admission evidence.
pub const WINDOWS_LEASE_OFFSET: u64 = u64::MAX - 1;
pub const WINDOWS_LEASE_LENGTH: u32 = 1;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TraceCacheKey {
    #[serde(rename = "traceSHA256")]
    trace_sha256: String,
    #[serde(rename = "parserBinarySHA256")]
    parser_binary_sha256: String,
    upstream_revision: String,
    schema_adapter_version: String,
    index_schema_version: i64,
    parser_key: String,
}

fn is_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

impl TraceCacheKey {
    pub fn new(
        trace_sha256: &str,
        parser_binary_sha256: &str,
        upstream_revision: &str,
        schema_adapter_version: &str,
        index_schema_version: i64,
    ) -> Result<Self, ContractError> {
        if !is_sha256(trace_sha256)
            || !is_sha256(parser_binary_sha256)
            || upstream_revision.is_empty()
            || upstream_revision.len() > 256
            || schema_adapter_version.is_empty()
            || schema_adapter_version.len() > 64
            || index_schema_version < 0
        {
            return Err(ContractError::InvalidCacheIdentity);
        }
        let index = index_schema_version.to_string();
        let mut preimage = Sha256::new();
        preimage.update(b"ArkTrace.Cache.ParserKey.v1");
        for field in [
            parser_binary_sha256,
            upstream_revision,
            schema_adapter_version,
            &index,
        ] {
            preimage.update((field.len() as u64).to_be_bytes());
            preimage.update(field.as_bytes());
        }
        Ok(Self {
            trace_sha256: trace_sha256.into(),
            parser_binary_sha256: parser_binary_sha256.into(),
            upstream_revision: upstream_revision.into(),
            schema_adapter_version: schema_adapter_version.into(),
            index_schema_version,
            parser_key: format!("{:x}", preimage.finalize()),
        })
    }

    pub fn trace_sha256(&self) -> &str {
        &self.trace_sha256
    }
    pub fn parser_key(&self) -> &str {
        &self.parser_key
    }
    pub fn entry_identifier(&self) -> String {
        format!(
            "{:x}",
            Sha256::digest(format!("{}:{}", self.trace_sha256, self.parser_key).as_bytes())
        )
    }
    pub fn lock_relative_path(&self) -> String {
        format!(".locks/{}.lock", self.entry_identifier())
    }
    pub fn lease_relative_path(&self) -> String {
        format!(".leases/{}.lease", self.entry_identifier())
    }
}

impl<'de> Deserialize<'de> for TraceCacheKey {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct Fields {
            #[serde(rename = "traceSHA256")]
            trace_sha256: String,
            #[serde(rename = "parserBinarySHA256")]
            parser_binary_sha256: String,
            upstream_revision: String,
            schema_adapter_version: String,
            index_schema_version: i64,
            parser_key: String,
        }
        let fields = Fields::deserialize(deserializer)?;
        let key = Self::new(
            &fields.trace_sha256,
            &fields.parser_binary_sha256,
            &fields.upstream_revision,
            &fields.schema_adapter_version,
            fields.index_schema_version,
        )
        .map_err(|_| D::Error::custom("invalid cache identity"))?;
        if fields.parser_key != key.parser_key {
            return Err(D::Error::custom("cache parser key mismatch"));
        }
        Ok(key)
    }
}
