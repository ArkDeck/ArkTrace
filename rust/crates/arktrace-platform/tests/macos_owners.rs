#![cfg(target_os = "macos")]
use arktrace_platform::{
    CancellationToken, HeldDirectory, HostError, IoBudget, OwnerKind, OwnerRecoveryOutcome,
    OwnerStore,
};
use std::{
    fs::{self, DirBuilder, OpenOptions},
    io::Write,
    os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt, symlink},
    path::PathBuf,
    process::{Child, Command},
    sync::{
        Mutex, MutexGuard,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};
static NEXT: AtomicU64 = AtomicU64::new(0);
// Rust's fixture Command spawn can temporarily inherit other test threads'
// CLOEXEC descriptors before exec. Keep owner assertions and these child
// launches in one scope; production recovery must remain nonblocking.
static OWNER_TEST_SCOPE: Mutex<()> = Mutex::new(());
struct Fixture {
    path: PathBuf,
    root: HeldDirectory,
    stage: HeldDirectory,
    store: OwnerStore,
    _scope: MutexGuard<'static, ()>,
}
impl Fixture {
    fn new() -> Self {
        let scope = OWNER_TEST_SCOPE
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arktrace-owner-{}-{}-空 格",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        DirBuilder::new().mode(0o700).create(&path).unwrap();
        let root = HeldDirectory::open_private(&path).unwrap();
        let stage = root.create_private_child("stage").unwrap();
        let store = OwnerStore::open(&stage, &root).unwrap();
        Self {
            path,
            root,
            stage,
            store,
            _scope: scope,
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.path).unwrap();
    }
}
fn budget() -> IoBudget {
    IoBudget {
        maximum_bytes: 16_384,
        deadline: Instant::now() + Duration::from_secs(10),
        cancellation: CancellationToken::default(),
    }
}
fn write_private(path: &std::path::Path, bytes: &[u8]) {
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .unwrap()
        .write_all(bytes)
        .unwrap();
}

fn cache_authority(
    fixture: &Fixture,
) -> (
    String,
    String,
    arktrace_platform::Lease,
    arktrace_platform::Lease,
) {
    use arktrace_platform::{Lease, LeaseMode};
    use sha2::{Digest, Sha256};
    let trace = "a".repeat(64);
    let parser = "b".repeat(64);
    let key = format!("{:x}", Sha256::digest(format!("{trace}:{parser}")));
    let locks = fixture.root.ensure_private_child(".locks").unwrap();
    let leases = fixture.root.ensure_private_child(".leases").unwrap();
    let key_lock = Lease::acquire(
        &locks,
        &format!("{key}.lock"),
        LeaseMode::Exclusive,
        &budget(),
    )
    .unwrap();
    let entry = Lease::acquire(
        &leases,
        &format!("{key}.lease"),
        LeaseMode::Exclusive,
        &budget(),
    )
    .unwrap();
    (trace, parser, key_lock, entry)
}

