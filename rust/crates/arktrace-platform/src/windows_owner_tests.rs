//! Windows runs of the owner transaction scenarios from macos_owner.rs tests.
use super::super::tests::{Fixture as Root, budget};
use super::*;
use std::fs;

struct Fixture(Root, OwnerStore);
impl Fixture {
    fn new() -> Self {
        let root = Root::new();
        let parent = root.1.create_private_child("stage").unwrap();
        let store = OwnerStore::open(&parent, &root.1).unwrap();
        Self(root, store)
    }
    fn root(&self) -> &HeldDirectory {
        &self.0.1
    }
}

const SESSION: &str = "session-00000000-0000-0000-0000-000000000000";

fn bound_fixture(
    fixture: &Fixture,
) -> (
    OwnedDirectory,
    super::super::EphemeralLease,
    Lease,
    HeldDirectory,
) {
    let ready = fixture.root().ensure_private_child(".ready").unwrap();
    let leases = fixture.root().ensure_private_child(".leases").unwrap();
    let locks = fixture.root().ensure_private_child(".locks").unwrap();
    let key = Lease::acquire(
        &locks,
        &format!("{}.lock", "0".repeat(64)),
        LeaseMode::Exclusive,
        &budget(),
    )
    .unwrap();
    let entry =
        super::super::EphemeralLease::acquire(&leases, &format!("{SESSION}.lease"), &budget())
            .unwrap();
    let mut owned = fixture.1.create(OwnerKind::Building, &budget()).unwrap();
    owned.bind_ephemeral(&entry, &key, &budget()).unwrap();
    owned
        .directory()
        .write_new_readonly("metadata.json", b"metadata", &budget())
        .unwrap();
    owned
        .directory()
        .write_new_readonly("trace.db", b"database", &budget())
        .unwrap();
    (owned, entry, key, ready)
}

#[test]
fn session_owner_cleanup_removes_directory_and_records() {
    let fixture = Fixture::new();
    let mut owned = fixture.1.create(OwnerKind::Session, &budget()).unwrap();
    owned
        .directory()
        .create_private_child("nested")
        .unwrap()
        .write_new_readonly("payload", b"x", &budget())
        .unwrap();
    let path = owned.directory().path().to_path_buf();
    assert_eq!(fixture.1.identifiers(&budget()).unwrap().len(), 1);
    owned.cleanup(&budget()).unwrap();
    assert!(!path.exists());
    assert!(fixture.1.identifiers(&budget()).unwrap().is_empty());
    assert_eq!(fs::read_dir(fixture.1.owners.path()).unwrap().count(), 0);
}

#[test]
fn stale_owner_is_recovered_only_after_its_holder_is_gone() {
    let fixture = Fixture::new();
    let owned = fixture.1.create(OwnerKind::Building, &budget()).unwrap();
    let identifier = owned.identifier().to_owned();
    assert_eq!(
        fixture.1.recover_stale(&identifier, &budget()).unwrap(),
        OwnerRecoveryOutcome::Active
    );
    let path = owned.directory().path().to_path_buf();
    drop(owned);
    assert_eq!(
        fixture.1.recover_stale(&identifier, &budget()).unwrap(),
        OwnerRecoveryOutcome::Removed
    );
    assert!(!path.exists());
    assert_eq!(
        fixture.1.recover_stale(&identifier, &budget()).unwrap(),
        OwnerRecoveryOutcome::NotFound
    );
}

#[test]
fn bound_removed_tombstone_reconciles_lease_without_metadata_and_preserves_stable_key() {
    let fixture = Fixture::new();
    let (mut owned, entry, key, _) = bound_fixture(&fixture);
    let identifier = owned.identifier().to_owned();
    owned.cleanup(&budget()).unwrap();
    let (_, evidence) = fixture.1.read(&identifier, &budget()).unwrap().unwrap();
    assert_eq!(evidence.format_version, 3);
    assert_eq!(evidence.state, State::Removed);
    drop(owned);
    drop(entry);
    assert_eq!(
        fixture.1.recover_stale(&identifier, &budget()).unwrap(),
        OwnerRecoveryOutcome::PublishedNeedsEntryLease
    );
    let info = fixture
        .1
        .published_evidence(&identifier, &budget())
        .unwrap()
        .unwrap();
    assert!(!info.requires_metadata());
    assert_eq!(
        fixture
            .1
            .recover_ephemeral_ready(&info, &key, None, &budget())
            .unwrap(),
        OwnerRecoveryOutcome::Removed
    );
    assert!(fixture.1.identifiers(&budget()).unwrap().is_empty());
    assert_eq!(
        fs::read_dir(fixture.root().path().join(".leases"))
            .unwrap()
            .count(),
        0
    );
    key.revalidate().unwrap();
}

#[test]
fn bound_publication_intent_recovers_both_sides_of_atomic_rename() {
    for renamed in [false, true] {
        let fixture = Fixture::new();
        let (mut owned, entry, key, ready) = bound_fixture(&fixture);
        let identifier = owned.identifier().to_owned();
        let sealed = owned
            .directory()
            .seal_readonly_directory(&budget())
            .unwrap();
        owned
            .prepare_ephemeral_publication(&ready, SESSION, &budget())
            .unwrap();
        if renamed {
            fixture
                .1
                .parent
                .promote_sealed_directory_noreplace(&sealed, &ready, SESSION, &budget())
                .unwrap();
        }
        drop(sealed);
        drop(owned);
        drop(entry);
        let info = fixture
            .1
            .published_evidence(&identifier, &budget())
            .unwrap()
            .unwrap();
        assert_eq!(
            fixture
                .1
                .recover_ephemeral_ready(&info, &key, None, &budget())
                .unwrap(),
            OwnerRecoveryOutcome::Removed,
            "renamed={renamed}"
        );
        assert!(fixture.1.identifiers(&budget()).unwrap().is_empty());
        assert_eq!(fs::read_dir(ready.path()).unwrap().count(), 0);
    }
}

