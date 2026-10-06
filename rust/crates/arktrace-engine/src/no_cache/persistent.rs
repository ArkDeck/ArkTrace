//! Persistent Ready authority in an isolated native cache root. Parser,
//! preparation, publication and query composition are shared with ephemeral.
use super::*;
use arktrace_platform::{PublishedOwnerEvidence, SourceFacts};

const EXCLUSIVE_LEASE_GRACE: Duration = Duration::from_secs(2);

pub fn open_cached(
    source: &HeldFile,
    format: SourceFormat,
    tools: &ParserTools<'_>,
    cache_root: &HeldDirectory,
    budget: &EngineBudget,
    report: impl FnMut(EngineProgress),
) -> Result<EngineSession, EngineError> {
    open_store(source, format, tools, cache_root, budget, true, report)
}

fn cache_error(f: EngineFailure) -> EngineError {
    failure(EngineStage::CacheLookup, f)
}

pub(super) fn exclusive_lease(
    leases: &HeldDirectory,
    key: &TraceCacheKey,
    budget: &EngineBudget,
) -> Result<Lease, EngineError> {
    let mut io = budget.io(MAXIMUM_METADATA_BYTES as u64);
    io.deadline = io.deadline.min(Instant::now() + EXCLUSIVE_LEASE_GRACE);
    Lease::acquire(
        leases,
        &format!("{}.lease", key.entry_identifier()),
        LeaseMode::Exclusive,
        &io,
    )
    .map_err(|e| {
        if e == HostError::DeadlineExceeded && budget.io(1).check().is_ok() {
            cache_error(EngineFailure::CacheBusy)
        } else {
            host(EngineStage::CacheLookup, e)
        }
    })
}

fn records(
    owners: &OwnerStore,
    key: &TraceCacheKey,
    io: &IoBudget,
) -> Result<Vec<PublishedOwnerEvidence>, EngineError> {
    let mut result = Vec::new();
    for id in owners
        .identifiers(io)
        .map_err(|e| host(EngineStage::CacheLookup, e))?
    {
        io.check().map_err(|e| host(EngineStage::CacheLookup, e))?;
        let record = owners
            .published_evidence(&id, io)
            .map_err(|e| host(EngineStage::CacheLookup, e))?;
        if record.is_none() {
            // A crash before format-4 binding leaves only a generic owned
            // input/build. Generic recovery cannot dispose any bound Ready.
            owners
                .recover_stale(&id, io)
                .map_err(|e| host(EngineStage::CacheLookup, e))?;
        }
        if let Some(record) = record
            && record.is_cached()
            && record.key_identifier() == Some(key.entry_identifier().as_str())
        {
            result.push(record);
        }
    }
    Ok(result)
}

// Unknown/foreign entries never become deletion authority. An abandoned build
// is disposable only through its format-4 owner binding and the fixed leases.
fn recover_missing(
    owners: &OwnerStore,
    key: &TraceCacheKey,
    key_lock: &Lease,
    entry: &Lease,
    io: &IoBudget,
) -> Result<(), EngineError> {
    for record in records(owners, key, io)? {
        if record.is_quarantined() {
            owners
                .quarantine_cached(&record, key_lock, entry, io)
                .map_err(|e| host(EngineStage::CacheLookup, e))?;
        } else {
            let outcome = owners
                .recover_cached_build(&record, key_lock, entry, io)
                .map_err(|e| host(EngineStage::CacheLookup, e))?;
            if outcome != OwnerRecoveryOutcome::Removed {
                return Err(cache_error(EngineFailure::CacheCorrupt));
            }
        }
    }
    Ok(())
}

fn matching_owner(
    owners: &OwnerStore,
    key: &TraceCacheKey,
    key_lock: &Lease,
    lease: &Lease,
    directory: &HeldDirectory,
    io: &IoBudget,
) -> Result<PublishedOwnerEvidence, EngineError> {
    let mut matched = None;
    for record in records(owners, key, io)? {
        let located = owners
            .validate_cached_location(&record, key_lock, lease, io)
            .map_err(|e| host(EngineStage::CacheLookup, e))?;
        if located
            .as_ref()
            .is_some_and(|d| d.identity() == directory.identity())
        {
            if matched.is_some() {
                return Err(cache_error(EngineFailure::CacheCorrupt));
            }
            matched = Some(record);
        }
    }
    matched.ok_or_else(|| cache_error(EngineFailure::CacheUnsupported))
}

