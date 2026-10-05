use arktrace_contract::*;
use arktrace_viewer::*;

fn state() -> ViewState {
    let facts: serde_json::Value =
        serde_json::from_str(include_str!("fixtures/navigation-inputs.json")).unwrap();
    let facts: TrackCatalogFacts = serde_json::from_value(facts[1]["facts"].clone()).unwrap();
    ViewState {
        identity: ViewIdentity {
            session_id: 8,
            generation: 9,
        },
        tree: build_track_tree(&facts, &mut || Ok(())).unwrap(),
        catalog_threads: facts.threads,
        capabilities: facts.capabilities,
        bounds: Some(TraceTimeRange::query(0, 1000).unwrap()),
        viewport_range: Some(TraceTimeRange::query(0, 1000).unwrap()),
        process_filter_text: String::new(),
        favorite_track_ids: vec![],
        search_results: vec![],
        search_results_truncated: false,
        search_selection_index: None,
        pending_selection_key: None,
    }
}
fn apply(state: &ViewState, action: ViewAction) -> ViewReduction {
    reduce_view_action(
        state,
        &ViewActionRequest {
            identity: state.identity,
            action,
        },
        &mut || Ok(()),
    )
    .unwrap()
}

#[test]
fn stale_session_and_generation_actions_cannot_mutate_even_matching_track_ids() {
    let state = state();
    for identity in [
        ViewIdentity {
            session_id: 9,
            generation: 9,
        },
        ViewIdentity {
            session_id: 8,
            generation: 8,
        },
    ] {
        let output = reduce_view_action(
            &state,
            &ViewActionRequest {
                identity,
                action: ViewAction::ToggleFavorite {
                    id: "thread-state:1000".into(),
                },
            },
            &mut || Ok(()),
        )
        .unwrap();
        assert!(output.stale);
        assert!(!output.applied);
        assert_eq!(output.state, state);
        assert_eq!(output.intents, ViewIntents::default());
    }
}
#[test]
fn cancellation_deadline_and_output_over_budget_are_transactional_and_recoverable() {
    let state = state();
    let request = ViewActionRequest {
        identity: state.identity,
        action: ViewAction::ToggleTrack {
            id: "thread-state:1000".into(),
        },
    };
    for error in [ViewerError::Cancelled, ViewerError::DeadlineReached] {
        let mut checkpoints = 0;
        reduce_view_action(&state, &request, &mut || {
            checkpoints += 1;
            Ok(())
        })
        .unwrap();
        for abort_at in [1, checkpoints - 1, checkpoints] {
            let mut calls = 0;
            assert_eq!(
                reduce_view_action(&state, &request, &mut || {
                    calls += 1;
                    if calls == abort_at {
                        Err(error)
                    } else {
                        Ok(())
                    }
                })
                .unwrap_err(),
                error
            );
            assert!(
                reduce_view_action(&state, &request, &mut || Ok(()))
                    .unwrap()
                    .applied
            );
        }
    }
    let mut oversized = state.clone();
    oversized.favorite_track_ids = vec!["unknown".into(); MAXIMUM_STORED_FAVORITE_IDS];
    let request = ViewActionRequest {
        identity: state.identity,
        action: ViewAction::ToggleFavorite {
            id: "thread-state:1000".into(),
        },
    };
    assert_eq!(
        reduce_view_action(&oversized, &request, &mut || Ok(())).unwrap_err(),
        ViewerError::InputBudgetExceeded
    );
    assert_eq!(
        oversized.favorite_track_ids.len(),
        MAXIMUM_STORED_FAVORITE_IDS
    );
    assert!(
        reduce_view_action(&state, &request, &mut || Ok(()))
            .unwrap()
            .applied
    );
}
#[test]
fn restoration_preserves_unknown_ids_duplicates_order_and_hidden_depth() {
    let mut state = state();
    state
        .tree
        .groups
        .iter_mut()
        .flat_map(|g| &mut g.tracks)
        .for_each(|t| {
            t.descriptor.is_collapsed = true;
            t.descriptor.shows_nested_depth = false;
        });
    let ids = vec![
        "missing".into(),
        "thread-state:1008".into(),
        "cpu:0".into(),
        "thread-state:1008".into(),
    ];
    let restored = apply(&state, ViewAction::RestoreFavorites { ids });
    assert_eq!(
        restored.state.favorite_track_ids,
        ["missing", "thread-state:1008", "cpu:0", "thread-state:1008"]
    );
    assert_eq!(
        restored
            .state
            .favorite_tracks(&mut || Ok(()))
            .unwrap()
            .iter()
            .map(|t| t.id())
            .collect::<Vec<_>>(),
        ["thread-state:1008", "cpu:0"]
    );
    assert_eq!(restored.state.tree, state.tree);
    assert!(!restored.intents.persist_favorites);
    let pinned = apply(
        &restored.state,
        ViewAction::ToggleFavorite {
            id: "named-slice:1008".into(),
        },
    );
    let track = pinned.state.tree.track("named-slice:1008").unwrap();
    assert!(!track.descriptor.is_collapsed);
    assert!(!track.descriptor.shows_nested_depth);
    let removed = apply(
        &pinned.state,
        ViewAction::ToggleFavorite {
            id: "thread-state:1008".into(),
        },
    );
    assert_eq!(
        removed.state.favorite_track_ids,
        ["missing", "cpu:0", "named-slice:1008"]
    );
}
#[test]
fn favorite_reorder_uses_visible_indices_and_keeps_unknown_records() {
    let mut state = state();
    state.favorite_track_ids = [
        "missing",
        "thread-state:1000",
        "missing",
        "cpu:0",
        "thread-state:1000",
    ]
    .map(String::from)
    .to_vec();
    let reordered = apply(
        &state,
        ViewAction::MoveFavorite {
            source: 1,
            destination: 0,
        },
    );
    assert!(reordered.intents.persist_favorites);
    assert_eq!(
        reordered.state.favorite_track_ids,
        [
            "missing",
            "cpu:0",
            "thread-state:1000",
            "missing",
            "thread-state:1000"
        ]
    );
    let invalid = apply(
        &reordered.state,
        ViewAction::MoveFavorite {
            source: 2,
            destination: 0,
        },
    );
    assert!(!invalid.applied && !invalid.intents.persist_favorites);
    assert_eq!(
        invalid.state.favorite_track_ids,
        reordered.state.favorite_track_ids
    );
}
#[test]
fn unknown_favorites_are_retained_by_toggle_but_do_not_count_as_visible_pins() {
    let mut state = state();
    for i in 0..20 {
        state = apply(
            &state,
            ViewAction::ToggleFavorite {
                id: format!("unknown:{i}"),
            },
        )
        .state;
    }
    for i in 0..12 {
        state = apply(
            &state,
            ViewAction::ToggleFavorite {
                id: format!("thread-state:{}", 1000 + i),
            },
        )
        .state;
    }
    assert_eq!(state.favorite_tracks(&mut || Ok(())).unwrap().len(), 12);
    assert!(!apply(&state, ViewAction::ToggleFavorite { id: "cpu:0".into() }).applied);
    assert_eq!(state.favorite_track_ids.len(), 32);
}
#[test]
fn restoring_after_directory_change_uses_stable_identity_and_never_pid_or_title() {
    let mut state = state();
    let ids = vec!["thread-state:1000".into(), "thread-state:1001".into()];
    state.tree.groups.retain(|g| g.id != "process:0");
    let restored = apply(&state, ViewAction::RestoreFavorites { ids });
    assert_eq!(
        restored.state.favorite_track_ids,
        ["thread-state:1000", "thread-state:1001"]
    );
    assert_eq!(
        restored
            .state
            .favorite_tracks(&mut || Ok(()))
            .unwrap()
            .iter()
            .map(|t| t.id())
            .collect::<Vec<_>>(),
        ["thread-state:1001"]
    );
}
#[test]
fn malformed_wire_extra_fields_and_unbounded_inputs_are_rejected() {
    assert!(
        serde_json::from_str::<ViewAction>(r#"{"kind":"stepSearchResult","delta":1,"sql":"x"}"#)
            .is_err()
    );
    let state = state();
    let request = ViewActionRequest {
        identity: state.identity,
        action: ViewAction::SetSearchResults {
            truncated: false,
            items: vec![
                TraceSearchResult {
                    kind: TraceSearchResultKind::Process,
                    title: "a".into(),
                    subtitle: None,
                    process_key: None,
                    thread_key: None,
                    event_key: None,
                    range: None
                };
                1001
            ],
        },
    };
    assert_eq!(
        reduce_view_action(&state, &request, &mut || Ok(())).unwrap_err(),
        ViewerError::InputBudgetExceeded
    );
    let action = ViewAction::SetProcessFilter {
        text: "é".repeat(MAXIMUM_VIEW_TEXT_BYTES / 2) + "a",
    };
    assert_eq!(
        reduce_view_action(
            &state,
            &ViewActionRequest {
                identity: state.identity,
                action
            },
            &mut || Ok(())
        )
        .unwrap_err(),
        ViewerError::InputBudgetExceeded
    );
}
