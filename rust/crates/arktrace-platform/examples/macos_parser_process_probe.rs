//! Real pinned C++ export through the native supervisor. Not a Ready DB gate.
#[cfg(target_os = "macos")]
mod native {
    use arktrace_platform::{
        CancellationToken, CodeTrustPolicy, HeldDirectory, HeldFile, HostError, IoBudget,
        OwnerKind, OwnerStore, ProcessBudget, ProcessError, ProcessOutputFileBudget,
        VerifiedExecutable, run_supervised,
    };
    use std::{
        ffi::OsString,
        path::Path,
        time::{Duration, Instant},
    };

    fn io_budget() -> IoBudget {
        IoBudget {
            maximum_bytes: 256 * 1024 * 1024,
            deadline: Instant::now() + Duration::from_secs(60),
            cancellation: CancellationToken::default(),
        }
    }
    fn process_budget() -> ProcessBudget {
        ProcessBudget {
            deadline: Instant::now() + Duration::from_secs(60),
            cancellation: CancellationToken::default(),
            stdout_bytes: 65_536,
            stderr_bytes: 65_536,
            termination_grace: Duration::from_millis(500),
            output_files: Vec::new(),
        }
    }
    fn copy_tool(
        root: &HeldDirectory,
        path: &Path,
        name: &str,
        expected: &str,
    ) -> VerifiedExecutable {
        let raw = HeldFile::open_explicit_source(path).unwrap();
        let (copy, facts) = root.copy_snapshot(&raw, name, true, &io_budget()).unwrap();
        assert_eq!(facts.sha256, expected);
        VerifiedExecutable::verify(
            copy,
            expected,
            CodeTrustPolicy::DevelopmentPinned,
            &io_budget(),
        )
        .unwrap()
    }
    pub fn run() {
        let args: Vec<_> = std::env::args_os().skip(1).collect();
        if args.len() == 2 && args[0] == "--recover-staging" {
            let root = HeldDirectory::open_private(Path::new(&args[1])).unwrap();
            let stage = HeldDirectory::open_private(&root.path().join("stage")).unwrap();
            let store = OwnerStore::open(&stage, &root).unwrap();
            let results = store.identifiers(&io_budget()).unwrap().iter().map(|identifier| {
                serde_json::json!({"identifier":identifier,"outcome":store.recover_stale(identifier,&io_budget()).unwrap()})
            }).collect::<Vec<_>>();
            println!(
                "{}",
                serde_json::json!({"ownerEvidenceVersion":2,"results":results})
            );
            return;
        }
        assert_eq!(
            args.len(),
            6,
            "private root, helper, helper pin, parser, parser pin, fixtures required"
        );
        let root = HeldDirectory::open_private(Path::new(&args[0])).unwrap();
        let tools = root.create_private_child("tools").unwrap();
        let helper = copy_tool(
            &tools,
            Path::new(&args[1]),
            "host-process",
            args[2].to_str().unwrap(),
        );
        let parser = copy_tool(
            &tools,
            Path::new(&args[3]),
            "trace-streamer",
            args[4].to_str().unwrap(),
        );
        let version = run_supervised(
            &helper,
            &parser,
            &root,
            &[OsString::from("--version")],
            &process_budget(),
        )
        .unwrap();
        assert_eq!(version.exit_code, Some(1));
        assert_eq!(version.signal, None);
        let text = format!(
            "{}\n{}",
            String::from_utf8_lossy(&version.stdout),
            String::from_utf8_lossy(&version.stderr)
        );
        assert!(text.contains("version 4.3.7"));
        let mut exports = Vec::new();
        let stage = root.create_private_child("stage").unwrap();
        let owner_store = OwnerStore::open(&stage, &root).unwrap();
        let published_root = root.create_private_child("published").unwrap();
        for (index, name) in [
            "zlib.htrace",
            "hiprofiler_data_ability.htrace",
            "trace_small_10.systrace",
        ]
        .iter()
        .enumerate()
        {
            let raw = HeldFile::open_explicit_source(&Path::new(&args[5]).join(name)).unwrap();
            let original = raw.facts(&io_budget()).unwrap();
            let session_owner = owner_store
                .create(OwnerKind::Session, &io_budget())
                .unwrap();
            let session = session_owner.directory();
            let (snapshot, copied) = session
                .copy_snapshot(&raw, name, false, &io_budget())
                .unwrap();
            assert_eq!(original, copied);
            let database = session.path().join("partial.db");
            let start = Instant::now();
            let budget = ProcessBudget {
                output_files: vec![
                    ProcessOutputFileBudget {
                        name: OsString::from("partial.db"),
                        maximum_bytes: 256 * 1024 * 1024,
                    },
                    ProcessOutputFileBudget {
                        name: OsString::from("partial.db.ohos.ts"),
                        maximum_bytes: 65_536,
                    },
                ],
                ..process_budget()
            };
            let outcome = run_supervised(
                &helper,
                &parser,
                session,
                &[
                    snapshot.path().into_os_string(),
                    OsString::from("-e"),
                    database.into_os_string(),
                    OsString::from("-nm"),
                ],
                &budget,
            )
            .unwrap();
            assert_eq!(outcome.exit_code, Some(0));
            assert_eq!(outcome.signal, None);
            assert!(!outcome.escalated_to_kill);
            snapshot.verify().unwrap();
            assert_eq!(raw.facts(&io_budget()).unwrap(), original);
            let db = session.open_file("partial.db").unwrap();
            let db_facts = db.facts(&io_budget()).unwrap();
            assert_eq!(
                outcome.output_file_bytes.first(),
                Some(&Some(db_facts.byte_count))
            );
            let mut candidate_owner = owner_store
                .create(OwnerKind::Building, &io_budget())
                .unwrap();
            let candidate = candidate_owner.directory().clone();
            let (_, copy_facts) = candidate
                .copy_snapshot(&db, "trace.db", false, &io_budget())
                .unwrap();
            assert_eq!(copy_facts, db_facts);
            // Development marker only; production metadata/schema/owner proofs
            // must be supplied by parser/Store before Engine can expose Ready.
            let marker = serde_json::to_vec(&serde_json::json!({"kind":"native-directory-publication-probe","readyAcceptance":false,"databaseSHA256":db_facts.sha256})).unwrap();
            candidate
                .write_new_readonly("probe.json", &marker, &io_budget())
                .unwrap();
            let sealed = candidate.seal_readonly_directory(&io_budget()).unwrap();
            let published = stage
                .promote_sealed_directory_noreplace(
                    &sealed,
                    &published_root,
                    &format!("case-{index}"),
                    &io_budget(),
                )
                .unwrap();
            candidate_owner
                .record_published_location(&published, &io_budget())
                .unwrap();
            assert_eq!(published.identity(), candidate.identity());
            assert_eq!(
                published
                    .open_file("trace.db")
                    .unwrap()
                    .facts(&io_budget())
                    .unwrap(),
                db_facts
            );
            assert!(!candidate.path().exists());
            let sidecar = match session.open_file("partial.db.ohos.ts") {
                Ok(f) => Some(f),
                Err(HostError::NotFound) => None,
                Err(error) => panic!("sidecar admission failed: {error:?}"),
            }
            .map(|f| {
                assert!(f.snapshot().byte_count <= 65_536);
                let facts = f.facts(&io_budget()).unwrap();
                serde_json::json!({"byteCount":facts.byte_count,"sha256":facts.sha256})
            });
            assert_eq!(
                outcome.output_file_bytes[1],
                sidecar.as_ref().map(|v| v["byteCount"].as_u64().unwrap())
            );
            exports.push(serde_json::json!({"fixture":name,"sourceByteCount":original.byte_count,"sourceSHA256":original.sha256,"rawBytesUnchanged":true,"databaseByteCount":db_facts.byte_count,"databaseSHA256":db_facts.sha256,"sidecar":sidecar,"liveOutputFileBytes":outcome.output_file_bytes,"exitCode":outcome.exit_code,"stdoutByteCount":outcome.stdout.len(),"stderrByteCount":outcome.stderr.len(),"wallTimeMs":start.elapsed().as_millis(),"sessionDirectory":format!("stage/{}",session_owner.identifier()),"sessionOwnerIdentifier":session_owner.identifier(),"publishedOwnerIdentifier":candidate_owner.identifier(),"publishedDirectory":format!("published/case-{index}"),"sealedPublicationVerified":true}));
        }
        let mut budget_failures = Vec::new();
        for (kind, database_limit, sidecar_limit, index) in [
            ("database", 1, 65_536, 0),
            ("sidecar", 256 * 1024 * 1024, 89, 1),
        ] {
            let raw =
                HeldFile::open_explicit_source(&Path::new(&args[5]).join("zlib.htrace")).unwrap();
            let original = raw.facts(&io_budget()).unwrap();
            let session_owner = owner_store
                .create(OwnerKind::Session, &io_budget())
                .unwrap();
            let session = session_owner.directory();
            let (snapshot, copied) = session
                .copy_snapshot(&raw, "zlib.htrace", false, &io_budget())
                .unwrap();
            assert_eq!(original, copied);
            let budget = ProcessBudget {
                output_files: vec![
                    ProcessOutputFileBudget {
                        name: "partial.db".into(),
                        maximum_bytes: database_limit,
                    },
                    ProcessOutputFileBudget {
                        name: "partial.db.ohos.ts".into(),
                        maximum_bytes: sidecar_limit,
                    },
                ],
                ..process_budget()
            };
            let result = run_supervised(
                &helper,
                &parser,
                session,
                &[
                    snapshot.path().into_os_string(),
                    "-e".into(),
                    session.path().join("partial.db").into_os_string(),
                    "-nm".into(),
                ],
                &budget,
            );
            let expected = ProcessError::OutputFileLimitExceeded { index };
            assert_eq!(result, Err(expected));
            snapshot.verify().unwrap();
            assert_eq!(raw.facts(&io_budget()).unwrap(), original);
            assert!(
                !published_root
                    .path()
                    .join(format!("budget-{kind}"))
                    .exists()
            );
            budget_failures.push(serde_json::json!({"fixture":"zlib.htrace","kind":kind,"databaseLimitBytes":database_limit,"sidecarLimitBytes":sidecar_limit,"failure":expected,"rawBytesUnchanged":true,"published":false,"sessionDirectory":format!("stage/{}",session_owner.identifier()),"sessionOwnerIdentifier":session_owner.identifier()}));
        }
        println!(
            "{}",
            serde_json::json!({"schemaVersion":"arktrace.native-parser-process/1","helperSHA256":helper.sha256(),"parserSHA256":parser.sha256(),"parserTrust":parser.trust(),"reportedVersion":"4.3.7","versionExitCode":version.exit_code,"ownerEvidenceVersion":2,"exports":exports,"budgetFailures":budget_failures,"readyAcceptance":false})
        );
    }
}
fn main() {
    #[cfg(target_os = "macos")]
    native::run();
    #[cfg(not(target_os = "macos"))]
    panic!("native macOS parser process probe required");
}
