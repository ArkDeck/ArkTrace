#![cfg(target_os = "macos")]
use arktrace_contract::TraceCacheKey;
use arktrace_engine::{CacheMaintenance, CacheMetadata, CacheWatermarks, EngineFailure};
use arktrace_platform::{
    CancellationToken, HeldDirectory, HostError, IoBudget, Lease, LeaseMode, OwnerKind, OwnerStore,
};
use std::{
    fs,
    os::unix::fs::DirBuilderExt,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
    time::{Duration, Instant},
};
static NEXT: AtomicU64 = AtomicU64::new(0);
fn budget() -> IoBudget {
    IoBudget {
        maximum_bytes: 16_384,
        deadline: Instant::now() + Duration::from_secs(10),
        cancellation: CancellationToken::default(),
    }
}
struct Fixture {
    path: PathBuf,
    cache: HeldDirectory,
    owners: OwnerStore,
    original: Vec<u8>,
}
impl Fixture {
    fn new() -> Self {
        let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arktrace-cache-maintenance-{}-{}-空 格",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        let root = HeldDirectory::open_private(&path).unwrap();
        let cache = root.create_private_child("cache").unwrap();
        let stage = cache.create_private_child(".staging").unwrap();
        let owners = OwnerStore::open(&stage, &cache).unwrap();
        cache.create_private_child(".locks").unwrap();
        cache.create_private_child(".leases").unwrap();
        let original = b"original trace must never be selected".to_vec();
        root.write_new_readonly("original.htrace", &original, &budget())
            .unwrap();
        Self {
            path,
            cache,
            owners,
            original,
        }
    }
    fn service(&self) -> CacheMaintenance {
        CacheMaintenance::new(self.cache.clone(), 4096).unwrap()
    }
    fn add(&self, digit: char, accessed: &str) -> (CacheMetadata, String, HeldDirectory) {
        self.add_with_parser(digit, accessed, 'b')
    }
    fn add_with_parser(
        &self,
        digit: char,
        accessed: &str,
        parser_digit: char,
    ) -> (CacheMetadata, String, HeldDirectory) {
        let mut m = CacheMetadata::decode(include_bytes!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../contracts/ready-metadata.json"
        )))
        .unwrap();
        m.source_sha256 = digit.to_string().repeat(64);
        m.trace_sha256 = m.source_sha256.clone();
        m.parser.binary_sha256 = parser_digit.to_string().repeat(64);
        m.cache_key = TraceCacheKey::new(
            &m.source_sha256,
            &m.parser.binary_sha256,
            &m.parser.upstream_revision,
            &m.schema_adapter_version,
            i64::from(m.index_schema_version),
        )
        .unwrap();
        m.created_at = "2026-10-01T00:00:00Z".into();
        m.last_accessed_at = accessed.into();
        let bytes = b"derived database";
        m.database_byte_count = bytes.len() as i64;
        let locks = self.cache.open_private_child(".locks").unwrap();
        let leases = self.cache.open_private_child(".leases").unwrap();
        let key = Lease::acquire(
            &locks,
            &format!("{}.lock", m.cache_key.entry_identifier()),
            LeaseMode::Exclusive,
            &budget(),
        )
        .unwrap();
        let entry = Lease::acquire(
            &leases,
            &format!("{}.lease", m.cache_key.entry_identifier()),
            LeaseMode::Exclusive,
            &budget(),
        )
        .unwrap();
        let mut owned = self.owners.create(OwnerKind::Building, &budget()).unwrap();
        let id = owned.identifier().to_owned();
        owned
            .bind_cached(
                &key,
                &entry,
                &format!(
                    "{}/{}",
                    m.cache_key.trace_sha256(),
                    m.cache_key.parser_key()
                ),
                &budget(),
            )
            .unwrap();
        let candidate = owned.directory().clone();
        candidate
            .write_new_readonly("trace.sqlite", bytes, &budget())
            .unwrap();
        candidate
            .write_new_readonly("metadata.json", &m.encode().unwrap(), &budget())
            .unwrap();
        candidate
            .write_new_readonly("view-state.json", b"private user state", &budget())
            .unwrap();
        let trace = self
            .cache
            .ensure_private_child(m.cache_key.trace_sha256())
            .unwrap();
        owned
            .prepare_cached_publication(&trace, m.cache_key.parser_key(), &key, &entry, &budget())
            .unwrap();
        let sealed = candidate.seal_readonly_directory(&budget()).unwrap();
        let ready = self
            .cache
            .open_private_child(".staging")
            .unwrap()
            .promote_sealed_directory_noreplace(
                &sealed,
                &trace,
                m.cache_key.parser_key(),
                &budget(),
            )
            .unwrap();
        owned.record_published_location(&ready, &budget()).unwrap();
        drop(owned);
        (m, id, ready)
    }
    fn shared(&self, m: &CacheMetadata) -> Lease {
        Lease::acquire(
            &self.cache.open_private_child(".leases").unwrap(),
            &format!("{}.lease", m.cache_key.entry_identifier()),
            LeaseMode::Shared,
            &budget(),
        )
        .unwrap()
    }
    fn assert_original(&self) {
        assert_eq!(
            fs::read(self.path.join("original.htrace")).unwrap(),
            self.original
        );
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.assert_original();
        fs::remove_dir_all(&self.path).unwrap();
    }
}

