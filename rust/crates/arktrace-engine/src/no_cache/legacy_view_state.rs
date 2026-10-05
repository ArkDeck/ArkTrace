//! Fixed, disjoint migration roots. Legacy entries are only read through held
//! descriptors and existing read-only locks. Backups and receipts outlive LRU.
use super::*;
use crate::view_state_migration::{self as model, Candidate, Decision};
use crate::{
    LegacyViewStateIssue as Issue, LegacyViewStateMigrationReport as Report,
    LegacyViewStateMigrationStatus as Status, LegacyViewStateSource as Source,
    MAXIMUM_LEGACY_BACKUP_FILE_BYTES, MAXIMUM_LEGACY_BACKUP_SCAN_BYTES,
    MAXIMUM_LEGACY_VIEW_STATE_ENTRIES, ViewStateDocument, ViewStateRead,
};
use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT: AtomicU64 = AtomicU64::new(0);
type DecodedSource = (Option<CacheMetadata>, Option<ViewStateDocument>);
#[cfg(feature = "process-fixtures")]
thread_local! { static DEVELOPMENT_PAUSE: Cell<Option<u8>> = const { Cell::new(None) }; }
#[cfg(test)]
thread_local! { static TEST_INTERRUPT: Cell<Option<u8>> = const { Cell::new(None) }; }

