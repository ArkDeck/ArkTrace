use arktrace_contract::{EventKey, EventTable};
use arktrace_viewer::*;

fn identity() -> SnapshotEventIndexIdentity {
    SnapshotEventIndexIdentity {
        view: ViewIdentity {
            session_id: 4,
            generation: 7,
        },
        snapshot_revision: 9,
    }
}
fn key(table: EventTable, row_id: i64) -> EventKey {
    EventKey { table, row_id }
}
fn detail(k: EventKey, has_inspector: bool) -> SnapshotEventPrimitiveFact {
    SnapshotEventPrimitiveFact::Detail {
        event_key: k,
        has_inspector,
    }
}
fn tracks(facts: &[Vec<SnapshotEventPrimitiveFact>]) -> Vec<SnapshotEventTrackFacts<'_>> {
    facts
        .iter()
        .map(|primitives| SnapshotEventTrackFacts { primitives })
        .collect()
}
fn matched(
    track_index: u32,
    primitive_index: u32,
    has_inspector: bool,
) -> SnapshotEventIndexLookup {
    SnapshotEventIndexLookup::Matched {
        location: SnapshotEventLocation {
            track_index,
            primitive_index,
            has_inspector,
        },
    }
}
#[test]
fn first_nil_inspector_blocks_later_duplicates_and_density_preserves_offsets() {
    let k = key(EventTable::Callstack, -1);
    let facts = vec![
        vec![
            SnapshotEventPrimitiveFact::Density {},
            detail(k, false),
            detail(k, true),
        ],
        vec![detail(k, true)],
    ];
    let index = build_snapshot_event_index(identity(), &tracks(&facts), &mut || Ok(())).unwrap();
    assert_eq!(index.len(), 1);
    assert_eq!(
        index.lookup(identity(), Some(k), &mut || Ok(())).unwrap(),
        matched(0, 1, false)
    );
    assert_eq!(
        index.lookup(identity(), None, &mut || Ok(())).unwrap(),
        SnapshotEventIndexLookup::NoMatch
    );
    assert_eq!(
        index
            .lookup(identity(), Some(key(EventTable::Measure, -1)), &mut || Ok(
                ()
            ))
            .unwrap(),
        SnapshotEventIndexLookup::NoMatch
    );
}
#[test]
fn signed_rows_and_all_six_table_identities_are_distinct() {
    let tables = [
        EventTable::SchedSlice,
        EventTable::ThreadState,
        EventTable::Callstack,
        EventTable::Measure,
        EventTable::ProcessMeasure,
        EventTable::FrameSlice,
    ];
    let mut facts = vec![vec![]];
    for table in tables {
        for row in [i64::MIN, -1, 0, i64::MAX] {
            facts[0].push(detail(key(table, row), true));
        }
    }
    let index = build_snapshot_event_index(identity(), &tracks(&facts), &mut || Ok(())).unwrap();
    assert_eq!(index.len(), 24);
    for (pi, fact) in facts[0].iter().enumerate() {
        if let SnapshotEventPrimitiveFact::Detail { event_key, .. } = fact {
            assert_eq!(
                index
                    .lookup(identity(), Some(*event_key), &mut || Ok(()))
                    .unwrap(),
                matched(0, pi as u32, true)
            );
        }
    }
}
#[test]
fn equal_generation_replacement_session_and_generation_all_reject_old_index() {
    let k = key(EventTable::SchedSlice, 1);
    let mut facts = vec![vec![detail(k, false)]];
    let old = build_snapshot_event_index(identity(), &tracks(&facts), &mut || Ok(())).unwrap();
    facts[0] = vec![SnapshotEventPrimitiveFact::Density {}, detail(k, true)];
    let mut replacement = identity();
    replacement.snapshot_revision += 1;
    let new = build_snapshot_event_index(replacement, &tracks(&facts), &mut || Ok(())).unwrap();
    assert_eq!(
        new.lookup(replacement, Some(k), &mut || Ok(())).unwrap(),
        matched(0, 1, true)
    );
    assert_eq!(
        old.lookup(identity(), Some(k), &mut || Ok(())).unwrap(),
        matched(0, 0, false)
    );
    for field in 0..3 {
        let mut changed = identity();
        match field {
            0 => changed.view.session_id += 1,
            1 => changed.view.generation += 1,
            _ => changed.snapshot_revision += 1,
        }
        for q in [Some(k), None] {
            assert_eq!(
                old.lookup(changed, q, &mut || Ok(())),
                Err(SnapshotEventIndexError::StaleSnapshot)
            );
        }
    }
    // Owner must use its CURRENT token before dereference; the index cannot discover replacement itself.
    assert_eq!(
        old.validate_identity(replacement, &mut || Ok(())),
        Err(SnapshotEventIndexError::StaleSnapshot)
    );
    drop(facts);
    assert_eq!(
        new.lookup(replacement, Some(k), &mut || Ok(())).unwrap(),
        matched(0, 1, true)
    );
}
#[test]
fn maximum_identity_values_are_opaque_and_do_not_increment_or_wrap() {
    let id = SnapshotEventIndexIdentity {
        view: ViewIdentity {
            session_id: u64::MAX,
            generation: u64::MAX,
        },
        snapshot_revision: u64::MAX,
    };
    let index = build_snapshot_event_index(id, &[], &mut || Ok(())).unwrap();
    assert_eq!(index.identity(), id);
    assert_eq!(
        index.lookup(id, None, &mut || Ok(())).unwrap(),
        SnapshotEventIndexLookup::NoMatch
    );
}
#[test]
fn density_cannot_deserialize_a_selectable_key_or_inspector_flag() {
    for text in [
        r#"{"kind":"density","eventKey":{"table":"sched_slice","rowID":1}}"#,
        r#"{"kind":"density","hasInspector":true}"#,
    ] {
        assert!(serde_json::from_str::<SnapshotEventPrimitiveFact>(text).is_err());
    }
    assert_eq!(
        serde_json::from_str::<SnapshotEventPrimitiveFact>(r#"{"kind":"density"}"#).unwrap(),
        SnapshotEventPrimitiveFact::Density {}
    );
}
#[test]
fn logical_count_limits_include_density_and_empty_tracks_before_allocation() {
    let empty = vec![vec![]; MAXIMUM_TRACKS];
    let index = build_snapshot_event_index(identity(), &tracks(&empty), &mut || Ok(())).unwrap();
    assert_eq!(index.source_track_count(), MAXIMUM_TRACKS);
    let too_many = vec![vec![]; MAXIMUM_TRACKS + 1];
    assert!(matches!(
        build_snapshot_event_index(identity(), &tracks(&too_many), &mut || Ok(())),
        Err(SnapshotEventIndexError::Viewer(
            ViewerError::InputBudgetExceeded
        ))
    ));
    let maximum = vec![vec![
        SnapshotEventPrimitiveFact::Density {};
        MAXIMUM_PRIMITIVES
    ]];
    assert_eq!(
        build_snapshot_event_index(identity(), &tracks(&maximum), &mut || Ok(()))
            .unwrap()
            .source_primitive_count(),
        MAXIMUM_PRIMITIVES
    );
    let too_many = vec![vec![
        SnapshotEventPrimitiveFact::Density {};
        MAXIMUM_PRIMITIVES + 1
    ]];
    assert!(matches!(
        build_snapshot_event_index(identity(), &tracks(&too_many), &mut || Ok(())),
        Err(SnapshotEventIndexError::Viewer(
            ViewerError::InputBudgetExceeded
        ))
    ));
    assert!(
        build_snapshot_event_index(identity(), &[], &mut || Ok(()))
            .unwrap()
            .is_empty()
    );
}
#[test]
fn owned_capacity_remains_charged_after_dedup_and_input_spare_stays_borrowed() {
    let k = key(EventTable::Callstack, 4);
    let single = vec![vec![detail(k, true)]];
    let one = build_snapshot_event_index(identity(), &tracks(&single), &mut || Ok(())).unwrap();
    let duplicates = vec![vec![detail(k, false); MAXIMUM_PRIMITIVES]];
    let full =
        build_snapshot_event_index(identity(), &tracks(&duplicates), &mut || Ok(())).unwrap();
    assert_eq!(full.len(), 1);
    assert_eq!(full.source_detail_count(), MAXIMUM_PRIMITIVES);
    assert!(full.retained_bytes() > one.retained_bytes() * 100);
    assert!(full.retained_bytes() <= MAXIMUM_SNAPSHOT_EVENT_INDEX_RETAINED_BYTES);
    assert!(matches!(
        build_snapshot_event_index_with_budget(
            identity(),
            &tracks(&duplicates),
            full.retained_bytes() - 1,
            &mut || Ok(())
        ),
        Err(SnapshotEventIndexError::Viewer(
            ViewerError::InputBudgetExceeded
        ))
    ));
    assert_eq!(
        build_snapshot_event_index_with_budget(
            identity(),
            &tracks(&duplicates),
            full.retained_bytes(),
            &mut || Ok(())
        )
        .unwrap()
        .retained_bytes(),
        full.retained_bytes()
    );
    let mut spare = Vec::with_capacity(MAXIMUM_PRIMITIVES * 3);
    spare.push(detail(k, true));
    let borrowed = vec![spare];
    let index = build_snapshot_event_index_with_budget(
        identity(),
        &tracks(&borrowed),
        one.retained_bytes(),
        &mut || Ok(()),
    )
    .unwrap();
    assert_eq!(index.retained_bytes(), one.retained_bytes());
    assert_eq!(index.source_primitive_count(), 1);
    // Input allocation belongs to host and is not copied into index ownership.
    println!(
        "snapshot-event-index retained: empty={} single={} duplicate_20000={} input_fact={} track_slice={}",
        std::mem::size_of::<SnapshotEventIndex>(),
        one.retained_bytes(),
        full.retained_bytes(),
        std::mem::size_of::<SnapshotEventPrimitiveFact>(),
        std::mem::size_of::<SnapshotEventTrackFacts<'_>>()
    );
}
#[test]
fn budget_failure_recovers_and_empty_still_accounts_inline_index() {
    let inline = std::mem::size_of::<SnapshotEventIndex>();
    for budget in [0, MAXIMUM_SNAPSHOT_EVENT_INDEX_RETAINED_BYTES + 1] {
        assert!(matches!(
            build_snapshot_event_index_with_budget(identity(), &[], budget, &mut || Ok(())),
            Err(SnapshotEventIndexError::Viewer(ViewerError::InvalidRequest))
        ));
    }
    assert!(matches!(
        build_snapshot_event_index_with_budget(identity(), &[], inline - 1, &mut || Ok(())),
        Err(SnapshotEventIndexError::Viewer(
            ViewerError::InputBudgetExceeded
        ))
    ));
    let good =
        build_snapshot_event_index_with_budget(identity(), &[], inline, &mut || Ok(())).unwrap();
    assert_eq!(good.retained_bytes(), inline);
    assert_eq!(
        good.lookup(identity(), None, &mut || Ok(())).unwrap(),
        SnapshotEventIndexLookup::NoMatch
    );
}
#[test]
fn cancellation_and_deadline_at_every_build_checkpoint_are_all_or_error_and_recover() {
    let facts = vec![
        (0..192)
            .rev()
            .map(|r| detail(key(EventTable::Measure, r % 71), r % 3 != 0))
            .collect(),
    ];
    let ts = tracks(&facts);
    let mut calls = 0;
    let good = build_snapshot_event_index(identity(), &ts, &mut || {
        calls += 1;
        Ok(())
    })
    .unwrap();
    assert!(calls > 15); // Reaches preflight, population, heapsort and dedup.
    for error in [ViewerError::Cancelled, ViewerError::DeadlineReached] {
        for fail_at in 1..=calls {
            let mut seen = 0;
            let result = build_snapshot_event_index(identity(), &ts, &mut || {
                seen += 1;
                if seen == fail_at { Err(error) } else { Ok(()) }
            });
            assert!(
                matches!(result,Err(SnapshotEventIndexError::Viewer(e)) if e==error),
                "{error:?} checkpoint {fail_at}/{calls}"
            );
        }
        let rebuilt = build_snapshot_event_index(identity(), &ts, &mut || Ok(())).unwrap();
        assert_eq!(rebuilt.len(), good.len());
        assert_eq!(
            rebuilt
                .lookup(
                    identity(),
                    Some(key(EventTable::Measure, 1)),
                    &mut || Ok(())
                )
                .unwrap(),
            good.lookup(
                identity(),
                Some(key(EventTable::Measure, 1)),
                &mut || Ok(())
            )
            .unwrap()
        );
    }
}
#[test]
fn every_lookup_checkpoint_including_final_gate_rejects_and_recovers() {
    let facts = vec![
        (0..257)
            .map(|r| detail(key(EventTable::FrameSlice, r), true))
            .collect(),
    ];
    let index = build_snapshot_event_index(identity(), &tracks(&facts), &mut || Ok(())).unwrap();
    for q in [
        None,
        Some(key(EventTable::FrameSlice, 128)),
        Some(key(EventTable::FrameSlice, 999)),
    ] {
        let mut calls = 0;
        let expected = index
            .lookup(identity(), q, &mut || {
                calls += 1;
                Ok(())
            })
            .unwrap();
        for error in [ViewerError::Cancelled, ViewerError::DeadlineReached] {
            for fail_at in 1..=calls {
                let mut seen = 0;
                assert_eq!(
                    index.lookup(identity(), q, &mut || {
                        seen += 1;
                        if seen == fail_at { Err(error) } else { Ok(()) }
                    }),
                    Err(SnapshotEventIndexError::Viewer(error))
                );
            }
            assert_eq!(
                index.lookup(identity(), q, &mut || Ok(())).unwrap(),
                expected
            );
        }
    }
}
#[test]
fn reverse_sorted_unique_and_duplicate_inputs_keep_original_positions() {
    for count in [0, 1, 2, 3, 4, 5, 6, 17, 257, MAXIMUM_PRIMITIVES] {
        let facts = vec![
            (0..count)
                .rev()
                .map(|r| detail(key(EventTable::SchedSlice, r as i64), true))
                .collect(),
        ];
        let index =
            build_snapshot_event_index(identity(), &tracks(&facts), &mut || Ok(())).unwrap();
        assert_eq!(index.len(), count);
        for r in 0..count {
            assert_eq!(
                index
                    .lookup(
                        identity(),
                        Some(key(EventTable::SchedSlice, r as i64)),
                        &mut || Ok(())
                    )
                    .unwrap(),
                matched(0, (count - r - 1) as u32, true)
            );
        }
    }
}