#[test]
fn cached_ready_requires_fixed_exclusive_authority_and_quarantine_preserves_sidecar() {
    use arktrace_platform::{Lease, LeaseMode};
    let f = Fixture::new();
    let (trace, parser, key, mut entry) = cache_authority(&f);
    let hash = f.root.ensure_private_child(&trace).unwrap();
    let mut owner = f.store.create(OwnerKind::Building, &budget()).unwrap();
    let id = owner.identifier().to_owned();
    owner
        .bind_cached(&key, &entry, &format!("{trace}/{parser}"), &budget())
        .unwrap();
    let candidate = owner.directory().clone();
    candidate
        .write_new_readonly("trace.sqlite", b"database", &budget())
        .unwrap();
    candidate
        .write_new_readonly("metadata.json", b"metadata", &budget())
        .unwrap();
    owner
        .prepare_cached_publication(&hash, &parser, &key, &entry, &budget())
        .unwrap();
    let sealed = candidate.seal_readonly_directory(&budget()).unwrap();
    let ready = f
        .stage
        .promote_sealed_directory_noreplace(&sealed, &hash, &parser, &budget())
        .unwrap();
    owner.record_published_location(&ready, &budget()).unwrap();
    ready
        .write_new_readonly("view-state.json", b"user sidecar", &budget())
        .unwrap();
    assert_eq!(owner.cleanup(&budget()), Err(HostError::InvalidEvidence));
    drop(owner);
    let record = f.store.published_evidence(&id, &budget()).unwrap().unwrap();
    assert!(record.is_ready() && record.is_cached());
    assert_eq!(
        f.store.recover_stale(&id, &budget()).unwrap(),
        OwnerRecoveryOutcome::PublishedNeedsEntryLease
    );
    entry.downgrade_shared().unwrap();
    let leases = f.root.open_private_child(".leases").unwrap();
    use sha2::{Digest, Sha256};
    let key_id = format!("{:x}", Sha256::digest(format!("{trace}:{parser}")));
    let another = Lease::acquire(
        &leases,
        &format!("{key_id}.lease"),
        LeaseMode::Shared,
        &budget(),
    )
    .unwrap();
    assert_eq!(
        f.store.quarantine_cached(&record, &key, &entry, &budget()),
        Err(HostError::InvalidEvidence)
    );
    assert!(
        Lease::try_acquire(
            &leases,
            &format!("{key_id}.lease"),
            LeaseMode::Exclusive,
            false
        )
        .unwrap()
        .is_none()
    );
    drop(another);
    drop(entry);
    let exclusive = Lease::acquire(
        &leases,
        &format!("{key_id}.lease"),
        LeaseMode::Exclusive,
        &budget(),
    )
    .unwrap();
    f.store
        .quarantine_cached(&record, &key, &exclusive, &budget())
        .unwrap();
    assert!(!hash.path().join(&parser).exists());
    let quarantined = f
        .root
        .open_private_child(".corrupt")
        .unwrap()
        .open_private_child(&id)
        .unwrap();
    assert_eq!(
        quarantined
            .open_file("view-state.json")
            .unwrap()
            .read_bounded(&budget())
            .unwrap(),
        b"user sidecar"
    );
    let current = f.store.published_evidence(&id, &budget()).unwrap().unwrap();
    assert!(current.is_quarantined());
    f.store
        .quarantine_cached(&current, &key, &exclusive, &budget())
        .unwrap();
    assert_eq!(
        f.store
            .recover_cached_build(&current, &key, &exclusive, &budget())
            .unwrap(),
        OwnerRecoveryOutcome::PublishedNeedsEntryLease
    );
    assert!(leases.path().join(format!("{key_id}.lease")).exists());
}

#[test]
fn abandoned_cached_publishing_before_rename_is_recovered_without_removing_stable_lease() {
    let f = Fixture::new();
    let (trace, parser, key, entry) = cache_authority(&f);
    let hash = f.root.ensure_private_child(&trace).unwrap();
    let mut owner = f.store.create(OwnerKind::Building, &budget()).unwrap();
    let id = owner.identifier().to_owned();
    let path = owner.directory().path().to_path_buf();
    owner
        .bind_cached(&key, &entry, &format!("{trace}/{parser}"), &budget())
        .unwrap();
    owner
        .directory()
        .write_new_readonly("partial", b"partial", &budget())
        .unwrap();
    owner
        .prepare_cached_publication(&hash, &parser, &key, &entry, &budget())
        .unwrap();
    drop(owner);
    let record = f.store.published_evidence(&id, &budget()).unwrap().unwrap();
    assert!(record.is_publishing());
    assert_eq!(
        f.store
            .recover_cached_build(&record, &key, &entry, &budget())
            .unwrap(),
        OwnerRecoveryOutcome::Removed
    );
    assert!(!path.exists());
    assert!(f.store.identifiers(&budget()).unwrap().is_empty());
    assert_eq!(
        fs::read_dir(f.root.path().join(".leases")).unwrap().count(),
        1
    );
}

