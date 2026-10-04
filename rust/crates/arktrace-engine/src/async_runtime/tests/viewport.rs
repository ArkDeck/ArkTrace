use super::*;
use arktrace_viewer::{DensityResolutionRequest, DetailPreference, Viewport, ViewportRequest};

fn viewport(generation: u64) -> RepositoryRequest {
    RepositoryRequest::ViewerViewport {
        request: Box::new(ViewportRequest {
            viewport: Viewport::new(
                TraceTimeRange::query(0, 100).unwrap(),
                200.0,
                80.0,
                0.0,
                generation,
            )
            .unwrap(),
            tracks: vec![],
            pixel_width: 400,
            generation,
            preference: DetailPreference::Detail,
            maximum_primitives: Some(16),
            focused_event_key: None,
        }),
        backing_scale: 2.0,
    }
}
fn fixture() -> (AsyncEngine, Receiver<Command>, [RuntimeHandle; 2]) {
    let limits = RuntimeLimits {
        workers: 1,
        ..RuntimeLimits::default()
    };
    let shared = Arc::new(Shared {
        registry: Mutex::new(Registry {
            table: HandleTable::new(72).unwrap(),
            queued: vec![0],
            next_worker: 0,
        }),
        stopping: AtomicBool::new(false),
        alive: AtomicUsize::new(0),
        result_budget: ResultBudget::new(4096),
    });
    let handles = std::array::from_fn(|_| {
        background_registry(&shared)
            .table
            .insert(Record::Session(SessionRecord {
                latest_viewport_generation: 0,
                worker: 0,
                status: SessionStatus {
                    state: SessionState::Ready,
                    resources_closed: false,
                    close_failure: None,
                    residue_owner: None,
                },
                close_queued: false,
            }))
            .unwrap()
    });
    let (sender, receiver) = mpsc::sync_channel(24);
    (
        AsyncEngine {
            cache_enabled: false,
            shared,
            senders: vec![sender],
            limits,
        },
        receiver,
        handles,
    )
}
fn submit(engine: &AsyncEngine, session: RuntimeHandle, generation: u64) -> RuntimeHandle {
    engine
        .submit(session, viewport(generation), Duration::from_secs(1))
        .unwrap()
}
#[test]
fn newer_viewport_cancels_only_older_viewports_of_the_same_session() {
    let (engine, receiver, [a, b]) = fixture();
    let old = submit(&engine, a, 1);
    let same = submit(&engine, a, 1);
    let other = submit(&engine, b, 1);
    let generic = engine
        .submit(
            a,
            RepositoryRequest::Density(TraceDensityQuery {
                source: TraceDensitySource::Cpu { cpu: 0 },
                range: TraceTimeRange::query(0, 100).unwrap(),
                bucket_count: 1,
            }),
            Duration::from_secs(1),
        )
        .unwrap();
    let latest = submit(&engine, a, 2);
    for handle in [old, same] {
        assert_eq!(engine.poll(handle).unwrap().state, RequestState::Cancelling);
    }
    for handle in [other, generic, latest] {
        assert_eq!(engine.poll(handle).unwrap().state, RequestState::Queued);
    }
    let commands = receiver.try_iter().collect::<Vec<_>>();
    assert_eq!(commands.len(), 5);
    for command in commands {
        assert_eq!(
            command.budget.cancellation.is_cancelled(),
            [old, same].contains(&command.request.unwrap())
        );
    }
    assert_eq!(
        engine.submit(a, viewport(1), Duration::from_secs(1)),
        Err(RuntimeFailure::Cancelled)
    );
    assert!(receiver.try_recv().is_err());
    assert_eq!(engine.poll(latest).unwrap().state, RequestState::Queued);
}
#[test]
fn full_queue_does_not_advance_generation_or_cancel_previously_accepted_work() {
    let (mut engine, _receiver, [session, _]) = fixture();
    engine.limits.queue_per_worker = 1;
    let old = submit(&engine, session, 1);
    assert_eq!(
        engine.submit(session, viewport(2), Duration::from_secs(1)),
        Err(RuntimeFailure::Capacity)
    );
    assert_eq!(engine.poll(old).unwrap().state, RequestState::Queued);
    let registry = background_registry(&engine.shared);
    assert!(
        matches!(registry.table.get(session).unwrap(),Record::Session(s) if s.latest_viewport_generation==1)
    );
}
#[test]
fn held_result_survives_supersession_but_old_handle_cannot_publish_again() {
    let (engine, receiver, [session, _]) = fixture();
    let old = submit(&engine, session, 1);
    let held =
        owned_result::encode(&"viewport-one", engine.shared.result_budget.clone(), 1024).unwrap();
    {
        let mut registry = background_registry(&engine.shared);
        publish(&mut registry, old, Ok(Some(held.clone())));
    }
    let acquired = engine.acquire_result(old).unwrap();
    submit(&engine, session, 2);
    assert!(matches!(
        engine.acquire_result(old),
        Err(RuntimeFailure::Cancelled)
    ));
    assert_eq!(acquired.bytes(), br#""viewport-one""#);
    engine.release_request(old).unwrap();
    assert_eq!(held.bytes(), acquired.bytes());
    assert!(engine.retained_result_bytes() > 0);
    drop(held);
    drop(acquired);
    assert_eq!(engine.retained_result_bytes(), 0);
    drop(receiver);
}
#[test]
fn superseded_publication_rejects_success_and_preserves_fatal_failure() {
    for outcome in [Ok(None), Err(RuntimeFailure::WorkerPanicked)] {
        let (engine, receiver, [session, _]) = fixture();
        let old = submit(&engine, session, 1);
        let command = receiver.try_recv().unwrap();
        submit(&engine, session, 2);
        let config = RuntimeConfiguration::new(
            PathBuf::from("/private/tmp/fixture"),
            PathBuf::from("/private/tmp/helper"),
            PathBuf::from("/private/tmp/parser"),
            String::new(),
            TraceParserIdentity {
                name: String::new(),
                reported_version: String::new(),
                binary_sha256: String::new(),
                upstream_repository: String::new(),
                upstream_revision: String::new(),
                architecture: String::new(),
                adapter_version: String::new(),
                build_recipe_version: String::new(),
            },
            CodeTrustPolicy::DevelopmentPinned,
        );
        let expected = outcome
            .as_ref()
            .err()
            .copied()
            .unwrap_or(RuntimeFailure::Cancelled);
        finish_command(
            &engine.shared,
            &command,
            &config,
            &mut HashMap::new(),
            outcome,
        );
        assert_eq!(engine.poll(old).unwrap().failure, Some(expected));
        assert_eq!(engine.poll(old).unwrap().state, RequestState::Failed);
        assert!(matches!(engine.acquire_result(old),Err(error) if error==expected));
    }
}
#[test]
fn viewport_and_resolution_bounds_are_checked_before_dispatch() {
    let (engine, receiver, [session, _]) = fixture();
    for scale in [0.0, -1.0, f64::INFINITY, f64::NAN] {
        let RepositoryRequest::ViewerViewport { request, .. } = viewport(1) else {
            unreachable!()
        };
        assert_eq!(
            engine.submit(
                session,
                RepositoryRequest::ViewerViewport {
                    request,
                    backing_scale: scale
                },
                Duration::from_secs(1)
            ),
            Err(RuntimeFailure::InvalidRequest)
        );
    }
    let RepositoryRequest::ViewerViewport {
        mut request,
        backing_scale,
    } = viewport(1)
    else {
        unreachable!()
    };
    request.generation = 2;
    assert_eq!(
        engine.submit(
            session,
            RepositoryRequest::ViewerViewport {
                request,
                backing_scale
            },
            Duration::from_secs(1)
        ),
        Err(RuntimeFailure::InvalidRequest)
    );
    for (bucket, time_ns) in [
        (TraceTimeRange::event(0, 0).unwrap(), 0),
        (TraceTimeRange::query(0, 10).unwrap(), 11),
    ] {
        assert_eq!(
            engine.submit(
                session,
                RepositoryRequest::ViewerResolveDensity(DensityResolutionRequest {
                    source: TraceDensitySource::Cpu { cpu: 0 },
                    bucket,
                    time_ns
                }),
                Duration::from_secs(1)
            ),
            Err(RuntimeFailure::InvalidRequest)
        );
    }
    assert!(receiver.try_recv().is_err());
}