#[derive(Clone)]
pub struct LegacyViewStateMigration {
    legacy: HeldDirectory,
    target_cache: HeldDirectory,
    backup: HeldDirectory,
    objects: HeldDirectory,
    records: HeldDirectory,
    pending: HeldDirectory,
    locks: HeldDirectory,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct BackupRecord {
    format_version: u32,
    #[serde(rename = "traceSHA256")]
    trace_sha256: String,
    source: Source,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ImportIntent {
    format_version: u32,
    target_cache_key: TraceCacheKey,
    source_snapshot_identifier: String,
    #[serde(rename = "importedDocumentSHA256")]
    imported_document_sha256: String,
    #[serde(rename = "unmatchedFavoriteTrackIDs")]
    unmatched_favorite_track_ids: Vec<String>,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum CompletionOutcome {
    Imported,
    DestinationKept,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ImportCompletion {
    format_version: u32,
    intent: ImportIntent,
    outcome: CompletionOutcome,
}

fn valid_digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|v| v.is_ascii_digit() || (b'a'..=b'f').contains(&v))
}
fn disjoint(left: &HeldDirectory, right: &HeldDirectory) -> bool {
    !left.path().starts_with(right.path()) && !right.path().starts_with(left.path())
}
fn optional_file(directory: &HeldDirectory, name: &str) -> Result<Option<HeldFile>, HostError> {
    match directory.open_file(name) {
        Ok(file) => Ok(Some(file)),
        Err(HostError::NotFound) => Ok(None),
        Err(error) => Err(error),
    }
}
fn require_readonly_backup(file: &HeldFile) -> Result<(), HostError> {
    file.require_readonly().map_err(|error| {
        if error == HostError::NotPrivate {
            HostError::InvalidEvidence
        } else {
            error
        }
    })
}
fn report(status: Status, sources: Vec<Source>, intent: Option<&ImportIntent>) -> Report {
    Report {
        status,
        sources,
        selected_snapshot_identifier: intent.map(|v| v.source_snapshot_identifier.clone()),
        unmatched_favorite_track_ids: intent
            .map(|v| v.unmatched_favorite_track_ids.clone())
            .unwrap_or_default(),
    }
}

impl LegacyViewStateMigration {
    #[cfg(feature = "process-fixtures")]
    #[doc(hidden)]
    pub fn development_pause_next_import(point: u8) -> Result<(), HostError> {
        if !(1..=2).contains(&point) {
            return Err(HostError::InvalidEvidence);
        }
        DEVELOPMENT_PAUSE.set(Some(point));
        Ok(())
    }

    fn checkpoint(&self, point: u8, io: &IoBudget) -> Result<(), HostError> {
        #[cfg(test)]
        if TEST_INTERRUPT.get() == Some(point) {
            TEST_INTERRUPT.set(None);
            return Err(HostError::DeadlineExceeded);
        }
        #[cfg(feature = "process-fixtures")]
        if DEVELOPMENT_PAUSE.get() == Some(point) {
            let bytes =
                serde_json::to_vec(&serde_json::json!({"point":point,"pid":std::process::id()}))
                    .map_err(|_| HostError::InvalidEvidence)?;
            self.backup.write_new_readonly(
                &format!("development-window-{}.json", std::process::id()),
                &bytes,
                io,
            )?;
            loop {
                std::thread::sleep(Duration::from_millis(5));
            }
        }
        let _ = point;
        io.check()
    }
    /// Product configuration supplies both existing private roots once. No
    /// discovery, caller pathname or new namespace is selected by an import.
    /// Opening this owner creates only backup-owned subdirectories.
    pub fn new(
        legacy: HeldDirectory,
        target_cache: HeldDirectory,
        backup: HeldDirectory,
        io: &IoBudget,
    ) -> Result<Self, HostError> {
        io.check()?;
        legacy.revalidate()?;
        target_cache.revalidate()?;
        backup.revalidate()?;
        if !disjoint(&legacy, &backup)
            || !disjoint(&legacy, &target_cache)
            || !disjoint(&backup, &target_cache)
        {
            return Err(HostError::InvalidPath);
        }
        Ok(Self {
            legacy,
            target_cache,
            objects: backup.ensure_private_child("objects")?,
            records: backup.ensure_private_child("records")?,
            pending: backup.ensure_private_child(".pending")?,
            locks: backup.ensure_private_child(".locks")?,
            backup,
        })
    }

    fn validate_target(&self, directory: &HeldDirectory) -> Result<(), HostError> {
        self.legacy.revalidate()?;
        self.target_cache.revalidate()?;
        self.backup.revalidate()?;
        directory.revalidate()?;
        // The backup must be outside the whole target cache, not just this
        // parser entry: purge and trace-parent removal cannot own it.
        let root = directory
            .path()
            .parent()
            .and_then(|v| v.parent())
            .ok_or(HostError::InvalidPath)?;
        if root != self.target_cache.path() {
            return Err(HostError::InvalidPath);
        }
        for migration_root in [&self.legacy, &self.backup] {
            if root.starts_with(migration_root.path()) || migration_root.path().starts_with(root) {
                return Err(HostError::InvalidPath);
            }
        }
        Ok(())
    }

    fn publish(
        &self,
        directory: &HeldDirectory,
        name: &str,
        bytes: &[u8],
        io: &IoBudget,
    ) -> Result<(), HostError> {
        io.check()?;
        if let Some(existing) = optional_file(directory, name)? {
            require_readonly_backup(&existing)?;
            if existing.read_bounded(io)? != bytes {
                return Err(HostError::InvalidEvidence);
            }
            existing.verify()?;
            directory.sync()?;
            return io.check();
        }
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| HostError::InvalidEvidence)?
            .as_nanos();
        let temporary = format!(
            "pending-{}-{nonce}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        );
        let staged = self.pending.write_new_readonly(&temporary, bytes, io)?;
        match self.pending.promote_noreplace(&staged, directory, name, io) {
            Ok(published) => {
                if published.read_bounded(io)? != bytes {
                    return Err(HostError::Changed);
                }
                published.verify()?;
                directory.sync()?;
                self.backup.sync()?;
                io.check()
            }
            Err(HostError::AlreadyExists) => {
                self.pending
                    .remove_owned_file(&temporary, staged.snapshot().identity)?;
                self.pending.sync()?;
                let existing = directory.open_file(name)?;
                require_readonly_backup(&existing)?;
                if existing.read_bounded(io)? != bytes {
                    return Err(HostError::InvalidEvidence);
                }
                existing.verify()?;
                directory.sync()?;
                io.check()
            }
            Err(error) => Err(error), // unproven pending residue is kept, never swept by age
        }
    }

    fn backup_bytes(&self, bytes: &[u8], io: &IoBudget) -> Result<String, HostError> {
        let digest = model::digest(bytes);
        self.publish(&self.objects, &format!("{digest}.bytes"), bytes, io)?;
        Ok(digest)
    }

    fn scan(&self, target: &CacheMetadata, io: &IoBudget) -> Result<Vec<Candidate>, HostError> {
        let trace = match self.legacy.open_private_child(&target.trace_sha256) {
            Ok(trace) => trace,
            Err(HostError::NotFound) => return Ok(vec![]),
            Err(error) => return Err(error),
        };
        let names = trace.child_names(io, MAXIMUM_LEGACY_VIEW_STATE_ENTRIES)?;
        let mut candidates = Vec::new();
        let mut remaining = MAXIMUM_LEGACY_BACKUP_SCAN_BYTES;
        for name in names {
            io.check()?;
            let Some(parser_key) = name.to_str().filter(|v| valid_digest(v)) else {
                continue;
            };
            let mut source = Source {
                parser_key: parser_key.into(),
                snapshot_identifier: None,
                metadata_sha256: None,
                metadata_byte_count: None,
                sidecar_sha256: None,
                sidecar_byte_count: None,
                source_format_version: None,
                backed_up: false,
                issue: None,
            };
            let result =
                self.read_source(&trace, parser_key, target, &mut source, &mut remaining, io);
            match result {
                Ok(None) => continue,
                Ok(Some((metadata, document))) => candidates.push(Candidate {
                    source,
                    metadata,
                    document,
                }),
                Err(HostError::Cancelled) => return Err(HostError::Cancelled),
                Err(HostError::DeadlineExceeded) => return Err(HostError::DeadlineExceeded),
                Err(HostError::LimitExceeded) => {
                    source.backed_up = false;
                    source.issue = Some(Issue::BackupTooLarge);
                    candidates.push(Candidate {
                        source,
                        metadata: None,
                        document: None,
                    });
                }
                Err(_) => {
                    source.backed_up = false;
                    source.issue = Some(Issue::SourceUnavailable);
                    candidates.push(Candidate {
                        source,
                        metadata: None,
                        document: None,
                    });
                }
            }
        }
        trace.revalidate()?;
        self.legacy.revalidate()?;
        io.check()?;
        Ok(candidates)
    }

    fn read_source(
        &self,
        trace: &HeldDirectory,
        parser_key: &str,
        target: &CacheMetadata,
        source: &mut Source,
        remaining: &mut u64,
        io: &IoBudget,
    ) -> Result<Option<DecodedSource>, HostError> {
        let directory = trace.open_private_child(parser_key)?;
        // Test only existence before locks. Missing sidecars need no lock or
        // backup. The actual read is reopened after both legacy authorities.
        if optional_file(&directory, "view-state.json")?.is_none() {
            return Ok(None);
        }
        let old_locks = self.legacy.open_private_child(".locks")?;
        let old_leases = self.legacy.open_private_child(".leases")?;
        let identifier = model::digest(format!("{}:{parser_key}", target.trace_sha256).as_bytes());
        let key = Lease::acquire_existing_readonly(
            &old_locks,
            &format!("{identifier}.lock"),
            LeaseMode::Exclusive,
            io,
        )?;
        let active = Lease::acquire_existing_readonly(
            &old_leases,
            &format!("{identifier}.lease"),
            LeaseMode::Shared,
            io,
        )?;
        let Some(sidecar) = optional_file(&directory, "view-state.json")? else {
            return Ok(None);
        };
        let metadata = directory.open_file("metadata.json")?;
        source.sidecar_byte_count = Some(sidecar.snapshot().byte_count);
        source.metadata_byte_count = Some(metadata.snapshot().byte_count);
        let bytes = source
            .sidecar_byte_count
            .unwrap()
            .checked_add(source.metadata_byte_count.unwrap())
            .ok_or(HostError::LimitExceeded)?;
        if sidecar.snapshot().byte_count > MAXIMUM_LEGACY_BACKUP_FILE_BYTES
            || metadata.snapshot().byte_count > MAXIMUM_LEGACY_BACKUP_FILE_BYTES
            || bytes > *remaining
        {
            return Err(HostError::LimitExceeded);
        }
        *remaining -= bytes;
        let read_budget = IoBudget {
            maximum_bytes: MAXIMUM_LEGACY_BACKUP_FILE_BYTES.min(io.maximum_bytes),
            ..io.clone()
        };
        let metadata_bytes = metadata.read_bounded(&read_budget)?;
        let sidecar_bytes = sidecar.read_bounded(&read_budget)?;
        source.metadata_sha256 = Some(self.backup_bytes(&metadata_bytes, &read_budget)?);
        source.sidecar_sha256 = Some(self.backup_bytes(&sidecar_bytes, &read_budget)?);
        source.snapshot_identifier = Some(model::snapshot_identifier(
            &target.trace_sha256,
            parser_key,
            source.metadata_sha256.as_deref().unwrap(),
            source.sidecar_sha256.as_deref().unwrap(),
        ));
        #[derive(Deserialize)]
        struct Version {
            #[serde(rename = "formatVersion")]
            format_version: u32,
        }
        source.source_format_version = serde_json::from_slice::<Version>(&sidecar_bytes)
            .ok()
            .map(|v| v.format_version);
        let decoded_metadata = CacheMetadata::decode_legacy_view_state(&metadata_bytes).ok();
        let decoded_metadata = match decoded_metadata {
            None => {
                source.issue = Some(Issue::MetadataPreserved);
                None
            }
            Some(metadata)
                if metadata.trace_sha256 != target.trace_sha256
                    || metadata.source_byte_count != target.source_byte_count
                    || metadata.cache_key.parser_key() != parser_key =>
            {
                source.issue = Some(Issue::IdentityMismatch);
                None
            }
            Some(metadata) => Some(metadata),
        };
        let document = match ViewStateDocument::decode(&sidecar_bytes, &target.trace_sha256) {
            ViewStateRead::Restored(document) => Some(document),
            _ => {
                source.issue.get_or_insert(Issue::SidecarPreserved);
                None
            }
        };
        // Legacy writers replace sidecars atomically but do not necessarily
        // take the cache key lock. Check exact held name/mtime/ctime again.
        metadata.verify()?;
        sidecar.verify()?;
        directory.revalidate()?;
        key.revalidate()?;
        active.revalidate()?;
        io.check()?;
        source.backed_up = true;
        let record = BackupRecord {
            format_version: 1,
            trace_sha256: target.trace_sha256.clone(),
            source: source.clone(),
        };
        let bytes = serde_json::to_vec(&record).map_err(|_| HostError::InvalidEvidence)?;
        self.publish(
            &self.records,
            &format!(
                "{}.source.json",
                source.snapshot_identifier.as_deref().unwrap()
            ),
            &bytes,
            io,
        )?;
        Ok(Some((decoded_metadata, document)))
    }

    fn validate_intent(
        &self,
        intent: &ImportIntent,
        target: &CacheMetadata,
        io: &IoBudget,
    ) -> Result<Candidate, HostError> {
        if intent.format_version != 1
            || intent.target_cache_key != target.cache_key
            || !valid_digest(&intent.source_snapshot_identifier)
            || !valid_digest(&intent.imported_document_sha256)
        {
            return Err(HostError::InvalidEvidence);
        }
        let record_file = self.records.open_file(&format!(
            "{}.source.json",
            intent.source_snapshot_identifier
        ))?;
        require_readonly_backup(&record_file)?;
        let record: BackupRecord =
            serde_json::from_slice(&record_file.read_bounded(&IoBudget {
                maximum_bytes: 16_384,
                ..io.clone()
            })?)
            .map_err(|_| HostError::InvalidEvidence)?;
        let source = &record.source;
        let metadata_digest = source
            .metadata_sha256
            .as_deref()
            .filter(|v| valid_digest(v))
            .ok_or(HostError::InvalidEvidence)?;
        let sidecar_digest = source
            .sidecar_sha256
            .as_deref()
            .filter(|v| valid_digest(v))
            .ok_or(HostError::InvalidEvidence)?;
        if record.format_version != 1
            || record.trace_sha256 != target.trace_sha256
            || !source.backed_up
            || source.issue.is_some()
            || !valid_digest(&source.parser_key)
            || source.snapshot_identifier.as_deref()
                != Some(intent.source_snapshot_identifier.as_str())
            || model::snapshot_identifier(
                &record.trace_sha256,
                &source.parser_key,
                metadata_digest,
                sidecar_digest,
            ) != intent.source_snapshot_identifier
        {
            return Err(HostError::InvalidEvidence);
        }
        let metadata_file = self
            .objects
            .open_file(&format!("{metadata_digest}.bytes"))?;
        let sidecar_file = self.objects.open_file(&format!("{sidecar_digest}.bytes"))?;
        require_readonly_backup(&metadata_file)?;
        require_readonly_backup(&sidecar_file)?;
        if Some(metadata_file.snapshot().byte_count) != source.metadata_byte_count
            || Some(sidecar_file.snapshot().byte_count) != source.sidecar_byte_count
        {
            return Err(HostError::InvalidEvidence);
        }
        let metadata_bytes = metadata_file.read_bounded(io)?;
        let sidecar_bytes = sidecar_file.read_bounded(io)?;
        if model::digest(&metadata_bytes) != metadata_digest
            || model::digest(&sidecar_bytes) != sidecar_digest
        {
            return Err(HostError::InvalidEvidence);
        }
        let metadata = CacheMetadata::decode_legacy_view_state(&metadata_bytes)
            .map_err(|_| HostError::InvalidEvidence)?;
        let ViewStateRead::Restored(document) =
            ViewStateDocument::decode(&sidecar_bytes, &target.trace_sha256)
        else {
            return Err(HostError::InvalidEvidence);
        };
        if metadata.trace_sha256 != target.trace_sha256
            || metadata.source_byte_count != target.source_byte_count
            || metadata.cache_key.parser_key() != source.parser_key
        {
            return Err(HostError::InvalidEvidence);
        }
        let candidate = Candidate {
            source: source.clone(),
            metadata: Some(metadata),
            document: Some(document),
        };
        let (document, unmatched) = model::import_document(&candidate, target);
        if model::digest(
            &document
                .encode(&target.trace_sha256)
                .map_err(|_| HostError::InvalidEvidence)?,
        ) != intent.imported_document_sha256
            || unmatched != intent.unmatched_favorite_track_ids
        {
            return Err(HostError::InvalidEvidence);
        }
        metadata_file.verify()?;
        sidecar_file.verify()?;
        record_file.verify()?;
        self.backup.revalidate()?;
        io.check()?;
        Ok(candidate)
    }

    fn apply(
        &self,
        destination: Destination<'_>,
        selected: Option<&str>,
        io: &IoBudget,
    ) -> Result<Report, HostError> {
        let Destination {
            directory,
            locks,
            lease,
            sidecars,
            target,
        } = destination;
        self.validate_target(directory)?;
        let migration_lock = Lease::acquire(
            &self.locks,
            &format!("{}.lock", target.trace_sha256),
            LeaseMode::Exclusive,
            io,
        )?;
        let identifier = target.cache_key.entry_identifier();
        let completion_name = format!("{identifier}.completed.json");
        let intent_name = format!("{identifier}.intent.json");
        if let Some(file) = optional_file(&self.records, &completion_name)? {
            require_readonly_backup(&file)?;
            let completed: ImportCompletion = serde_json::from_slice(&file.read_bounded(io)?)
                .map_err(|_| HostError::InvalidEvidence)?;
            if completed.format_version != 1 {
                return Err(HostError::InvalidEvidence);
            }
            self.validate_intent(&completed.intent, target, io)?;
            file.verify()?;
            migration_lock.revalidate()?;
            lease.revalidate()?;
            return Ok(report(
                Status::AlreadyCompleted,
                vec![],
                Some(&completed.intent),
            ));
        }
        let (sources, intent, bytes) =
            if let Some(file) = optional_file(&self.records, &intent_name)? {
                require_readonly_backup(&file)?;
                let intent: ImportIntent = serde_json::from_slice(&file.read_bounded(io)?)
                    .map_err(|_| HostError::InvalidEvidence)?;
                self.validate_intent(&intent, target, io)?;
                file.verify()?;
                // Resume exclusively from the durable, pinned source backup. A
                // changed or evicted legacy entry does not change this intent.
                (vec![], intent, None)
            } else {
                let candidates = self.scan(target, io)?;
                let sources: Vec<_> = candidates.iter().map(|v| v.source.clone()).collect();
                let index = match model::decide(&candidates, target, selected) {
                    Decision::Stop(status) => {
                        migration_lock.revalidate()?;
                        return Ok(report(status, sources, None));
                    }
                    Decision::Import(index) => index,
                };
                let (document, unmatched) = model::import_document(&candidates[index], target);
                let bytes = document
                    .encode(&target.trace_sha256)
                    .map_err(|_| HostError::InvalidEvidence)?;
                let intent = ImportIntent {
                    format_version: 1,
                    target_cache_key: target.cache_key.clone(),
                    source_snapshot_identifier: candidates[index]
                        .source
                        .snapshot_identifier
                        .clone()
                        .ok_or(HostError::InvalidEvidence)?,
                    imported_document_sha256: model::digest(&bytes),
                    unmatched_favorite_track_ids: unmatched,
                };
                (sources, intent, Some(bytes))
            };
        if selected.is_some_and(|selected| selected != intent.source_snapshot_identifier) {
            return Ok(report(Status::InvalidSelection, sources, Some(&intent)));
        }
        let key = Lease::acquire(
            locks,
            &format!("{identifier}.lock"),
            LeaseMode::Exclusive,
            io,
        )?;
        let recovered = sidecars.recover(directory, &key, lease, io)?;
        if matches!(
            recovered,
            SidecarRecovery::Preserved | SidecarRecovery::Active
        ) {
            return Ok(report(Status::PreservedDestination, sources, Some(&intent)));
        }
        let existing = super::view_state::read_directory(directory, &target.trace_sha256, io)?;
        let outcome = match existing {
            ViewStateRead::Preserved => {
                return Ok(report(Status::PreservedDestination, sources, Some(&intent)));
            }
            ViewStateRead::Restored(document) => {
                if bytes.is_none()
                    && model::digest(
                        &document
                            .encode(&target.trace_sha256)
                            .map_err(|_| HostError::InvalidEvidence)?,
                    ) == intent.imported_document_sha256
                {
                    CompletionOutcome::Imported // committed before process death
                } else {
                    CompletionOutcome::DestinationKept
                }
            }
            ViewStateRead::Missing => {
                let input = match bytes {
                    Some(bytes) => bytes,
                    None => self.materialize_intent(&intent, target, io)?,
                };
                let record = serde_json::to_vec(&intent).map_err(|_| HostError::InvalidEvidence)?;
                self.publish(&self.records, &intent_name, &record, io)?;
                self.checkpoint(1, io)?;
                sidecars.write(directory, &key, lease, Some(&input), io)?;
                self.checkpoint(2, io)?;
                CompletionOutcome::Imported
            }
            ViewStateRead::SessionScoped => return Err(HostError::InvalidEvidence),
        };
        key.revalidate()?;
        lease.revalidate()?;
        migration_lock.revalidate()?;
        self.validate_target(directory)?;
        io.check()?;
        let completed = ImportCompletion {
            format_version: 1,
            intent,
            outcome,
        };
        self.publish(
            &self.records,
            &completion_name,
            &serde_json::to_vec(&completed).map_err(|_| HostError::InvalidEvidence)?,
            io,
        )?;
        Ok(report(
            if outcome == CompletionOutcome::Imported {
                Status::Imported
            } else {
                Status::DestinationKept
            },
            sources,
            Some(&completed.intent),
        ))
    }

    fn materialize_intent(
        &self,
        intent: &ImportIntent,
        target: &CacheMetadata,
        io: &IoBudget,
    ) -> Result<Vec<u8>, HostError> {
        let candidate = self.validate_intent(intent, target, io)?;
        let (document, _) = model::import_document(&candidate, target);
        document
            .encode(&target.trace_sha256)
            .map_err(|_| HostError::InvalidEvidence)
    }
}

struct Destination<'a> {
    directory: &'a HeldDirectory,
    locks: &'a HeldDirectory,
    lease: &'a Lease,
    sidecars: &'a SidecarStore,
    target: &'a CacheMetadata,
}

impl EngineSession {
    /// Worker-only Ready import. UI code receives closed reports; it cannot
    /// select old paths or use this reader as an alternative engine.
    pub fn migrate_legacy_view_state(
        &self,
        migration: &LegacyViewStateMigration,
        selected_snapshot_identifier: Option<&str>,
        budget: &EngineBudget,
    ) -> Result<Report, EngineError> {
        self.query_reader(budget)?;
        let SessionStorage::Cached {
            directory,
            locks,
            lease,
            sidecars,
        } = &self.storage
        else {
            return Ok(report(Status::SessionScoped, vec![], None));
        };
        let io = budget.io(MAXIMUM_LEGACY_BACKUP_FILE_BYTES);
        let result = migration
            .apply(
                Destination {
                    directory,
                    locks,
                    lease,
                    sidecars,
                    target: &self.metadata,
                },
                selected_snapshot_identifier,
                &io,
            )
            .map_err(|error| host(EngineStage::Querying, error));
        self.query_reader(budget)?;
        result
    }
}

#[cfg(test)]
mod tests;
