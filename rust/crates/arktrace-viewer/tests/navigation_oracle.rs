use arktrace_contract::TraceTimeRange;
use arktrace_viewer::*;
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Deserialize)]
struct Case {
    name: String,
    facts: TrackCatalogFacts,
    actions: Vec<ViewAction>,
    filters: Vec<String>,
}
fn projection(state: &ViewState) -> Value {
    let mut value = json!({ "tree":state.tree,"searchResults":{"items":state.search_results,"truncated":state.search_results_truncated},"favoriteTrackIDs":state.favorite_track_ids,"processFilterText":state.process_filter_text,"searchSelectionIndex":state.search_selection_index,"pendingSelectionKey":state.pending_selection_key,"viewportRange":state.viewport_range });
    // Native TimelineTrackSource.frame has unlabeled _0. Frozen contract
    // TraceDensitySource.frame labels the identical owner as processKey.
    // Adapt this wire key only; all values/absence/identity remain compared.
    for group in value["tree"]["groups"].as_array_mut().unwrap() {
        for track in group["tracks"].as_array_mut().unwrap() {
            if let Some(frame) = track["descriptor"]["source"].get_mut("frame") {
                let object = frame.as_object_mut().unwrap();
                if let Some(owner) = object.remove("processKey") {
                    object.insert("_0".into(), owner);
                }
            }
        }
    }
    value
}
struct RecordedMatcher<'a> {
    matches: &'a [Value],
}
impl SidebarTitleMatcher for RecordedMatcher<'_> {
    fn contains_case_insensitive(
        &mut self,
        title: &str,
        _needle: &str,
    ) -> Result<bool, ViewerError> {
        self.matches
            .iter()
            .find(|m| m["title"].as_str() == Some(title))
            .and_then(|m| m["matches"].as_bool())
            .ok_or(ViewerError::InvalidEvidence)
    }
}

