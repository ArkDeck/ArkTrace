//! Transactional pure sidebar/search actions. Returned intents are executed
//! by the session owner and native UI; this module never persists sidecars.
use crate::track_tree::{
    capacity_budget, id_budget, logical_budget, sidebar_track, string_capacity, text_budget,
    thread_capacity, validate_threads,
};
use crate::{
    Check, DetailPreference, MAXIMUM_FAVORITE_TRACKS, MAXIMUM_TRACKS, SidebarTrack, TrackGroup,
    TrackGroupKind, TrackTree, ViewIdentity, ViewerError, checkpoint, process_group_id,
    process_group_title, reveal_range, step_search_index,
};
use arktrace_contract::{
    EventKey, ProcessKey, ThreadKey, TraceCapabilities, TraceDensitySource, TraceSearchResult,
    TraceSearchResultKind, TraceThread, TraceTimeRange,
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

pub const VIEW_ACTION_API_VERSION: u32 = 1;
pub const MAXIMUM_VIEW_SEARCH_RESULTS: usize = 1_000;
pub const MAXIMUM_STORED_FAVORITE_IDS: usize = MAXIMUM_TRACKS;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ViewState {
    pub identity: ViewIdentity,
    pub tree: TrackTree,
    pub catalog_threads: Vec<TraceThread>,
    pub capabilities: TraceCapabilities,
    pub bounds: Option<TraceTimeRange>,
    pub viewport_range: Option<TraceTimeRange>,
    pub process_filter_text: String,
    pub favorite_track_ids: Vec<String>,
    pub search_results: Vec<TraceSearchResult>,
    pub search_results_truncated: bool,
    pub search_selection_index: Option<usize>,
    pub pending_selection_key: Option<EventKey>,
}
impl ViewState {
    /// Count one owned state, including every nested spare capacity. The
    /// session owner separately budgets input+output and algorithm scratch peak.
    pub fn retained_bytes(&self, check: &mut Check<'_>) -> Result<usize, ViewerError> {
        check()?;
        let mut bytes = std::mem::size_of::<Self>();
        self.heap_capacity(&mut bytes, check)?;
        check()?;
        Ok(bytes)
    }
    fn heap_capacity(&self, bytes: &mut usize, check: &mut Check<'_>) -> Result<(), ViewerError> {
        self.tree.heap_capacity(bytes, check)?;
        thread_capacity(&self.catalog_threads, bytes, check)?;
        string_capacity(&self.process_filter_text, bytes)?;
        capacity_budget::<String>(self.favorite_track_ids.capacity(), bytes)?;
        for (i, id) in self.favorite_track_ids.iter().enumerate() {
            checkpoint(i, check)?;
            string_capacity(id, bytes)?;
        }
        capacity_budget::<TraceSearchResult>(self.search_results.capacity(), bytes)?;
        for (i, result) in self.search_results.iter().enumerate() {
            checkpoint(i, check)?;
            string_capacity(&result.title, bytes)?;
            if let Some(subtitle) = &result.subtitle {
                string_capacity(subtitle, bytes)?;
            }
        }
        Ok(())
    }
    pub fn validate(&self, check: &mut Check<'_>) -> Result<(), ViewerError> {
        self.tree.validate(check)?;
        if self.viewport_range.is_some_and(|r| r.is_instant()) {
            return Err(ViewerError::InvalidViewport);
        }
        let mut bytes = std::mem::size_of::<Self>();
        logical_budget::<TrackGroup>(self.tree.groups.len(), &mut bytes)?;
        validate_threads(&self.catalog_threads, &mut bytes, check)?;
        // Count every retained string including the tree, not independent caps.
        for (i, g) in self.tree.groups.iter().enumerate() {
            checkpoint(i, check)?;
            id_budget(&g.id, &mut bytes)?;
            text_budget(&g.title, &mut bytes)?;
            for (j, t) in g.tracks.iter().enumerate() {
                checkpoint(j, check)?;
                if group_id(&t.descriptor.source, &self.catalog_threads) != g.id {
                    return Err(ViewerError::InvalidEvidence);
                }
                logical_budget::<SidebarTrack>(1, &mut bytes)?;
                text_budget(&t.title, &mut bytes)?;
            }
        }
        text_budget(&self.process_filter_text, &mut bytes)?;
        if self.favorite_track_ids.len() > MAXIMUM_STORED_FAVORITE_IDS
            || self.search_results.len() > MAXIMUM_VIEW_SEARCH_RESULTS
        {
            return Err(ViewerError::InputBudgetExceeded);
        }
        logical_budget::<String>(self.favorite_track_ids.len(), &mut bytes)?;
        logical_budget::<TraceSearchResult>(self.search_results.len(), &mut bytes)?;
        for (i, id) in self.favorite_track_ids.iter().enumerate() {
            checkpoint(i, check)?;
            id_budget(id, &mut bytes)?;
        }
        for (i, r) in self.search_results.iter().enumerate() {
            checkpoint(i, check)?;
            validate_result(r, &mut bytes)?;
        }
        self.retained_bytes(check)?;
        // Cursor validity is handled by each action: persisted/stale cursors
        // cannot index a different result set and do not invalidate the tree.
        check()
    }
    pub fn favorite_tracks(
        &self,
        check: &mut Check<'_>,
    ) -> Result<Vec<&SidebarTrack>, ViewerError> {
        self.validate(check)?;
        let by_id: std::collections::BTreeMap<_, _> = self
            .tree
            .groups
            .iter()
            .flat_map(|g| &g.tracks)
            .map(|t| (t.id(), t))
            .collect();
        let mut tracks = Vec::new();
        let mut seen = BTreeSet::new();
        for (i, id) in self.favorite_track_ids.iter().enumerate() {
            checkpoint(i, check)?;
            if let Some(t) = by_id.get(id)
                && seen.insert(id)
            {
                tracks.push(*t);
                if tracks.len() == MAXIMUM_FAVORITE_TRACKS {
                    break;
                }
            }
        }
        let mut bytes = std::mem::size_of::<Vec<&SidebarTrack>>();
        capacity_budget::<&SidebarTrack>(tracks.capacity(), &mut bytes)?;
        check()?;
        Ok(tracks)
    }
}
fn validate_result(result: &TraceSearchResult, bytes: &mut usize) -> Result<(), ViewerError> {
    text_budget(&result.title, bytes)?;
    if let Some(subtitle) = &result.subtitle {
        text_budget(subtitle, bytes)?;
    }
    Ok(())
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum ViewAction {
    ToggleTrack {
        id: String,
    },
    ToggleTrackDepth {
        id: String,
    },
    RevealTrackGroup {
        id: String,
    },
    ToggleFavorite {
        id: String,
    },
    MoveFavorite {
        source: i64,
        destination: i64,
    },
    RestoreFavorites {
        ids: Vec<String>,
    },
    SetProcessFilter {
        text: String,
    },
    SetSearchResults {
        items: Vec<TraceSearchResult>,
        #[serde(default)]
        truncated: bool,
    },
    SelectSearchResult {
        index: i64,
    },
    StepSearchResult {
        delta: i64,
    },
    ActivateSearchResult,
    RevealSearchResult {
        result: TraceSearchResult,
    },
    RevealSliceAggregate {
        name: String,
        first_thread_key: Option<ThreadKey>,
        first_event_key: Option<EventKey>,
        first_range: Option<TraceTimeRange>,
    },
    RevealRange {
        range: TraceTimeRange,
    },
    AdmitTrack {
        track: SidebarTrack,
    },
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ViewActionRequest {
    pub identity: ViewIdentity,
    pub action: ViewAction,
}
impl ViewActionRequest {
    fn validate(&self, check: &mut Check<'_>) -> Result<(), ViewerError> {
        check()?;
        let mut bytes = std::mem::size_of::<Self>();
        match &self.action {
            ViewAction::ToggleTrack { id }
            | ViewAction::ToggleTrackDepth { id }
            | ViewAction::RevealTrackGroup { id }
            | ViewAction::ToggleFavorite { id } => id_budget(id, &mut bytes)?,
            ViewAction::RestoreFavorites { ids } => {
                if ids.len() > MAXIMUM_STORED_FAVORITE_IDS {
                    return Err(ViewerError::InputBudgetExceeded);
                }
                logical_budget::<String>(ids.len(), &mut bytes)?;
                for (i, id) in ids.iter().enumerate() {
                    checkpoint(i, check)?;
                    id_budget(id, &mut bytes)?;
                }
            }
            ViewAction::SetProcessFilter { text } => text_budget(text, &mut bytes)?,
            ViewAction::SetSearchResults { items, .. } => {
                if items.len() > MAXIMUM_VIEW_SEARCH_RESULTS {
                    return Err(ViewerError::InputBudgetExceeded);
                }
                logical_budget::<TraceSearchResult>(items.len(), &mut bytes)?;
                for (i, r) in items.iter().enumerate() {
                    checkpoint(i, check)?;
                    validate_result(r, &mut bytes)?;
                }
            }
            ViewAction::RevealSearchResult { result } => validate_result(result, &mut bytes)?,
            ViewAction::RevealSliceAggregate { name, .. } => text_budget(name, &mut bytes)?,
            ViewAction::AdmitTrack { track } => text_budget(&track.title, &mut bytes)?,
            _ => {}
        }
        check()
    }
}
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ViewIntents {
    pub viewport_range: Option<TraceTimeRange>,
    pub focus_timeline: bool,
    /// Requires real snapshot/Inspector evidence before selection can commit.
    pub pending_event_key: Option<EventKey>,
    pub snapshot_preference: Option<DetailPreference>,
    /// The host finds the group's first actual laid-out lane. No guessed y.
    pub scroll_group_id: Option<String>,
    pub scroll_after_snapshot: bool,
    /// The host may persist the returned favorite IDs using its existing IO.
    pub persist_favorites: bool,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ViewReduction {
    pub state: ViewState,
    pub applied: bool,
    pub stale: bool,
    pub intents: ViewIntents,
}

impl ViewReduction {
    /// Entire published result: state, action flags, intents, and intent text.
    pub fn retained_bytes(&self, check: &mut Check<'_>) -> Result<usize, ViewerError> {
        check()?;
        let mut bytes = std::mem::size_of::<Self>();
        self.state.heap_capacity(&mut bytes, check)?;
        if let Some(id) = &self.intents.scroll_group_id {
            string_capacity(id, &mut bytes)?;
        }
        check()?;
        Ok(bytes)
    }
}

fn group_id(source: &TraceDensitySource, threads: &[TraceThread]) -> String {
    match source {
        TraceDensitySource::Cpu { .. } => "cpu".into(),
        TraceDensitySource::CpuCounter { .. } => "cpu-counter".into(),
        TraceDensitySource::ProcessCounter { process_key, .. }
        | TraceDensitySource::Frame { process_key } => process_key
            .map(process_group_id)
            .unwrap_or_else(|| "unattributed".into()),
        TraceDensitySource::ThreadState { thread }
        | TraceDensitySource::NamedSlice {
            thread: Some(thread),
        } => threads
            .iter()
            .find(|t| t.key == thread.itid)
            .and_then(|t| t.process_key)
            .map(|ipid| process_group_id(ProcessKey { ipid }))
            .unwrap_or_else(|| "unattributed".into()),
        TraceDensitySource::NamedSlice { thread: None } => "unattributed".into(),
    }
}
fn admit(state: &mut ViewState, descriptor: SidebarTrack) {
    let id = group_id(&descriptor.descriptor.source, &state.catalog_threads);
    if let Some(group) = state.tree.groups.iter_mut().find(|g| g.id == id) {
        if let Some(existing) = group.tracks.iter_mut().find(|t| t.id() == descriptor.id()) {
            if existing.descriptor.is_collapsed {
                let depth = existing.descriptor.shows_nested_depth;
                *existing = descriptor;
                existing.descriptor.is_collapsed = false;
                existing.descriptor.shows_nested_depth = depth;
            }
        } else {
            group.tracks.push(descriptor);
        }
        return;
    }
    let thread = state
        .catalog_threads
        .iter()
        .find(|t| match descriptor.descriptor.source {
            TraceDensitySource::ThreadState { thread }
            | TraceDensitySource::NamedSlice {
                thread: Some(thread),
            } => t.key == thread.itid,
            _ => false,
        });
    // Swift appendGroup only appends a process node from a catalog thread.
    // Missing unowned/counter/CPU groups are deliberately not invented.
    if let Some(thread) = thread
        && let Some(ipid) = thread.process_key
    {
        let key = ProcessKey { ipid };
        state.tree.groups.push(TrackGroup {
            id,
            kind: TrackGroupKind::Process,
            process_key: Some(key),
            title: process_group_title(thread.process_name.as_deref(), thread.pid, key),
            capability_available: true,
            truncated: false,
            tracks: vec![descriptor],
        });
    }
}
fn expand(
    state: &mut ViewState,
    keys: &BTreeSet<i64>,
    check: &mut Check<'_>,
) -> Result<(), ViewerError> {
    for (i, track) in state
        .tree
        .groups
        .iter_mut()
        .flat_map(|g| &mut g.tracks)
        .enumerate()
    {
        checkpoint(i, check)?;
        match track.descriptor.source {
            TraceDensitySource::ThreadState { thread }
            | TraceDensitySource::NamedSlice {
                thread: Some(thread),
            } if keys.contains(&thread.itid) => track.descriptor.is_collapsed = false,
            _ => {}
        }
    }
    Ok(())
}
fn admit_slice(state: &mut ViewState, thread: Option<ThreadKey>, title: &str) {
    if state.capabilities.named_slices {
        admit(
            state,
            sidebar_track(
                if thread.is_none() {
                    "Unattributed Slices".into()
                } else {
                    title.into()
                },
                TraceDensitySource::NamedSlice { thread },
                false,
            ),
        );
    }
}
fn apply_range(
    state: &mut ViewState,
    event: TraceTimeRange,
    intents: &mut ViewIntents,
) -> Result<bool, ViewerError> {
    if let Some(bounds) = state.bounds
        && state.viewport_range.is_some()
        && let Some(range) = reveal_range(event, bounds)?
        && state.viewport_range != Some(range)
    {
        state.viewport_range = Some(range);
        intents.viewport_range = Some(range);
        intents.snapshot_preference = Some(DetailPreference::Automatic);
        return Ok(true);
    }
    Ok(false)
}
fn reveal(
    state: &mut ViewState,
    result: &TraceSearchResult,
    focus: bool,
    intents: &mut ViewIntents,
    check: &mut Check<'_>,
) -> Result<(), ViewerError> {
    let mut keys = BTreeSet::new();
    match result.kind {
        TraceSearchResultKind::Process => {
            for (i, t) in state.catalog_threads.iter().enumerate() {
                checkpoint(i, check)?;
                if t.process_key == result.process_key.map(|p| p.ipid) {
                    keys.insert(t.key);
                }
            }
        }
        TraceSearchResultKind::Thread => {
            if let Some(thread) = result.thread_key {
                if state.capabilities.thread_states {
                    admit(
                        state,
                        sidebar_track(
                            result.title.clone(),
                            TraceDensitySource::ThreadState { thread },
                            false,
                        ),
                    );
                }
                admit_slice(state, Some(thread), &result.title);
                keys.insert(thread.itid);
            }
        }
        TraceSearchResultKind::Slice => {
            admit_slice(state, result.thread_key, &result.title);
            if let Some(thread) = result.thread_key {
                keys.insert(thread.itid);
            }
            state.pending_selection_key = result.event_key;
        }
    }
    expand(state, &keys, check)?;
    if let Some(range) = result.range {
        apply_range(state, range, intents)?;
    }
    intents.focus_timeline = focus;
    intents.pending_event_key = state.pending_selection_key;
    intents.snapshot_preference = Some(if result.event_key.is_some() {
        DetailPreference::Detail
    } else {
        DetailPreference::Automatic
    });
    Ok(())
}

/// Validates owned input state (including spare capacity) before cloning.
/// Borrowed request payload is scan/length bounded; its spare capacity remains
/// with the caller. Every published reduction includes the entire owned output.
/// Temporary BTree/sort allocations and simultaneous input+output are host
/// aggregate budget responsibilities; this cap does not claim allocator RSS.
/// Validates all retained/action input before cloning. Failure/cancellation
/// never partially mutates the caller's state or poisons the next request.
pub fn reduce_view_action(
    state: &ViewState,
    request: &ViewActionRequest,
    check: &mut Check<'_>,
) -> Result<ViewReduction, ViewerError> {
    state.validate(check)?;
    request.validate(check)?;
    let mut reduction = ViewReduction {
        state: state.clone(),
        applied: false,
        stale: request.identity != state.identity,
        intents: ViewIntents::default(),
    };
    check()?;
    if reduction.stale {
        reduction.retained_bytes(check)?;
        check()?;
        return Ok(reduction);
    }
    let next = &mut reduction.state;
    let intents = &mut reduction.intents;
    match &request.action {
        ViewAction::ToggleTrack { id } | ViewAction::ToggleTrackDepth { id } => {
            if let Some(t) = next.tree.track_mut(id) {
                if matches!(request.action, ViewAction::ToggleTrack { .. }) {
                    t.descriptor.is_collapsed = !t.descriptor.is_collapsed;
                } else {
                    t.descriptor.shows_nested_depth = !t.descriptor.shows_nested_depth;
                }
                reduction.applied = true;
                intents.snapshot_preference = Some(DetailPreference::Automatic);
            }
        }
        ViewAction::RevealTrackGroup { id } => {
            if let Some(g) = next.tree.groups.iter_mut().find(|g| &g.id == id)
                && !g.tracks.is_empty()
            {
                let hidden = g.tracks.iter().all(|t| t.descriptor.is_collapsed);
                if hidden {
                    for (i, t) in g.tracks.iter_mut().enumerate() {
                        checkpoint(i, check)?;
                        t.descriptor.is_collapsed = false;
                    }
                    intents.snapshot_preference = Some(DetailPreference::Automatic);
                }
                intents.scroll_group_id = Some(id.clone());
                intents.scroll_after_snapshot = hidden;
                reduction.applied = true;
            }
        }
        ViewAction::ToggleFavorite { id } => {
            if next.favorite_track_ids.contains(id) {
                next.favorite_track_ids.retain(|i| i != id);
                reduction.applied = true;
            } else if next.favorite_tracks(check)?.len() < MAXIMUM_FAVORITE_TRACKS {
                next.favorite_track_ids.push(id.clone());
                if let Some(t) = next.tree.track_mut(id) {
                    t.descriptor.is_collapsed = false;
                    intents.snapshot_preference = Some(DetailPreference::Automatic);
                }
                reduction.applied = true;
            }
            intents.persist_favorites = reduction.applied;
        }
        ViewAction::MoveFavorite {
            source,
            destination,
        } => {
            let visible: Vec<_> = next
                .favorite_tracks(check)?
                .iter()
                .map(|t| t.id())
                .collect();
            if let (Ok(source), Ok(destination)) =
                (usize::try_from(*source), usize::try_from(*destination))
                && source < visible.len()
                && destination <= visible.len()
            {
                let id = &visible[source];
                let count = next
                    .favorite_track_ids
                    .iter()
                    .filter(|candidate| *candidate == id)
                    .count();
                next.favorite_track_ids.retain(|candidate| candidate != id);
                let mut reordered = visible.clone();
                reordered.remove(source);
                let index = if destination > source {
                    destination - 1
                } else {
                    destination
                };
                let target = reordered
                    .get(index)
                    .and_then(|target| {
                        next.favorite_track_ids
                            .iter()
                            .position(|candidate| candidate == target)
                    })
                    .unwrap_or(next.favorite_track_ids.len());
                next.favorite_track_ids
                    .splice(target..target, std::iter::repeat_n(id.clone(), count));
                reduction.applied = true;
                intents.persist_favorites = true;
            }
        }
        ViewAction::RestoreFavorites { ids } => {
            next.favorite_track_ids.clear();
            for (i, id) in ids.iter().enumerate() {
                checkpoint(i, check)?;
                next.favorite_track_ids.push(id.clone());
            }
            // Stored IDs keep unknown records and duplicates; display alone
            // chooses up to twelve distinct known tracks.
            reduction.applied = true;
        }
        ViewAction::SetProcessFilter { text } => {
            next.process_filter_text = text.clone();
            reduction.applied = true;
        }
        ViewAction::SetSearchResults { items, truncated } => {
            if next.search_results != *items || next.search_results_truncated != *truncated {
                next.search_selection_index = None;
            }
            next.search_results = items.clone();
            next.search_results_truncated = *truncated;
            reduction.applied = true;
        }
        ViewAction::SelectSearchResult { index } => {
            if let Ok(index) = usize::try_from(*index)
                && index < next.search_results.len()
            {
                next.search_selection_index = Some(index);
                reduction.applied = true;
            }
        }
        ViewAction::StepSearchResult { delta } => {
            if let Some(index) = step_search_index(
                next.search_results.len(),
                next.search_selection_index,
                *delta,
            ) {
                next.search_selection_index = Some(index);
                let result = next.search_results[index].clone();
                reveal(next, &result, false, intents, check)?;
                reduction.applied = true;
            }
        }
        ViewAction::ActivateSearchResult => {
            if let Some(index) = next.search_selection_index
                && let Some(result) = next.search_results.get(index).cloned()
            {
                reveal(next, &result, true, intents, check)?;
                reduction.applied = true;
            }
        }
        ViewAction::RevealSearchResult { result } => {
            reveal(next, result, true, intents, check)?;
            reduction.applied = true;
        }
        ViewAction::RevealSliceAggregate {
            name,
            first_thread_key,
            first_event_key,
            first_range,
        } => {
            let result = TraceSearchResult {
                kind: TraceSearchResultKind::Slice,
                title: name.clone(),
                subtitle: None,
                process_key: None,
                thread_key: *first_thread_key,
                event_key: *first_event_key,
                range: *first_range,
            };
            reveal(next, &result, true, intents, check)?;
            reduction.applied = true;
        }
        ViewAction::RevealRange { range } => {
            reduction.applied = apply_range(next, *range, intents)?;
        }
        ViewAction::AdmitTrack { track } => {
            let old = next.tree.clone();
            admit(next, track.clone());
            reduction.applied = next.tree != old;
        }
    }
    next.validate(check)?;
    reduction.retained_bytes(check)?;
    check()?;
    Ok(reduction)
}
