#[cfg(target_os = "macos")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use arktrace_contract::{
        DirectoryNameMatch, ThreadQuery, TraceParserIdentity, TraceRepositoryEventBatch,
        TraceTimeRange,
    };
    use arktrace_engine::{
        EngineBudget, EngineFailure, ParserTools, ReadPoolLimits, SourceFormat, open_no_cache,
    };
    use arktrace_platform::{
        CancellationToken, CodeTrustPolicy, HeldDirectory, HeldFile, IoBudget, OwnerStore,
        VerifiedExecutable,
    };
    use arktrace_store::StoreError;
    use serde::Serialize;
    use serde_json::{Value, json};
    use std::{
        fs,
        path::Path,
        process::Command,
        time::{Duration, Instant},
    };
    #[derive(Clone, Serialize)]
    struct Case {
        id: String,
        batch: TraceRepositoryEventBatch,
    }
    fn mixed(range: TraceTimeRange, limit: usize) -> TraceRepositoryEventBatch {
        serde_json::from_value(json!({
            "cpuSlices":[{"range":range,"limit":limit}],
            "threadStates":[{"range":range,"limit":limit}],
            "slices":[{"range":range,"limit":limit,"nameMatch":"exact","includesArgumentSet":false}],
            "counters":[{"range":range,"limit":limit,"nameMatch":"exact"}],
            "counterSeries":[{"range":range,"limit":limit}],
            "densities":[{"range":range,"bucketCount":32,"source":{"cpu":{"_0":0}}}],
            "threads":[{"limit":limit,"nameMatch":"exact"}]
        })).unwrap()
    }
    fn fds() -> usize {
        fs::read_dir("/dev/fd").unwrap().count()
    }
    let args = std::env::args_os().skip(1).collect::<Vec<_>>();
    if args.len() != 5 {
        return Err(
            "private root, fixtures, parser identity, helper pin and Swift oracle required".into(),
        );
    }
    let root = HeldDirectory::open_private(Path::new(&args[0]))?;
    let identity: TraceParserIdentity = serde_json::from_str(args[2].to_str().ok_or("identity")?)?;
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
    let workspace = root.create_private_child("batch-no-cache")?;
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
        let source = HeldFile::open_explicit_source(&Path::new(&args[1]).join(fixture))?;
        let original = source.facts(&io())?;
        let format = if fixture.ends_with(".systrace") {
            SourceFormat::Systrace
        } else {
            SourceFormat::Htrace
        };
        let session = open_no_cache(&source, format, &tools, &workspace, &budget(), |_| {})?;
        let range =
            TraceTimeRange::query(0, session.inspection().duration_ns).map_err(|_| "range")?;
        let seed = session.threads(
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
        let mut batches = vec![
            mixed(range, 1),
            mixed(range, 16),
            mixed(
                TraceTimeRange::query(range.end_ns() - 1, range.end_ns()).map_err(|_| "narrow")?,
                16,
            ),
        ];
        let mut full = mixed(range, 16);
        full.cpu_slices = vec![full.cpu_slices[0].clone(); 8];
        full.thread_states = vec![full.thread_states[0].clone(); 8];
        full.slices = vec![full.slices[0].clone(); 4];
        full.counters = vec![full.counters[0].clone(); 2];
        full.counter_series = vec![full.counter_series[0].clone(); 2];
        full.densities = vec![full.densities[0].clone(); 4];
        full.threads = vec![full.threads[0].clone(); 4];
        assert_eq!(full.query_count(), 32);
        batches.push(full);
        let mut absent = mixed(range, 1);
        absent.cpu_slices[0].cpu = Some(i64::MAX);
        absent.thread_states[0].raw_state = Some("_absent-state_".into());
        absent.slices[0].name = Some("_absent-slice_".into());
        absent.counters[0].name = Some("_absent-counter_".into());
        absent.threads[0].name = Some("_absent-thread_".into());
        batches.push(absent);
        let mut scoped = mixed(range, 16);
        if let Some(thread) = seed.items.first() {
            scoped.cpu_slices[0].thread_key = Some(thread.key);
            scoped.thread_states[0].thread_key = Some(thread.key);
            scoped.slices[0].thread_key = Some(thread.key);
            scoped.threads[0].thread_key = Some(thread.key);
        }
        batches.push(scoped);
        let mut order = mixed(range, 16);
        order.cpu_slices = (0..4)
            .rev()
            .map(|cpu| {
                let mut q = order.cpu_slices[0].clone();
                q.cpu = Some(cpu);
                q
            })
            .collect();
        order.thread_states = vec![order.thread_states[0].clone(); 3];
        order.threads = vec![order.threads[0].clone(); 2];
        batches.push(order);
        // Density-only mixed availability is still a valid bounded batch.
        let empty = TraceRepositoryEventBatch {
            densities: mixed(range, 1).densities,
            ..Default::default()
        };
        batches.push(empty);
        let positive_count = batches.len();
        batches.push(TraceRepositoryEventBatch::default());
        let mut over = mixed(range, 1);
        over.cpu_slices = vec![over.cpu_slices[0].clone(); 27];
        assert_eq!(over.query_count(), 33);
        batches.push(over);
        let mut invalid = mixed(range, 1);
        invalid.counter_series[0].limit = 0;
        batches.push(invalid);
        let mut invalid = mixed(range, 1);
        invalid.densities[0].bucket_count = 0;
        batches.push(invalid);
        let cases = batches
            .into_iter()
            .enumerate()
            .map(|(i, batch)| Case {
                id: format!("{fixture}/batch-{i}"),
                batch,
            })
            .collect::<Vec<_>>();
        let ready = fs::read_dir(workspace.path().join(".ready"))?
            .next()
            .ok_or("Ready absent")??
            .path()
            .join("trace.db");
        let context = serde_json::to_string(session.metadata())?;
        let input = serde_json::to_string(&cases)?;
        assert!(input.len() < 65536);
        let swift = Command::new(&args[4])
            .args([
                ready.as_os_str(),
                std::ffi::OsStr::new(&context),
                std::ffi::OsStr::new(&input),
            ])
            .output()?;
        if !swift.status.success() {
            return Err(format!(
                "Swift batch failed: {}",
                String::from_utf8_lossy(&swift.stderr)
            )
            .into());
        }
        assert!(swift.stderr.is_empty() && swift.stdout.len() <= 8 * 1024 * 1024);
        let oracle: Vec<Value> = serde_json::from_slice(&swift.stdout)?;
        assert_eq!(oracle.len(), cases.len());
        let before_fds = fds();
        let mut peak = 0;
        let mut queries = 0;
        for (index, (case, expected)) in cases.iter().zip(oracle).enumerate() {
            let actual = session.event_batch(&case.batch, &budget(), ReadPoolLimits::default());
            let (row, statistics) = match actual {
                Ok(result) => {
                    assert!(index < positive_count);
                    assert_eq!(
                        result.statistics.workers_opened,
                        result.statistics.connections_closed
                    );
                    assert!(
                        result.statistics.workers_opened <= 3
                            && result.statistics.peak_active_queries <= 3
                    );
                    assert_eq!(
                        result.statistics.completed_queries,
                        case.batch.query_count()
                    );
                    let serial = session
                        .event_batch(
                            &case.batch,
                            &budget(),
                            ReadPoolLimits {
                                maximum_workers: 1,
                                ..Default::default()
                            },
                        )
                        .map_err(|error| format!("{} serial pool: {error:?}", case.id))?;
                    assert_eq!(result.result, serial.result);
                    peak = peak.max(result.statistics.peak_active_queries);
                    queries += case.batch.query_count();
                    (
                        json!({"id":case.id,"result":result.result}),
                        Some(result.statistics),
                    )
                }
                Err(error) => {
                    if index < positive_count {
                        return Err(format!("{} parallel pool: {error:?}", case.id).into());
                    }
                    let error = error.public_error();
                    let public = serde_json::to_value(&error)?;
                    (
                        json!({"id":case.id,"error":{"code":public["code"],"stage":public["stage"],"details":public["details"]}}),
                        None,
                    )
                }
            };
            if row != expected {
                eprintln!("{}", json!({"case":case.id,"rust":row,"swift":expected}));
                return Err("batch parity".into());
            }
            assert_eq!(
                fds(),
                before_fds,
                "all request-owned connections must be drained"
            );
            results.push(json!({"fixture":fixture,"batch":case.batch,"rust":row,"swift":expected,"statistics":statistics,"parity":"T0","descriptorsUnchanged":true}));
        }
        let good = &cases[1].batch;
        let baseline = session
            .event_batch(good, &budget(), ReadPoolLimits::default())
            .map_err(|error| format!("{fixture} negative baseline: {error:?}"))?
            .result;
        for scenario in [
            "cancelled",
            "deadline",
            "database-budget",
            "decoded-budget",
            "worker-zero",
            "worker-over",
            "decoded-over",
        ] {
            let mut request = budget();
            let mut limits = ReadPoolLimits::default();
            match scenario {
                "cancelled" => request.cancellation.cancel(),
                "deadline" => request.deadline = Instant::now() - Duration::from_millis(1),
                "database-budget" => request.maximum_database_bytes = 1,
                "decoded-budget" => limits.maximum_decoded_bytes = 1,
                "worker-zero" => limits.maximum_workers = 0,
                "worker-over" => limits.maximum_workers = 4,
                "decoded-over" => limits.maximum_decoded_bytes = 256 * 1024 * 1024 + 1,
                _ => unreachable!(),
            }
            let error = session.event_batch(good, &request, limits).unwrap_err();
            if scenario == "decoded-budget" {
                assert_eq!(
                    error.failure,
                    EngineFailure::Store(StoreError::DecodedBudgetExceeded)
                );
            }
            assert_eq!(
                session
                    .event_batch(good, &budget(), ReadPoolLimits::default())
                    .map_err(|error| format!("{fixture} after {scenario}: {error:?}"))?
                    .result,
                baseline
            );
            assert_eq!(fds(), before_fds);
            negatives.push(json!({"fixture":fixture,"scenario":scenario,"error":error,
                "publicError":error.public_error(),"nextRequestUnchanged":true,"descriptorsUnchanged":true}));
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
        sources.push(json!({"fixture":fixture,"source":{"sha256":original.sha256,"byteCount":original.byte_count},
            "inspection":inspection,"seedThreads":seed,"positiveBatches":positive_count,"typedQueries":queries,
            "peakActiveQueries":peak,"descriptorsBeforeAndAfter":before_fds,"rawBytesUnchanged":true,
            "explicitCloseRemovedReadyOwnersAndLeases":true}));
    }
    println!(
        "{}",
        json!({"results":results,"negativeCases":negatives,"sources":sources,
        "developmentTrustOnly":true,"sdkOrAppAcceptance":false})
    );
    Ok(())
}
#[cfg(not(target_os = "macos"))]
fn main() {
    panic!("native macOS required; no simulated PASS")
}
