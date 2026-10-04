use arktrace_contract::*;
use arktrace_viewer::*;
use std::mem::size_of;
fn range(a: i64, b: i64) -> TraceTimeRange {
    TraceTimeRange::event(a, b).unwrap()
}
fn cpu() -> CpuSlice {
    CpuSlice {
        key: EventKey {
            table: EventTable::SchedSlice,
            row_id: 1,
        },
        range: range(10, 20),
        cpu: 0,
        thread_key: Some(ThreadKey { itid: 44 }),
        process_key: Some(ProcessKey { ipid: 33 }),
        tid: Some(7),
        pid: Some(7),
        thread_name: Some("共享🧭".into()),
        process_name: Some("共享🧭".into()),
        end_state: None,
        priority: Some(i64::MIN),
        is_open_ended: false,
    }
}
fn project(
    inputs: &[InspectorProjectionInput<'_>],
) -> Result<InspectorProjectionBatch, InspectorProjectionError> {
    project_inspectors(1, inputs, InspectorProjectionBudget::default(), &mut || {
        Ok(())
    })
}
fn descriptor() -> CounterSeriesDescriptor {
    CounterSeriesDescriptor {
        filter_id: 1,
        name: "counter".into(),
        scope: CounterScope::Cpu,
        cpu: Some(0),
        process_key: None,
        pid: None,
        process_name: None,
        unit: None,
    }
}
#[test]
fn version_budget_and_table_identity_fail_without_publishing_then_retry_succeeds() {
    let mut e = cpu();
    assert_eq!(
        project_inspectors(
            2,
            &[InspectorProjectionInput::CpuSlice(&e)],
            Default::default(),
            &mut || Ok(())
        )
        .unwrap_err(),
        InspectorProjectionError::UnsupportedVersion
    );
    assert_eq!(
        project_inspectors(
            1,
            &[],
            InspectorProjectionBudget {
                maximum_records: MAXIMUM_INSPECTOR_RECORDS + 1,
                ..Default::default()
            },
            &mut || Ok(())
        )
        .unwrap_err(),
        InspectorProjectionError::InvalidRequest
    );
    e.key.table = EventTable::ProcessMeasure;
    assert_eq!(
        project(&[InspectorProjectionInput::CpuSlice(&e)]).unwrap_err(),
        InspectorProjectionError::InvalidEventKey
    );
    e.key.table = EventTable::SchedSlice;
    assert_eq!(
        project(&[InspectorProjectionInput::CpuSlice(&e)])
            .unwrap()
            .records()[0]
            .unwrap()
            .key(),
        e.key
    );
}
#[test]
fn counter_invalid_duration_timestamp_query_and_overflow_are_typed() {
    let d = descriptor();
    let mut sample = CounterSample {
        key: EventKey {
            table: EventTable::Measure,
            row_id: 1,
        },
        timestamp_ns: 10,
        value: i64::MAX,
        duration_ns: Some(3),
    };
    for (timestamp, duration, error) in [
        (-1, None, InspectorProjectionError::InvalidRequest),
        (10, Some(-1), InspectorProjectionError::InvalidRequest),
        (
            i64::MAX,
            Some(1),
            InspectorProjectionError::ArithmeticOverflow,
        ),
    ] {
        sample.timestamp_ns = timestamp;
        sample.duration_ns = duration;
        assert_eq!(
            project(&[InspectorProjectionInput::Counter {
                series: &d,
                sample: &sample,
                query_range: range(0, 100)
            }])
            .unwrap_err(),
            error
        );
    }
    sample.timestamp_ns = 10;
    sample.duration_ns = Some(3);
    assert_eq!(
        project(&[InspectorProjectionInput::Counter {
            series: &d,
            sample: &sample,
            query_range: range(0, 0)
        }])
        .unwrap_err(),
        InspectorProjectionError::InvalidRequest
    );
    assert!(
        project(&[InspectorProjectionInput::Counter {
            series: &d,
            sample: &sample,
            query_range: range(0, 100)
        }])
        .is_ok()
    );
}
#[test]
fn counter_open_range_and_semantic_duration_are_independent() {
    let d = descriptor();
    let mut s = CounterSample {
        key: EventKey {
            table: EventTable::Measure,
            row_id: 1,
        },
        timestamp_ns: 10,
        value: 0,
        duration_ns: Some(100),
    };
    let make = |s: &CounterSample| {
        project(&[InspectorProjectionInput::Counter {
            series: &d,
            sample: s,
            query_range: range(20, 40),
        }])
        .unwrap()
        .records()[0]
            .unwrap()
    };
    let positive = make(&s);
    assert_eq!(positive.range(), range(10, 110));
    assert_eq!(positive.semantic_duration_ns(), Some(100));
    s.duration_ns = None;
    let open = make(&s);
    assert_eq!(open.range(), range(10, 40));
    assert_eq!(open.semantic_duration_ns(), None);
    assert!(!open.is_instant());
    s.timestamp_ns = 50;
    let late = make(&s);
    assert_eq!(late.range(), range(50, 50));
    assert!(!late.is_instant());
    s.duration_ns = Some(0);
    assert!(make(&s).is_instant());
}
#[test]
fn input_byte_limits_count_duplicate_borrowed_fields_and_utf8_not_characters() {
    let mut e = cpu();
    e.thread_name = Some("界".repeat(1365) + "a");
    e.process_name = None;
    assert_eq!(e.thread_name.as_ref().unwrap().len(), 4096);
    assert!(project(&[InspectorProjectionInput::CpuSlice(&e)]).is_ok());
    e.thread_name.as_mut().unwrap().push('界');
    assert_eq!(
        project(&[InspectorProjectionInput::CpuSlice(&e)]).unwrap_err(),
        InspectorProjectionError::InputBudgetExceeded
    );
    e.thread_name = Some("abc".into());
    e.process_name = Some("abc".into());
    assert_eq!(
        project_inspectors(
            1,
            &[InspectorProjectionInput::CpuSlice(&e)],
            InspectorProjectionBudget {
                maximum_input_string_bytes: 5,
                ..Default::default()
            },
            &mut || Ok(())
        )
        .unwrap_err(),
        InspectorProjectionError::InputBudgetExceeded
    );
    assert!(
        project_inspectors(
            1,
            &[InspectorProjectionInput::CpuSlice(&e)],
            InspectorProjectionBudget {
                maximum_input_string_bytes: 6,
                ..Default::default()
            },
            &mut || Ok(())
        )
        .is_ok()
    );
    let excessive =
        vec![InspectorProjectionInput::DensityBand; MAXIMUM_INSPECTOR_RECORDS as usize + 1];
    assert_eq!(
        project(&excessive).unwrap_err(),
        InspectorProjectionError::InputBudgetExceeded
    );
}
#[test]
fn retained_limits_include_fixed_and_spare_slots_and_string_capacity() {
    let empty = project(&[]).unwrap();
    let fixed = empty.retained_bytes() as u32;
    assert_eq!(
        project_inspectors(
            1,
            &[],
            InspectorProjectionBudget {
                maximum_retained_bytes: fixed - 1,
                ..Default::default()
            },
            &mut || Ok(())
        )
        .unwrap_err(),
        InspectorProjectionError::RetainedBudgetExceeded
    );
    let mut e = cpu();
    e.thread_name = Some("abc".into());
    e.process_name = Some("abc".into());
    assert_eq!(
        project_inspectors(
            1,
            &[InspectorProjectionInput::CpuSlice(&e)],
            InspectorProjectionBudget {
                maximum_retained_string_bytes: 5,
                ..Default::default()
            },
            &mut || Ok(())
        )
        .unwrap_err(),
        InspectorProjectionError::RetainedBudgetExceeded
    );
    let p = project(&[InspectorProjectionInput::CpuSlice(&e)]).unwrap();
    let bytes = size_of::<InspectorProjectionBatch>()
        + size_of::<Option<InspectorFacts>>()
        + 6 * size_of::<String>()
        + p.strings().iter().map(|s| s.capacity()).sum::<usize>();
    assert_eq!(p.retained_bytes(), bytes as u64);
    assert_eq!(
        project_inspectors(
            1,
            &[InspectorProjectionInput::CpuSlice(&e)],
            InspectorProjectionBudget {
                maximum_retained_bytes: p.retained_bytes() as u32 - 1,
                ..Default::default()
            },
            &mut || Ok(())
        )
        .unwrap_err(),
        InspectorProjectionError::RetainedBudgetExceeded
    );
    assert!(
        project_inspectors(
            1,
            &[InspectorProjectionInput::CpuSlice(&e)],
            InspectorProjectionBudget {
                maximum_retained_bytes: p.retained_bytes() as u32,
                ..Default::default()
            },
            &mut || Ok(())
        )
        .is_ok()
    );
}
#[test]
fn clone_measures_current_capacity_and_aggregate_owner_budget_is_separate() {
    let e = cpu();
    let inputs = vec![InspectorProjectionInput::CpuSlice(&e); 64];
    let p = project(&inputs).unwrap();
    let cloned = p.clone();
    assert_eq!(cloned, p);
    let current = size_of::<InspectorProjectionBatch>()
        + std::mem::size_of_val(cloned.records())
        + std::mem::size_of_val(cloned.strings())
        + cloned.strings().iter().map(|s| s.capacity()).sum::<usize>();
    assert_eq!(cloned.retained_bytes(), current as u64);
    assert!(cloned.retained_bytes() < p.retained_bytes());
    let encoding = serde_json::to_vec(&p).unwrap();
    let combined = p.retained_bytes() + cloned.retained_bytes() + encoding.capacity() as u64;
    assert!(combined > p.retained_bytes());
}
#[test]
fn cancellation_and_deadline_at_every_checkpoint_publish_no_partial_batch() {
    let e = cpu();
    let input = [InspectorProjectionInput::CpuSlice(&e); 3];
    let mut calls = 0;
    let expected = project_inspectors(1, &input, Default::default(), &mut || {
        calls += 1;
        Ok(())
    })
    .unwrap();
    for error in [
        InspectorProjectionError::Cancelled,
        InspectorProjectionError::DeadlineReached,
    ] {
        for stop in 0..calls {
            let mut current = 0;
            let result = project_inspectors(1, &input, Default::default(), &mut || {
                let probe = current;
                current += 1;
                if probe == stop { Err(error) } else { Ok(()) }
            });
            assert_eq!(result.unwrap_err(), error);
        }
        assert_eq!(project(&input).unwrap(), expected);
    }
}
#[test]
fn density_has_no_detail_and_identity_does_not_follow_reused_pid_tid() {
    let mut e = cpu();
    let mut other = e.clone();
    other.process_key = Some(ProcessKey { ipid: 99 });
    other.thread_key = Some(ThreadKey { itid: 88 });
    e.thread_name = None;
    other.thread_name = Some(String::new());
    let p = project(&[
        InspectorProjectionInput::CpuSlice(&e),
        InspectorProjectionInput::CpuSlice(&other),
        InspectorProjectionInput::DensityBand,
    ])
    .unwrap();
    let a = p.records()[0].unwrap();
    let b = p.records()[1].unwrap();
    assert_eq!(a.pid(), b.pid());
    assert_eq!(a.tid(), b.tid());
    assert_ne!(a.process_key(), b.process_key());
    assert_ne!(a.thread_key(), b.thread_key());
    assert_eq!(p.text(a.name()), None);
    assert_eq!(p.text(b.name()), Some(""));
    assert_eq!(p.records()[2], None);
}
