//! Deterministic interruption points exercise the actual copy/publication path.
//! ENOSPC is injected here; this is not a native full-disk acceptance result.
use super::*;
use crate::CancellationToken;
use std::{
    fs::{self, DirBuilder, Permissions},
    os::unix::fs::{DirBuilderExt, PermissionsExt},
};

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arktrace-io-faults-{}-{}",
            std::process::id(),
            NEXT_QUARANTINE.fetch_add(1, Ordering::Relaxed)
        ));
        DirBuilder::new().mode(0o700).create(&path).unwrap();
        Self(path)
    }
    fn held(&self) -> HeldDirectory {
        HeldDirectory::open_private(&self.0).unwrap()
    }
    fn source(&self) -> HeldFile {
        fs::write(self.0.join("source"), vec![42; CHUNK_BYTES * 2 + 1]).unwrap();
        HeldFile::open_explicit_source(&self.0.join("source")).unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}
fn budget() -> IoBudget {
    IoBudget {
        maximum_bytes: (CHUNK_BYTES * 3) as u64,
        deadline: Instant::now() + Duration::from_secs(10),
        cancellation: CancellationToken::default(),
    }
}

#[test]
fn signed_code_directory_has_no_storage_authority_and_retains_binding() {
    let fixture = Fixture::new();
    let path = fixture.0.join("Helpers");
    DirBuilder::new().mode(0o755).create(&path).unwrap();
    fs::write(path.join("helper"), b"held signed-code input").unwrap();
    fs::set_permissions(path.join("helper"), Permissions::from_mode(0o555)).unwrap();
    let code = HeldDirectory::open_code_directory(&path).unwrap();
    let file = code.open_file("helper").unwrap();
    file.require_signed_code_file().unwrap();
    assert!(matches!(
        code.create_private_child("storage"),
        Err(HostError::NotPrivate)
    ));
    assert!(matches!(
        HeldDirectory::open_private(&path),
        Err(HostError::NotPrivate)
    ));
    fs::rename(&path, fixture.0.join("retired")).unwrap();
    DirBuilder::new().mode(0o755).create(&path).unwrap();
    assert!(file.require_signed_code_file().is_err());
}

#[test]
fn signed_code_directory_rejects_writable_linked_and_development_inputs() {
    let fixture = Fixture::new();
    let path = fixture.0.join("Helpers");
    DirBuilder::new().mode(0o755).create(&path).unwrap();
    fs::write(path.join("helper"), b"not a Mach-O fixture").unwrap();
    fs::set_permissions(path.join("helper"), Permissions::from_mode(0o555)).unwrap();
    let code = HeldDirectory::open_code_directory(&path).unwrap();
    assert!(matches!(
        VerifiedExecutable::verify(
            code.open_file("helper").unwrap(),
            &"a".repeat(64),
            CodeTrustPolicy::DevelopmentPinned,
            &budget()
        ),
        Err(ProcessError::InvalidExecutable)
    ));
    fs::hard_link(path.join("helper"), path.join("linked")).unwrap();
    assert!(
        code.open_file("helper")
            .unwrap()
            .require_signed_code_file()
            .is_err()
    );
    fs::remove_file(path.join("linked")).unwrap();
    fs::set_permissions(path.join("helper"), Permissions::from_mode(0o755)).unwrap();
    assert!(
        code.open_file("helper")
            .unwrap()
            .require_signed_code_file()
            .is_err()
    );
    std::os::unix::fs::symlink(&path, fixture.0.join("alias")).unwrap();
    assert!(HeldDirectory::open_code_directory(&fixture.0.join("alias")).is_err());
    fs::set_permissions(&path, Permissions::from_mode(0o777)).unwrap();
    assert!(matches!(
        HeldDirectory::open_code_directory(&path),
        Err(HostError::NotPrivate)
    ));
}

