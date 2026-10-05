//! Fixed user-sidecar transactions in a cache-root-owned namespace. Generic
//! format-2 owner proof binds scratch directories before payload creation.
//! One immutable intent precedes mutation; no temporary Ready member appears.
use super::super::FileSnapshot;
use super::*;

const FILE: &str = "view-state.json";
const PAYLOAD: &str = "payload";
const MAXIMUM_INTENTS: usize = 4096;
#[cfg(feature = "process-fixtures")]
thread_local! { static PAUSE_SIDECAR: std::cell::Cell<Option<u8>> = const { std::cell::Cell::new(None) }; }
#[cfg(feature = "process-fixtures")]
pub(super) fn fixture_pause(point: u8) {
    PAUSE_SIDECAR.set(Some(point));
}
fn sidecar_window(store: &SidecarStore, point: u8) -> Result<(), HostError> {
    #[cfg(feature = "process-fixtures")]
    if PAUSE_SIDECAR.get() == Some(point) {
        let bytes =
            serde_json::to_vec(&serde_json::json!({"point": point, "pid": std::process::id()}))
                .map_err(|_| HostError::InvalidEvidence)?;
        let temporary = store.cache.path().join("sidecar-window.tmp");
        std::fs::write(&temporary, bytes)
            .map_err(|e| super::super::from_io(e, HostOperation::Write))?;
        std::fs::rename(temporary, store.cache.path().join("sidecar-window.json"))
            .map_err(|e| super::super::from_io(e, HostOperation::Rename))?;
        loop {
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    let _ = (store, point);
    Ok(())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SidecarRecovery {
    Absent,
    Aborted,
    Committed,
    Preserved,
    Active,
}

#[derive(Clone)]
pub struct SidecarStore {
    cache: HeldDirectory,
    root: HeldDirectory,
    owners: OwnerStore,
    maximum_bytes: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct KnownFile {
    snapshot: FileSnapshot,
    sha256: String,
}
impl KnownFile {
    fn bind(file: &HeldFile, io: &IoBudget) -> Result<Self, HostError> {
        Ok(Self {
            snapshot: file.snapshot(),
            sha256: file.facts(io)?.sha256,
        })
    }
    fn matches(&self, file: &HeldFile, io: &IoBudget) -> Result<bool, HostError> {
        let actual = file.snapshot();
        let mut expected = self.snapshot;
        // Only ctime may change through the journaled atomic rename.
        expected.change = actual.change;
        Ok(actual == expected && file.facts(io)?.sha256 == self.sha256)
    }
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Intent {
    format_version: u32,
    cache: FileIdentity,
    journal_root: FileIdentity,
    entry: FileIdentity,
    entry_relative_path: String,
    key_identifier: String,
    entry_lease: FileIdentity,
    owner_identifier: String,
    owner_directory: FileIdentity,
    previous: Option<KnownFile>,
    candidate: Option<KnownFile>,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum Disposition {
    Aborted,
    Committed,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Finish {
    format_version: u32,
    intent: Intent,
    record: KnownFile,
    disposition: Disposition,
}
impl Finish {
    fn outcome(&self) -> SidecarRecovery {
        match self.disposition {
            Disposition::Aborted => SidecarRecovery::Aborted,
            Disposition::Committed => SidecarRecovery::Committed,
        }
    }
}
fn expected_matches(
    expected: &Option<KnownFile>,
    actual: &Option<HeldFile>,
    io: &IoBudget,
) -> Result<bool, HostError> {
    match (expected, actual) {
        (None, None) => Ok(true),
        (Some(e), Some(f)) => e.matches(f, io),
        _ => Ok(false),
    }
}
fn journal_file(
    parent: &HeldDirectory,
    live: &str,
    retired: &str,
) -> Result<Option<HeldFile>, HostError> {
    match (
        optional_file(parent, live)?,
        optional_file(parent, retired)?,
    ) {
        (Some(_), Some(_)) => Err(HostError::InvalidEvidence),
        (Some(f), None) | (None, Some(f)) => Ok(Some(f)),
        (None, None) => Ok(None),
    }
}
fn retire_record(
    parent: &HeldDirectory,
    file: &HeldFile,
    retired: &str,
    io: &IoBudget,
) -> Result<(), HostError> {
    io.check()?;
    parent.revalidate()?;
    file.verify()?;
    let target = component(OsStr::new(retired))?;
    let current = if file.name != target {
        rename(parent, &file.name, &target, libc::RENAME_EXCL)?;
        let moved = parent.open_file(retired)?;
        if moved.snapshot().identity != file.snapshot().identity {
            rename(parent, &target, &file.name, libc::RENAME_EXCL)
                .map_err(|_| HostError::CleanupFailed)?;
            return Err(HostError::IdentityMismatch);
        }
        parent.sync()?;
        moved
    } else {
        parent.open_file(retired)?
    };
    current.verify()?;
    io.check()?;
    // SAFETY: exact regular journal document, held private parent, fixed
    // tombstone name under the journal EX lease. A crash after the rename
    // leaves a recognized identity/digest checked record for next recovery.
    if unsafe { libc::unlinkat(parent.0.file.as_raw_fd(), target.as_ptr(), 0) } != 0 {
        return Err(os_error(HostOperation::Remove));
    }
    parent.sync()
}
fn optional_file(parent: &HeldDirectory, name: &str) -> Result<Option<HeldFile>, HostError> {
    match parent.open_file(name) {
        Ok(v) => Ok(Some(v)),
        Err(HostError::NotFound) => Ok(None),
        Err(e) => Err(e),
    }
}

impl SidecarStore {
    /// The cache root is fixed by the Engine, never by a user request. Source
    /// and journal parents remain held throughout every operation.
    pub fn open(
        cache: &HeldDirectory,
        maximum_bytes: u64,
        io: &IoBudget,
    ) -> Result<Self, HostError> {
        if maximum_bytes == 0 || maximum_bytes > 16 * 1024 * 1024 {
            return Err(HostError::InvalidLimit);
        }
        io.check()?;
        cache.revalidate()?;
        let root = cache.ensure_private_child(".view-state")?;
        let stage = root.ensure_private_child(".staging")?;
        let owners = OwnerStore::open(&stage, &root)?;
        Ok(Self {
            cache: cache.clone(),
            root,
            owners,
            maximum_bytes,
        })
    }
    pub fn revalidate(&self) -> Result<(), HostError> {
        self.cache.revalidate()?;
        self.root.revalidate()?;
        self.owners.parent.revalidate()?;
        self.owners.owners.revalidate()
    }
    fn io(&self, io: &IoBudget) -> IoBudget {
        IoBudget {
            maximum_bytes: self.maximum_bytes,
            ..io.clone()
        }
    }
    fn authority(
        &self,
        entry: &HeldDirectory,
        key: &Lease,
        active: &Lease,
    ) -> Result<(String, String), HostError> {
        self.cache.revalidate()?;
        self.root.revalidate()?;
        entry.revalidate()?;
        key.revalidate()?;
        active.revalidate()?;
        let path = relative(&self.cache, entry)?;
        let parts = path.split('/').collect::<Vec<_>>();
        if parts.len() != 2 || !parts.iter().all(|v| digest_name(v)) {
            return Err(HostError::InvalidEvidence);
        }
        let identifier = format!(
            "{:x}",
            Sha256::digest(format!("{}:{}", parts[0], parts[1]).as_bytes())
        );
        if key.mode != LeaseMode::Exclusive
            || key.parent.identity() != self.cache.open_private_child(".locks")?.identity()
            || active.parent.identity() != self.cache.open_private_child(".leases")?.identity()
            || key.name.as_bytes() != format!("{identifier}.lock").as_bytes()
            || active.name.as_bytes() != format!("{identifier}.lease").as_bytes()
        {
            return Err(HostError::InvalidEvidence);
        }
        Ok((path, identifier))
    }
    fn valid(
        &self,
        intent: &Intent,
        entry: &HeldDirectory,
        key: &Lease,
        active: &Lease,
    ) -> Result<bool, HostError> {
        let (path, identifier) = self.authority(entry, key, active)?;
        Ok(intent.format_version == 1
            && intent.cache == self.cache.identity()
            && intent.journal_root == self.root.identity()
            && intent.entry == entry.identity()
            && intent.entry_relative_path == path
            && intent.key_identifier == identifier
            && intent.entry_lease == active.identity
            && owner_name(&intent.owner_identifier).is_ok()
            && intent.owner_directory.device == self.root.identity().device
            && intent.owner_directory.inode != 0
            && (intent.previous.is_some() || intent.candidate.is_some())
            && intent
                .previous
                .iter()
                .chain(intent.candidate.iter())
                .all(|v| {
                    v.snapshot.byte_count <= self.maximum_bytes
                        && v.snapshot.identity.device == entry.identity().device
                        && v.snapshot.identity.inode != 0
                        && digest_name(&v.sha256)
                }))
    }
    fn intent(
        &self,
        identifier: &str,
        io: &IoBudget,
    ) -> Result<Option<(HeldFile, Intent)>, HostError> {
        let Some(file) = journal_file(
            &self.root,
            &format!("{identifier}.json"),
            &format!("{identifier}.intent-remove.json"),
        )?
        else {
            return Ok(None);
        };
        let bytes = file.read_bounded(&record_budget(io))?;
        let value = serde_json::from_slice(&bytes).map_err(|_| HostError::InvalidEvidence)?;
        file.verify()?;
        Ok(Some((file, value)))
    }
    fn finish(
        &self,
        identifier: &str,
        io: &IoBudget,
    ) -> Result<Option<(HeldFile, Finish)>, HostError> {
        let Some(file) = journal_file(
            &self.root,
            &format!("{identifier}.finish.json"),
            &format!("{identifier}.finish-remove.json"),
        )?
        else {
            return Ok(None);
        };
        let bytes = file.read_bounded(&record_budget(io))?;
        let value: Finish =
            serde_json::from_slice(&bytes).map_err(|_| HostError::InvalidEvidence)?;
        file.verify()?;
        if value.format_version != 1 {
            return Err(HostError::InvalidEvidence);
        }
        Ok(Some((file, value)))
    }
    fn locate_intent_owner(
        &self,
        intent: &Intent,
        io: &IoBudget,
    ) -> Result<Option<HeldDirectory>, HostError> {
        self.owners.locate(
            &Evidence {
                format_version: 2,
                state: State::Session,
                device: Some(intent.owner_directory.device),
                inode: Some(intent.owner_directory.inode),
                relative_path: format!(".staging/{}", intent.owner_identifier),
                ephemeral: None,
                cache: None,
            },
            io,
        )
    }
    fn disposition(
        &self,
        intent: &Intent,
        present: &Option<HeldFile>,
        io: &IoBudget,
    ) -> Result<Option<Disposition>, HostError> {
        if expected_matches(&intent.candidate, present, io)? {
            Ok(Some(Disposition::Committed))
        } else if expected_matches(&intent.previous, present, io)? {
            Ok(Some(Disposition::Aborted))
        } else {
            Ok(None)
        }
    }
    fn finish_records(
        &self,
        identifier: &str,
        record: Option<&HeldFile>,
        finish: &HeldFile,
        io: &IoBudget,
    ) -> Result<(), HostError> {
        io.check()?;
        self.root.revalidate()?;
        if let Some(record) = record {
            retire_record(
                &self.root,
                record,
                &format!("{identifier}.intent-remove.json"),
                io,
            )?;
        }
        // Completion proof outlives the intent and every owner artifact.
        retire_record(
            &self.root,
            finish,
            &format!("{identifier}.finish-remove.json"),
            io,
        )
    }
    /// Under key EX and the same entry lease, determine the result from exact
    /// file snapshots, then persist that result before any scratch destruction.
    /// A completion receipt permits restart after payload/rmdir/ledger removal;
    /// unknown versions, replacements and unexpected members are preserved.
    pub fn recover(
        &self,
        entry: &HeldDirectory,
        key: &Lease,
        active: &Lease,
        io: &IoBudget,
    ) -> Result<SidecarRecovery, HostError> {
        self.authority(entry, key, active)?;
        let _journal = Lease::acquire(&self.root, "journal.lock", LeaseMode::Exclusive, io)?;
        self.recover_observed(entry, key, active, io, |p| sidecar_window(self, p))
    }
    fn recover_observed(
        &self,
        entry: &HeldDirectory,
        key: &Lease,
        active: &Lease,
        io: &IoBudget,
        mut observe: impl FnMut(u8) -> Result<(), HostError>,
    ) -> Result<SidecarRecovery, HostError> {
        let (_, identifier) = self.authority(entry, key, active)?;
        let io = self.io(io);
        io.check()?;
        let intent_record = match self.intent(&identifier, &io) {
            Ok(v) => v,
            Err(HostError::InvalidEvidence | HostError::LimitExceeded) => {
                return Ok(SidecarRecovery::Preserved);
            }
            Err(e) => return Err(e),
        };
        let completion = match self.finish(&identifier, &io) {
            Ok(v) => v,
            Err(HostError::InvalidEvidence | HostError::LimitExceeded) => {
                return Ok(SidecarRecovery::Preserved);
            }
            Err(e) => return Err(e),
        };
        let intent = match (&intent_record, &completion) {
            (Some((_, intent)), _) => intent.clone(),
            (None, Some((_, finish))) => finish.intent.clone(),
            (None, None) => return Ok(SidecarRecovery::Absent),
        };
        if !self.valid(&intent, entry, key, active)? {
            return Ok(SidecarRecovery::Preserved);
        }
        let present = optional_file(entry, FILE)?;
        let Some(disposition) = self.disposition(&intent, &present, &io)? else {
            return Ok(SidecarRecovery::Preserved);
        };
        if let Some((_, finish)) = &completion {
            if finish.intent != intent
                || finish.disposition != disposition
                || intent_record
                    .as_ref()
                    .is_some_and(|(_, i)| i != &finish.intent)
            {
                return Ok(SidecarRecovery::Preserved);
            }
            if let Some((record, _)) = &intent_record
                && !finish.record.matches(record, &record_budget(&io))?
            {
                return Ok(SidecarRecovery::Preserved);
            }
        }
        let owner_lease = match Lease::try_acquire(
            &self.owners.owners,
            &format!("{}.lock", intent.owner_identifier),
            LeaseMode::Exclusive,
            false,
        ) {
            Ok(Some(v)) => Some(v),
            Ok(None) => return Ok(SidecarRecovery::Active),
            Err(HostError::NotFound) => None,
            Err(e) => return Err(e),
        };
        let owner = match self.owners.read(&intent.owner_identifier, &io) {
            Ok(v) => v,
            Err(HostError::InvalidEvidence | HostError::LimitExceeded) => {
                return Ok(SidecarRecovery::Preserved);
            }
            Err(e) => return Err(e),
        };
        if let Some((record, evidence)) = &owner {
            record.verify()?;
            if evidence.format_version != 2
                || evidence.identity() != Some(intent.owner_directory)
                || evidence.cache.is_some()
                || evidence.ephemeral.is_some()
                || !matches!(
                    evidence.state,
                    State::Session | State::Removing | State::Removed
                )
                || owner_lease.is_none()
            {
                return Ok(SidecarRecovery::Preserved);
            }
        }
        let directory = match &owner {
            Some((_, e)) => self.owners.locate(e, &io)?,
            None => self.locate_intent_owner(&intent, &io)?,
        };
        let discarded = match disposition {
            Disposition::Committed => &intent.previous,
            Disposition::Aborted => &intent.candidate,
        };
        if let Some(d) = &directory {
            if owner
                .as_ref()
                .is_some_and(|(_, e)| e.state == State::Removed)
            {
                return Ok(SidecarRecovery::Preserved);
            }
            if owner.is_none() {
                return Ok(SidecarRecovery::Preserved);
            }
            let names = d.child_names(&io, 1)?;
            if let Some(name) = names.first() {
                let removing = completion.is_some()
                    && owner
                        .as_ref()
                        .is_some_and(|(_, e)| e.state == State::Removing);
                let tombstone = name.to_str().is_some_and(|n| {
                    n.strip_prefix(".arktrace-child-remove-")
                        .is_some_and(|v| owner_name(&format!("session-{v}")).is_ok())
                });
                if name != OsStr::new(PAYLOAD) && !(removing && tombstone) {
                    return Ok(SidecarRecovery::Preserved);
                }
                let f = d.open_file(name.to_str().ok_or(HostError::InvalidEvidence)?)?;
                if !expected_matches(discarded, &Some(f), &io)? {
                    return Ok(SidecarRecovery::Preserved);
                }
            } else if discarded.is_some()
                && !(completion.is_some()
                    && owner
                        .as_ref()
                        .is_some_and(|(_, e)| matches!(e.state, State::Removing | State::Removed)))
            {
                return Ok(SidecarRecovery::Preserved);
            }
        } else if completion.is_none()
            || owner
                .as_ref()
                .is_some_and(|(_, e)| e.state == State::Session)
        {
            return Ok(SidecarRecovery::Preserved);
        }
        let (finish_file, finish) = match completion {
            Some(v) => v,
            None => {
                let (record, _) = intent_record.as_ref().ok_or(HostError::InvalidEvidence)?;
                let finish = Finish {
                    format_version: 1,
                    intent: intent.clone(),
                    record: KnownFile::bind(record, &record_budget(&io))?,
                    disposition,
                };
                let bytes = serde_json::to_vec(&finish).map_err(|_| HostError::InvalidEvidence)?;
                let file = self.root.write_new_readonly(
                    &format!("{identifier}.finish.json"),
                    &bytes,
                    &record_budget(&io),
                )?;
                (file, finish)
            }
        };
        observe(3)?;
        self.authority(entry, key, active)?;
        finish_file.verify()?;
        if let Some(directory) = directory {
            let mut owned = OwnedDirectory {
                store: self.owners.clone(),
                identifier: intent.owner_identifier.clone(),
                directory,
                lease: owner_lease.ok_or(HostError::InvalidEvidence)?,
                removed: false,
            };
            owned.cleanup(&io)?;
        } else if let Some(lease) = owner_lease {
            if let Some((record, mut evidence)) = owner {
                // The durable completion and Removing state were recorded before
                // disposal. A complete bounded identity scan proves no owned
                // directory remains; no absent path or foreign object is removed.
                if evidence.state == State::Removing {
                    evidence.state = State::Removed;
                    self.owners.write(
                        &intent.owner_identifier,
                        &lease,
                        &evidence,
                        Some(&record),
                        &io,
                    )?;
                } else if evidence.state != State::Removed {
                    return Ok(SidecarRecovery::Preserved);
                }
                self.owners
                    .remove_artifacts(&intent.owner_identifier, &lease, &io)?;
            } else {
                self.owners
                    .owners
                    .remove_owned_component(&lease.name, lease.identity)?;
                self.owners.owners.sync()?;
            }
        } else if owner.is_some() {
            return Ok(SidecarRecovery::Preserved);
        }
        observe(4)?;
        self.authority(entry, key, active)?;
        self.finish_records(
            &identifier,
            intent_record.as_ref().map(|(f, _)| f),
            &finish_file,
            &io,
        )?;
        Ok(finish.outcome())
    }
    /// Collect abandoned candidates only after a complete bounded journal
    /// scan. Any unsupported record or unknown root member keeps all orphans;
    /// referenced owners are recovered only through their entry's key/lease.
    pub fn recover_orphans(&self, io: &IoBudget) -> Result<usize, HostError> {
        let _journal = Lease::acquire(&self.root, "journal.lock", LeaseMode::Exclusive, io)?;
        self.recover_orphans_locked(io)
    }
    fn recover_orphans_locked(&self, io: &IoBudget) -> Result<usize, HostError> {
        let io = self.io(io);
        io.check()?;
        self.cache.revalidate()?;
        self.root.revalidate()?;
        let mut referenced = std::collections::BTreeSet::new();
        for name in self.root.child_names(&io, MAXIMUM_INTENTS * 4 + 2)? {
            if name == OsStr::new(".staging") || name == OsStr::new("journal.lock") {
                continue;
            }
            let Some(text) = name.to_str() else {
                return Ok(0);
            };
            let parsed = if let Some(key) = text
                .strip_suffix(".finish.json")
                .or_else(|| text.strip_suffix(".finish-remove.json"))
            {
                if !digest_name(key) {
                    return Ok(0);
                }
                self.finish(key, &io).map(|v| v.map(|(_, f)| f.intent))
            } else if let Some(key) = text
                .strip_suffix(".intent-remove.json")
                .or_else(|| text.strip_suffix(".json"))
            {
                if !digest_name(key) {
                    return Ok(0);
                }
                self.intent(key, &io).map(|v| v.map(|(_, i)| i))
            } else {
                return Ok(0);
            };
            let intent = match parsed {
                Ok(Some(i)) => i,
                Ok(None) | Err(HostError::InvalidEvidence | HostError::LimitExceeded) => {
                    return Ok(0);
                }
                Err(e) => return Err(e),
            };
            let parts = intent.entry_relative_path.split('/').collect::<Vec<_>>();
            if intent.format_version != 1
                || intent.cache != self.cache.identity()
                || intent.journal_root != self.root.identity()
                || parts.len() != 2
                || !parts.iter().all(|v| digest_name(v))
                || owner_name(&intent.owner_identifier).is_err()
                || intent.key_identifier
                    != format!(
                        "{:x}",
                        Sha256::digest(intent.entry_relative_path.replace('/', ":"))
                    )
            {
                return Ok(0);
            }
            referenced.insert(intent.owner_identifier);
        }
        let mut removed = 0;
        for identifier in self.owners.identifiers(&io)? {
            if referenced.contains(&identifier) {
                continue;
            }
            let evidence = match self.owners.read(&identifier, &io) {
                Ok(Some((_, e))) => e,
                Ok(None) => continue,
                Err(HostError::InvalidEvidence | HostError::LimitExceeded) => continue,
                Err(e) => return Err(e),
            };
            if evidence.format_version != 2
                || evidence.cache.is_some()
                || evidence.ephemeral.is_some()
            {
                continue;
            }
            if self.owners.recover_stale(&identifier, &io)? == OwnerRecoveryOutcome::Removed {
                removed += 1;
            }
        }
        Ok(removed)
    }
    /// Save or remove exactly one sidecar. The domain caller validates format,
    /// trace identity and unsupported-source preservation before submitting.
    pub fn write(
        &self,
        entry: &HeldDirectory,
        key: &Lease,
        active: &Lease,
        bytes: Option<&[u8]>,
        io: &IoBudget,
    ) -> Result<(), HostError> {
        self.write_observed(entry, key, active, bytes, io, |p| sidecar_window(self, p))
    }
    fn write_observed(
        &self,
        entry: &HeldDirectory,
        key: &Lease,
        active: &Lease,
        bytes: Option<&[u8]>,
        io: &IoBudget,
        mut observe: impl FnMut(u8) -> Result<(), HostError>,
    ) -> Result<(), HostError> {
        let (path, identifier) = self.authority(entry, key, active)?;
        let io = self.io(io);
        io.check()?;
        if bytes.is_some_and(|v| v.len() as u64 > self.maximum_bytes) {
            return Err(HostError::LimitExceeded);
        }
        let _journal = Lease::acquire(&self.root, "journal.lock", LeaseMode::Exclusive, &io)?;
        self.recover_orphans_locked(&io)?;
        match self.recover_observed(entry, key, active, &io, |_| Ok(()))? {
            SidecarRecovery::Absent | SidecarRecovery::Aborted | SidecarRecovery::Committed => (),
            _ => return Err(HostError::InvalidEvidence),
        }
        let previous = optional_file(entry, FILE)?;
        if previous.is_none() && bytes.is_none() {
            return Ok(());
        }
        let old = previous
            .as_ref()
            .map(|f| KnownFile::bind(f, &io))
            .transpose()?;
        let mut owner = self.owners.create(OwnerKind::Session, &io)?;
        let candidate = bytes
            .map(|v| owner.directory.write_new_readonly(PAYLOAD, v, &io))
            .transpose();
        let candidate = match candidate {
            Ok(v) => v,
            Err(e) => {
                owner.cleanup(&cleanup(&io))?;
                return Err(e);
            }
        };
        observe(0)?;
        let intent = Intent {
            format_version: 1,
            cache: self.cache.identity(),
            journal_root: self.root.identity(),
            entry: entry.identity(),
            entry_relative_path: path,
            key_identifier: identifier.clone(),
            entry_lease: active.identity,
            owner_identifier: owner.identifier.clone(),
            owner_directory: owner.directory.identity(),
            previous: old,
            candidate: candidate
                .as_ref()
                .map(|f| KnownFile::bind(f, &io))
                .transpose()?,
        };
        let intent_bytes = serde_json::to_vec(&intent).map_err(|_| HostError::InvalidEvidence)?;
        if intent_bytes.len() as u64 > RECORD_LIMIT {
            owner.cleanup(&cleanup(&io))?;
            return Err(HostError::LimitExceeded);
        }
        let record = match self.root.write_new_readonly(
            &format!("{identifier}.json"),
            &intent_bytes,
            &record_budget(&io),
        ) {
            Ok(v) => v,
            Err(e) => {
                owner.cleanup(&cleanup(&io))?;
                return Err(e);
            }
        };
        let result = (|| {
            observe(1)?;
            self.authority(entry, key, active)?;
            record.verify()?;
            match (&candidate, &previous) {
                (Some(new), Some(old)) => {
                    owner.directory.exchange_private_document(new, old, &io)?;
                }
                (Some(new), None) => {
                    owner
                        .directory
                        .move_private_document(new, entry, FILE, &io)?;
                }
                (None, Some(old)) => {
                    entry.move_private_document(old, &owner.directory, PAYLOAD, &io)?;
                }
                (None, None) => return Err(HostError::InvalidEvidence),
            }
            observe(2)?;
            Ok(())
        })();
        drop(owner); // recovery acquires the exact owner's EX marker
        // Once intent is durable, cleanup is independent of caller cancel.
        let recovered = self.recover_observed(entry, key, active, &cleanup(&io), &mut observe)?;
        if !matches!(
            recovered,
            SidecarRecovery::Committed | SidecarRecovery::Aborted
        ) {
            return Err(HostError::CleanupFailed);
        }
        result?;
        io.check()?;
        Ok(())
    }
}
fn cleanup(io: &IoBudget) -> IoBudget {
    IoBudget {
        maximum_bytes: io.maximum_bytes,
        deadline: Instant::now() + Duration::from_secs(5),
        cancellation: CancellationToken::default(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs::{self, DirBuilder},
        os::unix::fs::{DirBuilderExt, PermissionsExt},
        panic::{AssertUnwindSafe, catch_unwind},
        path::PathBuf,
    };
    struct Fixture {
        path: PathBuf,
        store: SidecarStore,
        entry: HeldDirectory,
        key: Lease,
        active: Lease,
    }
    fn io() -> IoBudget {
        IoBudget {
            maximum_bytes: 4096,
            deadline: Instant::now() + Duration::from_secs(10),
            cancellation: CancellationToken::default(),
        }
    }
    impl Fixture {
        fn new(old: Option<&[u8]>) -> Self {
            let path = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("arktrace-sidecar-{}", id()));
            DirBuilder::new().mode(0o700).create(&path).unwrap();
            let root = HeldDirectory::open_private(&path).unwrap();
            let trace = "a".repeat(64);
            let parser = "b".repeat(64);
            let entry = root
                .ensure_private_child(&trace)
                .unwrap()
                .ensure_private_child(&parser)
                .unwrap();
            let locks = root.ensure_private_child(".locks").unwrap();
            let leases = root.ensure_private_child(".leases").unwrap();
            let key_id = format!("{:x}", Sha256::digest(format!("{trace}:{parser}")));
            let key = Lease::acquire(
                &locks,
                &format!("{key_id}.lock"),
                LeaseMode::Exclusive,
                &io(),
            )
            .unwrap();
            let active = Lease::acquire(
                &leases,
                &format!("{key_id}.lease"),
                LeaseMode::Shared,
                &io(),
            )
            .unwrap();
            let store = SidecarStore::open(&root, 4096, &io()).unwrap();
            if let Some(old) = old {
                entry.write_new_readonly(FILE, old, &io()).unwrap();
            }
            Self {
                path,
                store,
                entry,
                key,
                active,
            }
        }
        fn write(&self, bytes: Option<&[u8]>) -> Result<(), HostError> {
            self.store
                .write(&self.entry, &self.key, &self.active, bytes, &io())
        }
        fn recover(&self) -> Result<SidecarRecovery, HostError> {
            self.store
                .recover(&self.entry, &self.key, &self.active, &io())
        }
        fn bytes(&self) -> Option<Vec<u8>> {
            optional_file(&self.entry, FILE)
                .unwrap()
                .map(|f| f.read_bounded(&io()).unwrap())
        }
        fn crash(&self, bytes: Option<&[u8]>, point: u8) {
            assert!(
                catch_unwind(AssertUnwindSafe(|| self.store.write_observed(
                    &self.entry,
                    &self.key,
                    &self.active,
                    bytes,
                    &io(),
                    |p| {
                        if p == point {
                            panic!("simulated abrupt boundary {p}");
                        }
                        Ok(())
                    }
                )))
                .is_err()
            );
        }
        fn drained(&self) {
            assert!(self.store.owners.identifiers(&io()).unwrap().is_empty());
            let names = self.store.root.child_names(&io(), 16).unwrap();
            assert!(
                names
                    .iter()
                    .all(|n| n == OsStr::new(".staging") || n == OsStr::new("journal.lock"))
            );
            assert_eq!(
                self.entry.child_names(&io(), 2).unwrap().len(),
                usize::from(self.bytes().is_some())
            );
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.path).unwrap();
        }
    }
    #[test]
    fn create_replace_delete_preserve_legacy_mode_and_leave_no_ready_temporary() {
        let f = Fixture::new(None);
        f.write(Some(b"one")).unwrap();
        assert_eq!(f.bytes().unwrap(), b"one");
        f.drained();
        fs::set_permissions(f.entry.path().join(FILE), fs::Permissions::from_mode(0o600)).unwrap();
        f.write(Some(b"two")).unwrap();
        let saved = f.entry.open_file(FILE).unwrap();
        assert_eq!(saved.snapshot().mode & 0o7777, 0o400);
        assert_eq!(f.bytes().unwrap(), b"two");
        f.drained();
        f.write(None).unwrap();
        assert_eq!(f.bytes(), None);
        f.drained();
        f.write(None).unwrap();
        f.drained();
    }
    #[test]
    fn abrupt_boundaries_recover_all_three_operations_with_proved_result() {
        for old in [None, Some(b"old".as_slice())] {
            for new in [None, Some(b"new".as_slice())] {
                if old.is_none() && new.is_none() {
                    continue;
                }
                for point in 0..=4 {
                    let f = Fixture::new(old);
                    f.crash(new, point);
                    if point == 0 {
                        assert_eq!(f.recover().unwrap(), SidecarRecovery::Absent);
                        assert_eq!(f.store.recover_orphans(&io()).unwrap(), 1);
                    } else {
                        assert_eq!(
                            f.recover().unwrap(),
                            if point == 1 {
                                SidecarRecovery::Aborted
                            } else {
                                SidecarRecovery::Committed
                            }
                        );
                    }
                    assert_eq!(f.bytes().as_deref(), if point < 2 { old } else { new });
                    f.drained();
                }
            }
        }
    }
    #[test]
    fn cancellation_before_publication_aborts_and_late_cancellation_retains_commit() {
        for point in [1, 2] {
            let f = Fixture::new(Some(b"old"));
            let budget = io();
            let result =
                f.store
                    .write_observed(&f.entry, &f.key, &f.active, Some(b"new"), &budget, |p| {
                        if p == point {
                            budget.cancellation.cancel();
                        }
                        Ok(())
                    });
            assert_eq!(result.unwrap_err(), HostError::Cancelled);
            assert_eq!(f.bytes().unwrap(), if point == 1 { b"old" } else { b"new" });
            f.drained();
        }
    }
    #[test]
    fn bounded_invalid_future_and_foreign_payload_are_preserved() {
        let f = Fixture::new(Some(b"old"));
        f.crash(Some(b"new"), 3);
        let (_, key) = f.store.authority(&f.entry, &f.key, &f.active).unwrap();
        let (_, intent) = f.store.intent(&key, &io()).unwrap().unwrap();
        let d = f
            .store
            .locate_intent_owner(&intent, &io())
            .unwrap()
            .unwrap();
        let scratch = d.open_file(PAYLOAD).unwrap();
        d.remove_owned_file(PAYLOAD, scratch.snapshot().identity)
            .unwrap();
        d.write_new_readonly(PAYLOAD, b"foreign", &io()).unwrap();
        assert_eq!(f.recover().unwrap(), SidecarRecovery::Preserved);
        assert_eq!(f.bytes().unwrap(), b"new");
        assert_eq!(
            d.open_file(PAYLOAD).unwrap().read_bounded(&io()).unwrap(),
            b"foreign"
        );
        assert_eq!(f.store.recover_orphans(&io()).unwrap(), 0);
        let f = Fixture::new(None);
        f.crash(Some(b"new"), 0);
        let (_, key) = f.store.authority(&f.entry, &f.key, &f.active).unwrap();
        let unknown = f
            .store
            .root
            .write_new_readonly(&format!("{key}.json"), br#"{"formatVersion":999}"#, &io())
            .unwrap();
        assert_eq!(f.recover().unwrap(), SidecarRecovery::Preserved);
        assert_eq!(f.store.recover_orphans(&io()).unwrap(), 0);
        assert_eq!(
            unknown.read_bounded(&io()).unwrap(),
            br#"{"formatVersion":999}"#
        );
        let f = Fixture::new(Some(b"old"));
        assert_eq!(
            f.write(Some(&[0; 4097])).unwrap_err(),
            HostError::LimitExceeded
        );
        assert_eq!(f.bytes().unwrap(), b"old");
        f.drained();
    }
    #[test]
    fn completion_survives_intent_removal_before_its_own_unlink() {
        let f = Fixture::new(Some(b"old"));
        f.crash(Some(b"new"), 4);
        let (_, key) = f.store.authority(&f.entry, &f.key, &f.active).unwrap();
        let (record, _) = f.store.intent(&key, &io()).unwrap().unwrap();
        f.store
            .root
            .remove_owned_file(&format!("{key}.json"), record.snapshot().identity)
            .unwrap();
        assert_eq!(f.recover().unwrap(), SidecarRecovery::Committed);
        assert_eq!(f.bytes().unwrap(), b"new");
        f.drained();
    }
    #[test]
    fn active_owner_and_replaced_entry_lease_never_authorize_cleanup() {
        let f = Fixture::new(Some(b"old"));
        f.crash(Some(b"new"), 1);
        let (_, key) = f.store.authority(&f.entry, &f.key, &f.active).unwrap();
        let (_, intent) = f.store.intent(&key, &io()).unwrap().unwrap();
        let held = Lease::try_acquire(
            &f.store.owners.owners,
            &format!("{}.lock", intent.owner_identifier),
            LeaseMode::Exclusive,
            false,
        )
        .unwrap()
        .unwrap();
        assert_eq!(f.recover().unwrap(), SidecarRecovery::Active);
        drop(held);
        let lease_path = f
            .store
            .cache
            .path()
            .join(".leases")
            .join(format!("{key}.lease"));
        fs::rename(&lease_path, lease_path.with_extension("saved")).unwrap();
        let fresh = Lease::acquire(
            &f.store.cache.open_private_child(".leases").unwrap(),
            &format!("{key}.lease"),
            LeaseMode::Shared,
            &io(),
        )
        .unwrap();
        assert_eq!(
            f.store.recover(&f.entry, &f.key, &fresh, &io()).unwrap(),
            SidecarRecovery::Preserved
        );
        assert_eq!(f.bytes().unwrap(), b"old");
    }
    #[test]
    fn removing_receipt_resolves_renamed_payload_missing_payload_and_rmdir_gap() {
        for committed in [false, true] {
            for step in 0..=2 {
                let f = Fixture::new(Some(b"old"));
                if committed {
                    f.crash(Some(b"new"), 3);
                } else {
                    f.crash(Some(b"new"), 1);
                    let _ = catch_unwind(AssertUnwindSafe(|| {
                        f.store
                            .recover_observed(&f.entry, &f.key, &f.active, &io(), |p| {
                                if p == 3 {
                                    panic!("finish");
                                }
                                Ok(())
                            })
                    }));
                }
                let (_, key) = f.store.authority(&f.entry, &f.key, &f.active).unwrap();
                let (_, intent) = f.store.intent(&key, &io()).unwrap().unwrap();
                let owner_lease = Lease::try_acquire(
                    &f.store.owners.owners,
                    &format!("{}.lock", intent.owner_identifier),
                    LeaseMode::Exclusive,
                    false,
                )
                .unwrap()
                .unwrap();
                let (record, mut evidence) = f
                    .store
                    .owners
                    .read(&intent.owner_identifier, &io())
                    .unwrap()
                    .unwrap();
                let d = f.store.owners.locate(&evidence, &io()).unwrap().unwrap();
                evidence.state = State::Removing;
                f.store
                    .owners
                    .write(
                        &intent.owner_identifier,
                        &owner_lease,
                        &evidence,
                        Some(&record),
                        &io(),
                    )
                    .unwrap();
                if step == 0 {
                    rename(
                        &d,
                        &component(OsStr::new(PAYLOAD)).unwrap(),
                        &component(OsStr::new(&format!(".arktrace-child-remove-{}", id())))
                            .unwrap(),
                        libc::RENAME_EXCL,
                    )
                    .unwrap();
                } else {
                    let payload = d.open_file(PAYLOAD).unwrap();
                    d.remove_owned_file(PAYLOAD, payload.snapshot().identity)
                        .unwrap();
                    if step == 2 {
                        fs::remove_dir(d.path()).unwrap();
                    }
                }
                drop(owner_lease);
                assert_eq!(
                    f.recover().unwrap(),
                    if committed {
                        SidecarRecovery::Committed
                    } else {
                        SidecarRecovery::Aborted
                    }
                );
                assert_eq!(f.bytes().unwrap(), if committed { b"new" } else { b"old" });
                f.drained();
            }
        }
    }
    #[test]
    fn recognized_journal_retirement_names_recover_without_guessing_temporary_ownership() {
        for stage in 0..=2 {
            let f = Fixture::new(Some(b"old"));
            f.crash(Some(b"new"), 4);
            let (_, key) = f.store.authority(&f.entry, &f.key, &f.active).unwrap();
            let live = component(OsStr::new(&format!("{key}.json"))).unwrap();
            let trash = component(OsStr::new(&format!("{key}.intent-remove.json"))).unwrap();
            rename(&f.store.root, &live, &trash, libc::RENAME_EXCL).unwrap();
            if stage > 0 {
                let record = f
                    .store
                    .root
                    .open_file(&format!("{key}.intent-remove.json"))
                    .unwrap();
                retire_record(
                    &f.store.root,
                    &record,
                    &format!("{key}.intent-remove.json"),
                    &io(),
                )
                .unwrap();
            }
            if stage == 2 {
                rename(
                    &f.store.root,
                    &component(OsStr::new(&format!("{key}.finish.json"))).unwrap(),
                    &component(OsStr::new(&format!("{key}.finish-remove.json"))).unwrap(),
                    libc::RENAME_EXCL,
                )
                .unwrap();
            }
            assert_eq!(f.recover().unwrap(), SidecarRecovery::Committed);
            assert_eq!(f.bytes().unwrap(), b"new");
            f.drained();
        }
    }
}
