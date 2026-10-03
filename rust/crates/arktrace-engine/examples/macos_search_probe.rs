#[cfg(target_os = "macos")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use arktrace_contract::{
        DirectoryNameMatch, ProcessQuery, SearchDomains, ThreadQuery, TraceParserIdentity,
        TraceSearchRequest, TraceSliceQuery,
    };
    use arktrace_engine::{
        AnalysisFailure, EngineBudget, EngineFailure, EngineStage, ParserTools, SourceFormat,
        open_no_cache,
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
        process::Command,
        time::{Duration, Instant},
    };
    #[derive(Clone, Deserialize, serde::Serialize)]
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
    struct Case {
        fixture: String,
        id: String,
        query: TraceSearchRequest,
    }
    let args = std::env::args_os().skip(1).collect::<Vec<_>>();
    if args.len() != 6 {
        return Err(
            "owned root, fixtures, identity, helper pin, cases, Swift probe required".into(),
        );
    }
    let root = HeldDirectory::open_private(Path::new(&args[0]))?;
    let fixtures = Path::new(&args[1]);
    let identity: TraceParserIdentity = serde_json::from_str(args[2].to_str().ok_or("identity")?)?;
    let input = args[4].to_str().ok_or("cases")?;
    if input.len() > 65536 {
        return Err("case byte budget".into());
    }
    let cases: Vec<Case> = serde_json::from_str(input)?;
    if cases.is_empty()
        || cases.len() > 64
        || cases
            .iter()
            .any(|c| c.id.len() > 128 || c.query.validate().is_err())
    {
        return Err("case budget".into());
    }
    let io = || IoBudget {
        maximum_bytes: 256 * 1024 * 1024,
        deadline: Instant::now() + Duration::from_secs(60),
        cancellation: CancellationToken::default(),
    };
    let tool_root = root.open_private_child("tools")?;
    let helper = VerifiedExecutable::verify(
        tool_root.open_file("host-process")?,
        args[3].to_str().ok_or("helper pin")?,
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
    let workspace = root.create_private_child("search-no-cache")?;
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
        let mut selected = cases
            .iter()
            .filter(|c| c.fixture == fixture)
            .cloned()
            .collect::<Vec<_>>();
        if selected.is_empty() {
            return Err("missing fixture".into());
        }
        let process_seed = session.processes(
            &ProcessQuery {
                process_key: None,
                pid: None,
                name: None,
                name_match: DirectoryNameMatch::Exact,
                limit: 16,
            },
            &budget(),
        )?;
        let thread_seed = session.threads(
            &ThreadQuery {
                process_key: None,
                pid: None,
                thread_key: None,
                tid: None,
                name: None,
                name_match: DirectoryNameMatch::Exact,
                limit: 16,
            },
            &budget(),
        )?;
        let slice_seed = session.slices(
            &TraceSliceQuery {
                range: arktrace_contract::TraceTimeRange::query(
                    0,
                    session.inspection().duration_ns,
                )
                .map_err(|_| "invalid trace duration")?,
                event_key: None,
                process_key: None,
                pid: None,
                thread_key: None,
                tid: None,
                name: None,
                name_match: DirectoryNameMatch::Exact,
                minimum_duration_ns: None,
                depth: None,
                includes_argument_set: false,
                limit: 16,
            },
            &budget(),
        )?;
        let mut add = |suffix: String, text: String, domains: SearchDomains, limit: usize| {
            selected.push(Case {
                id: format!("{fixture}/{suffix}"),
                fixture: fixture.into(),
                query: TraceSearchRequest {
                    text,
                    limit,
                    domains,
                },
            });
        };
        for (i, row) in process_seed.items.iter().take(2).enumerate() {
            add(
                format!("process-{i}-pid"),
                row.pid.to_string(),
                SearchDomains::PROCESS,
                16,
            );
            add(
                format!("process-{i}-identity"),
                format!("ipid:{}", row.key),
                SearchDomains::PROCESS,
                16,
            );
            add(
                format!("process-{i}-limit-one"),
                row.pid.to_string(),
                SearchDomains::ALL,
                1,
            );
            if let Some(name) = row
                .name
                .as_ref()
                .filter(|s| !s.is_empty() && s.len() <= 256)
            {
                add(
                    format!("process-{i}-name"),
                    name.clone(),
                    SearchDomains::PROCESS,
                    16,
                );
            }
        }
        for (i, row) in thread_seed.items.iter().take(2).enumerate() {
            add(
                format!("thread-{i}-tid"),
                row.tid.to_string(),
                SearchDomains::TOOLBAR,
                16,
            );
            add(
                format!("thread-{i}-identity"),
                format!("itid:{}", row.key),
                SearchDomains::THREAD,
                16,
            );
            if let Some(name) = row
                .name
                .as_ref()
                .filter(|s| !s.is_empty() && s.len() <= 256)
            {
                add(
                    format!("thread-{i}-name"),
                    name.clone(),
                    SearchDomains::TOOLBAR,
                    16,
                );
            }
        }
        for (i, row) in slice_seed.items.iter().take(2).enumerate() {
            let name = row.name.chars().take(40).collect::<String>();
            if !name.is_empty() {
                add(format!("slice-{i}-name"), name, SearchDomains::SLICE, 1);
            }
        }
        if selected.len() > 64 {
            return Err("source case budget".into());
        }
        // This test-only subprocess reads the same immutable Ready inode while
        // Engine retains its lease. Production queries never accept a DB path.
        let ready = fs::read_dir(workspace.path().join(".ready"))?
            .next()
            .ok_or("Ready absent")??
            .path()
            .join("trace.db");
        let swift = Command::new(&args[5])
            .args([
                ready.as_os_str(),
                args[2].as_os_str(),
                std::ffi::OsStr::new(&serde_json::to_string(
                    &serde_json::json!({"sha256":original.sha256,"byteCount":original.byte_count}),
                )?),
                std::ffi::OsStr::new(&serde_json::to_string(&selected)?),
            ])
            .output()?;
        if !swift.status.success() {
            return Err(format!(
                "Swift oracle failed: {}",
                String::from_utf8_lossy(&swift.stderr)
            )
            .into());
        }
        if swift.stdout.len() > 8 * 1024 * 1024 {
            return Err("Swift output byte budget".into());
        }
        let oracle: Vec<serde_json::Value> = serde_json::from_slice(&swift.stdout)?;
        if oracle.len() != selected.len() {
            return Err("Swift case budget".into());
        }
        let mut positive_count = 0;
        for (case, expected) in selected.iter().zip(oracle) {
            let page = session.search(&case.query, &budget())?;
            positive_count += usize::from(!page.items.is_empty());
            let row = serde_json::json!({"id":case.id,"results":page});
            if row["id"] != expected["id"] || row["results"] != expected["results"] {
                eprintln!(
                    "{}",
                    serde_json::json!({"case":case.id,"rust":row,"swift":expected})
                );
                return Err("search parity".into());
            }
            results.push(serde_json::json!({"fixture":fixture,"query":case.query,"rust":row,"swift":expected,"parity":"T0"}));
        }
        if positive_count == 0 {
            return Err("real positive search required".into());
        }
        let good = selected
            .iter()
            .find(|c| c.id.ends_with("process-0-pid"))
            .ok_or("positive process seed")?
            .query
            .clone();
        let expected = session.search(&good, &budget())?;
        for scenario in [
            "cancelled",
            "deadline",
            "database-budget",
            "invalid-limit",
            "over-limit",
            "invalid-domains",
            "oversized-text",
        ] {
            let mut b = budget();
            let mut q = good.clone();
            let failure = match scenario {
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
                _ => {
                    match scenario {
                        "invalid-limit" => q.limit = 0,
                        "over-limit" => q.limit = 1001,
                        "invalid-domains" => q.domains = SearchDomains(0),
                        "oversized-text" => q.text = "中".repeat(86),
                        _ => return Err("negative scenario".into()),
                    }
                    EngineFailure::Analysis(AnalysisFailure::InvalidBounds)
                }
            };
            let error = session.search(&q, &b).unwrap_err();
            assert_eq!(
                error.stage,
                if scenario == "database-budget" {
                    EngineStage::Querying
                } else {
                    EngineStage::Analyzing
                }
            );
            assert_eq!(error.failure, failure);
            assert_eq!(session.search(&good, &budget())?, expected);
            negatives.push(serde_json::json!({"fixture":fixture,"scenario":scenario,"error":error,"publicError":error.public_error(),"nextRequestUnchanged":true}));
        }
        let inspection = session.inspection().clone();
        session.close()?;
        assert_eq!(fs::read_dir(workspace.path().join(".ready"))?.count(), 0);
        assert_eq!(fs::read_dir(workspace.path().join(".leases"))?.count(), 0);
        let staging = workspace.open_private_child(".staging")?;
        assert!(
            OwnerStore::open(&staging, &workspace)?
                .identifiers(&io())?
                .is_empty()
        );
        assert_eq!(source.facts(&io())?, original);
        sources.push(serde_json::json!({"fixture":fixture,"source":{"sha256":original.sha256,"byteCount":original.byte_count},"inspection":inspection,"boundedSeedPages":{"processes":process_seed,"threads":thread_seed,"slices":slice_seed},"positiveSearches":positive_count,"rawBytesUnchanged":true,"explicitCloseRemovedReadyOwnersAndLeases":true}));
    }
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
