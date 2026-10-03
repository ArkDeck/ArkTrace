#![cfg(target_os = "macos")]

use arktrace_platform::{
    CancellationToken, EphemeralLease, HeldDirectory, HeldFile, HostError, IoBudget, Lease,
    LeaseMode,
};
use std::{
    fs::{self, DirBuilder, Permissions},
    os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt, symlink},
    path::{Path, PathBuf},
    process::Command,
    sync::atomic::{AtomicU64, Ordering},
    time::{Duration, Instant},
};

static NEXT: AtomicU64 = AtomicU64::new(0);
struct Fixture(PathBuf);

impl Fixture {
    fn new() -> Self {
        let base = std::env::temp_dir().canonicalize().unwrap();
        let path = base.join(format!(
            "arktrace-native-{}-{}-空 格",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        DirBuilder::new().mode(0o700).create(&path).unwrap();
        Self(path)
    }
    fn held(&self) -> HeldDirectory {
        HeldDirectory::open_private(&self.0).unwrap()
    }
    fn raw(&self, name: &str, bytes: &[u8]) -> HeldFile {
        fs::write(self.0.join(name), bytes).unwrap();
        HeldFile::open_explicit_source(&self.0.join(name)).unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}
fn budget(maximum_bytes: u64) -> IoBudget {
    IoBudget {
        maximum_bytes,
        deadline: Instant::now() + Duration::from_secs(10),
        cancellation: CancellationToken::default(),
    }
}

#[test]
fn ephemeral_lease_is_fresh_exclusive_and_removed_without_admitting_existing_names() {
    let fixture = Fixture::new();
    let root = fixture.held();
    let lease = EphemeralLease::acquire(&root, "session.lease", &budget(100)).unwrap();
    assert!(
        Lease::try_acquire(&root, "session.lease", LeaseMode::Exclusive, false)
            .unwrap()
            .is_none()
    );
    assert!(matches!(
        EphemeralLease::acquire(&root, "session.lease", &budget(100)),
        Err(HostError::AlreadyExists)
    ));
    lease.remove().unwrap();
    assert!(!fixture.0.join("session.lease").exists());
    let next = EphemeralLease::acquire(&root, "session.lease", &budget(100)).unwrap();
    next.remove().unwrap();
}

#[test]
fn ephemeral_lease_replacement_is_preserved_and_original_proof_is_not_unlinked() {
    let fixture = Fixture::new();
    let root = fixture.held();
    let lease = EphemeralLease::acquire(&root, "session.lease", &budget(100)).unwrap();
    fs::rename(
        fixture.0.join("session.lease"),
        fixture.0.join("original.lease"),
    )
    .unwrap();
    fs::write(fixture.0.join("session.lease"), b"foreign").unwrap();
    assert_eq!(lease.remove(), Err(HostError::IdentityMismatch));
    assert_eq!(
        fs::read(fixture.0.join("session.lease")).unwrap(),
        b"foreign"
    );
    assert!(fixture.0.join("original.lease").exists());
}

#[test]
fn private_child_and_exact_membership_refuse_replacements_links_and_extra_files() {
    let fixture = Fixture::new();
    let root = fixture.held();
    let child = root.ensure_private_child("owned").unwrap();
    assert_eq!(
        root.ensure_private_child("owned").unwrap().identity(),
        child.identity()
    );
    child
        .write_new_readonly("data", b"d", &budget(100))
        .unwrap();
    child
        .require_file_membership(&["data"], &budget(100))
        .unwrap();
    child
        .write_new_readonly("extra", b"e", &budget(100))
        .unwrap();
    assert_eq!(
        child.require_file_membership(&["data"], &budget(100)),
        Err(HostError::InvalidEvidence)
    );
    symlink(fixture.0.join("owned"), fixture.0.join("linked")).unwrap();
    assert!(root.ensure_private_child("linked").is_err());
    assert!(root.open_private_child("../owned").is_err());
}

#[test]
fn publishes_complete_sealed_directory_with_literal_unicode_payloads() {
    let fixture = Fixture::new();
    let root = fixture.held();
    let stage = root.create_private_child("stage").unwrap();
    let destination = root.create_private_child("published").unwrap();
    stage
        .write_new_readonly("数据库.db", b"database", &budget(100))
        .unwrap();
    stage
        .write_new_readonly("metadata.json", b"{}", &budget(100))
        .unwrap();
    let sealed = stage.seal_readonly_directory(&budget(100)).unwrap();
    assert_eq!(sealed.file_count(), 2);
    assert_eq!(sealed.byte_count(), 10);
    // Repeated scans must not share a directory cursor or drop members.
    sealed.verify(&budget(100)).unwrap();
    sealed.verify(&budget(100)).unwrap();
    let published = root
        .promote_sealed_directory_noreplace(&sealed, &destination, "完整 entry", &budget(100))
        .unwrap();
    assert_eq!(published.identity(), stage.identity());
    assert_eq!(
        published
            .open_file("数据库.db")
            .unwrap()
            .read_bounded(&budget(100))
            .unwrap(),
        b"database"
    );
    assert_eq!(
        published
            .open_file("metadata.json")
            .unwrap()
            .read_bounded(&budget(100))
            .unwrap(),
        b"{}"
    );
    assert!(!stage.path().exists());
    assert_eq!(fs::read_dir(published.path()).unwrap().count(), 2);
}

#[test]
fn sealed_directory_refuses_aggregate_excess_and_membership_changes() {
    let fixture = Fixture::new();
    let root = fixture.held();
    let stage = root.create_private_child("stage").unwrap();
    stage.write_new_readonly("a", b"123", &budget(10)).unwrap();
    stage.write_new_readonly("b", b"45", &budget(10)).unwrap();
    assert!(matches!(
        stage.seal_readonly_directory(&budget(4)),
        Err(HostError::LimitExceeded)
    ));
    let sealed = stage.seal_readonly_directory(&budget(10)).unwrap();
    stage.write_new_readonly("new", b"x", &budget(10)).unwrap();
    assert_eq!(sealed.verify(&budget(10)), Err(HostError::Changed));
    let crowded = root.create_private_child("crowded").unwrap();
    for index in 0..65 {
        crowded
            .write_new_readonly(&format!("file-{index}"), b"x", &budget(100))
            .unwrap();
    }
    assert!(matches!(
        crowded.seal_readonly_directory(&budget(100)),
        Err(HostError::LimitExceeded)
    ));
}

#[test]
fn sealed_directory_refuses_writable_links_and_nested_payloads_without_chmod() {
    let fixture = Fixture::new();
    let root = fixture.held();
    let writable = root.create_private_child("writable").unwrap();
    fs::write(writable.path().join("db"), b"db").unwrap();
    fs::set_permissions(writable.path().join("db"), Permissions::from_mode(0o600)).unwrap();
    assert!(matches!(
        writable.seal_readonly_directory(&budget(100)),
        Err(HostError::NotPrivate)
    ));
    assert_eq!(
        fs::metadata(writable.path().join("db")).unwrap().mode() & 0o777,
        0o600
    );
    let linked = root.create_private_child("linked").unwrap();
    let raw = fixture.raw("raw", b"original");
    symlink(raw.path(), linked.path().join("db")).unwrap();
    assert!(matches!(
        linked.seal_readonly_directory(&budget(100)),
        Err(HostError::LinkedObject)
    ));
    assert_eq!(fs::read(raw.path()).unwrap(), b"original");
    let hard = root.create_private_child("hard").unwrap();
    hard.write_new_readonly("a", b"db", &budget(100)).unwrap();
    fs::hard_link(hard.path().join("a"), hard.path().join("b")).unwrap();
    assert!(matches!(
        hard.seal_readonly_directory(&budget(100)),
        Err(HostError::LinkedObject)
    ));
    let nested = root.create_private_child("nested").unwrap();
    nested.create_private_child("child").unwrap();
    assert!(matches!(
        nested.seal_readonly_directory(&budget(100)),
        Err(HostError::NotRegular)
    ));
}

#[test]
fn directory_promotion_never_overwrites_existing_file_directory_or_symlink() {
    let fixture = Fixture::new();
    let root = fixture.held();
    let stage = root.create_private_child("stage").unwrap();
    let target = root.create_private_child("target").unwrap();
    stage
        .write_new_readonly("db", b"candidate", &budget(100))
        .unwrap();
    let sealed = stage.seal_readonly_directory(&budget(100)).unwrap();
    fs::write(target.path().join("file"), b"original").unwrap();
    target.create_private_child("directory").unwrap();
    symlink(stage.path(), target.path().join("link")).unwrap();
    for name in ["file", "directory", "link"] {
        assert!(matches!(
            root.promote_sealed_directory_noreplace(&sealed, &target, name, &budget(100)),
            Err(HostError::AlreadyExists)
        ));
        sealed.verify(&budget(100)).unwrap();
    }
    assert_eq!(fs::read(target.path().join("file")).unwrap(), b"original");
    assert!(target.path().join("directory").is_dir());
    assert_eq!(
        fs::read_link(target.path().join("link")).unwrap(),
        stage.path()
    );
}

#[test]
fn accepts_native_unicode_components_beyond_255_utf8_bytes() {
    let fixture = Fixture::new();
    let name = format!("{}.htrace", "名".repeat(150));
    assert!(name.len() > 255);
    let source = fixture.raw(&name, b"trace");
    assert_eq!(source.read_bounded(&budget(100)).unwrap(), b"trace");
    let root = fixture.held();
    let directory = root.create_private_child(&"层".repeat(90)).unwrap();
    directory
        .copy_snapshot(&source, &name, false, &budget(100))
        .unwrap();
    let seal = directory.seal_readonly_directory(&budget(100)).unwrap();
    assert_eq!(seal.file_count(), 1);
    let published_root = root.create_private_child("published").unwrap();
    let published = root
        .promote_sealed_directory_noreplace(&seal, &published_root, "entry", &budget(100))
        .unwrap();
    assert_eq!(
        published
            .open_file(&name)
            .unwrap()
            .read_bounded(&budget(100))
            .unwrap(),
        b"trace"
    );
    source.verify().unwrap();
}

#[test]
fn copies_unicode_source_to_verified_readonly_snapshot_without_mutating_input() {
    let fixture = Fixture::new();
    let source = fixture.raw("原始 \"$() trace.htrace", b"abc");
    let initial = source.snapshot();
    let root = fixture.held();
    let stage = root.create_private_child("staging").unwrap();
    let (snapshot, facts) = stage
        .copy_snapshot(&source, "input.trace", false, &budget(3))
        .unwrap();
    assert_eq!(facts.byte_count, 3);
    assert_eq!(
        facts.sha256,
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
    assert_ne!(snapshot.snapshot().identity, initial.identity);
    assert_eq!(fs::metadata(snapshot.path()).unwrap().mode() & 0o777, 0o400);
    assert_eq!(snapshot.read_bounded(&budget(3)).unwrap(), b"abc");
    assert_eq!(source.snapshot(), initial);
    source.verify().unwrap();
    assert_eq!(fs::read(source.path()).unwrap(), b"abc");
}

#[test]
fn resolves_explicit_source_link_once_but_refuses_links_inside_storage() {
    let fixture = Fixture::new();
    let source = fixture.raw("source", b"abc");
    let alias = fixture.0.join("alias");
    symlink(source.path(), &alias).unwrap();
    let explicit = HeldFile::open_explicit_source(&alias).unwrap();
    assert_eq!(explicit.snapshot().identity, source.snapshot().identity);
    fs::remove_file(&alias).unwrap();
    symlink("absent", &alias).unwrap();
    assert_eq!(explicit.facts(&budget(3)).unwrap().byte_count, 3);
    assert!(matches!(
        fixture.held().open_file("alias"),
        Err(HostError::LinkedObject)
    ));
    assert!(HeldDirectory::open_private(&alias).is_err());
}

#[test]
fn permits_raw_hard_links_and_refuses_private_file_or_lease_hard_links() {
    let fixture = Fixture::new();
    let source = fixture.raw("raw", b"data");
    fs::hard_link(source.path(), fixture.0.join("raw-alias")).unwrap();
    let reopened = HeldFile::open_explicit_source(&source.path()).unwrap();
    assert_eq!(reopened.facts(&budget(4)).unwrap().byte_count, 4);
    let root = fixture.held();
    let file = root
        .write_new_readonly("private", b"data", &budget(4))
        .unwrap();
    fs::hard_link(file.path(), fixture.0.join("private-alias")).unwrap();
    assert!(matches!(
        root.open_file("private"),
        Err(HostError::LinkedObject)
    ));
    let lease = Lease::try_acquire(&root, "active.lease", LeaseMode::Shared, true)
        .unwrap()
        .unwrap();
    fs::hard_link(
        fixture.0.join("active.lease"),
        fixture.0.join("lease-alias"),
    )
    .unwrap();
    assert_eq!(lease.revalidate(), Err(HostError::IdentityMismatch));
    assert!(matches!(
        Lease::try_acquire(&root, "active.lease", LeaseMode::Shared, false),
        Err(HostError::LinkedObject)
    ));
}

#[test]
fn rejects_existing_public_directory_and_writable_ancestor_without_chmod() {
    let fixture = Fixture::new();
    fs::set_permissions(&fixture.0, Permissions::from_mode(0o755)).unwrap();
    assert!(matches!(
        HeldDirectory::open_private(&fixture.0),
        Err(HostError::NotPrivate)
    ));
    assert_eq!(fs::metadata(&fixture.0).unwrap().mode() & 0o777, 0o755);
    let child = fixture.0.join("private-child");
    DirBuilder::new().mode(0o700).create(&child).unwrap();
    fs::set_permissions(&fixture.0, Permissions::from_mode(0o777)).unwrap();
    assert!(matches!(
        HeldDirectory::open_private(&child),
        Err(HostError::NotPrivate)
    ));
    assert_eq!(fs::metadata(&fixture.0).unwrap().mode() & 0o777, 0o777);
    fs::set_permissions(&fixture.0, Permissions::from_mode(0o700)).unwrap();
}

#[test]
fn rejects_acl_grants_even_when_mode_bits_are_private_and_preserves_acl() {
    let fixture = Fixture::new();
    let status = Command::new("/bin/chmod")
        .arg("+a")
        .arg("everyone allow list,search")
        .arg(&fixture.0)
        .status()
        .unwrap();
    assert!(status.success());
    assert_eq!(fs::metadata(&fixture.0).unwrap().mode() & 0o777, 0o700);
    let before = Command::new("/bin/ls")
        .arg("-lde")
        .arg(&fixture.0)
        .output()
        .unwrap()
        .stdout;
    assert!(matches!(
        HeldDirectory::open_private(&fixture.0),
        Err(HostError::NotPrivate)
    ));
    let after = Command::new("/bin/ls")
        .arg("-lde")
        .arg(&fixture.0)
        .output()
        .unwrap()
        .stdout;
    assert_eq!(before, after);
    Command::new("/bin/chmod")
        .arg("-N")
        .arg(&fixture.0)
        .status()
        .unwrap();
}

#[test]
fn accepts_deny_only_acl_and_rejects_allow_acl_on_private_file_and_lease() {
    let fixture = Fixture::new();
    let status = Command::new("/bin/chmod")
        .arg("+a")
        .arg("everyone deny delete")
        .arg(&fixture.0)
        .status()
        .unwrap();
    assert!(status.success());
    let root = fixture.held();
    let file = root
        .write_new_readonly("snapshot", b"abc", &budget(3))
        .unwrap();
    let status = Command::new("/bin/chmod")
        .arg("+a")
        .arg("everyone allow read")
        .arg(file.path())
        .status()
        .unwrap();
    assert!(status.success());
    assert!(matches!(
        root.open_file("snapshot"),
        Err(HostError::NotPrivate)
    ));
    let lease = Lease::acquire(&root, "active.lease", LeaseMode::Shared, &budget(1)).unwrap();
    let status = Command::new("/bin/chmod")
        .arg("+a")
        .arg("everyone allow read")
        .arg(fixture.0.join("active.lease"))
        .status()
        .unwrap();
    assert!(status.success());
    assert_eq!(lease.revalidate(), Err(HostError::NotPrivate));
    assert!(matches!(
        Lease::try_acquire(&root, "active.lease", LeaseMode::Shared, false),
        Err(HostError::NotPrivate)
    ));
    assert!(
        Command::new("/bin/chmod")
            .arg("-N")
            .arg(&fixture.0)
            .status()
            .unwrap()
            .success()
    );
}

#[test]
fn refuses_nonregular_objects_and_path_escape_without_blocking_on_fifo() {
    let fixture = Fixture::new();
    let root = fixture.held();
    root.create_private_child("directory").unwrap();
    assert!(matches!(
        root.open_file("directory"),
        Err(HostError::NotRegular)
    ));
    for name in ["", ".", "..", "a/b", "nul\0component"] {
        assert!(matches!(root.open_file(name), Err(HostError::InvalidPath)));
    }
    assert!(matches!(
        root.create_private_child(&"x".repeat(256)),
        Err(HostError::InvalidPath)
    ));
    let result = Command::new("/usr/bin/mkfifo")
        .arg(fixture.0.join("fifo"))
        .status()
        .unwrap();
    assert!(result.success());
    assert!(matches!(root.open_file("fifo"), Err(HostError::NotRegular)));
}

#[test]
fn detects_in_place_mutation_and_replaced_source() {
    let fixture = Fixture::new();
    let source = fixture.raw("source", b"abc");
    fs::write(source.path(), b"xyz").unwrap();
    assert_eq!(source.verify(), Err(HostError::Changed));
    let changed = HeldFile::open_explicit_source(&source.path()).unwrap();
    fs::rename(source.path(), fixture.0.join("original")).unwrap();
    fs::write(source.path(), b"replacement").unwrap();
    assert_eq!(changed.verify(), Err(HostError::IdentityMismatch));
    assert_eq!(fs::read(source.path()).unwrap(), b"replacement");
}

#[test]
fn ancestor_replacement_prevents_publication_and_owned_deletion() {
    let fixture = Fixture::new();
    let root = fixture.held();
    let parent = root.create_private_child("parent").unwrap();
    let stage = parent.create_private_child("stage").unwrap();
    let ready = parent.create_private_child("ready").unwrap();
    let file = stage
        .write_new_readonly("candidate", b"old", &budget(3))
        .unwrap();
    fs::rename(parent.path(), fixture.0.join("detached")).unwrap();
    let replacement = root.create_private_child("parent").unwrap();
    replacement.create_private_child("stage").unwrap();
    replacement.create_private_child("ready").unwrap();
    assert_eq!(stage.revalidate(), Err(HostError::IdentityMismatch));
    assert!(matches!(
        stage.promote_noreplace(&file, &ready, "db", &budget(3)),
        Err(HostError::IdentityMismatch)
    ));
    assert_eq!(
        stage.remove_owned_file("candidate", file.snapshot().identity),
        Err(HostError::IdentityMismatch)
    );
    assert_eq!(
        fs::read(fixture.0.join("detached/stage/candidate")).unwrap(),
        b"old"
    );
    assert!(!fixture.0.join("parent/ready/db").exists());
}

#[test]
fn cancelled_expired_and_oversized_operations_leave_no_partial_file() {
    let fixture = Fixture::new();
    let source = fixture.raw("source", b"abc");
    let root = fixture.held();
    let cancelled = budget(3);
    cancelled.cancellation.cancel();
    assert!(matches!(
        root.copy_snapshot(&source, "cancelled", false, &cancelled),
        Err(HostError::Cancelled)
    ));
    let expired = IoBudget {
        deadline: Instant::now(),
        ..budget(3)
    };
    assert!(matches!(
        root.copy_snapshot(&source, "expired", false, &expired),
        Err(HostError::DeadlineExceeded)
    ));
    assert!(matches!(
        root.copy_snapshot(&source, "too-large", false, &budget(2)),
        Err(HostError::LimitExceeded)
    ));
    assert_eq!(source.facts(&budget(0)), Err(HostError::InvalidLimit));
    assert_eq!(fs::read_dir(&fixture.0).unwrap().count(), 1);
}

#[test]
fn publishes_exact_same_volume_identity_and_never_overwrites_existing_target() {
    let fixture = Fixture::new();
    let root = fixture.held();
    let stage = root.create_private_child("stage").unwrap();
    let ready = root.create_private_child("ready").unwrap();
    let file = stage
        .write_new_readonly("candidate", b"db", &budget(2))
        .unwrap();
    let occupied = ready.write_new_readonly("db", b"user", &budget(4)).unwrap();
    assert!(matches!(
        stage.promote_noreplace(&file, &ready, "db", &budget(2)),
        Err(HostError::AlreadyExists)
    ));
    assert_eq!(occupied.read_bounded(&budget(4)).unwrap(), b"user");
    symlink("outside", ready.path().join("link")).unwrap();
    assert!(matches!(
        stage.promote_noreplace(&file, &ready, "link", &budget(2)),
        Err(HostError::AlreadyExists)
    ));
    let published = stage
        .promote_noreplace(&file, &ready, "result.db", &budget(2))
        .unwrap();
    assert_eq!(published.snapshot().identity, file.snapshot().identity);
    assert_eq!(published.read_bounded(&budget(2)).unwrap(), b"db");
    assert!(!stage.path().join("candidate").exists());
}

#[test]
fn owned_cleanup_preserves_replacement_and_only_removes_proven_identity() {
    let fixture = Fixture::new();
    let root = fixture.held();
    let file = root
        .write_new_readonly("candidate", b"old", &budget(3))
        .unwrap();
    fs::rename(file.path(), fixture.0.join("original")).unwrap();
    fs::write(file.path(), b"new").unwrap();
    assert_eq!(
        root.remove_owned_file("candidate", file.snapshot().identity),
        Err(HostError::IdentityMismatch)
    );
    assert_eq!(fs::read(file.path()).unwrap(), b"new");
    root.remove_owned_file("original", file.snapshot().identity)
        .unwrap();
    assert!(!fixture.0.join("original").exists());
    assert_eq!(fs::read_dir(&fixture.0).unwrap().count(), 1);
}

fn python_lock_probe(path: &Path, shared: bool) -> String {
    let program = "import fcntl,sys\nf=open(sys.argv[1], 'r+b')\ntry:\n fcntl.flock(f, (fcntl.LOCK_SH if sys.argv[2]=='shared' else fcntl.LOCK_EX)|fcntl.LOCK_NB)\n print('acquired')\nexcept BlockingIOError:\n print('busy')\n";
    let output = Command::new("/usr/bin/python3")
        .arg("-c")
        .arg(program)
        .arg(path)
        .arg(if shared { "shared" } else { "exclusive" })
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).unwrap().trim().to_owned()
}

#[test]
fn shared_readers_block_cross_process_purge_until_all_leases_close() {
    let fixture = Fixture::new();
    let root = fixture.held();
    let leases = root.create_private_child(".leases").unwrap();
    let path = leases.path().join("entry.lease");
    let first = Lease::acquire(&leases, "entry.lease", LeaseMode::Shared, &budget(1)).unwrap();
    let second = Lease::acquire(&leases, "entry.lease", LeaseMode::Shared, &budget(1)).unwrap();
    assert_eq!(python_lock_probe(&path, false), "busy");
    assert_eq!(python_lock_probe(&path, true), "acquired");
    assert!(
        Lease::try_acquire(&leases, "entry.lease", LeaseMode::Exclusive, false)
            .unwrap()
            .is_none()
    );
    drop(first);
    assert_eq!(python_lock_probe(&path, false), "busy");
    drop(second);
    assert_eq!(python_lock_probe(&path, false), "acquired");
    let exclusive =
        Lease::acquire(&leases, "entry.lease", LeaseMode::Exclusive, &budget(1)).unwrap();
    assert_eq!(python_lock_probe(&path, true), "busy");
    assert_eq!(python_lock_probe(&path, false), "busy");
    assert_eq!(fs::read(&path).unwrap(), b"");
    exclusive.revalidate().unwrap();
}

#[test]
fn lease_wait_is_bounded_and_replaced_lease_is_rejected() {
    let fixture = Fixture::new();
    let root = fixture.held();
    let lease = Lease::acquire(&root, "entry.lease", LeaseMode::Shared, &budget(1)).unwrap();
    let start = Instant::now();
    let short = IoBudget {
        deadline: start + Duration::from_millis(20),
        ..budget(1)
    };
    assert!(matches!(
        Lease::acquire(&root, "entry.lease", LeaseMode::Exclusive, &short),
        Err(HostError::DeadlineExceeded)
    ));
    assert!(start.elapsed() < Duration::from_secs(2));
    let cancelled = budget(1);
    cancelled.cancellation.cancel();
    assert!(matches!(
        Lease::acquire(&root, "entry.lease", LeaseMode::Exclusive, &cancelled),
        Err(HostError::Cancelled)
    ));
    fs::rename(fixture.0.join("entry.lease"), fixture.0.join("old.lease")).unwrap();
    root.write_new_readonly("entry.lease", b"replacement", &budget(11))
        .unwrap();
    assert_eq!(lease.revalidate(), Err(HostError::IdentityMismatch));
}

#[test]
fn held_files_directories_and_leases_are_not_inherited_by_exec() {
    let fixture = Fixture::new();
    let root = fixture.held();
    let source = fixture.raw("source", b"abc");
    let snapshot = root
        .copy_snapshot(&source, "snapshot", false, &budget(3))
        .unwrap();
    let lease = Lease::acquire(&root, "entry.lease", LeaseMode::Shared, &budget(1)).unwrap();
    let program = "import os,sys\nfor n in os.listdir('/dev/fd'):\n try:\n  target=os.readlink('/dev/fd/'+n)\n  if target.startswith(sys.argv[1]): print(target)\n except OSError: pass\n";
    let output = Command::new("/usr/bin/python3")
        .arg("-c")
        .arg(program)
        .arg(&fixture.0)
        .output()
        .unwrap();
    assert!(output.status.success());
    assert!(output.stdout.is_empty());
    snapshot.0.verify().unwrap();
    lease.revalidate().unwrap();
}
