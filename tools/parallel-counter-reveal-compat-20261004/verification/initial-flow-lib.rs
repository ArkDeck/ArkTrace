//! External calls to the frozen public navigation/reveal APIs only.
use arktrace_contract::{EventKey, TraceDensitySource, TraceTimeRange};
use arktrace_viewer::*;
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Case {
    pub id: String,
    pub source: TraceDensitySource,
    pub after_event: Option<EventKey>,
    pub expected: String,
    pub identity: ViewIdentity,
    pub anchor_ns: i64,
    pub direction: EventNavigationDirection,
    pub limit: usize,
    pub fixture: Option<String>,
    pub inspectors: Option<Vec<Value>>,
    pub target_ordinal: Option<usize>,
    pub title: Option<String>,
}
pub fn intent_observation(case: &Case) -> Value {
    let intent = EventNavigationQueryIntent {
        identity: case.identity,
        source: case.source.clone(),
        anchor_ns: case.anchor_ns,
        after_event: case.after_event,
        direction: case.direction,
        limit: case.limit,
    };
    let encoded = serde_json::to_value(&intent).unwrap();
    let decoded: EventNavigationQueryIntent = serde_json::from_value(encoded.clone()).unwrap();
    assert_eq!(decoded, intent);
    let error = decoded.validate().err().map(|value| format!("{value:?}"));
    let RepositoryDetailQuery::Counter(query) =
        detail_query(&case.source, TraceTimeRange::query(0, 1000).unwrap(), 1).unwrap()
    else {
        unreachable!()
    };
    json!({"id":case.id,"intent":encoded,"validationError":error,
        "roundtripPreserved":true,"sourceID":source_id(&case.source),"typedSourceQuery":query})
}
pub fn flow_observation(case: &Case, swift: &Value) -> Value {
    let state: ViewState = serde_json::from_value(swift["beforeState"].clone()).unwrap();
    let descriptor = TrackDescriptor {
        source: case.source.clone(),
        is_collapsed: false,
        shows_nested_depth: true,
    };
    let track = SidebarTrack {
        title: case.title.clone().unwrap(),
        descriptor,
    };
    let admission = reduce_view_action(
        &state,
        &ViewActionRequest {
            identity: state.identity,
            action: ViewAction::AdmitTrack { track },
        },
        &mut || Ok(()),
    )
    .unwrap();
    let facts = case.inspectors.as_ref().unwrap();
    let lane = NavigationLane {
        track_id: source_id(&case.source),
        events: facts
            .iter()
            .map(|f| NavigationEvent {
                key: serde_json::from_value(f["key"].clone()).unwrap(),
                range: serde_json::from_value(f["range"].clone()).unwrap(),
                is_open_ended: f["isOpenEnded"].as_bool().unwrap(),
            })
            .collect(),
    };
    let mut focus = None;
    let mut steps = Vec::new();
    for _ in 0..=case.target_ordinal.unwrap() {
        let next = step_displayed_event(
            std::slice::from_ref(&lane),
            focus.as_ref(),
            None,
            1,
            &mut || Ok(()),
        )
        .unwrap();
        steps.push(json!(next));
        if next.is_some() {
            focus = next;
        }
    }
    let focused = focus.unwrap();
    let target = lane.events.iter().find(|e| e.key == focused.key).unwrap();
    let reveal = reduce_view_action(
        &admission.state,
        &ViewActionRequest {
            identity: state.identity,
            action: ViewAction::RevealRange {
                range: target.range,
            },
        },
        &mut || Ok(()),
    )
    .unwrap();
    let query = detail_query(&case.source, state.bounds.unwrap(), 1).unwrap();
    let RepositoryDetailQuery::Counter(query) = query else {
        unreachable!()
    };
    let generic = reveal_range(target.range, state.bounds.unwrap()).unwrap();
    json!({"id":case.id,"intent":intent_observation(case),"focusSteps":steps,
        "focused":focused,"admittedTree":admission.state.tree,
        "treeAfterReveal":reveal.state.tree,"viewportAfterReveal":reveal.state.viewport_range,
        "rangeOnlyReveal":generic,"revealIntents":reveal.intents,
        "pendingKeyAfterRangeAction":reveal.state.pending_selection_key,
        "typedSourceQuery":query,"sourceAfterRoundtrip":case.source,
        "eventSelectionAPIAvailableInViewAction":false})
}
pub fn all_observations(cases: &[Case], swift: &[Value]) -> Value {
    assert!(!cases.is_empty() && cases.len() <= 16);
    let intents = cases.iter().map(intent_observation).collect::<Vec<_>>();
    let flows = cases
        .iter()
        .filter(|c| c.inspectors.is_some())
        .map(|case| {
            let native = swift.iter().find(|v| v["id"] == case.id).unwrap();
            flow_observation(case, native)
        })
        .collect::<Vec<_>>();
    json!({"intents":intents,"flows":flows})
}
