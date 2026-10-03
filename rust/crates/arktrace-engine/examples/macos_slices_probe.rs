#[cfg(target_os = "macos")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use arktrace_contract::{
        EventKey, EventTable, TraceParserIdentity, TraceSliceQuery, TraceTimeRange,
    };
    use arktrace_engine::{
        EngineBudget, EngineFailure, EngineStage, ParserTools, SourceFormat, open_no_cache,
    };
    use arktrace_platform::{
        CancellationToken, CodeTrustPolicy, HeldDirectory, HeldFile, HostError, IoBudget,
        OwnerStore, VerifiedExecutable,
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
        query: TraceSliceQuery,
    }
    let args = std::env::args_os().skip(1).collect::<Vec<_>>();
    if args.len() != 5 {
        return Err("owned root, fixture root, parser identity, helper pin, cases required".into());
    }
    let root = HeldDirectory::open_private(Path::new(&args[0]))?;
    let fixtures = Path::new(&args[1]);
    let identity: TraceParserIdentity =
        serde_json::from_str(args[2].to_str().ok_or("invalid identity")?)?;
    let input = args[4].to_str().ok_or("invalid cases")?;
    if input.len() > 65536 {
        return Err("case byte budget".into());
    }
    let cases: Vec<Case> = serde_json::from_str(input)?;
    if cases.is_empty()
        || cases.len() > 64
        || cases
            .iter()
            .any(|c| c.id.len() > 128 || c.query.limit > 128)
    {
        return Err("case budget".into());
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
    let workspace = root.create_private_child("slices-no-cache")?;
    let budget = || EngineBudget {
        maximum_source_bytes: 256 * 1024 * 1024,
        maximum_database_bytes: 256 * 1024 * 1024,
        deadline: Instant::now() + Duration::from_secs(30),
        cancellation: CancellationToken::default(),
    };
    let mut results = Vec::new();
    let mut negatives = Vec::new();
    let mut sources = Vec::new();
    let mut sdk = Vec::new();
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
        let selected: Vec<_> = cases.iter().filter(|c| c.fixture == fixture).collect();
        if selected.is_empty() {
            return Err("missing fixture cases".into());
        }
        for case in &selected {
            results.push(serde_json::json!({"id":case.id,"fixture":fixture,"repositoryPage":session.slices(&case.query,&budget())?,"page":session.query_slices(&case.query,&budget())?}));
        }
        let good = selected[0].query.clone();
        let expected = session.slices(&good, &budget())?;
        if let Some(first) = expected.items.first() {
            let one = TraceSliceQuery {
                event_key: Some(first.key),
                limit: 1,
                ..good.clone()
            };
            let raw = session.slices(&one, &budget())?;
            assert_eq!(raw.items.len(), 1);
            assert_eq!(raw.items[0].key, first.key);
            assert!(raw.items[0].arg_set_id.is_none());
            let handles = session.slices(
                &TraceSliceQuery {
                    includes_argument_set: true,
                    ..one
                },
                &budget(),
            )?;
            assert_eq!(serde_json::to_value(&raw)?, serde_json::to_value(&handles)?);
            sdk.push(serde_json::json!({"fixture":fixture,"eventKey":first.key,"exactEventIdentity":true,"defaultArgumentHandle":raw.items[0].arg_set_id,"requestedArgumentHandle":handles.items[0].arg_set_id,"machineShapeUnchanged":true}));
        }
        for scenario in [
            "cancelled",
            "deadline",
            "database-budget",
            "invalid-limit",
            "degenerate-range",
            "name-byte-budget",
            "agent-name-byte-budget",
            "empty-agent-name",
            "name-match-without-name",
            "negative-duration",
            "negative-depth",
            "wrong-event-table",
            "outside-trace",
        ] {
            let mut b = budget();
            let mut q = good.clone();
            let expected_failure = match scenario {
                "cancelled" => {
                    b.cancellation.cancel();
                    EngineFailure::Host(HostError::Cancelled)
                }
                "deadline" => {
                    b.deadline = Instant::now() - Duration::from_millis(1);
                    EngineFailure::Host(HostError::DeadlineExceeded)
                }
                "database-budget" => {
                    b.maximum_database_bytes = 1;
                    EngineFailure::Store(StoreError::Host(HostError::LimitExceeded))
                }
                "invalid-limit" => {
                    q.limit = 0;
                    EngineFailure::Store(StoreError::InvalidQuery)
                }
                "degenerate-range" => {
                    q.range = TraceTimeRange::event(0, 0).map_err(|_| "range")?;
                    EngineFailure::Store(StoreError::InvalidQuery)
                }
                "name-byte-budget" => {
                    q.name = Some("界".repeat(1366));
                    EngineFailure::Store(StoreError::InvalidQuery)
                }
                "agent-name-byte-budget" => {
                    q.name = Some(format!("{}aa", "界".repeat(85)));
                    EngineFailure::Store(StoreError::InvalidQuery)
                }
                "empty-agent-name" => {
                    q.name = Some(String::new());
                    EngineFailure::Store(StoreError::InvalidQuery)
                }
                "name-match-without-name" => {
                    q.name_match = arktrace_contract::DirectoryNameMatch::Prefix;
                    EngineFailure::Store(StoreError::InvalidQuery)
                }
                "negative-duration" => {
                    q.minimum_duration_ns = Some(-1);
                    EngineFailure::Store(StoreError::InvalidQuery)
                }
                "negative-depth" => {
                    q.depth = Some(-1);
                    EngineFailure::Store(StoreError::InvalidQuery)
                }
                "wrong-event-table" => {
                    q.event_key = Some(EventKey {
                        table: EventTable::SchedSlice,
                        row_id: 1,
                    });
                    EngineFailure::Store(StoreError::InvalidQuery)
                }
                _ => {
                    q.range = TraceTimeRange::query(0, session.inspection().duration_ns + 1)
                        .map_err(|_| "range")?;
                    EngineFailure::Store(StoreError::InvalidQuery)
                }
            };
            let error = session.query_slices(&q, &b).unwrap_err();
            assert_eq!(error.stage, EngineStage::Querying);
            assert_eq!(error.failure, expected_failure);
            assert_eq!(session.slices(&good, &budget())?, expected);
            negatives.push(serde_json::json!({"fixture":fixture,"scenario":scenario,"error":error,"publicError":error.public_error(),"nextRequestUnchanged":true}));
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
        sources.push(serde_json::json!({"fixture":fixture,"source":{"sha256":original.sha256,"byteCount":original.byte_count},"inspection":inspection,"rawBytesUnchanged":true,"explicitCloseRemovedReadyOwnersAndLeases":true}));
    }
    assert_eq!(results.len(), cases.len());
    println!(
        "{}",
        serde_json::json!({"results":results,"negativeCases":negatives,"sdkCases":sdk,"sources":sources,"developmentTrustOnly":true,"readyAcceptance":false,"productionCliReplacement":false})
    );
    Ok(())
}
#[cfg(not(target_os = "macos"))]
fn main() {
    panic!("native macOS required; no simulated PASS");
}
