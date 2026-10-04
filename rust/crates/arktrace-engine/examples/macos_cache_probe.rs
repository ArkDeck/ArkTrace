#[cfg(target_os = "macos")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use arktrace_contract::{ProcessQuery, TraceParserIdentity};
    use arktrace_engine::{
        EngineBudget, EngineFailure, EngineProgress, ParserTools, SourceFormat, ViewStateRead,
        open_cached,
    };
    use arktrace_platform::{
        CancellationToken, CodeTrustPolicy, HeldDirectory, HeldFile, IoBudget, Lease, LeaseMode,
        OwnerStore, VerifiedExecutable,
    };
    use std::{
        fs,
        path::Path,
        time::{Duration, Instant},
    };
    let args = std::env::args_os().skip(1).collect::<Vec<_>>();
    if args.first().and_then(|a| a.to_str()) == Some("--purge-interrupted") {
        #[cfg(feature = "process-fixtures")]
        {
            if args.len() != 3 {
                return Err("cache root and cleanup point required".into());
            }
            let cache = HeldDirectory::open_private(Path::new(&args[1]))?;
            let point: u8 = args[2].to_str().ok_or("invalid point")?.parse()?;
            arktrace_platform::process_fixture::pause_owner_cleanup(point)?;
            let maintenance = arktrace_engine::CacheMaintenance::new(cache, 4096)?;
            maintenance.purge_unused(&IoBudget {
                maximum_bytes: 16_384,
                deadline: Instant::now() + Duration::from_secs(120),
                cancellation: CancellationToken::default(),
            })?;
            return Err("expected interrupted purge window".into());
        }
        #[cfg(not(feature = "process-fixtures"))]
        return Err("purge interruption requires development fixtures".into());
    }
    if args.len() != 5 {
        return Err(
            "private root, source, identity JSON, helper pin, source format required".into(),
        );
    }
    let root = HeldDirectory::open_private(Path::new(&args[0]))?;
    let source = HeldFile::open_explicit_source(Path::new(&args[1]))?;
    let identity: TraceParserIdentity =
        serde_json::from_str(args[2].to_str().ok_or("invalid identity")?)?;
    let format = match args[4].to_str() {
        Some("htrace") => SourceFormat::Htrace,
        Some("systrace") => SourceFormat::Systrace,
        _ => return Err("invalid format".into()),
    };
    let io = || IoBudget {
        maximum_bytes: 256 * 1024 * 1024,
        deadline: Instant::now() + Duration::from_secs(120),
        cancellation: CancellationToken::default(),
    };
    let budget = || EngineBudget {
        maximum_source_bytes: 256 * 1024 * 1024,
        maximum_database_bytes: 256 * 1024 * 1024,
        deadline: Instant::now() + Duration::from_secs(120),
        cancellation: CancellationToken::default(),
    };
    let tool_root = root.open_private_child("tools")?;
    let helper = VerifiedExecutable::verify(
        tool_root.open_file("helper")?,
        args[3].to_str().ok_or("invalid helper pin")?,
        CodeTrustPolicy::DevelopmentPinned,
        &io(),
    )?;
    let parser = VerifiedExecutable::verify(
        tool_root.open_file("parser")?,
        &identity.binary_sha256,
        CodeTrustPolicy::DevelopmentPinned,
        &io(),
    )?;
    let tools = ParserTools {
        helper: &helper,
        parser: &parser,
        identity,
    };
    let cache = root.create_private_child("cache")?;
    let before = source.facts(&io())?;
    let mut cold_progress = vec![];
    let first = open_cached(&source, format, &tools, &cache, &budget(), |p| {
        cold_progress.push(p)
    })?;
    assert!(!first.cache_hit() && cold_progress.contains(&EngineProgress::Parsing));
    let query = ProcessQuery {
        process_key: None,
        pid: None,
        name: None,
        name_match: arktrace_contract::DirectoryNameMatch::Exact,
        limit: 100,
    };
    let original_page = serde_json::to_value(first.processes(&query, &budget())?)?;
    let metadata = first.metadata().clone();
    let key = metadata.cache_key.clone();
    let directory = cache
        .open_private_child(key.trace_sha256())?
        .open_private_child(key.parser_key())?;
    let database_before = directory.open_file("trace.sqlite")?.facts(&io())?;
    std::thread::sleep(Duration::from_secs(1));
    let mut warm_progress = vec![];
    let second = open_cached(&source, format, &tools, &cache, &budget(), |p| {
        warm_progress.push(p)
    })?;
    assert!(
        second.cache_hit()
            && !warm_progress.contains(&EngineProgress::Parsing)
            && !warm_progress.contains(&EngineProgress::ParserIdentity)
    );
    assert_eq!(second.metadata().created_at, metadata.created_at);
    assert!(second.metadata().last_accessed_at > metadata.last_accessed_at);
    assert_eq!(
        serde_json::to_value(first.processes(&query, &budget())?)?,
        original_page
    );
    first.verify(&budget())?;
    second.verify(&budget())?;
    let mut too_small = budget();
    too_small.maximum_database_bytes = 1;
    assert!(open_cached(&source, format, &tools, &cache, &too_small, |_| {}).is_err());
    assert_eq!(
        directory.open_file("trace.sqlite")?.facts(&io())?,
        database_before
    );
    first.verify(&budget())?;
    second.verify(&budget())?;
    assert!(!cache.path().join(".corrupt").exists());
    let leases = cache.open_private_child(".leases")?;
    let lease_name = format!("{}.lease", key.entry_identifier());
    assert!(Lease::try_acquire(&leases, &lease_name, LeaseMode::Exclusive, false)?.is_none());
    assert_eq!(first.read_view_state(&budget())?, ViewStateRead::Missing);
    let sidecar_bytes = serde_json::to_vec(
        &serde_json::json!({"formatVersion":1,"traceSHA256":metadata.trace_sha256,
        "flags":[{"id":1,"timestampNs":0,"label":"保存 🦀","colorIndex":2}],"marks":[],"favoriteTrackIDs":["cpu:0"]}),
    )?;
    let sidecar = directory.write_new_readonly("view-state.json", &sidecar_bytes, &io())?;
    let restored = first.read_view_state(&budget())?;
    let ViewStateRead::Restored(document) = restored else {
        return Err("native sidecar did not restore".into());
    };
    assert_eq!(document.flags[0].label, "保存 🦀");
    assert_eq!(document.favorite_track_ids, Some(vec!["cpu:0".into()]));
    assert_eq!(
        second.read_view_state(&budget())?,
        ViewStateRead::Restored(document)
    );
    let cancelled = budget();
    cancelled.cancellation.cancel();
    assert!(first.read_view_state(&cancelled).is_err());
    assert_eq!(sidecar.read_bounded(&io())?, sidecar_bytes);
    let lock_parent = cache.open_private_child(".locks")?;
    let key_lock = Lease::acquire(
        &lock_parent,
        &format!("{}.lock", key.entry_identifier()),
        LeaseMode::Exclusive,
        &io(),
    )?;
    let short = EngineBudget {
        deadline: Instant::now() + Duration::from_millis(25),
        ..budget()
    };
    assert!(first.read_view_state(&short).is_err());
    drop(key_lock);
    let future_sidecar = serde_json::to_vec(
        &serde_json::json!({"formatVersion":999,"traceSHA256":metadata.trace_sha256,"flags":[],"marks":[]}),
    )?;
    let sidecar = directory.replace_readonly(&sidecar, &future_sidecar, &io())?;
    assert_eq!(first.read_view_state(&budget())?, ViewStateRead::Preserved);
    assert_eq!(sidecar.read_bounded(&io())?, future_sidecar);
    directory.remove_owned_file("view-state.json", sidecar.snapshot().identity)?;
    directory.write_new_readonly("view-state.json", b"{\"fixtureUserState\":true}", &io())?;
    assert_eq!(first.read_view_state(&budget())?, ViewStateRead::Preserved);
    let current = directory.open_file("metadata.json")?;
    let saved = current.read_bounded(&io())?;
    let mut corrupt: serde_json::Value = serde_json::from_slice(&saved)?;
    corrupt["databaseByteCount"] = serde_json::json!(0);
    let corrupt_bytes = serde_json::to_vec(&corrupt)?;
    directory.replace_readonly(&current, &corrupt_bytes, &io())?;
    let started = Instant::now();
    let error = match open_cached(&source, format, &tools, &cache, &budget(), |_| {}) {
        Ok(_) => return Err("active corrupt cache admitted".into()),
        Err(e) => e,
    };
    assert_eq!(error.failure, EngineFailure::CacheBusy);
    assert!(started.elapsed() < Duration::from_secs(5));
    assert_eq!(
        directory.open_file("metadata.json")?.read_bounded(&io())?,
        corrupt_bytes
    );
    assert_eq!(
        directory.open_file("trace.sqlite")?.facts(&io())?,
        database_before
    );
    first.close()?;
    second.close()?;
    assert!(directory.path().join("trace.sqlite").exists());
    let mut rebuild_progress = vec![];
    let rebuilt = open_cached(&source, format, &tools, &cache, &budget(), |p| {
        rebuild_progress.push(p)
    })?;
    assert!(!rebuilt.cache_hit() && rebuild_progress.contains(&EngineProgress::Parsing));
    assert_eq!(
        serde_json::to_value(rebuilt.processes(&query, &budget())?)?,
        original_page
    );
    rebuilt.close()?;
    let corrupt_root = cache.open_private_child(".corrupt")?;
    let quarantine_entries = fs::read_dir(corrupt_root.path())?.collect::<Result<Vec<_>, _>>()?;
    assert_eq!(quarantine_entries.len(), 1);
    let quarantined = corrupt_root.open_private_child(
        quarantine_entries[0]
            .file_name()
            .to_str()
            .ok_or("invalid quarantine name")?,
    )?;
    assert_eq!(
        quarantined
            .open_file("metadata.json")?
            .read_bounded(&io())?,
        corrupt_bytes
    );
    assert_eq!(
        quarantined
            .open_file("view-state.json")?
            .read_bounded(&io())?,
        b"{\"fixtureUserState\":true}"
    );
    assert_eq!(
        quarantined.open_file("trace.sqlite")?.facts(&io())?,
        database_before
    );
    let directory = cache
        .open_private_child(key.trace_sha256())?
        .open_private_child(key.parser_key())?;
    let current = directory.open_file("metadata.json")?;
    let valid = current.read_bounded(&io())?;
    let mut future: serde_json::Value = serde_json::from_slice(&valid)?;
    future["formatVersion"] = serde_json::json!(999);
    let future_bytes = serde_json::to_vec(&future)?;
    directory.replace_readonly(&current, &future_bytes, &io())?;
    let error = match open_cached(&source, format, &tools, &cache, &budget(), |_| {}) {
        Ok(_) => return Err("future metadata admitted".into()),
        Err(e) => e,
    };
    assert_eq!(error.failure, EngineFailure::CacheUnsupported);
    assert_eq!(
        directory.open_file("metadata.json")?.read_bounded(&io())?,
        future_bytes
    );
    assert_eq!(fs::read_dir(corrupt_root.path())?.count(), 1);
    directory.replace_readonly(&directory.open_file("metadata.json")?, &valid, &io())?;
    let third = open_cached(&source, format, &tools, &cache, &budget(), |_| {})?;
    assert!(third.cache_hit());
    third.close()?;
    let mut cancelled = vec![];
    for phase in [EngineProgress::Publishing, EngineProgress::OpeningDatabase] {
        let isolated = root.create_private_child(if phase == EngineProgress::Publishing {
            "cancel-before-publication"
        } else {
            "cancel-after-publication"
        })?;
        let b = budget();
        let error = match open_cached(&source, format, &tools, &isolated, &b, |p| {
            if p == phase {
                b.cancellation.cancel();
            }
        }) {
            Ok(_) => return Err("cancelled opening admitted".into()),
            Err(e) => e,
        };
        assert_eq!(
            error.public_error().code(),
            arktrace_contract::Code::Cancelled
        );
        let owners = OwnerStore::open(&isolated.open_private_child(".staging")?, &isolated)?;
        assert!(owners.identifiers(&io())?.is_empty());
        assert!(
            !isolated
                .path()
                .join(key.trace_sha256())
                .join(key.parser_key())
                .exists()
        );
        assert_eq!(fs::read_dir(isolated.path().join(".leases"))?.count(), 1);
        cancelled.push(phase);
    }
    assert_eq!(source.facts(&io())?, before);
    let stage = cache.open_private_child(".staging")?;
    let owners = OwnerStore::open(&stage, &cache)?;
    assert_eq!(owners.identifiers(&io())?.len(), 2); // Ready + preserved quarantine proof.
    assert_eq!(fs::read_dir(stage.path())?.count(), 1); // Only .owners.
    assert_eq!(fs::read_dir(leases.path())?.count(), 1);
    let maintenance_proof = if std::env::var_os("ARKTRACE_CACHE_MAINTENANCE_PROBE").is_some() {
        use arktrace_engine::{CacheMaintenance, CacheWatermarks};
        let maintenance = CacheMaintenance::new(cache.clone(), 4096)?;
        let active = open_cached(&source, format, &tools, &cache, &budget(), |_| {})?;
        let second_active = open_cached(&source, format, &tools, &cache, &budget(), |_| {})?;
        let active_inventory = maintenance.inventory(&io())?;
        assert_eq!(active_inventory.entry_count, 1);
        assert_eq!(active_inventory.active_entry_count, 1);
        let skipped = maintenance.purge_unused(&io())?;
        assert_eq!(skipped.removed_entry_count, 0);
        assert_eq!(skipped.skipped_active_entry_count, 1);
        assert_eq!(
            serde_json::to_value(active.processes(&query, &budget())?)?,
            original_page
        );
        active.close()?;
        let one_left = maintenance.purge_unused(&io())?;
        assert_eq!(one_left.removed_entry_count, 0);
        assert_eq!(one_left.skipped_active_entry_count, 1);
        assert_eq!(
            serde_json::to_value(second_active.processes(&query, &budget())?)?,
            original_page
        );
        second_active.close()?;
        let before_purge = maintenance.inventory(&io())?;
        let purged = maintenance.purge_unused(&io())?;
        assert_eq!(purged.removed_entry_count, 1);
        assert_eq!(purged.after.entry_count, 0);
        assert_eq!(fs::read_dir(leases.path())?.count(), 1);
        assert_eq!(owners.identifiers(&io())?.len(), 1); // preserved quarantine only
        let reparsed = open_cached(&source, format, &tools, &cache, &budget(), |_| {})?;
        assert!(!reparsed.cache_hit());
        assert_eq!(
            serde_json::to_value(reparsed.processes(&query, &budget())?)?,
            original_page
        );
        reparsed.close()?;
        let threshold = maintenance.inventory(&io())?;
        let no_op =
            maintenance.maintain(CacheWatermarks::new(threshold.total_byte_count, 0)?, &io())?;
        assert_eq!(no_op.removed_entry_count, 0);
        let lru = maintenance.maintain(
            CacheWatermarks::new(threshold.total_byte_count - 1, 0)?,
            &io(),
        )?;
        assert_eq!(lru.removed_entry_count, 1);
        #[cfg(feature = "process-fixtures")]
        let interrupted = {
            use std::{os::unix::process::ExitStatusExt, process::Command};
            struct ChildGuard(std::process::Child, bool);
            impl Drop for ChildGuard {
                fn drop(&mut self) {
                    if self.1 {
                        let _ = self.0.kill();
                        let _ = self.0.wait();
                    }
                }
            }
            let executable = std::env::current_exe()?;
            let marker = cache.path().join("owner-window.json");
            let mut rows = Vec::new();
            for point in [0_u8, 1, 2, 3, 4] {
                let reopened = open_cached(&source, format, &tools, &cache, &budget(), |_| {})?;
                reopened.close()?;
                if marker.exists() {
                    fs::remove_file(&marker)?;
                }
                let mut child = ChildGuard(
                    Command::new(&executable)
                        .arg("--purge-interrupted")
                        .arg(cache.path())
                        .arg(point.to_string())
                        .spawn()?,
                    true,
                );
                let until = Instant::now() + Duration::from_secs(10);
                let window = loop {
                    if marker.exists() {
                        let v: serde_json::Value = serde_json::from_slice(&fs::read(&marker)?)?;
                        if v["point"] == point && v["pid"].as_u64() == Some(u64::from(child.0.id()))
                        {
                            break v;
                        }
                    }
                    if child.0.try_wait()?.is_some() {
                        child.1 = false;
                        return Err("purge child exited before its window".into());
                    }
                    if Instant::now() >= until {
                        return Err("purge window timeout".into());
                    }
                    std::thread::sleep(Duration::from_millis(5));
                };
                child.0.kill()?;
                let status = child.0.wait()?;
                child.1 = false;
                assert_eq!(status.signal(), Some(9));
                let recovered = maintenance.maintain(CacheWatermarks::STANDARD, &io())?;
                assert_eq!(
                    recovered.recovered_private_directory_count,
                    usize::from(point < 3)
                );
                assert_eq!(recovered.after.entry_count, 0);
                assert_eq!(owners.identifiers(&io())?.len(), 1);
                assert_eq!(fs::read_dir(leases.path())?.count(), 1);
                assert_eq!(
                    cache
                        .open_private_child(".staging")?
                        .child_names(&io(), 4096)?
                        .len(),
                    1
                );
                rows.push(serde_json::json!({"window":window,"exitSuccess":status.success(),"signal":status.signal(),"recovery":recovered}));
                fs::remove_file(&marker)?;
            }
            rows
        };
        #[cfg(not(feature = "process-fixtures"))]
        let interrupted: Vec<serde_json::Value> = Vec::new();
        assert_eq!(source.facts(&io())?, before);
        assert_eq!(
            quarantined.open_file("trace.sqlite")?.facts(&io())?,
            database_before
        );
        assert_eq!(
            quarantined
                .open_file("view-state.json")?
                .read_bounded(&io())?,
            b"{\"fixtureUserState\":true}"
        );
        Some(
            serde_json::json!({"beforePurge":before_purge,"activeInventory":active_inventory,"oneReaderLeft":one_left,
            "skipped":skipped,"purged":purged,"thresholdNoOp":no_op,"lru":lru,"interruptedPurges":interrupted,
            "rawSourceUnchanged":true,"reparseAfterPurge":true,"quarantinePreserved":true,"stableLeasePreserved":true,
            "runtimeSDKMaintenanceConnected":false,"appCutover":false,"fullCacheAcceptance":false}),
        )
    } else {
        None
    };
    println!(
        "{}",
        serde_json::json!({"coldProgress":cold_progress,"warmProgress":warm_progress,"rebuildProgress":rebuild_progress,
        "coldParsed":true,"warmDidNotParse":true,"warmTimestampAdvanced":true,"concurrentSessionSurvivesTouch":true,
        "closePreservesReady":true,"exclusiveLeaseBlockedByReaders":true,"activeCorruptionBoundedBusy":true,"lowDatabaseBudgetPreservesReady":true,
        "corruptionQuarantinedWithUserSidecar":true,"futureFormatPreserved":true,"cancelledPhases":cancelled,
        "stableLeaseCount":1,"ownerProofCount":owners.identifiers(&io())?.len(),"stagingPayloadCount":0,"rawSourceUnchanged":true,
        "sourceSHA256":before.sha256,"sourceBytes":before.byte_count,"databaseSHA256":database_before.sha256,"databaseBytes":database_before.byte_count,
        "nativeSessionSidecarRead":true,"nativeSessionSidecarCancelAndLockBudget":true,"unknownSidecarBytesPreserved":true,
        "processPage":original_page,"maintenance":maintenance_proof,"fullCacheAcceptance":false,"appCutover":false})
    );
    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("macOS cache probe requires a native macOS runner");
}
