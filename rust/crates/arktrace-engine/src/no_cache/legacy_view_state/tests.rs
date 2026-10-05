use super::*;
use crate::MAXIMUM_VIEW_STATE_BYTES;
use std::{
    fs,
    os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt, symlink},
    path::PathBuf,
};

struct Fixture {
    path: PathBuf,
    legacy: HeldDirectory,
    cache: HeldDirectory,
    backup: HeldDirectory,
    migration: LegacyViewStateMigration,
    metadata: CacheMetadata,
    directory: HeldDirectory,
    locks: HeldDirectory,
    lease: Lease,
    sidecars: SidecarStore,
}
fn io() -> IoBudget {
    IoBudget {
        maximum_bytes: MAXIMUM_LEGACY_BACKUP_FILE_BYTES,
        deadline: Instant::now() + Duration::from_secs(30),
        cancellation: CancellationToken::default(),
    }
}
fn metadata() -> CacheMetadata {
    CacheMetadata::decode(include_bytes!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../contracts/ready-metadata.json"
    )))
    .unwrap()
}
fn bytes(metadata: &CacheMetadata, label: &str) -> Vec<u8> {
    serde_json::to_vec(&serde_json::json!({"formatVersion":1,"traceSHA256":metadata.trace_sha256,
        "flags":[{"id":1,"timestampNs":i64::MAX,"label":label,"colorIndex":i64::MIN}],
        "marks":[{"id":2,"range":{"startNs":8,"endNs":8},"label":"instant","colorIndex":2,"isPersistent":true},
        {"id":3,"range":{"startNs":0,"endNs":1},"label":"transient","colorIndex":0,"isPersistent":false}],
        "favoriteTrackIDs":["thread:7","thread:7","unknown 🦀"]})).unwrap()
}
fn changed_parser(mut value: CacheMetadata) -> CacheMetadata {
    value.parser.binary_sha256 = "f".repeat(64);
    value.cache_key = TraceCacheKey::new(
        &value.trace_sha256,
        &value.parser.binary_sha256,
        &value.parser.upstream_revision,
        &value.schema_adapter_version,
        i64::from(value.index_schema_version),
    )
    .unwrap();
    value
}
// Only atime is excluded: a read can update filesystem access time. All names,
// bytes, modes, identities, sizes, mtime and ctime must stay unchanged.
fn legacy_facts(root: &PathBuf) -> Vec<(PathBuf, Vec<u8>, Vec<i128>)> {
    fn visit(path: &PathBuf, output: &mut Vec<(PathBuf, Vec<u8>, Vec<i128>)>) {
        let metadata = fs::symlink_metadata(path).unwrap();
        let content = if metadata.is_file() {
            fs::read(path).unwrap()
        } else {
            vec![]
        };
        output.push((
            path.clone(),
            content,
            vec![
                metadata.dev() as i128,
                metadata.ino() as i128,
                metadata.len() as i128,
                metadata.mode() as i128,
                metadata.nlink() as i128,
                metadata.mtime() as i128,
                metadata.mtime_nsec() as i128,
                metadata.ctime() as i128,
                metadata.ctime_nsec() as i128,
            ],
        ));
        if metadata.is_dir() {
            let mut children: Vec<_> = fs::read_dir(path)
                .unwrap()
                .map(|v| v.unwrap().path())
                .collect();
            children.sort();
            for child in children {
                visit(&child, output);
            }
        }
    }
    let mut output = vec![];
    visit(root, &mut output);
    output
}
impl Fixture {
    fn new() -> Self {
        let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arktrace-legacy-state-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        let root = HeldDirectory::open_private(&path).unwrap();
        let legacy = root.create_private_child("legacy").unwrap();
        legacy.create_private_child(".locks").unwrap();
        legacy.create_private_child(".leases").unwrap();
        let cache = root.create_private_child("native").unwrap();
        let backup = root.create_private_child("migration-backup").unwrap();
        let migration =
            LegacyViewStateMigration::new(legacy.clone(), cache.clone(), backup.clone(), &io())
                .unwrap();
        let metadata = metadata();
        let directory = cache
            .create_private_child(&metadata.trace_sha256)
            .unwrap()
            .create_private_child(metadata.cache_key.parser_key())
            .unwrap();
        let locks = cache.create_private_child(".locks").unwrap();
        let leases = cache.create_private_child(".leases").unwrap();
        let lease = Lease::acquire(
            &leases,
            &format!("{}.lease", metadata.cache_key.entry_identifier()),
            LeaseMode::Shared,
            &io(),
        )
        .unwrap();
        let sidecars = SidecarStore::open(&cache, MAXIMUM_VIEW_STATE_BYTES as u64, &io()).unwrap();
        Self {
            path,
            legacy,
            cache,
            backup,
            migration,
            metadata,
            directory,
            locks,
            lease,
            sidecars,
        }
    }
    fn old(&self, metadata: &CacheMetadata, bytes: &[u8]) -> HeldDirectory {
        let directory = self
            .legacy
            .ensure_private_child(&metadata.trace_sha256)
            .unwrap()
            .create_private_child(metadata.cache_key.parser_key())
            .unwrap();
        directory
            .write_new_readonly("metadata.json", &metadata.encode().unwrap(), &io())
            .unwrap();
        let budget = IoBudget {
            maximum_bytes: bytes.len() as u64,
            ..io()
        };
        directory
            .write_new_readonly("view-state.json", bytes, &budget)
            .unwrap();
        for (parent, suffix) in [(".locks", "lock"), (".leases", "lease")] {
            self.legacy
                .open_private_child(parent)
                .unwrap()
                .write_new_readonly(
                    &format!("{}.{suffix}", metadata.cache_key.entry_identifier()),
                    b"",
                    &io(),
                )
                .unwrap();
        }
        directory
    }
    fn run(&self, selected: Option<&str>) -> Result<Report, HostError> {
        self.migration.apply(
            Destination {
                directory: &self.directory,
                locks: &self.locks,
                lease: &self.lease,
                sidecars: &self.sidecars,
                target: &self.metadata,
            },
            selected,
            &io(),
        )
    }
    fn read(&self) -> ViewStateRead {
        super::super::view_state::read_directory(
            &self.directory,
            &self.metadata.trace_sha256,
            &io(),
        )
        .unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.path).unwrap();
    }
}