fn decode_current(
    directory: &HeldDirectory,
    budget: &EngineBudget,
) -> Result<(HeldFile, CacheMetadata), EngineError> {
    let file = directory
        .open_file("metadata.json")
        .map_err(|e| host(EngineStage::CacheLookup, e))?;
    let bytes = file
        .read_bounded(&budget.io(MAXIMUM_METADATA_BYTES as u64))
        .map_err(|e| {
            if e == HostError::LimitExceeded {
                cache_error(EngineFailure::CacheCorrupt)
            } else {
                host(EngineStage::CacheLookup, e)
            }
        })?;
    // Peek solely to preserve future formats. Decode the original byte stream
    // below, so duplicate fields cannot be collapsed into a valid document.
    if let Ok(shape) = serde_json::from_slice::<serde_json::Value>(&bytes)
        && shape
            .get("formatVersion")
            .and_then(serde_json::Value::as_u64)
            .is_some_and(|v| v != 1)
    {
        return Err(cache_error(EngineFailure::CacheUnsupported));
    }
    let metadata =
        CacheMetadata::decode(&bytes).map_err(|_| cache_error(EngineFailure::CacheCorrupt))?;
    Ok((file, metadata))
}

fn validate_entry(
    directory: &HeldDirectory,
    original: &SourceFacts,
    tools: &ParserTools<'_>,
    key: &TraceCacheKey,
    budget: &EngineBudget,
) -> Result<(Arc<HeldFile>, StoreReader, HeldFile, CacheMetadata), EngineError> {
    let (metadata_file, metadata) = decode_current(directory, budget)?;
    if metadata.cache_key != *key
        || metadata.parser != tools.identity
        || metadata.source_byte_count as u64 != original.byte_count
        || metadata.source_sha256 != original.sha256
    {
        return Err(cache_error(EngineFailure::CacheCorrupt));
    }
    let mut members = vec!["trace.sqlite", "metadata.json"];
    match directory.open_file("view-state.json") {
        Ok(file) => {
            file.verify()
                .map_err(|e| host(EngineStage::CacheLookup, e))?;
            members.push("view-state.json");
        }
        Err(HostError::NotFound) => (),
        Err(e) => return Err(host(EngineStage::CacheLookup, e)),
    }
    directory
        .require_file_membership(&members, &budget.io(budget.maximum_database_bytes))
        .map_err(|e| host(EngineStage::CacheLookup, e))?;
    let database = Arc::new(
        directory
            .open_file("trace.sqlite")
            .map_err(|e| host(EngineStage::CacheLookup, e))?,
    );
    if database.snapshot().byte_count != metadata.database_byte_count as u64 {
        return Err(cache_error(EngineFailure::CacheCorrupt));
    }
    let reader = StoreReader::open(database.clone(), &budget.validation())
        .map_err(|e| failure(EngineStage::CacheLookup, EngineFailure::Store(e)))?;
    if reader.inspection().schema_fingerprint != metadata.schema_fingerprint {
        return Err(cache_error(EngineFailure::CacheCorrupt));
    }
    Ok((database, reader, metadata_file, metadata))
}

fn indicts_entry(error: &EngineError) -> bool {
    match error.failure {
        EngineFailure::CacheCorrupt => true,
        EngineFailure::Host(e) => indicts_host(e),
        EngineFailure::Store(
            StoreError::Cancelled
            | StoreError::DeadlineExceeded
            | StoreError::CleanupFailed
            | StoreError::WorkerFailed
            | StoreError::InvalidBudget
            | StoreError::VmBudgetExceeded
            | StoreError::SchemaBudgetExceeded
            | StoreError::SQLiteRuntimeMismatch
            | StoreError::SQLite { .. },
        ) => false,
        EngineFailure::Store(StoreError::Host(e)) => indicts_host(e),
        EngineFailure::Store(_) => true,
        _ => false,
    }
}

fn indicts_host(error: HostError) -> bool {
    matches!(
        error,
        HostError::NotFound
            | HostError::NotRegular
            | HostError::NotDirectory
            | HostError::NotPrivate
            | HostError::LinkedObject
            | HostError::Changed
            | HostError::IdentityMismatch
            | HostError::InvalidEvidence
    )
}

