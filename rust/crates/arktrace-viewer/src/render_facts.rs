//! Session-origin display facts retained alongside geometry, never supplied by
//! a geometry JSON client. Projection reuses the canonical presentation and
//! Inspector modules, and shares each immutable chunk instead of cloning text.
use crate::*;
use arktrace_contract::*;
use std::{collections::BTreeSet, mem::size_of, sync::Arc};

pub const MAXIMUM_RENDER_FACT_BYTES: usize = 16 * 1024 * 1024;

#[derive(Debug)]
struct RenderBatch {
    presentation: PresentationBatch,
    inspectors: InspectorProjectionBatch,
}
#[derive(Clone, Debug)]
pub struct RenderDetailFacts {
    batch: Arc<RenderBatch>,
    index: usize,
}
impl RenderDetailFacts {
    pub fn presentation(&self) -> &DetailPresentation {
        let PrimitivePresentation::Detail { detail } =
            &self.batch.presentation.primitives()[self.index]
        else {
            unreachable!("detail-only projection")
        };
        detail
    }
    pub fn label(&self) -> Option<&str> {
        self.batch.presentation.text(self.presentation().label)
    }
    pub fn category(&self) -> Option<&str> {
        self.batch.presentation.text(self.presentation().category)
    }
    pub fn inspector(&self) -> InspectorFacts {
        self.batch.inspectors.records()[self.index].expect("source detail Inspector")
    }
    pub fn inspector_text(&self, index: Option<u32>) -> Option<&str> {
        self.batch.inspectors.text(index)
    }
    pub(crate) fn batch_identity(&self) -> usize {
        Arc::as_ptr(&self.batch) as usize
    }
    pub(crate) fn batch_bytes(&self) -> usize {
        size_of::<RenderBatch>()
            + 2 * size_of::<usize>()
            + self.batch.presentation.retained_bytes()
            + self.batch.inspectors.retained_bytes() as usize
    }
}
impl PartialEq for RenderDetailFacts {
    fn eq(&self, other: &Self) -> bool {
        let a = self.inspector();
        let b = other.inspector();
        self.label() == other.label()
            && self.category() == other.category()
            && self.presentation().event_key == other.presentation().event_key
            && self.presentation().jank_tag == other.presentation().jank_tag
            && self.presentation().color == other.presentation().color
            && a.key() == b.key()
            && a.kind() == b.kind()
            && a.range() == b.range()
            && a.semantic_duration_ns() == b.semantic_duration_ns()
            && a.is_open_ended() == b.is_open_ended()
            && a.process_key() == b.process_key()
            && a.thread_key() == b.thread_key()
            && a.pid() == b.pid()
            && a.tid() == b.tid()
            && a.cpu() == b.cpu()
            && a.value() == b.value()
            && a.priority() == b.priority()
            && [
                (a.name(), b.name()),
                (a.process_name(), b.process_name()),
                (a.thread_name(), b.thread_name()),
                (a.category(), b.category()),
                (a.state(), b.state()),
                (a.unit(), b.unit()),
            ]
            .into_iter()
            .all(|(a, b)| self.inspector_text(a) == other.inspector_text(b))
    }
}

pub(crate) fn charge_render_facts<'a>(
    details: impl Iterator<Item = &'a DetailInput>,
    batches: &mut BTreeSet<usize>,
    bytes: &mut usize,
) -> Result<(), ViewerError> {
    for detail in details {
        if let Some(fact) = &detail.render_facts
            && batches.insert(fact.batch_identity())
        {
            *bytes = bytes
                .checked_add(fact.batch_bytes())
                .ok_or(ViewerError::InputBudgetExceeded)?;
            if *bytes > MAXIMUM_RENDER_FACT_BYTES {
                return Err(ViewerError::InputBudgetExceeded);
            }
        }
    }
    Ok(())
}