#[test]
fn replay_actual_swift_catalog_action_order_identity_and_focus_exactly() {
    let cases: Vec<Case> =
        serde_json::from_str(include_str!("fixtures/navigation-inputs.json")).unwrap();
    let expected: Vec<Value> =
        serde_json::from_str(include_str!("fixtures/navigation-swift-oracle.json")).unwrap();
    assert_eq!(cases.len(), expected.len());
    for (case, oracle) in cases.into_iter().zip(expected) {
        assert_eq!(case.name, oracle["name"]);
        let tree = build_track_tree(&case.facts, &mut || Ok(())).unwrap();
        let mut state = ViewState {
            identity: ViewIdentity {
                session_id: 1,
                generation: 2,
            },
            tree,
            catalog_threads: case.facts.threads,
            capabilities: case.facts.capabilities,
            bounds: Some(TraceTimeRange::event(0, case.facts.duration_ns).unwrap()),
            viewport_range: Some(TraceTimeRange::query(0, case.facts.duration_ns.max(1)).unwrap()),
            process_filter_text: String::new(),
            favorite_track_ids: vec![],
            search_results: vec![],
            search_results_truncated: false,
            search_selection_index: None,
            pending_selection_key: None,
        };
        assert_eq!(
            projection(&state),
            oracle["initial"],
            "initial {}",
            case.name
        );
        let filters = oracle["filters"].as_array().unwrap();
        assert_eq!(case.filters.len(), filters.len());
        for (text, filter) in case.filters.iter().zip(filters) {
            assert_eq!(
                trim_sidebar_filter(text),
                filter["trimmed"],
                "trim {}",
                case.name
            );
            let indices = filtered_group_indices(
                &state.tree,
                text,
                &mut RecordedMatcher {
                    matches: filter["matches"].as_array().unwrap(),
                },
                &mut || Ok(()),
            )
            .unwrap();
            let ids: Vec<_> = indices
                .into_iter()
                .map(|i| state.tree.groups[i].id.clone())
                .collect();
            assert_eq!(json!(ids), filter["ids"], "filter {} {text:?}", case.name);
        }
        let steps = oracle["steps"].as_array().unwrap();
        assert_eq!(case.actions.len(), steps.len());
        for (i, (action, expected)) in case.actions.into_iter().zip(steps).enumerate() {
            let reduced = reduce_view_action(
                &state,
                &ViewActionRequest {
                    identity: state.identity,
                    action,
                },
                &mut || Ok(()),
            )
            .unwrap();
            assert_eq!(
                projection(&reduced.state),
                expected["projection"],
                "projection {} step {i}",
                case.name
            );
            if let Some(returned) = expected["returned"].as_bool() {
                assert_eq!(reduced.applied, returned, "return {} step {i}", case.name);
            }
            assert_eq!(
                json!(reduced.intents.focus_timeline),
                expected["focusTimeline"],
                "focus {} step {i}",
                case.name
            );
            assert_eq!(
                json!(reduced.intents.snapshot_preference),
                expected["snapshotPreference"],
                "preference {} step {i}",
                case.name
            );
            assert_eq!(
                json!(reduced.intents.persist_favorites),
                expected["persistFavorites"],
                "persist {} step {i}",
                case.name
            );
            assert_eq!(
                json!(reduced.intents.viewport_range),
                expected["viewportIntent"],
                "range {} step {i}",
                case.name
            );
            state = reduced.state;
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RenderingCase {
    name: String,
    lanes: Vec<NavigationLane>,
    focused: Option<EventFocus>,
    selected: Option<arktrace_contract::EventKey>,
    viewport: TraceTimeRange,
    command: String,
    delta: i64,
    #[serde(default)]
    uses_pointer: bool,
    selection: Option<TraceTimeRange>,
    pointer_x: Option<f64>,
}
#[test]
fn replay_actual_native_move_event_move_track_and_zoom_anchor_without_tolerance() {
    let cases: Vec<RenderingCase> =
        serde_json::from_str(include_str!("fixtures/navigation-rendering-inputs.json")).unwrap();
    let expected: Vec<Value> = serde_json::from_str(include_str!(
        "fixtures/navigation-rendering-swift-oracle.json"
    ))
    .unwrap();
    assert_eq!(cases.len(), expected.len());
    for (case, expected) in cases.into_iter().zip(expected) {
        assert_eq!(case.name, expected["name"]);
        if case.command == "anchor" {
            let key = case.focused.as_ref().map(|f| f.key).or(case.selected);
            let range = key
                .and_then(|key| {
                    case.lanes
                        .iter()
                        .flat_map(|l| &l.events)
                        .find(|e| e.key == key)
                })
                .map(|e| e.range);
            let viewport = Viewport::new(case.viewport, 100.0, 100.0, 0.0, 0).unwrap();
            let pointer = case
                .pointer_x
                .filter(|x| *x >= 0.0 && *x < 100.0)
                .map(|x| viewport.time(x).unwrap());
            assert_eq!(
                json!(navigation_zoom_anchor(
                    case.viewport,
                    case.selection,
                    range,
                    pointer,
                    case.uses_pointer
                )),
                expected["anchorNs"],
                "{}",
                case.name
            );
        } else {
            let next = if case.command == "event" {
                step_displayed_event(
                    &case.lanes,
                    case.focused.as_ref(),
                    case.selected,
                    case.delta,
                    &mut || Ok(()),
                )
                .unwrap()
            } else {
                step_displayed_track(
                    &case.lanes,
                    case.focused.as_ref(),
                    case.selected,
                    case.viewport,
                    case.delta,
                    &mut || Ok(()),
                )
                .unwrap()
            };
            assert_eq!(json!(next.is_some()), expected["changed"], "{}", case.name);
            assert_eq!(
                json!(next.or(case.focused)),
                expected["focus"],
                "{}",
                case.name
            );
        }
    }
}

#[derive(Deserialize)]
struct RestoreCase {
    name: String,
    facts: TrackCatalogFacts,
    ids: Vec<String>,
}
#[test]
fn replay_actual_controller_open_sidecar_restoration_without_copying_its_io() {
    let inputs: Vec<RestoreCase> =
        serde_json::from_str(include_str!("fixtures/navigation-restore-inputs.json")).unwrap();
    let expected: Vec<Value> = serde_json::from_str(include_str!(
        "fixtures/navigation-restore-swift-oracle.json"
    ))
    .unwrap();
    assert_eq!(inputs.len(), expected.len());
    for (case, expected) in inputs.into_iter().zip(expected) {
        let tree = build_track_tree(&case.facts, &mut || Ok(())).unwrap();
        let state = ViewState {
            identity: ViewIdentity {
                session_id: 1,
                generation: 2,
            },
            tree,
            catalog_threads: case.facts.threads,
            capabilities: case.facts.capabilities,
            bounds: Some(TraceTimeRange::query(0, 1000).unwrap()),
            viewport_range: Some(TraceTimeRange::query(0, 1000).unwrap()),
            process_filter_text: String::new(),
            favorite_track_ids: vec![],
            search_results: vec![],
            search_results_truncated: false,
            search_selection_index: None,
            pending_selection_key: None,
        };
        let result = reduce_view_action(
            &state,
            &ViewActionRequest {
                identity: state.identity,
                action: ViewAction::RestoreFavorites { ids: case.ids },
            },
            &mut || Ok(()),
        )
        .unwrap();
        let output = projection(&result.state);
        assert_eq!(
            json!({"name":case.name,"tree":output["tree"],"favoriteTrackIDs":output["favoriteTrackIDs"]}),
            expected
        );
    }
}

#[test]
fn trimming_matches_actual_foundation_character_set_over_all_unicode_scalars() {
    let expected: Vec<u32> = serde_json::from_str(include_str!(
        "fixtures/navigation-whitespace-swift-oracle.json"
    ))
    .unwrap();
    let actual: Vec<_> = (0..=0x10ffff)
        .filter_map(char::from_u32)
        .filter(|c| trim_sidebar_filter(&c.to_string()).is_empty())
        .map(u32::from)
        .collect();
    assert_eq!(actual, expected);
}