#[test]
fn existing_readonly_leases_do_not_create_or_mutate_legacy_locks() {
    let fixture = Fixture::new();
    let root = fixture.held();
    assert!(matches!(
        Lease::try_acquire_existing_readonly(&root, "missing", LeaseMode::Shared),
        Err(HostError::NotFound)
    ));
    assert!(!root.path().join("missing").exists());
    drop(Lease::acquire(&root, "lock", LeaseMode::Shared, &budget()).unwrap());
    let file = root.open_file("lock").unwrap();
    let before = file.snapshot();
    let shared =
        Lease::acquire_existing_readonly(&root, "lock", LeaseMode::Shared, &budget()).unwrap();
    // SAFETY: inspect the owned descriptor's access mode without changing it.
    assert_eq!(
        unsafe { libc::fcntl(shared.file.as_raw_fd(), libc::F_GETFL) } & libc::O_ACCMODE,
        libc::O_RDONLY
    );
    assert!(
        Lease::try_acquire_existing_readonly(&root, "lock", LeaseMode::Exclusive)
            .unwrap()
            .is_none()
    );
    assert!(
        Lease::try_acquire(&root, "lock", LeaseMode::Exclusive, false)
            .unwrap()
            .is_none()
    );
    drop(shared);
    let exclusive =
        Lease::acquire_existing_readonly(&root, "lock", LeaseMode::Exclusive, &budget()).unwrap();
    assert!(
        Lease::try_acquire_existing_readonly(&root, "lock", LeaseMode::Shared)
            .unwrap()
            .is_none()
    );
    exclusive.revalidate().unwrap();
    drop(exclusive);
    assert_eq!(root.open_file("lock").unwrap().snapshot(), before);
    let readonly = root.write_new_readonly("readonly", b"", &budget()).unwrap();
    let readonly_lease =
        Lease::acquire_existing_readonly(&root, "readonly", LeaseMode::Exclusive, &budget())
            .unwrap();
    readonly_lease.revalidate().unwrap();
    drop(readonly_lease);
    readonly.verify().unwrap();
    root.write_new_readonly("foreign", b"not an empty legacy lock", &budget())
        .unwrap();
    assert!(matches!(
        Lease::try_acquire_existing_readonly(&root, "foreign", LeaseMode::Shared),
        Err(HostError::InvalidEvidence)
    ));
}

#[test]
fn existing_readonly_leases_reject_links_and_replaced_parent() {
    use std::os::unix::fs::symlink;
    let fixture = Fixture::new();
    let root = fixture.held();
    root.write_new_readonly("lock", b"", &budget()).unwrap();
    symlink(root.path().join("lock"), root.path().join("linked")).unwrap();
    assert!(Lease::try_acquire_existing_readonly(&root, "linked", LeaseMode::Shared).is_err());
    let child = root.create_private_child("child").unwrap();
    child.write_new_readonly("lock", b"", &budget()).unwrap();
    let lease =
        Lease::acquire_existing_readonly(&child, "lock", LeaseMode::Shared, &budget()).unwrap();
    fs::rename(child.path(), root.path().join("detached")).unwrap();
    root.create_private_child("child").unwrap();
    assert!(lease.revalidate().is_err());
    assert!(Lease::try_acquire_existing_readonly(&child, "lock", LeaseMode::Shared).is_err());
}

#[test]
fn cancellation_after_first_copy_chunk_removes_partial_output() {
    let fixture = Fixture::new();
    let source = fixture.source();
    let stage = fixture.held().create_private_child("stage").unwrap();
    let budget = budget();
    let result = stage.copy_snapshot_observed(&source, "snapshot", false, &budget, |offset| {
        assert_eq!(offset, 0);
        budget.cancellation.cancel();
        Ok(())
    });
    assert!(matches!(result, Err(HostError::Cancelled)));
    assert_eq!(fs::read_dir(stage.path()).unwrap().count(), 0);
    source.verify().unwrap();
}

#[test]
fn input_mutation_during_copy_is_rejected_and_partial_output_removed() {
    let fixture = Fixture::new();
    let source = fixture.source();
    let stage = fixture.held().create_private_child("stage").unwrap();
    let writer = File::options().write(true).open(source.path()).unwrap();
    let result = stage.copy_snapshot_observed(&source, "snapshot", false, &budget(), |offset| {
        if offset == 0 {
            writer
                .write_all_at(&[99], (CHUNK_BYTES + 7) as u64)
                .unwrap();
        }
        Ok(())
    });
    assert!(matches!(result, Err(HostError::Changed)));
    assert_eq!(fs::read_dir(stage.path()).unwrap().count(), 0);
}

