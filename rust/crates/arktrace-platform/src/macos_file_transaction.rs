//! Descriptor-only file mutation for separately journaled owner transactions.
//! No temporary member is introduced into the destination Ready directory.
//! After publication, failures retain both locations for the caller's recovery;
//! these primitives never erase or blindly roll back a displaced user file.
use super::*;

fn private_document(file: &HeldFile) -> Result<(), HostError> {
    if !file.private || !matches!(file.initial.mode & 0o7777, 0o400 | 0o600) {
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
    // An atomic rename changes ctime. Every other field is still exact.
    expected.change = current.initial.change;
    if current.initial != expected {
        return Err(HostError::Changed);
    }
    Ok(current)
}

impl HeldDirectory {
    /// Atomic exchange between two held private parents. The source must be
    /// a sealed candidate and the target a 0400/0600 document. Both resulting
    /// descriptors are returned; the caller journals and owns cleanup.
    pub fn exchange_private_document(
        &self,
        candidate: &HeldFile,
        target: &HeldFile,
        budget: &IoBudget,
    ) -> Result<(HeldFile, HeldFile), HostError> {
        self.exchange_document_observed(candidate, target, budget, || {}, || {})
    }

    fn exchange_document_observed(
        &self,
        candidate: &HeldFile,
        target: &HeldFile,
        budget: &IoBudget,
        before: impl FnOnce(),
        after: impl FnOnce(),
    ) -> Result<(HeldFile, HeldFile), HostError> {
        if candidate.parent.identity() != self.identity()
            || self.identity() == target.parent.identity()
            || !self.0.private
            || candidate.initial.mode & 0o7777 != 0o400
        {
            return Err(HostError::InvalidEvidence);
        }
        if self.identity().device != target.parent.identity().device {
            return Err(HostError::CrossVolume);
        }
        if candidate.initial.byte_count > budget.maximum_bytes
            || target.initial.byte_count > budget.maximum_bytes
        {
            return Err(HostError::LimitExceeded);
        }
        budget.check()?;
        private_document(candidate)?;
        private_document(target)?;
        before();
        budget.cancellation.publication(|| {
            budget.check_deadline()?;
            private_document(candidate)?;
            private_document(target)?;
            // SAFETY: exact bound files, held private same-volume parents,
            // valid single-component names; one atomic exchange syscall.
            if unsafe {
                libc::renameatx_np(
                    self.0.file.as_raw_fd(),
                    candidate.name.as_ptr(),
                    target.parent.0.file.as_raw_fd(),
                    target.name.as_ptr(),
                    libc::RENAME_SWAP,
                )
            } != 0
            {
                return Err(os_error(HostOperation::Rename));
            }
            Ok(())
        })?;
        after();
        // A durable intent exists in the caller before this method. Do not
        // convert a late cancellation into deletion of the displaced file.
        self.sync()?;
        target.parent.sync()?;
        let published = rebound(&target.parent, target.name.clone(), candidate.initial)?;
        let displaced = rebound(self, candidate.name.clone(), target.initial)?;
        published.verify()?;
        displaced.verify()?;
        Ok((published, displaced))
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
            // SAFETY: exact bound source, held private same-volume parents,
            // single-component target; refuses every existing target.
            if unsafe {
                libc::renameatx_np(
                    self.0.file.as_raw_fd(),
                    file.name.as_ptr(),
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
        self.sync()?;
        destination.sync()?;
        rebound(destination, name, file.initial)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt, symlink};
    struct Fixture(PathBuf, HeldDirectory, HeldDirectory);
    fn budget() -> IoBudget {
        IoBudget {
            maximum_bytes: 4096,
            deadline: Instant::now() + Duration::from_secs(10),
            cancellation: crate::CancellationToken::default(),
        }
    }
    impl Fixture {
        fn new() -> Self {
            let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
                "arktrace-file-transaction-{}-{}",
                std::process::id(),
                NEXT_QUARANTINE.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::DirBuilder::new()
                .mode(0o700)
                .create(&path)
                .unwrap();
            let root = HeldDirectory::open_private(&path).unwrap();
            Self(
                path,
                root.create_private_child("owner").unwrap(),
                root.create_private_child("ready").unwrap(),
            )
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            std::fs::remove_dir_all(&self.0).unwrap();
        }
    }
    #[test]
    fn cross_parent_exchange_accepts_existing_private_writable_sidecar() {
        let f = Fixture::new();
        let candidate =
            f.1.write_new_readonly("payload", b"new", &budget())
                .unwrap();
        let old =
            f.2.write_new_readonly("view-state.json", b"old", &budget())
                .unwrap();
        std::fs::set_permissions(old.path(), std::fs::Permissions::from_mode(0o600)).unwrap();
        let old = f.2.open_file("view-state.json").unwrap();
        let (new, displaced) =
            f.1.exchange_private_document(&candidate, &old, &budget())
                .unwrap();
        assert_eq!(new.read_bounded(&budget()).unwrap(), b"new");
        assert_eq!(displaced.read_bounded(&budget()).unwrap(), b"old");
        assert_eq!(new.snapshot().identity, candidate.snapshot().identity);
        assert_eq!(displaced.snapshot().identity, old.snapshot().identity);
        assert_eq!(
            f.2.child_names(&budget(), 10).unwrap(),
            [OsString::from("view-state.json")]
        );
    }
    #[test]
    fn cancellation_before_exchange_keeps_both_originals_and_after_keeps_both_results() {
        for cancel_before in [true, false] {
            let f = Fixture::new();
            let candidate =
                f.1.write_new_readonly("payload", b"new", &budget())
                    .unwrap();
            let old =
                f.2.write_new_readonly("view-state.json", b"old", &budget())
                    .unwrap();
            let b = budget();
            let result = f.1.exchange_document_observed(
                &candidate,
                &old,
                &b,
                || {
                    if cancel_before {
                        b.cancellation.cancel();
                    }
                },
                || {
                    if !cancel_before {
                        b.cancellation.cancel();
                    }
                },
            );
            if cancel_before {
                assert!(matches!(result, Err(HostError::Cancelled)));
                assert_eq!(old.read_bounded(&budget()).unwrap(), b"old");
                assert_eq!(candidate.read_bounded(&budget()).unwrap(), b"new");
            } else {
                let (new, displaced) = result.unwrap();
                assert_eq!(new.read_bounded(&budget()).unwrap(), b"new");
                assert_eq!(displaced.read_bounded(&budget()).unwrap(), b"old");
            }
        }
    }
    #[test]
    fn raced_target_and_symlink_are_preserved_without_publication() {
        let f = Fixture::new();
        let candidate =
            f.1.write_new_readonly("payload", b"new", &budget())
                .unwrap();
        let old =
            f.2.write_new_readonly("view-state.json", b"old", &budget())
                .unwrap();
        let result = f.1.exchange_document_observed(
            &candidate,
            &old,
            &budget(),
            || {
                std::fs::rename(old.path(), f.2.path().join("preserved-old")).unwrap();
                symlink("preserved-old", f.2.path().join("view-state.json")).unwrap();
            },
            || {},
        );
        assert!(result.is_err());
        assert_eq!(
            std::fs::read(f.2.path().join("preserved-old")).unwrap(),
            b"old"
        );
        assert_eq!(candidate.read_bounded(&budget()).unwrap(), b"new");
        assert!(f.2.path().join("view-state.json").is_symlink());
    }
    #[test]
    fn moving_old_sidecar_to_owner_never_overwrites_an_existing_slot() {
        let f = Fixture::new();
        let old =
            f.2.write_new_readonly("view-state.json", b"old", &budget())
                .unwrap();
        let occupied =
            f.1.write_new_readonly("payload", b"foreign", &budget())
                .unwrap();
        assert!(
            f.2.move_private_document(&old, &f.1, "payload", &budget())
                .is_err()
        );
        assert_eq!(old.read_bounded(&budget()).unwrap(), b"old");
        assert_eq!(occupied.read_bounded(&budget()).unwrap(), b"foreign");
        f.1.remove_owned_file("payload", occupied.snapshot().identity)
            .unwrap();
        let moved =
            f.2.move_private_document(&old, &f.1, "payload", &budget())
                .unwrap();
        assert_eq!(moved.read_bounded(&budget()).unwrap(), b"old");
        assert!(matches!(
            f.2.open_file("view-state.json"),
            Err(HostError::NotFound)
        ));
    }
}