#[test]
fn import_keeps_old_bytes_is_idempotent_and_does_not_resurrect_cleared_state() {
    let f = Fixture::new();
    let raw = bytes(&f.metadata, "保存\0🦀e\u{301}");
    f.old(&f.metadata, &raw);
    let before = legacy_facts(&f.legacy.path().to_path_buf());
    let report = f.run(None).unwrap();
    assert_eq!(report.status, Status::Imported);
    assert_eq!(report.sources.len(), 1);
    assert!(report.sources[0].backed_up);
    assert!(report.unmatched_favorite_track_ids.is_empty());
    let ViewStateRead::Restored(document) = f.read() else {
        panic!("not restored")
    };
    assert_eq!(document.flags[0].timestamp_ns, i64::MAX);
    assert_eq!(document.flags[0].color_index, i64::MIN);
    assert_eq!(document.flags[0].label, "保存\0🦀e\u{301}");
    assert_eq!(document.marks.len(), 1);
    assert!(document.marks[0].range.is_instant());
    assert_eq!(
        document.favorite_track_ids.unwrap(),
        ["thread:7", "thread:7", "unknown 🦀"]
    );
    assert_eq!(f.run(None).unwrap().status, Status::AlreadyCompleted);
    let saved = f.directory.open_file("view-state.json").unwrap();
    f.directory
        .remove_owned_file("view-state.json", saved.snapshot().identity)
        .unwrap();
    assert_eq!(f.run(None).unwrap().status, Status::AlreadyCompleted);
    assert_eq!(f.read(), ViewStateRead::Missing);
    assert_eq!(legacy_facts(&f.legacy.path().to_path_buf()), before);
    assert_eq!(
        f.migration
            .objects
            .open_file(&format!("{}.bytes", model::digest(&raw)))
            .unwrap()
            .read_bounded(&io())
            .unwrap(),
        raw
    );
}
#[test]
fn conflict_archives_all_candidates_and_explicit_selection_keeps_foreign_favorites_unmatched() {
    let f = Fixture::new();
    f.old(&f.metadata, &bytes(&f.metadata, "first"));
    let old = changed_parser(f.metadata.clone());
    let raw = bytes(&old, "second");
    f.old(&old, &raw);
    let before = legacy_facts(&f.legacy.path().to_path_buf());
    let report = f.run(None).unwrap();
    assert_eq!(report.status, Status::Conflict);
    assert_eq!(report.sources.len(), 2);
    assert!(report.sources.iter().all(|v| v.backed_up));
    assert_eq!(f.read(), ViewStateRead::Missing);
    assert_eq!(
        f.run(Some(&"0".repeat(64))).unwrap().status,
        Status::InvalidSelection
    );
    let selected = report
        .sources
        .iter()
        .find(|v| v.parser_key == old.cache_key.parser_key())
        .unwrap()
        .snapshot_identifier
        .as_deref();
    let report = f.run(selected).unwrap();
    assert_eq!(report.status, Status::Imported);
    assert_eq!(
        report.unmatched_favorite_track_ids,
        ["thread:7", "thread:7", "unknown 🦀"]
    );
    let ViewStateRead::Restored(document) = f.read() else {
        panic!("not restored")
    };
    assert_eq!(document.flags[0].label, "second");
    assert_eq!(document.favorite_track_ids, None);
    assert_eq!(
        f.run(None).unwrap().unmatched_favorite_track_ids,
        report.unmatched_favorite_track_ids
    );
    assert_eq!(legacy_facts(&f.legacy.path().to_path_buf()), before);
}
#[test]
fn future_corrupt_duplicate_keys_and_oversized_sidecars_remain_raw_backups() {
    for raw in [
        b"{".to_vec(),
        b"{\"formatVersion\":999}".to_vec(),
        b"{\"formatVersion\":1,\"formatVersion\":1}".to_vec(),
        vec![b' '; MAXIMUM_VIEW_STATE_BYTES + 1],
    ] {
        let f = Fixture::new();
        f.old(&f.metadata, &raw);
        let before = legacy_facts(&f.legacy.path().to_path_buf());
        let report = f.run(None).unwrap();
        assert_eq!(report.status, Status::PreservedSource);
        assert_eq!(report.sources[0].issue, Some(Issue::SidecarPreserved));
        assert!(report.sources[0].backed_up);
        assert_eq!(f.read(), ViewStateRead::Missing);
        assert_eq!(
            f.migration
                .objects
                .open_file(&format!("{}.bytes", model::digest(&raw)))
                .unwrap()
                .read_bounded(&io())
                .unwrap(),
            raw
        );
        assert_eq!(legacy_facts(&f.legacy.path().to_path_buf()), before);
    }
}
#[test]
fn oversized_raw_backup_is_reported_without_loading_or_modifying_the_original() {
    let f = Fixture::new();
    let raw = vec![42; MAXIMUM_LEGACY_BACKUP_FILE_BYTES as usize + 1];
    f.old(&f.metadata, &raw);
    let before = legacy_facts(&f.legacy.path().to_path_buf());
    let report = f.run(None).unwrap();
    assert_eq!(report.status, Status::PreservedSource);
    assert_eq!(report.sources[0].issue, Some(Issue::BackupTooLarge));
    assert!(!report.sources[0].backed_up);
    assert_eq!(f.migration.objects.child_names(&io(), 8).unwrap().len(), 0);
    assert_eq!(legacy_facts(&f.legacy.path().to_path_buf()), before);
}
#[test]
fn unknown_metadata_and_wrong_entry_identity_are_backed_up_without_import() {
    for wrong_identity in [false, true] {
        let f = Fixture::new();
        let directory = f.old(&f.metadata, &bytes(&f.metadata, "kept"));
        let path = directory.path().join("metadata.json");
        let mut value: serde_json::Value =
            serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        if wrong_identity {
            value["sourceByteCount"] = (f.metadata.source_byte_count + 1).into();
        } else {
            value["future"] = true.into();
        }
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o400)).unwrap();
        let before = legacy_facts(&f.legacy.path().to_path_buf());
        let report = f.run(None).unwrap();
        assert_eq!(report.status, Status::PreservedSource);
        assert!(report.sources[0].backed_up);
        assert_eq!(
            report.sources[0].issue,
            Some(if wrong_identity {
                Issue::IdentityMismatch
            } else {
                Issue::MetadataPreserved
            })
        );
        assert_eq!(legacy_facts(&f.legacy.path().to_path_buf()), before);
    }
}
#[test]
fn missing_locks_and_linked_sources_do_not_create_legacy_members() {
    for linked in [false, true] {
        let f = Fixture::new();
        let directory = f.old(&f.metadata, &bytes(&f.metadata, "kept"));
        if linked {
            fs::rename(
                directory.path().join("view-state.json"),
                directory.path().join("other"),
            )
            .unwrap();
            symlink("other", directory.path().join("view-state.json")).unwrap();
        } else {
            fs::remove_file(
                f.legacy
                    .path()
                    .join(".locks")
                    .join(format!("{}.lock", f.metadata.cache_key.entry_identifier())),
            )
            .unwrap();
        }
        let before = legacy_facts(&f.legacy.path().to_path_buf());
        let report = f.run(None).unwrap();
        assert_eq!(report.status, Status::PreservedSource);
        assert_eq!(report.sources[0].issue, Some(Issue::SourceUnavailable));
        assert_eq!(legacy_facts(&f.legacy.path().to_path_buf()), before);
        assert_eq!(f.read(), ViewStateRead::Missing);
    }
}
#[test]
fn existing_destination_is_kept_and_future_destination_is_not_completed() {
    for future in [false, true] {
        let f = Fixture::new();
        f.old(&f.metadata, &bytes(&f.metadata, "old"));
        let raw = if future {
            b"{\"formatVersion\":999}".to_vec()
        } else {
            bytes(&f.metadata, "new")
        };
        let before = f
            .directory
            .write_new_readonly("view-state.json", &raw, &io())
            .unwrap()
            .snapshot();
        let report = f.run(None).unwrap();
        assert_eq!(
            report.status,
            if future {
                Status::PreservedDestination
            } else {
                Status::DestinationKept
            }
        );
        assert_eq!(
            f.directory.open_file("view-state.json").unwrap().snapshot(),
            before
        );
        assert_eq!(
            f.directory
                .open_file("view-state.json")
                .unwrap()
                .read_bounded(&io())
                .unwrap(),
            raw
        );
        assert_eq!(
            f.run(None).unwrap().status,
            if future {
                Status::PreservedDestination
            } else {
                Status::AlreadyCompleted
            }
        );
    }
}
#[test]
fn interrupted_intent_or_commit_resumes_from_backup_after_the_legacy_entry_is_removed() {
    for point in [1, 2] {
        let f = Fixture::new();
        f.old(&f.metadata, &bytes(&f.metadata, "原件 🦀"));
        TEST_INTERRUPT.set(Some(point));
        assert_eq!(f.run(None).unwrap_err(), HostError::DeadlineExceeded);
        let before = if point == 2 {
            Some(f.directory.open_file("view-state.json").unwrap().snapshot())
        } else {
            None
        };
        fs::remove_dir_all(f.legacy.path().join(&f.metadata.trace_sha256)).unwrap();
        let report = f.run(None).unwrap();
        assert_eq!(report.status, Status::Imported);
        if let Some(before) = before {
            assert_eq!(
                f.directory.open_file("view-state.json").unwrap().snapshot(),
                before
            );
        }
        let ViewStateRead::Restored(document) = f.read() else {
            panic!("not restored")
        };
        assert_eq!(document.flags.len(), 1);
        assert_eq!(document.flags[0].label, "原件 🦀");
        assert_eq!(f.run(None).unwrap().status, Status::AlreadyCompleted);
    }
}
#[test]
fn a_user_edit_after_an_interrupted_commit_is_never_overwritten() {
    let f = Fixture::new();
    f.old(&f.metadata, &bytes(&f.metadata, "old"));
    TEST_INTERRUPT.set(Some(2));
    assert_eq!(f.run(None).unwrap_err(), HostError::DeadlineExceeded);
    let key = Lease::acquire(
        &f.locks,
        &format!("{}.lock", f.metadata.cache_key.entry_identifier()),
        LeaseMode::Exclusive,
        &io(),
    )
    .unwrap();
    let new = bytes(&f.metadata, "edited");
    f.sidecars
        .write(&f.directory, &key, &f.lease, Some(&new), &io())
        .unwrap();
    drop(key);
    assert_eq!(f.run(None).unwrap().status, Status::DestinationKept);
    assert_eq!(
        f.directory
            .open_file("view-state.json")
            .unwrap()
            .read_bounded(&io())
            .unwrap(),
        new
    );
}
#[test]
fn tampered_backup_is_preserved_and_cannot_complete_or_reimport() {
    let f = Fixture::new();
    let raw = bytes(&f.metadata, "old");
    f.old(&f.metadata, &raw);
    TEST_INTERRUPT.set(Some(1));
    assert_eq!(f.run(None).unwrap_err(), HostError::DeadlineExceeded);
    let path = f
        .migration
        .objects
        .path()
        .join(format!("{}.bytes", model::digest(&raw)));
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    fs::write(&path, b"foreign").unwrap();
    assert_eq!(f.run(None).unwrap_err(), HostError::InvalidEvidence);
    assert_eq!(fs::read(path).unwrap(), b"foreign");
    assert_eq!(f.read(), ViewStateRead::Missing);
}
#[test]
fn cancelled_expired_contended_or_unqualified_roots_do_not_publish_state() {
    let f = Fixture::new();
    f.old(&f.metadata, &bytes(&f.metadata, "old"));
    let before = legacy_facts(&f.legacy.path().to_path_buf());
    let cancelled = io();
    cancelled.cancellation.cancel();
    assert_eq!(
        f.migration.scan(&f.metadata, &cancelled).err(),
        Some(HostError::Cancelled)
    );
    let expired = IoBudget {
        deadline: Instant::now(),
        ..io()
    };
    assert_eq!(
        f.migration.scan(&f.metadata, &expired).err(),
        Some(HostError::DeadlineExceeded)
    );
    let old_locks = f.legacy.open_private_child(".locks").unwrap();
    let name = format!("{}.lock", f.metadata.cache_key.entry_identifier());
    let _contended =
        Lease::acquire_existing_readonly(&old_locks, &name, LeaseMode::Exclusive, &io()).unwrap();
    let short = IoBudget {
        deadline: Instant::now() + Duration::from_millis(30),
        ..io()
    };
    assert_eq!(
        f.migration.scan(&f.metadata, &short).err(),
        Some(HostError::DeadlineExceeded)
    );
    assert!(
        LegacyViewStateMigration::new(f.legacy.clone(), f.legacy.clone(), f.backup.clone(), &io())
            .is_err()
    );
    let nested = f.cache.create_private_child("nested-backup").unwrap();
    assert!(
        LegacyViewStateMigration::new(f.legacy.clone(), f.cache.clone(), nested.clone(), &io())
            .is_err()
    );
    assert_eq!(nested.child_names(&io(), 8).unwrap().len(), 0);
    assert_eq!(legacy_facts(&f.legacy.path().to_path_buf()), before);
    assert_eq!(f.read(), ViewStateRead::Missing);
}
#[test]
fn source_entry_limit_counts_ignored_names_before_any_backup() {
    let f = Fixture::new();
    let trace = f
        .legacy
        .create_private_child(&f.metadata.trace_sha256)
        .unwrap();
    for index in 0..=MAXIMUM_LEGACY_VIEW_STATE_ENTRIES {
        trace
            .create_private_child(&format!("ignored-{index}"))
            .unwrap();
    }
    assert_eq!(
        f.migration.scan(&f.metadata, &io()).err(),
        Some(HostError::LimitExceeded)
    );
    assert_eq!(f.migration.objects.child_names(&io(), 8).unwrap().len(), 0);
}
#[test]
fn pending_files_without_ownership_proof_are_not_cleaned_up_by_import() {
    let f = Fixture::new();
    f.old(&f.metadata, &bytes(&f.metadata, "kept"));
    let old = f
        .migration
        .pending
        .write_new_readonly("previous-owner", b"kept", &io())
        .unwrap()
        .snapshot();
    assert_eq!(f.run(None).unwrap().status, Status::Imported);
    assert_eq!(
        f.migration
            .pending
            .open_file("previous-owner")
            .unwrap()
            .snapshot(),
        old
    );
}

