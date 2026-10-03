#[allow(dead_code)]
mod common;
use arktrace_contract::*;
use arktrace_viewer::*;
use common::*;
use serde_json::json;
#[test]
fn viewport_rejects_nonfinite_degenerate_and_inconsistent_scale() {
    for width in [0.0, -1.0, f64::NAN, f64::INFINITY, f64::MIN_POSITIVE] {
        assert!(Viewport::new(range(0, i64::MAX), width, 80.0, 0.0, 1).is_err());
    }
    assert!(Viewport::new(range(5, 5), 100.0, 80.0, 0.0, 1).is_err());
    assert!(Viewport::new(range(0, 1000), 100.0, 80.0, -1.0, 1).is_err());
    let mut wire = serde_json::to_value(viewport()).unwrap();
    wire["nsPerPoint"] = json!(999);
    assert!(serde_json::from_value::<Viewport>(wire).is_err());
}
#[test]
fn local_subtraction_and_interior_floor_survive_int64_extremes() {
    let v = Viewport::new(range(i64::MAX - 1000, i64::MAX), 100.0, 80.0, 0.0, 1).unwrap();
    assert_eq!(v.x(i64::MAX - 999).to_bits(), 0.1_f64.to_bits());
    assert_eq!(v.time(50.0).unwrap(), i64::MAX - 500);
    let huge = Viewport::new(range(0, i64::MAX), 100.0, 80.0, 0.0, 1).unwrap();
    assert_eq!(huge.time(100.0).unwrap(), i64::MAX);
    assert!(huge.time(f64::from_bits(100.0_f64.to_bits() - 1)).unwrap() < i64::MAX);
}
#[test]
fn nonfinite_requests_reject_and_finite_pan_overflow_saturates() {
    let v = viewport();
    for x in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
        assert_eq!(v.nanosecond_delta(x), Err(ViewerError::InvalidGeometry));
        assert_eq!(v.time(x), Err(ViewerError::InvalidGeometry));
    }
    assert_eq!(v.nanosecond_delta(1e300).unwrap(), i64::MAX);
    assert_eq!(v.nanosecond_delta(-1e300).unwrap(), i64::MIN);
    assert_eq!(v.nanosecond_delta(0.1).unwrap(), 1);
    assert_eq!(v.nanosecond_delta(-0.1).unwrap(), -1);
}
#[test]
fn instant_and_open_ended_keep_domain_identity_while_expanding_one_pixel() {
    let d = detail(8, 500, 500, 0, DetailStyle::Running);
    let mut opened = d.clone();
    opened.is_open_ended = true;
    assert!(d.is_instant());
    assert!(!opened.is_instant());
    let t = track(vec![PrimitiveInput::Detail {
        detail: opened.clone(),
    }]);
    let s = project(&viewport(), 1, &[t], 4.0, &quality(), &mut || Ok(())).unwrap();
    assert_eq!(
        s.tracks()[0].primitives[0].input,
        PrimitiveInput::Detail { detail: opened }
    );
    assert_eq!(s.visible_frames().next().unwrap().width, 0.25);
}
#[test]
fn inclusive_visual_edges_preserve_domain_halfopen_contract() {
    let v = viewport();
    let edge = range(1000, 1000);
    assert!(!edge.intersects(v.range()));
    assert!(is_visible(edge, &v));
    let stale = range(1001, 1100);
    assert!(!is_visible(stale, &v));
    let t = track(vec![PrimitiveInput::Detail {
        detail: detail(1, 1001, 1100, 0, DetailStyle::Accent),
    }]);
    let s = project(&v, 0, &[t], 2.0, &quality(), &mut || Ok(())).unwrap();
    assert_eq!(s.source_generation(), 0);
    assert_eq!(s.visible_frames().count(), 0);
    assert!(
        s.detail_hit(Point { x: 200.0, y: 26.0 }, &mut || Ok(()))
            .unwrap()
            .is_none()
    );
}
#[test]
fn detail_hit_uses_style_then_later_input_not_duration_or_rowid() {
    let t = track(vec![
        PrimitiveInput::Detail {
            detail: detail(1, 250, 500, 0, DetailStyle::Running),
        },
        PrimitiveInput::Detail {
            detail: detail(100, 250, 250, 0, DetailStyle::Accent),
        },
        PrimitiveInput::Detail {
            detail: detail(900, 250, 251, 0, DetailStyle::Accent),
        },
    ]);
    let s = project(&viewport(), 1, &[t], 2.0, &quality(), &mut || Ok(())).unwrap();
    assert_eq!(
        s.detail_hit(Point { x: 50.0, y: 26.0 }, &mut || Ok(()))
            .unwrap()
            .unwrap()
            .row_id,
        900
    );
    assert!(
        s.detail_hit(Point { x: 50.0, y: 50.0 }, &mut || Ok(()))
            .unwrap()
            .is_none()
    );
}
#[test]
fn density_row_hit_keeps_first_closed_boundary_and_real_resolution_intent() {
    let t = track(vec![
        PrimitiveInput::Density {
            bucket: bucket(0, 500, 1),
        },
        PrimitiveInput::Density {
            bucket: bucket(500, 1000, 100000),
        },
    ]);
    let s = project(&viewport(), 1, &[t], 2.0, &quality(), &mut || Ok(())).unwrap();
    let h = s
        .density_hit(Point { x: 100.0, y: 49.0 }, &mut || Ok(()))
        .unwrap()
        .unwrap();
    assert_eq!(h.bucket, range(0, 500));
    assert_eq!(h.time_ns, 500);
    assert_eq!(
        h.covering.unwrap(),
        ResolutionQuery {
            range: range(500, 501),
            limit: 64
        }
    );
    assert_eq!(
        h.fallback,
        ResolutionQuery {
            range: range(0, 500),
            limit: 512
        }
    );
    assert_eq!(
        s.density_hit(Point { x: 200.0, y: 25.0 }, &mut || Ok(()))
            .unwrap()
            .unwrap()
            .time_ns,
        1000
    );
    assert!(
        s.density_hit(Point { x: -0.1, y: 25.0 }, &mut || Ok(()))
            .unwrap()
            .is_none()
    );
}
#[test]
fn density_int64_max_has_no_overflowing_covering_query() {
    let v = Viewport::new(range(i64::MAX - 1000, i64::MAX), 100.0, 80.0, 0.0, 1).unwrap();
    let t = track(vec![PrimitiveInput::Density {
        bucket: bucket(i64::MAX - 1000, i64::MAX, 1),
    }]);
    let s = project(&v, 1, &[t], 2.0, &quality(), &mut || Ok(())).unwrap();
    let h = s
        .density_hit(Point { x: 100.0, y: 25.0 }, &mut || Ok(()))
        .unwrap()
        .unwrap();
    assert!(h.covering.is_none());
    assert_eq!(h.fallback.limit, 512);
}
#[test]
fn resolver_is_nearest_then_longest_then_lowest_actual_rowid() {
    let rows = vec![
        detail(100, 450, 550, 0, DetailStyle::Running),
        detail(5, 400, 600, 0, DetailStyle::Running),
        detail(2, 400, 600, 0, DetailStyle::Running),
    ];
    assert_eq!(
        resolve_candidate(500, &rows, &mut || Ok(()))
            .unwrap()
            .unwrap()
            .row_id,
        2
    );
    assert_eq!(
        resolve_candidate(600, &rows, &mut || Ok(()))
            .unwrap()
            .unwrap()
            .row_id,
        2
    );
    assert_eq!(
        resolve_candidate(500, &vec![rows[0].clone(); 513], &mut || Ok(())),
        Err(ViewerError::InputBudgetExceeded)
    );
}
#[test]
fn depth_cap_preserves_event_and_extreme_depth_never_adds_overflow() {
    let d = depth_layout([0, 31, 32, i64::MAX], &mut || Ok(())).unwrap();
    assert_eq!(d.rows, 32);
    assert!(d.truncated);
    assert_eq!(d.observed_depth, i64::MAX);
    let mut t = track(vec![]);
    t.depth_row_count = 32;
    t.height = track_height(32).unwrap();
    let f = detail_frame(
        &detail(1, 0, 1000, i64::MAX, DetailStyle::Running),
        &t,
        &viewport(),
        2.0,
    )
    .unwrap();
    assert_eq!(f.y, 707.0);
    assert_eq!(f.height, 22.0);
}
#[test]
fn invalid_scale_track_and_density_fail_without_partial_snapshot() {
    for scale in [0.0, -1.0, f64::NAN, f64::INFINITY] {
        assert!(
            project(
                &viewport(),
                1,
                &[track(vec![])],
                scale,
                &quality(),
                &mut || Ok(())
            )
            .is_err()
        );
    }
    let mut t = track(vec![]);
    t.height = f64::INFINITY;
    assert!(project(&viewport(), 1, &[t], 2.0, &quality(), &mut || Ok(())).is_err());
    let t = track(vec![PrimitiveInput::Density {
        bucket: bucket(0, 500, -1),
    }]);
    assert!(project(&viewport(), 1, &[t], 2.0, &quality(), &mut || Ok(())).is_err());
    assert!(
        project(
            &viewport(),
            1,
            &[track(vec![])],
            2.0,
            &quality(),
            &mut || Ok(())
        )
        .is_ok()
    );
}
#[test]
fn pan_and_zoom_clamp_safely_while_preserving_anchor() {
    let r = range(i64::MAX - 1000, i64::MAX);
    let bounds = range(0, i64::MAX);
    assert_eq!(pan(r, i64::MAX, bounds).unwrap(), r);
    assert_eq!(pan(r, i64::MIN, bounds).unwrap(), range(0, 1000));
    assert_eq!(
        zoom(range(100, 300), 200, 0.5, range(0, 1000)).unwrap(),
        range(150, 250)
    );
    assert_eq!(zoom(r, i64::MAX, 20.0, bounds).unwrap().end_ns(), i64::MAX);
    assert!(zoom(r, i64::MAX, 0.0, bounds).is_err());
    assert!(zoom(r, i64::MAX, f64::NAN, bounds).is_err());
}
#[test]
fn new_selection_zero_clears_endpoint_zero_preserves_and_crossing_reorders() {
    let v = viewport();
    let previous = Some(range(400, 600));
    assert_eq!(
        selection_drag(&v, 500, 100.0, SelectionDrag::NewRange, previous).unwrap(),
        None
    );
    assert_eq!(
        selection_drag(&v, 500, 100.0, SelectionDrag::Endpoint, previous).unwrap(),
        previous
    );
    assert_eq!(
        selection_drag(&v, 500, 20.0, SelectionDrag::Endpoint, previous).unwrap(),
        Some(range(100, 500))
    );
    assert_eq!(
        selection_drag(&v, 500, 180.0, SelectionDrag::Endpoint, previous).unwrap(),
        Some(range(500, 900))
    );
}
#[test]
fn narrow_selection_midpoint_is_closed_and_start_wins() {
    let v = viewport();
    let s = range(500, 510);
    assert_eq!(
        selection_endpoint(Point { x: 101.0, y: 22.0 }, s, &v).unwrap(),
        Some(SelectionEndpoint::Start)
    );
    assert_eq!(
        selection_endpoint(Point { x: 101.5, y: 22.0 }, s, &v).unwrap(),
        Some(SelectionEndpoint::End)
    );
    assert_eq!(
        selection_endpoint(Point { x: 101.0, y: 21.0 }, s, &v).unwrap(),
        None
    );
}
#[test]
fn request_caps_generation_and_budget_are_enforced() {
    let mut r = request(1, 20000, DetailPreference::Automatic);
    r.pixel_width = 1;
    assert_eq!(r.effective_budget().unwrap(), 2000);
    r.generation = 2;
    assert!(plan(&r, &[], &mut || Ok(())).is_err());
    r.generation = 1;
    r.pixel_width = 0;
    assert!(plan(&r, &[], &mut || Ok(())).is_err());
    let mut r = request(10001, 20, DetailPreference::Detail);
    assert!(plan(&r, &[], &mut || Ok(())).is_err());
    r.tracks.clear();
    r.maximum_primitives = Some(0);
    assert!(plan(&r, &[], &mut || Ok(())).is_err());
}
#[test]
fn explicit_detail_keeps_overscan_without_querying_offscreen_lanes() {
    let a = request(100, 2000, DetailPreference::Automatic);
    let automatic = plan(&a, &[], &mut || Ok(())).unwrap();
    assert!(automatic.queried_indices.len() < 100);
    let mut d = a.clone();
    d.preference = DetailPreference::Detail;
    let detail = plan(&d, &[], &mut || Ok(())).unwrap();
    assert_eq!(detail.queried_indices, automatic.queried_indices);
    assert_eq!(detail.lanes.len(), 100);
    assert_eq!(detail.fair_budget, automatic.fair_budget);
    assert!(detail.density_prefetch.is_empty());
    d.tracks[0].is_collapsed = true;
    assert_eq!(plan(&d, &[], &mut || Ok(())).unwrap().lanes.len(), 99);
}
#[test]
fn density_prefetch_chunks_are_bounded_and_unused_share_stays_capped() {
    let mut r = request(65, 260, DetailPreference::Density);
    r.viewport = Viewport::new(range(0, 1000), 200.0, 2000.0, 0.0, 1).unwrap();
    let p = plan(&r, &[], &mut || Ok(())).unwrap();
    assert_eq!(
        p.density_batches.iter().map(Vec::len).collect::<Vec<_>>(),
        vec![32, 32, 1]
    );
    assert_eq!(p.lane_budget(260, 1).unwrap(), 4);
    assert!(p.density_prefetch.iter().all(|q| q.bucket_count == 4));
    let p = plan(&request(4, 3, DetailPreference::Density), &[], &mut || {
        Ok(())
    })
    .unwrap();
    assert_eq!(p.fair_budget, 0);
    assert!(p.density_prefetch.is_empty());
    assert_eq!(p.lane_budget(3, 4).unwrap(), 1);
}
#[test]
fn lod_threshold_unavailable_invalid_and_checked_count_sum_are_explicit() {
    assert_eq!(
        choose_lod(
            DetailPreference::Automatic,
            800,
            4,
            Some(&density(4)),
            &mut || Ok(())
        )
        .unwrap()
        .lod,
        Lod::Detail
    );
    assert_eq!(
        choose_lod(
            DetailPreference::Automatic,
            800,
            4,
            Some(&density(5)),
            &mut || Ok(())
        )
        .unwrap()
        .lod,
        Lod::Density
    );
    let mut unavailable = density(1);
    unavailable.capability_available = false;
    unavailable.buckets.clear();
    assert_eq!(
        choose_lod(
            DetailPreference::Automatic,
            800,
            4,
            Some(&unavailable),
            &mut || Ok(())
        )
        .unwrap()
        .lod,
        Lod::Unavailable
    );
    let mut overflow = density(i64::MAX);
    overflow.buckets.push(bucket(0, 1000, 1));
    assert_eq!(
        choose_lod(
            DetailPreference::Automatic,
            800,
            4,
            Some(&overflow),
            &mut || Ok(())
        ),
        Err(ViewerError::ArithmeticOverflow)
    );
}
#[test]
fn cached_rows_affect_overscan_and_invalid_cache_is_rejected() {
    let r = request(10, 2000, DetailPreference::Automatic);
    let uncached = plan(&r, &[], &mut || Ok(())).unwrap();
    let cache = vec![CachedDepth {
        track_id: "cpu:0".into(),
        rows: 32,
    }];
    let cached = plan(&r, &cache, &mut || Ok(())).unwrap();
    assert!(cached.queried_indices.len() < uncached.queried_indices.len());
    assert_eq!(cached.lanes[0].height, 710.0);
    assert!(
        plan(
            &r,
            &[CachedDepth {
                track_id: "cpu:0".into(),
                rows: 33
            }],
            &mut || Ok(())
        )
        .is_err()
    );
    assert!(plan(&r, &[cache[0].clone(), cache[0].clone()], &mut || Ok(())).is_err());
}
#[test]
fn source_truncation_and_depth_facts_survive_flattening_rules() {
    let mut r = request(1, 10, DetailPreference::Detail);
    r.tracks[0].source = TraceDensitySource::NamedSlice { thread: None };
    let page = EventPage {
        items: vec![detail(1, 0, 10, 99, DetailStyle::Accent)],
        truncated: true,
        capability_available: true,
        data_quality: quality(),
    };
    let pages = [LanePages {
        expanded_index: 0,
        detail: Some(&page),
        density: None,
    }];
    let a = assemble(&r, &[], &pages, 2.0, &mut || Ok(())).unwrap();
    assert_eq!(a.snapshot.tracks()[0].depth_row_count, 32);
    assert_eq!(a.quality_facts.len(), 2);
    assert_eq!(a.snapshot.data_quality().status, QualityStatus::Warnings);
    assert_eq!(a.snapshot.data_quality().warnings.len(), 2);
    assert_eq!(a.snapshot.tracks()[0].primitives.len(), 1);
    r.tracks[0].shows_nested_depth = false;
    let a = assemble(&r, &[], &pages, 2.0, &mut || Ok(())).unwrap();
    assert_eq!(a.snapshot.tracks()[0].depth_row_count, 1);
    assert_eq!(a.quality_facts.len(), 1);
    assert_eq!(a.quality_facts[0].scope, ViewerQualityScope::NamedSlice);
    assert_eq!(a.snapshot.data_quality().warnings.len(), 1);
}
#[test]
fn all_viewer_degradations_contribute_to_the_complete_snapshot_quality() {
    let mut r = request(6, 2000, DetailPreference::Detail);
    r.viewport = Viewport::new(range(0, 1000), 200.0, 2000.0, 0.0, 1).unwrap();
    let sources = [
        TraceDensitySource::Cpu { cpu: 0 },
        TraceDensitySource::ThreadState {
            thread: ThreadKey { itid: 1 },
        },
        TraceDensitySource::NamedSlice { thread: None },
        TraceDensitySource::Frame { process_key: None },
        TraceDensitySource::CpuCounter {
            filter_id: 1,
            cpu: Some(0),
        },
        TraceDensitySource::ProcessCounter {
            filter_id: 2,
            process_key: None,
        },
    ];
    for (track, source) in r.tracks.iter_mut().zip(sources) {
        track.source = source;
    }
    let detail_pages: Vec<_> = (0..6)
        .map(|i| EventPage {
            items: vec![detail(
                i,
                0,
                10,
                if i == 2 { 99 } else { 0 },
                DetailStyle::Accent,
            )],
            truncated: true,
            capability_available: true,
            data_quality: quality(),
        })
        .collect();
    let pages: Vec<_> = detail_pages
        .iter()
        .enumerate()
        .map(|(i, page)| LanePages {
            expanded_index: i,
            detail: Some(page),
            density: None,
        })
        .collect();
    let a = assemble(&r, &[], &pages, 2.0, &mut || Ok(())).unwrap();
    let q = a.snapshot.data_quality();
    assert_eq!(q.status, QualityStatus::Warnings);
    assert_eq!(
        q.warnings.len(),
        6,
        "counter lanes share one identical quality fact"
    );
    assert_eq!(
        q.warnings
            .iter()
            .map(|i| i.scope.as_deref().unwrap())
            .collect::<Vec<_>>(),
        vec![
            "timeline.counter",
            "timeline.cpu",
            "timeline.frame",
            "timeline.namedSlice",
            "timeline.namedSlice.depth",
            "timeline.threadState"
        ]
    );
    assert!(
        q.warnings
            .iter()
            .all(|i| i.category == QualityCategory::ProbeTruncated && i.message.is_none())
    );
}
#[test]
fn source_and_derived_quality_share_one_cap_and_full_identity_deduplication() {
    let r = request(1, 10, DetailPreference::Detail);
    let mut page = EventPage {
        items: vec![],
        truncated: true,
        capability_available: true,
        data_quality: DataQuality::machine(
            QualityStatus::Warnings,
            (0..4096)
                .map(|count| QualityIssue {
                    category: QualityCategory::InvalidValue,
                    scope: Some("sched_slice.value".into()),
                    count: Some(count),
                    message: None,
                })
                .collect(),
        )
        .unwrap(),
    };
    let run = |page: &EventPage<DetailInput>| {
        assemble(
            &r,
            &[],
            &[LanePages {
                expanded_index: 0,
                detail: Some(page),
                density: None,
            }],
            2.0,
            &mut || Ok(()),
        )
    };
    assert_eq!(
        run(&page),
        Err(ViewerError::Quality(
            ContractError::QualityItemBudgetExceeded
        ))
    );
    page.data_quality.warnings[0] = QualityIssue {
        category: QualityCategory::ProbeTruncated,
        scope: Some("timeline.cpu".into()),
        count: None,
        message: None,
    };
    let accepted = run(&page).unwrap();
    assert_eq!(accepted.snapshot.data_quality().warnings.len(), 4096);
    page.data_quality.warnings[0].message = Some("/private/source.htrace".into());
    assert_eq!(
        run(&page),
        Err(ViewerError::Quality(
            ContractError::QualityItemBudgetExceeded
        )),
        "different diagnostic identities cannot be collapsed after redaction to evade the cap"
    );
}
#[test]
fn assembly_requires_selected_pages_and_enforces_output_budget() {
    let r = request(1, 1, DetailPreference::Detail);
    assert!(assemble(&r, &[], &[], 2.0, &mut || Ok(())).is_err());
    let page = EventPage {
        items: vec![detail(1, 0, 10, 0, DetailStyle::Accent); 2],
        truncated: false,
        capability_available: true,
        data_quality: quality(),
    };
    assert_eq!(
        assemble(
            &r,
            &[],
            &[LanePages {
                expanded_index: 0,
                detail: Some(&page),
                density: None
            }],
            2.0,
            &mut || Ok(())
        ),
        Err(ViewerError::InputBudgetExceeded)
    );
}
#[test]
fn cancellation_and_deadline_checkpoint_abort_then_allow_fresh_request() {
    let t = track(
        (0..20000)
            .map(|i| PrimitiveInput::Detail {
                detail: detail(i, 0, 1000, 0, DetailStyle::Running),
            })
            .collect(),
    );
    let mut calls = 0;
    let mut check = || {
        calls += 1;
        if calls == 4 {
            Err(ViewerError::Cancelled)
        } else {
            Ok(())
        }
    };
    assert_eq!(
        project(&viewport(), 1, &[t], 2.0, &quality(), &mut check),
        Err(ViewerError::Cancelled)
    );
    assert_eq!(calls, 4);
    assert_eq!(
        plan(
            &request(1, 10, DetailPreference::Automatic),
            &[],
            &mut || Err(ViewerError::DeadlineReached)
        ),
        Err(ViewerError::DeadlineReached)
    );
    assert!(project(&viewport(), 1, &[], 2.0, &quality(), &mut || Ok(())).is_ok());
}
#[test]
fn source_machine_quality_strips_diagnostics_and_rejects_unknown_scopes() {
    let raw = DataQuality {
        status: QualityStatus::Warnings,
        warnings: vec![QualityIssue {
            category: QualityCategory::ProbeTruncated,
            scope: Some("callstack.depth".into()),
            count: Some(2),
            message: Some("/private/user/path".into()),
        }],
    };
    let s = project(&viewport(), 1, &[], 2.0, &raw, &mut || Ok(())).unwrap();
    assert!(s.data_quality().warnings[0].message.is_none());
    let mut unknown = raw;
    unknown.warnings[0].scope = Some("timeline.namedSlice.typo".into());
    assert_eq!(
        project(&viewport(), 1, &[], 2.0, &unknown, &mut || Ok(())),
        Err(ViewerError::Quality(
            ContractError::DataQualityNotMachineSafe
        ))
    );
}
#[test]
fn identical_derived_quality_facts_keep_first_occurrence_like_swift() {
    let mut r = request(2, 10, DetailPreference::Detail);
    r.tracks[0].source = TraceDensitySource::NamedSlice {
        thread: Some(ThreadKey { itid: 1 }),
    };
    r.tracks[1].source = TraceDensitySource::NamedSlice {
        thread: Some(ThreadKey { itid: 2 }),
    };
    let page = EventPage {
        items: vec![],
        truncated: true,
        capability_available: true,
        data_quality: quality(),
    };
    let a = assemble(
        &r,
        &[],
        &[
            LanePages {
                expanded_index: 0,
                detail: Some(&page),
                density: None,
            },
            LanePages {
                expanded_index: 1,
                detail: Some(&page),
                density: None,
            },
        ],
        2.0,
        &mut || Ok(()),
    )
    .unwrap();
    assert_eq!(a.quality_facts.len(), 1);
    assert_eq!(a.quality_facts[0].scope, ViewerQualityScope::NamedSlice);
}
#[test]
fn merged_source_quality_has_one_total_budget_before_allocating() {
    let r = request(2, 10, DetailPreference::Detail);
    let warnings = (0..3000)
        .map(|count| QualityIssue {
            category: QualityCategory::InvalidValue,
            scope: Some("sched_slice.value".into()),
            count: Some(count),
            message: None,
        })
        .collect();
    let page = EventPage {
        items: vec![],
        truncated: false,
        capability_available: true,
        data_quality: DataQuality::machine(QualityStatus::Warnings, warnings).unwrap(),
    };
    let mut page2 = page.clone();
    for warning in &mut page2.data_quality.warnings {
        warning.count = warning.count.map(|count| count + 3000);
    }
    let pages = [
        LanePages {
            expanded_index: 0,
            detail: Some(&page),
            density: None,
        },
        LanePages {
            expanded_index: 1,
            detail: Some(&page2),
            density: None,
        },
    ];
    assert_eq!(
        assemble(&r, &[], &pages, 2.0, &mut || Ok(())),
        Err(ViewerError::Quality(
            ContractError::QualityItemBudgetExceeded
        ))
    );
}
#[test]
fn source_issue_identity_deduplicates_before_human_message_redaction() {
    let r = request(2, 10, DetailPreference::Detail);
    let first = QualityIssue {
        category: QualityCategory::InvalidValue,
        scope: Some("sched_slice.value".into()),
        count: Some(1),
        message: Some("a".into()),
    };
    let page = EventPage {
        items: vec![],
        truncated: false,
        capability_available: true,
        data_quality: DataQuality {
            status: QualityStatus::Warnings,
            warnings: vec![first.clone()],
        },
    };
    let mut second = first;
    second.message = Some("b".into());
    let mut page2 = page.clone();
    page2.data_quality.warnings.push(second);
    let a = assemble(
        &r,
        &[],
        &[
            LanePages {
                expanded_index: 0,
                detail: Some(&page),
                density: None,
            },
            LanePages {
                expanded_index: 1,
                detail: Some(&page2),
                density: None,
            },
        ],
        2.0,
        &mut || Ok(()),
    )
    .unwrap();
    assert_eq!(a.snapshot.data_quality().warnings.len(), 2);
    assert!(
        a.snapshot
            .data_quality()
            .warnings
            .iter()
            .all(|w| w.message.is_none())
    );
    assert_eq!(
        a.snapshot.data_quality().warnings[0],
        a.snapshot.data_quality().warnings[1]
    );
}