#[test]
fn cached_owner_rejects_wrong_key_and_replaced_entry_lease_identity() {
    use arktrace_platform::{Lease, LeaseMode};
    let f = Fixture::new();
    let (trace, parser, key, entry) = cache_authority(&f);
    let mut owner = f.store.create(OwnerKind::Building, &budget()).unwrap();
    let id = owner.identifier().to_owned();
    owner
        .bind_cached(&key, &entry, &format!("{trace}/{parser}"), &budget())
        .unwrap();
    let record = f.store.published_evidence(&id, &budget()).unwrap().unwrap();
    let wrong = Lease::acquire(
        &f.root.open_private_child(".locks").unwrap(),
        "wrong.lock",
        LeaseMode::Exclusive,
        &budget(),
    )
    .unwrap();
    assert!(
        f.store
            .validate_cached_location(&record, &wrong, &entry, &budget())
            .is_err()
    );
    let leases = f.root.open_private_child(".leases").unwrap();
    let lease_path = fs::read_dir(leases.path())
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    fs::rename(&lease_path, f.path.join("displaced.lease")).unwrap();
    let replacement = Lease::acquire(
        &leases,
        lease_path.file_name().unwrap().to_str().unwrap(),
        LeaseMode::Exclusive,
        &budget(),
    )
    .unwrap();
    assert!(
        f.store
            .validate_cached_location(&record, &key, &replacement, &budget())
            .is_err()
    );
    assert!(owner.directory().path().exists());
}

#[test]
fn readonly_document_replacement_preserves_current_bytes_and_rejects_stale_fd() {
    let f = Fixture::new();
    let old = f
        .stage
        .write_new_readonly("metadata.json", b"old", &budget())
        .unwrap();
    let current = f.stage.replace_readonly(&old, b"new", &budget()).unwrap();
    assert_eq!(current.read_bounded(&budget()).unwrap(), b"new");
    assert!(f.stage.replace_readonly(&old, b"stale", &budget()).is_err());
    assert_eq!(
        f.stage
            .open_file("metadata.json")
            .unwrap()
            .read_bounded(&budget())
            .unwrap(),
        b"new"
    );
    assert!(!fs::read_dir(f.stage.path()).unwrap().any(|v| {
        v.unwrap()
            .file_name()
            .to_string_lossy()
            .starts_with(".arktrace-atomic")
    }));
}

#[test]
fn cancelled_cache_binding_disposes_its_still_generic_candidate() {
    let f = Fixture::new();
    let (trace, parser, key, entry) = cache_authority(&f);
    let mut owner = f.store.create(OwnerKind::Building, &budget()).unwrap();
    let path = owner.directory().path().to_path_buf();
    let cancelled = budget();
    cancelled.cancellation.cancel();
    assert_eq!(
        owner.bind_cached(&key, &entry, &format!("{trace}/{parser}"), &cancelled),
        Err(HostError::Cancelled)
    );
    owner.cleanup_cached(&key, &entry, &budget()).unwrap();
    assert!(!path.exists());
    assert!(f.store.identifiers(&budget()).unwrap().is_empty());
    assert_eq!(
        fs::read_dir(f.root.path().join(".leases")).unwrap().count(),
        1
    );
}

