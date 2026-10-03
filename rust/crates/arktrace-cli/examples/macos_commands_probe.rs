#[cfg(target_os = "macos")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use arktrace_cli::{
        CommandError, CommandLimits, DirectoryCommand, ToolIdentity, execute_no_cache,
    };
    use arktrace_contract::{DirectoryNameMatch, ProcessQuery, ThreadQuery, TraceParserIdentity};
    use arktrace_engine::{EngineBudget, ParserTools, SourceFormat, open_no_cache};
    use arktrace_platform::{
        CancellationToken, CodeTrustPolicy, HeldDirectory, HeldFile, IoBudget, OwnerStore,
        VerifiedExecutable,
    };
    use std::{
        fs,
        path::Path,
        time::{Duration, Instant},
    };
    let args = std::env::args_os().skip(1).collect::<Vec<_>>();
    if args.len() != 4 {
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
    let executable = HeldFile::open_explicit_source(&std::env::current_exe()?)?;
    let executable_sha256 = executable.facts(&io())?.sha256;
    let tool = ToolIdentity::from_executable_sha256(executable_sha256.clone())?;
    let workspace = root.create_private_child("cli-no-cache")?;
    let budget = || EngineBudget {
        maximum_source_bytes: 256 * 1024 * 1024,
        maximum_database_bytes: 256 * 1024 * 1024,
        deadline: Instant::now() + Duration::from_secs(30),
        cancellation: CancellationToken::default(),
    };
    let limits = CommandLimits {
        timeout_ms: 30000,
        max_rows: 128,
        max_events: 128,
        max_output_bytes: 8388608,
    };
    let process = || ProcessQuery {
        process_key: None,
        pid: None,
        name: None,
        name_match: DirectoryNameMatch::Exact,
        limit: 128,
    };
    let thread = || ThreadQuery {
        process_key: None,
        pid: None,
        thread_key: None,
        tid: None,
        name: None,
        name_match: DirectoryNameMatch::Exact,
        limit: 128,
    };
    let empty = || -> Result<(), Box<dyn std::error::Error>> {
        assert_eq!(fs::read_dir(workspace.path().join(".ready"))?.count(), 0);
        assert_eq!(fs::read_dir(workspace.path().join(".leases"))?.count(), 0);
        let staging = workspace.open_private_child(".staging")?;
        assert_eq!(fs::read_dir(staging.path())?.count(), 1);
        assert!(
            OwnerStore::open(&staging, &workspace)?
                .identifiers(&io())?
                .is_empty()
        );
        Ok(())
    };
    let mut results = Vec::new();
    for fixture in [
        "zlib.htrace",
        "hiprofiler_data_ability.htrace",
        "trace_small_10.systrace",
    ] {
        let source = HeldFile::open_explicit_source(&fixtures.join(fixture))?;
        let original = source.facts(&io())?;
        let format = if fixture.ends_with(".systrace") {
            SourceFormat::Systrace
        } else {
            SourceFormat::Htrace
        };
        for (name, command) in [
            ("inspect", DirectoryCommand::Inspect),
            ("processes", DirectoryCommand::Processes(process())),
            ("threads", DirectoryCommand::Threads(thread())),
        ] {
            let request = budget();
            let session = open_no_cache(&source, format, &tools, &workspace, &request, |_| {})?;
            let bytes = execute_no_cache(session, command, &tool, limits, &request)?;
            assert_eq!(bytes.last(), Some(&b'\n'));
            assert!(bytes.len() <= limits.max_output_bytes);
            let document: serde_json::Value = serde_json::from_slice(&bytes)?;
            empty()?;
            assert_eq!(source.facts(&io())?, original);
            results.push(serde_json::json!({"fixture":fixture,"command":name,"document":document,"encodedByteCount":bytes.len(),"rawBytesUnchanged":true,"explicitCloseRemovedReadyOwnersAndLeases":true}));
        }
    }
    let source = HeldFile::open_explicit_source(&fixtures.join("zlib.htrace"))?;
    let original = source.facts(&io())?;
    let mut failures = Vec::new();
    for scenario in ["output-limit", "cancelled", "deadline", "invalid-limit"] {
        let mut request = budget();
        let session = open_no_cache(
            &source,
            SourceFormat::Htrace,
            &tools,
            &workspace,
            &request,
            |_| {},
        )?;
        let mut output_limits = limits;
        let expected = match scenario {
            "output-limit" => {
                output_limits.max_output_bytes = 1024;
                CommandError::OutputLimitExceeded
            }
            "cancelled" => {
                request.cancellation.cancel();
                CommandError::Cancelled
            }
            "deadline" => {
                request.deadline = Instant::now() - Duration::from_millis(1);
                CommandError::DeadlineExceeded
            }
            _ => {
                output_limits.max_rows = 0;
                CommandError::InvalidArguments
            }
        };
        let result = execute_no_cache(
            session,
            DirectoryCommand::Threads(thread()),
            &tool,
            output_limits,
            &request,
        );
        assert_eq!(result, Err(expected));
        empty()?;
        assert_eq!(source.facts(&io())?, original);
        failures.push(serde_json::json!({"scenario":scenario,"error":expected,"successBytesReturned":false,"rawBytesUnchanged":true,"explicitCloseRemovedReadyOwnersAndLeases":true}));
    }
    // Typed SDK filters reuse the same connection after a rejected request.
    let open_budget = budget();
    let session = open_no_cache(
        &source,
        SourceFormat::Htrace,
        &tools,
        &workspace,
        &open_budget,
        |_| {},
    )?;
    let rows = session.processes(&process(), &budget())?;
    let first = rows.items.first().ok_or("expected process fixture")?;
    let mut query = process();
    query.process_key = Some(first.key);
    let rejected = budget();
    rejected.cancellation.cancel();
    assert!(session.processes(&query, &rejected).is_err());
    let reduced = EngineBudget {
        maximum_database_bytes: 1,
        ..budget()
    };
    assert_eq!(
        serde_json::to_value(session.processes(&query, &reduced).unwrap_err().failure)?,
        serde_json::json!({"Store":{"Host":"LimitExceeded"}})
    );
    let filtered = session.processes(&query, &budget())?;
    assert_eq!(filtered.items, vec![first.clone()]);
    let mut query = thread();
    query.process_key = Some(first.key);
    let children = session.threads(&query, &budget())?;
    assert!(
        !children.items.is_empty()
            && children
                .items
                .iter()
                .all(|v| v.process_key == Some(first.key))
    );
    session.close()?;
    empty()?;
    assert_eq!(source.facts(&io())?, original);
    println!(
        "{}",
        serde_json::json!({"readyAcceptance":false,"developmentTrustOnly":true,"productionCliReplacement":false,"toolExecutableSHA256":executable_sha256,"results":results,"negativeCases":failures,"typedSessionFiltersAndNextRequest":true})
    );
    Ok(())
}
#[cfg(not(target_os = "macos"))]
fn main() {
    panic!("native macOS probe; cannot simulate")
}
