#[cfg(all(target_os = "macos", feature = "process-fixtures"))]
mod native {
    use arktrace_contract::*;
    use arktrace_engine::*;
    use arktrace_platform::*;
    use serde_json::{Value, json};
    use std::{
        fs,
        path::{Path, PathBuf},
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
    fn processes() -> RepositoryRequest {
        RepositoryRequest::Processes(ProcessQuery {
            process_key: None,
            pid: None,
            name: None,
            name_match: DirectoryNameMatch::Exact,
            limit: 16,
        })
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
    fn batch(range: TraceTimeRange) -> TraceRepositoryEventBatch {
        serde_json::from_value(json!({
        "cpuSlices":[{"range":range,"limit":16}],"threadStates":[{"range":range,"limit":16}],
        "slices":[{"range":range,"limit":16,"nameMatch":"exact","includesArgumentSet":false}],
        "counters":[{"range":range,"limit":16,"nameMatch":"exact"}],"counterSeries":[{"range":range,"limit":16}],
        "densities":[{"range":range,"bucketCount":32,"source":{"cpu":{"_0":0}}}],"threads":[{"limit":16,"nameMatch":"exact"}]
    })).unwrap()
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
    fn clean(namespace: &HeldDirectory) -> bool {
        let actors = namespace.open_private_child(".actors").unwrap();
        let owners = OwnerStore::open(&actors, namespace).unwrap();
        owners.identifiers(&io()).unwrap().is_empty()
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
        let config = |name: &str| {
            RuntimeConfiguration::new(
                base.join(name),
                base.join("tools/host-process"),
                base.join("tools/trace-streamer"),
                helper_pin.clone(),
                identity.clone(),
                CodeTrustPolicy::DevelopmentPinned,
            )
        };
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
        let mut checks = Vec::new();
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
            let oracle_name = format!("oracle-{}", sources.len());
            let oracle_namespace = root.create_private_child(&oracle_name)?;
            let before = fds();
            let session = open_no_cache(
                &source,
                format,
                &tools,
                &oracle_namespace,
                &budget(),
                |_| {},
            )?;
            let engine = AsyncEngine::create(config(&name))?;
            let a = open(&engine, &path, format);
            let b = open(&engine, &path, format);
            assert_ne!(a.session, b.session);
            let opened = body(&result(&engine, a.request));
            result(&engine, b.request);
            assert_eq!(
                opened["inspection"],
                serde_json::to_value(session.inspection())?
            );
            let range =
                TraceTimeRange::query(0, session.inspection().duration_ns).map_err(|_| "range")?;
            let bq = batch(range);
            let expected = session
                .event_batch(&bq, &budget(), ReadPoolLimits::default())?
                .result;
            let r = submit(&engine, a.session, RepositoryRequest::Batch(bq));
            let owned = result(&engine, r);
            check_response(&owned, a.session, r, &expected);
            let held = owned.clone();
            let held_bytes = held.bytes().to_vec();
            drop(owned);
            release(&engine, r);
            assert_eq!(held.bytes(), held_bytes);
            let search = TraceSearchRequest {
                text: "a".into(),
                limit: 16,
                domains: SearchDomains::ALL,
            };
            let search_expected = session.search(&search, &budget())?;
            let sr = submit(&engine, a.session, RepositoryRequest::Search(search));
            let search_result = result(&engine, sr);
            check_response(&search_result, a.session, sr, &search_expected);
            let search_utf8 = std::str::from_utf8(search_result.bytes())
                .unwrap()
                .to_owned();
            drop(search_result);
            release(&engine, sr);
            let mut analysis = BoundedAnalysisRequest::new(range);
            analysis.maximum_cpu_slices = 64;
            analysis.maximum_process_slices = 64;
            analysis.maximum_thread_slices = 64;
            analysis.maximum_state_intervals = 64;
            analysis.maximum_scheduling_events = 64;
            analysis.maximum_hot_events = 64;
            analysis.maximum_output_rows = 64;
            analysis.hot_bucket_count = 8;
            let analysis_expected =
                session.analyze_bounded(&analysis, AnalysisScope::default(), &budget())?;
            let ar = submit(
                &engine,
                a.session,
                RepositoryRequest::Analyze {
                    request: analysis,
                    scope: AnalysisScope::default(),
                },
            );
            let analysis_result = result(&engine, ar);
            check_response(&analysis_result, a.session, ar, &analysis_expected);
            let analysis_utf8 = std::str::from_utf8(analysis_result.bytes())
                .unwrap()
                .to_owned();
            drop(analysis_result);
            release(&engine, ar);
            release(&engine, a.request);
            release(&engine, b.request);
            close(&engine, a.session);
            assert_eq!(
                retry(|| engine.submit(a.session, processes(), TIMEOUT)),
                Err(RuntimeFailure::Closed)
            );
            retry(|| engine.release_session(a.session))?;
            assert_eq!(
                retry(|| engine.session_status(a.session)),
                Err(RuntimeFailure::InvalidHandle)
            );
            let surviving = submit(&engine, b.session, processes());
            result(&engine, surviving);
            release(&engine, surviving);
            close(&engine, b.session);
            assert_eq!(held.bytes(), held_bytes);
            assert!(engine.retained_result_bytes() > 0);
            drain(&engine);
            assert_eq!(held.bytes(), held_bytes);
            drop(held);
            assert_eq!(engine.retained_result_bytes(), 0);
            assert!(clean(&namespace));
            drop(engine);
            session.close()?;
            let after = fds();
            assert_eq!(before, after, "{} descriptors", fixture);
            assert_eq!(source.facts(&io())?, original);
            sources.push(json!({"fixture":fixture,"fullBatchSearchAnalysisParity":true,"isolatedSessions":true,"resultSurvivesReleaseCloseDrain":true,"rawBytesUnchanged":true,"descriptorsBefore":before,"descriptorsAfter":after,"ownedScopesRemoved":true,"inspection":opened["inspection"],"responsesUtf8":{"batch":std::str::from_utf8(&held_bytes).unwrap(),"search":search_utf8,"analysis":analysis_utf8}}));
        }
        let path = fixtures.join("zlib.htrace");
        // A real Ready session is blocked before an actual query. Public methods
        // must return without waiting; queued work, close and drain stay bounded.
        {
            let ns = root.create_private_child("bounded-runtime")?;
            let before = fds();
            let gate = Gate::new(WorkerBoundary::Querying);
            let g = gate.clone();
            let mut c = config("bounded-runtime")
                .observe_worker_for_fixture(Arc::new(move |b| g.observe(b)));
            c.limits.workers = 1;
            c.limits.sessions = 1;
            c.limits.requests = 3;
            c.limits.queue_per_worker = 1;
            let engine = AsyncEngine::create(c)?;
            let ticket = open(&engine, &path, SourceFormat::Htrace);
            result(&engine, ticket.request);
            assert_eq!(
                retry(|| engine.open(path.clone(), SourceFormat::Htrace, TIMEOUT)),
                Err(RuntimeFailure::Capacity)
            );
            gate.arm(false);
            let active = submit(&engine, ticket.session, processes());
            gate.wait();
            let queued = submit(&engine, ticket.session, processes());
            assert_eq!(
                retry(|| engine.submit(ticket.session, processes(), TIMEOUT)),
                Err(RuntimeFailure::Capacity)
            );
            retry(|| engine.cancel(queued))?;
            retry(|| engine.cancel(queued))?;
            assert_eq!(
                retry(|| engine.release_request(active)),
                Err(RuntimeFailure::Busy)
            );
            let foreign_namespace = root.create_private_child("foreign-runtime")?;
            let foreign = AsyncEngine::create(config("foreign-runtime"))?;
            assert_eq!(
                retry(|| foreign.poll(active)),
                Err(RuntimeFailure::InvalidHandle)
            );
            assert_eq!(
                retry(|| engine.poll(ticket.session)),
                Err(RuntimeFailure::InvalidHandle)
            );
            assert_eq!(
                retry(|| engine.close(active)),
                Err(RuntimeFailure::InvalidHandle)
            );
            drain(&foreign);
            drop(foreign);
            drop(foreign_namespace);
            retry(|| engine.close(ticket.session))?;
            assert!(!retry(|| engine.session_status(ticket.session))?.resources_closed);
            assert_eq!(
                retry(|| engine.submit(ticket.session, processes(), TIMEOUT)),
                Err(RuntimeFailure::Closed)
            );
            engine.start_drain();
            assert_eq!(engine.drain_status(), DrainStatus::Draining);
            assert!(!retry(|| engine.session_status(ticket.session))?.resources_closed);
            gate.unblock();
            assert_eq!(
                wait(&engine, active).failure,
                Some(RuntimeFailure::Cancelled)
            );
            assert_eq!(
                wait(&engine, queued).failure,
                Some(RuntimeFailure::Cancelled)
            );
            drain(&engine);
            assert!(retry(|| engine.session_status(ticket.session))?.resources_closed);
            assert!(clean(&ns));
            release(&engine, ticket.request);
            release(&engine, active);
            release(&engine, queued);
            drop(engine);
            drop(gate);
            assert_eq!(before, fds());
            checks.push(
                json!({"id":"nonblocking-close-and-drain-with-full-normal-queue","passed":true}),
            );
        }
        // Cancellation alone must leave a Ready session usable for the next call.
        {
            let ns = root.create_private_child("cancel-runtime")?;
            let gate = Gate::new(WorkerBoundary::Querying);
            let g = gate.clone();
            let mut c = config("cancel-runtime")
                .observe_worker_for_fixture(Arc::new(move |b| g.observe(b)));
            c.limits.workers = 1;
            let engine = AsyncEngine::create(c)?;
            let ticket = open(&engine, &path, SourceFormat::Htrace);
            result(&engine, ticket.request);
            release(&engine, ticket.request);
            gate.arm(false);
            let active = submit(&engine, ticket.session, processes());
            gate.wait();
            let queued = submit(&engine, ticket.session, processes());
            retry(|| engine.cancel(active))?;
            retry(|| engine.cancel(queued))?;
            gate.unblock();
            assert_eq!(
                wait(&engine, active).failure,
                Some(RuntimeFailure::Cancelled)
            );
            assert_eq!(
                wait(&engine, queued).failure,
                Some(RuntimeFailure::Cancelled)
            );
            release(&engine, active);
            release(&engine, queued);
            assert_eq!(
                retry(|| engine.session_status(ticket.session))?.state,
                SessionState::Ready
            );
            let next = submit(&engine, ticket.session, processes());
            result(&engine, next);
            assert_ne!(next, active);
            assert_eq!(
                retry(|| engine.poll(active)),
                Err(RuntimeFailure::InvalidHandle)
            );
            release(&engine, next);
            close(&engine, ticket.session);
            drain(&engine);
            assert!(clean(&ns));
            checks.push(json!({"id":"active-and-queued-cancel-do-not-contaminate-next-query","passed":true}));
        }
        // Panic after an actual DB was opened is fatal, visible and still closable.
        for (name, boundary) in [
            ("panic-open", WorkerBoundary::Opened),
            ("panic-query", WorkerBoundary::Querying),
            ("panic-close", WorkerBoundary::Closing),
        ] {
            let ns = root.create_private_child(name)?;
            let before = fds();
            let gate = Gate::new(boundary);
            let g = gate.clone();
            let mut c = config(name).observe_worker_for_fixture(Arc::new(move |b| g.observe(b)));
            c.limits.workers = 1;
            if boundary == WorkerBoundary::Opened {
                gate.arm(true);
            }
            let engine = AsyncEngine::create(c)?;
            let ticket = open(&engine, &path, SourceFormat::Htrace);
            if boundary == WorkerBoundary::Opened {
                gate.wait();
                retry(|| engine.cancel(ticket.request))?;
                gate.unblock();
                assert_eq!(
                    wait(&engine, ticket.request).failure,
                    Some(RuntimeFailure::WorkerPanicked)
                );
            } else {
                result(&engine, ticket.request);
                gate.arm(true);
                if boundary == WorkerBoundary::Querying {
                    let r = submit(&engine, ticket.session, processes());
                    gate.wait();
                    retry(|| engine.cancel(r))?;
                    gate.unblock();
                    assert_eq!(
                        wait(&engine, r).failure,
                        Some(RuntimeFailure::WorkerPanicked)
                    );
                    release(&engine, r);
                    assert_eq!(
                        retry(|| engine.session_status(ticket.session))?.state,
                        SessionState::Failed
                    );
                    close(&engine, ticket.session);
                } else {
                    retry(|| engine.close(ticket.session))?;
                    gate.wait();
                    assert!(!retry(|| engine.session_status(ticket.session))?.resources_closed);
                    gate.unblock();
                    let deadline = Instant::now() + TIMEOUT;
                    loop {
                        let status = retry(|| engine.session_status(ticket.session))?;
                        if status.resources_closed {
                            assert_eq!(status.close_failure, Some(RuntimeFailure::WorkerPanicked));
                            break;
                        }
                        assert!(Instant::now() < deadline);
                        thread::sleep(Duration::from_millis(1));
                    }
                }
            }
            assert!(retry(|| engine.session_status(ticket.session))?.resources_closed);
            release(&engine, ticket.request);
            retry(|| engine.release_session(ticket.session))?;
            drain(&engine);
            assert!(clean(&ns));
            drop(engine);
            drop(gate);
            assert_eq!(before, fds());
            checks.push(json!({"id":name,"passed":true}));
        }
        // Cancel an opening after a real owned staging scope was created.
        {
            let ns = root.create_private_child("cancel-opening")?;
            let gate = Gate::new(WorkerBoundary::Opening);
            gate.arm(false);
            let g = gate.clone();
            let engine = AsyncEngine::create(
                config("cancel-opening")
                    .observe_worker_for_fixture(Arc::new(move |b| g.observe(b))),
            )?;
            let ticket = open(&engine, &path, SourceFormat::Htrace);
            gate.wait();
            assert_eq!(
                retry(|| engine.submit(ticket.session, processes(), TIMEOUT)),
                Err(RuntimeFailure::Closed)
            );
            retry(|| engine.close(ticket.session))?;
            assert!(!retry(|| engine.session_status(ticket.session))?.resources_closed);
            gate.unblock();
            assert_eq!(
                wait(&engine, ticket.request).failure,
                Some(RuntimeFailure::Cancelled)
            );
            close(&engine, ticket.session);
            drain(&engine);
            assert!(clean(&ns));
            checks.push(
                json!({"id":"close-opening-drains-owned-staging-before-terminal","passed":true}),
            );
        }
        // Encoding exhaustion must not prevent close, or publish partial output.
        {
            let ns = root.create_private_child("limited-result")?;
            let mut c = config("limited-result");
            c.limits.maximum_retained_result_bytes = 1;
            let engine = AsyncEngine::create(c)?;
            let ticket = open(&engine, &path, SourceFormat::Htrace);
            assert_eq!(
                wait(&engine, ticket.request).failure,
                Some(RuntimeFailure::OutputLimit)
            );
            assert!(retry(|| engine.acquire_result(ticket.request)).is_err());
            assert_eq!(engine.retained_result_bytes(), 0);
            assert!(retry(|| engine.session_status(ticket.session))?.resources_closed);
            retry(|| engine.close(ticket.session))?;
            drain(&engine);
            assert!(clean(&ns));
            checks.push(json!({"id":"result-allocation-exhaustion-cleans-real-ready-session","passed":true}));
        }
        // Retained Rust-owned results remain charged after their requests are
        // released; releasing the last owner makes the next query usable.
        {
            let ns = root.create_private_child("retained-budget")?;
            let mut c = config("retained-budget");
            c.limits.maximum_retained_result_bytes = 65536;
            let engine = AsyncEngine::create(c)?;
            let ticket = open(&engine, &path, SourceFormat::Htrace);
            result(&engine, ticket.request);
            release(&engine, ticket.request);
            let mut held = Vec::new();
            let mut exhausted = false;
            for _ in 0..128 {
                let r = submit(&engine, ticket.session, processes());
                let status = wait(&engine, r);
                if status.failure == Some(RuntimeFailure::OutputLimit) {
                    assert!(retry(|| engine.acquire_result(r)).is_err());
                    release(&engine, r);
                    exhausted = true;
                    break;
                }
                held.push(result(&engine, r));
                release(&engine, r);
            }
            assert!(exhausted && !held.is_empty());
            assert!(engine.retained_result_bytes() <= 65536);
            let retained_count = held.len();
            held.clear();
            assert_eq!(engine.retained_result_bytes(), 0);
            assert_eq!(
                retry(|| engine.session_status(ticket.session))?.state,
                SessionState::Ready
            );
            let r = submit(&engine, ticket.session, processes());
            result(&engine, r);
            release(&engine, r);
            close(&engine, ticket.session);
            drain(&engine);
            assert!(clean(&ns));
            checks.push(json!({"id":"retained-results-cannot-bypass-engine-capacity","passed":true,"retainedCountAtExhaustion":retained_count}));
        }
        // Observe the actual helper/parser process relationship, then cancel
        // an in-flight real Systrace export. Terminal state requires both gone.
        {
            fn processes() -> Vec<(u32, u32)> {
                let output = std::process::Command::new("/bin/ps")
                    .args(["-A", "-o", "pid=,ppid="])
                    .output()
                    .unwrap();
                assert!(
                    output.status.success(),
                    "native process observation unavailable"
                );
                String::from_utf8(output.stdout)
                    .unwrap()
                    .lines()
                    .filter_map(|line| {
                        let p = line
                            .split_whitespace()
                            .filter_map(|s| s.parse::<u32>().ok())
                            .collect::<Vec<_>>();
                        if p.len() == 2 {
                            Some((p[0], p[1]))
                        } else {
                            None
                        }
                    })
                    .collect()
            }
            let ns = root.create_private_child("cancel-parser")?;
            let before = fds();
            let engine = AsyncEngine::create(config("cancel-parser"))?;
            let ticket = open(
                &engine,
                &fixtures.join("trace_small_10.systrace"),
                SourceFormat::Systrace,
            );
            let deadline = Instant::now() + TIMEOUT;
            let (helper_pid, parser_pid) = loop {
                let status = retry(|| engine.poll(ticket.request))?;
                assert!(
                    !matches!(status.state, RequestState::Succeeded | RequestState::Failed),
                    "parser completed before in-flight observation"
                );
                if status.progress == Some(EngineProgress::Parsing) {
                    let rows = processes();
                    let observed = rows
                        .iter()
                        .filter(|(_, parent)| *parent == std::process::id())
                        .find_map(|(pid, _)| {
                            rows.iter()
                                .find(|(_, parent)| parent == pid)
                                .map(|(child, _)| (*pid, *child))
                        });
                    if let Some(pair) = observed {
                        break pair;
                    }
                }
                assert!(Instant::now() < deadline);
                thread::sleep(Duration::from_millis(1));
            };
            retry(|| engine.cancel(ticket.request))?;
            assert_eq!(
                wait(&engine, ticket.request).failure,
                Some(RuntimeFailure::Cancelled)
            );
            let remaining = processes();
            assert!(
                !remaining
                    .iter()
                    .any(|(pid, _)| *pid == helper_pid || *pid == parser_pid)
            );
            close(&engine, ticket.session);
            drain(&engine);
            assert!(clean(&ns));
            drop(engine);
            assert_eq!(before, fds());
            checks.push(json!({"id":"actual-parser-cancel-reaps-helper-and-parser-before-terminal","passed":true,"observedHelperPID":helper_pid,"observedParserPID":parser_pid}));
        }
        {
            let ns = root.create_private_child("drop-runtime")?;
            let before = fds();
            let gate = Gate::new(WorkerBoundary::Querying);
            let g = gate.clone();
            let mut c =
                config("drop-runtime").observe_worker_for_fixture(Arc::new(move |b| g.observe(b)));
            c.limits.workers = 1;
            let engine = AsyncEngine::create(c)?;
            let ticket = open(&engine, &path, SourceFormat::Htrace);
            result(&engine, ticket.request);
            release(&engine, ticket.request);
            let r = submit(&engine, ticket.session, processes());
            let held = result(&engine, r);
            let encoded = held.bytes().to_vec();
            release(&engine, r);
            gate.arm(false);
            submit(&engine, ticket.session, processes());
            gate.wait();
            drop(engine); // must return before the blocked owner is unparked
            assert_eq!(held.bytes(), encoded);
            gate.unblock();
            let deadline = Instant::now() + TIMEOUT;
            loop {
                if clean(&ns) && fds() == before {
                    break;
                }
                assert!(Instant::now() < deadline);
                thread::sleep(Duration::from_millis(1));
            }
            assert_eq!(held.bytes(), encoded);
            drop(held);
            checks.push(json!({"id":"drop-signals-owner-cleanup-without-waiting-or-invalidating-owned-result","passed":true}));
        }
        // Force the cleanup/publication race after an actual owned opening
        // scope was removed. Neither close nor poll may publish an early terminal.
        {
            let ns = root.create_private_child("opening-terminal-race")?;
            let gate = Gate::new(WorkerBoundary::OpeningDrained);
            gate.arm(false);
            let g = gate.clone();
            let mut c = config("opening-terminal-race")
                .observe_worker_for_fixture(Arc::new(move |b| g.observe(b)));
            c.limits.workers = 1;
            let engine = AsyncEngine::create(c)?;
            let ticket = open(
                &engine,
                &fixtures.join("absent.htrace"),
                SourceFormat::Htrace,
            );
            gate.wait();
            assert!(clean(&ns));
            assert!(!retry(|| engine.session_status(ticket.session))?.resources_closed);
            assert_eq!(
                retry(|| engine.poll(ticket.request))?.state,
                RequestState::Running
            );
            retry(|| engine.close(ticket.session))?;
            assert!(!retry(|| engine.session_status(ticket.session))?.resources_closed);
            gate.unblock();
            assert_eq!(
                wait(&engine, ticket.request).failure,
                Some(RuntimeFailure::Cancelled)
            );
            close(&engine, ticket.session);
            drain(&engine);
            assert!(clean(&ns));
            checks.push(json!({"id":"cleanup-and-request-terminal-publish-atomically-after-close-race","passed":true}));
        }
        // Tool/source failures stay async and produce a bounded public error.
        {
            let ns = root.create_private_child("missing-source")?;
            let engine = AsyncEngine::create(config("missing-source"))?;
            let ticket = open(
                &engine,
                &fixtures.join("absent.htrace"),
                SourceFormat::Htrace,
            );
            let status = wait(&engine, ticket.request);
            assert_eq!(status.state, RequestState::Failed);
            let public = serde_json::to_string(
                &status
                    .failure
                    .unwrap()
                    .public_error()
                    .expect("terminal error"),
            )?;
            assert!(!public.contains(base.to_str().unwrap()));
            assert!(retry(|| engine.session_status(ticket.session))?.resources_closed);
            drain(&engine);
            assert!(clean(&ns));
            checks.push(
                json!({"id":"missing-source-does-not-leak-path-or-owned-scope","passed":true}),
            );
        }
        println!(
            "{}",
            serde_json::to_string_pretty(
                &json!({"sdkAcceptance":false,"persistentCacheAcceptance":false,"sources":sources,"negativeCases":checks,"fixedSessionWorkers":true,"realParserIdentity":identity})
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
