use arktrace_contract::TraceTimeRange;
use arktrace_viewer::*;
fn range(a: i64, b: i64) -> TraceTimeRange {
    TraceTimeRange::event(a, b).unwrap()
}
fn state() -> AnnotationState {
    AnnotationState::new(
        1,
        Some(range(0, 1000)),
        AnnotationBudget::default(),
        &mut || Ok(()),
    )
    .unwrap()
}
fn run(
    state: &mut AnnotationState,
    action: AnnotationAction<'_>,
    context: AnnotationContext,
) -> Result<AnnotationOutcome, AnnotationError> {
    let session_id = state.session_id();
    state.apply(
        AnnotationRequest {
            api_version: ANNOTATION_API_VERSION,
            session_id,
            context,
            action,
        },
        &mut || Ok(()),
    )
}
fn flag(id: i64, timestamp_ns: i64, label: &str) -> AnnotationFlag {
    AnnotationFlag {
        id,
        timestamp_ns,
        label: label.into(),
        color_index: 0,
    }
}
#[test]
fn stale_deferred_edit_cannot_change_reused_id_in_replacement_session() {
    let mut s = state();
    run(
        &mut s,
        AnnotationAction::AddFlag {
            timestamp_ns: 10,
            label: None,
        },
        Default::default(),
    )
    .unwrap();
    run(
        &mut s,
        AnnotationAction::ReplaceSession {
            new_session_id: 2,
            bounds: Some(range(0, 1000)),
        },
        Default::default(),
    )
    .unwrap();
    run(
        &mut s,
        AnnotationAction::AddFlag {
            timestamp_ns: 20,
            label: Some("new"),
        },
        Default::default(),
    )
    .unwrap();
    assert_eq!(s.flags()[0].id, 1);
    for action in [
        AnnotationAction::UpdateFlag {
            id: 1,
            label: Some("stale"),
            color_index: Some(3),
        },
        AnnotationAction::RemoveFlag { id: 1 },
        AnnotationAction::CycleFlagColor { id: 1 },
    ] {
        assert_eq!(
            s.apply(
                AnnotationRequest {
                    api_version: 1,
                    session_id: 1,
                    context: Default::default(),
                    action
                },
                &mut || Ok(())
            ),
            Err(AnnotationError::StaleSession)
        );
        assert_eq!(s.flags()[0].label, "new");
        assert_eq!(s.flags()[0].color_index, 0);
    }
}
#[test]
fn transient_replacement_advances_maximum_id_and_color_without_overflow() {
    let mut s = state();
    let old = AnnotationMark {
        id: i64::MAX - 1,
        range: range(1, 5),
        label: "old transient".into(),
        color_index: i64::MAX,
        is_persistent: false,
    };
    s.restore(1, 1, &[], std::slice::from_ref(&old), &mut || Ok(()))
        .unwrap();
    run(
        &mut s,
        AnnotationAction::CycleMarkColor { id: old.id },
        Default::default(),
    )
    .unwrap();
    assert_eq!(s.marks()[0].color_index, 2);
    run(
        &mut s,
        AnnotationAction::AddMark {
            is_persistent: false,
            label: None,
        },
        AnnotationContext {
            selected_range: Some(range(10, 20)),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(s.marks().len(), 1);
    assert_eq!(s.marks()[0].id, i64::MAX);
    assert_eq!(s.marks()[0].range, range(10, 20));
    assert_eq!(s.next_id(), 1);
}
#[test]
fn maximum_id_restore_keeps_records_and_allocates_an_unused_identity() {
    let mut s = state();
    let original = [flag(i64::MAX, i64::MAX, "end"), flag(1, 30, "occupied")];
    s.restore(1, 1, &original, &[], &mut || Ok(())).unwrap();
    assert_eq!(s.next_id(), 1);
    run(
        &mut s,
        AnnotationAction::AddFlag {
            timestamp_ns: 10,
            label: None,
        },
        Default::default(),
    )
    .unwrap();
    assert_eq!(&s.flags()[..2], &original);
    assert_eq!(s.flags()[2].id, 2);
    assert_eq!(s.next_id(), 3);
    assert_eq!(
        flag(1, i64::MAX, "end").point_range().unwrap(),
        range(i64::MAX - 1, i64::MAX)
    );
    assert_eq!(flag(1, -10, "negative").point_range().unwrap(), range(0, 1));
}
#[test]
fn nearest_distance_is_total_over_extreme_restored_timestamps() {
    let mut s = state();
    s.restore(
        1,
        1,
        &[flag(3, i64::MIN, "min"), flag(2, i64::MAX, "max")],
        &[],
        &mut || Ok(()),
    )
    .unwrap();
    assert_eq!(s.nearest_flag(0, &mut || Ok(())).unwrap().unwrap().id, 2);
    assert_eq!(
        s.nearest_flag(i64::MIN, &mut || Ok(()))
            .unwrap()
            .unwrap()
            .id,
        3
    );
    assert_eq!(
        s.nearest_flag(i64::MAX, &mut || Ok(()))
            .unwrap()
            .unwrap()
            .id,
        2
    );
}
#[test]
fn flags_navigation_has_strict_timestamp_wrap_and_nearest_stable_tie() {
    let mut s = state();
    s.restore(
        1,
        1,
        &[
            flag(9, 100, "later id"),
            flag(1, 100, "first id"),
            flag(2, 300, "next"),
        ],
        &[],
        &mut || Ok(()),
    )
    .unwrap();
    assert_eq!(s.flag_after(100, &mut || Ok(())).unwrap().unwrap().id, 2);
    assert_eq!(s.flag_after(300, &mut || Ok(())).unwrap().unwrap().id, 1);
    assert_eq!(s.flag_before(100, &mut || Ok(())).unwrap().unwrap().id, 2);
    assert_eq!(s.flag_before(300, &mut || Ok(())).unwrap().unwrap().id, 9);
    assert_eq!(s.nearest_flag(200, &mut || Ok(())).unwrap().unwrap().id, 1);
}
#[test]
fn instant_selection_blocks_event_fallback_and_no_viewport_blocks_command() {
    let mut s = state();
    let context = AnnotationContext {
        selected_range: Some(range(4, 4)),
        selected_event_range: Some(range(10, 30)),
        ..Default::default()
    };
    assert!(
        run(
            &mut s,
            AnnotationAction::AddMark {
                is_persistent: true,
                label: None
            },
            context
        )
        .unwrap()
        .created
        .is_none()
    );
    assert!(s.is_empty());
    let context = AnnotationContext {
        selected_range: Some(range(3, 7)),
        ..Default::default()
    };
    assert!(
        run(
            &mut s,
            AnnotationAction::Command(AnnotationCommand::CreateMark {
                is_persistent: true
            }),
            context
        )
        .unwrap()
        .created
        .is_none()
    );
    assert!(
        run(
            &mut s,
            AnnotationAction::AddMark {
                is_persistent: true,
                label: None
            },
            context
        )
        .unwrap()
        .created
        .is_some()
    );
}
#[test]
fn unicode_byte_caps_and_failed_edit_are_atomic() {
    let mut s = state();
    let valid = "😀".repeat(1024);
    run(
        &mut s,
        AnnotationAction::AddFlag {
            timestamp_ns: 3,
            label: Some(&valid),
        },
        Default::default(),
    )
    .unwrap();
    let invalid = valid.clone() + "x";
    assert_eq!(
        run(
            &mut s,
            AnnotationAction::UpdateFlag {
                id: 1,
                label: Some(&invalid),
                color_index: Some(8)
            },
            Default::default()
        ),
        Err(AnnotationError::InputBudgetExceeded)
    );
    assert_eq!(s.flags()[0].label, valid);
    assert_eq!(s.flags()[0].color_index, 0);
    run(
        &mut s,
        AnnotationAction::UpdateFlag {
            id: 1,
            label: Some("e\u{301}"),
            color_index: None,
        },
        Default::default(),
    )
    .unwrap();
    assert_eq!(s.flags()[0].label.as_bytes(), "e\u{301}".as_bytes());
    run(
        &mut s,
        AnnotationAction::UpdateFlag {
            id: 1,
            label: Some(""),
            color_index: None,
        },
        Default::default(),
    )
    .unwrap();
    assert!(s.flags()[0].label.is_empty());
}
#[test]
fn input_record_and_retained_budgets_have_distinct_errors() {
    let mut s = AnnotationState::new(
        1,
        Some(range(0, 100)),
        AnnotationBudget {
            maximum_records: 1,
            ..Default::default()
        },
        &mut || Ok(()),
    )
    .unwrap();
    run(
        &mut s,
        AnnotationAction::AddFlag {
            timestamp_ns: 3,
            label: None,
        },
        Default::default(),
    )
    .unwrap();
    assert_eq!(
        run(
            &mut s,
            AnnotationAction::AddFlag {
                timestamp_ns: 4,
                label: None
            },
            Default::default()
        ),
        Err(AnnotationError::RetainedBudgetExceeded)
    );
    assert_eq!(s.flags().len(), 1);
    assert_eq!(s.next_id(), 2);
    assert_eq!(
        s.restore(1, 1, &[flag(3, 3, "a"), flag(4, 4, "b")], &[], &mut || Ok(
            ()
        )),
        Err(AnnotationError::InputBudgetExceeded)
    );
    let mut zero = AnnotationState::new(
        1,
        None,
        AnnotationBudget {
            maximum_input_bytes: 0,
            ..Default::default()
        },
        &mut || Ok(()),
    )
    .unwrap();
    assert_eq!(
        run(
            &mut zero,
            AnnotationAction::RemoveFlag { id: 0 },
            Default::default()
        ),
        Err(AnnotationError::InputBudgetExceeded)
    );
    let too_many: Vec<_> = (0..=MAXIMUM_ANNOTATION_RECORDS)
        .map(|i| flag(i64::from(i), 0, ""))
        .collect();
    assert_eq!(
        state().restore(1, 1, &too_many, &[], &mut || Ok(())),
        Err(AnnotationError::InputBudgetExceeded)
    );
}
#[test]
fn retained_byte_boundary_and_label_limit_are_enforced() {
    let base = state();
    let fixed = base.retained_bytes() as u32;
    assert_eq!(
        AnnotationState::new(
            1,
            None,
            AnnotationBudget {
                maximum_retained_bytes: fixed - 1,
                ..Default::default()
            },
            &mut || Ok(())
        )
        .unwrap_err(),
        AnnotationError::RetainedBudgetExceeded
    );
    let mut exact = AnnotationState::new(
        1,
        None,
        AnnotationBudget {
            maximum_retained_bytes: fixed,
            ..Default::default()
        },
        &mut || Ok(()),
    )
    .unwrap();
    assert_eq!(exact.retained_bytes(), u64::from(fixed));
    assert_eq!(
        exact.restore(1, 1, &[flag(1, 1, "x")], &[], &mut || Ok(())),
        Err(AnnotationError::RetainedBudgetExceeded)
    );
    assert!(exact.is_empty());
    let mut limited = AnnotationState::new(
        1,
        Some(range(0, 100)),
        AnnotationBudget {
            maximum_retained_label_bytes: 2,
            ..Default::default()
        },
        &mut || Ok(()),
    )
    .unwrap();
    assert_eq!(
        run(
            &mut limited,
            AnnotationAction::AddFlag {
                timestamp_ns: 1,
                label: Some("abc")
            },
            Default::default()
        ),
        Err(AnnotationError::RetainedBudgetExceeded)
    );
    assert_eq!(limited.next_id(), 1);
}
#[test]
fn cancellation_and_deadline_never_publish_partial_actions_and_next_request_succeeds() {
    let mut s = state();
    let flags: Vec<_> = (0..600).map(|i| flag(i, i, "old")).collect();
    s.restore(1, 1, &flags, &[], &mut || Ok(())).unwrap();
    for failure in [AnnotationError::Cancelled, AnnotationError::DeadlineReached] {
        let mut calls = 0;
        let mut check = || {
            calls += 1;
            if calls == 400 { Err(failure) } else { Ok(()) }
        };
        assert_eq!(
            s.apply(
                AnnotationRequest {
                    api_version: 1,
                    session_id: 1,
                    context: Default::default(),
                    action: AnnotationAction::UpdateFlag {
                        id: 599,
                        label: Some("edited"),
                        color_index: None
                    }
                },
                &mut check
            ),
            Err(failure)
        );
        assert_eq!(s.flags(), flags);
        assert_eq!(s.next_id(), 600);
    }
    run(
        &mut s,
        AnnotationAction::UpdateFlag {
            id: 599,
            label: Some("normal"),
            color_index: None,
        },
        Default::default(),
    )
    .unwrap();
    assert_eq!(s.flags()[599].label, "normal");
    let mut calls = 0;
    assert_eq!(
        s.persistence(&mut || {
            calls += 1;
            if calls == 300 {
                Err(AnnotationError::Cancelled)
            } else {
                Ok(())
            }
        }),
        Err(AnnotationError::Cancelled)
    );
    assert_eq!(s.flags()[599].label, "normal");
}
#[test]
fn persistence_excludes_transient_marks_without_sorting_or_viewport_dependence() {
    let mut s = state();
    run(
        &mut s,
        AnnotationAction::AddFlag {
            timestamp_ns: 900,
            label: Some("late"),
        },
        Default::default(),
    )
    .unwrap();
    run(
        &mut s,
        AnnotationAction::AddFlag {
            timestamp_ns: 100,
            label: Some("early"),
        },
        Default::default(),
    )
    .unwrap();
    for persistent in [true, false, true] {
        run(
            &mut s,
            AnnotationAction::AddMark {
                is_persistent: persistent,
                label: None,
            },
            AnnotationContext {
                selected_range: Some(range(4, 8)),
                ..Default::default()
            },
        )
        .unwrap();
    }
    let p = s.persistence(&mut || Ok(())).unwrap();
    assert_eq!(
        p.flags().iter().map(|f| f.timestamp_ns).collect::<Vec<_>>(),
        [900, 100]
    );
    assert_eq!(p.marks().len(), 2);
    assert!(p.marks().iter().all(|m| m.is_persistent));
    assert_eq!(s.marks().len(), 3);
    for vp in [range(0, 10), range(800, 1000)] {
        run(
            &mut s,
            AnnotationAction::Command(AnnotationCommand::ScrollNearestFlagIntoView),
            AnnotationContext {
                viewport_range: Some(vp),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(s.persistence(&mut || Ok(())).unwrap(), p);
    }
}
#[test]
fn restored_duplicates_edit_first_delete_all_and_restore_cursor_across_kinds() {
    let mut s = state();
    let flags = [flag(5, 30, "one"), flag(5, 20, "two")];
    let mark = AnnotationMark {
        id: 20,
        range: range(3, 7),
        label: "mark".into(),
        color_index: 0,
        is_persistent: true,
    };
    s.restore(1, 1, &flags, &[mark], &mut || Ok(())).unwrap();
    assert_eq!(s.next_id(), 21);
    run(
        &mut s,
        AnnotationAction::UpdateFlag {
            id: 5,
            label: Some("edited"),
            color_index: None,
        },
        Default::default(),
    )
    .unwrap();
    assert_eq!(s.flags()[0].label, "edited");
    assert_eq!(s.flags()[1].label, "two");
    run(
        &mut s,
        AnnotationAction::RemoveFlag { id: 5 },
        Default::default(),
    )
    .unwrap();
    assert!(s.flags().is_empty());
    assert_eq!(s.next_id(), 21);
}
#[test]
fn version_budget_and_session_exhaustion_are_explicit() {
    assert_eq!(
        AnnotationState::new(
            0,
            None,
            AnnotationBudget {
                maximum_records: MAXIMUM_ANNOTATION_RECORDS + 1,
                ..Default::default()
            },
            &mut || Ok(())
        )
        .unwrap_err(),
        AnnotationError::InvalidRequest
    );
    let mut s = AnnotationState::new(u64::MAX, None, Default::default(), &mut || Ok(())).unwrap();
    assert_eq!(
        run(
            &mut s,
            AnnotationAction::ReplaceSession {
                new_session_id: 0,
                bounds: None
            },
            Default::default()
        ),
        Err(AnnotationError::SessionExhausted)
    );
    assert_eq!(s.session_id(), u64::MAX);
    assert_eq!(
        s.restore(ANNOTATION_API_VERSION + 1, u64::MAX, &[], &[], &mut || Ok(
            ()
        )),
        Err(AnnotationError::UnsupportedVersion)
    );
    assert_eq!(
        run(
            &mut s,
            AnnotationAction::Command(AnnotationCommand::NextFlag),
            AnnotationContext {
                viewport_range: Some(range(3, 3)),
                ..Default::default()
            }
        ),
        Err(AnnotationError::InvalidRequest)
    );
}

#[test]
fn advancing_session_preserves_annotations_cursor_and_bounds_but_invalidates_old_edit() {
    let mut s = state();
    run(
        &mut s,
        AnnotationAction::AddFlag {
            timestamp_ns: 10,
            label: Some("kept"),
        },
        Default::default(),
    )
    .unwrap();
    let next = s.next_id();
    let bounds = s.bounds();
    run(
        &mut s,
        AnnotationAction::AdvanceSession { new_session_id: 2 },
        Default::default(),
    )
    .unwrap();
    assert_eq!(s.flags()[0].label, "kept");
    assert_eq!(s.next_id(), next);
    assert_eq!(s.bounds(), bounds);
    assert_eq!(
        s.apply(
            AnnotationRequest {
                api_version: 1,
                session_id: 1,
                context: Default::default(),
                action: AnnotationAction::RemoveFlag { id: 1 }
            },
            &mut || Ok(())
        ),
        Err(AnnotationError::StaleSession)
    );
    run(
        &mut s,
        AnnotationAction::UpdateFlag {
            id: 1,
            label: Some("fresh"),
            color_index: None,
        },
        Default::default(),
    )
    .unwrap();
    assert_eq!(s.flags()[0].label, "fresh");
    assert_eq!(s.next_id(), next);
}
