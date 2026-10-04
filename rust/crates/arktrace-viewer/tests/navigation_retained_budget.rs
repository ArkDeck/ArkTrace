use arktrace_contract::*;
use arktrace_viewer::*;

fn state() -> ViewState {
    let cases: serde_json::Value =
        serde_json::from_str(include_str!("fixtures/navigation-inputs.json")).unwrap();
    let facts: TrackCatalogFacts = serde_json::from_value(cases[0]["facts"].clone()).unwrap();
    ViewState {
        identity: ViewIdentity {
            session_id: 1,
            generation: 2,
        },
        tree: build_track_tree(&facts, &mut || Ok(())).unwrap(),
        catalog_threads: facts.threads,
        capabilities: facts.capabilities,
        bounds: None,
        viewport_range: None,
        process_filter_text: String::new(),
        favorite_track_ids: vec![],
        search_results: vec![],
        search_results_truncated: false,
        search_selection_index: None,
        pending_selection_key: None,
    }
}
fn apply(s: &ViewState, action: ViewAction) -> Result<ViewReduction, ViewerError> {
    reduce_view_action(
        s,
        &ViewActionRequest {
            identity: s.identity,
            action,
        },
        &mut || Ok(()),
    )
}
fn large_spare() -> String {
    String::with_capacity(MAXIMUM_VIEW_RETAINED_BYTES)
}

#[test]
fn every_tree_vector_and_string_spare_is_owned_and_rejected() {
    let good = state();
    let mut bad = good.clone();
    bad.tree
        .groups
        .reserve(MAXIMUM_VIEW_RETAINED_BYTES / std::mem::size_of::<TrackGroup>());
    assert_eq!(
        bad.tree.validate(&mut || Ok(())),
        Err(ViewerError::InputBudgetExceeded)
    );
    for field in 0..4 {
        let mut bad = good.clone();
        match field {
            0 => {
                let mut s = large_spare();
                s.push_str(&bad.tree.groups[0].id);
                bad.tree.groups[0].id = s;
            }
            1 => bad.tree.groups[0].title = large_spare(),
            2 => bad.tree.groups[0]
                .tracks
                .reserve(MAXIMUM_VIEW_RETAINED_BYTES / std::mem::size_of::<SidebarTrack>()),
            _ => bad.tree.groups[0].tracks[0].title = large_spare(),
        }
        assert_eq!(
            bad.tree.validate(&mut || Ok(())),
            Err(ViewerError::InputBudgetExceeded),
            "field {field}"
        );
    }
    good.validate(&mut || Ok(())).unwrap();
}

#[test]
fn state_aggregate_includes_nested_strings_and_empty_vectors() {
    let good = state();
    for field in 0..8 {
        let mut bad = good.clone();
        match field {
            0 => bad
                .catalog_threads
                .reserve(MAXIMUM_VIEW_RETAINED_BYTES / std::mem::size_of::<TraceThread>()),
            1 => bad.catalog_threads[0].name = Some(large_spare()),
            2 => bad.catalog_threads[0].process_name = Some(large_spare()),
            3 => bad.process_filter_text = large_spare(),
            4 => {
                bad.favorite_track_ids = Vec::with_capacity(
                    MAXIMUM_VIEW_RETAINED_BYTES / std::mem::size_of::<String>() + 1,
                )
            }
            5 => bad.favorite_track_ids.push(large_spare()),
            6 => {
                bad.search_results = Vec::with_capacity(
                    MAXIMUM_VIEW_RETAINED_BYTES / std::mem::size_of::<TraceSearchResult>() + 1,
                )
            }
            _ => bad.search_results.push(TraceSearchResult {
                kind: TraceSearchResultKind::Process,
                title: String::new(),
                subtitle: Some(large_spare()),
                process_key: None,
                thread_key: None,
                event_key: None,
                range: None,
            }),
        }
        assert_eq!(
            bad.validate(&mut || Ok(())),
            Err(ViewerError::InputBudgetExceeded),
            "field {field}"
        );
    }
    let mut aggregate = good.clone();
    aggregate.process_filter_text = String::with_capacity(MAXIMUM_VIEW_RETAINED_BYTES / 2);
    aggregate
        .favorite_track_ids
        .push(String::with_capacity(MAXIMUM_VIEW_RETAINED_BYTES / 2));
    assert_eq!(
        aggregate.validate(&mut || Ok(())),
        Err(ViewerError::InputBudgetExceeded)
    );
    good.validate(&mut || Ok(())).unwrap();
}

fn fill_to(s: &mut ViewState, target: usize) {
    if s.favorite_track_ids.is_empty() {
        s.favorite_track_ids = (0..1000).map(|_| String::new()).collect();
    }
    s.search_results = (0..1000)
        .map(|_| TraceSearchResult {
            kind: TraceSearchResultKind::Process,
            title: String::new(),
            subtitle: Some(String::new()),
            process_key: None,
            thread_key: None,
            event_key: None,
            range: None,
        })
        .collect();
    let mut remaining = target - s.retained_bytes(&mut || Ok(())).unwrap();
    for r in &mut s.search_results {
        for text in [&mut r.title, r.subtitle.as_mut().unwrap()] {
            let n = remaining.min(MAXIMUM_VIEW_TEXT_BYTES);
            *text = "x".repeat(n);
            remaining -= n;
        }
    }
    for text in &mut s.favorite_track_ids {
        let n = remaining.min(MAXIMUM_TRACK_ID_BYTES);
        *text = "x".repeat(n);
        remaining -= n;
    }
    assert_eq!(remaining, 0);
    assert_eq!(s.retained_bytes(&mut || Ok(())).unwrap(), target);
    s.validate(&mut || Ok(())).unwrap();
}

