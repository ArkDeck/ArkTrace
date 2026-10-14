use super::*;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT: AtomicU64 = AtomicU64::new(0);

/// A private fixture root `<temp>\arktrace-windows-<pid>-<n>` created through
/// the same trusted-parent path the product uses. Removed on drop.
pub(super) struct Fixture(pub(super) PathBuf, pub(super) HeldDirectory);
impl Fixture {
    pub(super) fn new() -> Self {
        let parent =
            HeldDirectory::open_trusted_temporary_parent(&known_local_app_data().unwrap()).unwrap();
        let name = component(OsStr::new(&format!(
            "arktrace-windows-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        )))
        .unwrap();
        parent.make_private_directory(&name).unwrap();
        let root = parent.open_child(&name, true, true).unwrap();
        Self(root.path().to_path_buf(), root)
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

pub(super) fn budget() -> IoBudget {
    IoBudget {
        maximum_bytes: 1 << 20,
        deadline: Instant::now() + Duration::from_secs(20),
        cancellation: crate::CancellationToken::default(),
    }
}

fn icacls(path: &Path, arguments: &[&str]) {
    let status = Command::new("icacls")
        .arg(path)
        .args(arguments)
        .output()
        .unwrap();
    assert!(status.status.success(), "{status:?}");
}

#[test]
fn identity_is_stable_across_reopen_and_rename_only_moves_change_time() {
    let f = Fixture::new();
    let first =
        f.1.write_new_readonly("payload", b"bytes", &budget())
            .unwrap();
    let again = f.1.open_file("payload").unwrap();
    assert_eq!(first.snapshot(), again.snapshot());
    assert_ne!(first.snapshot().identity.inode, 0);
    assert_eq!(
        first.snapshot().identity,
        f.1.open_file("payload").unwrap().snapshot().identity
    );
    let ready = f.1.create_private_child("ready").unwrap();
    let moved =
        f.1.promote_noreplace(&first, &ready, "payload", &budget())
            .unwrap();
    assert_eq!(moved.snapshot().identity, first.snapshot().identity);
    assert_eq!(moved.read_bounded(&budget()).unwrap(), b"bytes");
    assert_eq!(moved.facts(&budget()).unwrap().byte_count, 5);
}

#[test]
fn private_entries_are_owner_only_and_broader_dacls_are_refused() {
    let f = Fixture::new();
    let child = f.1.create_private_child("child").unwrap();
    assert!(Access::of(&child.0.file).unwrap().owner_private());
    let file = child.write_new_readonly("sealed", b"x", &budget()).unwrap();
    assert!(Access::of(&file.file).unwrap().sealed());
    file.require_readonly().unwrap();
    file.readonly_database_path().unwrap();
    // Grant Everyone read: the directory is no longer private, and a held
    // binding notices on its next revalidation.
    icacls(child.path(), &["/grant", "*S-1-1-0:(R)"]);
    assert_eq!(child.revalidate(), Err(HostError::NotPrivate));
    assert!(matches!(
        HeldDirectory::open_private(child.path()),
        Err(HostError::NotPrivate)
    ));
    assert!(matches!(file.verify(), Err(HostError::NotPrivate)));
    // A file whose DACL changes is refused as changed or not private.
    let other = f.1.write_new_readonly("other", b"y", &budget()).unwrap();
    icacls(&other.path(), &["/grant", "*S-1-1-0:(R)"]);
    assert!(matches!(
        other.verify(),
        Err(HostError::Changed | HostError::NotPrivate)
    ));
}

#[test]
fn junctions_and_reparse_points_are_never_followed() {
    let f = Fixture::new();
    let target = f.1.create_private_child("target").unwrap();
    target
        .write_new_readonly("inside", b"z", &budget())
        .unwrap();
    let link = f.0.join("link");
    let output = Command::new("cmd")
        .args(["/c", "mklink", "/J"])
        .arg(&link)
        .arg(target.path())
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    assert!(matches!(
        f.1.open_private_child("link"),
        Err(HostError::LinkedObject)
    ));
    assert!(matches!(
        HeldDirectory::open_private(&link.join("..").join("link")),
        Err(HostError::InvalidPath | HostError::LinkedObject)
    ));
    assert!(matches!(
        HeldDirectory::open_private(&link),
        Err(HostError::LinkedObject)
    ));
    assert_eq!(f.1.find_private_child("link").unwrap().map(|_| ()), None);
    assert!(matches!(
        f.1.open_file("link"),
        Err(HostError::LinkedObject | HostError::NotRegular)
    ));
    // Explicit raw inputs resolve links once, then hold the canonical file.
    let source = HeldFile::open_explicit_source(&link.join("inside")).unwrap();
    assert_eq!(source.read_bounded(&budget()).unwrap(), b"z");
}

#[test]
fn held_file_detects_replacement_deletion_and_in_place_mutation() {
    let f = Fixture::new();
    let held =
        f.1.write_new_readonly("payload", b"original", &budget())
            .unwrap();
    // POSIX-semantics rename keeps the held bytes, like a Unix descriptor,
    // while the name now resolves elsewhere: verification refuses.
    std::fs::rename(held.path(), f.0.join("moved")).unwrap();
    std::fs::write(f.0.join("payload"), b"replaced").unwrap();
    assert_eq!(held.verify(), Err(HostError::IdentityMismatch));
    let moved = f.1.open_file("moved").unwrap();
    std::fs::remove_file(f.0.join("moved")).unwrap();
    assert_eq!(moved.verify(), Err(HostError::NotFound));
    // A writable explicit source mutated in place changes its snapshot.
    let plain = f.0.join("plain.txt");
    std::fs::write(&plain, b"aaaa").unwrap();
    let source = HeldFile::open_explicit_source(&plain).unwrap();
    std::thread::sleep(Duration::from_millis(20));
    std::fs::write(&plain, b"bbbb").unwrap();
    assert_eq!(source.verify(), Err(HostError::Changed));
}

#[test]
fn explicit_sources_accept_spaces_and_unicode_names() {
    let f = Fixture::new();
    let directory = f.0.join("中文 目录 émoji 🚀");
    std::fs::create_dir(&directory).unwrap();
    let path = directory.join("trace file 跟踪.htrace");
    std::fs::write(&path, b"trace").unwrap();
    let source = HeldFile::open_explicit_source(&path).unwrap();
    let facts = source.facts(&budget()).unwrap();
    assert_eq!(facts.byte_count, 5);
    let staged =
        f.1.copy_snapshot(&source, "staged 文件", false, &budget())
            .unwrap();
    assert_eq!(staged.1, facts);
}

#[test]
fn component_rules_refuse_streams_devices_separators_and_trailing_dots() {
    for name in [
        "", ".", "..", "a:b", "a\\b", "a/b", "nul", "COM1.txt", "name.", "name ", "a*b", "a\u{1}",
    ] {
        assert_eq!(
            component(OsStr::new(name)),
            Err(HostError::InvalidPath),
            "{name:?}"
        );
    }
    assert!(component(OsStr::new("trace.db-journal")).is_ok());
    assert!(component(OsStr::new("session-00000000-0000-0000-0000-000000000000")).is_ok());
}

#[test]
fn promotion_never_replaces_and_failed_copy_leaves_nothing() {
    let f = Fixture::new();
    let staging = f.1.create_private_child("staging").unwrap();
    let ready = f.1.create_private_child("ready").unwrap();
    let candidate = staging
        .write_new_readonly("payload", b"new", &budget())
        .unwrap();
    let occupied = ready
        .write_new_readonly("payload", b"old", &budget())
        .unwrap();
    assert_eq!(
        staging
            .promote_noreplace(&candidate, &ready, "payload", &budget())
            .err(),
        Some(HostError::AlreadyExists)
    );
    assert_eq!(occupied.read_bounded(&budget()).unwrap(), b"old");
    candidate.verify().unwrap();
    // Cancellation before the publication critical section publishes nothing.
    let cancelled = budget();
    cancelled.cancellation.cancel();
    assert!(
        staging
            .promote_noreplace(&candidate, &ready, "fresh", &cancelled)
            .is_err()
    );
    assert!(!ready.path().join("fresh").exists());
    // An over-budget copy removes its partial output.
    let small = IoBudget {
        maximum_bytes: 2,
        ..budget()
    };
    assert_eq!(
        staging
            .copy_snapshot(&candidate, "copy", false, &small)
            .err(),
        Some(HostError::LimitExceeded)
    );
    assert!(!staging.path().join("copy").exists());
}

#[test]
fn sealed_directory_promotion_and_membership() {
    let f = Fixture::new();
    let staging = f.1.create_private_child("staging").unwrap();
    let ready = f.1.create_private_child("ready").unwrap();
    let candidate = staging.create_private_child("candidate").unwrap();
    candidate
        .write_new_readonly("metadata.json", b"{}", &budget())
        .unwrap();
    candidate
        .write_new_readonly("trace.db", b"db", &budget())
        .unwrap();
    candidate
        .require_file_membership(&["metadata.json", "trace.db"], &budget())
        .unwrap();
    let sealed = candidate.seal_readonly_directory(&budget()).unwrap();
    assert_eq!(sealed.file_count(), 2);
    let published = staging
        .promote_sealed_directory_noreplace(&sealed, &ready, "entry", &budget())
        .unwrap();
    assert_eq!(published.identity(), candidate.identity());
    assert_eq!(
        published.child_names(&budget(), 8).unwrap(),
        [OsString::from("metadata.json"), OsString::from("trace.db")]
    );
    assert!(candidate.revalidate().is_err());
}

#[test]
fn leases_exclude_across_handles_and_share_shared() {
    let f = Fixture::new();
    let locks = f.1.create_private_child(".locks").unwrap();
    let held = Lease::try_acquire(&locks, "key.lock", LeaseMode::Exclusive, true)
        .unwrap()
        .unwrap();
    assert!(
        Lease::try_acquire(&locks, "key.lock", LeaseMode::Exclusive, true)
            .unwrap()
            .is_none()
    );
    assert!(
        Lease::try_acquire(&locks, "key.lock", LeaseMode::Shared, true)
            .unwrap()
            .is_none()
    );
    drop(held);
    let first = Lease::try_acquire(&locks, "key.lock", LeaseMode::Shared, true)
        .unwrap()
        .unwrap();
    let second = Lease::try_acquire(&locks, "key.lock", LeaseMode::Shared, false)
        .unwrap()
        .unwrap();
    assert!(
        Lease::try_acquire(&locks, "key.lock", LeaseMode::Exclusive, false)
            .unwrap()
            .is_none()
    );
    drop((first, second));
    let mut upgradeable = Lease::try_acquire(&locks, "key.lock", LeaseMode::Exclusive, false)
        .unwrap()
        .unwrap();
    upgradeable.downgrade_shared().unwrap();
    assert_eq!(upgradeable.mode(), LeaseMode::Shared);
    let reader = Lease::try_acquire_existing_readonly(&locks, "key.lock", LeaseMode::Shared)
        .unwrap()
        .unwrap();
    reader.revalidate().unwrap();
    assert!(
        Lease::try_acquire_existing_readonly(&locks, "missing.lock", LeaseMode::Shared).is_err()
    );
    // Fresh ephemeral leases never admit an existing name.
    let fresh = EphemeralLease::acquire(&locks, "session.lease", &budget()).unwrap();
    assert_eq!(
        EphemeralLease::acquire(&locks, "session.lease", &budget()).err(),
        Some(HostError::AlreadyExists)
    );
    fresh.remove().unwrap();
    assert!(!locks.path().join("session.lease").exists());
}

/// Child half of the cross-process lock test: holds an exclusive lease on the
/// path in `ARKTRACE_WINDOWS_LOCK_CHILD`, signals readiness, then waits to be
/// killed. Ignored unless spawned by the parent test.
#[test]
#[ignore = "spawned by leases_exclude_another_process_and_release_on_its_death"]
fn lock_child_process() {
    let Some(path) = std::env::var_os("ARKTRACE_WINDOWS_LOCK_CHILD") else {
        return;
    };
    let locks = HeldDirectory::open_private(Path::new(&path)).unwrap();
    let _lease = Lease::try_acquire(&locks, "key.lock", LeaseMode::Exclusive, true)
        .unwrap()
        .unwrap();
    std::fs::write(Path::new(&path).join("..").join("child-ready"), b"1").unwrap();
    loop {
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn leases_exclude_another_process_and_release_on_its_death() {
    let f = Fixture::new();
    let locks = f.1.create_private_child(".locks").unwrap();
    let mut child = Command::new(std::env::current_exe().unwrap())
        .args([
            "--ignored",
            "--exact",
            "windows::tests::lock_child_process",
            "--nocapture",
        ])
        .env("ARKTRACE_WINDOWS_LOCK_CHILD", locks.path())
        .spawn()
        .unwrap();
    let ready = f.0.join("child-ready");
    let deadline = Instant::now() + Duration::from_secs(30);
    while !ready.exists() {
        assert!(Instant::now() < deadline, "child never locked");
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(
        Lease::try_acquire(&locks, "key.lock", LeaseMode::Shared, false)
            .unwrap()
            .is_none()
    );
    child.kill().unwrap();
    child.wait().unwrap();
    let lease = Lease::acquire(&locks, "key.lock", LeaseMode::Exclusive, &budget()).unwrap();
    lease.revalidate().unwrap();
}

#[test]
fn lock_byte_is_the_shared_purger_byte_and_data_stays_readable() {
    let f = Fixture::new();
    let locks = f.1.create_private_child(".locks").unwrap();
    let lease = Lease::try_acquire(&locks, "key.lock", LeaseMode::Exclusive, true)
        .unwrap()
        .unwrap();
    // An independent handle (the ArkDeck purger's probe) is refused exactly
    // that byte and nothing below it.
    let other = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(locks.path().join("key.lock"))
        .unwrap();
    assert!(!lock_byte(&other, false).unwrap());
    let mut overlapped = overlapped(LOCK_OFFSET - 1);
    // SAFETY: live handle; probing the byte just below the lease byte.
    let below = unsafe {
        LockFileEx(
            other.as_raw_handle(),
            LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY,
            0,
            1,
            0,
            &mut overlapped,
        )
    };
    assert_ne!(below, 0);
    drop(lease);
}

#[test]
fn lock_byte_matches_the_frozen_cross_product_contract() {
    let vectors: serde_json::Value = serde_json::from_str(include_str!(
        "../../../../contracts/cache-lease-vectors.json"
    ))
    .unwrap();
    let windows = &vectors["protocol"]["windows"];
    assert_eq!(windows["primitive"], "LockFileEx");
    assert_eq!(
        windows["offsetDecimal"]
            .as_str()
            .unwrap()
            .parse::<u64>()
            .unwrap(),
        LOCK_OFFSET
    );
    assert_eq!(windows["lengthBytes"], 1);
}

#[test]
fn writable_sqlite_binds_its_own_handle_and_seals() {
    let f = Fixture::new();
    let staging = f.1.create_private_child("staging").unwrap();
    let source_path = f.0.join("source.db");
    {
        let db = rusqlite::Connection::open(&source_path).unwrap();
        db.execute_batch("CREATE TABLE t(x); INSERT INTO t VALUES (1);")
            .unwrap();
    }
    let source = HeldFile::open_explicit_source(&source_path).unwrap();
    let (writable, facts) = staging
        .copy_writable_candidate(&source, "trace.db", &budget())
        .unwrap();
    assert!(facts.byte_count > 0);
    let rows: i64 = writable
        .with_sqlite_connection(&budget(), |db| {
            db.execute("INSERT INTO t VALUES (2)", [])
                .map_err(|_| HostError::InvalidEvidence)?;
            db.query_row("SELECT count(*) FROM t", [], |row| row.get(0))
                .map_err(|_| HostError::InvalidEvidence)
        })
        .unwrap();
    assert_eq!(rows, 2);
    let foreign = rusqlite::Connection::open(&source_path).unwrap();
    assert_eq!(
        writable.verify_sqlite_connection(&foreign, &budget()),
        Err(HostError::IdentityMismatch)
    );
    drop(foreign);
    let writable = Arc::into_inner(writable).unwrap();
    let sealed = writable.seal_readonly(&budget()).unwrap();
    let path = sealed.readonly_database_path().unwrap();
    let reader = rusqlite::Connection::open_with_flags(
        &path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .unwrap();
    sealed.verify_sqlite_readonly_connection(&reader).unwrap();
    let count: i64 = reader
        .query_row("SELECT count(*) FROM t", [], |row| row.get(0))
        .unwrap();
    assert_eq!(count, 2);
    let other = rusqlite::Connection::open(&source_path).unwrap();
    assert_eq!(
        sealed.verify_sqlite_readonly_connection(&other),
        Err(HostError::IdentityMismatch)
    );
}

#[test]
fn user_temporary_workspace_is_private_under_the_known_local_app_data() {
    let workspace = user_temporary_workspace("ArkTraceWindowsTest").unwrap();
    assert!(Access::of(&workspace.0.file).unwrap().owner_private());
    let expected = known_local_app_data().unwrap().join("ArkTraceWindowsTest");
    assert_eq!(workspace.path(), expected);
    let again = user_temporary_workspace("ArkTraceWindowsTest").unwrap();
    assert_eq!(again.identity(), workspace.identity());
    drop((workspace, again));
    std::fs::remove_dir(expected).unwrap();
}

#[test]
fn exchange_is_refused_and_move_never_overwrites() {
    let f = Fixture::new();
    let owner = f.1.create_private_child("owner").unwrap();
    let ready = f.1.create_private_child("ready").unwrap();
    let candidate = owner
        .write_new_readonly("payload", b"new", &budget())
        .unwrap();
    let old = ready
        .write_new_readonly("view-state.json", b"old", &budget())
        .unwrap();
    assert!(matches!(
        owner.exchange_private_document(&candidate, &old, &budget()),
        Err(HostError::SystemIo { code: 50, .. })
    ));
    assert!(
        ready
            .move_private_document(&old, &owner, "payload", &budget())
            .is_err()
    );
    owner
        .remove_owned_file("payload", candidate.snapshot().identity)
        .unwrap();
    let moved = ready
        .move_private_document(&old, &owner, "payload", &budget())
        .unwrap();
    assert_eq!(moved.read_bounded(&budget()).unwrap(), b"old");
}