#[test]
fn active_owner_blocks_recovery_then_stale_identity_is_reclaimed() {
    let fixture = Fixture::new();
    let owner = fixture
        .store
        .create(OwnerKind::Building, &budget())
        .unwrap();
    let identifier = owner.identifier().to_owned();
    let path = owner.directory().path().to_path_buf();
    owner
        .directory()
        .write_new_readonly("partial", b"partial", &budget())
        .unwrap();
    assert_eq!(
        fixture.store.recover_stale(&identifier, &budget()).unwrap(),
        OwnerRecoveryOutcome::Active
    );
    let record: serde_json::Value = serde_json::from_slice(
        &fs::read(
            fixture
                .stage
                .path()
                .join(".owners")
                .join(format!("{identifier}.json")),
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(record["formatVersion"], 2);
    assert_eq!(record["state"], "building");
    assert!(!record["relativePath"].as_str().unwrap().starts_with('/'));
    assert_eq!(
        fs::metadata(path.join("partial"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o400
    );
    drop(owner);
    assert_eq!(
        fixture.store.recover_stale(&identifier, &budget()).unwrap(),
        OwnerRecoveryOutcome::Removed
    );
    assert!(!path.exists());
    assert!(fixture.store.identifiers(&budget()).unwrap().is_empty());
    assert_eq!(
        fs::read_dir(fixture.stage.path().join(".owners"))
            .unwrap()
            .count(),
        0
    );
}

#[test]
fn stale_relocated_owner_is_found_and_replacement_path_is_preserved() {
    let fixture = Fixture::new();
    let owner = fixture.store.create(OwnerKind::Session, &budget()).unwrap();
    let identifier = owner.identifier().to_owned();
    let original = owner.directory().path().to_path_buf();
    let relocated = fixture.path.join("relocated");
    owner
        .directory()
        .write_new_readonly("owned", b"owned", &budget())
        .unwrap();
    fs::rename(&original, &relocated).unwrap();
    DirBuilder::new().mode(0o700).create(&original).unwrap();
    write_private(&original.join("foreign"), b"preserve");
    drop(owner);
    assert_eq!(
        fixture.store.recover_stale(&identifier, &budget()).unwrap(),
        OwnerRecoveryOutcome::Removed
    );
    assert!(!relocated.exists());
    assert_eq!(fs::read(original.join("foreign")).unwrap(), b"preserve");
}

#[test]
fn cleanup_recurses_bounded_held_directories_and_never_follows_links() {
    let fixture = Fixture::new();
    let mut owner = fixture.store.create(OwnerKind::Session, &budget()).unwrap();
    let path = owner.directory().path().to_path_buf();
    let outside = fixture.root.create_private_child("outside").unwrap();
    outside
        .write_new_readonly("raw", b"raw-bytes", &budget())
        .unwrap();
    let nested = owner.directory().create_private_child("nested").unwrap();
    nested
        .write_new_readonly("file", b"nested", &budget())
        .unwrap();
    symlink(outside.path(), path.join("outside-link")).unwrap();
    fs::hard_link(outside.path().join("raw"), path.join("raw-hard-link")).unwrap();
    owner.cleanup(&budget()).unwrap();
    owner.cleanup(&budget()).unwrap();
    assert!(!path.exists());
    assert_eq!(fs::read(outside.path().join("raw")).unwrap(), b"raw-bytes");
    assert_eq!(fs::read_dir(outside.path()).unwrap().count(), 1);
}

#[test]
fn published_owner_survives_generic_staging_recovery_and_needs_entry_authority() {
    let fixture = Fixture::new();
    let mut owner = fixture
        .store
        .create(OwnerKind::Building, &budget())
        .unwrap();
    let identifier = owner.identifier().to_owned();
    owner
        .directory()
        .write_new_readonly("trace.db", b"database", &budget())
        .unwrap();
    let sealed = owner
        .directory()
        .seal_readonly_directory(&budget())
        .unwrap();
    let published_root = fixture.root.create_private_child("published").unwrap();
    let published = fixture
        .stage
        .promote_sealed_directory_noreplace(&sealed, &published_root, "ready", &budget())
        .unwrap();
    owner
        .record_published_location(&published, &budget())
        .unwrap();
    drop(owner);
    assert_eq!(
        fixture.store.recover_stale(&identifier, &budget()).unwrap(),
        OwnerRecoveryOutcome::PublishedNeedsEntryLease
    );
    assert_eq!(
        fs::read(published.path().join("trace.db")).unwrap(),
        b"database"
    );
    assert_eq!(fixture.store.identifiers(&budget()).unwrap(), [identifier]);
}

#[test]
fn malformed_unknown_and_escaped_evidence_is_preserved_without_target_mutation() {
    for mode in [
        "version",
        "unknown-field",
        "duplicate-state",
        "escape",
        "creating",
        "missing-identity",
    ] {
        let fixture = Fixture::new();
        let owner = fixture
            .store
            .create(OwnerKind::Building, &budget())
            .unwrap();
        let identifier = owner.identifier().to_owned();
        let path = owner.directory().path().to_path_buf();
        owner
            .directory()
            .write_new_readonly("owned", b"keep", &budget())
            .unwrap();
        drop(owner);
        let record_path = fixture
            .stage
            .path()
            .join(".owners")
            .join(format!("{identifier}.json"));
        let mut record: serde_json::Value =
            serde_json::from_slice(&fs::read(&record_path).unwrap()).unwrap();
        let expected = match mode {
            "version" => {
                record["formatVersion"] = 99.into();
                Ok(OwnerRecoveryOutcome::UnsupportedVersion)
            }
            "unknown-field" => {
                record["unexpected"] = true.into();
                Err(HostError::InvalidEvidence)
            }
            "escape" => {
                record["relativePath"] = "../outside".into();
                Err(HostError::InvalidEvidence)
            }
            "duplicate-state" => Err(HostError::InvalidEvidence),
            "creating" => {
                record["state"] = "creating".into();
                record["device"] = serde_json::Value::Null;
                record["inode"] = serde_json::Value::Null;
                Ok(OwnerRecoveryOutcome::CreatingUnbound)
            }
            _ => {
                record["inode"] = serde_json::Value::Null;
                Err(HostError::InvalidEvidence)
            }
        };
        fs::remove_file(&record_path).unwrap();
        let mut bytes = serde_json::to_vec(&record).unwrap();
        if mode == "duplicate-state" {
            bytes = String::from_utf8(bytes)
                .unwrap()
                .replace(
                    "\"state\":\"building\"",
                    "\"state\":\"ready\",\"state\":\"building\"",
                )
                .into_bytes();
        }
        write_private(&record_path, &bytes);
        assert_eq!(
            fixture.store.recover_stale(&identifier, &budget()),
            expected
        );
        assert_eq!(fs::read(path.join("owned")).unwrap(), b"keep");
        assert!(record_path.exists());
    }
}

#[test]
fn cleanup_depth_limit_preserves_identity_record_for_resuming() {
    let fixture = Fixture::new();
    let mut owner = fixture
        .store
        .create(OwnerKind::Building, &budget())
        .unwrap();
    let identifier = owner.identifier().to_owned();
    let mut directory = owner.directory().clone();
    for i in 0..9 {
        directory = directory
            .create_private_child(&format!("level-{i}"))
            .unwrap();
    }
    directory
        .write_new_readonly("deep", b"deep", &budget())
        .unwrap();
    assert_eq!(owner.cleanup(&budget()), Err(HostError::LimitExceeded));
    assert_eq!(fixture.store.identifiers(&budget()).unwrap(), [identifier]);
    assert!(owner.directory().path().exists());
}

struct Worker(Child);
impl Drop for Worker {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let end = Instant::now() + Duration::from_secs(3);
        while self.0.try_wait().unwrap().is_none() {
            assert!(Instant::now() < end, "owner worker was not reaped");
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}
#[test]
fn sigkill_releases_real_owner_lease_and_next_process_recovers_staging() {
    let fixture = Fixture::new();
    let mut worker = Worker(
        Command::new(env!("CARGO_BIN_EXE_arktrace-process-fixture"))
            .args(["owner-worker", fixture.path.to_str().unwrap()])
            .spawn()
            .unwrap(),
    );
    let end = Instant::now() + Duration::from_secs(5);
    let marker = loop {
        if let Ok(bytes) = fs::read(fixture.path.join("worker-owner.json"))
            && let Ok(value) = serde_json::from_slice::<serde_json::Value>(&bytes)
        {
            break value;
        }
        assert!(Instant::now() < end);
        std::thread::sleep(Duration::from_millis(5));
    };
    let identifier = marker["identifier"].as_str().unwrap();
    assert_eq!(
        fixture.store.recover_stale(identifier, &budget()).unwrap(),
        OwnerRecoveryOutcome::Active
    );
    worker.0.kill().unwrap();
    let end = Instant::now() + Duration::from_secs(3);
    while worker.0.try_wait().unwrap().is_none() {
        assert!(Instant::now() < end);
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(
        fixture.store.recover_stale(identifier, &budget()).unwrap(),
        OwnerRecoveryOutcome::Removed
    );
    assert!(
        !fixture
            .path
            .join(marker["relativePath"].as_str().unwrap())
            .exists()
    );
    assert!(fixture.store.identifiers(&budget()).unwrap().is_empty());
}

fn crash_window(fixture: &Fixture, mode: &str) -> String {
    let mut worker = Worker(
        Command::new(env!("CARGO_BIN_EXE_arktrace-process-fixture"))
            .args(["owner-worker", fixture.path.to_str().unwrap(), mode])
            .spawn()
            .unwrap(),
    );
    let end = Instant::now() + Duration::from_secs(5);
    let marker = loop {
        if let Ok(bytes) = fs::read(fixture.path.join("owner-window.json"))
            && let Ok(value) = serde_json::from_slice::<serde_json::Value>(&bytes)
        {
            break value;
        }
        assert!(
            worker.0.try_wait().unwrap().is_none(),
            "worker exited before owner window"
        );
        assert!(Instant::now() < end);
        std::thread::sleep(Duration::from_millis(5));
    };
    let identifier = marker["identifier"].as_str().unwrap().to_owned();
    assert_eq!(
        fixture.store.recover_stale(&identifier, &budget()).unwrap(),
        OwnerRecoveryOutcome::Active
    );
    worker.0.kill().unwrap();
    let end = Instant::now() + Duration::from_secs(3);
    while worker.0.try_wait().unwrap().is_none() {
        assert!(Instant::now() < end);
        std::thread::sleep(Duration::from_millis(5));
    }
    identifier
}

#[test]
fn sigkill_at_creating_mkdir_and_bound_windows_preserves_or_reclaims_exact_proof() {
    for point in 0..3 {
        let fixture = Fixture::new();
        let identifier = crash_window(&fixture, &format!("create-{point}"));
        let outcome = fixture.store.recover_stale(&identifier, &budget()).unwrap();
        if point < 2 {
            assert_eq!(outcome, OwnerRecoveryOutcome::CreatingUnbound);
            assert_eq!(
                fixture.store.identifiers(&budget()).unwrap().as_slice(),
                std::slice::from_ref(&identifier)
            );
            assert_eq!(fixture.stage.path().join(identifier).exists(), point == 1);
        } else {
            assert_eq!(outcome, OwnerRecoveryOutcome::Removed);
            assert!(fixture.store.identifiers(&budget()).unwrap().is_empty());
        }
    }
}

#[test]
fn sigkill_at_cleanup_windows_recovers_or_retains_unresolved_identity_without_guessing() {
    for point in 0..5 {
        let fixture = Fixture::new();
        let identifier = crash_window(&fixture, &format!("cleanup-{point}"));
        let outcome = fixture.store.recover_stale(&identifier, &budget()).unwrap();
        if point == 3 {
            // rmdir succeeded but the durable removed tombstone did not. An
            // escaped directory is indistinguishable, so keep identity proof.
            assert_eq!(outcome, OwnerRecoveryOutcome::IdentityUnresolved);
            assert_eq!(fixture.store.identifiers(&budget()).unwrap(), [identifier]);
        } else {
            assert_eq!(outcome, OwnerRecoveryOutcome::Removed);
            assert!(fixture.store.identifiers(&budget()).unwrap().is_empty());
            assert_eq!(
                fs::read_dir(fixture.stage.path().join(".owners"))
                    .unwrap()
                    .count(),
                0
            );
        }
    }
}

#[test]
fn owner_moved_outside_recovery_root_retains_proof_and_never_deletes_escaped_bytes() {
    let fixture = Fixture::new();
    let owner = fixture
        .store
        .create(OwnerKind::Building, &budget())
        .unwrap();
    let identifier = owner.identifier().to_owned();
    owner
        .directory()
        .write_new_readonly("payload", b"preserve", &budget())
        .unwrap();
    let escaped = fixture.path.with_extension("escaped");
    fs::rename(owner.directory().path(), &escaped).unwrap();
    drop(owner);
    assert_eq!(
        fixture.store.recover_stale(&identifier, &budget()).unwrap(),
        OwnerRecoveryOutcome::IdentityUnresolved
    );
    assert_eq!(fs::read(escaped.join("payload")).unwrap(), b"preserve");
    assert_eq!(fixture.store.identifiers(&budget()).unwrap(), [identifier]);
    fs::remove_dir_all(escaped).unwrap();
}
