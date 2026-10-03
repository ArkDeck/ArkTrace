#[allow(dead_code)]
mod common;
use arktrace_contract::TraceTimeRange;
use arktrace_viewer::*;
use serde::Deserialize;
use serde_json::Value;
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Vector {
    name: String,
    viewport: Viewport,
    selection: Option<TraceTimeRange>,
    press_x: f64,
    anchor_ns: i64,
    mode: SelectionDrag,
    drag_xs: Vec<f64>,
}
#[test]
fn replay_three_actual_swift_selection_event_sequences_and_measure_nonfinite_difference() {
    let inputs: Vec<Vector> =
        serde_json::from_str(include_str!("fixtures/boundary-inputs.json")).unwrap();
    let expected: Vec<Value> =
        serde_json::from_str(include_str!("fixtures/swift-boundary-oracle.json")).unwrap();
    assert_eq!(inputs.len(), 3);
    assert_eq!(inputs.len(), expected.len());
    for (v, e) in inputs.iter().zip(&expected) {
        assert_eq!(
            v.viewport.time(v.press_x).unwrap(),
            if v.mode == SelectionDrag::NewRange {
                v.anchor_ns
            } else {
                v.selection.unwrap().start_ns()
            }
        );
        let mut previous = v.selection;
        let results: Vec<_> = v
            .drag_xs
            .iter()
            .map(|x| {
                previous = selection_drag(&v.viewport, v.anchor_ns, *x, v.mode, previous).unwrap();
                previous
            })
            .collect();
        common::compare(
            &serde_json::to_value(results).unwrap(),
            &e["selections"],
            &v.name,
        );
        // Explicit measured boundary difference; no tolerance or pretending
        // rejection is parity with Swift's no-op/saturation return values.
        assert_eq!(e["nonFinitePanDeltas"]["nan"].as_i64(), Some(0));
        assert_eq!(
            e["nonFinitePanDeltas"]["positiveInfinity"].as_i64(),
            Some(i64::MAX)
        );
        assert_eq!(
            e["nonFinitePanDeltas"]["negativeInfinity"].as_i64(),
            Some(i64::MIN)
        );
        for x in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            assert_eq!(
                v.viewport.nanosecond_delta(x),
                Err(ViewerError::InvalidGeometry)
            );
        }
    }
}