#[test]
fn purge_removes_only_exact_inactive_ready_and_preserves_stable_leases() {
    let f = Fixture::new();
    let (m, id, ready) = f.add('a', "2026-10-02T00:00:00Z");
    let service = f.service();
    let before = service.inventory(&budget()).unwrap();
    assert_eq!(before.entry_count, 1);
    assert_eq!(before.active_entry_count, 0);
    let report = service.purge_unused(&budget()).unwrap();
    assert_eq!(report.before, before);
    assert_eq!(report.removed_entry_count, 1);
    assert_eq!(report.skipped_active_entry_count, 0);
    assert_eq!(report.after.total_byte_count, 0);
    assert_eq!(report.after.entry_count, 0);
    assert!(!ready.path().exists());
    assert!(
        f.owners
            .published_evidence(&id, &budget())
            .unwrap()
            .is_none()
    );
    for (directory, suffix) in [(".locks", "lock"), (".leases", "lease")] {
        assert!(
            f.cache
                .path()
                .join(directory)
                .join(format!("{}.{suffix}", m.cache_key.entry_identifier()))
                .exists()
        );
    }
    assert_eq!(
        service.purge_unused(&budget()).unwrap().removed_entry_count,
        0
    );
}

#[test]
fn shared_reader_blocks_purge_without_delay_and_another_entry_is_removed() {
    let f = Fixture::new();
    let (m, _, active) = f.add('a', "2026-10-02T00:00:00Z");
    let (_, _, inactive) = f.add('b', "2026-10-03T00:00:00Z");
    let reader = f.shared(&m);
    let service = f.service();
    assert_eq!(service.inventory(&budget()).unwrap().active_entry_count, 1);
    let started = Instant::now();
    let report = service.purge_unused(&budget()).unwrap();
    assert!(started.elapsed() < Duration::from_secs(2));
    assert_eq!(report.removed_entry_count, 1);
    assert_eq!(report.skipped_active_entry_count, 1);
    assert!(active.path().exists());
    assert!(!inactive.path().exists());
    drop(reader);
    assert_eq!(
        service.purge_unused(&budget()).unwrap().removed_entry_count,
        1
    );
}

