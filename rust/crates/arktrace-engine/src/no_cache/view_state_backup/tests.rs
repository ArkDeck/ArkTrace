use super::*;
use std::{
    fs,
    os::unix::fs::{DirBuilderExt, MetadataExt, symlink},
    sync::atomic::{AtomicU64, Ordering},
};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Fixture {
    path: std::path::PathBuf,
    store: ViewStateBackupStore,
}
fn io() -> IoBudget {
    IoBudget {
        maximum_bytes: BUNDLE_BYTES,
        deadline: Instant::now() + Duration::from_secs(20),
        cancellation: CancellationToken::default(),
    }
}
fn key() -> TraceCacheKey {
    TraceCacheKey::new(&"a".repeat(64), &"b".repeat(64), "fixed", "1", 1).unwrap()
}
fn document(favorites: Option<Vec<String>>) -> ViewStateDocument {
    let value = serde_json::json!({"formatVersion":1,"traceSHA256":key().trace_sha256(),
        "flags":[{"id":-7,"timestampNs":i64::MAX,"label":"保存\u{0000}🦀e\u{301}","colorIndex":i64::MIN},
        {"id":-7,"timestampNs":i64::MIN,"label":"é","colorIndex":9}],
        "marks":[{"id":2,"range":{"startNs":8,"endNs":8},"label":"instant","colorIndex":-2,"isPersistent":true},
        {"id":3,"range":{"startNs":0,"endNs":1},"label":"transient","colorIndex":0,"isPersistent":false}],
        "favoriteTrackIDs":favorites});
    let ViewStateRead::Restored(value) =
        ViewStateDocument::decode(&serde_json::to_vec(&value).unwrap(), key().trace_sha256())
    else {
        panic!("document");
    };
    value
}
impl Fixture {
    fn new() -> Self {
        let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arktrace-rollback-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        let root = HeldDirectory::open_private(&path).unwrap();
        let cache = root.create_private_child("native").unwrap();
        let backup = root.create_private_child("backup").unwrap();
        Self {
            path,
            store: ViewStateBackupStore::new(cache, backup, &io()).unwrap(),
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.path).unwrap();
    }
}

