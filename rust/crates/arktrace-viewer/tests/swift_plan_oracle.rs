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
    request: ViewportRequest,
    event_counts: Vec<i64>,
    detail_depths: Vec<Vec<i64>>,
    truncated: Vec<bool>,
    source_issues: Option<Vec<QualityIssue>>,
}
#[test]
fn retain_measured_swift_difference_only_for_explicit_detail_offscreen_queries() {
    let before: Vec<Value> =
        serde_json::from_str(include_str!("fixtures/swift-plan-oracle.json")).unwrap();
    let after: Vec<Value> =
        serde_json::from_str(include_str!("fixtures/swift-plan-migration-oracle.json")).unwrap();
    assert_eq!(before.len(), 13);
    assert_eq!(after.len(), before.len());
    for (before, after) in before.iter().zip(&after) {
        if before["name"] == "explicit-detail-queries-all-expanded" {
            let expected_before: Vec<_> = (0..60)
                .map(|cpu| json!({"source": TraceDensitySource::Cpu { cpu }, "limit": 33}))
                .collect();
            common::compare(
                &before["detailCalls"],
                &json!(expected_before),
                "before detail calls",
            );
            common::compare(
                &after["detailCalls"],
                &json!([{"source": TraceDensitySource::Cpu { cpu: 0 }, "limit": 2000}]),
                "after detail calls",
            );
            // This is an explicit comparison of independently executed Swift
            // versions. Full Rust replay below compares every field unchanged.
            let mut before_other = before.clone();
            let mut after_other = after.clone();
            before_other.as_object_mut().unwrap().remove("detailCalls");
            after_other.as_object_mut().unwrap().remove("detailCalls");
            common::compare(&before_other, &after_other, "preserved layout and quality");
        } else {
            common::compare(before, after, "unaffected actual Swift vector");
        }
    }
}
#[test]
fn replay_13_actual_swift_loader_query_and_snapshot_vectors_exactly() {
    let inputs: Vec<Vector> =
        serde_json::from_str(include_str!("fixtures/plan-inputs.json")).unwrap();
    let expected: Vec<Value> =
        serde_json::from_str(include_str!("fixtures/swift-plan-migration-oracle.json")).unwrap();
    assert_eq!(inputs.len(), 13);
    assert_eq!(inputs.len(), expected.len());
    for (v, e) in inputs.iter().zip(&expected) {
        let mut check = || Ok(());
        let plan = plan(&v.request, &[], &mut check).unwrap();
        // Adapter supplies the same independent bounded repository pages.
        // Expected LOD/layout/budgets come only from the actual Swift loader.
        let densities: Vec<_> = plan
            .lanes
            .iter()
            .map(|l| TraceDensityResult {
                buckets: vec![TraceDensityBucket {
                    range: v.request.viewport.range(),
                    event_count: v.event_counts[l.request_index],
                    occupied_ns: None,
                    utilization: None,
                    dominant: None,
                }],
                capability_available: true,
                data_quality: common::quality(),
            })
            .collect();
        let mut detail_pages = Vec::new();
        let mut actual_details = Vec::new();
        let mut actual_densities = plan.density_prefetch.clone();
        let mut remaining = plan.maximum_primitives;
        let mut queried_remaining = plan.queried_indices.len();
        for (l, density) in plan.lanes.iter().zip(&densities) {
            let budget = if l.queried {
                plan.lane_budget(remaining, queried_remaining).unwrap()
            } else {
                0
            };
            let mut page = EventPage {
                items: vec![],
                truncated: false,
                capability_available: false,
                data_quality: common::quality(),
            };
            let mut output_count = 0;
            if budget > 0 {
                if plan.fair_budget == 0 && v.request.preference != DetailPreference::Detail {
                    actual_densities.push(TraceDensityQuery {
                        range: v.request.viewport.range(),
                        source: l.source.clone(),
                        bucket_count: density_bucket_limit(v.request.pixel_width, budget).unwrap(),
                    });
                }
                let decision = choose_lod(
                    v.request.preference,
                    v.request.pixel_width,
                    budget,
                    Some(density),
                    &mut check,
                )
                .unwrap();
                if decision.lod == Lod::Detail {
                    actual_details.push(json!({"source":l.source,"limit":budget}));
                    if matches!(l.source, TraceDensitySource::NamedSlice { .. }) {
                        let depths = &v.detail_depths[l.request_index];
                        page.capability_available = true;
                        if let Some(issues) = &v.source_issues {
                            page.data_quality = DataQuality {
                                status: QualityStatus::Warnings,
                                warnings: issues.clone(),
                            };
                        }
                        page.truncated = v.truncated[l.request_index] || depths.len() > budget;
                        page.items = depths
                            .iter()
                            .take(budget)
                            .enumerate()
                            .map(|(j, depth)| DetailInput {
                                event_key: EventKey {
                                    table: EventTable::Callstack,
                                    row_id: (l.request_index * 100 + j + 1) as i64,
                                },
                                range: common::range((j * 10) as i64, (j * 10 + 5) as i64),
                                depth: *depth,
                                style: DetailStyle::Accent,
                                is_open_ended: false,
                            })
                            .collect();
                        output_count = page.items.len();
                    }
                } else if decision.lod == Lod::Density {
                    output_count = density.buckets.len().min(decision.bucket_limit);
                }
            }
            remaining -= output_count;
            if l.queried {
                queried_remaining -= 1;
            }
            detail_pages.push(page);
        }
        let pages: Vec<_> = detail_pages
            .iter()
            .zip(&densities)
            .enumerate()
            .map(|(i, (d, n))| LanePages {
                expanded_index: i,
                detail: Some(d),
                density: Some(n),
            })
            .collect();
        let assembled = assemble(&v.request, &[], &pages, 2.0, &mut check).unwrap();
        let tracks:Vec<Value>=assembled.snapshot.tracks().iter().map(|t| {
            let primitives:Vec<Value>=t.primitives.iter().map(|p|match &p.input {
                PrimitiveInput::Detail{detail}=>json!({"kind":"detail","eventKey":detail.event_key,"range":detail.range,"depth":detail.depth}),
                PrimitiveInput::Density{bucket}=>json!({"kind":"density","bucket":bucket}),
            }).collect();
            json!({"trackID":t.descriptor.id(),"y":t.y,"height":t.height,"depthRowCount":t.depth_row_count,"primitives":primitives})
        }).collect();
        let result = json!({"name":v.name,"maximumPrimitives":plan.maximum_primitives,"densityCalls":actual_densities,"detailCalls":actual_details,
            "batches":plan.density_batches.iter().map(Vec::len).collect::<Vec<_>>(),"tracks":tracks,"qualityFacts":assembled.quality_facts,"sourceFacts":assembled.snapshot.data_quality().warnings.iter().map(|i|json!({"category":i.category,"scope":i.scope,"count":i.count})).collect::<Vec<_>>()});
        common::compare(&result, e, &v.name);
    }
}
