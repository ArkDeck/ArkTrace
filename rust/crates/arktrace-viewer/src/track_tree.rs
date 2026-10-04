//! Bounded sidebar catalog semantics. Ordering is the Swift controller's CPU
//! sample count (not duration), directory identities, and input series order.
use crate::{Check, MAXIMUM_TRACKS, TrackDescriptor, ViewerError, checkpoint, source_id};
use arktrace_contract::{
    CounterScope, CounterSeriesDescriptor, ProcessKey, TraceCapabilities, TraceDensitySource,
    TraceThread,
};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

pub const TRACK_TREE_API_VERSION: u32 = 1;
pub const MAXIMUM_CATALOG_THREADS: usize = 1_000;
pub const MAXIMUM_CATALOG_CPU_FACTS: usize = 20_000;
pub const MAXIMUM_CATALOG_COUNTERS: usize = 2_000;
pub const MAXIMUM_CATALOG_FRAME_OWNERS: usize = 20_000;
pub const MAXIMUM_TREE_GROUPS: usize = 10_000;
pub const MAXIMUM_VIEW_TEXT_BYTES: usize = 4_096;
pub const MAXIMUM_TRACK_ID_BYTES: usize = 128;
/// Owned inline records plus all nested Vec/String capacities; not allocator RSS.
pub const MAXIMUM_VIEW_RETAINED_BYTES: usize = 8 * 1_024 * 1_024;
/// Borrowed input scan/payload cap, independent of owned output capacity.
pub const MAXIMUM_VIEW_INPUT_LOGICAL_BYTES: usize = 8 * 1_024 * 1_024;
pub const MAXIMUM_FAVORITE_TRACKS: usize = 12;
pub const DEFAULT_EXPANDED_PROCESS_COUNT: usize = 8;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TrackGroupKind {
    Cpu,
    CpuCounter,
    Process,
    Unattributed,
}

