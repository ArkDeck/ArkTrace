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
struct Repository<'a> {
    vector: &'a Vector,
    density_calls: Vec<TraceDensityQuery>,
    detail_calls: Vec<Value>,
    batches: Vec<usize>,
}
impl Repository<'_> {
    fn index(&self, source: &TraceDensitySource) -> usize {
        self.vector
            .request
            .tracks
            .iter()
            .position(|t| t.source == *source)
            .unwrap()
    }
    fn density_page(&self, query: &TraceDensityQuery) -> TraceDensityResult {
        TraceDensityResult {
            buckets: vec![TraceDensityBucket {
                range: query.range,
                event_count: self.vector.event_counts[self.index(&query.source)],
                occupied_ns: None,
                utilization: None,
                dominant: None,
            }],
            capability_available: true,
            data_quality: common::quality(),
        }
    }
}
impl ViewportQueries for Repository<'_> {
    type Error = ViewerError;
    fn density_batch(
        &mut self,
        queries: &[TraceDensityQuery],
    ) -> Result<Vec<TraceDensityResult>, ViewerError> {
        self.batches.push(queries.len());
        self.density_calls.extend_from_slice(queries);
        Ok(queries.iter().map(|q| self.density_page(q)).collect())
    }
    fn density(&mut self, query: &TraceDensityQuery) -> Result<TraceDensityResult, ViewerError> {
        self.density_calls.push(query.clone());
        Ok(self.density_page(query))
    }
    fn details(
        &mut self,
        source: &TraceDensitySource,
        _range: TraceTimeRange,
        limit: usize,
        _focused: Option<EventKey>,
    ) -> Result<EventPage<DetailInput>, ViewerError> {
        self.detail_calls
            .push(json!({"source":source,"limit":limit}));
        let index = self.index(source);
        let mut page = EventPage {
            items: vec![],
            truncated: false,
            capability_available: false,
            data_quality: common::quality(),
        };
        if matches!(source, TraceDensitySource::NamedSlice { .. }) {
            page.capability_available = true;
            if let Some(issues) = &self.vector.source_issues {
                page.data_quality = DataQuality {
                    status: QualityStatus::Warnings,
                    warnings: issues.clone(),
                };
            }
            let depths = &self.vector.detail_depths[index];
            page.truncated = self.vector.truncated[index] || depths.len() > limit;
            page.items = depths
                .iter()
                .take(limit)
                .enumerate()
                .map(|(j, depth)| DetailInput {
                    event_key: EventKey {
                        table: EventTable::Callstack,
                        row_id: (index * 100 + j + 1) as i64,
                    },
                    range: common::range((j * 10) as i64, (j * 10 + 5) as i64),
                    depth: *depth,
                    style: DetailStyle::Accent,
                    is_open_ended: false,
                })
                .collect();
        }
        Ok(page)
    }
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
        let mut repository = Repository {
            vector: v,
            density_calls: Vec::new(),
            detail_calls: Vec::new(),
            batches: Vec::new(),
        };
        let assembled = ViewportLoader::default()
            .load(&v.request, 2.0, &mut repository, &mut check)
            .unwrap()
            .unwrap();
        let tracks:Vec<Value>=assembled.snapshot.tracks().iter().map(|t| {
            let primitives:Vec<Value>=t.primitives.iter().map(|p|match &p.input {
                PrimitiveInput::Detail{detail}=>json!({"kind":"detail","eventKey":detail.event_key,"range":detail.range,"depth":detail.depth}),
                PrimitiveInput::Density{bucket}=>json!({"kind":"density","bucket":bucket}),
            }).collect();
            json!({"trackID":t.descriptor.id(),"y":t.y,"height":t.height,"depthRowCount":t.depth_row_count,"primitives":primitives})
        }).collect();
        let result = json!({"name":v.name,"maximumPrimitives":plan.maximum_primitives,"densityCalls":repository.density_calls,"detailCalls":repository.detail_calls,
            "batches":repository.batches,"tracks":tracks,"qualityFacts":assembled.quality_facts,"sourceFacts":assembled.snapshot.data_quality().warnings.iter().filter(|i| !i.scope.as_deref().is_some_and(|s| s.starts_with("timeline."))).map(|i|json!({"category":i.category,"scope":i.scope,"count":i.count})).collect::<Vec<_>>()});
        let mut full_expected: Vec<QualityIssue> = ["sourceFacts", "qualityFacts"]
            .into_iter()
            .flat_map(|name| e[name].as_array().unwrap())
            .map(|fact| QualityIssue {
                category: serde_json::from_value(fact["category"].clone()).unwrap(),
                scope: fact["scope"].as_str().map(str::to_owned),
                count: fact["count"].as_i64(),
                message: None,
            })
            .collect();
        let status = if full_expected.is_empty() {
            QualityStatus::Ok
        } else {
            QualityStatus::Warnings
        };
        let expected_quality =
            DataQuality::machine(status, std::mem::take(&mut full_expected)).unwrap();
        assert_eq!(
            assembled.snapshot.data_quality(),
            &expected_quality,
            "{} complete quality envelope",
            v.name
        );
        common::compare(&result, e, &v.name);
    }
}
