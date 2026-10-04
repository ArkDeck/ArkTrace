#[allow(dead_code)]
mod common;
use arktrace_contract::TraceTimeRange;
use arktrace_viewer::*;
use serde_json::{Value, json};
fn range(value: &Value, key: &str) -> Option<TraceTimeRange> {
    value
        .get(key)
        .filter(|v| !v.is_null())
        .map(|v| serde_json::from_value(v.clone()).unwrap())
}
fn text<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}
fn integer(value: &Value, key: &str) -> i64 {
    value[key].as_i64().unwrap_or(0)
}
fn observe(
    state: &AnnotationState,
    outcome: AnnotationOutcome,
    rejected: bool,
    anchors: &[Value],
) -> Value {
    let mut check = || Ok(());
    let projection = state.persistence(&mut check).unwrap();
    let probes: Vec<_> = anchors.iter().map(|a| {
        let t = a.as_i64().unwrap();
        json!({"timestampNs":t,"flagAfter":state.flag_after(t,&mut check).unwrap().map(|f|f.id),"flagBefore":state.flag_before(t,&mut check).unwrap().map(|f|f.id),"markAfter":state.mark_after(t,&mut check).unwrap().map(|m|m.id),"markBefore":state.mark_before(t,&mut check).unwrap().map(|m|m.id)})
    }).collect();
    if let Some(reveal) = outcome.reveal {
        match reveal.target.kind {
            AnnotationKind::Flag => assert!(
                state
                    .flags()
                    .iter()
                    .any(|f| f.id == reveal.target.id && f.point_range().unwrap() == reveal.range)
            ),
            AnnotationKind::Mark => assert!(
                state
                    .marks()
                    .iter()
                    .any(|m| m.id == reveal.target.id && m.range == reveal.range)
            ),
        }
    }
    json!({"flags":state.flags(),"marks":state.marks(),"orderedFlags":state.ordered_flags(&mut check).unwrap(),"orderedMarks":state.ordered_marks(&mut check).unwrap(),"pointRanges":state.flags().iter().map(|f|json!({"id":f.id,"range":f.point_range().unwrap()})).collect::<Vec<_>>(),"nextID":state.next_id(),"sessionID":state.session_id(),"isEmpty":state.is_empty(),"persistence":{"flags":projection.flags(),"marks":projection.marks()},"created":outcome.created,"persistCount":if outcome.persistence==AnnotationPersistenceIntent::Save{1}else{0},"reveals":outcome.reveal.map(|r|vec![r.range]).unwrap_or_default(),"guardRejected":rejected,"probes":probes})
}
#[test]
fn actual_swift_controller_annotations_and_save_projection() {
    let inputs: Value =
        serde_json::from_str(include_str!("fixtures/annotation-inputs.json")).unwrap();
    let expected: Value =
        serde_json::from_str(include_str!("fixtures/annotation-swift-oracle.json")).unwrap();
    assert_eq!(inputs["cases"].as_array().unwrap().len(), 74);
    let mut actual = Vec::new();
    for vector in inputs["cases"].as_array().unwrap() {
        let duration = vector["durationNs"].as_i64();
        let bounds = duration.map(|d| TraceTimeRange::query(0, d).unwrap());
        let mut check = || Ok(());
        let mut state = AnnotationState::new(
            u64::from(duration.is_some()),
            bounds,
            AnnotationBudget::default(),
            &mut check,
        )
        .unwrap();
        let flags: Vec<AnnotationFlag> = serde_json::from_value(vector["flags"].clone()).unwrap();
        let marks: Vec<AnnotationMark> = serde_json::from_value(vector["marks"].clone()).unwrap();
        if duration.is_some() {
            state
                .restore(
                    ANNOTATION_API_VERSION,
                    state.session_id(),
                    &flags,
                    &marks,
                    &mut check,
                )
                .unwrap();
        }
        let anchors = vector["anchors"].as_array().unwrap();
        let mut states = vec![observe(
            &state,
            AnnotationOutcome::default(),
            false,
            anchors,
        )];
        for step in vector["steps"].as_array().unwrap() {
            let id = integer(step, "id");
            let label = text(step, "label");
            let color_index = step.get("colorIndex").and_then(Value::as_i64);
            let action = match step["action"].as_str().unwrap() {
                "addFlag" => AnnotationAction::AddFlag {
                    timestamp_ns: integer(step, "timestampNs"),
                    label,
                },
                "addMark" => AnnotationAction::AddMark {
                    is_persistent: step["isPersistent"].as_bool().unwrap(),
                    label,
                },
                "updateFlag" | "deferredRenameFlag" => AnnotationAction::UpdateFlag {
                    id,
                    label,
                    color_index,
                },
                "updateMark" => AnnotationAction::UpdateMark {
                    id,
                    label,
                    color_index,
                },
                "removeFlag" => AnnotationAction::RemoveFlag { id },
                "removeMark" => AnnotationAction::RemoveMark { id },
                "cycleFlagColor" => AnnotationAction::CycleFlagColor { id },
                "cycleMarkColor" => AnnotationAction::CycleMarkColor { id },
                "cancelSession" => AnnotationAction::AdvanceSession {
                    new_session_id: state.session_id() + 1,
                },
                "replaceSession" => AnnotationAction::ReplaceSession {
                    new_session_id: state.session_id() + 1,
                    bounds,
                },
                "closeSession" => AnnotationAction::ReplaceSession {
                    new_session_id: state.session_id() + 1,
                    bounds: None,
                },
                "command" => AnnotationAction::Command(match step["command"].as_str().unwrap() {
                    "nextFlag" => AnnotationCommand::NextFlag,
                    "previousFlag" => AnnotationCommand::PreviousFlag,
                    "nextMark" => AnnotationCommand::NextMark,
                    "previousMark" => AnnotationCommand::PreviousMark,
                    "nearest" => AnnotationCommand::ScrollNearestFlagIntoView,
                    "createPersistent" => AnnotationCommand::CreateMark {
                        is_persistent: true,
                    },
                    "createTransient" => AnnotationCommand::CreateMark {
                        is_persistent: false,
                    },
                    _ => panic!("unknown command"),
                }),
                _ => panic!("unknown action"),
            };
            let context = AnnotationContext {
                viewport_range: range(step, "viewportRange"),
                selected_range: range(step, "selectedRange"),
                selected_event_range: range(step, "selectedEventRange"),
            };
            let session_id = if step["action"] == "deferredRenameFlag" {
                step["capturedSessionID"].as_u64().unwrap()
            } else {
                state.session_id()
            };
            let result = state.apply(
                AnnotationRequest {
                    api_version: ANNOTATION_API_VERSION,
                    session_id,
                    context,
                    action,
                },
                &mut check,
            );
            let (outcome, rejected) = match result {
                Ok(outcome) => (outcome, false),
                Err(AnnotationError::StaleSession) if step["action"] == "deferredRenameFlag" => {
                    (AnnotationOutcome::default(), true)
                }
                Err(e) => panic!("{} {step}: {e:?}", vector["name"]),
            };
            states.push(observe(&state, outcome, rejected, anchors));
        }
        actual.push(json!({"name":vector["name"],"states":states}));
    }
    common::compare(&json!({"cases":actual}), &expected, "annotation-controller");
}
