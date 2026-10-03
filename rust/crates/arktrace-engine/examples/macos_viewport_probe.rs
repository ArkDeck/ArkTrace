#[cfg(all(target_os = "macos", feature = "process-fixtures"))]
mod native {
    use arktrace_contract::*;
    use arktrace_engine::*;
    use arktrace_platform::*;
    use arktrace_viewer::*;
    use serde_json::{Value, json};
    use std::{
        fs,
        path::{Path, PathBuf},
        process::Command,
        sync::{
            Arc, Condvar, Mutex,
            atomic::{AtomicBool, Ordering},
        },
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
    fn check_encoded_response(
        owned: &OwnedResult,
        session: RuntimeHandle,
        request: RuntimeHandle,
        body: &[u8],
    ) {
        let mut expected = format!(
            r#"{{"formatVersion":1,"session":{},"request":{},"body":"#,
            serde_json::to_string(&session).unwrap(),
            serde_json::to_string(&request).unwrap()
        )
        .into_bytes();
        expected.extend_from_slice(body);
        expected.push(b'}');
        assert_eq!(
            owned.bytes(),
            expected,
            "complete encoded viewport response differs"
        );
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
    struct Gate {
        boundary: WorkerBoundary,
        armed: AtomicBool,
        entered: AtomicBool,
        released: Mutex<bool>,
        wake: Condvar,
        panic: AtomicBool,
    }
    impl Gate {
        fn new(boundary: WorkerBoundary) -> Arc<Self> {
            Arc::new(Self {
                boundary,
                armed: AtomicBool::new(false),
                entered: AtomicBool::new(false),
                released: Mutex::new(false),
                wake: Condvar::new(),
                panic: AtomicBool::new(false),
            })
        }
        fn arm(&self, panic: bool) {
            self.panic.store(panic, Ordering::Release);
            self.armed.store(true, Ordering::Release);
        }
        fn observe(&self, boundary: WorkerBoundary) {
            if boundary != self.boundary || !self.armed.swap(false, Ordering::AcqRel) {
                return;
            }
            self.entered.store(true, Ordering::Release);
            let mut released = self.released.lock().unwrap();
            while !*released {
                released = self.wake.wait(released).unwrap();
            }
            if self.panic.load(Ordering::Acquire) {
                panic!("controlled runtime boundary failure");
            }
        }
        fn wait(&self) {
            let deadline = Instant::now() + TIMEOUT;
            while !self.entered.load(Ordering::Acquire) {
                assert!(Instant::now() < deadline);
                thread::sleep(Duration::from_millis(1));
            }
        }
        fn unblock(&self) {
            *self.released.lock().unwrap() = true;
            self.wake.notify_all();
        }
    }
    fn compare(actual: &Value, expected: &Value, path: &str) {
        match (actual, expected) {
            (Value::Object(a), Value::Object(b)) => {
                assert_eq!(
                    a.keys().collect::<Vec<_>>(),
                    b.keys().collect::<Vec<_>>(),
                    "{path}: fields"
                );
                for (key, value) in a {
                    compare(value, &b[key], &format!("{path}.{key}"));
                }
            }
            (Value::Array(a), Value::Array(b)) => {
                assert_eq!(a.len(), b.len(), "{path}: items");
                for (i, (a, b)) in a.iter().zip(b).enumerate() {
                    compare(a, b, &format!("{path}[{i}]"));
                }
            }
            (Value::Number(a), Value::Number(b)) => {
                if let (Some(a), Some(b)) = (a.as_i64(), b.as_i64()) {
                    assert_eq!(a, b, "{path}: exact integer");
                } else if let (Some(a), Some(b)) = (a.as_u64(), b.as_u64()) {
                    assert_eq!(a, b, "{path}: exact unsigned");
                } else {
                    assert_eq!(
                        a.as_f64().unwrap().to_bits(),
                        b.as_f64().unwrap().to_bits(),
                        "{path}: binary64 {a} != {b}"
                    );
                }
            }
            _ => assert_eq!(actual, expected, "{path}"),
        }
    }
    fn viewport_request(
        lanes: &[TraceDensitySource],
        range: TraceTimeRange,
        generation: u64,
        preference: DetailPreference,
        limit: usize,
        offset: f64,
    ) -> ViewportRequest {
        ViewportRequest {
            viewport: Viewport::new(range, 200.0, 600.0, offset, generation).unwrap(),
            tracks: lanes
                .iter()
                .map(|source| TrackDescriptor {
                    source: source.clone(),
                    is_collapsed: false,
                    shows_nested_depth: true,
                })
                .collect(),
            pixel_width: 400,
            generation,
            preference,
            maximum_primitives: Some(limit),
            focused_event_key: None,
        }
    }
    pub fn run() -> Result<(), Box<dyn std::error::Error>> {
        let args = std::env::args_os().skip(1).collect::<Vec<_>>();
        if args.len() != 5 {
            return Err(
                "private root, fixtures, parser identity, helper pin and Swift oracle required"
                    .into(),
            );
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
            let gate = Gate::new(WorkerBoundary::Querying);
            let observe_gate = gate.clone();
            let engine = AsyncEngine::create(
                RuntimeConfiguration::new(
                    base.join(&name),
                    base.join("tools/host-process"),
                    base.join("tools/trace-streamer"),
                    helper_pin.clone(),
                    identity.clone(),
                    CodeTrustPolicy::DevelopmentPinned,
                )
                .observe_worker_for_fixture(Arc::new(move |boundary| {
                    observe_gate.observe(boundary)
                })),
            )?;
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
            let mut vectors = Vec::new();
            for (i, (name, preference, limit)) in [
                ("detail", DetailPreference::Detail, 112),
                ("automatic", DetailPreference::Automatic, 112),
                ("density", DetailPreference::Density, 112),
                ("density-warm", DetailPreference::Density, 112),
                ("tiny-global", DetailPreference::Automatic, 2),
                ("focused", DetailPreference::Detail, 14),
                ("offscreen", DetailPreference::Detail, 112),
                ("collapsed", DetailPreference::Density, 112),
                ("narrow", DetailPreference::Density, 112),
                ("density-wide", DetailPreference::Density, 700),
                ("flattened", DetailPreference::Detail, 112),
            ]
            .into_iter()
            .enumerate()
            {
                let mut request = viewport_request(
                    &lanes,
                    range,
                    (i + 1) as u64,
                    preference,
                    limit,
                    if name == "offscreen" { 10_000.0 } else { 0.0 },
                );
                if name == "focused" {
                    request.focused_event_key = slice_seed.items.last().map(|s| s.key);
                }
                if name == "collapsed" {
                    for t in &mut request.tracks {
                        t.is_collapsed = true;
                    }
                }
                if name == "narrow" {
                    request.viewport = Viewport::new(
                        TraceTimeRange::query(
                            range.duration_ns() / 3,
                            2 * (range.duration_ns() / 3),
                        )
                        .map_err(|_| "narrow range")?,
                        200.0,
                        600.0,
                        0.0,
                        request.generation,
                    )?;
                }
                if name == "density-wide" {
                    request.pixel_width = 1600;
                }
                if name == "flattened" {
                    for t in &mut request.tracks {
                        t.shows_nested_depth = false;
                    }
                }
                vectors.push(json!({"name":name,"request":request,"backingScale":2.0}));
            }
            for (i, lane) in lanes.iter().enumerate() {
                for (name, time_ns) in [("start", 0), ("middle", range.duration_ns() / 2)] {
                    vectors.push(json!({"name":format!("resolve-{i}-{name}"),"resolution":DensityResolutionRequest{source:lane.clone(),bucket:range,time_ns},"backingScale":2.0}));
                }
            }
            let ready = fs::read_dir(
                base.join(format!("oracle-{}", sources.len()))
                    .join(".ready"),
            )?
            .next()
            .ok_or("Ready absent")??
            .path()
            .join("trace.db");
            let swift = Command::new(&args[4])
                .args([
                    ready.as_os_str(),
                    args[2].as_os_str(),
                    std::ffi::OsStr::new(&serde_json::to_string(
                        &json!({"sha256":original.sha256,"byteCount":original.byte_count}),
                    )?),
                    std::ffi::OsStr::new(&serde_json::to_string(&vectors)?),
                ])
                .output()?;
            assert!(
                swift.status.success(),
                "Swift oracle: {}",
                String::from_utf8_lossy(&swift.stderr)
            );
            assert!(swift.stderr.is_empty());
            fs::write(
                base.join(format!("swift-{}.json", sources.len())),
                &swift.stdout,
            )?;
            fs::write(
                base.join(format!("inputs-{}.json", sources.len())),
                serde_json::to_vec_pretty(&vectors)?,
            )?;
            let swift_records: Vec<Value> = serde_json::from_slice(&swift.stdout)?;
            assert_eq!(swift_records.len(), vectors.len());
            let mut responses = Vec::new();
            let mut held_results = Vec::new();
            let mut completed_viewport = None;
            for (vector, swift) in vectors.iter().zip(&swift_records) {
                assert_eq!(vector["name"], swift["name"]);
                let (expected, query) = if !vector["request"].is_null() {
                    let request: ViewportRequest =
                        serde_json::from_value(vector["request"].clone())?;
                    let snapshot = session.viewer_viewport(&request, 2.0, &budget())?;
                    let projected = serde_json::to_value(snapshot.as_ref().map(|s| &s.snapshot))?;
                    compare(
                        &projected,
                        &swift["projected"],
                        &format!("{fixture}/{}", vector["name"]),
                    );
                    (
                        serde_json::to_vec(&snapshot)?,
                        RepositoryRequest::ViewerViewport {
                            request: Box::new(request),
                            backing_scale: 2.0,
                        },
                    )
                } else {
                    let resolution: DensityResolutionRequest =
                        serde_json::from_value(vector["resolution"].clone())?;
                    let selected = session.viewer_resolve_density(&resolution, &budget())?;
                    let identity=selected.as_ref().map(|d|json!({"eventKey":d.event_key,"range":d.range,"isOpenEnded":d.is_open_ended})).unwrap_or(Value::Null);
                    compare(
                        &identity,
                        &swift["selected"],
                        &format!("{fixture}/{}", vector["name"]),
                    );
                    (
                        serde_json::to_vec(&selected)?,
                        RepositoryRequest::ViewerResolveDensity(resolution),
                    )
                };
                let request = submit(&engine, ticket.session, query);
                let owned = result(&engine, request);
                check_encoded_response(&owned, ticket.session, request, &expected);
                responses.push(json!({"input":vector,"swift":swift,"responseUtf8":std::str::from_utf8(owned.bytes())?,"fullRustBlockingAsyncBytesEqual":true,"swiftSemanticProjectionEqual":true}));
                held_results.push(owned);
                if vector["name"] == "flattened" {
                    completed_viewport = Some(request);
                } else {
                    release(&engine, request);
                }
            }
            gate.arm(false);
            let old = submit(
                &engine,
                ticket.session,
                RepositoryRequest::ViewerViewport {
                    request: Box::new(viewport_request(
                        &lanes,
                        range,
                        12,
                        DetailPreference::Density,
                        112,
                        0.0,
                    )),
                    backing_scale: 2.0,
                },
            );
            gate.wait();
            let generic = submit(
                &engine,
                ticket.session,
                RepositoryRequest::Density(TraceDensityQuery {
                    source: lanes[0].clone(),
                    range,
                    bucket_count: 1,
                }),
            );
            let latest_request =
                viewport_request(&lanes, range, 13, DetailPreference::Density, 112, 0.0);
            let latest = submit(
                &engine,
                ticket.session,
                RepositoryRequest::ViewerViewport {
                    request: Box::new(latest_request.clone()),
                    backing_scale: 2.0,
                },
            );
            assert_eq!(
                retry(|| engine.acquire_result(completed_viewport.unwrap())).err(),
                Some(RuntimeFailure::Cancelled)
            );
            release(&engine, completed_viewport.unwrap());
            gate.unblock();
            assert_eq!(wait(&engine, old).failure, Some(RuntimeFailure::Cancelled));
            let expected = session.viewer_viewport(&latest_request, 2.0, &budget())?;
            check_response(&result(&engine, latest), ticket.session, latest, &expected);
            check_response(
                &result(&engine, generic),
                ticket.session,
                generic,
                &session.density(
                    &TraceDensityQuery {
                        source: lanes[0].clone(),
                        range,
                        bucket_count: 1,
                    },
                    &budget(),
                )?,
            );
            assert_eq!(
                retry(|| engine.submit(
                    ticket.session,
                    RepositoryRequest::ViewerViewport {
                        request: Box::new(viewport_request(
                            &lanes,
                            range,
                            12,
                            DetailPreference::Density,
                            112,
                            0.0
                        )),
                        backing_scale: 2.0
                    },
                    TIMEOUT
                )),
                Err(RuntimeFailure::Cancelled)
            );
            for r in [old, generic, latest] {
                release(&engine, r);
            }
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
            assert_eq!(
                fs::read_dir(
                    base.join(format!("oracle-{}", sources.len()))
                        .join(".ready")
                )?
                .count(),
                0
            );
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
            sources.push(json!({"fixture":fixture,"fullViewportBlockingAsyncParity":true,"independentSwiftNativeProjectionParity":true,"gatedLatestGenerationWins":true,"genericQuerySurvivesSupersession":true,"staleCompletedHandleRejected":true,"resultSurvivesReleaseCloseDrain":true,"rawBytesUnchanged":true,"descriptorsBefore":before,"descriptorsAfter":after,"ownedScopesRemoved":true,"cpuSeedHasRealEvent":!cpu_seed.items.is_empty(),"cpuCounterSeedAvailable":cpu_counter.is_some(),"processCounterSeedAvailable":process_counter.is_some(),"inspection":opened["inspection"],"swiftResponseUtf8":std::str::from_utf8(&swift.stdout)?,"responses":responses}));
        }
        println!(
            "{}",
            serde_json::to_string_pretty(
                &json!({"sdkAcceptance":false,"persistentCacheAcceptance":false,"independentSwiftNativeProjectionParity":true,"sources":sources})
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
