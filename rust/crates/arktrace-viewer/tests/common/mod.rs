use arktrace_contract::*;
use arktrace_viewer::*;
use serde_json::Value;
pub fn range(a: i64, b: i64) -> TraceTimeRange {
    TraceTimeRange::event(a, b).unwrap()
}
pub fn quality() -> DataQuality {
    DataQuality::machine(QualityStatus::Ok, vec![]).unwrap()
}
pub fn viewport() -> Viewport {
    Viewport::new(range(0, 1000), 200.0, 80.0, 0.0, 1).unwrap()
}
pub fn descriptor(cpu: i64) -> TrackDescriptor {
    TrackDescriptor {
        source: TraceDensitySource::Cpu { cpu },
        is_collapsed: false,
        shows_nested_depth: true,
    }
}
pub fn detail(row: i64, a: i64, b: i64, depth: i64, style: DetailStyle) -> DetailInput {
    DetailInput {
        render_facts: None,
        event_key: EventKey {
            table: EventTable::SchedSlice,
            row_id: row,
        },
        range: range(a, b),
        depth,
        style,
        is_open_ended: false,
    }
}
pub fn track(primitives: Vec<PrimitiveInput>) -> TrackInput {
    TrackInput {
        descriptor: descriptor(0),
        y: 0.0,
        height: 28.0,
        depth_row_count: 1,
        primitives,
    }
}
pub fn bucket(a: i64, b: i64, count: i64) -> TraceDensityBucket {
    TraceDensityBucket {
        range: range(a, b),
        event_count: count,
        occupied_ns: None,
        utilization: None,
        dominant: None,
    }
}
pub fn density(count: i64) -> TraceDensityResult {
    TraceDensityResult {
        buckets: vec![bucket(0, 1000, count)],
        capability_available: true,
        data_quality: quality(),
    }
}
pub fn request(n: usize, budget: usize, preference: DetailPreference) -> ViewportRequest {
    ViewportRequest {
        viewport: viewport(),
        tracks: (0..n).map(|n| descriptor(n as i64)).collect(),
        pixel_width: 800,
        generation: 1,
        preference,
        maximum_primitives: Some(budget),
        focused_event_key: None,
    }
}
/// Integer times and identities stay exact. Floating fields compare binary64
/// bits, including integer/float JSON spelling; no epsilon or field drops.
pub fn compare(a: &Value, b: &Value, path: &str) {
    match (a, b) {
        (Value::Array(a), Value::Array(b)) => {
            assert_eq!(a.len(), b.len(), "{path}: length");
            for (i, (a, b)) in a.iter().zip(b).enumerate() {
                compare(a, b, &format!("{path}[{i}]"));
            }
        }
        (Value::Object(a), Value::Object(b)) => {
            assert_eq!(
                a.keys().collect::<Vec<_>>(),
                b.keys().collect::<Vec<_>>(),
                "{path}: fields"
            );
            for (k, a) in a {
                compare(a, &b[k], &format!("{path}.{k}"));
            }
        }
        (Value::Number(a), Value::Number(b)) => {
            if let (Some(a), Some(b)) = (a.as_i64(), b.as_i64()) {
                assert_eq!(a, b, "{path}: exact integer");
            } else if let (Some(a), Some(b)) = (a.as_u64(), b.as_u64()) {
                assert_eq!(a, b, "{path}: exact unsigned integer");
            } else {
                assert_eq!(
                    a.as_f64().unwrap().to_bits(),
                    b.as_f64().unwrap().to_bits(),
                    "{path}: binary64 ({a} vs {b})"
                );
            }
        }
        _ => assert_eq!(a, b, "{path}"),
    }
}
