#[allow(dead_code)]
mod common;
use arktrace_contract::*;
use arktrace_viewer::*;
fn cpu(name: Option<&str>, pid: Option<i64>, tid: Option<i64>) -> CpuSlice {
    CpuSlice {
        key: EventKey {
            table: EventTable::SchedSlice,
            row_id: 99,
        },
        range: common::range(0, 100),
        cpu: 0,
        thread_key: Some(ThreadKey { itid: 500 }),
        process_key: Some(ProcessKey { ipid: 600 }),
        pid,
        tid,
        process_name: name.map(str::to_owned),
        thread_name: None,
        end_state: None,
        priority: None,
        is_open_ended: false,
    }
}
#[test]
fn pid_tid_color_identity_is_separate_from_internal_identity() {
    let a = cpu(Some("same"), Some(1234), Some(99));
    let mut b = a.clone();
    b.process_key = Some(ProcessKey { ipid: 1 });
    b.thread_key = Some(ThreadKey { itid: 2 });
    let batch = present(
        &[PresentationInput::Cpu(&a), PresentationInput::Cpu(&b)],
        PresentationBudget::default(),
        &mut || Ok(()),
    )
    .unwrap();
    let PrimitivePresentation::Detail { detail: first } = &batch.primitives()[0] else {
        panic!()
    };
    let PrimitivePresentation::Detail { detail: second } = &batch.primitives()[1] else {
        panic!()
    };
    assert_ne!(first.identity, second.identity);
    assert_eq!(first.color, second.color);
    assert_eq!(
        first.color,
        process_or_thread_color(1234, &mut || Ok(())).unwrap()
    );
}
#[test]
fn label_nil_empty_and_tid_fallback_are_preserved() {
    assert_eq!(cpu_slice_label(None, Some(""), None).unwrap(), None);
    assert_eq!(
        cpu_slice_label(None, None, Some(i64::MIN)).unwrap(),
        Some(format!("TID {}", i64::MIN))
    );
    assert_eq!(
        cpu_slice_label(Some("proc"), Some("线程"), Some(42)).unwrap(),
        Some("proc · 线程 [42]".into())
    );
    assert_eq!(
        cpu_slice_label(Some(" "), None, None).unwrap(),
        Some(" ".into())
    );
}
#[test]
fn source_strings_are_bounded_before_projection_and_normal_request_recovers() {
    let too_long = cpu(Some(&"x".repeat(4097)), None, None);
    assert_eq!(
        present(
            &[PresentationInput::Cpu(&too_long)],
            PresentationBudget::default(),
            &mut || Ok(())
        ),
        Err(ViewerError::InputBudgetExceeded)
    );
    let normal = cpu(Some("a"), None, None);
    let b = PresentationBudget {
        maximum_input_string_bytes: 0,
        ..Default::default()
    };
    assert!(present(&[PresentationInput::Cpu(&normal)], b, &mut || Ok(())).is_err());
    assert!(
        present(
            &[PresentationInput::Cpu(&normal)],
            PresentationBudget::default(),
            &mut || Ok(())
        )
        .is_ok()
    );
}
#[test]
fn retained_limits_reject_atomically_while_interning_repeated_labels_once() {
    let a = cpu(Some("proc"), None, None);
    let inputs = [PresentationInput::Cpu(&a); 100];
    let full = present(&inputs, PresentationBudget::default(), &mut || Ok(())).unwrap();
    assert_eq!(full.strings(), &["proc", "cpu"]);
    assert_eq!(full.retained_string_bytes(), 7);
    assert_eq!(full.input_string_bytes(), 400);
    let mut b = PresentationBudget {
        maximum_retained_string_bytes: 6,
        ..Default::default()
    };
    assert_eq!(
        present(&inputs, b, &mut || Ok(())),
        Err(ViewerError::InputBudgetExceeded)
    );
    b = PresentationBudget::default();
    b.maximum_retained_bytes = full.retained_bytes() - 1;
    assert!(present(&inputs, b, &mut || Ok(())).is_err());
    b.maximum_retained_bytes = full.retained_bytes();
    assert!(present(&inputs, b, &mut || Ok(())).is_ok());
}
#[test]
fn string_pool_preserves_utf8_bytes_and_first_occurrence_order() {
    let a = cpu(Some("é"), None, None);
    let b = cpu(Some("e\u{301}"), None, None);
    let result = present(
        &[
            PresentationInput::Cpu(&a),
            PresentationInput::Cpu(&b),
            PresentationInput::Cpu(&a),
        ],
        PresentationBudget::default(),
        &mut || Ok(()),
    )
    .unwrap();
    assert_eq!(result.strings(), &["é", "cpu", "e\u{301}"]);
    assert_eq!(result.retained_string_bytes(), 8);
}
#[test]
fn batch_primitive_and_retained_fixed_memory_caps_reject() {
    let a = cpu(None, None, None);
    let inputs = vec![PresentationInput::Cpu(&a); 20001];
    assert!(present(&inputs, PresentationBudget::default(), &mut || Ok(())).is_err());
    let b = PresentationBudget {
        maximum_retained_bytes: 0,
        ..Default::default()
    };
    assert!(present(&[], b, &mut || Ok(())).is_err());
    let b = PresentationBudget {
        maximum_primitives: 20001,
        ..Default::default()
    };
    assert_eq!(
        present(&[], b, &mut || Ok(())),
        Err(ViewerError::InvalidRequest)
    );
}
#[test]
fn cancellation_and_deadline_are_bounded_and_do_not_poison_next_request() {
    let a = cpu(Some("label"), None, None);
    let inputs = vec![PresentationInput::Cpu(&a); 1000];
    let mut calls = 0;
    let mut check = || {
        calls += 1;
        if calls == 4 {
            Err(ViewerError::Cancelled)
        } else {
            Ok(())
        }
    };
    assert_eq!(
        present(&inputs, PresentationBudget::default(), &mut check),
        Err(ViewerError::Cancelled)
    );
    assert_eq!(calls, 4);
    assert_eq!(
        present(&inputs, PresentationBudget::default(), &mut || Err(
            ViewerError::DeadlineReached
        )),
        Err(ViewerError::DeadlineReached)
    );
    assert!(present(&inputs, PresentationBudget::default(), &mut || Ok(())).is_ok());
}
#[test]
fn invalid_source_key_or_counter_index_is_not_replaced_by_fake_key() {
    let mut a = cpu(None, None, None);
    a.key.table = EventTable::Callstack;
    assert_eq!(
        present(
            &[PresentationInput::Cpu(&a)],
            PresentationBudget::default(),
            &mut || Ok(())
        ),
        Err(ViewerError::InvalidEvidence)
    );
}
#[test]
fn depth_and_open_ended_survive_without_changing_name_color() {
    let e = TraceSlice {
        key: EventKey {
            table: EventTable::Callstack,
            row_id: i64::MIN,
        },
        range: common::range(100, 100),
        thread_key: None,
        process_key: None,
        pid: None,
        tid: None,
        process_name: None,
        thread_name: None,
        name: "fn42".into(),
        category: None,
        depth: Some(i64::MAX),
        parent_event_key: None,
        is_async: false,
        is_open_ended: true,
        arg_set_id: None,
    };
    let b = present(
        &[
            PresentationInput::NamedSlice {
                event: &e,
                shows_nested_depth: true,
            },
            PresentationInput::NamedSlice {
                event: &e,
                shows_nested_depth: false,
            },
        ],
        PresentationBudget::default(),
        &mut || Ok(()),
    )
    .unwrap();
    let PrimitivePresentation::Detail { detail: a } = &b.primitives()[0] else {
        panic!()
    };
    let PrimitivePresentation::Detail { detail: c } = &b.primitives()[1] else {
        panic!()
    };
    assert_eq!(a.depth, i64::MAX);
    assert_eq!(c.depth, 0);
    assert_eq!(a.color, c.color);
    assert!(!a.is_instant);
    assert!(a.is_open_ended);
    assert_eq!(a.event_key.row_id, i64::MIN);
}
#[test]
fn density_has_no_event_key_keeps_full_opacity_and_explicit_fallback_fact() {
    let bucket = TraceDensityBucket {
        range: common::range(0, 100),
        event_count: 64,
        occupied_ns: None,
        utilization: None,
        dominant: None,
    };
    let track = common::descriptor(0);
    let b = present(
        &[PresentationInput::Density {
            bucket: &bucket,
            track: &track,
        }],
        PresentationBudget::default(),
        &mut || Ok(()),
    )
    .unwrap();
    let PrimitivePresentation::Density { density: d } = &b.primitives()[0] else {
        panic!()
    };
    assert_eq!(d.color.rgba.alpha, 1.0);
    assert_eq!(d.intensity, 6);
    assert!(d.uses_track_fallback);
    assert!(b.strings().is_empty());
    assert!(!serde_json::to_string(&b).unwrap().contains("eventKey"));
}
#[test]
fn counter_index_duration_and_open_ended_are_bounded_without_cloning_series() {
    let value: serde_json::Value =
        serde_json::from_str(include_str!("fixtures/detail-inputs.json")).unwrap();
    let mut series: CounterSeries =
        serde_json::from_value(value[4]["counters"][0].clone()).unwrap();
    let r = common::range(0, 1000);
    let bad = PresentationInput::Counter {
        series: &series,
        sample_index: usize::MAX,
        query_range: r,
    };
    assert_eq!(
        present(&[bad], PresentationBudget::default(), &mut || Ok(())),
        Err(ViewerError::InvalidEvidence)
    );
    series.samples[0].duration_ns = Some(-1);
    assert_eq!(
        present(
            &[PresentationInput::Counter {
                series: &series,
                sample_index: 0,
                query_range: r
            }],
            PresentationBudget::default(),
            &mut || Ok(())
        ),
        Err(ViewerError::InvalidEvidence)
    );
    series.samples[0].timestamp_ns = i64::MAX;
    series.samples[0].duration_ns = Some(1);
    assert_eq!(
        present(
            &[PresentationInput::Counter {
                series: &series,
                sample_index: 0,
                query_range: r
            }],
            PresentationBudget::default(),
            &mut || Ok(())
        ),
        Err(ViewerError::ArithmeticOverflow)
    );
    series.samples[0].duration_ns = None;
    let b = present(
        &[PresentationInput::Counter {
            series: &series,
            sample_index: 0,
            query_range: r,
        }],
        PresentationBudget::default(),
        &mut || Ok(()),
    )
    .unwrap();
    let PrimitivePresentation::Detail { detail: d } = &b.primitives()[0] else {
        panic!()
    };
    assert_eq!(d.range, common::range(i64::MAX, i64::MAX));
    assert!(d.is_open_ended);
    assert!(!d.is_instant);
}
