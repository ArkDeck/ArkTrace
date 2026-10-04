use arktrace_viewer::*;
fn facts(index: usize) -> TrackCatalogFacts {
    let cases: serde_json::Value =
        serde_json::from_str(include_str!("fixtures/navigation-inputs.json")).unwrap();
    serde_json::from_value(cases[index]["facts"].clone()).unwrap()
}
#[test]
fn sample_count_not_duration_orders_processes_and_reused_pid_never_merges() {
    let tree = build_track_tree(&facts(0), &mut || Ok(())).unwrap();
    assert_eq!(
        tree.groups
            .iter()
            .map(|g| g.id.as_str())
            .collect::<Vec<_>>(),
        [
            "cpu",
            "cpu-counter",
            "process:2",
            "process:1",
            "process:77",
            "process:88",
            "unattributed"
        ]
    );
    assert_eq!(tree.groups[2].title, tree.groups[3].title);
    assert_ne!(tree.groups[2].tracks[0].id(), tree.groups[3].tracks[0].id());
    assert_eq!(
        tree.groups[2]
            .tracks
            .iter()
            .map(SidebarTrack::id)
            .collect::<Vec<_>>(),
        [
            "thread-state:200",
            "named-slice:200",
            "thread-state:201",
            "named-slice:201",
            "frame:2"
        ]
    );
    assert!(tree.track_list_truncated());
}
#[test]
fn counter_cap_is_assigned_before_lexical_sort_and_cpu_cap_after_numeric_sort() {
    let tree = build_track_tree(&facts(1), &mut || Ok(())).unwrap();
    assert!(!tree.track("cpu:15").unwrap().descriptor.is_collapsed);
    assert!(tree.track("cpu:16").unwrap().descriptor.is_collapsed);
    assert!(
        tree.track("cpu-counter:0:0")
            .unwrap()
            .descriptor
            .is_collapsed
    );
    assert!(
        !tree
            .track("cpu-counter:19:19")
            .unwrap()
            .descriptor
            .is_collapsed
    );
    assert!(
        !tree
            .groups
            .iter()
            .find(|g| g.id == "process:7")
            .unwrap()
            .tracks[0]
            .descriptor
            .is_collapsed
    );
    assert!(
        tree.groups
            .iter()
            .find(|g| g.id == "process:8")
            .unwrap()
            .tracks[0]
            .descriptor
            .is_collapsed
    );
}
#[test]
fn duplicate_internal_thread_identity_and_catalog_text_caps_fail_then_recover() {
    let good = facts(0);
    let mut bad = good.clone();
    bad.threads.push(bad.threads[0].clone());
    assert_eq!(
        build_track_tree(&bad, &mut || Ok(())).unwrap_err(),
        ViewerError::InvalidEvidence
    );
    bad = good.clone();
    bad.threads[0].name = Some("x".repeat(MAXIMUM_VIEW_TEXT_BYTES + 1));
    assert_eq!(
        build_track_tree(&bad, &mut || Ok(())).unwrap_err(),
        ViewerError::InputBudgetExceeded
    );
    bad = good.clone();
    bad.cpu_samples = vec![good.cpu_samples[0]; MAXIMUM_CATALOG_CPU_FACTS + 1];
    assert_eq!(
        build_track_tree(&bad, &mut || Ok(())).unwrap_err(),
        ViewerError::InputBudgetExceeded
    );
    assert!(build_track_tree(&good, &mut || Ok(())).is_ok());
}
#[test]
fn catalogue_and_title_matching_cancellation_leave_next_request_usable() {
    let facts = facts(1);
    assert_eq!(
        build_track_tree(&facts, &mut || Err(ViewerError::Cancelled)).unwrap_err(),
        ViewerError::Cancelled
    );
    let tree = build_track_tree(&facts, &mut || Ok(())).unwrap();
    struct Fail;
    impl SidebarTitleMatcher for Fail {
        fn contains_case_insensitive(&mut self, _: &str, _: &str) -> Result<bool, ViewerError> {
            Err(ViewerError::DeadlineReached)
        }
    }
    assert_eq!(
        filtered_group_indices(&tree, "CPU", &mut Fail, &mut || Ok(())).unwrap_err(),
        ViewerError::DeadlineReached
    );
    assert_eq!(
        filtered_group_indices(&tree, "\u{200b}\u{85}\u{a0}", &mut Fail, &mut || Ok(()))
            .unwrap()
            .len(),
        tree.groups.len()
    );
}
