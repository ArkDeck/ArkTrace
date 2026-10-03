#[cfg(all(target_os = "macos", feature = "process-fixtures"))]
mod native {
    use arktrace_contract::*;
    use arktrace_engine::*;
    use arktrace_platform::*;
    use serde_json::{Value, json};
    use std::{
        fs,
        path::{Path, PathBuf},
        thread,
        time::{Duration, Instant},
    };
    const TIMEOUT: Duration = Duration::from_secs(60);
    fn retry<T>(mut call: impl FnMut() -> Result<T, RuntimeFailure>) -> Result<T, RuntimeFailure> {
        let deadline = Instant::now() + TIMEOUT;
        loop {
            match call() {
                Err(RuntimeFailure::Busy) if Instant::now() < deadline => thread::yield_now(),
                result => return result,
            }
        }
    }
    fn wait(engine: &AsyncEngine, request: RuntimeHandle) -> RequestStatus {
        let deadline = Instant::now() + TIMEOUT;
        loop {
            let status = retry(|| engine.poll(request)).unwrap();
            if matches!(status.state, RequestState::Succeeded | RequestState::Failed) {
                return status;
            }
            assert!(Instant::now() < deadline, "request deadline");
            thread::sleep(Duration::from_millis(1));
        }
    }
    fn result(engine: &AsyncEngine, request: RuntimeHandle) -> OwnedResult {
        let status = wait(engine, request);
        assert_eq!(
            status.state,
            RequestState::Succeeded,
            "{:?}",
            status.failure
        );
        retry(|| engine.acquire_result(request)).unwrap()
    }
    fn body(result: &OwnedResult) -> Value {
        let document: Value = serde_json::from_slice(result.bytes()).unwrap();
        assert_eq!(document["formatVersion"], 1);
        document["body"].clone()
    }
    fn check_response<T: serde::Serialize>(
        owned: &OwnedResult,
        session: RuntimeHandle,
        request: RuntimeHandle,
        expected: &T,
    ) {
        #[derive(serde::Serialize)]
        #[serde(rename_all = "camelCase")]
        struct Expected<'a, T: serde::Serialize> {
            format_version: u32,
            session: RuntimeHandle,
            request: RuntimeHandle,
            body: &'a T,
        }
        let encoded = serde_json::to_vec(&Expected {
            format_version: 1,
            session,
            request,
            body: expected,
        })
        .unwrap();
        assert_eq!(owned.bytes(), encoded, "complete encoded response differs");
    }
    fn close(engine: &AsyncEngine, session: RuntimeHandle) {
        retry(|| engine.close(session)).unwrap();
        retry(|| engine.close(session)).unwrap();
        let deadline = Instant::now() + TIMEOUT;
        loop {
            let status = retry(|| engine.session_status(session)).unwrap();
            if status.resources_closed {
                assert_eq!(status.close_failure, None);
                assert_eq!(status.residue_owner, None);
                assert_eq!(status.state, SessionState::Closed);
                break;
            }
            assert!(Instant::now() < deadline);
            thread::sleep(Duration::from_millis(1));
        }
    }
    fn drain(engine: &AsyncEngine) {
        engine.start_drain();
        engine.start_drain();
        let deadline = Instant::now() + TIMEOUT;
        while engine.drain_status() != DrainStatus::Drained {
            assert!(Instant::now() < deadline);
            thread::sleep(Duration::from_millis(1));
        }
    }
    fn submit(engine: &AsyncEngine, session: RuntimeHandle, q: RepositoryRequest) -> RuntimeHandle {
        retry(|| engine.submit(session, q.clone(), TIMEOUT)).unwrap()
    }
    fn open(engine: &AsyncEngine, path: &Path, format: SourceFormat) -> OpenTicket {
        retry(|| engine.open(path.to_path_buf(), format, TIMEOUT)).unwrap()
    }
    fn release(engine: &AsyncEngine, r: RuntimeHandle) {
        retry(|| engine.release_request(r)).unwrap();
        assert_eq!(
            retry(|| engine.release_request(r)),
            Err(RuntimeFailure::InvalidHandle)
        );
    }
    fn fds() -> usize {
        fs::read_dir("/dev/fd").unwrap().count()
    }
    fn budget() -> EngineBudget {
        EngineBudget {
            maximum_source_bytes: 256 * 1024 * 1024,
            maximum_database_bytes: 256 * 1024 * 1024,
            deadline: Instant::now() + TIMEOUT,
            cancellation: CancellationToken::default(),
        }
    }
    fn io() -> IoBudget {
        IoBudget {
            maximum_bytes: 256 * 1024 * 1024,
            deadline: Instant::now() + TIMEOUT,
            cancellation: CancellationToken::default(),
        }
    }
    pub fn run() -> Result<(), Box<dyn std::error::Error>> {
        let args = std::env::args_os().skip(1).collect::<Vec<_>>();
        if args.len() != 4 {
            return Err("private root, fixtures, parser identity, helper pin required".into());
        }
        let base = PathBuf::from(&args[0]);
        let fixtures = PathBuf::from(&args[1]);
        let root = HeldDirectory::open_private(&base)?;
        let identity: TraceParserIdentity =
            serde_json::from_str(args[2].to_str().ok_or("identity")?)?;
        let helper_pin = args[3].to_str().ok_or("helper pin")?.to_owned();
        let tool_root = root.open_private_child("tools")?;
        let helper = VerifiedExecutable::verify(
            tool_root.open_file("host-process")?,
            &helper_pin,
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
            identity: identity.clone(),
        };
        let mut sources = Vec::new();
        for fixture in [
            "zlib.htrace",
            "hiprofiler_data_ability.htrace",
            "trace_small_10.systrace",
        ] {
            let path = fixtures.join(fixture);
            let source = HeldFile::open_explicit_source(&path)?;
            let original = source.facts(&io())?;
            let format = if fixture.ends_with(".systrace") {
                SourceFormat::Systrace
            } else {
                SourceFormat::Htrace
            };
            let name = format!("runtime-{}", sources.len());
            let namespace = root.create_private_child(&name)?;
            let oracle_namespace =
                root.create_private_child(&format!("oracle-{}", sources.len()))?;
            let before = fds();
            let session = open_no_cache(
                &source,
                format,
                &tools,
                &oracle_namespace,
                &budget(),
                |_| {},
            )?;
            let engine = AsyncEngine::create(RuntimeConfiguration::new(
                base.join(&name),
                base.join("tools/host-process"),
                base.join("tools/trace-streamer"),
                helper_pin.clone(),
                identity.clone(),
                CodeTrustPolicy::DevelopmentPinned,
            ))?;
            let ticket = open(&engine, &path, format);
            let opened = body(&result(&engine, ticket.request));
            assert_eq!(
                opened["inspection"],
                serde_json::to_value(session.inspection())?
            );
            release(&engine, ticket.request);
            let range =
                TraceTimeRange::query(0, session.inspection().duration_ns).map_err(|_| "range")?;
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
            let cpu = cpu_seed.items.first().map_or(0, |c| c.cpu);
            let threads = session.threads(
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
            let arktrace_viewer::RepositoryDetailQuery::NamedSlice(mut general) =
                arktrace_viewer::detail_query(
                    &TraceDensitySource::NamedSlice { thread: None },
                    range,
                    16,
                )?
            else {
                unreachable!()
            };
            general.unattributed_only = false;
            let slice_seed = session.slices(&general, &budget())?;
            let thread = slice_seed
                .items
                .iter()
                .find_map(|s| s.thread_key)
                .or_else(|| threads.items.first().map(|t| ThreadKey { itid: t.key }))
                .ok_or("real thread required")?;
            let counters =
                session.counter_series(&CounterSeriesQuery { range, limit: 16 }, &budget())?;
            let cpu_counter = counters.items.iter().find(|c| c.scope == CounterScope::Cpu);
            let process_counter = counters
                .items
                .iter()
                .find(|c| c.scope == CounterScope::Process);
            let lanes = [
                TraceDensitySource::Cpu { cpu },
                TraceDensitySource::ThreadState { thread },
                TraceDensitySource::NamedSlice {
                    thread: Some(thread),
                },
                TraceDensitySource::NamedSlice { thread: None },
                TraceDensitySource::CpuCounter {
                    filter_id: cpu_counter.map_or(0, |c| c.filter_id),
                    cpu: cpu_counter.and_then(|c| c.cpu),
                },
                TraceDensitySource::ProcessCounter {
                    filter_id: process_counter.map_or(0, |c| c.filter_id),
                    process_key: process_counter.and_then(|c| c.process_key),
                },
                TraceDensitySource::Frame { process_key: None },
            ];
            let mut responses = Vec::new();
            let mut held_results = Vec::new();
            for lane in lanes {
                let expected = session
                    .viewer_details(&lane, range, 16, &budget())
                    .map_err(|error| format!("{fixture} source {lane:?}: {error:?}"))?;
                let request = submit(
                    &engine,
                    ticket.session,
                    RepositoryRequest::ViewerDetails {
                        source: lane.clone(),
                        range,
                        limit: 16,
                    },
                );
                let owned = result(&engine, request);
                check_response(&owned, ticket.session, request, &expected);
                responses.push(json!({"source":lane,"range":range,"limit":16,"itemCount":expected.items.len(),"truncated":expected.truncated,"capabilityAvailable":expected.capability_available,"responseUtf8":std::str::from_utf8(owned.bytes())?}));
                held_results.push(owned);
                release(&engine, request);
            }
            for limit in [0, 20_001, usize::MAX] {
                assert_eq!(
                    engine.submit(
                        ticket.session,
                        RepositoryRequest::ViewerDetails {
                            source: TraceDensitySource::NamedSlice { thread: None },
                            range,
                            limit
                        },
                        TIMEOUT
                    ),
                    Err(RuntimeFailure::InvalidRequest)
                );
            }
            let invalid = EngineBudget {
                cancellation: CancellationToken::default(),
                ..budget()
            };
            invalid.cancellation.cancel();
            assert!(matches!(
                session.viewer_details(&TraceDensitySource::Cpu { cpu }, range, 16, &invalid),
                Err(EngineError {
                    failure: EngineFailure::Store(arktrace_store::StoreError::Cancelled)
                        | EngineFailure::Host(HostError::Cancelled),
                    ..
                })
            ));
            let saved = held_results
                .iter()
                .map(|r| r.bytes().to_vec())
                .collect::<Vec<_>>();
            close(&engine, ticket.session);
            retry(|| engine.release_session(ticket.session))?;
            drain(&engine);
            assert!(engine.retained_result_bytes() > 0);
            for (held, bytes) in held_results.iter().zip(&saved) {
                assert_eq!(held.bytes(), bytes);
            }
            drop(held_results);
            assert_eq!(engine.retained_result_bytes(), 0);
            assert!(
                OwnerStore::open(&namespace.open_private_child(".actors")?, &namespace)?
                    .identifiers(&io())?
                    .is_empty()
            );
            drop(engine);
            session.close()?;
            assert!(
                OwnerStore::open(
                    &oracle_namespace.open_private_child(".staging")?,
                    &oracle_namespace
                )?
                .identifiers(&io())?
                .is_empty()
            );
            let after = fds();
            assert_eq!(before, after, "descriptors for {fixture}");
            assert_eq!(source.facts(&io())?, original);
            sources.push(json!({"fixture":fixture,"fullViewerDetailParity":true,"resultSurvivesReleaseCloseDrain":true,"rawBytesUnchanged":true,"descriptorsBefore":before,"descriptorsAfter":after,"ownedScopesRemoved":true,"invalidFrontendBoundsRejected":true,"cancelledOwnerQueryRejected":true,"cpuSeedHasRealEvent":!cpu_seed.items.is_empty(),"cpuCounterSeedAvailable":cpu_counter.is_some(),"processCounterSeedAvailable":process_counter.is_some(),"inspection":opened["inspection"],"responses":responses}));
        }
        println!(
            "{}",
            serde_json::to_string_pretty(
                &json!({"sdkAcceptance":false,"persistentCacheAcceptance":false,"independentSwiftNativeParity":false,"sources":sources})
            )?
        );
        Ok(())
    }
}
#[cfg(all(target_os = "macos", feature = "process-fixtures"))]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    native::run()
}
#[cfg(not(all(target_os = "macos", feature = "process-fixtures")))]
fn main() {
    eprintln!("native macOS process-fixtures build required; no simulated PASS");
    std::process::exit(2);
}
