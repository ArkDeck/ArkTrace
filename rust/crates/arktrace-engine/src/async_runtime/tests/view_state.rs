use super::*;

fn fixture(queue_slots: usize) -> (AsyncEngine, Receiver<Command>, RuntimeHandle) {
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
        view_state_input_budget: InputBudget::new(MAXIMUM_RETAINED_VIEW_STATE_INPUT_BYTES),
    });
    let session = background_registry(&shared)
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
        .unwrap();
    let (sender, receiver) = mpsc::sync_channel(queue_slots);
    (
        AsyncEngine {
            cache_enabled: false,
            shared,
            senders: vec![sender],
            limits,
        },
        receiver,
        session,
    )
}
fn submit(
    engine: &AsyncEngine,
    session: RuntimeHandle,
    bytes: &[u8],
) -> Result<RuntimeHandle, RuntimeFailure> {
    engine.submit_view_state(
        session,
        ViewStateRequest::Write(bytes),
        Duration::from_secs(1),
    )
}

#[test]
fn original_input_is_copied_once_and_cancellation_retains_credits_until_command_drops() {
    let (engine, receiver, session) = fixture(8);
    let mut input = b"original".to_vec();
    let request = submit(&engine, session, &input).unwrap();
    input.fill(0);
    let command = receiver.recv().unwrap();
    let Operation::ViewState(ViewStateOperation::Write(bytes)) = &command.operation else {
        panic!("write command");
    };
    assert_eq!(bytes.bytes(), b"original");
    assert_eq!(command.session, session);
    assert_eq!(command.request, Some(request));
    engine.cancel(request).unwrap();
    assert!(command.budget.cancellation.is_cancelled());
    assert_eq!(
        engine.poll(request).unwrap().state,
        RequestState::Cancelling
    );
    assert_eq!(engine.retained_view_state_input_bytes(), 8);
    drop(command);
    assert_eq!(engine.retained_view_state_input_bytes(), 0);
}

#[test]
fn byte_and_shared_capacity_rejection_never_enqueue_or_truncate() {
    let (engine, receiver, session) = fixture(8);
    assert_eq!(
        submit(&engine, session, &[]),
        Err(RuntimeFailure::InvalidRequest)
    );
    let mut bytes = vec![0; crate::MAXIMUM_VIEW_STATE_BYTES + 1];
    assert_eq!(
        submit(&engine, session, &bytes),
        Err(RuntimeFailure::InvalidRequest)
    );
    bytes.pop();
    for _ in 0..4 {
        submit(&engine, session, &bytes).unwrap();
    }
    assert_eq!(
        engine.retained_view_state_input_bytes(),
        MAXIMUM_RETAINED_VIEW_STATE_INPUT_BYTES
    );
    assert_eq!(
        submit(&engine, session, &[0]),
        Err(RuntimeFailure::Capacity)
    );
    let commands: Vec<_> = receiver.try_iter().collect();
    assert_eq!(commands.len(), 4);
    drop(commands);
    assert_eq!(engine.retained_view_state_input_bytes(), 0);
}

#[test]
fn busy_stale_closed_and_failed_queue_admission_refund_all_input_capacity() {
    let (engine, receiver, session) = fixture(1);
    {
        let _registry = engine.shared.registry.lock().unwrap();
        assert_eq!(submit(&engine, session, b"x"), Err(RuntimeFailure::Busy));
        assert_eq!(engine.retained_view_state_input_bytes(), 0);
    }
    assert_eq!(
        submit(&engine, RuntimeHandle::from_raw(0), b"x"),
        Err(RuntimeFailure::InvalidHandle)
    );
    engine
        .submit_view_state(session, ViewStateRequest::Read, Duration::from_secs(1))
        .unwrap();
    assert_eq!(
        submit(&engine, session, b"x"),
        Err(RuntimeFailure::Capacity)
    );
    assert_eq!(engine.retained_view_state_input_bytes(), 0);
    assert_eq!(receiver.try_iter().count(), 1);
    drop(receiver);
    assert_eq!(
        submit(&engine, session, b"x"),
        Err(RuntimeFailure::WorkerPanicked)
    );
    assert_eq!(engine.retained_view_state_input_bytes(), 0);
    if let Record::Session(s) = background_registry(&engine.shared)
        .table
        .get_mut(session)
        .unwrap()
    {
        s.status.state = SessionState::Closing;
    }
    assert_eq!(submit(&engine, session, b"x"), Err(RuntimeFailure::Closed));
    assert_eq!(engine.retained_view_state_input_bytes(), 0);
}

#[test]
fn drain_cancels_queued_documents_and_unwind_drops_their_owned_credits() {
    let (engine, receiver, session) = fixture(8);
    let request = submit(&engine, session, b"document").unwrap();
    engine.start_drain();
    assert_eq!(submit(&engine, session, b"x"), Err(RuntimeFailure::Closed));
    let command = receiver.recv().unwrap();
    assert_eq!(command.request, Some(request));
    assert!(command.budget.cancellation.is_cancelled());
    assert_eq!(engine.retained_view_state_input_bytes(), 8);
    assert!(
        catch_unwind(AssertUnwindSafe(move || {
            let _owned = command;
            panic!("worker fixture");
        }))
        .is_err()
    );
    assert_eq!(engine.retained_view_state_input_bytes(), 0);
}