#[test]
fn lru_threshold_is_strict_and_ties_use_trace_then_parser_names() {
    let f = Fixture::new();
    let (_, _, a) = f.add('a', "2026-10-02T00:00:00Z");
    let (_, _, b) = f.add('b', "2026-10-02T00:00:00Z");
    let (_, _, c) = f.add('c', "2026-10-03T00:00:00Z");
    let service = f.service();
    let before = service.inventory(&budget()).unwrap();
    let no_op = service
        .maintain(
            CacheWatermarks::new(before.total_byte_count, 0).unwrap(),
            &budget(),
        )
        .unwrap();
    assert_eq!(no_op.before, no_op.after);
    assert_eq!(no_op.removed_entry_count, 0);
    let low = before.total_byte_count - 1;
    let report = service
        .maintain(
            CacheWatermarks::new(before.total_byte_count - 1, low - 1).unwrap(),
            &budget(),
        )
        .unwrap();
    assert_eq!(report.removed_entry_count, 1);
    assert!(!a.path().exists());
    assert!(b.path().exists() && c.path().exists());
    assert_eq!(
        CacheWatermarks::STANDARD.high_bytes,
        20 * 1024 * 1024 * 1024
    );
    assert_eq!(CacheWatermarks::STANDARD.low_bytes, 16 * 1024 * 1024 * 1024);
}

#[test]
fn wrong_owner_inode_is_skipped_but_inventory_does_not_call_it_active() {
    let f = Fixture::new();
    let (_, id, ready) = f.add('a', "2026-10-02T00:00:00Z");
    let owners = f
        .cache
        .open_private_child(".staging")
        .unwrap()
        .open_private_child(".owners")
        .unwrap();
    let record = owners.open_file(&format!("{id}.json")).unwrap();
    let mut value: serde_json::Value =
        serde_json::from_slice(&record.read_bounded(&budget()).unwrap()).unwrap();
    value["inode"] = serde_json::json!(f.cache.identity().inode);
    owners
        .replace_readonly(&record, &serde_json::to_vec(&value).unwrap(), &budget())
        .unwrap();
    let service = f.service();
    assert_eq!(service.inventory(&budget()).unwrap().active_entry_count, 0);
    let report = service.purge_unused(&budget()).unwrap();
    assert_eq!(report.removed_entry_count, 0);
    assert_eq!(report.skipped_active_entry_count, 1);
    assert!(ready.path().exists());
}

#[test]
fn unknown_metadata_is_counted_and_preserved_with_all_payload_bytes() {
    let f = Fixture::new();
    let (_, _, ready) = f.add('a', "2026-10-02T00:00:00Z");
    let current = ready.open_file("metadata.json").unwrap();
    let mut v: serde_json::Value =
        serde_json::from_slice(&current.read_bounded(&budget()).unwrap()).unwrap();
    v["formatVersion"] = 999.into();
    let future = serde_json::to_vec(&v).unwrap();
    ready
        .replace_readonly(&current, &future, &budget())
        .unwrap();
    let report = f.service().purge_unused(&budget()).unwrap();
    assert_eq!(report.before.active_entry_count, 1);
    assert_eq!(report.removed_entry_count, 0);
    assert_eq!(report.skipped_active_entry_count, 1);
    assert_eq!(report.before, report.after);
    assert_eq!(
        ready
            .open_file("metadata.json")
            .unwrap()
            .read_bounded(&budget())
            .unwrap(),
        future
    );
    assert!(ready.path().join("view-state.json").exists());
}

#[test]
fn missing_key_or_entry_lease_grants_no_authority_and_is_not_created() {
    let f = Fixture::new();
    let (m, _, ready) = f.add('a', "2026-10-02T00:00:00Z");
    let path = f
        .cache
        .path()
        .join(".leases")
        .join(format!("{}.lease", m.cache_key.entry_identifier()));
    fs::remove_file(&path).unwrap();
    let report = f.service().purge_unused(&budget()).unwrap();
    assert_eq!(report.before.active_entry_count, 1);
    assert_eq!(report.skipped_active_entry_count, 1);
    assert_eq!(report.removed_entry_count, 0);
    assert!(!path.exists());
    assert!(ready.path().exists());
}

