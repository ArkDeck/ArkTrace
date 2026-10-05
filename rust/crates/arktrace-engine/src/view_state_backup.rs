//! Fixed, path-free receipts for user-requested rollback snapshots.
use serde::{Deserialize, Serialize};
#[cfg(target_os = "macos")]
use sha2::{Digest, Sha256};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ViewStateBackupStatus {
    NotConfigured,
    SessionScoped,
    Missing,
    Preserved,
    BackedUp,
    AlreadyBackedUp,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ViewStateBackupReceipt {
    pub format_version: u32,
    pub backup_identifier: String,
    #[serde(rename = "traceSHA256")]
    pub trace_sha256: String,
    pub parser_key: String,
    #[serde(rename = "documentSHA256")]
    pub document_sha256: String,
    pub document_byte_count: u64,
    pub flag_count: usize,
    pub persistent_mark_count: usize,
    pub favorite_track_count: Option<usize>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ViewStateBackupReport {
    pub status: ViewStateBackupStatus,
    pub receipt: Option<ViewStateBackupReceipt>,
}
#[cfg(target_os = "macos")]
impl ViewStateBackupReport {
    pub(crate) fn empty(status: ViewStateBackupStatus) -> Self {
        Self {
            status,
            receipt: None,
        }
    }
}

#[cfg(target_os = "macos")]
pub(crate) fn identifier(trace: &str, parser: &str, document: &str) -> String {
    let mut hash = Sha256::new();
    hash.update(b"ArkTrace.ViewStateRollback.v1\0");
    for value in [trace, parser, document] {
        hash.update(value.as_bytes());
        hash.update([0]);
    }
    format!("{:x}", hash.finalize())
}
