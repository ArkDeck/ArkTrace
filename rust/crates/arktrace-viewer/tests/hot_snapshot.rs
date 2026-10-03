#[allow(dead_code)]
mod common;
use arktrace_contract::*;
use arktrace_viewer::*;
use common::*;
use serde_json::Value;
fn text(s: &HotSnapshot, offset: u32, length: u32) -> &str {
    std::str::from_utf8(&s.strings[offset as usize..offset as usize + length as usize]).unwrap()
}
#[test]
fn pack_actual_geometry_vectors_without_losing_ranges_keys_or_binary64_frames() {
    let vectors: Vec<Value> =
        serde_json::from_str(include_str!("fixtures/geometry-inputs.json")).unwrap();
    for v in vectors {
        let vp: Viewport = serde_json::from_value(v["viewport"].clone()).unwrap();
        let tracks: Vec<TrackInput> = serde_json::from_value(v["tracks"].clone()).unwrap();
        let snapshot = project(
            &vp,
            77,
            &tracks,
            v["backingScale"].as_f64().unwrap(),
            &quality(),
            &mut || Ok(()),
        )
        .unwrap();
        let packed = HotSnapshot::pack(&snapshot, 16 * 1024 * 1024, &mut || Ok(())).unwrap();
        assert_eq!(packed.quality_status, WIRE_QUALITY_STATUS_OK);
        assert_eq!(packed.viewport.start_ns, vp.range().start_ns());
        assert_eq!(packed.viewport.end_ns, vp.range().end_ns());
        assert_eq!(
            packed.viewport.ns_per_point.to_bits(),
            vp.ns_per_point().to_bits()
        );
        assert_eq!(packed.viewport.source_generation, 77);
        assert_eq!(
            packed.viewport.backing_scale.to_bits(),
            snapshot.backing_scale().to_bits()
        );
        assert_eq!(packed.tracks.len(), snapshot.tracks().len());
        for (index, (record, track)) in packed.tracks.iter().zip(snapshot.tracks()).enumerate() {
            assert_eq!(
                text(&packed, record.id_offset, record.id_length),
                track.descriptor.id()
            );
            assert_eq!(record.y.to_bits(), track.y.to_bits());
            assert_eq!(record.height.to_bits(), track.height.to_bits());
            assert_eq!(record.depth_rows as usize, track.depth_row_count);
            let primitives = &packed.primitives[record.primitive_start as usize
                ..(record.primitive_start + record.primitive_count) as usize];
            assert_eq!(primitives.len(), track.primitives.len());
            for (r, p) in primitives.iter().zip(&track.primitives) {
                assert_eq!(r.track_index as usize, index);
                assert_eq!(r.start_ns, p.input.range().start_ns());
                assert_eq!(r.end_ns, p.input.range().end_ns());
                assert_eq!(r.flags & WIRE_FLAG_VISIBLE != 0, p.visible);
                assert_eq!(r.flags & WIRE_FLAG_FRAME != 0, p.frame.is_some());
                if let Some(f) = p.frame {
                    for (a, b) in [
                        (r.x, f.x),
                        (r.y, f.y),
                        (r.width, f.width),
                        (r.height, f.height),
                    ] {
                        assert_eq!(a.to_bits(), b.to_bits());
                    }
                }
                if let PrimitiveInput::Detail { detail } = &p.input {
                    assert_eq!(r.kind, WIRE_PRIMITIVE_DETAIL);
                    assert_eq!(r.row_id, detail.event_key.row_id);
                    assert_eq!(r.depth, detail.depth);
                    assert_eq!(r.flags & WIRE_FLAG_OPEN_ENDED != 0, detail.is_open_ended);
                }
            }
        }
    }
}
#[test]
fn string_table_preserves_utf8_dominant_identity_and_complete_machine_quality() {
    let mut b = bucket(0, 1000, 7);
    b.occupied_ns = Some(900);
    b.utilization = Some(0.9);
    b.dominant = Some(TraceDensityIdentity::Name {
        name: "绘制🦀".into(),
    });
    let mut other = b.clone();
    other.dominant = Some(TraceDensityIdentity::ProcessOrThread { identity: i64::MAX });
    let q = DataQuality::machine(
        QualityStatus::Warnings,
        vec![QualityIssue {
            category: QualityCategory::DroppedValue,
            scope: None,
            count: Some(2),
            message: Some("private user path".into()),
        }],
    )
    .unwrap();
    let s = project(
        &viewport(),
        4,
        &[track(vec![
            PrimitiveInput::Density { bucket: b.clone() },
            PrimitiveInput::Density { bucket: b },
            PrimitiveInput::Density { bucket: other },
        ])],
        2.0,
        &q,
        &mut || Ok(()),
    )
    .unwrap();
    let wire = HotSnapshot::pack(&s, 4096, &mut || Ok(())).unwrap();
    assert_eq!(wire.quality_status, WIRE_QUALITY_STATUS_WARNINGS);
    let a = wire.primitives[0];
    let b = wire.primitives[1];
    assert_eq!(
        (a.text_offset, a.text_length),
        (b.text_offset, b.text_length)
    );
    assert_eq!(text(&wire, a.text_offset, a.text_length), "绘制🦀");
    assert_eq!(wire.primitives[2].dominant_value, i64::MAX);
    assert_eq!(wire.primitives[2].dominant_kind, WIRE_DOMINANT_IDENTITY);
    assert_eq!(a.occupied_ns, 900);
    assert_eq!(a.utilization.to_bits(), 0.9f64.to_bits());
    assert_eq!(wire.quality.len(), 1);
    assert_eq!(wire.quality[0].count, 2);
    assert!(
        !std::str::from_utf8(&wire.strings)
            .unwrap()
            .contains("private")
    );
    let bytes = wire.retained_bytes().unwrap();
    assert!(bytes <= 4096);
    assert_eq!(
        HotSnapshot::pack(&s, bytes - 1, &mut || Ok(())).unwrap_err(),
        ViewerError::InputBudgetExceeded
    );
    assert_eq!(
        HotSnapshot::pack(&s, 4096, &mut || Err(ViewerError::Cancelled)).unwrap_err(),
        ViewerError::Cancelled
    );
    let mut calls = 0;
    assert_eq!(
        HotSnapshot::pack(&s, 4096, &mut || {
            calls += 1;
            if calls > 1 {
                Err(ViewerError::DeadlineReached)
            } else {
                Ok(())
            }
        })
        .unwrap_err(),
        ViewerError::DeadlineReached
    );
}
#[test]
fn optional_sources_keep_zero_distinct_from_absence_and_filter_family() {
    let sources = [
        TraceDensitySource::NamedSlice { thread: None },
        TraceDensitySource::NamedSlice {
            thread: Some(ThreadKey { itid: 0 }),
        },
        TraceDensitySource::CpuCounter {
            filter_id: i64::MIN,
            cpu: None,
        },
        TraceDensitySource::CpuCounter {
            filter_id: i64::MIN,
            cpu: Some(0),
        },
        TraceDensitySource::ProcessCounter {
            filter_id: i64::MAX,
            process_key: Some(ProcessKey { ipid: 0 }),
        },
        TraceDensitySource::Frame { process_key: None },
    ];
    let tracks: Vec<_> = sources
        .into_iter()
        .enumerate()
        .map(|(i, source)| TrackInput {
            descriptor: TrackDescriptor {
                source,
                is_collapsed: false,
                shows_nested_depth: false,
            },
            y: i as f64 * 28.0,
            ..track(vec![])
        })
        .collect();
    let snap = project(&viewport(), 1, &tracks, 1.0, &quality(), &mut || Ok(())).unwrap();
    let wire = HotSnapshot::pack(&snap, 4096, &mut || Ok(())).unwrap();
    for (i, r) in wire.tracks.iter().enumerate() {
        assert_eq!(
            r.flags & WIRE_TRACK_OWNER != 0,
            [false, true, false, true, true, false][i]
        );
    }
    assert_eq!(wire.tracks[2].filter_id, i64::MIN);
    assert_eq!(wire.tracks[4].filter_id, i64::MAX);
    assert_ne!(wire.tracks[2].source_kind, wire.tracks[4].source_kind);
}