#[test]
fn recovery_reclaims_generic_residual_and_only_unlocked_orphan_marker() {
    let f = Fixture::new();
    let owned = f.owners.create(OwnerKind::Building, &budget()).unwrap();
    let residual = owned.directory().path().to_path_buf();
    owned
        .directory()
        .write_new_readonly("data", b"residual", &budget())
        .unwrap();
    drop(owned);
    let owner_dir = f
        .cache
        .open_private_child(".staging")
        .unwrap()
        .open_private_child(".owners")
        .unwrap();
    let name = "entry-00000000-0000-4000-8000-000000000001.lock";
    let marker = Lease::acquire(&owner_dir, name, LeaseMode::Exclusive, &budget()).unwrap();
    let first = f.service().purge_unused(&budget()).unwrap();
    assert_eq!(first.recovered_private_directory_count, 1);
    assert_eq!(first.removed_orphan_owner_marker_count, 0);
    assert!(!residual.exists());
    assert!(owner_dir.path().join(name).exists());
    drop(marker);
    let second = f.service().purge_unused(&budget()).unwrap();
    assert_eq!(second.removed_orphan_owner_marker_count, 1);
    assert!(!owner_dir.path().join(name).exists());
}

#[test]
fn cancelled_and_invalid_maintenance_do_not_remove_ready() {
    let f = Fixture::new();
    let (_, _, ready) = f.add('a', "2026-10-02T00:00:00Z");
    let service = f.service();
    let cancelled = budget();
    cancelled.cancellation.cancel();
    assert_eq!(
        service.purge_unused(&cancelled).unwrap_err().failure,
        EngineFailure::Host(HostError::Cancelled)
    );
    assert_eq!(
        service
            .maintain(
                CacheWatermarks {
                    high_bytes: 0,
                    low_bytes: 0
                },
                &budget()
            )
            .unwrap_err()
            .failure,
        EngineFailure::InvalidBudget
    );
    assert!(ready.path().exists());
    assert!(CacheMaintenance::new(f.cache.clone(), 0).is_err());
    assert!(CacheMaintenance::new(f.cache.clone(), 65_537).is_err());
    assert!(
        CacheMaintenance::new(f.cache.clone(), 1)
            .unwrap()
            .inventory(&budget())
            .is_err()
    );
    assert!(ready.path().exists());
}

#[test]
fn durable_removing_intent_at_canonical_location_resumes_with_entry_authority() {
    let f = Fixture::new();
    let (_, id, ready) = f.add('a', "2026-10-02T00:00:00Z");
    let owners = f
        .cache
        .open_private_child(".staging")
        .unwrap()
        .open_private_child(".owners")
        .unwrap();
    let record = owners.open_file(&format!("{id}.json")).unwrap();
    let mut value: serde_json::Value =
        serde_json::from_slice(&record.read_bounded(&budget()).unwrap()).unwrap();
    value["state"] = "removing".into();
    owners
        .replace_readonly(&record, &serde_json::to_vec(&value).unwrap(), &budget())
        .unwrap();
    let report = f
        .service()
        .maintain(CacheWatermarks::STANDARD, &budget())
        .unwrap();
    assert_eq!(report.recovered_private_directory_count, 1);
    assert_eq!(report.removed_entry_count, 0);
    assert_eq!(report.before.entry_count, 0);
    assert!(!ready.path().exists());
    assert!(
        f.owners
            .published_evidence(&id, &budget())
            .unwrap()
            .is_none()
    );
}

#[test]
fn missing_ready_identity_is_preserved_without_a_durable_removal_intent() {
    let f = Fixture::new();
    let (_, id, ready) = f.add('a', "2026-10-02T00:00:00Z");
    let moved = f.path.join("explicitly-moved-user-payload");
    fs::rename(ready.path(), &moved).unwrap();
    let report = f.service().purge_unused(&budget()).unwrap();
    assert_eq!(report.recovered_private_directory_count, 0);
    assert_eq!(report.removed_entry_count, 0);
    assert!(
        f.owners
            .published_evidence(&id, &budget())
            .unwrap()
            .unwrap()
            .is_ready()
    );
    assert!(moved.join("view-state.json").exists());
}

