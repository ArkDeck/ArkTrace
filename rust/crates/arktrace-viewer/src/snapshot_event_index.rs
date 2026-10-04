//! Immutable first-detail EventKey lookup, independent of geometric hit order.
//! The host reads Inspector from the same immutable snapshot at the returned
//! position. This index neither constructs an Inspector nor authorizes publish.
use crate::{Check, MAXIMUM_PRIMITIVES, MAXIMUM_TRACKS, ViewIdentity, ViewerError};
use arktrace_contract::{EventKey, EventTable};
use serde::{Deserialize, Serialize};
use std::cmp::Ordering;

pub const SNAPSHOT_EVENT_INDEX_API_VERSION: u32 = 1;
/// One complete owned index, including unused Vec capacity and inline records.
/// Borrowed input, host snapshot and simultaneous old/new indexes are separate
/// host aggregate ownership. In-place heapsort needs no heap scratch buffer.
pub const MAXIMUM_SNAPSHOT_EVENT_INDEX_RETAINED_BYTES: usize = 1_024 * 1_024;

/// The owner changes revision on EVERY snapshot replacement, even if viewport
/// generation is unchanged. Never derive revision from a pointer or use index
/// identity as authority to publish an old snapshot. Recheck before publication
/// and before dereferencing a position after any host await/state transition.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SnapshotEventIndexIdentity {
    pub view: ViewIdentity,
    pub snapshot_revision: u64,
}
/// Closed primitive facts preserve density slots but permit no density key.
/// has_inspector must be projected from that same source detail, not inferred
/// from visibility, frame presence, EventKey or a detail hit candidate.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum SnapshotEventPrimitiveFact {
    Detail {
        event_key: EventKey,
        has_inspector: bool,
    },
    Density {},
}
#[derive(Clone, Copy, Debug)]
pub struct SnapshotEventTrackFacts<'a> {
    pub primitives: &'a [SnapshotEventPrimitiveFact],
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SnapshotEventLocation {
    pub track_index: u32,
    pub primitive_index: u32,
    pub has_inspector: bool,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub enum SnapshotEventIndexLookup {
    NoMatch,
    Matched { location: SnapshotEventLocation },
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SnapshotEventIndexError {
    Viewer(ViewerError),
    StaleSnapshot,
}
impl From<ViewerError> for SnapshotEventIndexError {
    fn from(error: ViewerError) -> Self {
        Self::Viewer(error)
    }
}
impl std::fmt::Display for SnapshotEventIndexError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for SnapshotEventIndexError {}
#[derive(Clone, Copy, Debug)]
struct Entry {
    key: EventKey,
    location: SnapshotEventLocation,
}
fn key_order(key: EventKey) -> (u8, i64) {
    let table = match key.table {
        EventTable::SchedSlice => 0,
        EventTable::ThreadState => 1,
        EventTable::Callstack => 2,
        EventTable::Measure => 3,
        EventTable::ProcessMeasure => 4,
        EventTable::FrameSlice => 5,
    };
    (table, key.row_id)
}
fn entry_order(entry: &Entry) -> ((u8, i64), u32, u32) {
    (
        key_order(entry.key),
        entry.location.track_index,
        entry.location.primitive_index,
    )
}
fn poll(work: &mut usize, check: &mut Check<'_>) -> Result<(), ViewerError> {
    if work.is_multiple_of(64) {
        check()?;
    }
    *work += 1;
    Ok(())
}
fn sift(
    entries: &mut [Entry],
    mut root: usize,
    end: usize,
    work: &mut usize,
    check: &mut Check<'_>,
) -> Result<(), ViewerError> {
    while root < end / 2 {
        poll(work, check)?;
        let mut child = root * 2 + 1;
        if child + 1 < end && entry_order(&entries[child]) < entry_order(&entries[child + 1]) {
            child += 1;
        }
        if entry_order(&entries[root]) >= entry_order(&entries[child]) {
            break;
        }
        entries.swap(root, child);
        root = child;
    }
    Ok(())
}
fn sort(entries: &mut [Entry], work: &mut usize, check: &mut Check<'_>) -> Result<(), ViewerError> {
    for root in (0..entries.len() / 2).rev() {
        sift(entries, root, entries.len(), work, check)?;
    }
    for end in (1..entries.len()).rev() {
        poll(work, check)?;
        entries.swap(0, end);
        sift(entries, 0, end, work, check)?;
    }
    check()
}

/// Private storage has no mutation/deserialization/clone API. Entries remain
/// sorted by full identity then original location. Dedup keeps the first and
/// deliberately retains the input-detail allocation's actual spare capacity.
#[derive(Debug)]
pub struct SnapshotEventIndex {
    identity: SnapshotEventIndexIdentity,
    entries: Vec<Entry>,
    source_track_count: usize,
    source_primitive_count: usize,
    source_detail_count: usize,
}
impl SnapshotEventIndex {
    pub fn identity(&self) -> SnapshotEventIndexIdentity {
        self.identity
    }
    pub fn len(&self) -> usize {
        self.entries.len()
    }
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
    pub fn source_track_count(&self) -> usize {
        self.source_track_count
    }
    pub fn source_primitive_count(&self) -> usize {
        self.source_primitive_count
    }
    pub fn source_detail_count(&self) -> usize {
        self.source_detail_count
    }
    pub fn retained_bytes(&self) -> usize {
        std::mem::size_of::<Self>() + self.entries.capacity() * std::mem::size_of::<Entry>()
    }
    pub fn validate_identity(
        &self,
        current: SnapshotEventIndexIdentity,
        check: &mut Check<'_>,
    ) -> Result<(), SnapshotEventIndexError> {
        check()?;
        if current != self.identity {
            return Err(SnapshotEventIndexError::StaleSnapshot);
        }
        check()?;
        Ok(())
    }
    /// A matched nil-inspector detail is distinct from NoMatch: it blocks any
    /// later duplicate. Nil key matches no primitive. Even nil key must pass
    /// identity checks so an old index never answers for a replacement snapshot.
    pub fn lookup(
        &self,
        current: SnapshotEventIndexIdentity,
        key: Option<EventKey>,
        check: &mut Check<'_>,
    ) -> Result<SnapshotEventIndexLookup, SnapshotEventIndexError> {
        self.validate_identity(current, check)?;
        let Some(key) = key else {
            check()?;
            return Ok(SnapshotEventIndexLookup::NoMatch);
        };
        let target = key_order(key);
        let mut lo = 0;
        let mut hi = self.entries.len();
        while lo < hi {
            check()?;
            let mid = lo + (hi - lo) / 2;
            match key_order(self.entries[mid].key).cmp(&target) {
                Ordering::Less => lo = mid + 1,
                Ordering::Greater => hi = mid,
                Ordering::Equal => {
                    check()?;
                    return Ok(SnapshotEventIndexLookup::Matched {
                        location: self.entries[mid].location,
                    });
                }
            }
        }
        check()?;
        Ok(SnapshotEventIndexLookup::NoMatch)
    }
}
pub fn build_snapshot_event_index(
    identity: SnapshotEventIndexIdentity,
    tracks: &[SnapshotEventTrackFacts<'_>],
    check: &mut Check<'_>,
) -> Result<SnapshotEventIndex, SnapshotEventIndexError> {
    build_snapshot_event_index_with_budget(
        identity,
        tracks,
        MAXIMUM_SNAPSHOT_EVENT_INDEX_RETAINED_BYTES,
        check,
    )
}
/// Validate borrowed logical counts before allocation, then count actual output
/// capacity before returning. No partial index escapes failure/cancel/deadline.
/// Input spare capacity remains caller-owned: borrowed slices reveal length,
/// not their parent allocations. Sorting and dedup are in-place and cancellable.
pub fn build_snapshot_event_index_with_budget(
    identity: SnapshotEventIndexIdentity,
    tracks: &[SnapshotEventTrackFacts<'_>],
    maximum_retained_bytes: usize,
    check: &mut Check<'_>,
) -> Result<SnapshotEventIndex, SnapshotEventIndexError> {
    check()?;
    if maximum_retained_bytes == 0
        || maximum_retained_bytes > MAXIMUM_SNAPSHOT_EVENT_INDEX_RETAINED_BYTES
    {
        return Err(ViewerError::InvalidRequest.into());
    }
    if tracks.len() > MAXIMUM_TRACKS {
        return Err(ViewerError::InputBudgetExceeded.into());
    }
    let mut primitive_count = 0usize;
    let mut detail_count = 0usize;
    let mut work = 0;
    for track in tracks {
        poll(&mut work, check)?;
        primitive_count = primitive_count
            .checked_add(track.primitives.len())
            .ok_or(ViewerError::InputBudgetExceeded)?;
        if primitive_count > MAXIMUM_PRIMITIVES {
            return Err(ViewerError::InputBudgetExceeded.into());
        }
        for fact in track.primitives {
            poll(&mut work, check)?;
            if matches!(fact, SnapshotEventPrimitiveFact::Detail { .. }) {
                detail_count += 1;
            }
        }
    }
    let planned = detail_count
        .checked_mul(std::mem::size_of::<Entry>())
        .and_then(|n| n.checked_add(std::mem::size_of::<SnapshotEventIndex>()))
        .ok_or(ViewerError::InputBudgetExceeded)?;
    if planned > maximum_retained_bytes {
        return Err(ViewerError::InputBudgetExceeded.into());
    }
    check()?;
    let mut index = SnapshotEventIndex {
        identity,
        entries: Vec::with_capacity(detail_count),
        source_track_count: tracks.len(),
        source_primitive_count: primitive_count,
        source_detail_count: detail_count,
    };
    if index.retained_bytes() > maximum_retained_bytes {
        return Err(ViewerError::InputBudgetExceeded.into());
    }
    for (ti, track) in tracks.iter().enumerate() {
        poll(&mut work, check)?;
        for (pi, fact) in track.primitives.iter().enumerate() {
            poll(&mut work, check)?;
            if let SnapshotEventPrimitiveFact::Detail {
                event_key,
                has_inspector,
            } = *fact
            {
                index.entries.push(Entry {
                    key: event_key,
                    location: SnapshotEventLocation {
                        track_index: u32::try_from(ti)
                            .map_err(|_| ViewerError::InputBudgetExceeded)?,
                        primitive_index: u32::try_from(pi)
                            .map_err(|_| ViewerError::InputBudgetExceeded)?,
                        has_inspector,
                    },
                });
            }
        }
    }
    sort(&mut index.entries, &mut work, check)?;
    let mut retained = 0;
    for read in 0..index.entries.len() {
        poll(&mut work, check)?;
        if retained == 0 || index.entries[read].key != index.entries[retained - 1].key {
            index.entries[retained] = index.entries[read];
            retained += 1;
        }
    }
    index.entries.truncate(retained);
    if index.retained_bytes() > maximum_retained_bytes {
        return Err(ViewerError::InputBudgetExceeded.into());
    }
    check()?;
    Ok(index)
}