/// Titles belong to the sidebar. Geometry continues to consume the existing
/// title-free descriptor, so this module does not alter the rendering wire.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SidebarTrack {
    pub title: String,
    pub descriptor: TrackDescriptor,
}
impl SidebarTrack {
    pub fn id(&self) -> String {
        self.descriptor.id()
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TrackGroup {
    pub id: String,
    pub kind: TrackGroupKind,
    pub process_key: Option<ProcessKey>,
    pub title: String,
    pub capability_available: bool,
    pub truncated: bool,
    pub tracks: Vec<SidebarTrack>,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TrackTree {
    pub groups: Vec<TrackGroup>,
}

/// Only the CPU and owning ipid are used; no event is fabricated from this
/// sample-count projection. The host derives these from the bounded CPU page.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CatalogCpuFact {
    pub cpu: i64,
    pub process_key: Option<ProcessKey>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TrackCatalogFacts {
    pub duration_ns: i64,
    pub capabilities: TraceCapabilities,
    pub threads: Vec<TraceThread>,
    pub threads_truncated: bool,
    pub cpu_samples: Vec<CatalogCpuFact>,
    pub cpu_truncated: bool,
    pub counters: Vec<CounterSeriesDescriptor>,
    pub counters_truncated: bool,
    /// Includes only process keys from a capability-available frame probe.
    /// Unowned frames do not create a speculative frame lane in Swift.
    pub frame_process_keys: Vec<ProcessKey>,
}

pub(crate) fn text_budget(s: &str, total: &mut usize) -> Result<(), ViewerError> {
    if s.len() > MAXIMUM_VIEW_TEXT_BYTES {
        return Err(ViewerError::InputBudgetExceeded);
    }
    *total = total
        .checked_add(s.len())
        .ok_or(ViewerError::InputBudgetExceeded)?;
    if *total > MAXIMUM_VIEW_INPUT_LOGICAL_BYTES {
        return Err(ViewerError::InputBudgetExceeded);
    }
    Ok(())
}
pub(crate) fn logical_budget<T>(count: usize, total: &mut usize) -> Result<(), ViewerError> {
    let bytes = count
        .checked_mul(std::mem::size_of::<T>())
        .ok_or(ViewerError::InputBudgetExceeded)?;
    *total = total
        .checked_add(bytes)
        .ok_or(ViewerError::InputBudgetExceeded)?;
    if *total > MAXIMUM_VIEW_INPUT_LOGICAL_BYTES {
        return Err(ViewerError::InputBudgetExceeded);
    }
    Ok(())
}
/// Add actual owned capacity, excluding allocator bookkeeping/alignment slack.
/// Nested inline fields are already part of their enclosing record allocation.
pub(crate) fn capacity_budget<T>(capacity: usize, total: &mut usize) -> Result<(), ViewerError> {
    let bytes = capacity
        .checked_mul(std::mem::size_of::<T>())
        .ok_or(ViewerError::InputBudgetExceeded)?;
    *total = total
        .checked_add(bytes)
        .ok_or(ViewerError::InputBudgetExceeded)?;
    if *total > MAXIMUM_VIEW_RETAINED_BYTES {
        return Err(ViewerError::InputBudgetExceeded);
    }
    Ok(())
}
pub(crate) fn string_capacity(s: &String, total: &mut usize) -> Result<(), ViewerError> {
    capacity_budget::<u8>(s.capacity(), total)
}
pub(crate) fn thread_capacity(
    threads: &Vec<TraceThread>,
    total: &mut usize,
    check: &mut Check<'_>,
) -> Result<(), ViewerError> {
    capacity_budget::<TraceThread>(threads.capacity(), total)?;
    for (i, t) in threads.iter().enumerate() {
        checkpoint(i, check)?;
        for s in [&t.name, &t.process_name].into_iter().flatten() {
            string_capacity(s, total)?;
        }
    }
    Ok(())
}
pub(crate) fn id_budget(s: &str, total: &mut usize) -> Result<(), ViewerError> {
    if s.len() > MAXIMUM_TRACK_ID_BYTES {
        return Err(ViewerError::InputBudgetExceeded);
    }
    text_budget(s, total)
}
pub(crate) fn validate_threads(
    threads: &[TraceThread],
    total: &mut usize,
    check: &mut Check<'_>,
) -> Result<(), ViewerError> {
    if threads.len() > MAXIMUM_CATALOG_THREADS {
        return Err(ViewerError::InputBudgetExceeded);
    }
    logical_budget::<TraceThread>(threads.len(), total)?;
    let mut ids = BTreeSet::new();
    for (i, t) in threads.iter().enumerate() {
        checkpoint(i, check)?;
        if !ids.insert(t.key) {
            return Err(ViewerError::InvalidEvidence);
        }
        for name in [&t.name, &t.process_name].into_iter().flatten() {
            text_budget(name, total)?;
        }
    }
    Ok(())
}
impl TrackTree {
    /// Includes caller-supplied spare capacity because this tree is owned state.
    /// Borrowed catalog facts are checked by logical length instead.
    pub fn retained_bytes(&self, check: &mut Check<'_>) -> Result<usize, ViewerError> {
        check()?;
        let mut bytes = std::mem::size_of::<Self>();
        self.heap_capacity(&mut bytes, check)?;
        check()?;
        Ok(bytes)
    }
    pub(crate) fn heap_capacity(
        &self,
        bytes: &mut usize,
        check: &mut Check<'_>,
    ) -> Result<(), ViewerError> {
        capacity_budget::<TrackGroup>(self.groups.capacity(), bytes)?;
        for (i, group) in self.groups.iter().enumerate() {
            checkpoint(i, check)?;
            string_capacity(&group.id, bytes)?;
            string_capacity(&group.title, bytes)?;
            capacity_budget::<SidebarTrack>(group.tracks.capacity(), bytes)?;
            for (j, track) in group.tracks.iter().enumerate() {
                checkpoint(j, check)?;
                string_capacity(&track.title, bytes)?;
            }
        }
        Ok(())
    }
    pub fn validate(&self, check: &mut Check<'_>) -> Result<(), ViewerError> {
        check()?;
        if self.groups.len() > MAXIMUM_TREE_GROUPS {
            return Err(ViewerError::InputBudgetExceeded);
        }
        let mut retained = std::mem::size_of::<Self>();
        logical_budget::<TrackGroup>(self.groups.len(), &mut retained)?;
        let mut count = 0;
        let mut groups = BTreeSet::new();
        let mut tracks = BTreeSet::new();
        for (i, g) in self.groups.iter().enumerate() {
            checkpoint(i, check)?;
            id_budget(&g.id, &mut retained)?;
            text_budget(&g.title, &mut retained)?;
            let expected = match g.kind {
                TrackGroupKind::Cpu if g.process_key.is_none() => "cpu".into(),
                TrackGroupKind::CpuCounter if g.process_key.is_none() => "cpu-counter".into(),
                TrackGroupKind::Unattributed if g.process_key.is_none() => "unattributed".into(),
                TrackGroupKind::Process if g.process_key.is_some() => {
                    process_group_id(g.process_key.unwrap())
                }
                _ => return Err(ViewerError::InvalidEvidence),
            };
            if g.id != expected || !groups.insert(&g.id) {
                return Err(ViewerError::InvalidEvidence);
            }
            for t in &g.tracks {
                checkpoint(count, check)?;
                count += 1;
                if count > MAXIMUM_TRACKS {
                    return Err(ViewerError::InputBudgetExceeded);
                }
                logical_budget::<SidebarTrack>(1, &mut retained)?;
                text_budget(&t.title, &mut retained)?;
                if !tracks.insert(t.id()) {
                    return Err(ViewerError::InvalidEvidence);
                }
            }
        }
        self.retained_bytes(check)?;
        check()
    }
    pub fn track_list_truncated(&self) -> bool {
        self.groups.iter().any(|g| g.truncated)
    }
    pub fn track(&self, id: &str) -> Option<&SidebarTrack> {
        self.groups
            .iter()
            .flat_map(|g| &g.tracks)
            .find(|t| t.id() == id)
    }
    pub(crate) fn track_mut(&mut self, id: &str) -> Option<&mut SidebarTrack> {
        self.groups
            .iter_mut()
            .flat_map(|g| &mut g.tracks)
            .find(|t| t.id() == id)
    }
}

pub fn process_group_id(key: ProcessKey) -> String {
    format!("process:{}", key.ipid)
}
pub fn process_group_title(name: Option<&str>, pid: Option<i64>, key: ProcessKey) -> String {
    match (name.filter(|n| !n.is_empty()), pid) {
        (Some(n), Some(p)) => format!("{n} [{p}]"),
        (Some(n), None) => n.into(),
        (None, Some(p)) => format!("PID {p}"),
        (None, None) => format!("ipid {}", key.ipid),
    }
}
pub fn thread_track_title(thread: &TraceThread) -> String {
    let name = thread
        .name
        .clone()
        .unwrap_or_else(|| format!("TID {}", thread.tid));
    match thread.process_name.as_deref().filter(|s| !s.is_empty()) {
        Some(process) => format!("{process} · {name}"),
        None => name,
    }
}
pub(crate) fn sidebar_track(
    title: String,
    source: TraceDensitySource,
    collapsed: bool,
) -> SidebarTrack {
    SidebarTrack {
        title,
        descriptor: TrackDescriptor {
            source,
            is_collapsed: collapsed,
            shows_nested_depth: true,
        },
    }
}
fn counter_tracks(
    items: &[&CounterSeriesDescriptor],
    collapsed: Option<bool>,
    check: &mut Check<'_>,
) -> Result<Vec<SidebarTrack>, ViewerError> {
    let mut seen = BTreeSet::new();
    let mut result = Vec::new();
    for (i, s) in items.iter().enumerate() {
        checkpoint(i, check)?;
        let source = if s.scope == CounterScope::Cpu {
            TraceDensitySource::CpuCounter {
                filter_id: s.filter_id,
                cpu: s.cpu,
            }
        } else {
            TraceDensitySource::ProcessCounter {
                filter_id: s.filter_id,
                process_key: s.process_key,
            }
        };
        if !seen.insert(source_id(&source)) {
            continue;
        }
        let title = s
            .unit
            .as_ref()
            .map(|u| format!("{} ({u})", s.name))
            .unwrap_or_else(|| s.name.clone());
        result.push(sidebar_track(
            title,
            source,
            collapsed.unwrap_or(result.len() >= 16),
        ));
    }
    result.sort_by_key(SidebarTrack::id);
    check()?;
    Ok(result)
}
fn group(
    id: &str,
    kind: TrackGroupKind,
    title: &str,
    available: bool,
    truncated: bool,
    tracks: Vec<SidebarTrack>,
) -> TrackGroup {
    TrackGroup {
        id: id.into(),
        kind,
        process_key: None,
        title: title.into(),
        capability_available: available,
        truncated,
        tracks,
    }
}

pub fn build_track_tree(
    facts: &TrackCatalogFacts,
    check: &mut Check<'_>,
) -> Result<TrackTree, ViewerError> {
    check()?;
    if facts.duration_ns < 0 {
        return Err(ViewerError::InvalidRequest);
    }
    if facts.cpu_samples.len() > MAXIMUM_CATALOG_CPU_FACTS
        || facts.counters.len() > MAXIMUM_CATALOG_COUNTERS
        || facts.frame_process_keys.len() > MAXIMUM_CATALOG_FRAME_OWNERS
    {
        return Err(ViewerError::InputBudgetExceeded);
    }
    let mut retained = std::mem::size_of::<TrackCatalogFacts>();
    logical_budget::<CatalogCpuFact>(facts.cpu_samples.len(), &mut retained)?;
    logical_budget::<CounterSeriesDescriptor>(facts.counters.len(), &mut retained)?;
    logical_budget::<ProcessKey>(facts.frame_process_keys.len(), &mut retained)?;
    validate_threads(&facts.threads, &mut retained, check)?;
    for (i, s) in facts.counters.iter().enumerate() {
        checkpoint(i, check)?;
        text_budget(&s.name, &mut retained)?;
        for t in [&s.process_name, &s.unit].into_iter().flatten() {
            text_budget(t, &mut retained)?;
        }
    }
    let cap = &facts.capabilities;
    if facts.duration_ns == 0 {
        let tree = TrackTree {
            groups: vec![
                group(
                    "cpu",
                    TrackGroupKind::Cpu,
                    "CPUs",
                    cap.cpu_scheduling,
                    false,
                    vec![],
                ),
                group(
                    "cpu-counter",
                    TrackGroupKind::CpuCounter,
                    "CPU Counters",
                    cap.cpu_counters,
                    false,
                    vec![],
                ),
                group(
                    "unattributed",
                    TrackGroupKind::Unattributed,
                    "Unattributed",
                    cap.named_slices,
                    false,
                    vec![],
                ),
            ],
        };
        tree.validate(check)?;
        return Ok(tree);
    }
    let mut cpus = BTreeSet::new();
    let mut scheduled: BTreeMap<i64, usize> = BTreeMap::new();
    for (i, s) in facts.cpu_samples.iter().enumerate() {
        checkpoint(i, check)?;
        cpus.insert(s.cpu);
        if let Some(p) = s.process_key {
            *scheduled.entry(p.ipid).or_default() += 1;
        }
    }
    let cpu_tracks = cpus
        .into_iter()
        .enumerate()
        .map(|(i, cpu)| {
            sidebar_track(
                format!("CPU {cpu}"),
                TraceDensitySource::Cpu { cpu },
                i >= 16,
            )
        })
        .collect();
    let cpu_counters: Vec<_> = facts
        .counters
        .iter()
        .filter(|c| c.scope == CounterScope::Cpu)
        .collect();
    let mut groups = vec![
        group(
            "cpu",
            TrackGroupKind::Cpu,
            "CPUs",
            cap.cpu_scheduling,
            facts.cpu_truncated,
            cpu_tracks,
        ),
        group(
            "cpu-counter",
            TrackGroupKind::CpuCounter,
            "CPU Counters",
            cap.cpu_counters,
            facts.counters_truncated,
            counter_tracks(&cpu_counters, None, check)?,
        ),
    ];
    let mut threads: BTreeMap<i64, Vec<&TraceThread>> = BTreeMap::new();
    let mut unattributed_threads = Vec::new();
    for (i, t) in facts.threads.iter().enumerate() {
        checkpoint(i, check)?;
        match t.process_key {
            Some(p) => threads.entry(p).or_default().push(t),
            None => unattributed_threads.push(t),
        }
    }
    let mut counters: BTreeMap<i64, Vec<&CounterSeriesDescriptor>> = BTreeMap::new();
    let mut unowned_counters = Vec::new();
    for (i, s) in facts.counters.iter().enumerate() {
        checkpoint(i, check)?;
        if s.scope == CounterScope::Process {
            match s.process_key {
                Some(p) => counters.entry(p.ipid).or_default().push(s),
                None => unowned_counters.push(s),
            }
        }
    }
    let mut frames = BTreeSet::new();
    for (i, p) in facts.frame_process_keys.iter().enumerate() {
        checkpoint(i, check)?;
        frames.insert(p.ipid);
    }
    let keys: BTreeSet<_> = threads
        .keys()
        .chain(counters.keys())
        .copied()
        .chain(frames.iter().copied())
        .collect();
    let mut ordered: Vec<_> = keys.into_iter().collect();
    ordered.sort_by(|a, b| {
        scheduled
            .get(b)
            .unwrap_or(&0)
            .cmp(scheduled.get(a).unwrap_or(&0))
            .then_with(|| {
                threads
                    .get(b)
                    .map_or(0, Vec::len)
                    .cmp(&threads.get(a).map_or(0, Vec::len))
            })
            .then(a.cmp(b))
    });
    check()?;
    for (offset, key) in ordered.into_iter().enumerate() {
        checkpoint(offset, check)?;
        let collapsed = offset >= DEFAULT_EXPANDED_PROCESS_COUNT;
        let mut ts = threads.remove(&key).unwrap_or_default();
        ts.sort_by_key(|t| (t.tid, t.key));
        let cs = counters.remove(&key).unwrap_or_default();
        let mut tracks = Vec::new();
        for (i, t) in ts.iter().enumerate() {
            checkpoint(i, check)?;
            if cap.thread_states {
                tracks.push(sidebar_track(
                    thread_track_title(t),
                    TraceDensitySource::ThreadState {
                        thread: arktrace_contract::ThreadKey { itid: t.key },
                    },
                    collapsed,
                ));
            }
            if cap.named_slices {
                tracks.push(sidebar_track(
                    thread_track_title(t),
                    TraceDensitySource::NamedSlice {
                        thread: Some(arktrace_contract::ThreadKey { itid: t.key }),
                    },
                    collapsed,
                ));
            }
        }
        if frames.contains(&key) {
            tracks.push(sidebar_track(
                "Frames".into(),
                TraceDensitySource::Frame {
                    process_key: Some(ProcessKey { ipid: key }),
                },
                collapsed,
            ));
        }
        tracks.extend(counter_tracks(&cs, Some(collapsed), check)?);
        if tracks.is_empty() {
            continue;
        }
        let name = ts
            .iter()
            .find_map(|t| t.process_name.as_deref())
            .or_else(|| cs.iter().find_map(|s| s.process_name.as_deref()));
        let pid = ts
            .iter()
            .find_map(|t| t.pid)
            .or_else(|| cs.iter().find_map(|s| s.pid));
        let process_key = ProcessKey { ipid: key };
        groups.push(TrackGroup {
            id: process_group_id(process_key),
            kind: TrackGroupKind::Process,
            process_key: Some(process_key),
            title: process_group_title(name, pid, process_key),
            capability_available: true,
            truncated: facts.threads_truncated,
            tracks,
        });
    }
    let mut unowned = Vec::new();
    if cap.named_slices {
        unowned.push(sidebar_track(
            "Unattributed Slices".into(),
            TraceDensitySource::NamedSlice { thread: None },
            true,
        ));
    }
    for (i, t) in unattributed_threads.iter().enumerate() {
        checkpoint(i, check)?;
        if cap.thread_states {
            unowned.push(sidebar_track(
                thread_track_title(t),
                TraceDensitySource::ThreadState {
                    thread: arktrace_contract::ThreadKey { itid: t.key },
                },
                true,
            ));
        }
        if cap.named_slices {
            unowned.push(sidebar_track(
                thread_track_title(t),
                TraceDensitySource::NamedSlice {
                    thread: Some(arktrace_contract::ThreadKey { itid: t.key }),
                },
                true,
            ));
        }
    }
    unowned.extend(counter_tracks(&unowned_counters, Some(true), check)?);
    if !unowned.is_empty() {
        groups.push(group(
            "unattributed",
            TrackGroupKind::Unattributed,
            "Unattributed",
            cap.named_slices || cap.thread_states,
            facts.counters_truncated,
            unowned,
        ));
    }
    let tree = TrackTree { groups };
    tree.validate(check)?;
    Ok(tree)
}

/// Foundation CharacterSet.whitespacesAndNewlines includes U+200B and NEL.
/// Rust str::trim's Unicode White_Space is deliberately not substituted.
pub fn trim_sidebar_filter(text: &str) -> &str {
    text.trim_matches(|c| matches!(c, '\u{0009}'..='\u{000d}' | '\u{0020}' | '\u{0085}' | '\u{00a0}' | '\u{1680}' | '\u{2000}'..='\u{200b}' | '\u{2028}' | '\u{2029}' | '\u{202f}' | '\u{205f}' | '\u{3000}'))
}
/// Canonical text comparison port: Swift String.range(of:options:[.caseInsensitive]),
/// including canonical equivalence, full folding and grapheme boundaries.
/// No ASCII/lowercase fallback is offered because it changes sidebar behavior.
/// This callback is read-only, bounded, and must not perform search/IO.
pub trait SidebarTitleMatcher {
    fn contains_case_insensitive(&mut self, title: &str, needle: &str)
    -> Result<bool, ViewerError>;
}
pub fn filtered_group_indices(
    tree: &TrackTree,
    text: &str,
    matcher: &mut impl SidebarTitleMatcher,
    check: &mut Check<'_>,
) -> Result<Vec<usize>, ViewerError> {
    tree.validate(check)?;
    let mut retained = 0;
    text_budget(text, &mut retained)?;
    let needle = trim_sidebar_filter(text);
    let mut result = Vec::new();
    for (i, g) in tree.groups.iter().enumerate() {
        checkpoint(i, check)?;
        check()?;
        let matches = needle.is_empty() || matcher.contains_case_insensitive(&g.title, needle)?;
        check()?;
        if matches {
            result.push(i);
        }
    }
    let mut output_bytes = std::mem::size_of::<Vec<usize>>();
    capacity_budget::<usize>(result.capacity(), &mut output_bytes)?;
    check()?;
    Ok(result)
}
