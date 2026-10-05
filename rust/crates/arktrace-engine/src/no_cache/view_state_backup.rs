//! Complete immutable rollback bundles, published through a request-held owner.
//! The fixed backup profile outlives cache eviction; no legacy IO is required.
use super::*;
use crate::{
    MAXIMUM_VIEW_STATE_BYTES, ViewStateBackupReceipt as Receipt, ViewStateBackupReport as Report,
    ViewStateBackupStatus as Status, ViewStateDocument, ViewStateEncodeError, ViewStateRead,
};
use sha2::{Digest, Sha256};
use std::io::Write;

const RECEIPT_BYTES: u64 = 1024;
const BUNDLE_BYTES: u64 = MAXIMUM_VIEW_STATE_BYTES as u64 + RECEIPT_BYTES;

#[derive(Clone)]
pub struct ViewStateBackupStore {
    cache: HeldDirectory,
    backup: HeldDirectory,
    rollback: HeldDirectory,
    staging: HeldDirectory,
    owners: OwnerStore,
}

struct Encoder<'a> {
    bytes: Vec<u8>,
    io: &'a IoBudget,
    failure: Option<HostError>,
}
impl Encoder<'_> {
    fn reject(&mut self, error: HostError) -> std::io::Error {
        self.failure = Some(error);
        std::io::Error::other("rollback encoding stopped")
    }
}
impl Write for Encoder<'_> {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        if let Err(error) = self.io.check() {
            return Err(self.reject(error));
        }
        if bytes.len() > MAXIMUM_VIEW_STATE_BYTES.saturating_sub(self.bytes.len()) {
            return Err(self.reject(HostError::LimitExceeded));
        }
        self.bytes.extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// The one output allocation is reserved up front; no clone of the document
/// coexists with it. Readback happens only after the parsed document is dropped.
fn encode(
    document: ViewStateDocument,
    key: &TraceCacheKey,
    io: &IoBudget,
) -> Result<(Vec<u8>, Receipt), HostError> {
    io.check()?;
    let mut bytes = Vec::new();
    bytes
        .try_reserve_exact(MAXIMUM_VIEW_STATE_BYTES)
        .map_err(|_| HostError::LimitExceeded)?;
    // Vec reports actual usable capacity, including any allocator rounding.
    if bytes.capacity() > MAXIMUM_VIEW_STATE_BYTES {
        return Err(HostError::LimitExceeded);
    }
    let mut output = Encoder {
        bytes,
        io,
        failure: None,
    };
    if let Err(error) = document.write_persisted(key.trace_sha256(), &mut output) {
        return Err(output.failure.unwrap_or(match error {
            ViewStateEncodeError::InvalidDocument => HostError::InvalidEvidence,
            ViewStateEncodeError::InputBudgetExceeded => HostError::LimitExceeded,
        }));
    }
    io.check()?;
    let digest = format!("{:x}", Sha256::digest(&output.bytes));
    let receipt = Receipt {
        format_version: 1,
        backup_identifier: crate::view_state_backup::identifier(
            key.trace_sha256(),
            key.parser_key(),
            &digest,
        ),
        trace_sha256: key.trace_sha256().into(),
        parser_key: key.parser_key().into(),
        document_sha256: digest,
        document_byte_count: output.bytes.len() as u64,
        flag_count: document.flags.len(),
        persistent_mark_count: document.marks.iter().filter(|v| v.is_persistent).count(),
        favorite_track_count: document.favorite_track_ids.as_ref().map(Vec::len),
    };
    Ok((output.bytes, receipt))
}

impl ViewStateBackupStore {
    pub fn new(
        cache: HeldDirectory,
        backup: HeldDirectory,
        io: &IoBudget,
    ) -> Result<Self, HostError> {
        io.check()?;
        cache.revalidate()?;
        backup.revalidate()?;
        if cache.path().starts_with(backup.path()) || backup.path().starts_with(cache.path()) {
            return Err(HostError::InvalidEvidence);
        }
        let rollback = backup.ensure_private_child("rollback")?;
        let staging = rollback.ensure_private_child(".staging")?;
        let owners = OwnerStore::open(&staging, &rollback)?;
        io.check()?;
        Ok(Self {
            cache,
            backup,
            rollback,
            staging,
            owners,
        })
    }

