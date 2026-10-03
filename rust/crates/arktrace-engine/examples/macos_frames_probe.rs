#[cfg(target_os = "macos")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use arktrace_contract::{
        CpuSliceQuery, DirectoryNameMatch, ThreadStateQuery, TraceFrame, TraceFrameQuery,
        TraceParserIdentity, TraceSliceQuery,
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
        process::Command,
        time::{Duration, Instant},
    };
    #[derive(Deserialize, serde::Serialize)]
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
    struct Case {
        fixture: String,
        id: String,
        view: String,
        query: TraceFrameQuery,
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
        || cases.iter().any(|c| {
            c.id.len() > 128
                || c.query.limit > 128
                || !matches!(
                    c.view.as_str(),
                    "frames" | "cpuSlices" | "threadStates" | "slices"
                )
        })
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
    let workspace = root.create_private_child("frames-no-cache")?;
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
        let selected = cases
            .iter()
            .filter(|c| c.fixture == fixture)
            .collect::<Vec<_>>();
        if selected.is_empty() {
            return Err("missing fixture".into());
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
        for (case, expected) in selected.iter().zip(oracle) {
            let q = &case.query;
            let row = match case.view.as_str() {
                "frames" => {
                    let page = session.frames(q, &budget())?;
                    let jank = page.items.iter().map(|f| serde_json::json!({"isJank":f.is_jank(),"jankTag":TraceFrame::jank_tag(f.flag)})).collect::<Vec<_>>();
                    serde_json::json!({"id":case.id,"fixture":fixture,"query":q,"page":page,"jank":jank})
                }
                "cpuSlices" => {
                    let q = CpuSliceQuery {
                        range: q.range,
                        process_key: q.process_key,
                        limit: q.limit,
                        cpu: None,
                        pid: None,
                        thread_key: None,
                        tid: None,
                    };
                    serde_json::json!({"id":case.id,"fixture":fixture,"query":q,"page":session.cpu_slices(&q,&budget())?,"agentPage":session.query_cpu_slices(&q,&budget())?})
                }
                "threadStates" => {
                    let q = ThreadStateQuery {
                        range: q.range,
                        process_key: q.process_key,
                        limit: q.limit,
                        cpu: None,
                        pid: None,
                        thread_key: None,
                        tid: None,
                        raw_state: None,
                        state: None,
                    };
                    serde_json::json!({"id":case.id,"fixture":fixture,"query":q,"page":session.thread_states(&q,&budget())?,"agentPage":session.query_thread_states(&q,&budget())?})
                }
                "slices" => {
                    let q = TraceSliceQuery {
                        range: q.range,
                        process_key: q.process_key,
                        limit: q.limit,
                        pid: None,
                        thread_key: None,
                        tid: None,
                        event_key: None,
                        name: None,
                        name_match: DirectoryNameMatch::Exact,
                        minimum_duration_ns: None,
                        depth: None,
                        includes_argument_set: false,
                    };
                    serde_json::json!({"id":case.id,"fixture":fixture,"query":q,"page":session.slices(&q,&budget())?,"agentPage":session.query_slices(&q,&budget())?})
                }
                _ => return Err("unknown view".into()),
            };
            let extra = if case.view == "frames" {
                "jank"
            } else {
                "agentPage"
            };
            for field in ["id", "page", extra] {
                if row[field] != expected[field] {
                    eprintln!(
                        "{}",
                        serde_json::json!({"case":case.id,"field":field,"rust":row,"swift":expected})
                    );
                    return Err("event parity".into());
                }
            }
            results.push(serde_json::json!({"rust":row,"swift":expected,"parity":"T0"}));
        }
        let good = selected[0].query.clone();
        let expected = session.frames(&good, &budget())?;
        for scenario in [
            "cancelled",
            "deadline",
            "database-budget",
            "invalid-limit",
            "over-limit",
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
                    q.limit = if scenario == "invalid-limit" {
                        0
                    } else {
                        20001
                    };
                    EngineFailure::Store(StoreError::InvalidQuery)
                }
            };
            let error = session.frames(&q, &b).unwrap_err();
            assert_eq!(error.stage, EngineStage::Querying);
            assert_eq!(error.failure, failure);
            assert_eq!(session.frames(&good, &budget())?, expected);
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
        sources.push(serde_json::json!({"fixture":fixture,"source":{"sha256":original.sha256,"byteCount":original.byte_count},"inspection":inspection,"rawBytesUnchanged":true,"explicitCloseRemovedReadyOwnersAndLeases":true}));
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