pub(crate) fn project_render_page(
    page: &RepositoryDetailPage,
    range: TraceTimeRange,
    check: &mut Check<'_>,
) -> Result<Vec<RenderDetailFacts>, ViewerError> {
    check()?;
    let mut presentation = Vec::new();
    let mut inspectors = Vec::new();
    // Counter Inspector projection accepts descriptors, not whole sample
    // series. Bound aggregate source text before creating these descriptors.
    let descriptors = if let RepositoryDetailPage::Counter(page) = page {
        let mut bytes = 0usize;
        if page.items.len() > MAXIMUM_PRIMITIVES {
            return Err(ViewerError::InputBudgetExceeded);
        }
        for series in &page.items {
            check()?;
            for text in [
                Some(series.name.as_str()),
                series.process_name.as_deref(),
                series.unit.as_deref(),
            ]
            .into_iter()
            .flatten()
            {
                bytes = bytes
                    .checked_add(text.len())
                    .ok_or(ViewerError::InputBudgetExceeded)?;
                if text.len() > MAXIMUM_INSPECTOR_TEXT_BYTES as usize
                    || bytes > MAXIMUM_INSPECTOR_INPUT_STRING_BYTES as usize
                {
                    return Err(ViewerError::InputBudgetExceeded);
                }
            }
        }
        page.items
            .iter()
            .map(|s| CounterSeriesDescriptor {
                filter_id: s.filter_id,
                name: s.name.clone(),
                scope: s.scope,
                cpu: s.cpu,
                process_key: s.process_key,
                pid: s.pid,
                process_name: s.process_name.clone(),
                unit: s.unit.clone(),
            })
            .collect::<Vec<_>>()
    } else {
        Vec::new()
    };
    macro_rules! add {
        ($p:expr,$i:expr) => {{
            if presentation.len() == MAXIMUM_PRIMITIVES {
                return Err(ViewerError::InputBudgetExceeded);
            }
            presentation.push($p);
            inspectors.push($i);
        }};
    }
    match page {
        RepositoryDetailPage::Cpu(p) => {
            for e in &p.items {
                add!(
                    PresentationInput::Cpu(e),
                    InspectorProjectionInput::CpuSlice(e)
                );
            }
        }
        RepositoryDetailPage::ThreadState(p) => {
            for e in &p.items {
                add!(
                    PresentationInput::ThreadState(e),
                    InspectorProjectionInput::ThreadState(e)
                );
            }
        }
        RepositoryDetailPage::NamedSlice(p) => {
            for e in &p.items {
                add!(
                    PresentationInput::NamedSlice {
                        event: e,
                        shows_nested_depth: true
                    },
                    InspectorProjectionInput::NamedSlice(e)
                );
            }
        }
        RepositoryDetailPage::Frame(p) => {
            for e in &p.items {
                add!(
                    PresentationInput::Frame(e),
                    InspectorProjectionInput::Frame(e)
                );
            }
        }
        RepositoryDetailPage::Counter(p) => {
            for (series, descriptor) in p.items.iter().zip(&descriptors) {
                for (index, sample) in series.samples.iter().enumerate() {
                    add!(
                        PresentationInput::Counter {
                            series,
                            sample_index: index,
                            query_range: range
                        },
                        InspectorProjectionInput::Counter {
                            series: descriptor,
                            sample,
                            query_range: range
                        }
                    );
                }
            }
        }
    }
    let mut output = Vec::new();
    output
        .try_reserve_exact(presentation.len())
        .map_err(|_| ViewerError::InputBudgetExceeded)?;
    let mut retained = output.capacity() * size_of::<RenderDetailFacts>();
    for (p, i) in presentation
        .chunks(MAXIMUM_INSPECTOR_RECORDS as usize)
        .zip(inspectors.chunks(MAXIMUM_INSPECTOR_RECORDS as usize))
    {
        check()?;
        let presentation = present(p, PresentationBudget::default(), check)?;
        let inspectors = project_inspectors(
            INSPECTOR_PROJECTION_API_VERSION,
            i,
            InspectorProjectionBudget::default(),
            &mut || {
                check().map_err(|e| match e {
                    ViewerError::Cancelled => InspectorProjectionError::Cancelled,
                    ViewerError::DeadlineReached => InspectorProjectionError::DeadlineReached,
                    _ => InspectorProjectionError::InvalidRequest,
                })
            },
        )
        .map_err(|e| match e {
            InspectorProjectionError::Cancelled => ViewerError::Cancelled,
            InspectorProjectionError::DeadlineReached => ViewerError::DeadlineReached,
            InspectorProjectionError::InputBudgetExceeded
            | InspectorProjectionError::RetainedBudgetExceeded => ViewerError::InputBudgetExceeded,
            InspectorProjectionError::ArithmeticOverflow => ViewerError::ArithmeticOverflow,
            _ => ViewerError::InvalidEvidence,
        })?;
        retained = retained
            .checked_add(size_of::<RenderBatch>() + 2 * size_of::<usize>())
            .and_then(|n| n.checked_add(presentation.retained_bytes()))
            .and_then(|n| n.checked_add(inspectors.retained_bytes() as usize))
            .ok_or(ViewerError::InputBudgetExceeded)?;
        if retained > MAXIMUM_RENDER_FACT_BYTES {
            return Err(ViewerError::InputBudgetExceeded);
        }
        let batch = Arc::new(RenderBatch {
            presentation,
            inspectors,
        });
        for index in 0..p.len() {
            output.push(RenderDetailFacts {
                batch: batch.clone(),
                index,
            });
        }
    }
    check()?;
    Ok(output)
}
