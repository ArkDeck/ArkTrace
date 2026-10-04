#[allow(dead_code)]
mod common;
use arktrace_contract::*;
use arktrace_viewer::*;
use serde::Deserialize;
use serde_json::{Value, json};
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Dto {
    name: String,
    range: TraceTimeRange,
    shows_nested_depth: bool,
    cpu: Vec<CpuSlice>,
    thread_states: Vec<ThreadStateInterval>,
    slices: Vec<TraceSlice>,
    counters: Vec<CounterSeries>,
    frames: Vec<TraceFrame>,
    capability_available: bool,
}
#[test]
fn actual_swift_loader_labels_classification_color_and_identity_from_store_dtos() {
    let root: Value =
        serde_json::from_str(include_str!("fixtures/presentation-inputs.json")).unwrap();
    let expected: Value =
        serde_json::from_str(include_str!("fixtures/presentation-swift-oracle.json")).unwrap();
    let cases: Vec<Dto> = serde_json::from_value(root["dto"].clone()).unwrap();
    assert_eq!(cases.len(), 62);
    for (v, e) in cases.iter().zip(expected["dto"].as_array().unwrap()) {
        let mut inputs = Vec::new();
        if v.capability_available {
            inputs.extend(v.cpu.iter().map(PresentationInput::Cpu));
            inputs.extend(v.thread_states.iter().map(PresentationInput::ThreadState));
            inputs.extend(v.slices.iter().map(|event| PresentationInput::NamedSlice {
                event,
                shows_nested_depth: v.shows_nested_depth,
            }));
            for series in &v.counters {
                for sample_index in 0..series.samples.len() {
                    inputs.push(PresentationInput::Counter {
                        series,
                        sample_index,
                        query_range: v.range,
                    });
                }
            }
            inputs.extend(v.frames.iter().map(PresentationInput::Frame));
        }
        let batch = present(&inputs, PresentationBudget::default(), &mut || Ok(())).unwrap();
        let facts:Vec<Value>=batch.primitives().iter().map(|p|{let PrimitivePresentation::Detail{detail:d}=p else{panic!("detail expected")};let c=d.color;
   json!({"key":d.event_key,"kind":d.kind,"range":d.range,"isOpenEnded":d.is_open_ended,"isInstant":d.is_instant,"depth":d.depth,"jankTag":d.jank_tag,"identity":d.identity,"label":batch.text(d.label),"category":batch.text(d.category),"state":batch.text(d.state),"style":d.style,"color":{"rgb":c.fill,"rgba":[c.rgba.red,c.rgba.green,c.rgba.blue,c.rgba.alpha],"foreground":c.label_foreground}})
  }).collect();
        common::compare(&json!({"name":v.name,"facts":facts}), e, &v.name);
    }
}
