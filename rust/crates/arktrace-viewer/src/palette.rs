//! Shared sRGB values and assignment from the frozen Swift palette.
//! Assignment ports SmartPerf Host ColorUtils (Apache-2.0), including Number
//! multiplication before ToInt32. See THIRD_PARTY_NOTICES.md; values are ArkTrace's.
use crate::{Check, TrackDescriptor, ViewerError, checkpoint};
use arktrace_contract::{TraceDensityIdentity, TraceThreadState};
use serde::{Deserialize, Serialize};
pub const MAXIMUM_PALETTE_INPUT_BYTES: usize = 4096;
#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Rgb {
    pub red: u8,
    pub green: u8,
    pub blue: u8,
}
impl Rgb {
    pub const fn hex(value: u32) -> Self {
        Self {
            red: (value >> 16) as u8,
            green: (value >> 8) as u8,
            blue: value as u8,
        }
    }
    pub fn label_foreground(self) -> Self {
        let gray = self.red as f64 * 0.299 + self.green as f64 * 0.587 + self.blue as f64 * 0.114;
        if gray >= 100.0 {
            Self::hex(0)
        } else {
            Self::hex(0xffffff)
        }
    }
    pub fn rgba(self, alpha: f64) -> Result<Rgba, ViewerError> {
        if !alpha.is_finite() {
            return Err(ViewerError::InvalidGeometry);
        }
        Ok(Rgba {
            red: self.red as f64 / 255.0,
            green: self.green as f64 / 255.0,
            blue: self.blue as f64 / 255.0,
            alpha: alpha.clamp(0.0, 1.0),
        })
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
pub struct Rgba {
    pub red: f64,
    pub green: f64,
    pub blue: f64,
    pub alpha: f64,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum PaletteFamily {
    Identity,
    State,
    Jank,
    Annotation,
    Grey,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub struct ColorSlot {
    pub family: PaletteFamily,
    pub index: u8,
}
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolvedColor {
    pub slot: ColorSlot,
    pub fill: Rgb,
    pub rgba: Rgba,
    pub label_foreground: Rgb,
}
impl ResolvedColor {
    fn new(family: PaletteFamily, index: usize, fill: Rgb) -> Self {
        Self {
            slot: ColorSlot {
                family,
                index: index as u8,
            },
            fill,
            rgba: Rgba {
                red: fill.red as f64 / 255.0,
                green: fill.green as f64 / 255.0,
                blue: fill.blue as f64 / 255.0,
                alpha: 1.0,
            },
            label_foreground: fill.label_foreground(),
        }
    }
}
pub const IDENTITY_COLORS: [Rgb; 20] = [
    Rgb::hex(0x377ea7),
    Rgb::hex(0xa5698f),
    Rgb::hex(0x7388cc),
    Rgb::hex(0x419a83),
    Rgb::hex(0x22858c),
    Rgb::hex(0x817e76),
    Rgb::hex(0x4893c5),
    Rgb::hex(0x83739f),
    Rgb::hex(0x6e8b62),
    Rgb::hex(0x6276b8),
    Rgb::hex(0x829446),
    Rgb::hex(0x4692a1),
    Rgb::hex(0x9c7735),
    Rgb::hex(0x488268),
    Rgb::hex(0xb58255),
    Rgb::hex(0x957bbc),
    Rgb::hex(0xaa6168),
    Rgb::hex(0x6985aa),
    Rgb::hex(0xab7fa4),
    Rgb::hex(0xaf6943),
];
/// Raw-state chain's seven distinct fills, then the catch-all token.
pub const STATE_COLORS: [Rgb; 8] = [
    Rgb::hex(0xa47c74),
    Rgb::hex(0xbd7211),
    Rgb::hex(0x7b7849),
    Rgb::hex(0x948c63),
    Rgb::hex(0x627987),
    Rgb::hex(0x489252),
    Rgb::hex(0x898d94),
    Rgb::hex(0xd85d72),
];
pub const JANK_COLORS: [Rgb; 6] = [
    Rgb::hex(0x42a14d),
    Rgb::hex(0xc0ce85),
    Rgb::hex(0xff651d),
    Rgb::hex(0xe8be44),
    Rgb::hex(0x009dfa),
    Rgb::hex(0xe97978),
];
pub const ANNOTATION_COLORS: [Rgb; 6] = [
    Rgb::hex(0xe03b24),
    Rgb::hex(0xf2990c),
    Rgb::hex(0x1d9a6c),
    Rgb::hex(0x1c7ed6),
    Rgb::hex(0x8e44ad),
    Rgb::hex(0x4a4a4a),
];
pub fn palette_color(family: PaletteFamily, index: usize) -> Result<ResolvedColor, ViewerError> {
    let values: &[Rgb] = match family {
        PaletteFamily::Identity => &IDENTITY_COLORS,
        PaletteFamily::State => &STATE_COLORS,
        PaletteFamily::Jank => &JANK_COLORS,
        PaletteFamily::Annotation => &ANNOTATION_COLORS,
        PaletteFamily::Grey => &[Rgb::hex(0x817e76)],
    };
    values
        .get(index)
        .copied()
        .map(|c| ResolvedColor::new(family, index, c))
        .ok_or(ViewerError::InvalidRequest)
}
pub fn grey_color() -> ResolvedColor {
    ResolvedColor::new(PaletteFamily::Grey, 0, IDENTITY_COLORS[5])
}
pub(crate) fn palette_string(value: &str) -> Result<(), ViewerError> {
    if value.len() > MAXIMUM_PALETTE_INPUT_BYTES {
        Err(ViewerError::InputBudgetExceeded)
    } else {
        Ok(())
    }
}
fn fnv_utf16(value: &str, strip_digits: bool, check: &mut Check<'_>) -> Result<u32, ViewerError> {
    palette_string(value)?;
    check()?;
    let mut hash = 0x011c9dc5_i32;
    for (i, unit) in value.encode_utf16().enumerate() {
        checkpoint(i, check)?;
        if strip_digits && (0x30..=0x39).contains(&unit) {
            continue;
        }
        hash ^= unit as i32;
        // Product rounded as binary64, THEN truncation to the low signed 32 bits.
        hash = ((hash as f64 * 16_777_619.0) as i64) as i32;
    }
    check()?;
    Ok(hash.unsigned_abs())
}
pub fn palette_hash(value: &str, modulus: i64, check: &mut Check<'_>) -> Result<u64, ViewerError> {
    palette_string(value)?;
    check()?;
    if modulus <= 0 {
        return Ok(0);
    }
    Ok(fnv_utf16(value, false, check)? as u64 % modulus as u64)
}
pub fn palette_hash_func(
    value: &str,
    depth: i64,
    modulus: i64,
    check: &mut Check<'_>,
) -> Result<u64, ViewerError> {
    palette_string(value)?;
    check()?;
    if modulus <= 0 {
        return Ok(0);
    }
    Ok((fnv_utf16(value, true, check)? as u64 + depth.max(0) as u64) % modulus as u64)
}
pub fn name_color(name: &str, check: &mut Check<'_>) -> Result<ResolvedColor, ViewerError> {
    palette_color(
        PaletteFamily::Identity,
        palette_hash(name, 20, check)? as usize,
    )
}
pub fn slice_name_color(
    name: &str,
    depth: i64,
    check: &mut Check<'_>,
) -> Result<ResolvedColor, ViewerError> {
    palette_color(
        PaletteFamily::Identity,
        palette_hash_func(name, depth, 20, check)? as usize,
    )
}
pub fn process_or_thread_color(
    identity: i64,
    check: &mut Check<'_>,
) -> Result<ResolvedColor, ViewerError> {
    name_color(&identity.to_string(), check)
}
/// Color identity is the OS pid > 0, otherwise tid (or 0), never ipid/itid.
pub fn process_thread_color(
    pid: Option<i64>,
    tid: Option<i64>,
    check: &mut Check<'_>,
) -> Result<ResolvedColor, ViewerError> {
    process_or_thread_color(
        pid.filter(|pid| *pid > 0).unwrap_or(tid.unwrap_or(0)),
        check,
    )
}
pub fn track_identity_color(
    key: &str,
    check: &mut Check<'_>,
) -> Result<ResolvedColor, ViewerError> {
    palette_string(key)?;
    check()?;
    let mut hash = 0xcbf29ce484222325_u64;
    for (i, b) in key.bytes().enumerate() {
        checkpoint(i, check)?;
        hash ^= b as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    check()?;
    palette_color(PaletteFamily::Identity, (hash % 20) as usize)
}
pub fn track_color(
    track: &TrackDescriptor,
    check: &mut Check<'_>,
) -> Result<ResolvedColor, ViewerError> {
    track_identity_color(&track.id(), check)
}
pub fn state_color(
    raw: Option<&str>,
    normalized: Option<TraceThreadState>,
) -> Result<ResolvedColor, ViewerError> {
    if let Some(raw) = raw {
        palette_string(raw)?;
    }
    let exact = match raw {
        Some("D-NIO" | "DK-NIO") => Some(0),
        Some("D-IO" | "DK-IO" | "D" | "DK") => Some(1),
        Some("R" | "R+") => Some(2),
        Some("R-B") => Some(3),
        Some("I") => Some(4),
        Some("Running") => Some(5),
        Some("S") => Some(6),
        _ => None,
    };
    let index = exact.unwrap_or(match normalized {
        Some(TraceThreadState::Running) => 5,
        Some(TraceThreadState::Runnable) => 2,
        Some(TraceThreadState::Sleeping) => 6,
        Some(TraceThreadState::Blocked) => 1,
        _ => 7,
    });
    palette_color(PaletteFamily::State, index)
}
pub fn jank_color(tag: i64) -> ResolvedColor {
    let index = match tag {
        1 => 2,
        3 => 3,
        _ => 0,
    };
    ResolvedColor::new(PaletteFamily::Jank, index, JANK_COLORS[index])
}
pub fn annotation_color(index: i64) -> ResolvedColor {
    let index = index.rem_euclid(6) as usize;
    ResolvedColor::new(PaletteFamily::Annotation, index, ANNOTATION_COLORS[index])
}
pub fn density_color(
    dominant: Option<&TraceDensityIdentity>,
    track: &TrackDescriptor,
    check: &mut Check<'_>,
) -> Result<ResolvedColor, ViewerError> {
    check()?;
    match dominant {
        Some(TraceDensityIdentity::ProcessOrThread { identity }) => {
            process_or_thread_color(*identity, check)
        }
        Some(TraceDensityIdentity::Name { name }) => slice_name_color(name, 0, check),
        Some(TraceDensityIdentity::ThreadState { state }) => state_color(Some(state), None),
        Some(TraceDensityIdentity::Jank { flag }) => Ok(jank_color(*flag)),
        None => track_color(track, check),
    }
}
/// Swift uses a full-opacity fill; event count changes logical band height.
pub fn density_intensity(event_count: i64) -> u8 {
    let count = event_count.max(1) as u64;
    (63 - count.leading_zeros()).min(7) as u8
}
pub fn density_height_fraction(intensity: i64) -> f64 {
    0.32 + 0.68 * intensity.clamp(0, 7) as f64 / 7.0
}