#[test]
fn aggregate_raw_backup_budget_stops_before_the_next_entry_is_loaded() {
    let f = Fixture::new();
    let raw = vec![b' '; 13 * 1024 * 1024];
    for index in 1..=5 {
        let mut old = f.metadata.clone();
        old.parser.binary_sha256 = format!("{index:064x}");
        old.cache_key = TraceCacheKey::new(
            &old.trace_sha256,
            &old.parser.binary_sha256,
            &old.parser.upstream_revision,
            &old.schema_adapter_version,
            i64::from(old.index_schema_version),
        )
        .unwrap();
        f.old(&old, &raw);
    }
    let report = f.run(None).unwrap();
    assert_eq!(report.status, Status::PreservedSource);
    assert_eq!(report.sources.iter().filter(|v| v.backed_up).count(), 4);
    assert_eq!(
        report
            .sources
            .iter()
            .filter(|v| v.issue == Some(Issue::BackupTooLarge))
            .count(),
        1
    );
    assert_eq!(f.read(), ViewStateRead::Missing);
}

#[test]
fn an_interrupted_intent_cannot_silently_choose_another_source() {
    let f = Fixture::new();
    f.old(&f.metadata, &bytes(&f.metadata, "first"));
    let other = changed_parser(f.metadata.clone());
    f.old(&other, &bytes(&other, "second"));
    let conflict = f.run(None).unwrap();
    let selected = conflict
        .sources
        .iter()
        .find(|v| v.parser_key == f.metadata.cache_key.parser_key())
        .unwrap()
        .snapshot_identifier
        .as_deref();
    let alternate = conflict
        .sources
        .iter()
        .find(|v| v.parser_key == other.cache_key.parser_key())
        .unwrap()
        .snapshot_identifier
        .as_deref();
    TEST_INTERRUPT.set(Some(1));
    assert_eq!(f.run(selected).unwrap_err(), HostError::DeadlineExceeded);
    assert_eq!(f.run(alternate).unwrap().status, Status::InvalidSelection);
    assert_eq!(f.read(), ViewStateRead::Missing);
    assert_eq!(f.run(selected).unwrap().status, Status::Imported);
}
