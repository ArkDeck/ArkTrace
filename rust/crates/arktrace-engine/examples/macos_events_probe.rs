#[cfg(target_os = "macos")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use arktrace_contract::{CpuSliceQuery, ThreadStateQuery, TraceParserIdentity, TraceTimeRange};
    use arktrace_engine::{
        EngineBudget, EngineFailure, EngineStage, ParserTools, SourceFormat, open_no_cache,
    };
    use arktrace_platform::{
        CancellationToken, CodeTrustPolicy, HeldDirectory, HeldFile, IoBudget, OwnerStore,
        VerifiedExecutable,
    };
    use arktrace_store::StoreError;
    use serde::Deserialize;
    use std::{
        fs,
        path::Path,
        time::{Duration, Instant},
    };

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
    struct Case {
        fixture: String,
        id: String,
        cpu_query: Option<CpuSliceQuery>,
        state_query: Option<ThreadStateQuery>,
    }
    let args = std::env::args_os().skip(1).collect::<Vec<_>>();
    if args.len() != 5 {
        return Err(
            "owned root, fixture root, parser identity, helper pin, query cases required".into(),
        );
    }
    let root = HeldDirectory::open_private(Path::new(&args[0]))?;
    let fixtures = Path::new(&args[1]);
    let identity: TraceParserIdentity =
        serde_json::from_str(args[2].to_str().ok_or("invalid identity")?)?;
    let input = args[4].to_str().ok_or("invalid cases")?;
    if input.len() > 65536 {
        return Err("case budget".into());
    }
    let cases: Vec<Case> = serde_json::from_str(input)?;
    if cases.is_empty()
        || cases.len() > 100
        || cases
            .iter()
            .any(|c| c.id.len() > 128 || c.cpu_query.is_some() == c.state_query.is_some())
    {
        return Err("invalid case set".into());
    }
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
    let workspace = root.create_private_child("event-no-cache")?;
    let budget = || EngineBudget {
        maximum_source_bytes: 256 * 1024 * 1024,
        maximum_database_bytes: 256 * 1024 * 1024,
        deadline: Instant::now() + Duration::from_secs(30),
        cancellation: CancellationToken::default(),
    };
    let mut results = Vec::new();
    let mut negatives = Vec::new();
    let mut sources = Vec::new();
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
        let session = open_no_cache(&source, format, &tools, &workspace, &budget(), |_| {})?;
        let mut count = 0;
        for case in cases.iter().filter(|c| c.fixture == fixture) {
            if let Some(query) = &case.cpu_query {
                if query.limit > 128 {
                    return Err("native row budget".into());
                }
                results.push(serde_json::json!({"id":case.id,"fixture":fixture,"repositoryPage":session.cpu_slices(query,&budget())?,"page":session.query_cpu_slices(query,&budget())?}));
            } else if let Some(query) = &case.state_query {
                if query.limit > 128 {
                    return Err("native row budget".into());
                }
                results.push(serde_json::json!({"id":case.id,"fixture":fixture,"repositoryPage":session.thread_states(query,&budget())?,"page":session.query_thread_states(query,&budget())?}));
            }
            count += 1;
        }
        if count == 0 {
            return Err("missing native fixture cases".into());
        }
        let good = CpuSliceQuery {
            range: TraceTimeRange::query(0, session.inspection().duration_ns)
                .map_err(|_| "invalid range")?,
            cpu: None,
            process_key: None,
            pid: None,
            thread_key: None,
            tid: None,
            limit: 1,
        };
        let expected_page = session.cpu_slices(&good, &budget())?;
        for scenario in [
            "cancelled",
            "deadline",
            "database-budget",
            "invalid-limit",
            "degenerate-range",
            "raw-state-byte-budget",
        ] {
            let mut request = budget();
            let mut query = good.clone();
            let expected = match scenario {
                "cancelled" => {
                    request.cancellation.cancel();
                    EngineFailure::Host(arktrace_platform::HostError::Cancelled)
                }
                "deadline" => {
                    request.deadline = Instant::now() - Duration::from_millis(1);
                    EngineFailure::Host(arktrace_platform::HostError::DeadlineExceeded)
                }
                "database-budget" => {
                    request.maximum_database_bytes = 1;
                    EngineFailure::Store(StoreError::Host(
                        arktrace_platform::HostError::LimitExceeded,
                    ))
                }
                "invalid-limit" => {
                    query.limit = usize::MAX;
                    EngineFailure::Store(StoreError::InvalidQuery)
                }
                "degenerate-range" => {
                    query.range = TraceTimeRange::event(0, 0).map_err(|_| "invalid range")?;
                    EngineFailure::Store(StoreError::InvalidQuery)
                }
                _ => EngineFailure::Store(StoreError::InvalidQuery),
            };
            let error = if scenario == "raw-state-byte-budget" {
                session
                    .thread_states(
                        &ThreadStateQuery {
                            range: good.range,
                            cpu: None,
                            process_key: None,
                            pid: None,
                            thread_key: None,
                            tid: None,
                            raw_state: Some("界".repeat(86)),
                            state: None,
                            limit: 1,
                        },
                        &request,
                    )
                    .unwrap_err()
            } else {
                session.cpu_slices(&query, &request).unwrap_err()
            };
            assert_eq!(error.stage, EngineStage::Querying);
            assert_eq!(error.failure, expected);
            assert_eq!(session.cpu_slices(&good, &budget())?, expected_page);
            negatives.push(serde_json::json!({"fixture":fixture,"scenario":scenario,"error":error,"nextRequestUnchanged":true}));
        }
        let inspection = session.inspection().clone();
        session.close()?;
        assert_eq!(fs::read_dir(workspace.path().join(".ready"))?.count(), 0);
        assert_eq!(fs::read_dir(workspace.path().join(".leases"))?.count(), 0);
        let staging = workspace.open_private_child(".staging")?;
        assert_eq!(fs::read_dir(staging.path())?.count(), 1);
        assert!(
            OwnerStore::open(&staging, &workspace)?
                .identifiers(&io())?
                .is_empty()
        );
        assert_eq!(source.facts(&io())?, original);
        sources.push(serde_json::json!({"fixture":fixture,"source":{"sha256":original.sha256,"byteCount":original.byte_count},"inspection":inspection,"explicitCloseRemovedReadyOwnersAndLeases":true,"rawBytesUnchanged":true}));
    }
    assert_eq!(results.len(), cases.len());
    println!(
        "{}",
        serde_json::json!({"results":results,"negativeCases":negatives,"sources":sources,"developmentTrustOnly":true,"readyAcceptance":false,"productionCliReplacement":false})
    );
    Ok(())
}
#[cfg(not(target_os = "macos"))]
fn main() {
    panic!("native macOS required; no simulated PASS");
}
