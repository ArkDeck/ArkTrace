use arktrace_contract::TraceTimeRange;
use arktrace_viewer::*;
use std::mem::size_of;

fn projection() -> (AnnotationState, AnnotationPersistence) {
    let mut state =
        AnnotationState::new(1, None, AnnotationBudget::default(), &mut || Ok(())).unwrap();
    let flags = [AnnotationFlag {
        id: 1,
        timestamp_ns: 2,
        label: "标注".into(),
        color_index: 0,
    }];
    let marks: Vec<_> = (0..100)
        .map(|i| AnnotationMark {
            id: i + 2,
            range: TraceTimeRange::event(i, i + 1).unwrap(),
            label: "保留".into(),
            color_index: i,
            is_persistent: i == 3 || i == 90,
        })
        .collect();
    state.restore(1, 1, &flags, &marks, &mut || Ok(())).unwrap();
    let projection = state.persistence(&mut || Ok(())).unwrap();
    (state, projection)
}
fn bytes(p: &AnnotationPersistence, flags_capacity: usize, marks_capacity: usize) -> u64 {
    (size_of::<AnnotationPersistence>()
        + flags_capacity * size_of::<AnnotationFlag>()
        + marks_capacity * size_of::<AnnotationMark>()
        + p.flags().iter().map(|f| f.label.capacity()).sum::<usize>()
        + p.marks().iter().map(|m| m.label.capacity()).sum::<usize>()) as u64
}
#[test]
fn projection_counts_spare_slots_for_filtered_marks() {
    let (state, p) = projection();
    assert_eq!(p.api_version(), ANNOTATION_API_VERSION);
    assert_eq!(p.flags(), state.flags());
    assert_eq!(p.marks().iter().map(|m| m.id).collect::<Vec<_>>(), [5, 92]);
    assert_eq!(p.retained_bytes(), bytes(&p, 1, 100));
    assert!(p.retained_bytes() > bytes(&p, 1, p.marks().len()));
    assert!(p.retained_bytes() <= u64::from(MAXIMUM_ANNOTATION_RETAINED_BYTES));
}
#[test]
fn clone_reports_its_current_capacity_and_serializes_that_measurement() {
    let (_, p) = projection();
    let cloned = p.clone();
    assert_eq!(cloned, p);
    assert_eq!(cloned.retained_bytes(), bytes(&cloned, 1, 2));
    assert!(cloned.retained_bytes() < p.retained_bytes());
    for current in [&p, &cloned] {
        let json = serde_json::to_value(current).unwrap();
        assert_eq!(
            json["retainedBytes"].as_u64(),
            Some(current.retained_bytes())
        );
        assert_eq!(json["apiVersion"], ANNOTATION_API_VERSION);
        assert_eq!(json["marks"].as_array().unwrap().len(), 2);
    }
}
#[test]
fn read_only_projection_is_independent_of_owner_replacement() {
    let (mut state, p) = projection();
    let original = serde_json::to_value(&p).unwrap();
    state.restore(1, 1, &[], &[], &mut || Ok(())).unwrap();
    assert!(state.is_empty());
    assert!(!p.is_empty());
    assert_eq!(serde_json::to_value(&p).unwrap(), original);
    assert_eq!(p.retained_bytes(), bytes(&p, 1, 100));
}
#[test]
fn host_budget_counts_live_state_each_projection_and_encoding_separately() {
    let (state, p) = projection();
    let cloned = p.clone();
    let encoded = serde_json::to_vec(&p).unwrap();
    let live = state.retained_bytes() + p.retained_bytes() + cloned.retained_bytes();
    let total = live + encoded.capacity() as u64;
    assert!(live > state.retained_bytes() + p.retained_bytes());
    assert!(total > live);
    // A per-value cap does not authorize this combined allocation. The owner
    // must admit/release projection, clones and encoding against its own cap.
    let owner_cap = state.retained_bytes() + p.retained_bytes();
    assert!(total > owner_cap);
}