fn payload_bytes(directory: &HeldDirectory) -> i64 {
    directory
        .child_names(&budget(), 16)
        .unwrap()
        .iter()
        .map(|name| {
            i64::try_from(
                directory
                    .open_file(name.to_str().unwrap())
                    .unwrap()
                    .snapshot()
                    .byte_count,
            )
            .unwrap()
        })
        .sum()
}

#[test]
fn equal_access_time_same_trace_uses_parser_tie_and_stops_exactly_at_low() {
    let f = Fixture::new();
    let (a, _, ar) = f.add_with_parser('a', "2026-10-02T00:00:00Z", 'b');
    let (b, _, br) = f.add_with_parser('a', "2026-10-02T00:00:00Z", 'c');
    let (first, survivor) = if a.cache_key.parser_key() < b.cache_key.parser_key() {
        (&ar, &br)
    } else {
        (&br, &ar)
    };
    let service = f.service();
    let before = service.inventory(&budget()).unwrap();
    let low = payload_bytes(survivor);
    let report = service
        .maintain(
            CacheWatermarks::new(before.total_byte_count - 1, low).unwrap(),
            &budget(),
        )
        .unwrap();
    assert_eq!(report.removed_entry_count, 1);
    assert_eq!(report.after.total_byte_count, low);
    assert_eq!(report.after.entry_count, 1);
    assert!(!first.path().exists());
    assert!(survivor.path().exists());
}

#[test]
fn oldest_busy_entry_is_skipped_and_next_lru_entry_reaches_low() {
    let f = Fixture::new();
    let (a, _, oldest) = f.add('a', "2026-10-02T00:00:00Z");
    let (_, _, next) = f.add('b', "2026-10-03T00:00:00Z");
    let (_, _, newest) = f.add('c', "2026-10-04T00:00:00Z");
    let reader = f.shared(&a);
    let service = f.service();
    let before = service.inventory(&budget()).unwrap();
    let low = payload_bytes(&oldest) + payload_bytes(&newest);
    let report = service
        .maintain(
            CacheWatermarks::new(before.total_byte_count - 1, low).unwrap(),
            &budget(),
        )
        .unwrap();
    assert_eq!(report.skipped_active_entry_count, 1);
    assert_eq!(report.removed_entry_count, 1);
    assert_eq!(report.after.total_byte_count, low);
    assert_eq!(report.after.active_entry_count, 1);
    assert!(oldest.path().exists() && newest.path().exists());
    assert!(!next.path().exists());
    drop(reader);
}

#[cfg(feature = "process-fixtures")]
#[test]
fn cancellation_after_durable_intent_drains_removal_and_does_not_claim_no_mutation() {
    let f = Fixture::new();
    let (m, id, ready) = f.add('a', "2026-10-02T00:00:00Z");
    arktrace_platform::process_fixture::cancel_next_cache_purge_after_intent();
    let error = f.service().purge_unused(&budget()).unwrap_err();
    assert_eq!(error.failure, EngineFailure::Host(HostError::Cancelled));
    assert!(!ready.path().exists());
    assert!(
        f.owners
            .published_evidence(&id, &budget())
            .unwrap()
            .is_none()
    );
    assert_eq!(f.service().inventory(&budget()).unwrap().entry_count, 0);
    assert!(
        f.cache
            .path()
            .join(".leases")
            .join(format!("{}.lease", m.cache_key.entry_identifier()))
            .exists()
    );
}

#[cfg(feature = "process-fixtures")]
mod async_tests {
    use super::*;
    use arktrace_engine::{
        AsyncEngine, CacheRequest, DrainStatus, RequestState, RuntimeConfiguration, RuntimeFailure,
        RuntimeHandle, RuntimeLimits, WorkerBoundary,
    };
    use arktrace_platform::CodeTrustPolicy;
    use std::sync::{Arc, Mutex, atomic::AtomicBool, mpsc};

