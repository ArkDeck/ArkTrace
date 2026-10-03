//! Flat, sealed staging directory publication. Payload names/bytes are private;
//! the caller must separately prove the Trace schema, metadata and owner lease.
use super::{
    FileSnapshot, HeldDirectory, HeldFile, component, from_io, os_error, stat_child, stat_identity,
};
use crate::{HostError, HostOperation, IoBudget};
use std::{
    ffi::{CString, OsStr},
    fs::File,
    os::{
        fd::{AsRawFd, FromRawFd, IntoRawFd},
        unix::ffi::OsStrExt,
    },
    ptr::NonNull,
};

const MAXIMUM_FILES: usize = 64;

struct Entries(NonNull<libc::DIR>);
impl Drop for Entries {
    fn drop(&mut self) {
        // SAFETY: fdopendir transferred one descriptor to this stream; closed once.
        unsafe { libc::closedir(self.0.as_ptr()) };
    }
}

fn directory_snapshot(directory: &HeldDirectory) -> Result<FileSnapshot, HostError> {
    directory.revalidate()?;
    Ok(FileSnapshot::metadata(
        &directory
            .0
            .file
            .metadata()
            .map_err(|error| from_io(error, HostOperation::Stat))?,
    ))
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
    // An independent open file description prevents readdir from changing a
    // held directory's cursor or making repeated membership checks miss files.
    // SAFETY: held directory, fixed dot component, no inherited descriptor.
    let fd = unsafe {
        libc::openat(
            directory.0.file.as_raw_fd(),
            c".".as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(os_error(HostOperation::Open));
    }
    // SAFETY: fresh descriptor returned by successful openat, transferred once.
    let file = unsafe { File::from_raw_fd(fd) };
    if FileSnapshot::metadata(
        &file
            .metadata()
            .map_err(|e| from_io(e, HostOperation::Stat))?,
    )
    .identity
        != directory.identity()
    {
        return Err(HostError::IdentityMismatch);
    }
    // SAFETY: live directory descriptor; fdopendir consumes it only on success.
    let stream = NonNull::new(unsafe { libc::fdopendir(file.as_raw_fd()) })
        .ok_or_else(|| os_error(HostOperation::Read))?;
    let _ = file.into_raw_fd();
    let entries = Entries(stream);
    let mut names = Vec::new();
    loop {
        budget.check()?;
        // SAFETY: this thread owns the directory stream and Darwin errno slot.
        unsafe { *libc::__error() = 0 };
        // SAFETY: live stream; output belongs to it until the next readdir call.
        let entry = unsafe { libc::readdir(entries.0.as_ptr()) };
        if entry.is_null() {
            if std::io::Error::last_os_error().raw_os_error() != Some(0) {
                return Err(os_error(HostOperation::Read));
            }
            break;
        }
        // SAFETY: readdir initialized d_namlen and its name. Xcode 27 dirent's
        // d_name has 1024 bytes; bound the length before borrowing these bytes.
        let length = unsafe { (*entry).d_namlen } as usize;
        if length == 0 || length >= 1024 {
            return Err(HostError::InvalidPath);
        }
        // SAFETY: only the initialized name bytes are read, within d_name.
        let bytes =
            unsafe { std::slice::from_raw_parts((*entry).d_name.as_ptr().cast::<u8>(), length) };
        if bytes == b"." || bytes == b".." {
            continue;
        }
        if names.len() == maximum_files {
            return Err(HostError::LimitExceeded);
        }
        names.push(component(OsStr::from_bytes(bytes))?);
    }
    names.sort_unstable_by(|left, right| left.as_bytes().cmp(right.as_bytes()));
    if names.windows(2).any(|pair| pair[0] == pair[1]) {
        return Err(HostError::Changed);
    }
    directory.revalidate()?;
    Ok(names)
}

struct Seal {
    file: HeldFile,
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
                .any(|(name, seal)| *name != seal.file.name)
        {
            return Err(HostError::Changed);
        }
        for seal in &self.files {
            budget.check()?;
            // Parent binding changed on promotion; open through the new held
            // parent and require the original full file metadata and digest.
            let file = directory.open_file_component(seal.file.name.clone(), true)?;
            if file.initial != seal.file.initial {
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
    /// This validates existing permissions without changing them.
    pub fn seal_readonly_directory(&self, budget: &IoBudget) -> Result<SealedDirectory, HostError> {
        if !self.0.private {
            return Err(HostError::NotPrivate);
        }
        let snapshot = directory_snapshot(self)?;
        let mut files = Vec::new();
        let mut byte_count = 0_u64;
        for name in names(self, budget)? {
            let file = self.open_file_component(name, true)?;
            if file.initial.mode & 0o222 != 0 {
                return Err(HostError::NotPrivate);
            }
            byte_count = byte_count
                .checked_add(file.initial.byte_count)
                .ok_or(HostError::LimitExceeded)?;
            if byte_count > budget.maximum_bytes {
                return Err(HostError::LimitExceeded);
            }
            file.file
                .sync_all()
                .map_err(|e| from_io(e, HostOperation::Sync))?;
            let facts = file.facts(budget)?;
            files.push(Seal {
                file,
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
        self.promote_directory_observed(candidate, destination, name, budget, || {}, || {})
    }

    pub(super) fn promote_directory_observed(
        &self,
        candidate: &SealedDirectory,
        destination: &Self,
        name: &str,
        budget: &IoBudget,
        before_publication: impl FnOnce(),
        after_publication: impl FnOnce(),
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
        before_publication();
        budget.cancellation.publication(|| {
            budget.check_deadline()?;
            // Hash work stays outside the cancellation mutex. Frozen readonly
            // file metadata (including ctime) and membership must still match
            // immediately before rename. A fresh token avoids recursive locking.
            let verification = IoBudget {
                cancellation: Default::default(),
                ..budget.clone()
            };
            candidate.verify_at(directory, &verification, false, PayloadCheck::Metadata)?;
            destination.revalidate()?;
            // SAFETY: owned held parents and verified child, same-volume atomic
            // no-replace rename. Never overwrite a file, directory or symlink.
            if unsafe {
                libc::renameatx_np(
                    self.0.file.as_raw_fd(),
                    directory.0.name.as_ptr(),
                    destination.0.file.as_raw_fd(),
                    name.as_ptr(),
                    libc::RENAME_EXCL,
                )
            } != 0
            {
                return Err(os_error(HostOperation::Rename));
            }
            Ok(())
        })?;
        after_publication();
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
                // Restore the complete candidate, not just one payload file.
                // Identity mismatch or source-name collision is cleanup failure;
                // preserve both unrelated replacement and relocated owned data.
                let rollback = (|| {
                    self.revalidate()?;
                    destination.revalidate()?;
                    let linked = stat_child(&destination.0.file, &name)?;
                    if linked.st_mode & libc::S_IFMT != libc::S_IFDIR
                        || stat_identity(&linked) != directory.identity()
                    {
                        return Err(HostError::IdentityMismatch);
                    }
                    // SAFETY: identity-checked published candidate, no overwrite.
                    if unsafe {
                        libc::renameatx_np(
                            destination.0.file.as_raw_fd(),
                            name.as_ptr(),
                            self.0.file.as_raw_fd(),
                            directory.0.name.as_ptr(),
                            libc::RENAME_EXCL,
                        )
                    } != 0
                    {
                        return Err(os_error(HostOperation::Rename));
                    }
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
