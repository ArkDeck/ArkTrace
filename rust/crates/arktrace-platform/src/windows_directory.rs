//! Flat, sealed staging directory publication. Payload names/bytes are private;
//! the caller must separately prove the Trace schema, metadata and owner lease.
use super::{FileSnapshot, HeldDirectory, component, list_names, rename_entry, stat_child};
use crate::{HostError, IoBudget};
use std::ffi::{CString, OsStr};

const MAXIMUM_FILES: usize = 64;

fn directory_snapshot(directory: &HeldDirectory) -> Result<FileSnapshot, HostError> {
    directory.revalidate()?;
    FileSnapshot::of(&directory.0.file)
}

fn names(directory: &HeldDirectory, budget: &IoBudget) -> Result<Vec<CString>, HostError> {
    names_bounded(directory, budget, MAXIMUM_FILES)
}

pub(super) fn names_bounded(
    directory: &HeldDirectory,
    budget: &IoBudget,
    maximum_files: usize,
) -> Result<Vec<CString>, HostError> {
    budget.check()?;
    directory.revalidate()?;
    let mut names = list_names(&directory.0.file, maximum_files)?;
    budget.check()?;
    names.sort_unstable_by(|left, right| left.as_bytes().cmp(right.as_bytes()));
    if names.windows(2).any(|pair| pair[0] == pair[1]) {
        return Err(HostError::Changed);
    }
    directory.revalidate()?;
    Ok(names)
}

/// A frozen member. NTFS refuses to rename a directory while any file below
/// it is open, whatever the share mode, so unlike Darwin no member handle is
/// retained: every verification rebinds the name and requires the frozen
/// identity, full snapshot and digest.
struct Seal {
    name: CString,
    initial: FileSnapshot,
    sha256: String,
}
enum PayloadCheck {
    Metadata,
    Digest,
}
pub struct SealedDirectory {
    directory: HeldDirectory,
    snapshot: FileSnapshot,
    files: Vec<Seal>,
    byte_count: u64,
}
impl SealedDirectory {
    pub fn directory(&self) -> &HeldDirectory {
        &self.directory
    }
    pub fn byte_count(&self) -> u64 {
        self.byte_count
    }
    pub fn file_count(&self) -> usize {
        self.files.len()
    }

    pub fn verify(&self, budget: &IoBudget) -> Result<(), HostError> {
        self.verify_at(&self.directory, budget, false, PayloadCheck::Digest)
    }

    fn verify_at(
        &self,
        directory: &HeldDirectory,
        budget: &IoBudget,
        renamed: bool,
        payload_check: PayloadCheck,
    ) -> Result<(), HostError> {
        budget.check()?;
        if self.byte_count > budget.maximum_bytes {
            return Err(HostError::LimitExceeded);
        }
        let actual = directory_snapshot(directory)?;
        let mut expected = self.snapshot;
        if renamed {
            expected.change = actual.change;
        }
        if actual != expected {
            return Err(HostError::Changed);
        }
        let members = names(directory, budget)?;
        if members.len() != self.files.len()
            || members
                .iter()
                .zip(&self.files)
                .any(|(name, seal)| *name != seal.name)
        {
            return Err(HostError::Changed);
        }
        for seal in &self.files {
            budget.check()?;
            // Parent binding changed on promotion; open through the new held
            // parent and require the original full file metadata and digest.
            // The handle is released at the end of this iteration.
            let file = directory.open_file_component(seal.name.clone(), true)?;
            if file.initial != seal.initial {
                return Err(HostError::Changed);
            }
            match payload_check {
                PayloadCheck::Digest if file.facts(budget)?.sha256 != seal.sha256 => {
                    return Err(HostError::Changed);
                }
                _ => file.verify()?,
            }
        }
        if directory_snapshot(directory)? != actual {
            return Err(HostError::Changed);
        }
        budget.check()
    }
}

impl HeldDirectory {
    /// Freeze all direct child names, metadata and bytes. Reject links, nested
    /// directories, writable payload files, >64 members and aggregate IO excess.
    /// This validates existing security without changing it.
    pub fn seal_readonly_directory(&self, budget: &IoBudget) -> Result<SealedDirectory, HostError> {
        if !self.0.private {
            return Err(HostError::NotPrivate);
        }
        let snapshot = directory_snapshot(self)?;
        let mut files = Vec::new();
        let mut byte_count = 0_u64;
        for name in names(self, budget)? {
            let file = self.open_file_component(name, true)?;
            file.require_readonly()?;
            byte_count = byte_count
                .checked_add(file.initial.byte_count)
                .ok_or(HostError::LimitExceeded)?;
            if byte_count > budget.maximum_bytes {
                return Err(HostError::LimitExceeded);
            }
            // Sealed files were flushed before their DACL dropped write access.
            let facts = file.facts(budget)?;
            files.push(Seal {
                name: file.name.clone(),
                initial: file.initial,
                sha256: facts.sha256,
            });
        }
        self.sync()?;
        let sealed = SealedDirectory {
            directory: self.clone(),
            snapshot,
            files,
            byte_count,
        };
        sealed.verify(budget)?;
        Ok(sealed)
    }

    pub fn promote_sealed_directory_noreplace(
        &self,
        candidate: &SealedDirectory,
        destination: &Self,
        name: &str,
        budget: &IoBudget,
    ) -> Result<Self, HostError> {
        let directory = &candidate.directory;
        if !self.0.private
            || !destination.0.private
            || directory.0.parent.as_ref().map(|p| p.identity) != Some(self.identity())
        {
            return Err(HostError::NotPrivate);
        }
        if self.identity().device != destination.identity().device {
            return Err(HostError::CrossVolume);
        }
        let name = component(OsStr::new(name))?;
        budget.check()?;
        candidate.verify(budget)?;
        destination.revalidate()?;
        budget.cancellation.publication(|| {
            budget.check_deadline()?;
            // Hash work stays outside the cancellation mutex. Frozen readonly
            // file metadata and membership must still match immediately before
            // the rename. A fresh token avoids recursive locking.
            let verification = IoBudget {
                cancellation: Default::default(),
                ..budget.clone()
            };
            candidate.verify_at(directory, &verification, false, PayloadCheck::Metadata)?;
            destination.revalidate()?;
            rename_entry(
                &self.0.file,
                &directory.0.name,
                &destination.0.file,
                &name,
                false,
            )
        })?;
        let result = (|| {
            self.sync()?;
            destination.sync()?;
            let ready = destination.open_child(&name, true, true)?;
            if ready.identity() != directory.identity() {
                return Err(HostError::IdentityMismatch);
            }
            candidate.verify_at(&ready, budget, true, PayloadCheck::Digest)?;
            Ok(ready)
        })();
        match result {
            Ok(ready) => Ok(ready),
            Err(error) => {
                // Restore the complete candidate; an identity mismatch or a
                // source-name collision is a cleanup failure that preserves both.
                let rollback = (|| {
                    self.revalidate()?;
                    destination.revalidate()?;
                    let linked = stat_child(&destination.0.file, &name)?;
                    if !linked.is_dir() || linked.identity()? != directory.identity() {
                        return Err(HostError::IdentityMismatch);
                    }
                    rename_entry(
                        &destination.0.file,
                        &name,
                        &self.0.file,
                        &directory.0.name,
                        false,
                    )?;
                    directory.revalidate()?;
                    self.sync()?;
                    destination.sync()
                })();
                rollback.map_err(|_| HostError::CleanupFailed)?;
                Err(error)
            }
        }
    }
}
