use serde_json::Value;

#[test]
fn independent_swift_scope_fix_changes_only_the_three_unattributed_detail_cases() {
    let before: Vec<Value> =
        serde_json::from_str(include_str!("fixtures/swift-scoped-slices-before.json")).unwrap();
    let after: Vec<Value> =
        serde_json::from_str(include_str!("fixtures/swift-scoped-slices.json")).unwrap();
    assert_eq!(before.len(), 6);
    assert_eq!(after.len(), before.len());
    for (b, a) in before.iter().zip(&after) {
        assert_eq!(b["name"], a["name"]);
        let changed = matches!(
            a["name"].as_str().unwrap(),
            "unattributed-detail"
                | "unattributed-focus-own-event"
                | "unattributed-focus-other-thread"
        );
        assert_eq!(b != a, changed, "{}", a["name"]);
        if changed {
            // Full immutable output is retained. This check demonstrates
            // domain identity/range ownership, rather than a second oracle.
            let primitives = a["result"]["tracks"][0]["primitives"].as_array().unwrap();
            assert_eq!(primitives.len(), 2);
            assert!(primitives.iter().all(|p| {
                [7, 8, 9].contains(&p["detail"]["_0"]["eventKey"]["rowID"].as_i64().unwrap())
            }));
        }
    }
}