#[allow(clippy::too_many_arguments)]
pub(super) fn lookup(
    source: &HeldFile,
    original: &SourceFacts,
    tools: &ParserTools<'_>,
    root: &HeldDirectory,
    owners: &OwnerStore,
    locks: &HeldDirectory,
    leases: &HeldDirectory,
    hash_directory: &HeldDirectory,
    key: &TraceCacheKey,
    key_lock: &Lease,
    budget: &EngineBudget,
    report: &mut impl FnMut(EngineProgress),
) -> Result<Option<EngineSession>, EngineError> {
    let io = budget.io(budget
        .maximum_database_bytes
        .max(MAXIMUM_METADATA_BYTES as u64));
    let mut lease = Lease::acquire(
        leases,
        &format!("{}.lease", key.entry_identifier()),
        LeaseMode::Shared,
        &io,
    )
    .map_err(|e| host(EngineStage::CacheLookup, e))?;
    let directory = match hash_directory.open_private_child(key.parser_key()) {
        Ok(d) => d,
        Err(HostError::NotFound) => {
            drop(lease);
            let exclusive = exclusive_lease(leases, key, budget)?;
            recover_missing(owners, key, key_lock, &exclusive, &io)?;
            return Ok(None);
        }
        Err(e) => return Err(host(EngineStage::CacheLookup, e)),
    };
    let record = matching_owner(owners, key, key_lock, &lease, &directory, &io)?;
    let sidecars = SidecarStore::open(root, crate::MAXIMUM_VIEW_STATE_BYTES as u64, &io)
        .map_err(|e| host(EngineStage::Recovering, e))?;
    sidecars
        .recover_orphans(&io)
        .map_err(|e| host(EngineStage::Recovering, e))?;
    let recovered = sidecars
        .recover(&directory, key_lock, &lease, &io)
        .map_err(|e| host(EngineStage::Recovering, e))?;
    let journal_ready = matches!(
        recovered,
        SidecarRecovery::Absent | SidecarRecovery::Aborted | SidecarRecovery::Committed
    );
    if record.is_quarantined() {
        if !journal_ready {
            return Err(cache_error(EngineFailure::CacheUnsupported));
        }
        drop(lease);
        let exclusive = exclusive_lease(leases, key, budget)?;
        owners
            .quarantine_cached(&record, key_lock, &exclusive, &io)
            .map_err(|e| host(EngineStage::CacheLookup, e))?;
        recover_missing(owners, key, key_lock, &exclusive, &io)?;
        return Ok(None);
    }
    if !record.is_ready() && !record.is_publishing() {
        return Err(cache_error(EngineFailure::CacheUnsupported));
    }
    report(EngineProgress::OpeningDatabase);
    let validated = validate_entry(&directory, original, tools, key, budget);
    let (database, reader, metadata_file, mut metadata) = match validated {
        Ok(v) => v,
        Err(error) if indicts_entry(&error) => {
            if !journal_ready {
                return Err(error);
            }
            drop(lease);
            let exclusive = exclusive_lease(leases, key, budget)?;
            owners
                .quarantine_cached(&record, key_lock, &exclusive, &io)
                .map_err(|e| host(EngineStage::CacheLookup, e))?;
            recover_missing(owners, key, key_lock, &exclusive, &io)?;
            return Ok(None);
        }
        Err(error) => return Err(error),
    };
    if record.is_publishing() {
        drop(lease);
        lease = exclusive_lease(leases, key, budget)?;
        owners
            .complete_cached_publication(&record, &directory, key_lock, &lease, &io)
            .map_err(|e| host(EngineStage::CacheLookup, e))?;
        lease
            .downgrade_shared()
            .map_err(|e| host(EngineStage::CacheLookup, e))?;
    }
    // Bookkeeping failure does not indict a just-validated Ready. Whichever
    // document is current must still have exactly the same immutable fields.
    let mut updated = metadata.clone();
    if let Ok(now) = SystemTime::now().duration_since(UNIX_EPOCH)
        && let Ok(now) = utc_from_unix_seconds(now.as_secs())
    {
        updated.last_accessed_at = now.max(metadata.last_accessed_at.clone());
        if let Ok(bytes) = updated.encode() {
            let replacement = directory.replace_readonly(
                &metadata_file,
                &bytes,
                &budget.io(MAXIMUM_METADATA_BYTES as u64),
            );
            if replacement.is_err_and(|e| e == HostError::CleanupFailed) {
                return Err(cache_error(EngineFailure::CleanupFailed));
            }
        }
    }
    let (current_file, current) = decode_current(&directory, budget)?;
    if !same_immutable_metadata(&current, &metadata) {
        return Err(cache_error(EngineFailure::CacheCorrupt));
    }
    metadata = current;
    source
        .verify()
        .map_err(|e| host(EngineStage::SourceSnapshot, e))?;
    // validate_entry fully inspected this exact held immutable database.
    // Recheck its binding, timestamps, mode, sidecars and budget after the
    // metadata update without repeating the full SQLite integrity scan.
    reader
        .verify_snapshot(&budget.validation())
        .map_err(|e| failure(EngineStage::CacheLookup, EngineFailure::Store(e)))?;
    current_file
        .verify()
        .map_err(|e| host(EngineStage::CacheLookup, e))?;
    key_lock
        .revalidate()
        .map_err(|e| host(EngineStage::CacheLookup, e))?;
    lease
        .revalidate()
        .map_err(|e| host(EngineStage::CacheLookup, e))?;
    io.check().map_err(|e| host(EngineStage::CacheLookup, e))?;
    let inspection = reader.inspection().clone();
    let session = EngineSession {
        storage: SessionStorage::Cached {
            directory,
            lease,
            locks: locks.clone(),
            sidecars,
        },
        cache_hit: true,
        database: Some(database),
        reader: Some(reader),
        metadata_file: Some(current_file),
        metadata,
        inspection,
        cleanup_bytes: io.maximum_bytes,
        query_worker_failed: Cell::new(false),
        viewer: RefCell::default(),
    };
    report(EngineProgress::Ready);
    Ok(Some(session))
}

