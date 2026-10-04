//! Fixed-root maintenance of the isolated format-4 Rust cache. Inventory is a
//! bounded observation; deletion separately proves key, entry and owner leases.
use crate::{CacheMetadata, EngineError, EngineFailure, EngineStage};
use arktrace_contract::TraceCacheKey;
use arktrace_platform::{
    HeldDirectory, HostError, IoBudget, Lease, LeaseMode, OwnerRecoveryOutcome, OwnerStore,
    PublishedOwnerEvidence,
};
use serde::Serialize;
use std::collections::HashMap;

fn host(error: HostError) -> EngineError {
    EngineError {
        stage: EngineStage::CacheLookup,
        failure: EngineFailure::Host(error),
    }
}
fn invalid() -> EngineError {
    EngineError {
        stage: EngineStage::CacheLookup,
        failure: EngineFailure::InvalidBudget,
    }
}
fn digest(name: &str) -> bool {
    name.len() == 64
        && name
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CacheWatermarks {
    pub high_bytes: i64,
    pub low_bytes: i64,
}
impl CacheWatermarks {
    pub const STANDARD: Self = Self {
        high_bytes: 20 * 1024 * 1024 * 1024,
        low_bytes: 16 * 1024 * 1024 * 1024,
    };
    pub fn new(high_bytes: i64, low_bytes: i64) -> Result<Self, EngineError> {
        if high_bytes <= 0 || low_bytes < 0 || low_bytes >= high_bytes {
            return Err(invalid());
        }
        Ok(Self {
            high_bytes,
            low_bytes,
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CacheInventory {
    pub entry_count: usize,
    pub total_byte_count: i64,
    pub active_entry_count: usize,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CacheMaintenanceReport {
    pub before: CacheInventory,
    pub after: CacheInventory,
    pub recovered_private_directory_count: usize,
    pub removed_orphan_owner_marker_count: usize,
    pub removed_entry_count: usize,
    /// Preserves the existing public name. Includes missing/invalid owner
    /// authority as well as a contended key, entry or owner lease.
    pub skipped_active_entry_count: usize,
}

struct Entry {
    trace: String,
    parser: String,
    directory: HeldDirectory,
    bytes: i64,
    metadata: Option<CacheMetadata>,
}
impl Entry {
    fn key(&self) -> Option<&TraceCacheKey> {
        self.metadata.as_ref().map(|m| &m.cache_key)
    }
    fn last_accessed(&self) -> Option<&str> {
        self.metadata.as_ref().map(|m| m.last_accessed_at.as_str())
    }
    fn relative(&self) -> String {
        format!("{}/{}", self.trace, self.parser)
    }
}

/// The caller fixes a held private cache root and enumeration bound once.
/// Requests cannot supply a target path. This never opens original trace files.
pub struct CacheMaintenance {
    root: HeldDirectory,
    maximum_entries: usize,
}
impl CacheMaintenance {
    pub fn new(root: HeldDirectory, maximum_entries: usize) -> Result<Self, EngineError> {
        if !(1..=65_536).contains(&maximum_entries) {
            return Err(invalid());
        }
        root.revalidate().map_err(host)?;
        Ok(Self {
            root,
            maximum_entries,
        })
    }

    fn entries(&self, budget: &IoBudget) -> Result<Vec<Entry>, EngineError> {
        let mut result = Vec::new();
        for trace in self
            .root
            .child_names(budget, self.maximum_entries)
            .map_err(host)?
        {
            let Some(trace) = trace.to_str().filter(|n| digest(n)) else {
                continue;
            };
            let Some(trace_root) = self.root.find_private_child(trace).map_err(host)? else {
                continue;
            };
            let remaining = self.maximum_entries - result.len();
            if remaining == 0 {
                return Err(host(HostError::LimitExceeded));
            }
            for parser in trace_root.child_names(budget, remaining).map_err(host)? {
                let Some(parser) = parser.to_str().filter(|n| digest(n)) else {
                    continue;
                };
                let Some(directory) = trace_root.find_private_child(parser).map_err(host)? else {
                    continue;
                };
                let mut bytes = 0_i64;
                for name in directory.child_names(budget, 16).map_err(host)? {
                    budget.check().map_err(host)?;
                    let file = directory
                        .open_file(name.to_str().ok_or_else(|| host(HostError::InvalidPath))?)
                        .map_err(host)?;
                    file.verify().map_err(host)?;
                    let size = i64::try_from(file.snapshot().byte_count)
                        .map_err(|_| host(HostError::LimitExceeded))?;
                    bytes = bytes
                        .checked_add(size)
                        .ok_or_else(|| host(HostError::LimitExceeded))?;
                }
                let metadata = self.metadata(&directory, trace, parser, budget)?;
                result.push(Entry {
                    trace: trace.into(),
                    parser: parser.into(),
                    directory,
                    bytes,
                    metadata,
                });
            }
        }
        budget.check().map_err(host)?;
        Ok(result)
    }

    fn metadata(
        &self,
        directory: &HeldDirectory,
        trace: &str,
        parser: &str,
        budget: &IoBudget,
    ) -> Result<Option<CacheMetadata>, EngineError> {
        budget.check().map_err(host)?;
        let bounded = IoBudget {
            maximum_bytes: crate::metadata::MAXIMUM_METADATA_BYTES as u64,
            deadline: budget.deadline,
            cancellation: budget.cancellation.clone(),
        };
        let loaded = (|| {
            let bytes = directory
                .open_file("metadata.json")?
                .read_bounded(&bounded)?;
            let m = CacheMetadata::decode(&bytes).map_err(|_| HostError::InvalidEvidence)?;
            let database = directory.open_file("trace.sqlite")?;
            database.verify()?;
            if m.cache_key.trace_sha256() != trace
                || m.cache_key.parser_key() != parser
                || u64::try_from(m.database_byte_count).ok() != Some(database.snapshot().byte_count)
            {
                return Err(HostError::InvalidEvidence);
            }
            Ok(m)
        })();
        match loaded {
            Ok(m) => Ok(Some(m)),
            Err(e @ (HostError::Cancelled | HostError::DeadlineExceeded)) => Err(host(e)),
            Err(_) => {
                budget.check().map_err(host)?;
                Ok(None)
            }
        }
    }

    fn leases(&self, key: &TraceCacheKey) -> Result<Option<(Lease, Lease)>, EngineError> {
        match self.leases_by_identifier(&key.entry_identifier()) {
            Err(EngineError {
                failure: EngineFailure::Host(HostError::NotFound),
                ..
            }) => Ok(None),
            result => result,
        }
    }
    fn leases_by_identifier(
        &self,
        identifier: &str,
    ) -> Result<Option<(Lease, Lease)>, EngineError> {
        let locks = self.root.open_private_child(".locks").map_err(host)?;
        let active = self.root.open_private_child(".leases").map_err(host)?;
        let Some(lock) = Lease::try_acquire(
            &locks,
            &format!("{identifier}.lock"),
            LeaseMode::Exclusive,
            false,
        )
        .map_err(host)?
        else {
            return Ok(None);
        };
        let Some(lease) = Lease::try_acquire(
            &active,
            &format!("{identifier}.lease"),
            LeaseMode::Exclusive,
            false,
        )
        .map_err(host)?
        else {
            return Ok(None);
        };
        Ok(Some((lock, lease)))
    }

    pub fn inventory(&self, budget: &IoBudget) -> Result<CacheInventory, EngineError> {
        let entries = self.entries(budget)?;
        let mut total = 0_i64;
        let mut active = 0;
        for entry in &entries {
            budget.check().map_err(host)?;
            total = total
                .checked_add(entry.bytes)
                .ok_or_else(|| host(HostError::LimitExceeded))?;
            if let Some(key) = entry.key() {
                if self.leases(key)?.is_none() {
                    active += 1;
                }
            } else {
                active += 1;
            }
        }
        budget.check().map_err(host)?;
        Ok(CacheInventory {
            entry_count: entries.len(),
            total_byte_count: total,
            active_entry_count: active,
        })
    }

    fn owners(&self) -> Result<OwnerStore, EngineError> {
        let stage = self.root.ensure_private_child(".staging").map_err(host)?;
        OwnerStore::open(&stage, &self.root).map_err(host)
    }

    fn identifiers(
        &self,
        owners: &OwnerStore,
        budget: &IoBudget,
    ) -> Result<Vec<String>, EngineError> {
        let ids = owners
            .identifiers_bounded(budget, self.maximum_entries * 3)
            .map_err(host)?;
        if ids.len() > self.maximum_entries {
            return Err(host(HostError::LimitExceeded));
        }
        Ok(ids)
    }

    fn recover(
        &self,
        owners: &OwnerStore,
        budget: &IoBudget,
    ) -> Result<(usize, usize), EngineError> {
        let mut count = 0;
        for id in self.identifiers(owners, budget)? {
            budget.check().map_err(host)?;
            match owners.published_evidence(&id, budget).map_err(host)? {
                None => {
                    if owners.recover_stale(&id, budget).map_err(host)?
                        == OwnerRecoveryOutcome::Removed
                    {
                        count += 1;
                    }
                }
                Some(record)
                    if record.is_cached() && !record.is_ready() && !record.is_quarantined() =>
                {
                    let identifier = record
                        .key_identifier()
                        .ok_or_else(|| host(HostError::InvalidEvidence))?;
                    let leases = match self.leases_by_identifier(identifier) {
                        Ok(Some(v)) => v,
                        Ok(None) => continue,
                        Err(EngineError {
                            failure: EngineFailure::Host(HostError::NotFound),
                            ..
                        }) => continue,
                        Err(e) => return Err(e),
                    };
                    let present = owners
                        .locate_published(&record, budget)
                        .map_err(host)?
                        .is_some();
                    match owners.recover_cached_build(&record, &leases.0, &leases.1, budget) {
                        Ok(OwnerRecoveryOutcome::Removed) if present => count += 1,
                        Ok(_)
                        | Err(
                            HostError::Busy
                            | HostError::InvalidEvidence
                            | HostError::IdentityMismatch
                            | HostError::NotFound,
                        ) => (),
                        Err(e) => return Err(host(e)),
                    }
                }
                Some(_) => (),
            }
        }
        let orphan = owners
            .recover_orphan_markers(budget, self.maximum_entries * 3)
            .map_err(host)?;
        Ok((count, orphan))
    }

    pub fn maintain(
        &self,
        watermarks: CacheWatermarks,
        budget: &IoBudget,
    ) -> Result<CacheMaintenanceReport, EngineError> {
        CacheWatermarks::new(watermarks.high_bytes, watermarks.low_bytes)?;
        self.evict(watermarks.low_bytes, watermarks.high_bytes, budget)
    }
    pub fn purge_unused(&self, budget: &IoBudget) -> Result<CacheMaintenanceReport, EngineError> {
        self.evict(0, 0, budget)
    }

    fn evict(
        &self,
        target: i64,
        threshold: i64,
        budget: &IoBudget,
    ) -> Result<CacheMaintenanceReport, EngineError> {
        budget.check().map_err(host)?;
        let owners = self.owners()?;
        let (recovered, orphan) = self.recover(&owners, budget)?;
        let before = self.inventory(budget)?;
        let mut report = CacheMaintenanceReport {
            before,
            after: before,
            recovered_private_directory_count: recovered,
            removed_orphan_owner_marker_count: orphan,
            removed_entry_count: 0,
            skipped_active_entry_count: 0,
        };
        if before.total_byte_count <= threshold {
            return Ok(report);
        }
        let mut entries = self.entries(budget)?;
        entries.sort_by(|a, b| {
            match (a.last_accessed(), b.last_accessed()) {
                (Some(a), Some(b)) => a.cmp(b),
                (Some(_), None) => std::cmp::Ordering::Less,
                (None, Some(_)) => std::cmp::Ordering::Greater,
                (None, None) => std::cmp::Ordering::Equal,
            }
            .then_with(|| a.trace.cmp(&b.trace))
            .then_with(|| a.parser.cmp(&b.parser))
        });
        let mut records = HashMap::<String, Vec<PublishedOwnerEvidence>>::new();
        for id in self.identifiers(&owners, budget)? {
            if let Some(r) = owners.published_evidence(&id, budget).map_err(host)?
                && r.is_cached()
                && (r.is_ready() || r.is_publishing())
            {
                let identifier = r
                    .key_identifier()
                    .ok_or_else(|| host(HostError::InvalidEvidence))?
                    .to_owned();
                records.entry(identifier).or_default().push(r);
            }
        }
        let mut remaining = before.total_byte_count;
        for entry in entries {
            if remaining <= target {
                break;
            }
            budget.check().map_err(host)?;
            let Some(key) = entry.key() else {
                report.skipped_active_entry_count += 1;
                continue;
            };
            let Some((lock, lease)) = self.leases(key)? else {
                report.skipped_active_entry_count += 1;
                continue;
            };
            let relative = entry.relative();
            let matching = records
                .get(&key.entry_identifier())
                .into_iter()
                .flatten()
                .filter(|r| {
                    r.cached_entry_relative_path() == Some(relative.as_str())
                        && r.directory_identity() == Some(entry.directory.identity())
                })
                .collect::<Vec<_>>();
            if matching.len() != 1 || entry.directory.revalidate().is_err() {
                report.skipped_active_entry_count += 1;
                continue;
            }
            // A future/invalid document installed since enumeration cannot be
            // erased using stale metadata, even when the directory is unchanged.
            if !self
                .metadata(&entry.directory, &entry.trace, &entry.parser, budget)?
                .is_some_and(|m| m.cache_key == *key)
            {
                report.skipped_active_entry_count += 1;
                continue;
            }
            match owners.purge_cached_ready(
                matching[0],
                entry.directory.identity(),
                &lock,
                &lease,
                budget,
            ) {
                Ok(()) => {
                    report.removed_entry_count += 1;
                    remaining = remaining.saturating_sub(entry.bytes).max(0);
                }
                Err(
                    HostError::Busy
                    | HostError::InvalidEvidence
                    | HostError::IdentityMismatch
                    | HostError::NotFound,
                ) => report.skipped_active_entry_count += 1,
                Err(e) => return Err(host(e)),
            }
        }
        report.after = self.inventory(budget)?;
        Ok(report)
    }
}
