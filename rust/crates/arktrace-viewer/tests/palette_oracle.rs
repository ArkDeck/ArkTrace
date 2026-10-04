#[allow(dead_code)]
mod common;
use arktrace_contract::*;
use arktrace_viewer::*;
use serde::Deserialize;
use serde_json::{Value, json};
fn color(c: ResolvedColor) -> Value {
    json!({"rgb":c.fill,"rgba":[c.rgba.red,c.rgba.green,c.rgba.blue,c.rgba.alpha],"foreground":c.label_foreground})
}
fn string<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v[key].as_str()
}
#[test]
fn actual_swift_palette_and_private_density_paint_exact_oracle() {
    let inputs: Value =
        serde_json::from_str(include_str!("fixtures/presentation-inputs.json")).unwrap();
    let expected: Value =
        serde_json::from_str(include_str!("fixtures/presentation-swift-oracle.json")).unwrap();
    let cases = inputs["palette"].as_array().unwrap();
    assert_eq!(cases.len(), 1068);
    assert_eq!(cases.len(), expected["palette"].as_array().unwrap().len());
    for (v, e) in cases.iter().zip(expected["palette"].as_array().unwrap()) {
        let mut check = || Ok(());
        let text = string(v, "text").unwrap_or("");
        let mut r = json!({"name":v["name"]});
        match v["kind"].as_str().unwrap() {
            "hash" => {
                let depth = v["depth"].as_i64().unwrap();
                let modulus = v["modulus"].as_i64().unwrap();
                r["hash"] = json!(palette_hash(text, modulus, &mut check).unwrap());
                r["hashFunc"] = json!(palette_hash_func(text, depth, modulus, &mut check).unwrap());
                r["nameColor"] = color(name_color(text, &mut check).unwrap());
                r["sliceColor"] = color(slice_name_color(text, 0, &mut check).unwrap());
                r["sliceDepthColor"] = color(slice_name_color(text, depth, &mut check).unwrap());
            }
            "identity" => {
                r["color"] = color(
                    process_or_thread_color(v["identity"].as_i64().unwrap(), &mut check).unwrap(),
                )
            }
            "state" => {
                r["color"] = color(
                    state_color(
                        string(v, "raw"),
                        serde_json::from_value(v["normalized"].clone()).unwrap(),
                    )
                    .unwrap(),
                )
            }
            "jank" => r["color"] = color(jank_color(v["tag"].as_i64().unwrap())),
            "annotation" => r["color"] = color(annotation_color(v["index"].as_i64().unwrap())),
            "track" => r["color"] = color(track_identity_color(text, &mut check).unwrap()),
            "rgba" => {
                let rgb: Rgb = serde_json::from_value(
                    json!({"red":v["red"],"green":v["green"],"blue":v["blue"]}),
                )
                .unwrap();
                let rgba = rgb.rgba(1.0).unwrap();
                r["color"] = json!({"rgb":rgb,"rgba":[rgba.red,rgba.green,rgba.blue,rgba.alpha],"foreground":rgb.label_foreground()});
                let a = rgb.rgba(v["alpha"].as_f64().unwrap()).unwrap();
                r["alphaRgba"] = json!([a.red, a.green, a.blue, a.alpha]);
            }
            "densityColor" => {
                let source: TraceDensitySource =
                    serde_json::from_value(v["source"].clone()).unwrap();
                let dominant: Option<TraceDensityIdentity> =
                    serde_json::from_value(v["dominant"].clone()).unwrap();
                let track = TrackDescriptor {
                    source,
                    is_collapsed: false,
                    shows_nested_depth: true,
                };
                r["color"] = color(density_color(dominant.as_ref(), &track, &mut check).unwrap());
            }
            "density" => {
                let count = v["count"].as_i64().unwrap();
                let intensity = density_intensity(count);
                let fraction = density_height_fraction(intensity as i64);
                let height = (22.0 * fraction).max(1.0);
                let c = track_identity_color("cpu:0", &mut check).unwrap();
                r["paint"] = json!({"intensity":intensity,"heightFraction":fraction,"frame":{"x":0,"y":25.0+(22.0-height),"width":200,"height":height},"rgba":[c.rgba.red,c.rgba.green,c.rgba.blue,c.rgba.alpha]});
            }
            _ => panic!("unknown case"),
        }
        common::compare(&r, e, v["name"].as_str().unwrap());
    }
    let tokens = &expected["tokens"];
    for (family, key) in [
        (PaletteFamily::Identity, "identity"),
        (PaletteFamily::Jank, "jank"),
        (PaletteFamily::Annotation, "annotation"),
    ] {
        for (i, c) in tokens[key].as_array().unwrap().iter().enumerate() {
            common::compare(&color(palette_color(family, i).unwrap()), c, key);
        }
    }
    for (raw, c) in tokens["states"].as_object().unwrap() {
        common::compare(&color(state_color(Some(raw), None).unwrap()), c, raw);
    }
    common::compare(&color(grey_color()), &tokens["grey"], "grey");
    common::compare(
        &color(state_color(None, None).unwrap()),
        &tokens["unknown"],
        "unknown",
    );
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Generic {
    name: String,
    inspector_kind: Option<PresentationKind>,
    label: Option<String>,
    category: Option<String>,
    inspector_name: Option<String>,
    state: Option<String>,
    pid: Option<i64>,
    tid: Option<i64>,
    jank_tag: i64,
}
#[test]
fn actual_swift_detail_discriminator_nil_and_fallback_chains() {
    let input: Value =
        serde_json::from_str(include_str!("fixtures/presentation-inputs.json")).unwrap();
    let expected: Value =
        serde_json::from_str(include_str!("fixtures/presentation-swift-oracle.json")).unwrap();
    let cases: Vec<Generic> = serde_json::from_value(input["genericDetails"].clone()).unwrap();
    assert_eq!(cases.len(), 38);
    for (v, e) in cases
        .iter()
        .zip(expected["genericDetails"].as_array().unwrap())
    {
        let c = detail_color(
            DetailColorInput {
                kind: v.inspector_kind,
                label: v.label.as_deref(),
                category: v.category.as_deref(),
                name: v.inspector_name.as_deref(),
                state: v.state.as_deref(),
                pid: v.pid,
                tid: v.tid,
                jank_tag: v.jank_tag,
            },
            &mut || Ok(()),
        )
        .unwrap();
        common::compare(
            &json!({"name":v.name,"color":color(c),"style":DetailStyle::from_category(v.category.as_deref())}),
            e,
            &v.name,
        );
    }
}
