#[allow(dead_code)]
mod common;
use arktrace_contract::*;
use arktrace_viewer::*;
use common::*;
use serde::Deserialize;
use serde_json::{Value, json};
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Vector {
    name: String,
    source: TraceDensitySource,
    range: TraceTimeRange,
    shows_nested_depth: bool,
    cpu: Vec<CpuSlice>,
    thread_states: Vec<ThreadStateInterval>,
    slices: Vec<TraceSlice>,
    counters: Vec<CounterSeries>,
    frames: Vec<TraceFrame>,
    truncated: bool,
    capability_available: bool,
}
impl Vector {
    fn page(&self) -> RepositoryDetailPage {
        macro_rules! page {
            ($items:expr) => {
                EventPage {
                    items: $items.clone(),
                    truncated: self.truncated,
                    capability_available: self.capability_available,
                    data_quality: quality(),
                }
            };
        }
        match self.source {
            TraceDensitySource::Cpu { .. } => RepositoryDetailPage::Cpu(page!(self.cpu)),
            TraceDensitySource::ThreadState { .. } => {
                RepositoryDetailPage::ThreadState(page!(self.thread_states))
            }
            TraceDensitySource::NamedSlice { .. } => {
                RepositoryDetailPage::NamedSlice(page!(self.slices))
            }
            TraceDensitySource::Frame { .. } => RepositoryDetailPage::Frame(page!(self.frames)),
            _ => RepositoryDetailPage::Counter(page!(self.counters)),
        }
    }
}
fn vectors() -> Vec<Vector> {
    serde_json::from_str(include_str!("fixtures/detail-inputs.json")).unwrap()
}
#[test]
fn replay_eight_actual_swift_loader_dto_mapping_vectors_exactly() {
    let expected: Vec<Value> =
        serde_json::from_str(include_str!("fixtures/swift-detail-oracle.json")).unwrap();
    let vectors = vectors();
    assert_eq!(vectors.len(), 8);
    assert_eq!(vectors.len(), expected.len());
    for (v, e) in vectors.iter().zip(expected) {
        let page = map_detail_page(&v.source, v.range, 3200, v.page(), &mut || Ok(())).unwrap();
        let r = ViewportRequest {
            viewport: Viewport::new(v.range, 200.0, 1000.0, 0.0, 1).unwrap(),
            tracks: vec![TrackDescriptor {
                source: v.source.clone(),
                is_collapsed: false,
                shows_nested_depth: v.shows_nested_depth,
            }],
            pixel_width: 400,
            generation: 1,
            preference: DetailPreference::Detail,
            maximum_primitives: None,
            focused_event_key: None,
        };
        let a = assemble(
            &r,
            &[],
            &[LanePages {
                expanded_index: 0,
                detail: Some(&page),
                density: None,
            }],
            2.0,
            &mut || Ok(()),
        )
        .unwrap();
        let track = &a.snapshot.tracks()[0];
        let details: Vec<Value> = track
            .primitives
            .iter()
            .map(|p| {
                let PrimitiveInput::Detail { detail } = &p.input else {
                    panic!("detail request produced density")
                };
                serde_json::to_value(detail).unwrap()
            })
            .collect();
        // Style comes from the actual private Swift renderer method via a
        // cache-only access seam. No copied normalization or range formulas.
        let facts: Vec<_> = a
            .snapshot
            .data_quality()
            .warnings
            .iter()
            .map(|i| json!({"category":i.category,"scope":i.scope,"count":i.count}))
            .collect();
        compare(
            &json!({"name":v.name,"details":details,"depthRowCount":track.depth_row_count,"height":track.height,"qualityFacts":facts}),
            &e,
            &v.name,
        );
    }
}
#[test]
fn detail_mapping_rejects_wrong_family_lane_and_table_identity() {
    let v = &vectors()[0];
    assert_eq!(
        map_detail_page(
            &TraceDensitySource::Frame { process_key: None },
            v.range,
            10,
            v.page(),
            &mut || Ok(())
        ),
        Err(ViewerError::InvalidEvidence)
    );
    assert_eq!(
        map_detail_page(
            &TraceDensitySource::Cpu { cpu: 4 },
            v.range,
            10,
            v.page(),
            &mut || Ok(())
        ),
        Err(ViewerError::InvalidEvidence)
    );
    let mut page = v.page();
    let RepositoryDetailPage::Cpu(p) = &mut page else {
        unreachable!()
    };
    p.items[0].key.table = EventTable::Callstack;
    assert_eq!(
        map_detail_page(&v.source, v.range, 10, page, &mut || Ok(())),
        Err(ViewerError::InvalidEvidence)
    );
}
#[test]
fn counter_mapping_rejects_overflow_negative_duration_and_total_sample_overrun() {
    let v = &vectors()[4];
    for (timestamp, duration, expected) in [
        (i64::MAX, Some(1), ViewerError::ArithmeticOverflow),
        (0, Some(-1), ViewerError::InvalidEvidence),
    ] {
        let mut page = v.page();
        let RepositoryDetailPage::Counter(p) = &mut page else {
            unreachable!()
        };
        p.items[0].samples[0].timestamp_ns = timestamp;
        p.items[0].samples[0].duration_ns = duration;
        assert_eq!(
            map_detail_page(&v.source, v.range, 10, page, &mut || Ok(())),
            Err(expected)
        );
    }
    let mut page = v.page();
    let RepositoryDetailPage::Counter(p) = &mut page else {
        unreachable!()
    };
    p.items.push(p.items[0].clone());
    assert_eq!(
        map_detail_page(&v.source, v.range, 7, page, &mut || Ok(())),
        Err(ViewerError::InputBudgetExceeded)
    );
}
#[test]
fn unavailable_detail_pages_cannot_publish_rows_or_truncation_and_check_is_live() {
    let v = &vectors()[0];
    let mut page = v.page();
    let RepositoryDetailPage::Cpu(p) = &mut page else {
        unreachable!()
    };
    p.capability_available = false;
    assert_eq!(
        map_detail_page(&v.source, v.range, 10, page, &mut || Ok(())),
        Err(ViewerError::InvalidEvidence)
    );
    let mut checks = 0;
    assert_eq!(
        map_detail_page(&v.source, v.range, 10, v.page(), &mut || {
            checks += 1;
            if checks == 2 {
                Err(ViewerError::Cancelled)
            } else {
                Ok(())
            }
        }),
        Err(ViewerError::Cancelled)
    );
    assert_eq!(checks, 2);
    assert!(map_detail_page(&v.source, v.range, 10, v.page(), &mut || Ok(())).is_ok());
}
