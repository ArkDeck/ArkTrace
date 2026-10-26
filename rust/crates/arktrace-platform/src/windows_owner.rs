//! Private owner transactions. Format 2 retains legacy prototype evidence;
//! format 3 binds ephemeral key/lease identity before publication or disposal;
//! format 4 binds persistent cache keys, stable entry leases and quarantine.
//! Swift/ArkDeck format-1 writers must not use this isolated namespace.
//! Windows port of macos_owner.rs: same evidence format and transitions;
//! only the primitive calls differ (see windows.rs).
use super::{
    Access, FileIdentity, HeldDirectory, HeldFile, Lease, LeaseMode, component,
    directory::names_bounded, not_supported, remove_child, rename_entry, stat_child,
};
use crate::{CancellationToken, HostError, HostOperation, IoBudget};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    ffi::{CString, OsStr},
    path::Component,
    time::{Duration, Instant},
};

const RECORD_LIMIT: u64 = 4096;
const ENTRY_LIMIT: usize = 4096;
const DEPTH_LIMIT: usize = 8;

/// View-state sidecar journal. Its Darwin implementation needs an atomic
/// two-name exchange (`RENAME_SWAP`), which Windows lacks; until a Windows
/// journal design exists every entry point refuses (`ERROR_NOT_SUPPORTED`).
/// It is not part of the `--no-cache` CLI path.
pub enum SidecarRecovery {
    Absent,
    Aborted,
    Committed,
    Preserved,
    Active,
}

#[derive(Clone)]
pub struct SidecarStore {
    _refused: (),
}

