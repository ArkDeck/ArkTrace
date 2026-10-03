//! Safe packing on the owner worker. C/Swift never decode viewport JSON.
use crate::*;
use arktrace_contract::{EventTable, QualityCategory, TraceDensityIdentity, TraceDensitySource};
use std::{collections::BTreeMap, mem::size_of};
#[derive(Debug)]
pub struct HotSnapshot {
    pub quality_status: u32,
    pub viewport: ViewportRecord,
    pub tracks: Vec<TrackRecord>,
    pub primitives: Vec<PrimitiveRecord>,
    pub quality: Vec<QualityRecord>,
    pub strings: Vec<u8>,
}
impl HotSnapshot {
    pub fn retained_bytes(&self) -> Option<usize> {
        size_of::<Self>()
            .checked_add(
                self.tracks
                    .capacity()
                    .checked_mul(size_of::<TrackRecord>())?,
            )?
            .checked_add(
                self.primitives
                    .capacity()
                    .checked_mul(size_of::<PrimitiveRecord>())?,
            )?
            .checked_add(
                self.quality
                    .capacity()
                    .checked_mul(size_of::<QualityRecord>())?,
            )?
            .checked_add(self.strings.capacity())
    }
    pub fn pack(
        snapshot: &ProjectedSnapshot,
        maximum_bytes: usize,
        check: &mut Check<'_>,
    ) -> Result<Self, ViewerError> {
        check()?;
        let vp = snapshot.viewport();
        let mut scene = Self {
            quality_status: match snapshot.data_quality().status {
                arktrace_contract::QualityStatus::Ok => WIRE_QUALITY_STATUS_OK,
                arktrace_contract::QualityStatus::Warnings => WIRE_QUALITY_STATUS_WARNINGS,
            },
            viewport: ViewportRecord {
                start_ns: vp.range().start_ns(),
                end_ns: vp.range().end_ns(),
                ns_per_point: vp.ns_per_point(),
                width_points: vp.width_points(),
                height_points: vp.height_points(),
                vertical_offset_points: vp.vertical_offset_points(),
                generation: vp.generation(),
                source_generation: snapshot.source_generation(),
                backing_scale: snapshot.backing_scale(),
            },
            tracks: Vec::new(),
            primitives: Vec::new(),
            quality: Vec::new(),
            strings: Vec::new(),
        };
        let count = snapshot
            .tracks()
            .iter()
            .try_fold(0usize, |n, t| n.checked_add(t.primitives.len()))
            .ok_or(ViewerError::InputBudgetExceeded)?;
        if snapshot.tracks().len() > MAXIMUM_TRACKS || count > MAXIMUM_PRIMITIVES {
            return Err(ViewerError::InputBudgetExceeded);
        }
        let quality = machine(snapshot.data_quality())?;
        let fixed = size_of::<Self>()
            + snapshot.tracks().len() * size_of::<TrackRecord>()
            + count * size_of::<PrimitiveRecord>()
            + quality.warnings.len() * size_of::<QualityRecord>();
        if fixed > maximum_bytes {
            return Err(ViewerError::InputBudgetExceeded);
        }
        scene
            .tracks
            .try_reserve_exact(snapshot.tracks().len())
            .map_err(|_| ViewerError::InputBudgetExceeded)?;
        scene
            .primitives
            .try_reserve_exact(count)
            .map_err(|_| ViewerError::InputBudgetExceeded)?;
        scene
            .quality
            .try_reserve_exact(quality.warnings.len())
            .map_err(|_| ViewerError::InputBudgetExceeded)?;
        let mut names = BTreeMap::new();
        for (index, track) in snapshot.tracks().iter().enumerate() {
            checkpoint(index, check)?;
            let (source_kind, source_value, filter_id, owner_value, has_owner) =
                source(&track.descriptor.source);
            let (id_offset, id_length) =
                scene.intern(&track.descriptor.id(), &mut names, maximum_bytes)?;
            let primitive_start = scene.primitives.len() as u32;
            for (i, p) in track.primitives.iter().enumerate() {
                checkpoint(i, check)?;
                let range = p.input.range();
                let mut record = PrimitiveRecord {
                    track_index: index as u32,
                    start_ns: range.start_ns(),
                    end_ns: range.end_ns(),
                    flags: if p.visible { WIRE_FLAG_VISIBLE } else { 0 },
                    ..Default::default()
                };
                if let Some(frame) = p.frame {
                    record.flags |= WIRE_FLAG_FRAME;
                    record.x = frame.x;
                    record.y = frame.y;
                    record.width = frame.width;
                    record.height = frame.height;
                }
                match &p.input {
                    PrimitiveInput::Detail { detail } => {
                        record.kind = WIRE_PRIMITIVE_DETAIL;
                        record.event_table = event_table(detail.event_key.table);
                        record.row_id = detail.event_key.row_id;
                        record.depth = detail.depth;
                        record.style = style(detail.style);
                        if detail.is_open_ended {
                            record.flags |= WIRE_FLAG_OPEN_ENDED;
                        }
                    }
                    PrimitiveInput::Density { bucket } => {
                        record.kind = WIRE_PRIMITIVE_DENSITY;
                        record.event_count = bucket.event_count;
                        if let Some(ns) = bucket.occupied_ns {
                            record.flags |= WIRE_FLAG_OCCUPANCY;
                            record.occupied_ns = ns;
                        }
                        if let Some(u) = bucket.utilization {
                            record.flags |= WIRE_FLAG_UTILIZATION;
                            record.utilization = u;
                        }
                        match &bucket.dominant {
                            None => {}
                            Some(TraceDensityIdentity::ProcessOrThread { identity }) => {
                                record.dominant_kind = WIRE_DOMINANT_IDENTITY;
                                record.dominant_value = *identity;
                            }
                            Some(TraceDensityIdentity::Jank { flag }) => {
                                record.dominant_kind = WIRE_DOMINANT_JANK;
                                record.dominant_value = *flag;
                            }
                            Some(TraceDensityIdentity::Name { name })
                            | Some(TraceDensityIdentity::ThreadState { state: name }) => {
                                record.dominant_kind = if matches!(
                                    bucket.dominant,
                                    Some(TraceDensityIdentity::Name { .. })
                                ) {
                                    WIRE_DOMINANT_NAME
                                } else {
                                    WIRE_DOMINANT_THREAD_STATE
                                };
                                (record.text_offset, record.text_length) =
                                    scene.intern(name, &mut names, maximum_bytes)?;
                            }
                        }
                    }
                }
                scene.primitives.push(record);
            }
            scene.tracks.push(TrackRecord {
                source_kind,
                source_value,
                filter_id,
                owner_value,
                id_offset,
                id_length,
                y: track.y,
                height: track.height,
                depth_rows: track.depth_row_count as u32,
                primitive_start,
                primitive_count: track.primitives.len() as u32,
                flags: if track.descriptor.is_collapsed {
                    WIRE_TRACK_COLLAPSED
                } else {
                    0
                } | if track.descriptor.shows_nested_depth {
                    WIRE_TRACK_NESTED
                } else {
                    0
                } | if has_owner { WIRE_TRACK_OWNER } else { 0 },
                reserved: 0,
            });
        }
        for (i, q) in quality.warnings.iter().enumerate() {
            checkpoint(i, check)?;
            let mut record = QualityRecord {
                category: category(q.category),
                ..Default::default()
            };
            if let Some(scope) = &q.scope {
                record.flags |= WIRE_QUALITY_SCOPE;
                (record.scope_offset, record.scope_length) =
                    scene.intern(scope, &mut names, maximum_bytes)?;
            }
            if let Some(count) = q.count {
                record.flags |= WIRE_QUALITY_COUNT;
                record.count = count;
            }
            scene.quality.push(record);
        }
        if scene
            .retained_bytes()
            .ok_or(ViewerError::InputBudgetExceeded)?
            > maximum_bytes
        {
            return Err(ViewerError::InputBudgetExceeded);
        }
        check()?;
        Ok(scene)
    }
    fn intern(
        &mut self,
        name: &str,
        names: &mut BTreeMap<String, (u32, u32)>,
        maximum: usize,
    ) -> Result<(u32, u32), ViewerError> {
        if let Some(found) = names.get(name) {
            return Ok(*found);
        }
        let length = self
            .strings
            .len()
            .checked_add(name.len())
            .ok_or(ViewerError::InputBudgetExceeded)?;
        let fixed = self
            .retained_bytes()
            .ok_or(ViewerError::InputBudgetExceeded)?
            - self.strings.capacity();
        if length > u32::MAX as usize || fixed.checked_add(length).is_none_or(|n| n > maximum) {
            return Err(ViewerError::InputBudgetExceeded);
        }
        let entry = (self.strings.len() as u32, name.len() as u32);
        self.strings
            .try_reserve_exact(name.len())
            .map_err(|_| ViewerError::InputBudgetExceeded)?;
        if fixed
            .checked_add(self.strings.capacity())
            .is_none_or(|n| n > maximum)
        {
            return Err(ViewerError::InputBudgetExceeded);
        }
        self.strings.extend_from_slice(name.as_bytes());
        names.insert(name.to_owned(), entry);
        Ok(entry)
    }
}
fn source(value: &TraceDensitySource) -> (u32, i64, i64, i64, bool) {
    match value {
        TraceDensitySource::Cpu { cpu } => (WIRE_SOURCE_CPU, *cpu, 0, 0, false),
        TraceDensitySource::ThreadState { thread } => {
            (WIRE_SOURCE_THREAD_STATE, thread.itid, 0, 0, false)
        }
        TraceDensitySource::NamedSlice { thread } => (
            WIRE_SOURCE_NAMED_SLICE,
            thread.map_or(0, |t| t.itid),
            0,
            0,
            thread.is_some(),
        ),
        TraceDensitySource::CpuCounter { filter_id, cpu } => (
            WIRE_SOURCE_CPU_COUNTER,
            0,
            *filter_id,
            cpu.unwrap_or(0),
            cpu.is_some(),
        ),
        TraceDensitySource::ProcessCounter {
            filter_id,
            process_key,
        } => (
            WIRE_SOURCE_PROCESS_COUNTER,
            0,
            *filter_id,
            process_key.map_or(0, |p| p.ipid),
            process_key.is_some(),
        ),
        TraceDensitySource::Frame { process_key } => (
            WIRE_SOURCE_FRAME,
            0,
            0,
            process_key.map_or(0, |p| p.ipid),
            process_key.is_some(),
        ),
    }
}
fn event_table(v: EventTable) -> u32 {
    match v {
        EventTable::SchedSlice => WIRE_TABLE_SCHED_SLICE,
        EventTable::ThreadState => WIRE_TABLE_THREAD_STATE,
        EventTable::Callstack => WIRE_TABLE_CALLSTACK,
        EventTable::Measure => WIRE_TABLE_MEASURE,
        EventTable::ProcessMeasure => WIRE_TABLE_PROCESS_MEASURE,
        EventTable::FrameSlice => WIRE_TABLE_FRAME_SLICE,
    }
}
fn style(v: DetailStyle) -> u32 {
    match v {
        DetailStyle::Running => WIRE_STYLE_RUNNING,
        DetailStyle::Runnable => WIRE_STYLE_RUNNABLE,
        DetailStyle::Blocked => WIRE_STYLE_BLOCKED,
        DetailStyle::Sleeping => WIRE_STYLE_SLEEPING,
        DetailStyle::Counter => WIRE_STYLE_COUNTER,
        DetailStyle::Accent => WIRE_STYLE_ACCENT,
    }
}
fn category(v: QualityCategory) -> u32 {
    match v {
        QualityCategory::ProbeTruncated => WIRE_QUALITY_PROBE_TRUNCATED,
        QualityCategory::InvalidValue => WIRE_QUALITY_INVALID_VALUE,
        QualityCategory::ClampedValue => WIRE_QUALITY_CLAMPED_VALUE,
        QualityCategory::DroppedValue => WIRE_QUALITY_DROPPED_VALUE,
        QualityCategory::ReferentialIntegrity => WIRE_QUALITY_REFERENTIAL_INTEGRITY,
        QualityCategory::UnavailableValue => WIRE_QUALITY_UNAVAILABLE_VALUE,
        QualityCategory::Unclassified => WIRE_QUALITY_UNCLASSIFIED,
    }
}
