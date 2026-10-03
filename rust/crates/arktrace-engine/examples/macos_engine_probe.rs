#[cfg(target_os = "macos")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use arktrace_contract::TraceParserIdentity;
    use arktrace_engine::{
        EngineBudget, EngineProgress, NoCacheRecoveryOutcome, ParserTools, SourceFormat,
        open_no_cache, recover_no_cache,
    };
    use arktrace_platform::{
        CancellationToken, CodeTrustPolicy, HeldDirectory, HeldFile, IoBudget,
        OwnerRecoveryOutcome, OwnerStore, VerifiedExecutable,
    };
    use std::{
        fs,
        os::unix::fs::PermissionsExt,
        path::Path,
        time::{Duration, Instant},
    };
    let args = std::env::args_os().skip(1).collect::<Vec<_>>();
    if args.len() != 4 && args.len() != 6 {
        return Err("owned root, fixture root, parser identity JSON, helper pin required".into());
    }
    let root = HeldDirectory::open_private(Path::new(&args[0]))?;
    let fixtures = Path::new(&args[1]);
    let identity: TraceParserIdentity =
        serde_json::from_str(args[2].to_str().ok_or("invalid identity")?)?;
    let tool_root = root.open_private_child("tools")?;
    let io = || IoBudget {
        maximum_bytes: 256 * 1024 * 1024,
        deadline: Instant::now() + Duration::from_secs(60),
        cancellation: CancellationToken::default(),
    };
    let helper = VerifiedExecutable::verify(
        tool_root.open_file("host-process")?,
        args[3].to_str().ok_or("invalid helper pin")?,
        CodeTrustPolicy::DevelopmentPinned,
        &io(),
    )?;
    let parser = VerifiedExecutable::verify(
        tool_root.open_file("trace-streamer")?,
        &identity.binary_sha256,
        CodeTrustPolicy::DevelopmentPinned,
        &io(),
    )?;
    let tools = ParserTools {
        helper: &helper,
        parser: &parser,
        identity,
    };
    let control = if args.len() == 6 {
        let action = args[4].to_str().ok_or("invalid action")?;
        let window = args[5].to_str().ok_or("invalid window")?;
        if !["--pause-ready", "--recover-ready"].contains(&action)
            || ![
                "OpeningDatabase",
                "Ready",
                "Returned",
                "BeforeRename",
                "AfterRename",
                "Cleanup0",
                "Cleanup1",
                "Cleanup2",
                "Cleanup3",
                "Cleanup4",
                "LeaseUnlink0",
                "LeaseUnlink1",
            ]
            .contains(&window)
        {
            return Err("unsupported control window".into());
        }
        Some((action, window))
    } else {
        None
    };
    let workspace = match control {
        Some((_, window)) => root.ensure_private_child(&format!("engine-crash-{window}"))?,
        None => root.create_private_child("engine-no-cache")?,
    };
    let budget = || EngineBudget {
        maximum_source_bytes: 256 * 1024 * 1024,
        maximum_database_bytes: 256 * 1024 * 1024,
        deadline: Instant::now() + Duration::from_secs(60),
        cancellation: CancellationToken::default(),
    };
    let empty = || -> Result<(), Box<dyn std::error::Error>> {
        assert_eq!(fs::read_dir(workspace.path().join(".ready"))?.count(), 0);
        assert_eq!(fs::read_dir(workspace.path().join(".leases"))?.count(), 0);
        let stage = workspace.open_private_child(".staging")?;
        assert_eq!(fs::read_dir(stage.path())?.count(), 1);
        assert!(
            OwnerStore::open(&stage, &workspace)?
                .identifiers(&io())?
                .is_empty()
        );
        Ok(())
    };
    if let Some((action, window)) = control {
        let source = HeldFile::open_explicit_source(&fixtures.join("zlib.htrace"))?;
        let before = source.facts(&io())?;
        if action == "--recover-ready" {
            let rows = recover_no_cache(&workspace, &budget())?;
            assert_eq!(
                rows.len(),
                if ["OpeningDatabase", "BeforeRename", "AfterRename"].contains(&window) {
                    2
                } else {
                    1
                }
            );
            if window == "Cleanup3" {
                assert_eq!(
                    rows[0].outcome,
                    NoCacheRecoveryOutcome::Owner(OwnerRecoveryOutcome::IdentityUnresolved)
                );
                assert_eq!(fs::read_dir(workspace.path().join(".ready"))?.count(), 0);
                assert_eq!(fs::read_dir(workspace.path().join(".leases"))?.count(), 1);
                assert_eq!(
                    OwnerStore::open(&workspace.open_private_child(".staging")?, &workspace)?
                        .identifiers(&io())?
                        .len(),
                    1
                );
            } else {
                assert!(rows.iter().all(|row| row.outcome
                    == NoCacheRecoveryOutcome::Owner(OwnerRecoveryOutcome::Removed)));
                empty()?;
            }
            assert_eq!(source.facts(&io())?, before);
            println!(
                "{}",
                serde_json::json!({"window":window,"recovery":rows,"rawUnchanged":true,"readyOwnersAndLeasesRemoved":window!="Cleanup3","unresolvedIdentityAndBoundLeaseRetained":window=="Cleanup3","readyAcceptance":false})
            );
            return Ok(());
        }
        let pause = || {
            fs::write(
                workspace.path().join("worker-window.tmp"),
                serde_json::to_vec(&serde_json::json!({"pid":std::process::id(),"window":window}))
                    .unwrap(),
            )
            .unwrap();
            fs::rename(
                workspace.path().join("worker-window.tmp"),
                workspace.path().join("worker-window.json"),
            )
            .unwrap();
            loop {
                std::thread::sleep(Duration::from_millis(5));
            }
        };
        #[cfg(feature = "process-fixtures")]
        match window {
            "BeforeRename" => arktrace_platform::process_fixture::pause_ephemeral_owner(0)?,
            "AfterRename" => arktrace_platform::process_fixture::pause_ephemeral_owner(1)?,
            _ => {}
        }
        #[cfg(not(feature = "process-fixtures"))]
        if !["OpeningDatabase", "Ready", "Returned"].contains(&window) {
            return Err("process-fixtures required for native owner fault windows".into());
        }
        let session = open_no_cache(
            &source,
            SourceFormat::Htrace,
            &tools,
            &workspace,
            &budget(),
            |event| {
                if (window == "OpeningDatabase" && event == EngineProgress::OpeningDatabase)
                    || (window == "Ready" && event == EngineProgress::Ready)
                {
                    pause();
                }
            },
        )?;
        if window == "Returned" {
            session.verify(&budget())?;
            pause();
        }
        #[cfg(feature = "process-fixtures")]
        if let Some(point) = window.strip_prefix("Cleanup") {
            arktrace_platform::process_fixture::pause_owner_cleanup(point.parse()?)?;
            session.close()?;
            return Err("close missed cleanup fault window".into());
        }
        #[cfg(feature = "process-fixtures")]
        if let Some(point) = window.strip_prefix("LeaseUnlink") {
            arktrace_platform::process_fixture::pause_ephemeral_owner(2 + point.parse::<u8>()?)?;
            session.close()?;
            return Err("close missed lease unlink fault window".into());
        }
        return Err("worker missed pause window".into());
    }
    let mut results = Vec::new();
    for (index, (name, format)) in [
        ("zlib.htrace", SourceFormat::Htrace),
        ("hiprofiler_data_ability.htrace", SourceFormat::Htrace),
        ("trace_small_10.systrace", SourceFormat::Systrace),
    ]
    .into_iter()
    .enumerate()
    {
        let source = HeldFile::open_explicit_source(&fixtures.join(name))?;
        let before = source.facts(&io())?;
        let mut events = Vec::new();
        let request = budget();
        let session = open_no_cache(&source, format, &tools, &workspace, &request, |event| {
            events.push(event)
        })?;
        session.verify(&request)?;
        let names =
            fs::read_dir(workspace.path().join(".ready"))?.collect::<Result<Vec<_>, _>>()?;
        assert_eq!(names.len(), 1);
        let ready = workspace
            .open_private_child(".ready")?
            .open_private_child(names[0].file_name().to_str().ok_or("invalid ready name")?)?;
        ready.require_file_membership(&["trace.db", "metadata.json"], &io())?;
        let database = ready.open_file("trace.db")?;
        let metadata = ready.open_file("metadata.json")?;
        let facts = database.facts(&io())?;
        assert_eq!(
            fs::metadata(database.path())?.permissions().mode() & 0o777,
            0o400
        );
        assert_eq!(
            fs::metadata(metadata.path())?.permissions().mode() & 0o777,
            0o400
        );
        root.copy_snapshot(&database, &format!("engine-case-{index}.db"), false, &io())?;
        root.copy_snapshot(
            &metadata,
            &format!("engine-case-{index}-metadata.json"),
            false,
            &io(),
        )?;
        let row = serde_json::json!({"fixture":name,"sourceByteCount":before.byte_count,"sourceSHA256":before.sha256,
            "databaseSHA256":facts.sha256,"databaseByteCount":facts.byte_count,"metadata":session.metadata(),"inspection":session.inspection(),"progress":events});
        session.close()?;
        empty()?;
        assert_eq!(source.facts(&io())?, before);
        results.push(row);
    }
    let source = HeldFile::open_explicit_source(&fixtures.join("zlib.htrace"))?;
    let before = source.facts(&io())?;
    let request = budget();
    let first = open_no_cache(
        &source,
        SourceFormat::Htrace,
        &tools,
        &workspace,
        &request,
        |_| {},
    )?;
    let second = open_no_cache(
        &source,
        SourceFormat::Htrace,
        &tools,
        &workspace,
        &request,
        |_| {},
    )?;
    assert_eq!(fs::read_dir(workspace.path().join(".ready"))?.count(), 2);
    first.close()?;
    second.verify(&request)?;
    second.close()?;
    empty()?;
    let mut failures = Vec::new();
    for scenario in [
        "cancel-source",
        "cancel-parse",
        "cancel-index",
        "cancel-publish",
        "cancel-after-publish",
        "deadline-after-publish",
        "writable-after-publish",
        "replace-ready-directory",
        "database-output-budget",
        "scratch-output-budget",
        "parser-version",
    ] {
        let mut request = budget();
        let mut local = ParserTools {
            helper: &helper,
            parser: &parser,
            identity: tools.identity.clone(),
        };
        if scenario == "database-output-budget" {
            request.maximum_database_bytes = 1;
        }
        if scenario == "scratch-output-budget" {
            request.maximum_source_bytes = before.byte_count;
        }
        if scenario == "parser-version" {
            local.identity.reported_version = "4.3.8".into();
        }
        if scenario == "deadline-after-publish" {
            request.deadline = Instant::now() + Duration::from_secs(5);
        }
        let mut saw_ready = false;
        let mut foreign_path = None;
        let result = open_no_cache(
            &source,
            SourceFormat::Htrace,
            &local,
            &workspace,
            &request,
            |event| {
                if event == EngineProgress::Ready {
                    saw_ready = true;
                }
                let cancel = match scenario {
                    "cancel-source" => event == EngineProgress::SourceSnapshot,
                    "cancel-parse" => event == EngineProgress::Parsing,
                    "cancel-index" => matches!(event, EngineProgress::Indexing(_)),
                    "cancel-publish" => event == EngineProgress::Publishing,
                    "cancel-after-publish" => event == EngineProgress::OpeningDatabase,
                    _ => false,
                };
                if cancel {
                    request.cancellation.cancel();
                }
                if scenario == "deadline-after-publish" && event == EngineProgress::OpeningDatabase
                {
                    std::thread::sleep(
                        request.deadline.saturating_duration_since(Instant::now())
                            + Duration::from_millis(2),
                    );
                }
                if scenario == "writable-after-publish" && event == EngineProgress::OpeningDatabase
                {
                    let path = fs::read_dir(workspace.path().join(".ready"))
                        .unwrap()
                        .next()
                        .unwrap()
                        .unwrap()
                        .path()
                        .join("trace.db");
                    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
                }
                if scenario == "replace-ready-directory" && event == EngineProgress::OpeningDatabase
                {
                    let path = fs::read_dir(workspace.path().join(".ready"))
                        .unwrap()
                        .next()
                        .unwrap()
                        .unwrap()
                        .path();
                    fs::rename(&path, workspace.path().join("relocated-owned-entry")).unwrap();
                    use std::os::unix::fs::DirBuilderExt;
                    fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
                    fs::write(path.join("foreign-bytes"), b"preserve foreign replacement").unwrap();
                    foreign_path = Some(path);
                }
            },
        );
        assert!(!saw_ready);
        let error = match result {
            Err(e) => e,
            Ok(session) => {
                session.close()?;
                return Err("negative returned Ready".into());
            }
        };
        if let Some(path) = foreign_path {
            assert_eq!(
                fs::read(path.join("foreign-bytes"))?,
                b"preserve foreign replacement"
            );
            assert!(!workspace.path().join("relocated-owned-entry").exists());
            // This test owns the injected fixture; Engine has preserved it.
            fs::remove_dir_all(path)?;
        }
        empty()?;
        assert_eq!(source.facts(&io())?, before);
        failures.push(serde_json::json!({"scenario":scenario,"error":error,"returnedReady":false,"transientsRemoved":true,"rawUnchanged":true,
            "foreignReplacementPreserved":scenario=="replace-ready-directory","testInjectedForeignFixtureRemoved":scenario=="replace-ready-directory"}));
    }
    let mut recovery_cases = Vec::new();
    for scenario in [
        "active-ready",
        "dropped-ready",
        "moved-ready",
        "invalid-metadata",
    ] {
        let session = open_no_cache(
            &source,
            SourceFormat::Htrace,
            &tools,
            &workspace,
            &budget(),
            |_| {},
        )?;
        let ready_path = fs::read_dir(workspace.path().join(".ready"))?
            .next()
            .unwrap()?
            .path();
        let encoded = fs::read(ready_path.join("metadata.json"))?;
        if scenario == "active-ready" {
            let rows = recover_no_cache(&workspace, &budget())?;
            assert_eq!(rows.len(), 1);
            assert_eq!(
                rows[0].outcome,
                NoCacheRecoveryOutcome::Owner(OwnerRecoveryOutcome::Active)
            );
            session.verify(&budget())?;
            session.close()?;
            empty()?;
            recovery_cases.push(serde_json::json!({"scenario":scenario,"recovery":rows,"activeSessionPreserved":true}));
            continue;
        }
        drop(session);
        if scenario == "moved-ready" {
            fs::rename(&ready_path, workspace.path().join("moved-owned-ready"))?;
            use std::os::unix::fs::DirBuilderExt;
            fs::DirBuilder::new().mode(0o700).create(&ready_path)?;
            fs::write(ready_path.join("foreign"), b"foreign ready replacement")?;
        }
        let mut initial_rejection = None;
        if scenario == "invalid-metadata" {
            let path = ready_path.join("metadata.json");
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
            fs::write(&path, b"{\"formatVersion\":1,\"unknown\":true}")?;
            fs::set_permissions(&path, fs::Permissions::from_mode(0o400))?;
            let rows = recover_no_cache(&workspace, &budget())?;
            assert_eq!(rows.len(), 1);
            assert_eq!(
                rows[0].outcome,
                NoCacheRecoveryOutcome::Rejected(arktrace_engine::EngineFailure::InvalidMetadata)
            );
            assert_eq!(fs::read_dir(workspace.path().join(".leases"))?.count(), 1);
            assert!(ready_path.exists());
            initial_rejection = Some(rows);
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
            fs::write(&path, &encoded)?;
            fs::set_permissions(&path, fs::Permissions::from_mode(0o400))?;
        }
        let rows = recover_no_cache(&workspace, &budget())?;
        assert_eq!(rows.len(), 1);
        assert_eq!(
            rows[0].outcome,
            NoCacheRecoveryOutcome::Owner(OwnerRecoveryOutcome::Removed)
        );
        if scenario == "moved-ready" {
            assert_eq!(
                fs::read(ready_path.join("foreign"))?,
                b"foreign ready replacement"
            );
            assert!(!workspace.path().join("moved-owned-ready").exists());
            fs::remove_dir_all(&ready_path)?;
        }
        empty()?;
        assert_eq!(source.facts(&io())?, before);
        recovery_cases.push(serde_json::json!({"scenario":scenario,"recovery":rows,"initialRejection":initial_rejection,
            "rawUnchanged":true,"foreignReplacementPreserved":scenario=="moved-ready","ownedReadyAndLeaseRemoved":true}));
    }
    println!(
        "{}",
        serde_json::json!({"version":1,"readyAcceptance":false,"engineNoCacheReadyPublication":true,"developmentTrustOnly":true,
        "results":results,"negativeCases":failures,"recoveryCases":recovery_cases,"simultaneousIndependentNoCacheSessions":true,"explicitCloseRemovedReadyOwnersAndLeases":true})
    );
    Ok(())
}
#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("native macOS required; no simulated acceptance");
    std::process::exit(2);
}
