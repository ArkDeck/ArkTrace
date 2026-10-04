use arktrace_contract::*;
use arktrace_viewer::*;
fn range(a: i64, b: i64) -> TraceTimeRange {
    TraceTimeRange::event(a, b).unwrap()
}
fn event(table: EventTable, id: i64, time: i64) -> NavigationEvent {
    NavigationEvent {
        key: EventKey { table, row_id: id },
        range: range(time, time),
        is_open_ended: false,
    }
}
#[test]
fn search_selection_empty_delta_extremes_and_invalid_cursor_never_wrap() {
    assert_eq!(step_search_index(0, None, 1), None);
    assert_eq!(step_search_index(3, None, 0), None);
    assert_eq!(step_search_index(3, None, i64::MAX), Some(0));
    assert_eq!(step_search_index(3, None, i64::MIN), Some(2));
    assert_eq!(step_search_index(3, Some(1), 1), Some(2));
    assert_eq!(step_search_index(3, Some(2), 1), None);
    assert_eq!(step_search_index(3, Some(0), -1), None);
    assert_eq!(step_search_index(3, Some(50), -49), None);
    assert_eq!(step_search_index(3, Some(1), i64::MAX), None);
    assert_eq!(step_search_index(3, Some(1), i64::MIN), None);
}
#[test]
fn reveal_instant_open_range_edges_and_overflow_are_integer_exact() {
    let bounds = range(0, 1000);
    assert_eq!(
        reveal_range(range(200, 200), bounds).unwrap(),
        Some(range(199, 201))
    );
    assert_eq!(
        reveal_range(range(0, 50), bounds).unwrap(),
        Some(range(0, 100))
    );
    assert_eq!(
        reveal_range(range(950, 1000), bounds).unwrap(),
        Some(range(900, 1000))
    );
    let maximum = range(0, i64::MAX);
    assert_eq!(
        reveal_range(range(i64::MAX - 10, i64::MAX), maximum).unwrap(),
        Some(range(i64::MAX - 50, i64::MAX))
    );
    assert_eq!(reveal_range(maximum, maximum).unwrap(), Some(maximum));
    assert_eq!(reveal_range(range(0, 0), range(0, 0)).unwrap(), None);
    assert_eq!(reveal_range(range(2000, 2001), bounds).unwrap(), None);
}
#[test]
fn displayed_event_step_uses_real_keys_first_lane_and_raw_table_order() {
    let mut open = event(EventTable::SchedSlice, 99, 10);
    open.is_open_ended = true;
    let lanes = vec![
        NavigationLane {
            track_id: "cpu:0".into(),
            events: vec![
                open.clone(),
                event(EventTable::Callstack, 80, 10),
                event(EventTable::FrameSlice, 1, 10),
            ],
        },
        NavigationLane {
            track_id: "cpu:1".into(),
            events: vec![open],
        },
    ];
    let next = step_displayed_event(&lanes, None, None, 1, &mut || Ok(()))
        .unwrap()
        .unwrap();
    assert_eq!(
        next.key,
        EventKey {
            table: EventTable::Callstack,
            row_id: 80
        }
    );
    let last = step_displayed_event(&lanes, None, None, -1, &mut || Ok(()))
        .unwrap()
        .unwrap();
    assert_eq!(last.key.row_id, 99);
    assert_eq!(
        step_displayed_event(&lanes, Some(&last), None, i64::MAX, &mut || Ok(())).unwrap(),
        None
    );
    let duplicate = EventFocus {
        track_id: "cpu:1".into(),
        key: last.key,
    };
    let moved = step_displayed_event(&lanes, Some(&duplicate), None, -1, &mut || Ok(()))
        .unwrap()
        .unwrap();
    assert_eq!(moved.track_id, "cpu:0");
    assert_eq!(moved.key.table, EventTable::FrameSlice);
}
#[test]
fn track_step_skips_empty_lanes_and_nearest_ties_keep_sorted_real_event() {
    let lanes = vec![
        NavigationLane {
            track_id: "cpu:0".into(),
            events: vec![event(EventTable::SchedSlice, 1, 100)],
        },
        NavigationLane {
            track_id: "cpu:1".into(),
            events: vec![],
        },
        NavigationLane {
            track_id: "cpu:2".into(),
            events: vec![
                event(EventTable::Callstack, 2, 110),
                event(EventTable::Callstack, 3, 90),
            ],
        },
    ];
    let focus = EventFocus {
        track_id: "cpu:0".into(),
        key: lanes[0].events[0].key,
    };
    let next = step_displayed_track(&lanes, Some(&focus), None, range(0, 200), 1, &mut || Ok(()))
        .unwrap()
        .unwrap();
    assert_eq!(next.track_id, "cpu:2");
    assert_eq!(next.key.row_id, 3);
    assert_eq!(
        step_displayed_track(
            &lanes,
            Some(&focus),
            None,
            range(0, 200),
            i64::MIN,
            &mut || Ok(())
        )
        .unwrap(),
        None
    );
}
#[test]
fn focus_anchor_chain_keeps_selection_midpoint_and_real_focus_start_at_large_time() {
    let viewport = range(i64::MAX - 100, i64::MAX);
    let selection = range(i64::MAX - 90, i64::MAX - 70);
    let event = range(i64::MAX - 99, i64::MAX - 99);
    assert_eq!(
        navigation_zoom_anchor(
            viewport,
            Some(selection),
            Some(event),
            Some(i64::MAX - 3),
            true
        ),
        i64::MAX - 3
    );
    assert_eq!(
        navigation_zoom_anchor(
            viewport,
            Some(selection),
            Some(event),
            Some(i64::MAX - 3),
            false
        ),
        i64::MAX - 80
    );
    assert_eq!(
        navigation_zoom_anchor(viewport, None, Some(event), None, true),
        i64::MAX - 99
    );
    assert_eq!(
        navigation_zoom_anchor(viewport, None, None, None, true),
        i64::MAX - 50
    );
}
#[test]
fn repository_navigation_is_only_bounded_query_intent_and_has_no_invented_result() {
    let intent = EventNavigationQueryIntent {
        identity: ViewIdentity {
            session_id: 1,
            generation: 2,
        },
        source: TraceDensitySource::NamedSlice { thread: None },
        anchor_ns: i64::MAX,
        after_event: Some(EventKey {
            table: EventTable::Callstack,
            row_id: 5,
        }),
        direction: EventNavigationDirection::Next,
        limit: 1000,
    };
    assert!(intent.validate().is_ok());
    assert!(
        EventNavigationQueryIntent {
            limit: 1001,
            ..intent.clone()
        }
        .validate()
        .is_err()
    );
    assert!(
        EventNavigationQueryIntent {
            anchor_ns: -1,
            ..intent
        }
        .validate()
        .is_err()
    );
    assert_eq!(
        step_displayed_event(&[], None, None, 1, &mut || Ok(())).unwrap(),
        None
    );
}