impl SidecarStore {
    pub fn open(
        _cache: &HeldDirectory,
        _maximum_bytes: u64,
        _io: &IoBudget,
    ) -> Result<Self, HostError> {
        Err(not_supported(HostOperation::Open))
    }
    pub fn revalidate(&self) -> Result<(), HostError> {
        Err(not_supported(HostOperation::Stat))
    }
    pub fn recover(
        &self,
        _entry: &HeldDirectory,
        _key: &Lease,
        _active: &Lease,
        _io: &IoBudget,
    ) -> Result<SidecarRecovery, HostError> {
        Err(not_supported(HostOperation::Read))
    }
    pub fn recover_orphans(&self, _io: &IoBudget) -> Result<usize, HostError> {
        Err(not_supported(HostOperation::Read))
    }
    pub fn write(
        &self,
        _entry: &HeldDirectory,
        _key: &Lease,
        _active: &Lease,
        _bytes: Option<&[u8]>,
        _io: &IoBudget,
    ) -> Result<(), HostError> {
        Err(not_supported(HostOperation::Write))
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OwnerKind {
    Session,
    Building,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum State {
    Creating,
    Session,
    Building,
    Publishing,
    Ready,
    Quarantined,
    Removing,
    Removed,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Evidence {
    format_version: u32,
    state: State,
    device: Option<u64>,
    inode: Option<u64>,
    relative_path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    ephemeral: Option<EphemeralBinding>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    cache: Option<CacheBinding>,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CacheBinding {
    key_identifier: String,
    entry_relative_path: String,
    lease_device: u64,
    lease_inode: u64,
}
fn digest_name(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
impl CacheBinding {
    fn validate(&self) -> Result<(), HostError> {
        let parts = self.entry_relative_path.split('/').collect::<Vec<_>>();
        if parts.len() != 2
            || !parts.iter().all(|part| digest_name(part))
            || self.lease_inode == 0
            || self.key_identifier
                != Sha256::digest(format!("{}:{}", parts[0], parts[1]).as_bytes())
                    .iter()
                    .map(|byte| format!("{byte:02x}"))
                    .collect::<String>()
        {
            return Err(HostError::InvalidEvidence);
        }
        Ok(())
    }
    fn lease_identity(&self) -> FileIdentity {
        FileIdentity {
            device: self.lease_device,
            inode: self.lease_inode,
        }
    }
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct EphemeralBinding {
    key_identifier: String,
    session_identifier: String,
    lease_device: u64,
    lease_inode: u64,
}
impl EphemeralBinding {
    fn validate(&self) -> Result<(), HostError> {
        if self.key_identifier.len() != 64
            || !self
                .key_identifier
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            || !self.session_identifier.starts_with("session-")
            || self.lease_inode == 0
        {
            return Err(HostError::InvalidEvidence);
        }
        owner_name(&self.session_identifier).map_err(|_| HostError::InvalidEvidence)
    }
    fn lease_identity(&self) -> FileIdentity {
        FileIdentity {
            device: self.lease_device,
            inode: self.lease_inode,
        }
    }
}
impl Evidence {
    fn decode(bytes: &[u8]) -> Result<Self, HostError> {
        let shape: serde_json::Value =
            serde_json::from_slice(bytes).map_err(|_| HostError::InvalidEvidence)?;
        let version = shape.get("formatVersion").and_then(|v| v.as_u64());
        if match version {
            Some(2) => shape.get("ephemeral").is_some() || shape.get("cache").is_some(),
            Some(3) => {
                !shape.get("ephemeral").is_some_and(|v| v.is_object())
                    || shape.get("cache").is_some()
            }
            Some(4) => {
                !shape.get("cache").is_some_and(|v| v.is_object())
                    || shape.get("ephemeral").is_some()
            }
            _ => true,
        } {
            return Err(HostError::InvalidEvidence);
        }
        let evidence: Self =
            serde_json::from_slice(bytes).map_err(|_| HostError::InvalidEvidence)?;
        evidence.validate()?;
        Ok(evidence)
    }
    fn identity(&self) -> Option<FileIdentity> {
        self.device
            .zip(self.inode)
            .map(|(device, inode)| FileIdentity { device, inode })
    }
    fn validate(&self) -> Result<(), HostError> {
        if !((self.format_version == 2
            && self.ephemeral.is_none()
            && self.cache.is_none()
            && !matches!(self.state, State::Publishing | State::Quarantined))
            || (self.format_version == 3
                && self.ephemeral.is_some()
                && self.cache.is_none()
                && !matches!(
                    self.state,
                    State::Creating | State::Session | State::Quarantined
                ))
            || (self.format_version == 4
                && self.cache.is_some()
                && self.ephemeral.is_none()
                && !matches!(self.state, State::Creating | State::Session)))
            || (self.device.is_some() != self.inode.is_some())
            || (self.state == State::Creating) != self.identity().is_none()
            || self.inode == Some(0)
        {
            return Err(HostError::InvalidEvidence);
        }
        relative_names(&self.relative_path)?;
        if let Some(binding) = &self.ephemeral {
            binding.validate()?;
            if matches!(self.state, State::Publishing | State::Ready)
                && self.relative_path != format!(".ready/{}", binding.session_identifier)
            {
                return Err(HostError::InvalidEvidence);
            }
        }
        if let Some(binding) = &self.cache {
            binding.validate()?;
            if matches!(self.state, State::Publishing | State::Ready)
                && self.relative_path != binding.entry_relative_path
            {
                return Err(HostError::InvalidEvidence);
            }
            if self.state == State::Quarantined {
                let names = relative_names(&self.relative_path)?;
                if names.len() != 2 || names[0].to_bytes() != b".corrupt" {
                    return Err(HostError::InvalidEvidence);
                }
                owner_name(
                    std::str::from_utf8(names[1].to_bytes())
                        .map_err(|_| HostError::InvalidEvidence)?,
                )?;
            }
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum OwnerRecoveryOutcome {
    Active,
    Removed,
    CreatingUnbound,
    PublishedNeedsEntryLease,
    IdentityUnresolved,
    UnsupportedVersion,
    NotFound,
}

#[derive(Clone)]
pub struct OwnerStore {
    parent: HeldDirectory,
    owners: HeldDirectory,
    recovery_root: HeldDirectory,
}
pub struct OwnedDirectory {
    store: OwnerStore,
    identifier: String,
    directory: HeldDirectory,
    lease: Lease,
    removed: bool,
}

/// Read-only discovery is not disposal authority. Recovery rechecks this exact
/// record after acquiring key, entry and owner leases in that order.
pub struct PublishedOwnerEvidence {
    identifier: String,
    evidence: Evidence,
    root_identity: FileIdentity,
}
impl PublishedOwnerEvidence {
    pub fn identifier(&self) -> &str {
        &self.identifier
    }
    pub fn key_identifier(&self) -> Option<&str> {
        self.evidence
            .ephemeral
            .as_ref()
            .map(|b| b.key_identifier.as_str())
            .or_else(|| {
                self.evidence
                    .cache
                    .as_ref()
                    .map(|b| b.key_identifier.as_str())
            })
    }
    pub fn is_cached(&self) -> bool {
        self.evidence.cache.is_some()
    }
    pub fn directory_identity(&self) -> Option<FileIdentity> {
        self.evidence.identity()
    }
    pub fn cached_entry_relative_path(&self) -> Option<&str> {
        self.evidence
            .cache
            .as_ref()
            .map(|b| b.entry_relative_path.as_str())
    }
    pub fn is_ready(&self) -> bool {
        self.evidence.state == State::Ready
    }
    pub fn is_publishing(&self) -> bool {
        self.evidence.state == State::Publishing
    }
    pub fn is_quarantined(&self) -> bool {
        self.evidence.state == State::Quarantined
    }
    pub fn requires_metadata(&self) -> bool {
        self.evidence.state == State::Ready
    }
}
// Drop releases only handles/lease. It never starts implicit IO or erases proof
// after an error/panic; a later caller recovers under the exclusive owner lease.

fn id() -> String {
    super::uuid()
}
fn owner_name(value: &str) -> Result<(), HostError> {
    let suffix = value
        .strip_prefix("session-")
        .or_else(|| value.strip_prefix("entry-"))
        .ok_or(HostError::InvalidPath)?;
    if suffix.len() != 36
        || !suffix.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
    {
        return Err(HostError::InvalidPath);
    }
    Ok(())
}
fn relative_names(value: &str) -> Result<Vec<CString>, HostError> {
    if value.len() > 1024 {
        return Err(HostError::InvalidEvidence);
    }
    let result = value
        .split('/')
        .map(|n| component(OsStr::new(n)).map_err(|_| HostError::InvalidEvidence))
        .collect::<Result<Vec<_>, _>>()?;
    if result.is_empty() || result.len() > DEPTH_LIMIT {
        return Err(HostError::InvalidEvidence);
    }
    Ok(result)
}
fn relative(root: &HeldDirectory, target: &HeldDirectory) -> Result<String, HostError> {
    root.revalidate()?;
    target.revalidate()?;
    let mut node = Some(target.0.clone());
    let mut belongs = false;
    while let Some(current) = node {
        if current.identity == root.identity() {
            belongs = true;
            break;
        }
        node = current.parent.clone();
    }
    if !belongs || root.identity().device != target.identity().device {
        return Err(HostError::InvalidPath);
    }
    let path = target
        .path()
        .strip_prefix(root.path())
        .map_err(|_| HostError::InvalidPath)?;
    let text = path
        .components()
        .map(|c| match c {
            Component::Normal(n) => n.to_str().ok_or(HostError::InvalidPath),
            _ => Err(HostError::InvalidPath),
        })
        .collect::<Result<Vec<_>, _>>()?
        .join("/");
    if !text.is_empty() {
        relative_names(&text)?;
    }
    Ok(text)
}
fn record_budget(budget: &IoBudget) -> IoBudget {
    IoBudget {
        maximum_bytes: RECORD_LIMIT,
        deadline: budget.deadline,
        cancellation: budget.cancellation.clone(),
    }
}
fn cleanup_budget() -> IoBudget {
    IoBudget {
        maximum_bytes: RECORD_LIMIT,
        deadline: Instant::now() + Duration::from_secs(2),
        cancellation: CancellationToken::default(),
    }
}
fn ensure_child(parent: &HeldDirectory, name: &str) -> Result<HeldDirectory, HostError> {
    match parent.create_private_child(name) {
        Ok(child) => Ok(child),
        Err(HostError::AlreadyExists) => {
            let child = parent.open_child(&component(OsStr::new(name))?, true, true)?;
            child.revalidate()?;
            Ok(child)
        }
        Err(error) => Err(error),
    }
}
/// Same-directory rename. `replace` is the Windows stand-in for Darwin's
/// `RENAME_SWAP` where a verified record replaces its predecessor: the old
/// name is unlinked atomically (its holder keeps the bytes) instead of being
/// left at the temporary name. Callers verify both identities around it.
fn rename(
    parent: &HeldDirectory,
    source: &CString,
    target: &CString,
    replace: bool,
) -> Result<(), HostError> {
    parent.revalidate()?;
    rename_entry(&parent.0.file, source, &parent.0.file, target, replace)
}

fn move_owned_directory(
    directory: &HeldDirectory,
    destination: &HeldDirectory,
    name: &str,
    budget: &IoBudget,
) -> Result<HeldDirectory, HostError> {
    budget.check()?;
    directory.revalidate()?;
    destination.revalidate()?;
    let parent = HeldDirectory(directory.0.parent.clone().ok_or(HostError::InvalidPath)?);
    parent.revalidate()?;
    if !directory.0.private
        || !destination.0.private
        || !parent.0.private
        || directory.identity().device != destination.identity().device
    {
        return Err(HostError::InvalidEvidence);
    }
    let target = component(OsStr::new(name))?;
    rename_entry(
        &parent.0.file,
        &directory.0.name,
        &destination.0.file,
        &target,
        false,
    )?;
    let moved = destination.open_child(&target, true, true)?;
    if moved.identity() != directory.identity() {
        // Preserve a raced replacement by moving it back only into a vacant
        // source name; never unlink it or overwrite another replacement.
        rename_entry(
            &destination.0.file,
            &target,
            &parent.0.file,
            &directory.0.name,
            false,
        )
        .map_err(|_| HostError::CleanupFailed)?;
        parent.sync()?;
        destination.sync()?;
        return Err(HostError::IdentityMismatch);
    }
    parent.sync()?;
    destination.sync()?;
    moved.revalidate()?;
    Ok(moved)
}

impl HeldDirectory {
    /// Identity-checked atomic replacement of a private readonly document.
    /// A raced target is never replaced silently: the old binding is verified
    /// immediately before the replace and the new binding immediately after.
    pub fn replace_readonly(
        &self,
        old: &HeldFile,
        bytes: &[u8],
        budget: &IoBudget,
    ) -> Result<HeldFile, HostError> {
        if old.parent.identity() != self.identity()
            || !old.private
            || !Access::of(&old.file)?.sealed()
        {
            return Err(HostError::InvalidEvidence);
        }
        budget.check()?;
        old.verify()?;
        let temporary = format!(".arktrace-atomic-{}.tmp", id());
        let candidate = self.write_new_readonly(&temporary, bytes, budget)?;
        let result = (|| {
            candidate.verify()?;
            old.verify()?;
            budget.check()?;
            rename(self, &candidate.name, &old.name, true)?;
            let current = stat_child(&self.0.file, &old.name)?;
            if !current.is_file() || current.identity()? != candidate.initial.identity {
                return Err(HostError::CleanupFailed);
            }
            self.sync()?;
            let new = self.open_file_component(old.name.clone(), true)?;
            if new.initial.identity != candidate.initial.identity {
                return Err(HostError::IdentityMismatch);
            }
            Ok(new)
        })();
        if result.is_err() {
            match stat_child(&self.0.file, &candidate.name) {
                Ok(info) if info.identity()? == candidate.initial.identity => {
                    self.remove_owned_component(&candidate.name, candidate.initial.identity)?;
                    self.sync()?;
                }
                Err(HostError::NotFound) => (),
                _ => return Err(HostError::CleanupFailed),
            }
        }
        result
    }
}

impl OwnerStore {
    fn cache_authority(
        &self,
        evidence: &Evidence,
        key: &Lease,
        entry: &Lease,
        exclusive: bool,
    ) -> Result<(), HostError> {
        let binding = evidence.cache.as_ref().ok_or(HostError::InvalidEvidence)?;
        binding.validate()?;
        let locks = self.recovery_root.open_private_child(".locks")?;
        let leases = self.recovery_root.open_private_child(".leases")?;
        if key.mode != LeaseMode::Exclusive
            || (exclusive && entry.mode != LeaseMode::Exclusive)
            || key.parent.identity() != locks.identity()
            || entry.parent.identity() != leases.identity()
            || key.name.to_bytes() != format!("{}.lock", binding.key_identifier).as_bytes()
            || entry.name.to_bytes() != format!("{}.lease", binding.key_identifier).as_bytes()
            || entry.identity != binding.lease_identity()
        {
            return Err(HostError::InvalidEvidence);
        }
        key.revalidate()?;
        entry.revalidate()
    }

    /// Read-only cache discovery under the fixed key and active entry lease.
    /// A record copied from another root or replaced since discovery is rejected.
    pub fn validate_cached_location(
        &self,
        published: &PublishedOwnerEvidence,
        key: &Lease,
        entry: &Lease,
        budget: &IoBudget,
    ) -> Result<Option<HeldDirectory>, HostError> {
        if published.root_identity != self.recovery_root.identity() {
            return Err(HostError::InvalidEvidence);
        }
        let (_, current) = self
            .read(&published.identifier, budget)?
            .ok_or(HostError::InvalidEvidence)?;
        if current != published.evidence {
            return Err(HostError::InvalidEvidence);
        }
        self.cache_authority(&current, key, entry, false)?;
        self.locate(&current, budget)
    }

    fn cached_owned(
        &self,
        published: &PublishedOwnerEvidence,
        key: &Lease,
        entry: &Lease,
        budget: &IoBudget,
    ) -> Result<OwnedDirectory, HostError> {
        self.cache_authority(&published.evidence, key, entry, true)?;
        let directory = self
            .validate_cached_location(published, key, entry, budget)?
            .ok_or(HostError::InvalidEvidence)?;
        let lease = Lease::try_acquire(
            &self.owners,
            &format!("{}.lock", published.identifier),
            LeaseMode::Exclusive,
            false,
        )?
        .ok_or(HostError::Busy)?;
        let (_, current) = self
            .read(&published.identifier, budget)?
            .ok_or(HostError::InvalidEvidence)?;
        if current != published.evidence {
            return Err(HostError::InvalidEvidence);
        }
        Ok(OwnedDirectory {
            store: self.clone(),
            identifier: published.identifier.clone(),
            directory,
            lease,
            removed: false,
        })
    }

    /// Complete a prior durable Publishing intent only after Engine has checked
    /// the Ready metadata/schema/index handoff under exclusive entry authority.
    pub fn complete_cached_publication(
        &self,
        published: &PublishedOwnerEvidence,
        directory: &HeldDirectory,
        key: &Lease,
        entry: &Lease,
        budget: &IoBudget,
    ) -> Result<(), HostError> {
        if !matches!(published.evidence.state, State::Publishing | State::Ready)
            || published.evidence.identity() != Some(directory.identity())
        {
            return Err(HostError::InvalidEvidence);
        }
        let mut owned = self.cached_owned(published, key, entry, budget)?;
        owned.record_published_location(directory, budget)
    }

    /// Preserve corrupt cache bytes, including user sidecars. Intent is durable
    /// before rename and can be resumed after a crash without guessing by name.
    pub fn quarantine_cached(
        &self,
        published: &PublishedOwnerEvidence,
        key: &Lease,
        entry: &Lease,
        budget: &IoBudget,
    ) -> Result<(), HostError> {
        let mut owned = self.cached_owned(published, key, entry, budget)?;
        let (record, mut evidence) = self
            .read(&owned.identifier, budget)?
            .ok_or(HostError::InvalidEvidence)?;
        if !matches!(
            evidence.state,
            State::Ready | State::Publishing | State::Quarantined
        ) {
            return Err(HostError::InvalidEvidence);
        }
        let corrupt = self.recovery_root.ensure_private_child(".corrupt")?;
        let target = format!(".corrupt/{}", owned.identifier);
        if relative(&self.recovery_root, &owned.directory)? == target {
            return Ok(());
        }
        evidence.state = State::Quarantined;
        evidence.relative_path = target;
        self.write(
            &owned.identifier,
            &owned.lease,
            &evidence,
            Some(&record),
            budget,
        )?;
        owned.directory =
            move_owned_directory(&owned.directory, &corrupt, &owned.identifier, budget)?;
        Ok(())
    }

    /// Dispose a bound abandoned build, never a Ready or quarantined cache.
    /// Stable key/entry lease names are retained after payload disposal.
    pub fn recover_cached_build(
        &self,
        published: &PublishedOwnerEvidence,
        key: &Lease,
        entry: &Lease,
        budget: &IoBudget,
    ) -> Result<OwnerRecoveryOutcome, HostError> {
        if published.root_identity != self.recovery_root.identity() {
            return Err(HostError::InvalidEvidence);
        }
        self.cache_authority(&published.evidence, key, entry, true)?;
        if !matches!(
            published.evidence.state,
            State::Building | State::Removing | State::Removed | State::Publishing
        ) {
            return Ok(OwnerRecoveryOutcome::PublishedNeedsEntryLease);
        }
        if matches!(published.evidence.state, State::Removing | State::Removed)
            && self.locate(&published.evidence, budget)?.is_none()
        {
            let lease = Lease::try_acquire(
                &self.owners,
                &format!("{}.lock", published.identifier),
                LeaseMode::Exclusive,
                false,
            )?
            .ok_or(HostError::Busy)?;
            let (_, current) = self
                .read(&published.identifier, budget)?
                .ok_or(HostError::InvalidEvidence)?;
            if current != published.evidence {
                return Err(HostError::InvalidEvidence);
            }
            // A durable removal intent may have completed rmdir immediately
            // before death, without committing Removed. Dispose only this
            // exact ledger/marker pair; no payload name is deletion authority.
            // Ready/Publishing records with missing identity never enter here.
            if self.locate(&current, budget)?.is_some() {
                return Err(HostError::InvalidEvidence);
            }
            self.cache_authority(&current, key, entry, true)?;
            self.remove_artifacts(&published.identifier, &lease, budget)?;
            return Ok(OwnerRecoveryOutcome::Removed);
        }
        let mut owned = self.cached_owned(published, key, entry, budget)?;
        if published.evidence.state == State::Publishing
            && relative(&self.recovery_root, &owned.directory)?
                == published
                    .evidence
                    .cache
                    .as_ref()
                    .ok_or(HostError::InvalidEvidence)?
                    .entry_relative_path
        {
            return Ok(OwnerRecoveryOutcome::PublishedNeedsEntryLease);
        }
        owned.cleanup_cached(key, entry, budget)?;
        Ok(OwnerRecoveryOutcome::Removed)
    }

    /// Ready eviction uses the same fixed key -> exclusive entry -> exact
    /// owner transaction as publication. Discovery alone grants no authority.
    /// Stable key/entry leases survive removal; quarantined bytes are retained.
    pub fn purge_cached_ready(
        &self,
        published: &PublishedOwnerEvidence,
        expected_directory: FileIdentity,
        key: &Lease,
        entry: &Lease,
        budget: &IoBudget,
    ) -> Result<(), HostError> {
        if !published.is_cached()
            || !(published.is_ready() || published.is_publishing())
            || published.directory_identity() != Some(expected_directory)
        {
            return Err(HostError::InvalidEvidence);
        }
        let mut owned = self.cached_owned(published, key, entry, budget)?;
        if relative(&self.recovery_root, &owned.directory)?
            != published
                .cached_entry_relative_path()
                .ok_or(HostError::InvalidEvidence)?
            || owned.directory.identity() != expected_directory
        {
            return Err(HostError::InvalidEvidence);
        }
        // Ready records cannot be treated as disposable private residuals.
        // Persist removal authority before the first rename, so a crash in
        // cleanup's rename-before-location window can resume under entry EX.
        let (record, mut evidence) = self
            .read(&owned.identifier, budget)?
            .ok_or(HostError::InvalidEvidence)?;
        evidence.state = State::Removing;
        self.write(
            &owned.identifier,
            &owned.lease,
            &evidence,
            Some(&record),
            budget,
        )?;
        // Once the durable removal intent exists, cancellation must drain this
        // owned transaction instead of abandoning half a directory. Cleanup
        // gets its own short deadline; any residual takes failure priority.
        let cleanup = IoBudget {
            maximum_bytes: budget.maximum_bytes,
            deadline: Instant::now() + Duration::from_secs(5),
            cancellation: CancellationToken::default(),
        };
        owned
            .cleanup_cached(key, entry, &cleanup)
            .map_err(|_| HostError::CleanupFailed)?;
        budget.check()
    }

    /// Both directories must already be held/private and share this namespace.
    /// Only a missing .owners child is created; existing ACL/modes are not fixed.
    pub fn open(parent: &HeldDirectory, recovery_root: &HeldDirectory) -> Result<Self, HostError> {
        relative(recovery_root, parent)?;
        Ok(Self {
            parent: parent.clone(),
            owners: ensure_child(parent, ".owners")?,
            recovery_root: recovery_root.clone(),
        })
    }
    pub fn create(&self, kind: OwnerKind, budget: &IoBudget) -> Result<OwnedDirectory, HostError> {
        self.create_observed(kind, budget, |_, _| Ok(()))
    }
    fn create_observed(
        &self,
        kind: OwnerKind,
        budget: &IoBudget,
        mut observe: impl FnMut(u8, &std::path::Path) -> Result<(), HostError>,
    ) -> Result<OwnedDirectory, HostError> {
        budget.check()?;
        let prefix = if kind == OwnerKind::Session {
            "session-"
        } else {
            "entry-"
        };
        let identifier = format!("{prefix}{}", id());
        for name in [
            &identifier,
            &format!("{identifier}.json"),
            &format!("{identifier}.lock"),
        ] {
            let parent = if name == &identifier {
                &self.parent
            } else {
                &self.owners
            };
            match stat_child(&parent.0.file, &component(OsStr::new(name))?) {
                Err(HostError::NotFound) => {}
                Ok(_) => return Err(HostError::AlreadyExists),
                Err(e) => return Err(e),
            }
        }
        let lease = Lease::acquire(
            &self.owners,
            &format!("{identifier}.lock"),
            LeaseMode::Exclusive,
            budget,
        )?;
        let parent_relative = relative(&self.recovery_root, &self.parent)?;
        let relative_path = if parent_relative.is_empty() {
            identifier.clone()
        } else {
            format!("{parent_relative}/{identifier}")
        };
        let creating = Evidence {
            format_version: 2,
            state: State::Creating,
            device: None,
            inode: None,
            relative_path,
            ephemeral: None,
            cache: None,
        };
        self.write(&identifier, &lease, &creating, None, budget)?;
        let path = self.parent.path().join(&identifier);
        if let Err(error) = observe(0, &path).and_then(|_| budget.check()) {
            self.remove_artifacts(&identifier, &lease, &cleanup_budget())
                .map_err(|_| HostError::CleanupFailed)?;
            return Err(error);
        }
        // No production callback runs between mkdir and first descriptor bind.
        // A failed first bind retains creating proof, never guesses by pathname.
        let name = component(OsStr::new(&identifier))?;
        if let Err(error) = self.parent.revalidate() {
            self.remove_artifacts(&identifier, &lease, &cleanup_budget())
                .map_err(|_| HostError::CleanupFailed)?;
            return Err(error);
        }
        if let Err(error) = self.parent.make_private_directory(&name) {
            self.remove_artifacts(&identifier, &lease, &cleanup_budget())
                .map_err(|_| HostError::CleanupFailed)?;
            return Err(error);
        }
        observe(1, &path).map_err(|_| HostError::CleanupFailed)?;
        let directory = self
            .parent
            .open_child(&name, true, true)
            .map_err(|_| HostError::CleanupFailed)?;
        directory
            .revalidate()
            .map_err(|_| HostError::CleanupFailed)?;
        let mut owned = OwnedDirectory {
            store: self.clone(),
            identifier,
            directory,
            lease,
            removed: false,
        };
        let result = (|| {
            let mut bound = creating;
            let identity = owned.directory.identity();
            bound.device = Some(identity.device);
            bound.inode = Some(identity.inode);
            bound.state = if kind == OwnerKind::Session {
                State::Session
            } else {
                State::Building
            };
            let old = self
                .read(&owned.identifier, budget)?
                .ok_or(HostError::InvalidEvidence)?
                .0;
            self.write(&owned.identifier, &owned.lease, &bound, Some(&old), budget)?;
            owned.directory.sync()?;
            self.parent.sync()?;
            observe(2, owned.directory.path())?;
            budget.check()?;
            Ok(())
        })();
        if let Err(error) = result {
            // A live identity is authoritative even if bound evidence failed.
            owned
                .cleanup_live(&cleanup_budget())
                .map_err(|_| HostError::CleanupFailed)?;
            return Err(error);
        }
        Ok(owned)
    }

    fn read(
        &self,
        identifier: &str,
        budget: &IoBudget,
    ) -> Result<Option<(HeldFile, Evidence)>, HostError> {
        owner_name(identifier)?;
        let file = match self.owners.open_file(&format!("{identifier}.json")) {
            Err(HostError::NotFound) => return Ok(None),
            value => value?,
        };
        let bytes = file.read_bounded(&record_budget(budget))?;
        let value = Evidence::decode(&bytes)?;
        Ok(Some((file, value)))
    }
    fn write(
        &self,
        identifier: &str,
        lease: &Lease,
        value: &Evidence,
        old: Option<&HeldFile>,
        budget: &IoBudget,
    ) -> Result<(), HostError> {
        value.validate()?;
        budget.check()?;
        lease.revalidate()?;
        let bytes = serde_json::to_vec(value).map_err(|_| HostError::InvalidEvidence)?;
        let temporary = format!(".owner-evidence-{}.tmp", id());
        let temp = self
            .owners
            .write_new_readonly(&temporary, &bytes, &record_budget(budget))?;
        let target = component(OsStr::new(&format!("{identifier}.json")))?;
        let result = (|| {
            lease.revalidate()?;
            temp.verify()?;
            if let Some(old) = old {
                old.verify()?;
            }
            budget.check()?;
            // Darwin swaps the old record to the temporary name and removes it
            // after checking both. Windows has no exchange: the old binding was
            // verified just above under the owner's exclusive lease, then the
            // replace unlinks it atomically and the new binding is checked.
            rename(&self.owners, &temp.name, &target, old.is_some())?;
            if stat_child(&self.owners.0.file, &target)?.identity()? != temp.initial.identity {
                return Err(HostError::CleanupFailed);
            }
            self.owners.sync()?;
            Ok(())
        })();
        if result.is_err() {
            match stat_child(&self.owners.0.file, &temp.name) {
                Ok(info) if info.identity()? == temp.initial.identity => self
                    .owners
                    .remove_owned_component(&temp.name, temp.initial.identity)
                    .map_err(|_| HostError::CleanupFailed)?,
                Err(HostError::NotFound) => {}
                // An old/replaced evidence remains under a temporary name. Keep
                // it on ambiguous durability instead of deleting foreign proof.
                _ => return Err(HostError::CleanupFailed),
            }
        }
        result
    }
    fn remove_artifacts(
        &self,
        identifier: &str,
        lease: &Lease,
        budget: &IoBudget,
    ) -> Result<(), HostError> {
        budget.check()?;
        lease.revalidate()?;
        if let Some((record, _)) = self.read(identifier, budget)? {
            self.owners
                .remove_owned_component(&record.name, record.initial.identity)?;
        }
        self.owners
            .remove_owned_component(&lease.name, lease.identity)?;
        self.owners.sync()
    }
    fn locate(
        &self,
        evidence: &Evidence,
        budget: &IoBudget,
    ) -> Result<Option<HeldDirectory>, HostError> {
        let identity = evidence.identity().ok_or(HostError::InvalidEvidence)?;
        let mut preferred = self.recovery_root.clone();
        let mut possible = true;
        for name in relative_names(&evidence.relative_path)? {
            match preferred.open_child(&name, true, true) {
                Ok(child) => preferred = child,
                Err(HostError::NotFound | HostError::NotDirectory | HostError::LinkedObject) => {
                    possible = false;
                    break;
                }
                Err(error) => return Err(error),
            }
        }
        if possible && preferred.identity() == identity {
            preferred.revalidate()?;
            return Ok(Some(preferred));
        }
        // No symlinks, no cross-volume traversal; every directory is rebound to
        // held ancestors. A complete bounded scan cannot infer ownership from a name.
        let mut queue = vec![(self.recovery_root.clone(), 0)];
        let mut remaining = ENTRY_LIMIT;
        while let Some((directory, depth)) = queue.pop() {
            budget.check()?;
            for name in names_bounded(&directory, budget, remaining)? {
                remaining = remaining.checked_sub(1).ok_or(HostError::LimitExceeded)?;
                let info = stat_child(&directory.0.file, &name)?;
                if !info.is_dir() {
                    continue;
                }
                let child = directory.open_child(&name, true, true)?;
                child.revalidate()?;
                if child.identity().device != self.recovery_root.identity().device {
                    continue;
                }
                if child.identity() == identity {
                    return Ok(Some(child));
                }
                if depth + 1 >= DEPTH_LIMIT {
                    return Err(HostError::LimitExceeded);
                }
                queue.push((child, depth + 1));
            }
        }
        Ok(None)
    }
    /// Recovery refuses a live owner and preserves creating/unknown/Ready proof.
    /// Cache Ready cleanup additionally requires the Engine's entry lease policy.
    pub fn recover_stale(
        &self,
        identifier: &str,
        budget: &IoBudget,
    ) -> Result<OwnerRecoveryOutcome, HostError> {
        owner_name(identifier)?;
        budget.check()?;
        let lease = match Lease::try_acquire(
            &self.owners,
            &format!("{identifier}.lock"),
            LeaseMode::Exclusive,
            false,
        ) {
            Ok(Some(lease)) => lease,
            Ok(None) => return Ok(OwnerRecoveryOutcome::Active),
            Err(HostError::NotFound) => return Ok(OwnerRecoveryOutcome::NotFound),
            Err(e) => return Err(e),
        };
        let record_file = match self.owners.open_file(&format!("{identifier}.json")) {
            Ok(file) => file,
            Err(HostError::NotFound) => return Ok(OwnerRecoveryOutcome::IdentityUnresolved),
            Err(e) => return Err(e),
        };
        let bytes = record_file.read_bounded(&record_budget(budget))?;
        let json: serde_json::Value =
            serde_json::from_slice(&bytes).map_err(|_| HostError::InvalidEvidence)?;
        if !matches!(
            json.get("formatVersion").and_then(|v| v.as_u64()),
            Some(2..=4)
        ) {
            return Ok(OwnerRecoveryOutcome::UnsupportedVersion);
        }
        // Decode original bytes: Value would silently collapse duplicate keys.
        let evidence = Evidence::decode(&bytes)?;
        if evidence.state == State::Creating {
            return Ok(OwnerRecoveryOutcome::CreatingUnbound);
        }
        if evidence.state == State::Ready
            || evidence.ephemeral.is_some()
            || evidence.cache.is_some()
        {
            return Ok(OwnerRecoveryOutcome::PublishedNeedsEntryLease);
        }
        if evidence.state == State::Removed {
            // A durable removed tombstone is written only after rmdir succeeds.
            // If its identity reappears, retain proof rather than guessing.
            if self.locate(&evidence, budget)?.is_some() {
                return Ok(OwnerRecoveryOutcome::IdentityUnresolved);
            }
            budget.check()?;
            self.remove_artifacts(identifier, &lease, budget)?;
            return Ok(OwnerRecoveryOutcome::Removed);
        }
        let Some(directory) = self.locate(&evidence, budget)? else {
            return Ok(OwnerRecoveryOutcome::IdentityUnresolved);
        };
        let mut owned = OwnedDirectory {
            store: self.clone(),
            identifier: identifier.into(),
            directory,
            lease,
            removed: false,
        };
        owned.cleanup(budget)?;
        Ok(OwnerRecoveryOutcome::Removed)
    }
    pub fn identifiers(&self, budget: &IoBudget) -> Result<Vec<String>, HostError> {
        self.identifiers_bounded(budget, ENTRY_LIMIT)
    }
    pub fn identifiers_bounded(
        &self,
        budget: &IoBudget,
        maximum_names: usize,
    ) -> Result<Vec<String>, HostError> {
        if maximum_names > 196_608 {
            return Err(HostError::LimitExceeded);
        }
        let mut result = Vec::new();
        for name in names_bounded(&self.owners, budget, maximum_names)? {
            let name =
                std::str::from_utf8(name.as_bytes()).map_err(|_| HostError::InvalidEvidence)?;
            if let Some(identifier) = name.strip_suffix(".json") {
                owner_name(identifier)?;
                result.push(identifier.into());
            }
        }
        Ok(result)
    }

    /// A missing record is checked again under its existing exclusive marker.
    /// A live creator, unknown record or replaced marker is never unlinked.
    pub fn recover_orphan_markers(
        &self,
        budget: &IoBudget,
        maximum_names: usize,
    ) -> Result<usize, HostError> {
        if maximum_names > 196_608 {
            return Err(HostError::LimitExceeded);
        }
        let mut removed = 0;
        for name in names_bounded(&self.owners, budget, maximum_names)? {
            budget.check()?;
            let name_text =
                std::str::from_utf8(name.as_bytes()).map_err(|_| HostError::InvalidEvidence)?;
            let Some(identifier) = name_text.strip_suffix(".lock") else {
                continue;
            };
            owner_name(identifier)?;
            match self.owners.open_file(&format!("{identifier}.json")) {
                Ok(_) => continue,
                Err(HostError::NotFound) => (),
                Err(e) => return Err(e),
            }
            let Some(lease) =
                Lease::try_acquire(&self.owners, name_text, LeaseMode::Exclusive, false)?
            else {
                continue;
            };
            match self.owners.open_file(&format!("{identifier}.json")) {
                Ok(_) => continue,
                Err(HostError::NotFound) => (),
                Err(e) => return Err(e),
            }
            budget.check()?;
            lease.revalidate()?;
            self.owners.remove_owned_component(&name, lease.identity)?;
            self.owners.sync()?;
            removed += 1;
        }
        Ok(removed)
    }

    pub fn published_evidence(
        &self,
        identifier: &str,
        budget: &IoBudget,
    ) -> Result<Option<PublishedOwnerEvidence>, HostError> {
        owner_name(identifier)?;
        let Some((_, evidence)) = self.read(identifier, budget)? else {
            return Ok(None);
        };
        Ok((evidence.state == State::Ready
            || evidence.ephemeral.is_some()
            || evidence.cache.is_some())
        .then(|| PublishedOwnerEvidence {
            identifier: identifier.into(),
            evidence,
            root_identity: self.recovery_root.identity(),
        }))
    }

    /// A bounded identity lookup for preliminary metadata discovery. This never
    /// grants permission to remove the directory and never opens a replacement.
    pub fn locate_published(
        &self,
        published: &PublishedOwnerEvidence,
        budget: &IoBudget,
    ) -> Result<Option<HeldDirectory>, HostError> {
        if published.root_identity != self.recovery_root.identity() {
            return Err(HostError::InvalidEvidence);
        }
        self.locate(&published.evidence, budget)
    }

    /// Restricted to this isolated namespace's `.ready/session-UUID` convention.
    /// Engine supplies the exclusive key lease matching the decoded metadata.
    /// Entry and owner leases are acquired without waiting or creating a lock.
    /// A held metadata snapshot is rechecked after both acquisitions, preventing
    /// the key used for discovery from drifting before disposal.
    pub fn recover_ephemeral_ready(
        &self,
        published: &PublishedOwnerEvidence,
        key_lease: &Lease,
        metadata: Option<&HeldFile>,
        budget: &IoBudget,
    ) -> Result<OwnerRecoveryOutcome, HostError> {
        budget.check()?;
        let binding = published.evidence.ephemeral.as_ref();
        let session = match binding {
            Some(binding) => binding.session_identifier.as_str(),
            None => published
                .evidence
                .relative_path
                .strip_prefix(".ready/")
                .filter(|v| v.starts_with("session-"))
                .ok_or(HostError::InvalidEvidence)?,
        };
        owner_name(session).map_err(|_| HostError::InvalidEvidence)?;
        let locks = self.recovery_root.open_private_child(".locks")?;
        if published.root_identity != self.recovery_root.identity()
            || !published.identifier.starts_with("entry-")
            || key_lease.mode != LeaseMode::Exclusive
            || key_lease.parent.identity() != locks.identity()
            || !key_lease.name.as_bytes().ends_with(b".lock")
            || binding.is_some_and(|b| {
                key_lease.name.as_bytes() != format!("{}.lock", b.key_identifier).as_bytes()
            })
            || (published.requires_metadata() && metadata.is_none())
        {
            return Err(HostError::InvalidEvidence);
        }
        key_lease.revalidate()?;
        if let Some(metadata) = metadata {
            if Some(metadata.parent.identity()) != published.evidence.identity()
                || metadata.name.as_bytes() != b"metadata.json"
            {
                return Err(HostError::InvalidEvidence);
            }
            metadata.verify()?;
        }
        let leases = self.recovery_root.open_private_child(".leases")?;
        let entry_lease = match Lease::try_acquire(
            &leases,
            &format!("{session}.lease"),
            LeaseMode::Exclusive,
            false,
        ) {
            Ok(Some(lease)) => {
                if binding.is_some_and(|binding| binding.lease_identity() != lease.identity) {
                    return Err(HostError::IdentityMismatch);
                }
                Some(lease)
            }
            Ok(None) => return Ok(OwnerRecoveryOutcome::Active),
            Err(HostError::NotFound)
                if published.evidence.state == State::Removed && binding.is_some() =>
            {
                None
            }
            Err(error) => return Err(error),
        };
        let owner_lease = match Lease::try_acquire(
            &self.owners,
            &format!("{}.lock", published.identifier),
            LeaseMode::Exclusive,
            false,
        )? {
            Some(lease) => lease,
            None => return Ok(OwnerRecoveryOutcome::Active),
        };
        let Some((record, evidence)) = self.read(&published.identifier, budget)? else {
            return Ok(OwnerRecoveryOutcome::IdentityUnresolved);
        };
        if evidence != published.evidence {
            return Err(HostError::InvalidEvidence);
        }
        let directory = self.locate(&evidence, budget)?;
        key_lease.revalidate()?;
        if let Some(entry) = &entry_lease {
            entry.revalidate()?;
        }
        if let Some(metadata) = metadata {
            metadata.verify()?;
        }
        record.verify()?;
        if evidence.state == State::Removed {
            if directory.is_some() {
                return Ok(OwnerRecoveryOutcome::IdentityUnresolved);
            }
            budget.check()?;
            if let Some(entry) = &entry_lease {
                leases.remove_owned_component(&entry.name, entry.identity)?;
                leases.sync()?;
            }
            self.remove_artifacts(&published.identifier, &owner_lease, budget)?;
            return Ok(OwnerRecoveryOutcome::Removed);
        }
        let Some(directory) = directory else {
            return Ok(OwnerRecoveryOutcome::IdentityUnresolved);
        };
        let mut owned = OwnedDirectory {
            store: self.clone(),
            identifier: published.identifier.clone(),
            directory,
            lease: owner_lease,
            removed: false,
        };
        owned.cleanup(budget)?;
        key_lease.revalidate()?;
        let entry = entry_lease.as_ref().ok_or(HostError::InvalidEvidence)?;
        entry.revalidate()?;
        budget.check()?;
        leases.remove_owned_component(&entry.name, entry.identity)?;
        leases.sync()?;
        if binding.is_some() {
            self.remove_artifacts(&published.identifier, &owned.lease, budget)?;
        }
        Ok(OwnerRecoveryOutcome::Removed)
    }
}

impl OwnedDirectory {
    pub fn identifier(&self) -> &str {
        &self.identifier
    }
    pub fn directory(&self) -> &HeldDirectory {
        &self.directory
    }
    pub fn bind_cached(
        &mut self,
        key: &Lease,
        entry: &Lease,
        entry_relative_path: &str,
        budget: &IoBudget,
    ) -> Result<(), HostError> {
        let key_identifier = key
            .name
            .to_str()
            .map_err(|_| HostError::InvalidEvidence)?
            .strip_suffix(".lock")
            .ok_or(HostError::InvalidEvidence)?
            .to_owned();
        let binding = CacheBinding {
            key_identifier,
            entry_relative_path: entry_relative_path.into(),
            lease_device: entry.identity.device,
            lease_inode: entry.identity.inode,
        };
        binding.validate()?;
        let (record, mut evidence) = self
            .store
            .read(&self.identifier, budget)?
            .ok_or(HostError::InvalidEvidence)?;
        if self.removed
            || evidence.state != State::Building
            || evidence.identity() != Some(self.directory.identity())
            || evidence.ephemeral.is_some()
            || evidence.cache.is_some()
        {
            return Err(HostError::InvalidEvidence);
        }
        evidence.format_version = 4;
        evidence.cache = Some(binding);
        self.store.cache_authority(&evidence, key, entry, true)?;
        self.store.write(
            &self.identifier,
            &self.lease,
            &evidence,
            Some(&record),
            budget,
        )
    }
    pub fn prepare_cached_publication(
        &mut self,
        destination: &HeldDirectory,
        name: &str,
        key: &Lease,
        entry: &Lease,
        budget: &IoBudget,
    ) -> Result<(), HostError> {
        let (record, mut evidence) = self
            .store
            .read(&self.identifier, budget)?
            .ok_or(HostError::InvalidEvidence)?;
        self.store.cache_authority(&evidence, key, entry, true)?;
        if self.removed
            || evidence.state != State::Building
            || evidence.identity() != Some(self.directory.identity())
            || format!(
                "{}/{}",
                relative(&self.store.recovery_root, destination)?,
                name
            ) != evidence
                .cache
                .as_ref()
                .ok_or(HostError::InvalidEvidence)?
                .entry_relative_path
        {
            return Err(HostError::InvalidEvidence);
        }
        evidence.state = State::Publishing;
        evidence.relative_path = evidence
            .cache
            .as_ref()
            .ok_or(HostError::InvalidEvidence)?
            .entry_relative_path
            .clone();
        self.store.write(
            &self.identifier,
            &self.lease,
            &evidence,
            Some(&record),
            budget,
        )
    }
    pub fn cleanup_cached(
        &mut self,
        key: &Lease,
        entry: &Lease,
        budget: &IoBudget,
    ) -> Result<(), HostError> {
        if self.removed {
            return Ok(());
        }
        let (_, evidence) = self
            .store
            .read(&self.identifier, budget)?
            .ok_or(HostError::InvalidEvidence)?;
        if evidence.cache.is_none() && evidence.ephemeral.is_none() {
            // Binding may have failed on cancellation after generic creation.
            // The live owner still authorizes disposal of its unbound staging.
            return self.cleanup(budget);
        }
        self.store.cache_authority(&evidence, key, entry, true)?;
        if evidence.identity() != Some(self.directory.identity()) {
            return Err(HostError::InvalidEvidence);
        }
        self.directory = self
            .store
            .locate(&evidence, budget)?
            .ok_or(HostError::CleanupFailed)?;
        self.cleanup_live(budget)
    }
    /// Persist the actual fresh lease identity and key before any publication.
    /// This upgrades only the bound entry record; old format-2 records remain.
    pub fn bind_ephemeral(
        &mut self,
        entry: &super::EphemeralLease,
        key: &Lease,
        budget: &IoBudget,
    ) -> Result<(), HostError> {
        let locks = self.store.recovery_root.open_private_child(".locks")?;
        let leases = self.store.recovery_root.open_private_child(".leases")?;
        if self.removed
            || key.mode != LeaseMode::Exclusive
            || key.parent.identity() != locks.identity()
            || entry.0.parent.identity() != leases.identity()
            || !entry.0.newly_created
            || entry.0.mode != LeaseMode::Exclusive
        {
            return Err(HostError::InvalidEvidence);
        }
        key.revalidate()?;
        entry.revalidate()?;
        let binding = EphemeralBinding {
            key_identifier: key
                .name
                .to_str()
                .map_err(|_| HostError::InvalidEvidence)?
                .strip_suffix(".lock")
                .ok_or(HostError::InvalidEvidence)?
                .into(),
            session_identifier: entry
                .0
                .name
                .to_str()
                .map_err(|_| HostError::InvalidEvidence)?
                .strip_suffix(".lease")
                .ok_or(HostError::InvalidEvidence)?
                .into(),
            lease_device: entry.0.identity.device,
            lease_inode: entry.0.identity.inode,
        };
        binding.validate()?;
        let (record, mut evidence) = self
            .store
            .read(&self.identifier, budget)?
            .ok_or(HostError::InvalidEvidence)?;
        if evidence.state != State::Building
            || evidence.identity() != Some(self.directory.identity())
            || evidence.ephemeral.is_some()
            || evidence.cache.is_some()
        {
            return Err(HostError::InvalidEvidence);
        }
        evidence.format_version = 3;
        evidence.ephemeral = Some(binding);
        self.store.write(
            &self.identifier,
            &self.lease,
            &evidence,
            Some(&record),
            budget,
        )
    }

    /// Durable intent precedes rename. Recovery searches for the same identity
    /// whether the atomic rename happened or the candidate is still staging.
    pub fn prepare_ephemeral_publication(
        &mut self,
        destination: &HeldDirectory,
        name: &str,
        budget: &IoBudget,
    ) -> Result<(), HostError> {
        let (record, mut evidence) = self
            .store
            .read(&self.identifier, budget)?
            .ok_or(HostError::InvalidEvidence)?;
        let binding = evidence
            .ephemeral
            .as_ref()
            .ok_or(HostError::InvalidEvidence)?;
        if evidence.state != State::Building
            || evidence.identity() != Some(self.directory.identity())
            || relative(&self.store.recovery_root, destination)? != ".ready"
            || name != binding.session_identifier
        {
            return Err(HostError::InvalidEvidence);
        }
        evidence.state = State::Publishing;
        evidence.relative_path = format!(".ready/{name}");
        self.store.write(
            &self.identifier,
            &self.lease,
            &evidence,
            Some(&record),
            budget,
        )?;
        Ok(())
    }

    /// After the durable Removed tombstone, unlink the exact bound ephemeral
    /// lease before erasing owner proof. A crash between these operations can be
    /// retried without metadata or a pathname ownership guess.
    pub fn finish_ephemeral_cleanup(
        &mut self,
        entry: super::EphemeralLease,
        budget: &IoBudget,
    ) -> Result<(), HostError> {
        if !self.removed {
            return Err(HostError::InvalidEvidence);
        }
        let Some((_, evidence)) = self.store.read(&self.identifier, budget)? else {
            // A successful legacy cleanup has already erased its artifacts.
            // The caller still owns the fresh O_EXCL ephemeral lease.
            return entry.remove();
        };
        let binding = evidence
            .ephemeral
            .as_ref()
            .ok_or(HostError::InvalidEvidence)?;
        if !self.removed
            || evidence.state != State::Removed
            || binding.lease_identity() != entry.0.identity
            || entry.0.name.as_bytes() != format!("{}.lease", binding.session_identifier).as_bytes()
        {
            return Err(HostError::InvalidEvidence);
        }
        self.lease.revalidate()?;
        entry.revalidate()?;
        budget.check()?;
        entry.remove()?;
        self.store
            .remove_artifacts(&self.identifier, &self.lease, budget)
    }
    /// Called after caller-validated atomic directory promotion, before Ready
    /// handoff. Records ownership location, not database/schema acceptance.
    pub fn record_published_location(
        &mut self,
        directory: &HeldDirectory,
        budget: &IoBudget,
    ) -> Result<(), HostError> {
        if self.removed || directory.identity() != self.directory.identity() {
            return Err(HostError::IdentityMismatch);
        }
        let relative_path = relative(&self.store.recovery_root, directory)?;
        let (record, mut evidence) = self
            .store
            .read(&self.identifier, budget)?
            .ok_or(HostError::InvalidEvidence)?;
        if evidence.identity() != Some(self.directory.identity())
            || !matches!(
                evidence.state,
                State::Building | State::Publishing | State::Ready
            )
        {
            return Err(HostError::InvalidEvidence);
        }
        self.directory = directory.clone();
        evidence.state = State::Ready;
        evidence.relative_path = relative_path;
        self.store.write(
            &self.identifier,
            &self.lease,
            &evidence,
            Some(&record),
            budget,
        )
    }
    pub fn cleanup(&mut self, budget: &IoBudget) -> Result<(), HostError> {
        if self.removed {
            return Ok(());
        }
        let (_, evidence) = self
            .store
            .read(&self.identifier, budget)?
            .ok_or(HostError::InvalidEvidence)?;
        if evidence.cache.is_some() {
            return Err(HostError::InvalidEvidence);
        }
        if evidence.identity() != Some(self.directory.identity()) {
            return Err(HostError::InvalidEvidence);
        }
        self.directory = self
            .store
            .locate(&evidence, budget)?
            .ok_or(HostError::CleanupFailed)?;
        self.cleanup_live(budget)
    }
    fn cleanup_live(&mut self, budget: &IoBudget) -> Result<(), HostError> {
        self.lease.revalidate()?;
        budget.check()?;
        if self.directory.revalidate().is_err() {
            let (_, mut evidence) = self
                .store
                .read(&self.identifier, budget)?
                .ok_or(HostError::InvalidEvidence)?;
            if evidence
                .identity()
                .is_some_and(|identity| identity != self.directory.identity())
            {
                return Err(HostError::InvalidEvidence);
            }
            // A live first-open descriptor can resolve a move even if persisting
            // the bound record failed. Recovery after death has no such authority.
            evidence.state = State::Building;
            evidence.device = Some(self.directory.identity().device);
            evidence.inode = Some(self.directory.identity().inode);
            self.directory = self
                .store
                .locate(&evidence, budget)?
                .ok_or(HostError::CleanupFailed)?;
        }
        let identity = self.directory.identity();
        let parent = HeldDirectory(
            self.directory
                .0
                .parent
                .clone()
                .ok_or(HostError::InvalidPath)?,
        );
        // Darwin first renames the owned directory to a quarantine name. NTFS
        // refuses to rename a directory while any file below it is open (a
        // reader's metadata or database handle), whatever the share mode, so
        // Windows disposes in place: the Removing record keeps the bound
        // identity at its current location, which `locate` resolves after a
        // crash without any name being ownership evidence.
        let original = self.directory.0.name.clone();
        let (record, previous) = self
            .store
            .read(&self.identifier, budget)?
            .ok_or(HostError::InvalidEvidence)?;
        let mut evidence = Evidence {
            format_version: previous.format_version,
            state: State::Removing,
            device: Some(identity.device),
            inode: Some(identity.inode),
            relative_path: relative(&self.store.recovery_root, &self.directory)?,
            ephemeral: previous.ephemeral,
            cache: previous.cache,
        };
        self.store.write(
            &self.identifier,
            &self.lease,
            &evidence,
            Some(&record),
            budget,
        )?;
        let mut remaining = ENTRY_LIMIT;
        remove_contents(&self.directory, budget, 0, &mut remaining)?;
        self.directory.revalidate()?;
        parent.revalidate()?;
        // Empty identity-checked directory in the held private parent only;
        // the check and the POSIX delete share one handle.
        remove_child(&parent.0.file, &original, identity, true)?;
        parent.sync()?;
        evidence.state = State::Removed;
        let (record, _) = self
            .store
            .read(&self.identifier, budget)?
            .ok_or(HostError::InvalidEvidence)?;
        self.store.write(
            &self.identifier,
            &self.lease,
            &evidence,
            Some(&record),
            budget,
        )?;
        if evidence.ephemeral.is_none() {
            self.store
                .remove_artifacts(&self.identifier, &self.lease, budget)?;
        }
        self.removed = true;
        Ok(())
    }
}

fn remove_contents(
    directory: &HeldDirectory,
    budget: &IoBudget,
    depth: usize,
    remaining: &mut usize,
) -> Result<(), HostError> {
    if depth >= DEPTH_LIMIT {
        return Err(HostError::LimitExceeded);
    }
    for name in names_bounded(directory, budget, *remaining)? {
        budget.check()?;
        *remaining = remaining.checked_sub(1).ok_or(HostError::LimitExceeded)?;
        directory.revalidate()?;
        let before = stat_child(&directory.0.file, &name)?;
        let identity = before.identity()?;
        let is_directory = before.is_dir();
        if is_directory {
            let child = directory.open_child(&name, true, true)?;
            if child.identity() != identity {
                return Err(HostError::CleanupFailed);
            }
            remove_contents(&child, budget, depth + 1, remaining)?;
            child.revalidate()?;
        }
        directory.revalidate()?;
        // In place: the identity check and the POSIX delete share one handle,
        // so a raced replacement is never removed (no quarantine rename is
        // needed, and a directory with open readers below it could not be
        // renamed). A reparse point is never followed or removed; it fails.
        remove_child(&directory.0.file, &name, identity, is_directory)?;
    }
    directory.sync()
}

#[cfg(test)]
#[path = "windows_owner_tests.rs"]
mod tests;