fn same_immutable_metadata(current: &CacheMetadata, expected: &CacheMetadata) -> bool {
    let mut current = current.clone();
    current
        .last_accessed_at
        .clone_from(&expected.last_accessed_at);
    current == *expected
}

impl EngineSession {
    pub(super) fn verify_metadata(&self, budget: &EngineBudget) -> Result<(), EngineError> {
        match &self.storage {
            SessionStorage::Ephemeral { .. } => self
                .metadata_file
                .as_ref()
                .ok_or_else(|| failure(EngineStage::Querying, EngineFailure::InvalidMetadata))?
                .verify()
                .map_err(|e| host(EngineStage::Querying, e)),
            SessionStorage::Cached { directory, .. } => {
                let (file, metadata) = decode_current(directory, budget).map_err(|mut e| {
                    e.stage = EngineStage::Querying;
                    e
                })?;
                if !same_immutable_metadata(&metadata, &self.metadata) {
                    return Err(failure(
                        EngineStage::Querying,
                        EngineFailure::InvalidMetadata,
                    ));
                }
                file.verify().map_err(|e| host(EngineStage::Querying, e))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn resource_failures_do_not_quarantine_a_valid_cache_entry() {
        for error in [
            EngineFailure::Host(HostError::Cancelled),
            EngineFailure::Host(HostError::DeadlineExceeded),
            EngineFailure::Host(HostError::LimitExceeded),
            EngineFailure::Host(HostError::CleanupFailed),
            EngineFailure::Host(HostError::SystemIo {
                operation: arktrace_platform::HostOperation::Read,
                code: 5,
            }),
            EngineFailure::Store(StoreError::VmBudgetExceeded),
            EngineFailure::Store(StoreError::SchemaBudgetExceeded),
            EngineFailure::Store(StoreError::SQLiteRuntimeMismatch),
            EngineFailure::Store(StoreError::SQLite { code: 10 }),
            EngineFailure::CacheUnsupported,
        ] {
            assert!(!indicts_entry(&cache_error(error)));
        }
        for error in [
            EngineFailure::CacheCorrupt,
            EngineFailure::Host(HostError::NotFound),
            EngineFailure::Store(StoreError::InvalidReadyIndexes),
            EngineFailure::Store(StoreError::InvalidDatabase),
        ] {
            assert!(indicts_entry(&cache_error(error)));
        }
    }
}
