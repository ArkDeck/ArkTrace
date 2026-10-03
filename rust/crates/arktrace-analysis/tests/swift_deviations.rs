//! Independently recorded behavior differences, kept outside the 23 parity
//! vectors. Integration must review these instead of broadening normalization.
use arktrace_analysis::*;
use arktrace_contract::*;
use serde_json::Value;

fn page<T>(items: Vec<T>) -> EventPage<T> {
    EventPage {
        items,
        truncated: false,
        capability_available: true,
        data_quality: DataQuality::machine(QualityStatus::Ok, vec![]).unwrap(),
    }
}
#[test]
fn open_ended_runnable_does_not_prove_an_observed_boundary() {
    let inputs: Value =
        serde_json::from_str(include_str!("fixtures/deviation-inputs.json")).unwrap();
    let oracle: Value =
        serde_json::from_str(include_str!("fixtures/swift-deviations.json")).unwrap();
    assert_eq!(oracle[0]["name"], inputs[0]["name"]);
    // Historical Swift inferred a transition from the normalized endpoint.
    // The mainline oracle separately verifies the corrected shared behavior.
    assert_eq!(oracle[0]["result"]["schedulingLatency"]["supported"], true);
    assert_eq!(oracle[0]["result"]["schedulingLatency"]["count"], 1);
    let cpu = page(serde_json::from_value::<Vec<CpuSlice>>(inputs[0]["cpuRows"].clone()).unwrap());
    let states = page(
        serde_json::from_value::<Vec<ThreadStateInterval>>(inputs[0]["stateRows"].clone()).unwrap(),
    );
    let rust = scheduling_latency(
        &cpu,
        &states,
        RunnableSemantics::ProvenNormalizedIntervals,
        20,
        &mut || Ok(()),
    )
    .unwrap();
    assert!(!rust.supported);
    assert_eq!(rust.count, 0);
    assert_eq!(
        rust.unsupported_reason,
        Some(SchedulingUnsupportedReason::NoProvableRunnableTransitions)
    );
}
#[test]
fn unicode_state_grouping_matches_canonical_equivalence_and_preserves_source_label() {
    let inputs: Value =
        serde_json::from_str(include_str!("fixtures/deviation-inputs.json")).unwrap();
    let oracle: Value =
        serde_json::from_str(include_str!("fixtures/swift-deviations.json")).unwrap();
    assert_eq!(oracle[1]["name"], inputs[1]["name"]);
    let states =
        serde_json::from_value::<Vec<ThreadStateInterval>>(inputs[1]["stateRows"].clone()).unwrap();
    let request: AnalysisRequest = serde_json::from_value(inputs[1]["request"].clone()).unwrap();
    // The historical oracle is retained unchanged. Normalize the grouping key,
    // keeping Swift's first raw label rather than rewriting the reported text.
    let swift = oracle[1]["result"]["threadStateDistribution"]
        .as_array()
        .unwrap();
    assert_eq!(swift.len(), 1);
    assert_eq!(swift[0]["durationNs"], 60);
    let rust = state_distribution(&states, request.range, &mut || Ok(())).unwrap();
    assert_eq!(rust.len(), 1);
    assert_eq!(rust.iter().map(|r| r.duration_ns).sum::<i64>(), 60);
    assert_eq!(
        rust.iter()
            .map(|r| r.raw_state.as_str())
            .collect::<Vec<_>>(),
        [swift[0]["rawState"].as_str().unwrap()]
    );
}