#[test]
fn ephemeral_publication_records_ready_and_cleanup_finishes_with_the_lease() {
    let fixture = Fixture::new();
    let (mut owned, entry, _key, ready) = bound_fixture(&fixture);
    let sealed = owned
        .directory()
        .seal_readonly_directory(&budget())
        .unwrap();
    owned
        .prepare_ephemeral_publication(&ready, SESSION, &budget())
        .unwrap();
    let published = fixture
        .1
        .parent
        .promote_sealed_directory_noreplace(&sealed, &ready, SESSION, &budget())
        .unwrap();
    owned
        .record_published_location(&published, &budget())
        .unwrap();
    let info = fixture
        .1
        .published_evidence(owned.identifier(), &budget())
        .unwrap()
        .unwrap();
    assert!(info.is_ready() && info.requires_metadata());
    assert_eq!(
        fixture
            .1
            .locate_published(&info, &budget())
            .unwrap()
            .map(|d| d.identity()),
        Some(published.identity())
    );
    drop((sealed, published));
    owned.cleanup(&budget()).unwrap();
    owned.finish_ephemeral_cleanup(entry, &budget()).unwrap();
    assert!(fixture.1.identifiers(&budget()).unwrap().is_empty());
    assert_eq!(fs::read_dir(ready.path()).unwrap().count(), 0);
    assert_eq!(
        fs::read_dir(fixture.root().path().join(".leases"))
            .unwrap()
            .count(),
        0
    );
}

#[test]
fn ephemeral_ready_recovery_refuses_live_entry_and_owner_then_removes_stale_artifacts() {
    let fixture = Fixture::new();
    let (mut owned, entry, key, ready) = bound_fixture(&fixture);
    let sealed = owned
        .directory()
        .seal_readonly_directory(&budget())
        .unwrap();
    owned
        .prepare_ephemeral_publication(&ready, SESSION, &budget())
        .unwrap();
    let published = fixture
        .1
        .parent
        .promote_sealed_directory_noreplace(&sealed, &ready, SESSION, &budget())
        .unwrap();
    owned
        .record_published_location(&published, &budget())
        .unwrap();
    drop(sealed);
    let info = fixture
        .1
        .published_evidence(owned.identifier(), &budget())
        .unwrap()
        .unwrap();
    let metadata = published.open_file("metadata.json").unwrap();
    assert_eq!(
        fixture
            .1
            .recover_ephemeral_ready(&info, &key, Some(&metadata), &budget())
            .unwrap(),
        OwnerRecoveryOutcome::Active
    );
    drop(entry);
    assert_eq!(
        fixture
            .1
            .recover_ephemeral_ready(&info, &key, Some(&metadata), &budget())
            .unwrap(),
        OwnerRecoveryOutcome::Active
    );
    drop(owned);
    assert_eq!(
        fixture
            .1
            .recover_ephemeral_ready(&info, &key, Some(&metadata), &budget())
            .unwrap(),
        OwnerRecoveryOutcome::Removed
    );
    assert_eq!(fs::read_dir(ready.path()).unwrap().count(), 0);
    assert!(fixture.1.identifiers(&budget()).unwrap().is_empty());
    key.revalidate().unwrap();
}

#[test]
fn bound_evidence_closes_versions_keys_lease_identity_and_nested_fields() {
    let fixture = Fixture::new();
    let (owned, _entry, _key, _) = bound_fixture(&fixture);
    let (_, evidence) = fixture
        .1
        .read(owned.identifier(), &budget())
        .unwrap()
        .unwrap();
    let original = serde_json::to_value(evidence).unwrap();
    for mutation in [
        "old-version",
        "missing-binding",
        "inode",
        "unknown",
        "unknown-nested",
    ] {
        let mut v = original.clone();
        match mutation {
            "old-version" => v["formatVersion"] = 2.into(),
            "missing-binding" => {
                v.as_object_mut().unwrap().remove("ephemeral");
            }
            "inode" => v["ephemeral"]["leaseInode"] = 0.into(),
            "unknown" => v["extra"] = true.into(),
            "unknown-nested" => v["ephemeral"]["extra"] = true.into(),
            _ => unreachable!(),
        }
        assert!(
            matches!(
                Evidence::decode(&serde_json::to_vec(&v).unwrap()),
                Err(HostError::InvalidEvidence)
            ),
            "{mutation}"
        );
    }
}

#[test]
fn sealed_document_replacement_is_identity_checked() {
    let fixture = Fixture::new();
    let directory = fixture.root().create_private_child("documents").unwrap();
    let old = directory
        .write_new_readonly("metadata.json", b"one", &budget())
        .unwrap();
    let new = directory.replace_readonly(&old, b"two", &budget()).unwrap();
    assert_eq!(new.read_bounded(&budget()).unwrap(), b"two");
    assert_ne!(new.snapshot().identity, old.snapshot().identity);
    assert_eq!(
        directory.child_names(&budget(), 8).unwrap(),
        [std::ffi::OsString::from("metadata.json")]
    );
    // The previous binding is gone: replacing it again is refused.
    assert!(
        directory
            .replace_readonly(&old, b"three", &budget())
            .is_err()
    );
    assert_eq!(new.read_bounded(&budget()).unwrap(), b"two");
}
