#[allow(dead_code)]
mod common;
use arktrace_contract::*;
use arktrace_viewer::*;
use serde::Deserialize;
use serde_json::{Value, json};
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Vector {
    name: String,
    viewport: Viewport,
    tracks: Vec<TrackInput>,
    backing_scale: f64,
    times: Vec<i64>,
    xs: Vec<f64>,
    points: Vec<Point>,
    pans: Vec<Pan>,
    zooms: Vec<Zoom>,
    selections: Vec<Selection>,
    resolution_time_ns: i64,
}
#[derive(Deserialize)]
struct Pan {
    points: f64,
    bounds: TraceTimeRange,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Zoom {
    anchor_ns: i64,
    scale: f64,
    bounds: TraceTimeRange,
}
#[derive(Deserialize)]
struct Selection {
    range: TraceTimeRange,
    points: Vec<Point>,
}
#[test]
fn replay_25_actual_swift_geometry_hit_interaction_vectors_exactly() {
    let inputs: Vec<Vector> =
        serde_json::from_str(include_str!("fixtures/geometry-inputs.json")).unwrap();
    let expected: Vec<Value> =
        serde_json::from_str(include_str!("fixtures/swift-geometry-oracle.json")).unwrap();
    assert_eq!(inputs.len(), 25);
    assert_eq!(inputs.len(), expected.len());
    for (v, e) in inputs.iter().zip(&expected) {
        let mut check = || Ok(());
        let snap = project(
            &v.viewport,
            v.viewport.generation(),
            &v.tracks,
            v.backing_scale,
            &common::quality(),
            &mut check,
        )
        .unwrap();
        let hit_scale = e["hitScale"].as_f64().unwrap();
        let hit_snap = project(
            &v.viewport,
            v.viewport.generation(),
            &v.tracks,
            hit_scale,
            &common::quality(),
            &mut check,
        )
        .unwrap();
        let frames: Vec<Vec<Option<Rect>>> = snap
            .tracks()
            .iter()
            .map(|t| t.primitives.iter().map(|p| p.frame).collect())
            .collect();
        let visible: Vec<Vec<bool>> = snap
            .tracks()
            .iter()
            .map(|t| t.primitives.iter().map(|p| p.visible).collect())
            .collect();
        let hits: Vec<Value> = v
            .points
            .iter()
            .map(|p| {
                let detail = hit_snap.detail_hit(*p, &mut check).unwrap();
                let density = hit_snap.density_hit(*p, &mut check).unwrap().map(
                    |hit| json!({"trackID":hit.track_id,"bucket":hit.bucket,"timeNs":hit.time_ns}),
                );
                json!({"detail":detail,"density":density})
            })
            .collect();
        let pans: Vec<Value> = v
            .pans
            .iter()
            .map(|p| {
                let delta = v.viewport.nanosecond_delta(p.points).unwrap();
                json!({"deltaNs":delta,"range":pan(v.viewport.range(),delta,p.bounds).unwrap()})
            })
            .collect();
        let zooms: Vec<_> = v
            .zooms
            .iter()
            .map(|z| zoom(v.viewport.range(), z.anchor_ns, z.scale, z.bounds).unwrap())
            .collect();
        let endpoints: Vec<Vec<_>> = v
            .selections
            .iter()
            .map(|s| {
                s.points
                    .iter()
                    .map(|p| selection_endpoint(*p, s.range, &v.viewport).unwrap())
                    .collect()
            })
            .collect();
        let details: Vec<_> = v
            .tracks
            .iter()
            .flat_map(|t| &t.primitives)
            .filter_map(|p| match p {
                PrimitiveInput::Detail { detail } => Some(detail.clone()),
                _ => None,
            })
            .collect();
        let result = json!({"name":v.name,"viewport":v.viewport,"frames":frames,"visible":visible,
            "xCoordinates":v.times.iter().map(|t|v.viewport.x(*t)).collect::<Vec<_>>(),"times":v.xs.iter().map(|x|v.viewport.time(*x).unwrap()).collect::<Vec<_>>(),
            "hitScale":hit_scale,"hits":hits,"pans":pans,"zooms":zooms,"selectionEndpoints":endpoints,"resolution":resolve_candidate(v.resolution_time_ns,&details,&mut check).unwrap()});
        common::compare(&result, e, &v.name);
    }
}
