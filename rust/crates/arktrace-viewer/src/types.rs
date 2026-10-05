use crate::{ViewerError, finite};
use arktrace_contract::{EventKey, TraceDensityBucket, TraceDensitySource, TraceTimeRange};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Viewport {
    pub(crate) range: TraceTimeRange,
    pub(crate) ns_per_point: f64,
    pub(crate) width_points: f64,
    pub(crate) height_points: f64,
    pub(crate) vertical_offset_points: f64,
    pub(crate) generation: u64,
}
impl Viewport {
    pub fn new(
        range: TraceTimeRange,
        width_points: f64,
        height_points: f64,
        vertical_offset_points: f64,
        generation: u64,
    ) -> Result<Self, ViewerError> {
        if range.is_instant()
            || !width_points.is_finite()
            || width_points <= 0.0
            || !height_points.is_finite()
            || height_points <= 0.0
            || !vertical_offset_points.is_finite()
            || vertical_offset_points < 0.0
        {
            return Err(ViewerError::InvalidViewport);
        }
        let ns_per_point = range.duration_ns() as f64 / width_points;
        if !ns_per_point.is_finite() || ns_per_point <= 0.0 {
            return Err(ViewerError::InvalidViewport);
        }
        Ok(Self {
            range,
            ns_per_point,
            width_points,
            height_points,
            vertical_offset_points,
            generation,
        })
    }
    pub fn range(&self) -> TraceTimeRange {
        self.range
    }
    pub fn width_points(&self) -> f64 {
        self.width_points
    }
    pub fn height_points(&self) -> f64 {
        self.height_points
    }
    pub fn vertical_offset_points(&self) -> f64 {
        self.vertical_offset_points
    }
    pub fn generation(&self) -> u64 {
        self.generation
    }
    pub fn ns_per_point(&self) -> f64 {
        self.ns_per_point
    }
}
impl<'de> Deserialize<'de> for Viewport {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct Input {
            range: TraceTimeRange,
            width_points: f64,
            height_points: f64,
            vertical_offset_points: f64,
            generation: u64,
            #[serde(default)]
            ns_per_point: Option<f64>,
        }
        let i = Input::deserialize(d)?;
        let value = Viewport::new(
            i.range,
            i.width_points,
            i.height_points,
            i.vertical_offset_points,
            i.generation,
        )
        .map_err(|_| serde::de::Error::custom("invalid viewport"))?;
        if i.ns_per_point
            .is_some_and(|n| n.to_bits() != value.ns_per_point.to_bits())
        {
            return Err(serde::de::Error::custom("inconsistent viewport scale"));
        }
        Ok(value)
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}
impl Point {
    pub(crate) fn validate(self) -> Result<(), ViewerError> {
        finite(self.x)?;
        finite(self.y)?;
        Ok(())
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}
impl Rect {
    pub(crate) fn validate(self) -> Result<(), ViewerError> {
        for x in [
            self.x,
            self.y,
            self.width,
            self.height,
            self.x + self.width,
            self.y + self.height,
        ] {
            finite(x)?;
        }
        if self.width <= 0.0 || self.height <= 0.0 {
            return Err(ViewerError::InvalidGeometry);
        }
        Ok(())
    }
    pub fn contains(self, p: Point) -> bool {
        p.x >= self.x && p.x < self.x + self.width && p.y >= self.y && p.y < self.y + self.height
    }
    pub(crate) fn expanded(self, amount: f64) -> Self {
        Self {
            x: self.x - amount,
            y: self.y - amount,
            width: self.width + 2.0 * amount,
            height: self.height + 2.0 * amount,
        }
    }
}

/// Reuses contract source identities and its associated-value wire coding.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TrackDescriptor {
    pub source: TraceDensitySource,
    pub is_collapsed: bool,
    pub shows_nested_depth: bool,
}
impl TrackDescriptor {
    pub fn id(&self) -> String {
        source_id(&self.source)
    }
    pub fn default_depth_rows(&self) -> usize {
        if matches!(self.source, TraceDensitySource::Frame { .. }) {
            2
        } else {
            1
        }
    }
}
pub fn source_id(source: &TraceDensitySource) -> String {
    use TraceDensitySource::*;
    match source {
        Cpu { cpu } => format!("cpu:{cpu}"),
        ThreadState { thread } => format!("thread-state:{}", thread.itid),
        NamedSlice { thread } => format!(
            "named-slice:{}",
            thread
                .map(|t| t.itid.to_string())
                .unwrap_or_else(|| "unattributed".into())
        ),
        CpuCounter { filter_id, cpu } => format!(
            "cpu-counter:{filter_id}:{}",
            cpu.map(|c| c.to_string()).unwrap_or_else(|| "all".into())
        ),
        ProcessCounter {
            filter_id,
            process_key,
        } => format!(
            "process-counter:{filter_id}:{}",
            process_key
                .map(|p| p.ipid.to_string())
                .unwrap_or_else(|| "all".into())
        ),
        Frame { process_key } => format!(
            "frame:{}",
            process_key
                .map(|p| p.ipid.to_string())
                .unwrap_or_else(|| "all".into())
        ),
    }
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DetailPreference {
    Automatic,
    Detail,
    Density,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DetailStyle {
    Running,
    Runnable,
    Blocked,
    Sleeping,
    Counter,
    Accent,
}
impl DetailStyle {
    pub fn from_category(category: Option<&str>) -> Self {
        match category {
            Some("running" | "cpu") => Self::Running,
            Some("runnable") => Self::Runnable,
            Some("blocked") => Self::Blocked,
            Some("sleeping") => Self::Sleeping,
            Some("counter") => Self::Counter,
            _ => Self::Accent,
        }
    }
    pub(crate) fn z_order(self) -> u8 {
        match self {
            Self::Running => 0,
            Self::Runnable => 1,
            Self::Blocked => 2,
            Self::Sleeping => 3,
            Self::Counter => 4,
            Self::Accent => 5,
        }
    }
}
/// A renderer projection of a real typed event, not an invented database row.
/// Domain range and open-ended status survive minimum-width visual expansion.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DetailInput {
    pub event_key: EventKey,
    pub range: TraceTimeRange,
    pub depth: i64,
    pub style: DetailStyle,
    pub is_open_ended: bool,
    /// Session-origin adjunct; geometry JSON cannot construct display facts.
    #[serde(skip)]
    pub render_facts: Option<crate::RenderDetailFacts>,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub enum PrimitiveInput {
    Detail { detail: DetailInput },
    Density { bucket: TraceDensityBucket },
}
impl PrimitiveInput {
    pub fn range(&self) -> TraceTimeRange {
        match self {
            Self::Detail { detail } => detail.range,
            Self::Density { bucket } => bucket.range,
        }
    }
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TrackInput {
    pub descriptor: TrackDescriptor,
    pub y: f64,
    pub height: f64,
    pub depth_row_count: usize,
    pub primitives: Vec<PrimitiveInput>,
}

impl DetailInput {
    pub fn is_instant(&self) -> bool {
        self.range.is_instant() && !self.is_open_ended
    }
}
