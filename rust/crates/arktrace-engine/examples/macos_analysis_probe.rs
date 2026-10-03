#[cfg(target_os = "macos")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use arktrace_contract::{
        CpuSliceQuery, DirectoryNameMatch, ThreadStateQuery, TraceParserIdentity, TraceSliceQuery,
        TraceThreadState,
    };
    use arktrace_engine::{
        AnalysisScope, BoundedAnalysisRequest, EngineBudget, EngineStage, ParserTools,
        SourceFormat, open_no_cache,
    };
    use arktrace_platform::{
        CancellationToken, CodeTrustPolicy, HeldDirectory, HeldFile, IoBudget, OwnerStore,
        VerifiedExecutable,
    };
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
        request: BoundedAnalysisRequest,
        scope: AnalysisScope,
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
    if input.len() > 65_536 {
        return Err("case byte budget".into());
    }
    let cases: Vec<Case> = serde_json::from_str(input)?;
    if cases.is_empty()
        || cases.len() > 32
        || cases.iter().any(|c| {
            c.id.len() > 128
                || c.request.maximum_output_rows > 128
                || [
                    c.request.maximum_cpu_slices,
                    c.request.maximum_process_slices,
                    c.request.maximum_thread_slices,
                    c.request.maximum_state_intervals,
                    c.request.maximum_scheduling_events,
                    c.request.maximum_hot_events,
                ]
                .into_iter()
                .any(|v| v > 128)
        })
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
    let workspace = root.create_private_child("analysis-no-cache")?;
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
        let selected: Vec<_> = cases.iter().filter(|c| c.fixture == fixture).collect();
        if selected.is_empty() {
            return Err("missing fixture cases".into());
        }
        for case in &selected {
            let result = session.analyze_bounded(&case.request, case.scope, &budget())?;
            let cpu_query = |limit| CpuSliceQuery {
                range: case.request.range,
                cpu: None,
                process_key: case.scope.process_key,
                pid: case.scope.pid,
                thread_key: case.scope.thread_key,
                tid: case.scope.tid,
                limit,
            };
            let cpu = session.cpu_slices(&cpu_query(case.request.maximum_cpu_slices), &budget())?;
            let processes =
                session.cpu_slices(&cpu_query(case.request.maximum_process_slices), &budget())?;
            let threads =
                session.cpu_slices(&cpu_query(case.request.maximum_thread_slices), &budget())?;
            let state_query = ThreadStateQuery {
                range: case.request.range,
                cpu: None,
                process_key: case.scope.process_key,
                pid: case.scope.pid,
                thread_key: case.scope.thread_key,
                tid: case.scope.tid,
                raw_state: None,
                state: None,
                limit: case.request.maximum_state_intervals,
            };
            let states = session.thread_states(&state_query, &budget())?;
            let runnable = session.thread_states(
                &ThreadStateQuery {
                    state: Some(TraceThreadState::Runnable),
                    limit: case.request.maximum_scheduling_events,
                    ..state_query
                },
                &budget(),
            )?;
            let hot_cpu =
                session.cpu_slices(&cpu_query(case.request.maximum_hot_events), &budget())?;
            let hot_named = session.slices(
                &TraceSliceQuery {
                    range: case.request.range,
                    event_key: None,
                    process_key: case.scope.process_key,
                    pid: case.scope.pid,
                    thread_key: case.scope.thread_key,
                    tid: case.scope.tid,
                    name: None,
                    name_match: DirectoryNameMatch::Exact,
                    minimum_duration_ns: Some(case.request.minimum_long_slice_duration_ns),
                    depth: None,
                    unattributed_only: false,
                    includes_argument_set: false,
                    limit: case.request.maximum_hot_events,
                },
                &budget(),
            )?;
            assert_eq!(
                result
                    .cpu_utilization
                    .iter()
                    .map(|r| r.slice_count)
                    .sum::<usize>(),
                cpu.items.len()
            );
            assert_eq!(result.sections.cpu_utilization.sampled, cpu.truncated);
            assert_eq!(result.sections.top_processes.sampled, processes.truncated);
            assert_eq!(result.sections.top_threads.sampled, threads.truncated);
            assert_eq!(
                result
                    .thread_state_distribution
                    .iter()
                    .map(|r| r.interval_count)
                    .sum::<usize>(),
                states.items.len()
            );
            assert_eq!(
                result.sections.thread_state_distribution.sampled,
                states.truncated
            );
            assert!(!result.scheduling_latency.supported);
            if session.inspection().capabilities.cpu_scheduling
                && session.inspection().capabilities.thread_states
            {
                assert_eq!(
                    result.scheduling_latency.unsupported_reason,
                    Some(arktrace_analysis::SchedulingUnsupportedReason::RunnableSemanticsUnproven)
                );
            }
            assert_eq!(
                result.sections.hot_intervals.supported,
                hot_cpu.capability_available || hot_named.capability_available
            );
            assert_eq!(
                result.sections.hot_intervals.sampled,
                hot_cpu.truncated || hot_named.truncated
            );
            assert!(result.hot_intervals_unsupported_reason.is_none());
            assert!(hot_named.items.iter().all(|s| s.arg_set_id.is_none()
                && s.range.duration_ns() >= case.request.minimum_long_slice_duration_ns));
            results.push(serde_json::json!({"id":case.id,"fixture":fixture,"request":case.request,"scope":case.scope,"result":result,"rawPages":{"cpu":cpu,"processes":processes,"threads":threads,"states":states,"runnable":runnable,"hotCpu":hot_cpu,"hotNamed":hot_named}}));
        }
        let good = selected[0];
        let expected = session.analyze_bounded(&good.request, good.scope, &budget())?;
        for scenario in [
            "cancelled",
            "deadline",
            "zero-input-budget",
            "zero-hot-input-budget",
            "negative-named-duration",
            "outside-trace",
            "identity-zero",
            "identity-property-conflict",
            "database-budget",
        ] {
            let mut request = good.request.clone();
            let mut scope = good.scope;
            let mut b = budget();
            match scenario {
                "cancelled" => b.cancellation.cancel(),
                "deadline" => b.deadline = Instant::now() - Duration::from_millis(1),
                "zero-input-budget" => request.maximum_cpu_slices = 0,
                "zero-hot-input-budget" => request.maximum_hot_events = 0,
                "negative-named-duration" => request.minimum_long_slice_duration_ns = -1,
                "outside-trace" => {
                    request.range = arktrace_contract::TraceTimeRange::query(
                        0,
                        session.inspection().duration_ns + 1,
                    )
                    .map_err(|_| "invalid range")?
                }
                "identity-zero" => scope.thread_key = Some(0),
                "identity-property-conflict" => {
                    scope.thread_key = Some(1);
                    scope.tid = Some(1);
                }
                _ => b.maximum_database_bytes = 1,
            }
            let started = Instant::now();
            let error = session.analyze_bounded(&request, scope, &b).unwrap_err();
            let public = error.public_error();
            if matches!(scenario, "cancelled" | "deadline") {
                assert_eq!(error.stage, EngineStage::Analyzing);
                assert_eq!(public.stage(), arktrace_contract::Stage::Analyzing);
            }
            assert!(started.elapsed() < Duration::from_secs(5));
            assert_eq!(
                session.analyze_bounded(&good.request, good.scope, &budget())?,
                expected
            );
            negatives.push(serde_json::json!({"fixture":fixture,"scenario":scenario,"error":error,"publicError":public,"nextRequestUnchanged":true}));
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
