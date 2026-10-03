/// Closed host failures. No pathname or OS diagnostic prose enters this type.
#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub enum HostError {
    InvalidPath,
    InvalidLimit,
    InvalidEvidence,
    NotFound,
    NotRegular,
    NotDirectory,
    NotPrivate,
    LinkedObject,
    Changed,
    IdentityMismatch,
    LimitExceeded,
    AlreadyExists,
    Busy,
    Cancelled,
    DeadlineExceeded,
    CrossVolume,
    CleanupFailed,
    SystemIo { operation: HostOperation, code: i32 },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub enum HostOperation {
    Open,
    Stat,
    Read,
    Write,
    CreateDirectory,
    SetPermissions,
    Sync,
    Rename,
    Remove,
    Lock,
}

impl std::fmt::Display for HostError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{self:?}")
    }
}

impl std::error::Error for HostError {}