#[test]
fn format_one_backup_keeps_raw_order_duplicates_optional_favorites_and_signed_times() {
    for favorites in [
        None,
        Some(vec![]),
        Some(vec![
            "thread:7".into(),
            "thread:7".into(),
            "e\u{301}".into(),
            "é".into(),
        ]),
    ] {
        let source = document(favorites.clone());
        let expected = source.persisted();
        let (bytes, receipt) = encode(source, &key(), &io()).unwrap();
        assert_eq!(
            ViewStateDocument::decode(&bytes, key().trace_sha256()),
            ViewStateRead::Restored(expected)
        );
        assert_eq!(
            receipt.favorite_track_count,
            favorites.as_ref().map(Vec::len)
        );
        assert_eq!(receipt.flag_count, 2);
        assert_eq!(receipt.persistent_mark_count, 1);
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&bytes).unwrap()["favoriteTrackIDs"],
            serde_json::to_value(favorites).unwrap()
        );
        assert_eq!(
            receipt.document_sha256,
            format!("{:x}", Sha256::digest(&bytes))
        );
        assert_eq!(receipt.document_byte_count, bytes.len() as u64);
    }
}
#[test]
fn complete_bundle_is_immutable_idempotent_and_survives_fresh_owner() {
    let f = Fixture::new();
    let (bytes, receipt) = encode(document(Some(vec![])), &key(), &io()).unwrap();
    let report = f.store.publish(&bytes, receipt.clone(), &io()).unwrap();
    assert_eq!(report.status, Status::BackedUp);
    let path = f.store.rollback.path().join(&receipt.backup_identifier);
    let before: Vec<_> = ["receipt.json", "view-state.json"]
        .iter()
        .map(|name| {
            let p = path.join(name);
            let m = fs::metadata(&p).unwrap();
            assert_eq!(m.mode() & 0o777, 0o400);
            (
                fs::read(p).unwrap(),
                m.ino(),
                m.mtime(),
                m.mtime_nsec(),
                m.ctime(),
                m.ctime_nsec(),
            )
        })
        .collect();
    assert_eq!(fs::metadata(&path).unwrap().mode() & 0o777, 0o700);
    let fresh =
        ViewStateBackupStore::new(f.store.cache.clone(), f.store.backup.clone(), &io()).unwrap();
    assert_eq!(
        fresh
            .publish(&bytes, receipt.clone(), &io())
            .unwrap()
            .status,
        Status::AlreadyBackedUp
    );
    let after: Vec<_> = ["receipt.json", "view-state.json"]
        .iter()
        .map(|name| {
            let p = path.join(name);
            let m = fs::metadata(&p).unwrap();
            (
                fs::read(p).unwrap(),
                m.ino(),
                m.mtime(),
                m.mtime_nsec(),
                m.ctime(),
                m.ctime_nsec(),
            )
        })
        .collect();
    assert_eq!(before, after);
    assert_eq!(
        f.store.staging.child_names(&io(), 10).unwrap(),
        [std::ffi::OsString::from(".owners")]
    );
    let (changed, changed_receipt) = encode(document(None), &key(), &io()).unwrap();
    assert_ne!(receipt.backup_identifier, changed_receipt.backup_identifier);
    assert_eq!(
        fresh
            .publish(&changed, changed_receipt, &io())
            .unwrap()
            .status,
        Status::BackedUp
    );
}
#[test]
fn existing_corrupt_incomplete_extra_or_linked_destination_is_never_overwritten() {
    for variant in 0..4 {
        let f = Fixture::new();
        let (bytes, receipt) = encode(document(None), &key(), &io()).unwrap();
        let path = f.store.rollback.path().join(&receipt.backup_identifier);
        if variant == 3 {
            symlink(&f.path, &path).unwrap();
        } else {
            let d = f
                .store
                .rollback
                .create_private_child(&receipt.backup_identifier)
                .unwrap();
            d.write_new_readonly(
                "view-state.json",
                if variant == 0 { b"corrupt" } else { &bytes },
                &io(),
            )
            .unwrap();
            if variant != 1 {
                d.write_new_readonly(
                    "receipt.json",
                    &serde_json::to_vec(&receipt).unwrap(),
                    &io(),
                )
                .unwrap();
            }
            if variant == 2 {
                d.write_new_readonly("foreign", b"keep", &io()).unwrap();
            }
        }
        let before = fs::symlink_metadata(&path).unwrap();
        assert!(f.store.publish(&bytes, receipt, &io()).is_err());
        let after = fs::symlink_metadata(&path).unwrap();
        assert_eq!(
            (before.ino(), before.mode(), before.mtime(), before.ctime()),
            (after.ino(), after.mode(), after.mtime(), after.ctime())
        );
        if variant == 0 {
            assert_eq!(fs::read(path.join("view-state.json")).unwrap(), b"corrupt");
        }
        if variant == 2 {
            assert_eq!(fs::read(path.join("foreign")).unwrap(), b"keep");
        }
    }
}
#[test]
fn concurrent_identical_publications_return_one_complete_bundle() {
    let f = Fixture::new();
    let barrier = Arc::new(std::sync::Barrier::new(2));
    let threads: Vec<_> = (0..2)
        .map(|_| {
            let store = f.store.clone();
            let barrier = barrier.clone();
            std::thread::spawn(move || {
                let (bytes, receipt) = encode(document(None), &key(), &io()).unwrap();
                barrier.wait();
                store.publish(&bytes, receipt, &io()).unwrap().status
            })
        })
        .collect();
    let mut statuses: Vec<_> = threads.into_iter().map(|t| t.join().unwrap()).collect();
    statuses.sort_by_key(|status| if *status == Status::BackedUp { 0 } else { 1 });
    assert_eq!(statuses, [Status::BackedUp, Status::AlreadyBackedUp]);
    assert_eq!(
        f.store.staging.child_names(&io(), 10).unwrap(),
        [std::ffi::OsString::from(".owners")]
    );
}
#[test]
fn cancelled_expired_and_replaced_roots_do_not_create_backups() {
    let f = Fixture::new();
    let (bytes, receipt) = encode(document(None), &key(), &io()).unwrap();
    let cancelled = io();
    cancelled.cancellation.cancel();
    assert_eq!(
        f.store.publish(&bytes, receipt.clone(), &cancelled),
        Err(HostError::Cancelled)
    );
    assert_eq!(
        encode(document(None), &key(), &cancelled),
        Err(HostError::Cancelled)
    );
    let expired = IoBudget {
        deadline: Instant::now(),
        ..io()
    };
    assert_eq!(
        f.store.publish(&bytes, receipt.clone(), &expired),
        Err(HostError::DeadlineExceeded)
    );
    assert_eq!(
        f.store.rollback.child_names(&io(), 10).unwrap(),
        [std::ffi::OsString::from(".staging")]
    );
    fs::rename(f.store.backup.path(), f.path.join("moved")).unwrap();
    fs::DirBuilder::new()
        .mode(0o700)
        .create(f.path.join("backup"))
        .unwrap();
    assert!(f.store.publish(&bytes, receipt, &io()).is_err());
    assert_eq!(fs::read_dir(f.path.join("backup")).unwrap().count(), 0);
}
#[test]
fn escaping_expansion_and_invalid_documents_fail_before_publication() {
    let f = Fixture::new();
    let mut d = document(None);
    d.flags[0].label = "\0".repeat(4096);
    d.flags = vec![d.flags[0].clone(); 200];
    assert_eq!(encode(d, &key(), &io()), Err(HostError::LimitExceeded));
    let mut d = document(None);
    d.trace_sha256 = "f".repeat(64);
    assert_eq!(encode(d, &key(), &io()), Err(HostError::InvalidEvidence));
    assert_eq!(
        f.store.rollback.child_names(&io(), 10).unwrap(),
        [std::ffi::OsString::from(".staging")]
    );
}