    fn configuration(f: &Fixture) -> RuntimeConfiguration {
        let metadata = CacheMetadata::decode(include_bytes!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../contracts/ready-metadata.json"
        )))
        .unwrap();
        let mut config = RuntimeConfiguration::new(
            f.path.join("unopened-actor-namespace"),
            f.path.join("absent-tools/helper"),
            f.path.join("absent-tools/parser"),
            "a".repeat(64),
            metadata.parser,
            CodeTrustPolicy::DevelopmentPinned,
        );
        config.cache_directory = Some(f.cache.path().to_owned());
        config.limits = RuntimeLimits {
            workers: 1,
            queue_per_worker: 1,
            requests: 2,
            ..RuntimeLimits::default()
        };
        config
    }
    fn retry<T>(mut call: impl FnMut() -> Result<T, RuntimeFailure>) -> Result<T, RuntimeFailure> {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            match call() {
                Err(RuntimeFailure::Busy) if Instant::now() < deadline => std::thread::yield_now(),
                result => return result,
            }
        }
    }
    fn terminal(engine: &AsyncEngine, request: RuntimeHandle) -> arktrace_engine::RequestStatus {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let status = retry(|| engine.poll(request)).unwrap();
            if matches!(status.state, RequestState::Succeeded | RequestState::Failed) {
                return status;
            }
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(1));
        }
    }
    fn submit(engine: &AsyncEngine, operation: CacheRequest) -> RuntimeHandle {
        retry(|| engine.submit_cache_maintenance(operation, Duration::from_secs(10))).unwrap()
    }
    fn drain(engine: &AsyncEngine) {
        engine.start_drain();
        let deadline = Instant::now() + Duration::from_secs(10);
        while engine.drain_status() != DrainStatus::Drained {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(1));
        }
    }

    #[test]
    fn maintenance_before_open_uses_no_actor_or_parser_and_retains_engine_scoped_result() {
        let f = Fixture::new();
        let (_, _, ready) = f.add('a', "2026-10-02T00:00:00Z");
        let config = configuration(&f);
        let namespace = config.namespace.clone();
        let engine = AsyncEngine::create(config).unwrap();
        let request = submit(&engine, CacheRequest::Inventory);
        let status = terminal(&engine, request);
        assert_eq!(status.state, RequestState::Succeeded);
        assert_eq!(status.session.raw(), 0);
        let result = retry(|| engine.acquire_result(request)).unwrap();
        let expected: serde_json::Value = serde_json::from_slice(result.bytes()).unwrap();
        assert_eq!(expected["session"], 0);
        assert_eq!(expected["request"], request.raw());
        assert_eq!(expected["body"]["entryCount"], 1);
        assert_eq!(expected["body"]["activeEntryCount"], 0);
        retry(|| engine.release_request(request)).unwrap();
        let clone = result.clone();
        let maintained = submit(&engine, CacheRequest::Maintain);
        assert_eq!(terminal(&engine, maintained).state, RequestState::Succeeded);
        retry(|| engine.release_request(maintained)).unwrap();
        assert!(ready.path().exists());
        let purged = submit(&engine, CacheRequest::PurgeUnused);
        assert_eq!(terminal(&engine, purged).state, RequestState::Succeeded);
        let report = retry(|| engine.acquire_result(purged)).unwrap();
        let report_value: serde_json::Value = serde_json::from_slice(report.bytes()).unwrap();
        assert_eq!(report_value["body"]["removedEntryCount"], 1);
        assert_eq!(report_value["body"]["after"]["entryCount"], 0);
        retry(|| engine.release_request(purged)).unwrap();
        assert_eq!(
            engine.session_status(RuntimeHandle::from_raw(0)),
            Err(RuntimeFailure::InvalidHandle)
        );
        assert!(!namespace.exists());
        drain(&engine);
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(clone.bytes()).unwrap(),
            expected
        );
        assert!(engine.retained_result_bytes() > 0);
        drop(result);
        drop(clone);
        drop(report);
        assert_eq!(engine.retained_result_bytes(), 0);
    }

    #[test]
    fn running_and_queued_maintenance_cancel_and_drain_with_bounded_admission() {
        let f = Fixture::new();
        let (_, _, ready) = f.add('a', "2026-10-02T00:00:00Z");
        let (started_send, started_recv) = mpsc::channel();
        let (resume_send, resume_recv) = mpsc::channel();
        let resume = Arc::new(Mutex::new(resume_recv));
        let first = Arc::new(AtomicBool::new(true));
        let config = configuration(&f).observe_worker_for_fixture(Arc::new(move |boundary| {
            if boundary == WorkerBoundary::CacheMaintaining && first.swap(false, Ordering::AcqRel) {
                started_send.send(()).unwrap();
                resume
                    .lock()
                    .unwrap()
                    .recv_timeout(Duration::from_secs(10))
                    .unwrap();
            }
        }));
        let engine = AsyncEngine::create(config).unwrap();
        let running = submit(&engine, CacheRequest::PurgeUnused);
        started_recv.recv_timeout(Duration::from_secs(10)).unwrap();
        let queued = submit(&engine, CacheRequest::PurgeUnused);
        assert_eq!(
            engine.submit_cache_maintenance(CacheRequest::Inventory, Duration::from_secs(1)),
            Err(RuntimeFailure::Capacity)
        );
        retry(|| engine.cancel(queued)).unwrap();
        engine.start_drain();
        assert_eq!(engine.drain_status(), DrainStatus::Draining);
        resume_send.send(()).unwrap();
        drain(&engine);
        for request in [running, queued] {
            let status = terminal(&engine, request);
            assert_eq!(status.state, RequestState::Failed);
            assert_eq!(status.failure, Some(RuntimeFailure::Cancelled));
            assert_eq!(status.session.raw(), 0);
            retry(|| engine.release_request(request)).unwrap();
        }
        assert!(ready.path().exists());
        assert_eq!(engine.retained_result_bytes(), 0);
    }

    #[test]
    fn worker_cancel_after_removal_intent_drains_owned_cleanup_before_terminal_failure() {
        let f = Fixture::new();
        let (metadata, id, ready) = f.add('a', "2026-10-02T00:00:00Z");
        let config = configuration(&f).observe_worker_for_fixture(Arc::new(|boundary| {
            if boundary == WorkerBoundary::CacheMaintaining {
                arktrace_platform::process_fixture::cancel_next_cache_purge_after_intent();
            }
        }));
        let engine = AsyncEngine::create(config).unwrap();
        let request = submit(&engine, CacheRequest::PurgeUnused);
        assert_eq!(
            terminal(&engine, request).failure,
            Some(RuntimeFailure::Cancelled)
        );
        assert!(!ready.path().exists());
        assert!(
            f.owners
                .published_evidence(&id, &budget())
                .unwrap()
                .is_none()
        );
        assert!(
            f.cache
                .path()
                .join(".leases")
                .join(format!("{}.lease", metadata.cache_key.entry_identifier()))
                .exists()
        );
        retry(|| engine.release_request(request)).unwrap();
        drain(&engine);
    }

    #[test]
    fn maintenance_rejects_ephemeral_policy_and_enforces_result_credit_before_publication() {
        let f = Fixture::new();
        let (_, _, ready) = f.add('a', "2026-10-02T00:00:00Z");
        let mut config = configuration(&f);
        config.cache_directory = None;
        let ephemeral = AsyncEngine::create(config).unwrap();
        assert_eq!(
            ephemeral.submit_cache_maintenance(CacheRequest::Inventory, Duration::from_secs(1)),
            Err(RuntimeFailure::InvalidRequest)
        );
        drain(&ephemeral);
        let mut config = configuration(&f);
        config.limits.maximum_retained_result_bytes = 1;
        let engine = AsyncEngine::create(config).unwrap();
        let request = submit(&engine, CacheRequest::Inventory);
        assert_eq!(
            terminal(&engine, request).failure,
            Some(RuntimeFailure::OutputLimit)
        );
        assert!(ready.path().exists());
        assert_eq!(engine.retained_result_bytes(), 0);
        retry(|| engine.release_request(request)).unwrap();
        drain(&engine);
    }
}
