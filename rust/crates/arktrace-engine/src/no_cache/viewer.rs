use super::*;
use arktrace_contract::{
    EventKey, EventTable, TraceDensityQuery, TraceDensityResult, TraceDensitySource, TraceTimeRange,
};
use arktrace_store::ReadPoolLimits;
use arktrace_viewer::{
    AssembledSnapshot, DensityResolutionRequest, DetailInput, RepositoryDetailPage,
    RepositoryDetailQuery, ViewportFailure, ViewportQueries, ViewportRequest,
};

impl NoCacheSession {
    /// Executes a full immutable viewport on this session's Store owner.
    /// Depth and bounded density caches are private to this trace session.
    pub fn viewer_viewport(
        &self,
        request: &ViewportRequest,
        backing_scale: f64,
        budget: &EngineBudget,
    ) -> Result<Option<AssembledSnapshot>, EngineError> {
        self.query_reader(budget)?;
        let mut state = self
            .viewer
            .try_borrow_mut()
            .map_err(|_| viewer_error(arktrace_viewer::ViewerError::InvalidEvidence))?;
        let mut repository = SessionQueries {
            session: self,
            budget,
        };
        let result = state
            .load(request, backing_scale, &mut repository, &mut || {
                check(budget)
            })
            .map_err(execution_error);
        self.query_reader(budget)?;
        result
    }
    /// A density press resolves against at most 64 instant candidates followed
    /// by 512 bucket candidates. It leaves the retained viewport/cache intact.
    pub fn viewer_resolve_density(
        &self,
        request: &DensityResolutionRequest,
        budget: &EngineBudget,
    ) -> Result<Option<DetailInput>, EngineError> {
        self.query_reader(budget)?;
        let mut repository = SessionQueries {
            session: self,
            budget,
        };
        let result =
            arktrace_viewer::resolve_density_event(request, &mut repository, &mut || check(budget))
                .map_err(execution_error);
        self.query_reader(budget)?;
        result
    }
    fn viewer_focused_details(
        &self,
        source: &TraceDensitySource,
        range: TraceTimeRange,
        limit: usize,
        focused: Option<EventKey>,
        budget: &EngineBudget,
    ) -> Result<EventPage<DetailInput>, EngineError> {
        let page = self.viewer_details(source, range, limit, budget)?;
        let focus = match (source, focused) {
            (TraceDensitySource::NamedSlice { .. }, Some(key))
                if key.table == EventTable::Callstack =>
            {
                let RepositoryDetailQuery::NamedSlice(mut query) =
                    arktrace_viewer::detail_query(source, range, 1).map_err(viewer_error)?
                else {
                    unreachable!()
                };
                query.event_key = Some(key);
                let raw = self.slices(&query, budget)?;
                arktrace_viewer::map_detail_page(
                    source,
                    range,
                    1,
                    RepositoryDetailPage::NamedSlice(raw),
                    &mut || check(budget),
                )
                .map_err(viewer_error)?
                .items
                .into_iter()
                .next()
            }
            _ => None,
        };
        arktrace_viewer::include_focused_detail(page, focus, limit).map_err(viewer_error)
    }
}
struct SessionQueries<'a> {
    session: &'a NoCacheSession,
    budget: &'a EngineBudget,
}
impl ViewportQueries for SessionQueries<'_> {
    type Error = EngineError;
    fn density_batch(
        &mut self,
        queries: &[TraceDensityQuery],
    ) -> Result<Vec<TraceDensityResult>, EngineError> {
        self.session
            .event_batch(
                &arktrace_contract::TraceRepositoryEventBatch {
                    densities: queries.to_vec(),
                    ..Default::default()
                },
                self.budget,
                ReadPoolLimits::default(),
            )
            .map(|b| b.result.densities)
    }
    fn density(&mut self, query: &TraceDensityQuery) -> Result<TraceDensityResult, EngineError> {
        self.session.density(query, self.budget)
    }
    fn details(
        &mut self,
        source: &TraceDensitySource,
        range: TraceTimeRange,
        limit: usize,
        focused: Option<EventKey>,
    ) -> Result<EventPage<DetailInput>, EngineError> {
        self.session
            .viewer_focused_details(source, range, limit, focused, self.budget)
    }
}
fn check(budget: &EngineBudget) -> Result<(), arktrace_viewer::ViewerError> {
    budget.check().map_err(|e| match e.failure {
        EngineFailure::Host(HostError::Cancelled) => arktrace_viewer::ViewerError::Cancelled,
        EngineFailure::Host(HostError::DeadlineExceeded) => {
            arktrace_viewer::ViewerError::DeadlineReached
        }
        _ => arktrace_viewer::ViewerError::InvalidRequest,
    })
}
fn execution_error(error: ViewportFailure<EngineError>) -> EngineError {
    match error {
        ViewportFailure::Repository(e) => e,
        ViewportFailure::Viewer(e) => viewer_error(e),
    }
}