#[test]
fn favorite_growth_fails_before_publication_then_next_legal_request_recovers() {
    let mut input = state();
    input.favorite_track_ids = (0..4000).map(|_| String::new()).collect();
    fill_to(&mut input, MAXIMUM_VIEW_RETAINED_BYTES - 32 * 1024);
    assert_eq!(
        apply(
            &input,
            ViewAction::ToggleFavorite {
                id: "unknown".into()
            }
        ),
        Err(ViewerError::InputBudgetExceeded)
    );
    assert_eq!(input.favorite_track_ids.len(), 4000);
    let recovered = apply(&input, ViewAction::SetProcessFilter { text: "ok".into() }).unwrap();
    assert!(recovered.applied);
    assert!(recovered.retained_bytes(&mut || Ok(())).unwrap() <= MAXIMUM_VIEW_RETAINED_BYTES);
    // Growth is measured on a small successful result too; capacity exceeds len.
    let mut small = state();
    small.favorite_track_ids = vec!["unknown-a".into()];
    let compact = apply(
        &small,
        ViewAction::SetProcessFilter {
            text: String::new(),
        },
    )
    .unwrap();
    let grown = apply(
        &small,
        ViewAction::ToggleFavorite {
            id: "unknown-b".into(),
        },
    )
    .unwrap();
    assert!(grown.state.favorite_track_ids.capacity() > grown.state.favorite_track_ids.len());
    assert!(
        grown.retained_bytes(&mut || Ok(())).unwrap()
            > compact.retained_bytes(&mut || Ok(())).unwrap()
    );
}

#[test]
fn whole_reduction_includes_intents_and_stale_publication_checks_capacity() {
    let mut near_limit = state().clone();
    let overhead = std::mem::size_of::<ViewReduction>() - std::mem::size_of::<ViewState>();
    fill_to(&mut near_limit, MAXIMUM_VIEW_RETAINED_BYTES - overhead / 2);
    assert_eq!(
        apply(
            &near_limit,
            ViewAction::SetProcessFilter {
                text: String::new()
            }
        ),
        Err(ViewerError::InputBudgetExceeded)
    );
    let request = ViewActionRequest {
        identity: ViewIdentity {
            generation: 999,
            ..near_limit.identity
        },
        action: ViewAction::ActivateSearchResult,
    };
    assert_eq!(
        reduce_view_action(&near_limit, &request, &mut || Ok(())).map(|_| ()),
        Err(ViewerError::InputBudgetExceeded)
    );
    let output = apply(&state(), ViewAction::RevealTrackGroup { id: "cpu".into() }).unwrap();
    let extra = overhead
        + output
            .intents
            .scroll_group_id
            .as_ref()
            .map_or(0, String::capacity);
    assert_eq!(
        output.retained_bytes(&mut || Ok(())).unwrap(),
        output.state.retained_bytes(&mut || Ok(())).unwrap() + extra
    );
}

#[test]
fn borrowed_request_spare_is_not_transferred_and_cancellation_never_publishes() {
    let input = state();
    let mut text = large_spare();
    text.push_str("ok");
    let output = apply(&input, ViewAction::SetProcessFilter { text }).unwrap();
    assert_eq!(output.state.process_filter_text, "ok");
    assert!(output.state.process_filter_text.capacity() < MAXIMUM_VIEW_RETAINED_BYTES);
    assert_eq!(
        input.retained_bytes(&mut || Err(ViewerError::Cancelled)),
        Err(ViewerError::Cancelled)
    );
    let request = ViewActionRequest {
        identity: input.identity,
        action: ViewAction::ToggleFavorite { id: "cpu:0".into() },
    };
    let mut calls = 0;
    reduce_view_action(&input, &request, &mut || {
        calls += 1;
        Ok(())
    })
    .unwrap();
    for fail_at in [1, calls - 1, calls] {
        let mut actual = 0;
        assert_eq!(
            reduce_view_action(&input, &request, &mut || {
                actual += 1;
                if actual == fail_at {
                    Err(ViewerError::DeadlineReached)
                } else {
                    Ok(())
                }
            }),
            Err(ViewerError::DeadlineReached)
        );
    }
    apply(&input, ViewAction::ToggleFavorite { id: "cpu:0".into() }).unwrap();
}

#[test]
fn borrowed_catalog_spare_is_scan_bounded_and_zero_duration_output_is_checked() {
    let cases: serde_json::Value =
        serde_json::from_str(include_str!("fixtures/navigation-inputs.json")).unwrap();
    let mut facts: TrackCatalogFacts = serde_json::from_value(cases[0]["facts"].clone()).unwrap();
    facts
        .cpu_samples
        .reserve(MAXIMUM_VIEW_RETAINED_BYTES / std::mem::size_of::<CatalogCpuFact>());
    let tree = build_track_tree(&facts, &mut || Ok(())).unwrap();
    tree.validate(&mut || Ok(())).unwrap();
    facts.duration_ns = 0;
    let empty = build_track_tree(&facts, &mut || Ok(())).unwrap();
    assert!(empty.retained_bytes(&mut || Ok(())).unwrap() < MAXIMUM_VIEW_RETAINED_BYTES);
}
