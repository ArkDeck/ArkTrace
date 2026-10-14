//! Handle-only file mutation for separately journaled owner transactions.
//! After publication, failures retain both locations for the caller's recovery;
//! these primitives never erase or blindly roll back a displaced user file.
use super::*;

fn private_document(file: &HeldFile) -> Result<(), HostError> {
    let access = Access::of(&file.file)?;
    if !file.private || !(access.sealed() || access.owner_read_write()) {
        return Err(HostError::InvalidEvidence);
    }
    file.verify()
}

fn rebound(
    parent: &HeldDirectory,
    name: CString,
    previous: FileSnapshot,
) -> Result<HeldFile, HostError> {
    let current = parent.open_file_component(name, true)?;
    let mut expected = previous;
    // An atomic rename changes the change time. Every other field is exact.
    expected.change = current.initial.change;
    if current.initial != expected {
        return Err(HostError::Changed);
    }
    Ok(current)
}

impl HeldDirectory {
    /// Darwin swaps two documents with one `RENAME_SWAP`. Windows has no atomic
    /// exchange of two names, and two renames would expose a window in which
    /// neither or both names are bound, so the exchange is refused.
    pub fn exchange_private_document(
        &self,
        candidate: &HeldFile,
        target: &HeldFile,
        budget: &IoBudget,
    ) -> Result<(HeldFile, HeldFile), HostError> {
        budget.check()?;
        private_document(candidate)?;
        private_document(target)?;
        Err(not_supported(HostOperation::Rename))
    }

    /// Journaled no-replace move. Unlike fresh parser promotion, this may move
    /// an existing user sidecar and therefore never deletes it on late error.
    pub fn move_private_document(
        &self,
        file: &HeldFile,
        destination: &Self,
        name: &str,
        budget: &IoBudget,
    ) -> Result<HeldFile, HostError> {
        if file.parent.identity() != self.identity()
            || self.identity() == destination.identity()
            || !destination.0.private
        {
            return Err(HostError::InvalidEvidence);
        }
        if self.identity().device != destination.identity().device {
            return Err(HostError::CrossVolume);
        }
        if file.initial.byte_count > budget.maximum_bytes {
            return Err(HostError::LimitExceeded);
        }
        let name = component(OsStr::new(name))?;
        budget.check()?;
        private_document(file)?;
        destination.revalidate()?;
        budget.cancellation.publication(|| {
            budget.check_deadline()?;
            private_document(file)?;
            destination.revalidate()?;
            rename_entry(&self.0.file, &file.name, &destination.0.file, &name, false)
        })?;
        self.sync()?;
        destination.sync()?;
        rebound(destination, name, file.initial)
    }
}
