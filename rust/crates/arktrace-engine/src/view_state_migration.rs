//! Path-free decisions for a one-way format-1 annotation import. A source
//! never grants database authority. Native IO keeps all original bytes.
#[cfg(any(target_os = "macos", test))]
use crate::{CacheMetadata, ViewStateDocument};
use serde::{Deserialize, Serialize};
#[cfg(any(target_os = "macos", test))]
use sha2::{Digest, Sha256};

pub const MAXIMUM_LEGACY_VIEW_STATE_ENTRIES: usize = 64;
pub const MAXIMUM_LEGACY_BACKUP_FILE_BYTES: u64 = 16 * 1024 * 1024;
pub const MAXIMUM_LEGACY_BACKUP_SCAN_BYTES: u64 = 64 * 1024 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LegacyViewStateIssue {
    SourceUnavailable,
    BackupTooLarge,
    MetadataPreserved,
    IdentityMismatch,
    SidecarPreserved,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LegacyViewStateSource {
    pub parser_key: String,
    pub snapshot_identifier: Option<String>,
    #[serde(rename = "metadataSHA256")]
    pub metadata_sha256: Option<String>,
    pub metadata_byte_count: Option<u64>,
    #[serde(rename = "sidecarSHA256")]
    pub sidecar_sha256: Option<String>,
    pub sidecar_byte_count: Option<u64>,
    pub source_format_version: Option<u32>,
    pub backed_up: bool,
    pub issue: Option<LegacyViewStateIssue>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum LegacyViewStateMigrationStatus {
    NotConfigured,
    Missing,
    Conflict,
    PreservedSource,
    InvalidSelection,
    Imported,
    AlreadyCompleted,
    DestinationKept,
    PreservedDestination,
    SessionScoped,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LegacyViewStateMigrationReport {
    pub status: LegacyViewStateMigrationStatus,
    pub sources: Vec<LegacyViewStateSource>,
    pub candidates: Vec<LegacyViewStateCandidateSummary>,
    pub selected_snapshot_identifier: Option<String>,
    /// Cross-parser identities retain their original order and duplicates.
    /// They are backup records, never guessed or projected into another lane.
    #[serde(rename = "unmatchedFavoriteTrackIDs")]
    pub unmatched_favorite_track_ids: Vec<String>,
}

/// Presentation facts are derived from validated bytes, separate from the
/// immutable source backup record so existing receipts remain byte-stable.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LegacyViewStateCandidateSummary {
    pub snapshot_identifier: String,
    pub parser_reported_version: String,
    pub flag_count: usize,
    pub persistent_mark_count: usize,
    pub favorite_track_count: Option<usize>,
    pub exact_parser_identity: bool,
    pub label_previews: Vec<String>,
}

#[cfg(target_os = "macos")]
impl LegacyViewStateMigrationReport {
    pub(crate) fn empty(status: LegacyViewStateMigrationStatus) -> Self {
        Self {
            status,
            sources: vec![],
            candidates: vec![],
            selected_snapshot_identifier: None,
            unmatched_favorite_track_ids: vec![],
        }
    }
}

#[cfg(any(target_os = "macos", test))]
#[derive(Clone)]
pub(crate) struct Candidate {
    pub source: LegacyViewStateSource,
    pub metadata: Option<CacheMetadata>,
    pub document: Option<ViewStateDocument>,
}

#[cfg(any(target_os = "macos", test))]
impl Candidate {
    pub(crate) fn summary(
        &self,
        target: &CacheMetadata,
    ) -> Option<LegacyViewStateCandidateSummary> {
        if self.source.issue.is_some() || !self.source.backed_up {
            return None;
        }
        let metadata = self.metadata.as_ref()?;
        let document = self.document.as_ref()?;
        let previews = document
            .flags
            .iter()
            .map(|v| &v.label)
            .chain(
                document
                    .marks
                    .iter()
                    .filter(|v| v.is_persistent)
                    .map(|v| &v.label),
            )
            .filter(|label| !label.is_empty())
            .take(3)
            .map(|label| {
                let mut end = label.len().min(256);
                while !label.is_char_boundary(end) {
                    end -= 1;
                }
                label[..end].to_owned()
            })
            .collect();
        Some(LegacyViewStateCandidateSummary {
            snapshot_identifier: self.source.snapshot_identifier.clone()?,
            parser_reported_version: metadata.parser.reported_version.clone(),
            flag_count: document.flags.len(),
            persistent_mark_count: document.marks.iter().filter(|v| v.is_persistent).count(),
            favorite_track_count: document.favorite_track_ids.as_ref().map(Vec::len),
            exact_parser_identity: metadata.parser == target.parser
                && metadata.cache_key == target.cache_key,
            label_previews: previews,
        })
    }
}

#[cfg(any(target_os = "macos", test))]
pub(crate) enum Decision {
    Stop(LegacyViewStateMigrationStatus),
    Import(usize),
}

#[cfg(any(target_os = "macos", test))]
pub(crate) fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

#[cfg(any(target_os = "macos", test))]
pub(crate) fn snapshot_identifier(
    trace: &str,
    parser: &str,
    metadata: &str,
    sidecar: &str,
) -> String {
    // All four fields are fixed-width lowercase SHA256 values. No pathname,
    // mtime, source ordering or absolute user location affects the identity.
    digest(format!("ArkTrace.ViewStateImport.v1:{trace}:{parser}:{metadata}:{sidecar}").as_bytes())
}

#[cfg(any(target_os = "macos", test))]
pub(crate) fn decide(
    candidates: &[Candidate],
    target: &CacheMetadata,
    selected: Option<&str>,
) -> Decision {
    if let Some(selected) = selected {
        return candidates
            .iter()
            .position(|candidate| {
                candidate.source.snapshot_identifier.as_deref() == Some(selected)
                    && candidate.source.issue.is_none()
                    && candidate.document.is_some()
                    && candidate.metadata.is_some()
            })
            .map(Decision::Import)
            .unwrap_or(Decision::Stop(
                LegacyViewStateMigrationStatus::InvalidSelection,
            ));
    }
    let Some(first) = candidates.first() else {
        return Decision::Stop(LegacyViewStateMigrationStatus::Missing);
    };
    if candidates
        .iter()
        .any(|candidate| candidate.source.issue.is_some())
    {
        return Decision::Stop(LegacyViewStateMigrationStatus::PreservedSource);
    }
    if candidates
        .iter()
        .any(|candidate| candidate.document != first.document)
    {
        return Decision::Stop(LegacyViewStateMigrationStatus::Conflict);
    }
    // Equal documents may come from distinct parser identities. Prefer the
    // exact target identity; otherwise sorted parser-key order is stable.
    Decision::Import(
        candidates
            .iter()
            .position(|candidate| {
                candidate.metadata.as_ref().is_some_and(|metadata| {
                    metadata.parser == target.parser && metadata.cache_key == target.cache_key
                })
            })
            .unwrap_or(0),
    )
}

#[cfg(any(target_os = "macos", test))]
pub(crate) fn import_document(
    candidate: &Candidate,
    target: &CacheMetadata,
) -> (ViewStateDocument, Vec<String>) {
    let mut document = candidate
        .document
        .as_ref()
        .expect("validated candidate")
        .persisted();
    let exact_identity = candidate.metadata.as_ref().is_some_and(|metadata| {
        metadata.parser == target.parser && metadata.cache_key == target.cache_key
    });
    let unmatched = if exact_identity {
        vec![]
    } else {
        document.favorite_track_ids.take().unwrap_or_default()
    };
    (document, unmatched)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{ViewStateRead, metadata::MAXIMUM_METADATA_BYTES};
    use arktrace_contract::TraceCacheKey;
    fn metadata() -> CacheMetadata {
        CacheMetadata::decode(include_bytes!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../contracts/ready-metadata.json"
        )))
        .unwrap()
    }
    fn candidate(metadata: CacheMetadata, label: &str) -> Candidate {
        let bytes = serde_json::to_vec(&serde_json::json!({
            "formatVersion":1,"traceSHA256":metadata.trace_sha256,
            "flags":[{"id":1,"timestampNs":i64::MAX,"label":label,"colorIndex":i64::MIN}],
            "marks":[],"favoriteTrackIDs":["thread:7","thread:7","unknown"]
        }))
        .unwrap();
        let ViewStateRead::Restored(document) =
            ViewStateDocument::decode(&bytes, &metadata.trace_sha256)
        else {
            panic!("invalid fixture")
        };
        Candidate {
            source: LegacyViewStateSource {
                parser_key: metadata.cache_key.parser_key().into(),
                snapshot_identifier: Some(digest(&bytes)),
                metadata_sha256: Some(digest(&metadata.encode().unwrap())),
                metadata_byte_count: Some(100),
                sidecar_sha256: Some(digest(&bytes)),
                sidecar_byte_count: Some(bytes.len() as u64),
                source_format_version: Some(1),
                backed_up: true,
                issue: None,
            },
            metadata: Some(metadata),
            document: Some(document),
        }
    }
    fn old_parser(mut metadata: CacheMetadata) -> CacheMetadata {
        metadata.parser.binary_sha256 = "f".repeat(64);
        metadata.cache_key = TraceCacheKey::new(
            &metadata.trace_sha256,
            &metadata.parser.binary_sha256,
            &metadata.parser.upstream_revision,
            &metadata.schema_adapter_version,
            i64::from(metadata.index_schema_version),
        )
        .unwrap();
        metadata
    }
    #[test]
    fn candidate_presentation_uses_validated_bytes_and_bounded_utf8_previews() {
        let target = metadata();
        let mut source = candidate(old_parser(target.clone()), &"🦀".repeat(100));
        let summary = source.summary(&target).unwrap();
        assert!(!summary.exact_parser_identity);
        assert_eq!(summary.flag_count, 1);
        assert_eq!(summary.persistent_mark_count, 0);
        assert_eq!(summary.favorite_track_count, Some(3));
        assert_eq!(summary.label_previews, vec!["🦀".repeat(64)]);
        source.source.issue = Some(LegacyViewStateIssue::MetadataPreserved);
        assert!(source.summary(&target).is_none());
        source.source.issue = None;
        source.source.backed_up = false;
        assert!(source.summary(&target).is_none());
    }
    #[test]
    fn different_annotations_require_choice_and_no_timestamp_winner() {
        let target = metadata();
        let mut left = candidate(target.clone(), "old 🦀");
        let mut right = candidate(old_parser(target.clone()), "other");
        left.metadata.as_mut().unwrap().last_accessed_at = "2099-01-01T00:00:00Z".into();
        right.metadata.as_mut().unwrap().last_accessed_at = "1970-01-01T00:00:00Z".into();
        let values = [left, right];
        assert!(matches!(
            decide(&values, &target, None),
            Decision::Stop(LegacyViewStateMigrationStatus::Conflict)
        ));
        assert!(matches!(
            decide(
                &values,
                &target,
                values[1].source.snapshot_identifier.as_deref()
            ),
            Decision::Import(1)
        ));
        assert!(matches!(
            decide(&values, &target, Some("../chosen")),
            Decision::Stop(LegacyViewStateMigrationStatus::InvalidSelection)
        ));
    }
    #[test]
    fn matching_identity_preserves_favorites_and_foreign_parser_retains_unmatched_bytes() {
        let target = metadata();
        let values = [
            candidate(old_parser(target.clone()), "same"),
            candidate(target.clone(), "same"),
        ];
        assert!(matches!(
            decide(&values, &target, None),
            Decision::Import(1)
        ));
        let (same, unmatched) = import_document(&values[1], &target);
        assert!(unmatched.is_empty());
        assert_eq!(
            same.favorite_track_ids,
            Some(vec!["thread:7".into(), "thread:7".into(), "unknown".into()])
        );
        let (foreign, unmatched) = import_document(&values[0], &target);
        assert_eq!(foreign.favorite_track_ids, None);
        assert_eq!(unmatched, ["thread:7", "thread:7", "unknown"]);
        assert_eq!(foreign.flags, same.flags);
        assert_eq!(foreign.flags[0].timestamp_ns, i64::MAX);
        assert_eq!(foreign.flags[0].color_index, i64::MIN);
    }
    #[test]
    fn damaged_candidates_block_automatic_import_but_valid_explicit_choice_remains_available() {
        let target = metadata();
        let good = candidate(target.clone(), "kept");
        let mut bad = candidate(old_parser(target.clone()), "broken");
        bad.document = None;
        bad.source.issue = Some(LegacyViewStateIssue::SidecarPreserved);
        let values = [good, bad];
        assert!(matches!(
            decide(&values, &target, None),
            Decision::Stop(LegacyViewStateMigrationStatus::PreservedSource)
        ));
        assert!(matches!(
            decide(
                &values,
                &target,
                values[0].source.snapshot_identifier.as_deref()
            ),
            Decision::Import(0)
        ));
        assert!(matches!(
            decide(
                &values,
                &target,
                values[1].source.snapshot_identifier.as_deref()
            ),
            Decision::Stop(LegacyViewStateMigrationStatus::InvalidSelection)
        ));
    }
    #[test]
    fn older_format_one_parser_versions_are_annotation_evidence_only() {
        let mut old = metadata();
        old.schema_adapter_version = "old-adapter".into();
        old.index_schema_version = 1;
        old.parser.adapter_version = "old-parser".into();
        old.database_preparation.schema_adapter_version = old.schema_adapter_version.clone();
        old.database_preparation.index_version = old.index_schema_version;
        old.cache_key = TraceCacheKey::new(
            &old.trace_sha256,
            &old.parser.binary_sha256,
            &old.parser.upstream_revision,
            &old.schema_adapter_version,
            1,
        )
        .unwrap();
        let bytes = serde_json::to_vec(&old).unwrap();
        assert!(CacheMetadata::decode(&bytes).is_err());
        assert_eq!(CacheMetadata::decode_legacy_view_state(&bytes), Ok(old));
        assert!(
            CacheMetadata::decode_legacy_view_state(&vec![0; MAXIMUM_METADATA_BYTES + 1]).is_err()
        );
        let mut value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        value["sourceSHA256"] = "b".repeat(64).into();
        assert!(
            CacheMetadata::decode_legacy_view_state(&serde_json::to_vec(&value).unwrap()).is_err()
        );
    }

    #[test]
    fn a_choice_is_bound_to_both_raw_inputs_not_just_the_parser_entry() {
        let target = metadata();
        let mut source = candidate(target.clone(), "first");
        let metadata_digest = source.source.metadata_sha256.as_deref().unwrap();
        let first = snapshot_identifier(
            &target.trace_sha256,
            source.source.parser_key.as_str(),
            metadata_digest,
            source.source.sidecar_sha256.as_deref().unwrap(),
        );
        let second = snapshot_identifier(
            &target.trace_sha256,
            source.source.parser_key.as_str(),
            metadata_digest,
            &digest(b"changed original bytes"),
        );
        assert_ne!(first, second);
        source.source.snapshot_identifier = Some(second);
        assert!(matches!(
            decide(&[source], &target, Some(&first)),
            Decision::Stop(LegacyViewStateMigrationStatus::InvalidSelection)
        ));
    }
}