#[test]
fn injected_enospc_after_partial_write_preserves_closed_failure_and_cleans_output() {
    let fixture = Fixture::new();
    let source = fixture.source();
    let stage = fixture.held().create_private_child("stage").unwrap();
    let expected = HostError::SystemIo {
        operation: HostOperation::Write,
        code: libc::ENOSPC,
    };
    let result =
        stage.copy_snapshot_observed(&source, "snapshot", false, &budget(), |_| Err(expected));
    assert!(matches!(result, Err(error) if error == expected));
    assert_eq!(fs::read_dir(stage.path()).unwrap().count(), 0);
    source.verify().unwrap();
}

#[test]
fn cleanup_failure_takes_priority_over_copy_cancellation_without_deleting_replacement() {
    let fixture = Fixture::new();
    let source = fixture.source();
    let stage = fixture.held().create_private_child("stage").unwrap();
    let budget = budget();
    let result = stage.copy_snapshot_observed(&source, "snapshot", false, &budget, |_| {
        fs::rename(stage.path().join("snapshot"), stage.path().join("detached")).unwrap();
        fs::write(stage.path().join("snapshot"), b"other-owner").unwrap();
        budget.cancellation.cancel();
        Ok(())
    });
    assert!(matches!(result, Err(HostError::CleanupFailed)));
    assert_eq!(
        fs::read(stage.path().join("snapshot")).unwrap(),
        b"other-owner"
    );
    assert_eq!(
        fs::metadata(stage.path().join("detached")).unwrap().len(),
        CHUNK_BYTES as u64
    );
}

#[test]
fn cancellation_immediately_before_atomic_rename_publishes_nothing() {
    let fixture = Fixture::new();
    let root = fixture.held();
    let stage = root.create_private_child("stage").unwrap();
    let ready = root.create_private_child("ready").unwrap();
    let file = stage
        .write_new_readonly("candidate", b"db", &budget())
        .unwrap();
    let budget = budget();
    let result = stage.promote_observed(
        &file,
        &ready,
        "db",
        &budget,
        || budget.cancellation.cancel(),
        || {},
    );
    assert!(matches!(result, Err(HostError::Cancelled)));
    assert_eq!(fs::read_dir(ready.path()).unwrap().count(), 0);
    file.verify().unwrap();
}

#[test]
fn cancellation_immediately_after_atomic_rename_rolls_back_owned_publication() {
    let fixture = Fixture::new();
    let root = fixture.held();
    let stage = root.create_private_child("stage").unwrap();
    let ready = root.create_private_child("ready").unwrap();
    let file = stage
        .write_new_readonly("candidate", b"db", &budget())
        .unwrap();
    let budget = budget();
    let result = stage.promote_observed(
        &file,
        &ready,
        "db",
        &budget,
        || {},
        || budget.cancellation.cancel(),
    );
    assert!(matches!(result, Err(HostError::Cancelled)));
    assert_eq!(fs::read_dir(ready.path()).unwrap().count(), 0);
    assert_eq!(fs::read_dir(stage.path()).unwrap().count(), 0);
}

#[test]
fn parent_replacement_at_publication_window_is_rejected_inside_critical_section() {
    let fixture = Fixture::new();
    let root = fixture.held();
    let stage = root.create_private_child("stage").unwrap();
    let ready = root.create_private_child("ready").unwrap();
    let file = stage
        .write_new_readonly("candidate", b"db", &budget())
        .unwrap();
    let result = stage.promote_observed(
        &file,
        &ready,
        "db",
        &budget(),
        || {
            fs::rename(ready.path(), fixture.0.join("old-ready")).unwrap();
            root.create_private_child("ready").unwrap();
        },
        || {},
    );
    assert!(matches!(result, Err(HostError::IdentityMismatch)));
    assert_eq!(
        fs::read_dir(fixture.0.join("old-ready")).unwrap().count(),
        0
    );
    assert_eq!(fs::read_dir(fixture.0.join("ready")).unwrap().count(), 0);
    file.verify().unwrap();
}

