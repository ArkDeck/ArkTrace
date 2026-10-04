//! Session-owned annotation semantics. No viewport mutation, color assignment,
//! sidecar layout, IO, trace path or favorite rules. Publish only whole actions.
use arktrace_contract::TraceTimeRange;
use serde::{Deserialize, Serialize};
use std::mem::size_of;

pub const ANNOTATION_API_VERSION: u32 = 1;
pub const MAXIMUM_ANNOTATION_RECORDS: u32 = 4096;
pub const MAXIMUM_ANNOTATION_LABEL_BYTES: u32 = 4096;
pub const MAXIMUM_ANNOTATION_INPUT_BYTES: u32 = 4 * 1024 * 1024;
pub const MAXIMUM_ANNOTATION_RETAINED_LABEL_BYTES: u32 = 4 * 1024 * 1024;
pub const MAXIMUM_ANNOTATION_RETAINED_BYTES: u32 = 8 * 1024 * 1024;

/// Numeric discriminants are stable; Rust enum/struct memory layout is not ABI.
#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum AnnotationError {
    UnsupportedVersion = 1,
    InvalidRequest = 2,
    InputBudgetExceeded = 3,
    RetainedBudgetExceeded = 4,
    ArithmeticOverflow = 5,
    IdentityExhausted = 6,
    StaleSession = 7,
    SessionExhausted = 8,
    Cancelled = 9,
    DeadlineReached = 10,
}
impl std::fmt::Display for AnnotationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for AnnotationError {}
pub type AnnotationCheck<'a> = dyn FnMut() -> Result<(), AnnotationError> + 'a;
fn checkpoint(index: usize, check: &mut AnnotationCheck<'_>) -> Result<(), AnnotationError> {
    if index.is_multiple_of(256) {
        check()?;
    }
    Ok(())
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AnnotationBudget {
    pub maximum_records: u32,
    pub maximum_input_bytes: u32,
    pub maximum_retained_label_bytes: u32,
    pub maximum_retained_bytes: u32,
}
impl Default for AnnotationBudget {
    fn default() -> Self {
        Self {
            maximum_records: MAXIMUM_ANNOTATION_RECORDS,
            maximum_input_bytes: MAXIMUM_ANNOTATION_INPUT_BYTES,
            maximum_retained_label_bytes: MAXIMUM_ANNOTATION_RETAINED_LABEL_BYTES,
            maximum_retained_bytes: MAXIMUM_ANNOTATION_RETAINED_BYTES,
        }
    }
}
impl AnnotationBudget {
    fn validate(self) -> Result<(), AnnotationError> {
        if self.maximum_records > MAXIMUM_ANNOTATION_RECORDS
            || self.maximum_input_bytes > MAXIMUM_ANNOTATION_INPUT_BYTES
            || self.maximum_retained_label_bytes > MAXIMUM_ANNOTATION_RETAINED_LABEL_BYTES
            || self.maximum_retained_bytes > MAXIMUM_ANNOTATION_RETAINED_BYTES
        {
            return Err(AnnotationError::InvalidRequest);
        }
        Ok(())
    }
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AnnotationFlag {
    pub id: i64,
    pub timestamp_ns: i64,
    pub label: String,
    pub color_index: i64,
}
impl AnnotationFlag {
    /// Same one-nanosecond target and invalid-negative fallback as Swift,
    /// but MAX + 1 is a typed error rather than a trap.
    pub fn point_range(&self) -> Result<TraceTimeRange, AnnotationError> {
        let end = self
            .timestamp_ns
            .checked_add(1)
            .ok_or(AnnotationError::ArithmeticOverflow)?;
        Ok(TraceTimeRange::query(self.timestamp_ns, end)
            .unwrap_or_else(|_| TraceTimeRange::query(0, 1).expect("constant valid range")))
    }
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AnnotationMark {
    pub id: i64,
    pub range: TraceTimeRange,
    pub label: String,
    pub color_index: i64,
    pub is_persistent: bool,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum AnnotationKind {
    Flag,
    Mark,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub struct AnnotationKey {
    pub kind: AnnotationKind,
    pub id: i64,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub struct AnnotationReveal {
    pub target: AnnotationKey,
    pub range: TraceTimeRange,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum AnnotationPersistenceIntent {
    None,
    Save,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AnnotationOutcome {
    pub created: Option<AnnotationKey>,
    pub reveal: Option<AnnotationReveal>,
    pub persistence: AnnotationPersistenceIntent,
}
impl Default for AnnotationOutcome {
    fn default() -> Self {
        Self {
            created: None,
            reveal: None,
            persistence: AnnotationPersistenceIntent::None,
        }
    }
}
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct AnnotationContext {
    pub viewport_range: Option<TraceTimeRange>,
    pub selected_range: Option<TraceTimeRange>,
    pub selected_event_range: Option<TraceTimeRange>,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AnnotationCommand {
    ScrollNearestFlagIntoView,
    PreviousFlag,
    NextFlag,
    PreviousMark,
    NextMark,
    CreateMark { is_persistent: bool },
}
#[derive(Clone, Copy, Debug)]
pub enum AnnotationAction<'a> {
    AddFlag {
        timestamp_ns: i64,
        label: Option<&'a str>,
    },
    UpdateFlag {
        id: i64,
        label: Option<&'a str>,
        color_index: Option<i64>,
    },
    RemoveFlag {
        id: i64,
    },
    AddMark {
        is_persistent: bool,
        label: Option<&'a str>,
    },
    UpdateMark {
        id: i64,
        label: Option<&'a str>,
        color_index: Option<i64>,
    },
    RemoveMark {
        id: i64,
    },
    CycleFlagColor {
        id: i64,
    },
    CycleMarkColor {
        id: i64,
    },
    Command(AnnotationCommand),
    ReplaceSession {
        new_session_id: u64,
        bounds: Option<TraceTimeRange>,
    },
    /// Invalidate deferred editors without replacing annotations (Swift cancel()).
    AdvanceSession {
        new_session_id: u64,
    },
}
#[derive(Clone, Copy, Debug)]
pub struct AnnotationRequest<'a> {
    pub api_version: u32,
    pub session_id: u64,
    pub context: AnnotationContext,
    pub action: AnnotationAction<'a>,
}
/// Immutable projection only: host owns content identity, disk format and favorites.
/// Accessors borrow slices; neither buffers, labels nor the API version can be edited.
///
/// ```compile_fail
/// use arktrace_viewer::AnnotationPersistence;
/// fn grow(p: &mut AnnotationPersistence) { p.flags.reserve(9_000_000); }
/// ```
/// ```compile_fail
/// use arktrace_viewer::AnnotationPersistence;
/// fn edit(p: &mut AnnotationPersistence) { p.marks()[0].label.push_str("edited"); }
/// ```
/// ```compile_fail
/// use arktrace_viewer::AnnotationPersistence;
/// fn change_version(p: &mut AnnotationPersistence) { p.api_version = 999; }
/// ```
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AnnotationPersistence {
    api_version: u32,
    flags: Vec<AnnotationFlag>,
    marks: Vec<AnnotationMark>,
}
impl AnnotationPersistence {
    pub fn api_version(&self) -> u32 {
        self.api_version
    }
    pub fn flags(&self) -> &[AnnotationFlag] {
        &self.flags
    }
    pub fn marks(&self) -> &[AnnotationMark] {
        &self.marks
    }
    pub fn is_empty(&self) -> bool {
        self.flags.is_empty() && self.marks.is_empty()
    }
    /// Current struct, Vec and label capacities, including spare record slots.
    /// Each clone is an additional caller-owned allocation; host budgets the sum.
    pub fn retained_bytes(&self) -> u64 {
        retained_bytes(size_of::<Self>(), &self.flags, &self.marks) as u64
    }
}
impl Serialize for AnnotationPersistence {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeStruct;
        let mut output = serializer.serialize_struct("AnnotationPersistence", 4)?;
        output.serialize_field("apiVersion", &self.api_version)?;
        output.serialize_field("flags", &self.flags)?;
        output.serialize_field("marks", &self.marks)?;
        output.serialize_field("retainedBytes", &self.retained_bytes())?;
        output.end()
    }
}
#[derive(Debug, Eq, PartialEq)]
pub struct AnnotationState {
    session_id: u64,
    bounds: Option<TraceTimeRange>,
    next_id: i64,
    flags: Vec<AnnotationFlag>,
    marks: Vec<AnnotationMark>,
    budget: AnnotationBudget,
}
fn query(range: Option<TraceTimeRange>) -> Result<(), AnnotationError> {
    if range.is_some_and(|r| r.is_instant()) {
        return Err(AnnotationError::InvalidRequest);
    }
    Ok(())
}
fn label(value: &str) -> Result<(), AnnotationError> {
    if value.len() > MAXIMUM_ANNOTATION_LABEL_BYTES as usize {
        return Err(AnnotationError::InputBudgetExceeded);
    }
    Ok(())
}
fn owned_label(value: &str, check: &mut AnnotationCheck<'_>) -> Result<String, AnnotationError> {
    label(value)?;
    // Copy only validated UTF-8. Check both sides of the <=4096-byte copy.
    check()?;
    let mut result = String::new();
    result
        .try_reserve_exact(value.len())
        .map_err(|_| AnnotationError::RetainedBudgetExceeded)?;
    result.push_str(value);
    check()?;
    Ok(result)
}
fn reserve<T>(values: &mut Vec<T>, count: usize) -> Result<(), AnnotationError> {
    values
        .try_reserve_exact(count)
        .map_err(|_| AnnotationError::RetainedBudgetExceeded)
}
fn copy_flags(
    values: &[AnnotationFlag],
    check: &mut AnnotationCheck<'_>,
) -> Result<Vec<AnnotationFlag>, AnnotationError> {
    let mut output = Vec::new();
    reserve(&mut output, values.len())?;
    for (i, value) in values.iter().enumerate() {
        checkpoint(i, check)?;
        output.push(AnnotationFlag {
            label: owned_label(&value.label, check)?,
            ..*value
        });
    }
    Ok(output)
}
fn copy_marks(
    values: &[AnnotationMark],
    persistent_only: bool,
    check: &mut AnnotationCheck<'_>,
) -> Result<Vec<AnnotationMark>, AnnotationError> {
    let mut output = Vec::new();
    reserve(&mut output, values.len())?;
    for (i, value) in values.iter().enumerate() {
        checkpoint(i, check)?;
        if !persistent_only || value.is_persistent {
            output.push(AnnotationMark {
                label: owned_label(&value.label, check)?,
                ..*value
            });
        }
    }
    Ok(output)
}
fn record_bytes(flags: &[AnnotationFlag], marks: &[AnnotationMark]) -> usize {
    std::mem::size_of_val(flags) + std::mem::size_of_val(marks)
}
fn payload_bytes(
    flags: &[AnnotationFlag],
    marks: &[AnnotationMark],
    check: &mut AnnotationCheck<'_>,
) -> Result<usize, AnnotationError> {
    let mut total = 0usize;
    for (i, text) in flags
        .iter()
        .map(|f| &f.label)
        .chain(marks.iter().map(|m| &m.label))
        .enumerate()
    {
        checkpoint(i, check)?;
        label(text)?;
        total = total
            .checked_add(text.len())
            .ok_or(AnnotationError::InputBudgetExceeded)?;
    }
    Ok(total)
}
fn retained_bytes(fixed: usize, flags: &Vec<AnnotationFlag>, marks: &Vec<AnnotationMark>) -> usize {
    fixed
        + flags.capacity() * size_of::<AnnotationFlag>()
        + marks.capacity() * size_of::<AnnotationMark>()
        + flags.iter().map(|f| f.label.capacity()).sum::<usize>()
        + marks.iter().map(|m| m.label.capacity()).sum::<usize>()
}
fn retain<T>(
    values: &mut Vec<T>,
    mut keep: impl FnMut(&T) -> bool,
    check: &mut AnnotationCheck<'_>,
) -> Result<(), AnnotationError> {
    let mut error = None;
    let mut index = 0;
    values.retain(|value| {
        if error.is_none() {
            error = checkpoint(index, check).err();
        }
        index += 1;
        error.is_none() && keep(value)
    });
    error.map_or(Ok(()), Err)
}
impl AnnotationState {
    pub fn new(
        session_id: u64,
        bounds: Option<TraceTimeRange>,
        budget: AnnotationBudget,
        check: &mut AnnotationCheck<'_>,
    ) -> Result<Self, AnnotationError> {
        check()?;
        budget.validate()?;
        query(bounds)?;
        let state = Self {
            session_id,
            bounds,
            next_id: 1,
            flags: Vec::new(),
            marks: Vec::new(),
            budget,
        };
        state.validate_retained(check)?;
        check()?;
        Ok(state)
    }
    pub fn session_id(&self) -> u64 {
        self.session_id
    }
    pub fn bounds(&self) -> Option<TraceTimeRange> {
        self.bounds
    }
    pub fn next_id(&self) -> i64 {
        self.next_id
    }
    pub fn flags(&self) -> &[AnnotationFlag] {
        &self.flags
    }
    pub fn marks(&self) -> &[AnnotationMark] {
        &self.marks
    }
    pub fn is_empty(&self) -> bool {
        self.flags.is_empty() && self.marks.is_empty()
    }
    pub fn retained_bytes(&self) -> u64 {
        retained_bytes(size_of::<Self>(), &self.flags, &self.marks) as u64
    }
    pub fn retained_label_bytes(&self) -> u64 {
        self.flags
            .iter()
            .map(|f| f.label.len() as u64)
            .chain(self.marks.iter().map(|m| m.label.len() as u64))
            .sum()
    }
    fn validate_retained(&self, check: &mut AnnotationCheck<'_>) -> Result<(), AnnotationError> {
        if self.flags.len() + self.marks.len() > self.budget.maximum_records as usize
            || payload_bytes(&self.flags, &self.marks, check)?
                > self.budget.maximum_retained_label_bytes as usize
            || self.retained_bytes() > self.budget.maximum_retained_bytes as u64
        {
            return Err(AnnotationError::RetainedBudgetExceeded);
        }
        Ok(())
    }
    fn authorize(&self, version: u32, session: u64) -> Result<(), AnnotationError> {
        if version != ANNOTATION_API_VERSION {
            return Err(AnnotationError::UnsupportedVersion);
        }
        if session != self.session_id {
            return Err(AnnotationError::StaleSession);
        }
        Ok(())
    }
    /// Restore host-validated records. Duplicate/negative IDs retain Swift's
    /// first-update/all-delete behavior; next ID is max across both arrays + 1.
    pub fn restore(
        &mut self,
        api_version: u32,
        session_id: u64,
        flags: &[AnnotationFlag],
        marks: &[AnnotationMark],
        check: &mut AnnotationCheck<'_>,
    ) -> Result<(), AnnotationError> {
        check()?;
        self.authorize(api_version, session_id)?;
        if flags
            .len()
            .checked_add(marks.len())
            .is_none_or(|n| n > self.budget.maximum_records as usize)
        {
            return Err(AnnotationError::InputBudgetExceeded);
        }
        let bytes = record_bytes(flags, marks)
            .checked_add(payload_bytes(flags, marks, check)?)
            .ok_or(AnnotationError::InputBudgetExceeded)?;
        if bytes > self.budget.maximum_input_bytes as usize {
            return Err(AnnotationError::InputBudgetExceeded);
        }
        let max_id = flags
            .iter()
            .map(|f| f.id)
            .chain(marks.iter().map(|m| m.id))
            .max();
        let next_id = match max_id {
            Some(id) => id
                .checked_add(1)
                .ok_or(AnnotationError::IdentityExhausted)?,
            None => 1,
        };
        let candidate = Self {
            session_id: self.session_id,
            bounds: self.bounds,
            next_id,
            flags: copy_flags(flags, check)?,
            marks: copy_marks(marks, false, check)?,
            budget: self.budget,
        };
        candidate.validate_retained(check)?;
        check()?;
        *self = candidate;
        Ok(())
    }
    /// Pure projection of save(): insertion order, all flags, kept marks only.
    /// Does not define whether a favorites-containing sidecar can be removed.
    pub fn persistence(
        &self,
        check: &mut AnnotationCheck<'_>,
    ) -> Result<AnnotationPersistence, AnnotationError> {
        check()?;
        let flags = copy_flags(&self.flags, check)?;
        let marks = copy_marks(&self.marks, true, check)?;
        let bytes = retained_bytes(size_of::<AnnotationPersistence>(), &flags, &marks);
        if bytes > self.budget.maximum_retained_bytes as usize {
            return Err(AnnotationError::RetainedBudgetExceeded);
        }
        check()?;
        Ok(AnnotationPersistence {
            api_version: ANNOTATION_API_VERSION,
            flags,
            marks,
        })
    }
    pub fn ordered_flags<'a>(
        &'a self,
        check: &mut AnnotationCheck<'_>,
    ) -> Result<Vec<&'a AnnotationFlag>, AnnotationError> {
        check()?;
        let mut result = Vec::new();
        reserve(&mut result, self.flags.len())?;
        for (i, f) in self.flags.iter().enumerate() {
            checkpoint(i, check)?;
            result.push(f);
        }
        // Stable ordering preserves insertion ties even for duplicate restored IDs.
        // Sort is bounded by 4096 records; no callback executes in its comparator.
        result.sort_by_key(|f| (f.timestamp_ns, f.id));
        check()?;
        Ok(result)
    }
    pub fn ordered_marks<'a>(
        &'a self,
        check: &mut AnnotationCheck<'_>,
    ) -> Result<Vec<&'a AnnotationMark>, AnnotationError> {
        check()?;
        let mut result = Vec::new();
        reserve(&mut result, self.marks.len())?;
        for (i, m) in self.marks.iter().enumerate() {
            checkpoint(i, check)?;
            result.push(m);
        }
        result.sort_by_key(|m| (m.range.start_ns(), m.id));
        check()?;
        Ok(result)
    }
    pub fn flag_after(
        &self,
        timestamp_ns: i64,
        check: &mut AnnotationCheck<'_>,
    ) -> Result<Option<&AnnotationFlag>, AnnotationError> {
        let ordered = self.ordered_flags(check)?;
        Ok(ordered
            .iter()
            .copied()
            .find(|f| f.timestamp_ns > timestamp_ns)
            .or_else(|| ordered.first().copied()))
    }
    pub fn flag_before(
        &self,
        timestamp_ns: i64,
        check: &mut AnnotationCheck<'_>,
    ) -> Result<Option<&AnnotationFlag>, AnnotationError> {
        let ordered = self.ordered_flags(check)?;
        Ok(ordered
            .iter()
            .rev()
            .copied()
            .find(|f| f.timestamp_ns < timestamp_ns)
            .or_else(|| ordered.last().copied()))
    }
    pub fn mark_after(
        &self,
        timestamp_ns: i64,
        check: &mut AnnotationCheck<'_>,
    ) -> Result<Option<&AnnotationMark>, AnnotationError> {
        let ordered = self.ordered_marks(check)?;
        Ok(ordered
            .iter()
            .copied()
            .find(|m| m.range.start_ns() > timestamp_ns)
            .or_else(|| ordered.first().copied()))
    }
    pub fn mark_before(
        &self,
        timestamp_ns: i64,
        check: &mut AnnotationCheck<'_>,
    ) -> Result<Option<&AnnotationMark>, AnnotationError> {
        let ordered = self.ordered_marks(check)?;
        Ok(ordered
            .iter()
            .rev()
            .copied()
            .find(|m| m.range.start_ns() < timestamp_ns)
            .or_else(|| ordered.last().copied()))
    }
    pub fn nearest_flag(
        &self,
        timestamp_ns: i64,
        check: &mut AnnotationCheck<'_>,
    ) -> Result<Option<&AnnotationFlag>, AnnotationError> {
        check()?;
        let mut nearest = None;
        let mut best = None;
        for (i, f) in self.flags.iter().enumerate() {
            checkpoint(i, check)?;
            // Total distance even for MIN/MAX restored timestamps; Swift abs
            // subtraction can trap for those invalid extremes.
            let key = (
                (f.timestamp_ns as i128 - timestamp_ns as i128).unsigned_abs(),
                f.timestamp_ns,
                f.id,
            );
            if best.is_none_or(|b| key < b) {
                best = Some(key);
                nearest = Some(f);
            }
        }
        check()?;
        Ok(nearest)
    }
    /// Copy-on-action transaction. At most two bounded states are live before
    /// commit; caller-owned persistence projections are budgeted separately.
    pub fn apply(
        &mut self,
        request: AnnotationRequest<'_>,
        check: &mut AnnotationCheck<'_>,
    ) -> Result<AnnotationOutcome, AnnotationError> {
        check()?;
        self.authorize(request.api_version, request.session_id)?;
        query(request.context.viewport_range)?;
        let input_label = match request.action {
            AnnotationAction::AddFlag { label, .. }
            | AnnotationAction::UpdateFlag { label, .. }
            | AnnotationAction::AddMark { label, .. }
            | AnnotationAction::UpdateMark { label, .. } => label,
            _ => None,
        };
        if let Some(text) = input_label {
            label(text)?;
        }
        if size_of::<AnnotationRequest<'_>>() + input_label.map_or(0, str::len)
            > self.budget.maximum_input_bytes as usize
        {
            return Err(AnnotationError::InputBudgetExceeded);
        }
        let mut candidate = Self {
            session_id: self.session_id,
            bounds: self.bounds,
            next_id: self.next_id,
            flags: copy_flags(&self.flags, check)?,
            marks: copy_marks(&self.marks, false, check)?,
            budget: self.budget,
        };
        let outcome = candidate.perform(request.action, request.context, check)?;
        candidate.validate_retained(check)?;
        check()?;
        *self = candidate;
        Ok(outcome)
    }
    fn allocate_id(&mut self) -> Result<i64, AnnotationError> {
        let id = self.next_id;
        self.next_id = id
            .checked_add(1)
            .ok_or(AnnotationError::IdentityExhausted)?;
        Ok(id)
    }
    fn add_mark(
        &mut self,
        persistent: bool,
        input_label: Option<&str>,
        context: AnnotationContext,
        check: &mut AnnotationCheck<'_>,
    ) -> Result<AnnotationOutcome, AnnotationError> {
        let Some(range) = context
            .selected_range
            .or(context.selected_event_range)
            .filter(|r| !r.is_instant())
        else {
            return Ok(AnnotationOutcome::default());
        };
        if !persistent {
            retain(&mut self.marks, |m| m.is_persistent, check)?;
        }
        let default_label = if persistent {
            format!("Mark {}", self.marks.len() + 1)
        } else {
            "Mark".into()
        };
        let text = owned_label(input_label.unwrap_or(&default_label), check)?;
        let id = self.allocate_id()?;
        reserve(&mut self.marks, 1)?;
        self.marks.push(AnnotationMark {
            id,
            range,
            label: text,
            color_index: self.marks.len() as i64,
            is_persistent: persistent,
        });
        Ok(AnnotationOutcome {
            created: Some(AnnotationKey {
                kind: AnnotationKind::Mark,
                id,
            }),
            persistence: AnnotationPersistenceIntent::Save,
            ..Default::default()
        })
    }
    fn command(
        &mut self,
        command: AnnotationCommand,
        context: AnnotationContext,
        check: &mut AnnotationCheck<'_>,
    ) -> Result<AnnotationOutcome, AnnotationError> {
        let Some(viewport) = context.viewport_range else {
            return Ok(AnnotationOutcome::default());
        };
        let anchor = viewport.start_ns() + viewport.duration_ns() / 2;
        let reveal = match command {
            AnnotationCommand::CreateMark { is_persistent } => {
                return self.add_mark(is_persistent, None, context, check);
            }
            AnnotationCommand::NextFlag => self
                .flag_after(anchor, check)?
                .map(|f| {
                    Ok(AnnotationReveal {
                        target: AnnotationKey {
                            kind: AnnotationKind::Flag,
                            id: f.id,
                        },
                        range: f.point_range()?,
                    })
                })
                .transpose()?,
            AnnotationCommand::PreviousFlag => self
                .flag_before(anchor, check)?
                .map(|f| {
                    Ok(AnnotationReveal {
                        target: AnnotationKey {
                            kind: AnnotationKind::Flag,
                            id: f.id,
                        },
                        range: f.point_range()?,
                    })
                })
                .transpose()?,
            AnnotationCommand::NextMark => {
                self.mark_after(anchor, check)?.map(|m| AnnotationReveal {
                    target: AnnotationKey {
                        kind: AnnotationKind::Mark,
                        id: m.id,
                    },
                    range: m.range,
                })
            }
            AnnotationCommand::PreviousMark => {
                self.mark_before(anchor, check)?.map(|m| AnnotationReveal {
                    target: AnnotationKey {
                        kind: AnnotationKind::Mark,
                        id: m.id,
                    },
                    range: m.range,
                })
            }
            AnnotationCommand::ScrollNearestFlagIntoView => self
                .nearest_flag(anchor, check)?
                .filter(|f| {
                    f.timestamp_ns < viewport.start_ns() || f.timestamp_ns > viewport.end_ns()
                })
                .map(|f| {
                    Ok(AnnotationReveal {
                        target: AnnotationKey {
                            kind: AnnotationKind::Flag,
                            id: f.id,
                        },
                        range: f.point_range()?,
                    })
                })
                .transpose()?,
        };
        Ok(AnnotationOutcome {
            reveal,
            ..Default::default()
        })
    }
    fn perform(
        &mut self,
        action: AnnotationAction<'_>,
        context: AnnotationContext,
        check: &mut AnnotationCheck<'_>,
    ) -> Result<AnnotationOutcome, AnnotationError> {
        match action {
            AnnotationAction::AddFlag {
                timestamp_ns,
                label: input_label,
            } => {
                let Some(bounds) = self.bounds else {
                    return Ok(AnnotationOutcome::default());
                };
                let default_label = format!("Flag {}", self.flags.len() + 1);
                let text = owned_label(input_label.unwrap_or(&default_label), check)?;
                let id = self.allocate_id()?;
                reserve(&mut self.flags, 1)?;
                self.flags.push(AnnotationFlag {
                    id,
                    timestamp_ns: timestamp_ns.clamp(bounds.start_ns(), bounds.end_ns()),
                    label: text,
                    color_index: self.flags.len() as i64,
                });
                Ok(AnnotationOutcome {
                    created: Some(AnnotationKey {
                        kind: AnnotationKind::Flag,
                        id,
                    }),
                    persistence: AnnotationPersistenceIntent::Save,
                    ..Default::default()
                })
            }
            AnnotationAction::AddMark {
                is_persistent,
                label,
            } => self.add_mark(is_persistent, label, context, check),
            AnnotationAction::UpdateFlag {
                id,
                label,
                color_index,
            } => {
                let Some(f) = self.flags.iter_mut().find(|f| f.id == id) else {
                    return Ok(AnnotationOutcome::default());
                };
                if let Some(text) = label {
                    f.label = owned_label(text, check)?;
                }
                if let Some(index) = color_index {
                    f.color_index = index;
                }
                Ok(AnnotationOutcome {
                    persistence: AnnotationPersistenceIntent::Save,
                    ..Default::default()
                })
            }
            AnnotationAction::UpdateMark {
                id,
                label,
                color_index,
            } => {
                let Some(m) = self.marks.iter_mut().find(|m| m.id == id) else {
                    return Ok(AnnotationOutcome::default());
                };
                if let Some(text) = label {
                    m.label = owned_label(text, check)?;
                }
                if let Some(index) = color_index {
                    m.color_index = index;
                }
                Ok(AnnotationOutcome {
                    persistence: AnnotationPersistenceIntent::Save,
                    ..Default::default()
                })
            }
            AnnotationAction::RemoveFlag { id } => {
                retain(&mut self.flags, |f| f.id != id, check)?;
                Ok(AnnotationOutcome {
                    persistence: AnnotationPersistenceIntent::Save,
                    ..Default::default()
                })
            }
            AnnotationAction::RemoveMark { id } => {
                retain(&mut self.marks, |m| m.id != id, check)?;
                Ok(AnnotationOutcome {
                    persistence: AnnotationPersistenceIntent::Save,
                    ..Default::default()
                })
            }
            AnnotationAction::CycleFlagColor { id } => {
                let Some(f) = self.flags.iter_mut().find(|f| f.id == id) else {
                    return Ok(AnnotationOutcome::default());
                };
                f.color_index = f
                    .color_index
                    .checked_add(1)
                    .ok_or(AnnotationError::ArithmeticOverflow)?;
                Ok(AnnotationOutcome {
                    persistence: AnnotationPersistenceIntent::Save,
                    ..Default::default()
                })
            }
            AnnotationAction::CycleMarkColor { id } => {
                let Some(m) = self.marks.iter_mut().find(|m| m.id == id) else {
                    return Ok(AnnotationOutcome::default());
                };
                m.color_index = m
                    .color_index
                    .checked_add(1)
                    .ok_or(AnnotationError::ArithmeticOverflow)?;
                Ok(AnnotationOutcome {
                    persistence: AnnotationPersistenceIntent::Save,
                    ..Default::default()
                })
            }
            AnnotationAction::Command(command) => self.command(command, context, check),
            AnnotationAction::AdvanceSession { new_session_id } => {
                if self.session_id == u64::MAX {
                    return Err(AnnotationError::SessionExhausted);
                }
                if new_session_id <= self.session_id {
                    return Err(AnnotationError::StaleSession);
                }
                self.session_id = new_session_id;
                Ok(AnnotationOutcome::default())
            }
            AnnotationAction::ReplaceSession {
                new_session_id,
                bounds,
            } => {
                if self.session_id == u64::MAX {
                    return Err(AnnotationError::SessionExhausted);
                }
                if new_session_id <= self.session_id {
                    return Err(AnnotationError::StaleSession);
                }
                query(bounds)?;
                self.flags = Vec::new();
                self.marks = Vec::new();
                self.next_id = 1;
                self.session_id = new_session_id;
                self.bounds = bounds;
                Ok(AnnotationOutcome::default())
            }
        }
    }
}
