use arktrace_contract::EventKey;
use arktrace_viewer::*;
use serde::Deserialize;
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Inputs {
    schema_version: u32,
    cases: Vec<Case>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Case {
    id: String,
    snapshot_present: bool,
    generation: u64,
    tracks: Vec<Vec<SnapshotEventPrimitiveFact>>,
    queries: Vec<Option<EventKey>>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Output {
    schema_version: u32,
    cases: usize,
    rows: Vec<Row>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Row {
    #[serde(rename = "caseID")]
    case_id: String,
    query_index: usize,
    lookup: SnapshotEventIndexLookup,
    direct_marker: Option<String>,
    hover_marker: Option<String>,
    select_marker: Option<String>,
    hover_position: Option<[u32; 2]>,
    select_position: Option<[u32; 2]>,
}
#[test]
fn all_positions_and_nil_inspectors_match_actual_swift_controller_hover_select() {
    let inputs: Inputs =
        serde_json::from_str(include_str!("fixtures/snapshot-event-index-inputs.json")).unwrap();
    let output: Output = serde_json::from_str(include_str!(
        "fixtures/snapshot-event-index-swift-oracle.json"
    ))
    .unwrap();
    assert_eq!(inputs.schema_version, 1);
    assert_eq!(output.schema_version, 1);
    assert_eq!(output.cases, inputs.cases.len());
    let mut next = 0;
    for (revision, case) in inputs.cases.iter().enumerate() {
        let identity = SnapshotEventIndexIdentity {
            view: ViewIdentity {
                session_id: 100,
                generation: case.generation,
            },
            snapshot_revision: revision as u64,
        };
        let tracks: Vec<_> = case
            .tracks
            .iter()
            .map(|primitives| SnapshotEventTrackFacts { primitives })
            .collect();
        let index = build_snapshot_event_index(
            identity,
            if case.snapshot_present { &tracks } else { &[] },
            &mut || Ok(()),
        )
        .unwrap();
        for (qi, q) in case.queries.iter().enumerate() {
            let row = &output.rows[next];
            next += 1;
            assert_eq!(row.case_id, case.id);
            assert_eq!(row.query_index, qi);
            assert_eq!(
                index.lookup(identity, *q, &mut || Ok(())).unwrap(),
                row.lookup,
                "{} query {qi}",
                case.id
            );
            assert_eq!(row.direct_marker, row.hover_marker);
            assert_eq!(row.direct_marker, row.select_marker);
            let pos = match row.lookup {
                SnapshotEventIndexLookup::Matched { location } => {
                    Some([location.track_index, location.primitive_index])
                }
                SnapshotEventIndexLookup::NoMatch => None,
            };
            assert_eq!(pos, row.hover_position);
            assert_eq!(pos, row.select_position);
        }
    }
    assert_eq!(next, output.rows.len());
    println!(
        "actual Swift canonical: {} snapshots, {} lookup/hover/select queries",
        output.cases, next
    );
}