    fn verify_bundle(
        &self,
        directory: &HeldDirectory,
        document: &[u8],
        receipt: &[u8],
        io: &IoBudget,
    ) -> Result<(), HostError> {
        let sealed = directory.seal_readonly_directory(io)?;
        if sealed.file_count() != 2
            || sealed.byte_count() != (document.len() + receipt.len()) as u64
        {
            return Err(HostError::InvalidEvidence);
        }
        for (name, expected, maximum_bytes) in [
            ("view-state.json", document, MAXIMUM_VIEW_STATE_BYTES as u64),
            ("receipt.json", receipt, RECEIPT_BYTES),
        ] {
            let file = directory.open_file(name)?;
            file.require_readonly()?;
            if file.read_bounded(&IoBudget {
                maximum_bytes,
                ..io.clone()
            })? != expected
            {
                return Err(HostError::InvalidEvidence);
            }
            file.verify()?;
        }
        sealed.verify(io)?;
        self.cache.revalidate()?;
        self.backup.revalidate()?;
        self.rollback.revalidate()?;
        io.check()
    }

    fn publish(
        &self,
        document: &[u8],
        receipt: Receipt,
        io: &IoBudget,
    ) -> Result<Report, HostError> {
        io.check()?;
        self.cache.revalidate()?;
        self.backup.revalidate()?;
        let bytes = serde_json::to_vec(&receipt).map_err(|_| HostError::InvalidEvidence)?;
        if bytes.len() as u64 > RECEIPT_BYTES {
            return Err(HostError::LimitExceeded);
        }
        match self.rollback.find_private_child(&receipt.backup_identifier) {
            Ok(Some(directory)) => {
                self.verify_bundle(&directory, document, &bytes, io)?;
                return Ok(Report {
                    status: Status::AlreadyBackedUp,
                    receipt: Some(receipt),
                });
            }
            Ok(None) => {}
            Err(error) => return Err(error),
        }
        let mut owned = self.owners.create(OwnerKind::Building, io)?;
        let staged = (|| {
            owned
                .directory()
                .write_new_readonly("view-state.json", document, io)?;
            owned
                .directory()
                .write_new_readonly("receipt.json", &bytes, io)?;
            self.verify_bundle(owned.directory(), document, &bytes, io)?;
            let sealed = owned.directory().seal_readonly_directory(io)?;
            self.staging.promote_sealed_directory_noreplace(
                &sealed,
                &self.rollback,
                &receipt.backup_identifier,
                io,
            )
        })();
        let directory = match staged {
            Ok(directory) => directory,
            Err(error) => {
                // A failed platform rollback retains ambiguous ownership.
                // All other prepublication failures remove only this owner.
                if error == HostError::CleanupFailed {
                    return Err(error);
                }
                owned
                    .cleanup(&IoBudget {
                        maximum_bytes: BUNDLE_BYTES,
                        deadline: Instant::now() + Duration::from_secs(5),
                        cancellation: CancellationToken::default(),
                    })
                    .map_err(|_| HostError::CleanupFailed)?;
                if error == HostError::AlreadyExists {
                    let directory = self
                        .rollback
                        .open_private_child(&receipt.backup_identifier)?;
                    self.verify_bundle(&directory, document, &bytes, io)?;
                    return Ok(Report {
                        status: Status::AlreadyBackedUp,
                        receipt: Some(receipt),
                    });
                }
                return Err(error);
            }
        };
        // Publication has committed the complete folder. Subsequent failure or
        // cancellation preserves it for verification on the next request.
        owned.record_published_location(&directory, io)?;
        self.verify_bundle(&directory, document, &bytes, io)?;
        self.backup.sync()?;
        io.check()?;
        Ok(Report {
            status: Status::BackedUp,
            receipt: Some(receipt),
        })
    }
}

impl EngineSession {
    /// Read a validated snapshot under this Session's existing key lock, then
    /// publish it separately. Other Sessions can write after that snapshot;
    /// the receipt identifies these exact bytes, not global latest state.
    pub fn backup_view_state(
        &self,
        store: &ViewStateBackupStore,
        budget: &EngineBudget,
    ) -> Result<Report, EngineError> {
        self.query_reader(budget)?;
        if let SessionStorage::Cached { directory, .. } = &self.storage
            && directory.path()
                != store
                    .cache
                    .path()
                    .join(self.metadata.cache_key.trace_sha256())
                    .join(self.metadata.cache_key.parser_key())
        {
            return Err(host(EngineStage::Querying, HostError::InvalidEvidence));
        }
        let document = match self.read_view_state(budget)? {
            ViewStateRead::SessionScoped => return Ok(Report::empty(Status::SessionScoped)),
            ViewStateRead::Missing => return Ok(Report::empty(Status::Missing)),
            ViewStateRead::Preserved => return Ok(Report::empty(Status::Preserved)),
            ViewStateRead::Restored(document) => document,
        };
        let io = budget.io(BUNDLE_BYTES);
        let (bytes, receipt) = encode(document, &self.metadata.cache_key, &io)
            .map_err(|e| host(EngineStage::Querying, e))?;
        self.query_reader(budget)?;
        let result = store
            .publish(&bytes, receipt, &io)
            .map_err(|e| host(EngineStage::Querying, e));
        self.query_reader(budget)?;
        result
    }
}

#[cfg(test)]
mod tests;