#[test]
fn replaced_publication_is_preserved_and_cleanup_failure_is_not_hidden_by_cancel() {
    let fixture = Fixture::new();
    let root = fixture.held();
    let stage = root.create_private_child("stage").unwrap();
    let ready = root.create_private_child("ready").unwrap();
    let file = stage
        .write_new_readonly("candidate", b"db", &budget())
        .unwrap();
    let budget = budget();
    let result = stage.promote_observed(
        &file,
        &ready,
        "db",
        &budget,
        || {},
        || {
            fs::rename(ready.path().join("db"), ready.path().join("detached")).unwrap();
            fs::write(ready.path().join("db"), b"other-owner").unwrap();
            fs::set_permissions(ready.path().join("db"), Permissions::from_mode(0o600)).unwrap();
            budget.cancellation.cancel();
        },
    );
    assert!(matches!(result, Err(HostError::CleanupFailed)));
    assert_eq!(fs::read(ready.path().join("db")).unwrap(), b"other-owner");
    assert_eq!(fs::read(ready.path().join("detached")).unwrap(), b"db");
}

#[test]
fn same_inode_same_size_content_mutation_after_rename_is_rejected_and_rolled_back() {
    let fixture = Fixture::new();
    let root = fixture.held();
    let stage = root.create_private_child("stage").unwrap();
    let ready = root.create_private_child("ready").unwrap();
    let file = stage
        .write_new_readonly("candidate", b"db", &budget())
        .unwrap();
    let result = stage.promote_observed(
        &file,
        &ready,
        "db",
        &budget(),
        || {},
        || {
            let path = ready.path().join("db");
            fs::set_permissions(&path, Permissions::from_mode(0o600)).unwrap();
            fs::write(&path, b"xx").unwrap();
            fs::set_permissions(&path, Permissions::from_mode(0o400)).unwrap();
        },
    );
    assert!(matches!(result, Err(HostError::Changed)));
    assert_eq!(fs::read_dir(ready.path()).unwrap().count(), 0);
}

#[test]
fn directory_cancel_before_rename_publishes_nothing() {
    let fixture = Fixture::new();
    let root = fixture.held();
    let stage = root.create_private_child("stage").unwrap();
    let ready = root.create_private_child("ready").unwrap();
    stage.write_new_readonly("db", b"db", &budget()).unwrap();
    let candidate = stage.seal_readonly_directory(&budget()).unwrap();
    let budget = budget();
    let result = root.promote_directory_observed(
        &candidate,
        &ready,
        "entry",
        &budget,
        || budget.cancellation.cancel(),
        || {},
    );
    assert!(matches!(result, Err(HostError::Cancelled)));
    candidate.verify(&super_budget()).unwrap();
    assert_eq!(fs::read_dir(ready.path()).unwrap().count(), 0);
}

// A distinct token allows inspection after the tested operation was cancelled.
fn super_budget() -> IoBudget {
    budget()
}

#[test]
fn directory_cancel_after_rename_restores_complete_identity_and_payloads() {
    let fixture = Fixture::new();
    let root = fixture.held();
    let stage = root.create_private_child("stage").unwrap();
    let ready = root.create_private_child("ready").unwrap();
    stage.write_new_readonly("db", b"db", &budget()).unwrap();
    stage
        .write_new_readonly("metadata", b"metadata", &budget())
        .unwrap();
    let candidate = stage.seal_readonly_directory(&budget()).unwrap();
    let budget = budget();
    let result = root.promote_directory_observed(
        &candidate,
        &ready,
        "entry",
        &budget,
        || {},
        || budget.cancellation.cancel(),
    );
    assert!(matches!(result, Err(HostError::Cancelled)));
    stage.revalidate().unwrap();
    assert_eq!(fs::read(stage.path().join("db")).unwrap(), b"db");
    assert_eq!(
        fs::read(stage.path().join("metadata")).unwrap(),
        b"metadata"
    );
    assert_eq!(fs::read_dir(ready.path()).unwrap().count(), 0);
}

