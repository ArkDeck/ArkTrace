use arktrace_contract::{TraceCacheKey, TraceParserIdentity};
use serde::{Deserialize, Serialize};

pub const MAXIMUM_METADATA_BYTES: usize = 16_384;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct MetadataPreparation {
    pub schema_adapter_version: String,
    pub schema_fingerprint: String,
    pub index_version: u32,
    #[serde(rename = "upstreamDatabaseSHA256")]
    pub upstream_database_sha256: String,
    pub upstream_database_byte_count: i64,
}

/// Exactly the current format-1 Swift document, in an isolated Rust root.
/// The native format-2 owner ledger is a separate document/protocol.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CacheMetadata {
    pub format_version: u32,
    pub cache_key: TraceCacheKey,
    pub parser: TraceParserIdentity,
    #[serde(rename = "traceSHA256")]
    pub trace_sha256: String,
    #[serde(rename = "sourceSHA256")]
    pub source_sha256: String,
    pub source_byte_count: i64,
    pub schema_fingerprint: String,
    pub schema_adapter_version: String,
    pub index_schema_version: u32,
    pub database_preparation: MetadataPreparation,
    pub database_byte_count: i64,
    pub created_at: String,
    pub last_accessed_at: String,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct InvalidMetadata;
fn digest(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn leap(year: u32) -> bool {
    year.is_multiple_of(4) && (!year.is_multiple_of(100) || year.is_multiple_of(400))
}
fn month_days(year: u32) -> [u32; 12] {
    [
        31,
        if leap(year) { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ]
}
fn valid_utc(s: &str) -> bool {
    let b = s.as_bytes();
    if b.len() != 20
        || b[4] != b'-'
        || b[7] != b'-'
        || b[10] != b'T'
        || b[13] != b':'
        || b[16] != b':'
        || b[19] != b'Z'
        || b.iter()
            .enumerate()
            .any(|(i, b)| ![4, 7, 10, 13, 16, 19].contains(&i) && !b.is_ascii_digit())
    {
        return false;
    }
    let number = |start, end| s[start..end].parse::<u32>().unwrap_or(u32::MAX);
    let year = number(0, 4);
    let month = number(5, 7);
    let day = number(8, 10);
    (1970..=9999).contains(&year)
        && (1..=12).contains(&month)
        && day >= 1
        && day <= month_days(year)[month as usize - 1]
        && number(11, 13) < 24
        && number(14, 16) < 60
        && number(17, 19) < 60
}
#[cfg(any(target_os = "macos", test))]
pub(crate) fn utc_from_unix_seconds(seconds: u64) -> Result<String, InvalidMetadata> {
    // A bounded Gregorian conversion avoids ambient timezone/locale and an
    // additional date dependency. At most 8030 year iterations are performed.
    let mut days = seconds / 86400;
    let mut year = 1970_u32;
    while year <= 9999 {
        let length = if leap(year) { 366 } else { 365 };
        if days < length {
            break;
        }
        days -= length;
        year += 1;
    }
    if year > 9999 {
        return Err(InvalidMetadata);
    }
    let mut month = 1;
    for length in month_days(year) {
        if days < u64::from(length) {
            break;
        }
        days -= u64::from(length);
        month += 1;
    }
    let daytime = seconds % 86400;
    Ok(format!(
        "{year:04}-{month:02}-{:02}T{:02}:{:02}:{:02}Z",
        days + 1,
        daytime / 3600,
        daytime / 60 % 60,
        daytime % 60
    ))
}
impl CacheMetadata {
    pub fn validate(&self) -> Result<(), InvalidMetadata> {
        self.parser.validate().map_err(|_| InvalidMetadata)?;
        let preparation = &self.database_preparation;
        let key = TraceCacheKey::new(
            &self.source_sha256,
            &self.parser.binary_sha256,
            &self.parser.upstream_revision,
            &self.schema_adapter_version,
            i64::from(self.index_schema_version),
        )
        .map_err(|_| InvalidMetadata)?;
        if self.format_version != 1
            || self.cache_key != key
            || self.trace_sha256 != self.source_sha256
            || self.source_byte_count <= 0
            || self.database_byte_count <= 0
            || !digest(&self.schema_fingerprint)
            || !digest(&preparation.upstream_database_sha256)
            || preparation.upstream_database_byte_count <= 0
            || self.schema_adapter_version != arktrace_contract::SCHEMA_ADAPTER_VERSION
            || self.index_schema_version != arktrace_contract::INDEX_SCHEMA_VERSION
            || self.parser.adapter_version != arktrace_contract::PARSER_ADAPTER_VERSION
            || preparation.schema_adapter_version != self.schema_adapter_version
            || preparation.schema_fingerprint != self.schema_fingerprint
            || preparation.index_version != self.index_schema_version
            || !valid_utc(&self.created_at)
            || !valid_utc(&self.last_accessed_at)
            || self.last_accessed_at < self.created_at
        {
            return Err(InvalidMetadata);
        }
        Ok(())
    }
    pub fn decode(bytes: &[u8]) -> Result<Self, InvalidMetadata> {
        if bytes.is_empty() || bytes.len() > MAXIMUM_METADATA_BYTES {
            return Err(InvalidMetadata);
        }
        let result: Self = serde_json::from_slice(bytes).map_err(|_| InvalidMetadata)?;
        result.validate()?;
        Ok(result)
    }
    pub fn encode(&self) -> Result<Vec<u8>, InvalidMetadata> {
        self.validate()?;
        let bytes = serde_json::to_vec(self).map_err(|_| InvalidMetadata)?;
        if bytes.len() > MAXIMUM_METADATA_BYTES {
            return Err(InvalidMetadata);
        }
        Ok(bytes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const GOLDEN: &[u8] = include_bytes!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../contracts/ready-metadata.json"
    ));
    #[test]
    fn current_swift_metadata_fields_and_iso8601_roundtrip_without_new_fields() {
        let metadata = CacheMetadata::decode(GOLDEN).unwrap();
        assert_eq!(metadata.format_version, 1);
        assert_eq!(metadata.source_byte_count, 67837);
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&metadata.encode().unwrap()).unwrap(),
            serde_json::from_slice::<serde_json::Value>(GOLDEN).unwrap()
        );
    }
    #[test]
    fn unknown_duplicate_nested_fields_and_oversized_json_are_rejected() {
        let base: serde_json::Value = serde_json::from_slice(GOLDEN).unwrap();
        for nested in [
            None,
            Some("cacheKey"),
            Some("parser"),
            Some("databasePreparation"),
        ] {
            let mut value = base.clone();
            let object = if let Some(nested) = nested {
                value[nested].as_object_mut().unwrap()
            } else {
                value.as_object_mut().unwrap()
            };
            object.insert(
                "sourcePath".into(),
                serde_json::Value::String("/private/user/source".into()),
            );
            assert_eq!(
                CacheMetadata::decode(&serde_json::to_vec(&value).unwrap()),
                Err(InvalidMetadata)
            );
        }
        let text = std::str::from_utf8(GOLDEN).unwrap();
        for (needle, duplicate) in [
            (
                "\"formatVersion\": 1",
                "\"formatVersion\": 1,\"formatVersion\": 1",
            ),
            (
                "\"indexVersion\": 3",
                "\"indexVersion\": 3,\"indexVersion\": 3",
            ),
            (
                "\"name\": \"trace_streamer\"",
                "\"name\": \"trace_streamer\",\"name\": \"trace_streamer\"",
            ),
        ] {
            let changed = text.replace(needle, duplicate);
            assert_ne!(changed, text);
            assert_eq!(
                CacheMetadata::decode(changed.as_bytes()),
                Err(InvalidMetadata)
            );
        }
        assert_eq!(
            CacheMetadata::decode(&vec![b' '; MAXIMUM_METADATA_BYTES + 1]),
            Err(InvalidMetadata)
        );
    }
    #[test]
    fn contradictory_identity_versions_sizes_and_dates_are_rejected() {
        let base = CacheMetadata::decode(GOLDEN).unwrap();
        for index in 0..10 {
            let mut value = base.clone();
            match index {
                0 => value.format_version = 2,
                1 => value.source_byte_count = 0,
                2 => value.database_byte_count = -1,
                3 => value.parser.binary_sha256 = "f".repeat(64),
                4 => value.schema_adapter_version = "9".into(),
                5 => value.database_preparation.index_version = 2,
                6 => value.database_preparation.schema_fingerprint = "f".repeat(64),
                7 => value.created_at = "2026-02-29T00:00:00Z".into(),
                8 => value.last_accessed_at = "2026-10-02T23:59:59Z".into(),
                _ => value.parser.name = "/Users/private/parser".into(),
            }
            assert_eq!(value.encode(), Err(InvalidMetadata), "case {index}");
        }
    }
    #[test]
    fn utc_conversion_covers_epoch_leap_year_century_and_upper_bound() {
        for (seconds, expected) in [
            (0, "1970-01-01T00:00:00Z"),
            (951782400, "2000-02-29T00:00:00Z"),
            (4107542400, "2100-03-01T00:00:00Z"),
            (253402300799, "9999-12-31T23:59:59Z"),
        ] {
            let actual = utc_from_unix_seconds(seconds).unwrap();
            assert_eq!(actual, expected);
            assert!(valid_utc(&actual));
        }
        assert_eq!(utc_from_unix_seconds(253402300800), Err(InvalidMetadata));
        assert_eq!(utc_from_unix_seconds(u64::MAX), Err(InvalidMetadata));
        assert!(!valid_utc("2026-10-03T00:00:00+00:00"));
    }
}
