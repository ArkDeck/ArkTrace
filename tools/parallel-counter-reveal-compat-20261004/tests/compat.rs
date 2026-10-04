use arktrace_counter_reveal_compat::{Case, flow_observation, intent_observation};
use serde_json::Value;
use std::{env, fs};
fn inputs() -> (Vec<Case>, Vec<Value>) {
    (
        serde_json::from_slice(&fs::read(env::var("COUNTER_REVEAL_CASES").unwrap()).unwrap())
            .unwrap(),
        serde_json::from_slice(&fs::read(env::var("COUNTER_REVEAL_SWIFT").unwrap()).unwrap())
            .unwrap(),
    )
}
#[test]
fn wrong_physical_tables_are_rejected_and_shape_validation_keeps_source_identity() {
    let (cases, _) = inputs();
    let mut invalid = 0;
    let mut shape = 0;
    for case in cases.iter().filter(|c| c.expected != "legal") {
        let output = intent_observation(case);
        assert_eq!(
            output["intent"]["source"],
            serde_json::to_value(&case.source).unwrap()
        );
        assert_eq!(
            output["intent"]["afterEvent"],
            serde_json::to_value(case.after_event).unwrap()
        );
        if case.expected == "invalidEvidence" {
            assert_eq!(output["validationError"], "InvalidEvidence");
            invalid += 1;
        } else {
            assert!(output["validationError"].is_null());
            shape += 1;
        }
    }
    assert_eq!((invalid, shape), (5, 3));
}
#[test]
fn native_controller_selection_and_range_reveal_preserve_real_counter_keys() {
    let (cases, swift) = inputs();
    let mut count = 0;
    for case in cases.iter().filter(|c| c.inspectors.is_some()) {
        let native = swift.iter().find(|v| v["id"] == case.id).unwrap();
        let rust = flow_observation(case, native);
        assert_eq!(
            rust["focusSteps"], native["focusSteps"],
            "focus: {}",
            case.id
        );
        assert_eq!(
            rust["focused"], native["focused"],
            "table-qualified focus: {}",
            case.id
        );
        assert_eq!(
            rust["admittedTree"], native["admittedTree"],
            "source admission: {}",
            case.id
        );
        assert_eq!(
            rust["treeAfterReveal"], native["treeAfterReveal"],
            "source retained: {}",
            case.id
        );
        assert_eq!(
            rust["viewportAfterReveal"], native["viewportAfterReveal"],
            "range reveal: {}",
            case.id
        );
        assert_eq!(rust["focused"]["key"], native["selectedInspector"]["key"]);
        assert_eq!(
            native["selectedInspector"],
            case.inspectors.as_ref().unwrap()[case.target_ordinal.unwrap()]
        );
        assert!(rust["pendingKeyAfterRangeAction"].is_null());
        count += 1;
    }
    assert_eq!(count, 6);
}
#[test]
fn all_real_repository_counter_anchors_must_pass_navigation_intent_validation() {
    let (cases, _) = inputs();
    for case in cases.iter().filter(|c| c.expected == "legal") {
        let output = intent_observation(case);
        assert!(
            output["validationError"].is_null(),
            "legal real Store anchor rejected: {}\n{}",
            case.id,
            output
        );
    }
}