#[test]
fn directory_payload_change_at_publication_windows_is_rejected() {
    for after in [false, true] {
        let fixture = Fixture::new();
        let root = fixture.held();
        let stage = root.create_private_child("stage").unwrap();
        let ready = root.create_private_child("ready").unwrap();
        stage.write_new_readonly("db", b"db", &budget()).unwrap();
        let candidate = stage.seal_readonly_directory(&budget()).unwrap();
        let mutate = |path: PathBuf| {
            fs::set_permissions(&path, Permissions::from_mode(0o600)).unwrap();
            fs::write(&path, b"xx").unwrap();
            fs::set_permissions(&path, Permissions::from_mode(0o400)).unwrap();
        };
        let result = root.promote_directory_observed(
            &candidate,
            &ready,
            "entry",
            &budget(),
            || {
                if !after {
                    mutate(stage.path().join("db"));
                }
            },
            || {
                if after {
                    mutate(ready.path().join("entry/db"));
                }
            },
        );
        assert!(matches!(result, Err(HostError::Changed)));
        assert_eq!(fs::read_dir(ready.path()).unwrap().count(), 0);
        stage.revalidate().unwrap();
        assert_eq!(fs::read(stage.path().join("db")).unwrap(), b"xx");
    }
}

#[test]
fn directory_ancestor_replacement_at_rename_window_preserves_owned_candidate() {
    let fixture = Fixture::new();
    let root = fixture.held();
    let parent = root.create_private_child("parent").unwrap();
    let stage = parent.create_private_child("stage").unwrap();
    let ready = root.create_private_child("ready").unwrap();
    stage.write_new_readonly("db", b"db", &budget()).unwrap();
    let candidate = stage.seal_readonly_directory(&budget()).unwrap();
    let result = parent.promote_directory_observed(
        &candidate,
        &ready,
        "entry",
        &budget(),
        || {
            fs::rename(parent.path(), root.path().join("detached")).unwrap();
            root.create_private_child("parent").unwrap();
        },
        || {},
    );
    assert!(matches!(result, Err(HostError::IdentityMismatch)));
    assert_eq!(
        fs::read(root.path().join("detached/stage/db")).unwrap(),
        b"db"
    );
    assert_eq!(fs::read_dir(ready.path()).unwrap().count(), 0);
}

#[test]
fn directory_replaced_publication_cleanup_failure_wins_over_cancellation() {
    let fixture = Fixture::new();
    let root = fixture.held();
    let stage = root.create_private_child("stage").unwrap();
    let ready = root.create_private_child("ready").unwrap();
    stage.write_new_readonly("db", b"db", &budget()).unwrap();
    let candidate = stage.seal_readonly_directory(&budget()).unwrap();
    let budget = budget();
    let result = root.promote_directory_observed(
        &candidate,
        &ready,
        "entry",
        &budget,
        || {},
        || {
            fs::rename(ready.path().join("entry"), ready.path().join("detached")).unwrap();
            let other = ready.create_private_child("entry").unwrap();
            other
                .write_new_readonly("other", b"unrelated", &super_budget())
                .unwrap();
            budget.cancellation.cancel();
        },
    );
    assert!(matches!(result, Err(HostError::CleanupFailed)));
    assert_eq!(
        fs::read(ready.path().join("entry/other")).unwrap(),
        b"unrelated"
    );
    assert_eq!(fs::read(ready.path().join("detached/db")).unwrap(), b"db");
}

#[test]
fn directory_rollback_collision_preserves_both_directories() {
    let fixture = Fixture::new();
    let root = fixture.held();
    let stage = root.create_private_child("stage").unwrap();
    let ready = root.create_private_child("ready").unwrap();
    stage.write_new_readonly("db", b"db", &budget()).unwrap();
    let candidate = stage.seal_readonly_directory(&budget()).unwrap();
    let budget = budget();
    let result = root.promote_directory_observed(
        &candidate,
        &ready,
        "entry",
        &budget,
        || {},
        || {
            let other = root.create_private_child("stage").unwrap();
            other
                .write_new_readonly("other", b"unrelated", &super_budget())
                .unwrap();
            budget.cancellation.cancel();
        },
    );
    assert!(matches!(result, Err(HostError::CleanupFailed)));
    assert_eq!(
        fs::read(root.path().join("stage/other")).unwrap(),
        b"unrelated"
    );
    assert_eq!(fs::read(ready.path().join("entry/db")).unwrap(), b"db");
}
