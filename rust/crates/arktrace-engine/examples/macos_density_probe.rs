#[cfg(target_os = "macos")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use arktrace_contract::{
        CounterScope, CounterSeriesQuery, CpuSliceQuery, DirectoryNameMatch, ThreadQuery,
        TraceDensityQuery, TraceDensitySource, TraceParserIdentity, TraceSliceQuery,
        TraceTimeRange,
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
    #[derive(Clone, Deserialize, serde::Serialize)]
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
    struct Case {
        fixture: String,
        id: String,
        query: TraceDensityQuery,
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
    let workspace = root.create_private_child("density-no-cache")?;
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
        let range = TraceTimeRange::query(0, session.inspection().duration_ns)
            .map_err(|_| "trace duration")?;
        let mut selected = cases
            .iter()
            .filter(|c| c.fixture == fixture)
            .cloned()
            .collect::<Vec<_>>();
        for case in &mut selected {
            case.query.range = range;
        }
        let cpu_seed = session.cpu_slices(
            &CpuSliceQuery {
                range,
                cpu: None,
                process_key: None,
                pid: None,
                thread_key: None,
                tid: None,
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
                range,
                event_key: None,
                process_key: None,
                pid: None,
                thread_key: None,
                tid: None,
                name: None,
                name_match: DirectoryNameMatch::Exact,
                minimum_duration_ns: None,
                depth: None,
                unattributed_only: false,
                includes_argument_set: false,
                limit: 16,
            },
            &budget(),
        )?;
        let counter_seed =
            session.counter_series(&CounterSeriesQuery { range, limit: 16 }, &budget())?;
        let mut seed_sources = Vec::new();
        for cpu in cpu_seed.items.iter().take(2).map(|v| v.cpu) {
            let source = TraceDensitySource::Cpu { cpu };
            if !seed_sources.contains(&source) {
                seed_sources.push(source);
            }
        }
        for thread in thread_seed.items.iter().take(2) {
            seed_sources.push(TraceDensitySource::ThreadState {
                thread: arktrace_contract::ThreadKey { itid: thread.key },
            });
        }
        for slice in slice_seed.items.iter().take(2) {
            let source = TraceDensitySource::NamedSlice {
                thread: slice.thread_key,
            };
            if !seed_sources.contains(&source) {
                seed_sources.push(source);
            }
        }
        for counter in counter_seed.items.iter().take(2) {
            seed_sources.push(match counter.scope {
                CounterScope::Cpu => TraceDensitySource::CpuCounter {
                    filter_id: counter.filter_id,
                    cpu: counter.cpu,
                },
                CounterScope::Process => TraceDensitySource::ProcessCounter {
                    filter_id: counter.filter_id,
                    process_key: counter.process_key,
                },
            });
        }
        for (i, source) in seed_sources.into_iter().enumerate() {
            for bucket_count in [1, 32] {
                selected.push(Case {
                    fixture: fixture.into(),
                    id: format!("{fixture}/density/seed-{i}-{bucket_count}"),
                    query: TraceDensityQuery {
                        range,
                        source: source.clone(),
                        bucket_count,
                    },
                });
            }
        }
        if selected.is_empty() || selected.len() > 64 {
            return Err("source case budget".into());
        }
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
        if swift.stdout.len() > 8 * 1024 * 1024 || !swift.stderr.is_empty() {
            return Err("Swift output budget".into());
        }
        let oracle: Vec<serde_json::Value> = serde_json::from_slice(&swift.stdout)?;
        if oracle.len() != selected.len() {
            return Err("Swift case budget".into());
        }
        let mut positive_count = 0;
        for (case, expected) in selected.iter().zip(oracle) {
            let result = session.density(&case.query, &budget())?;
            positive_count += usize::from(!result.buckets.is_empty());
            let row = serde_json::json!({"id":case.id,"source":case.query.source,"result":result});
            if row != expected {
                eprintln!(
                    "{}",
                    serde_json::json!({"case":case.id,"rust":row,"swift":expected})
                );
                return Err("density parity".into());
            }
            results.push(serde_json::json!({"fixture":fixture,"query":case.query,"rust":row,"swift":expected,"parity":"T0"}));
        }
        let good = selected[0].query.clone();
        let expected = session.density(&good, &budget())?;
        for scenario in [
            "cancelled",
            "deadline",
            "database-budget",
            "zero-buckets",
            "over-buckets",
            "instant-range",
            "past-trace",
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
                        "zero-buckets" => q.bucket_count = 0,
                        "over-buckets" => q.bucket_count = 40001,
                        "instant-range" => {
                            q.range = TraceTimeRange::event(0, 0).map_err(|_| "instant")?
                        }
                        "past-trace" => {
                            q.range =
                                TraceTimeRange::query(0, range.end_ns() + 1).map_err(|_| "range")?
                        }
                        _ => return Err("scenario".into()),
                    };
                    EngineFailure::Store(StoreError::InvalidQuery)
                }
            };
            let error = session.density(&q, &b).unwrap_err();
            assert_eq!(error.stage, EngineStage::Querying);
            assert_eq!(error.failure, failure);
            assert_eq!(session.density(&good, &budget())?, expected);
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
        sources.push(serde_json::json!({"fixture":fixture,"source":{"sha256":original.sha256,"byteCount":original.byte_count},"inspection":inspection,"boundedSeedPages":{"cpu":cpu_seed,"threads":thread_seed,"slices":slice_seed,"counterSeries":counter_seed},"positiveDensities":positive_count,"rawBytesUnchanged":true,"explicitCloseRemovedReadyOwnersAndLeases":true}));
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
