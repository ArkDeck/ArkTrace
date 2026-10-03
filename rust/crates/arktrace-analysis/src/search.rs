//! Search composition over typed, bounded sources; no SQL or filesystem IO.
use crate::{AnalysisError, Check, checked_sort, checkpoint};
use arktrace_contract::{
    DirectoryNameMatch, DirectoryPage, EventPage, ProcessKey, ProcessQuery, SearchDomains,
    ThreadKey, ThreadQuery, TraceProcess, TraceSearchRequest, TraceSearchResult,
    TraceSearchResultKind, TraceSearchResults, TraceSlice, TraceSliceQuery, TraceThread,
    TraceTimeRange,
};
use std::collections::BTreeSet;

pub trait SearchRepository {
    type Error;
    fn duration_ns(&self) -> Result<i64, Self::Error>;
    fn processes(&self, query: &ProcessQuery) -> Result<DirectoryPage<TraceProcess>, Self::Error>;
    fn threads(&self, query: &ThreadQuery) -> Result<DirectoryPage<TraceThread>, Self::Error>;
    fn slices(&self, query: &TraceSliceQuery) -> Result<EventPage<TraceSlice>, Self::Error>;
}
#[derive(Debug, PartialEq)]
pub enum SearchError<E> {
    Analysis(AnalysisError),
    Repository(E),
}
impl<E> From<AnalysisError> for SearchError<E> {
    fn from(value: AnalysisError) -> Self {
        Self::Analysis(value)
    }
}

fn bounded<T, E>(page: DirectoryPage<T>, limit: usize) -> Result<DirectoryPage<T>, SearchError<E>> {
    if page.items.len() > limit {
        return Err(AnalysisError::InputBudgetExceeded.into());
    }
    Ok(page)
}
fn merged<T, E>(
    lhs: DirectoryPage<T>,
    rhs: DirectoryPage<T>,
    key: impl Fn(&T) -> i64,
    check: &mut Check<'_>,
) -> Result<DirectoryPage<T>, SearchError<E>> {
    let mut seen = BTreeSet::new();
    let mut items = Vec::new();
    for (index, value) in lhs.items.into_iter().chain(rhs.items).enumerate() {
        checkpoint(index, check)?;
        if seen.insert(key(&value)) {
            items.push(value);
        }
    }
    // Search results have no quality field in Swift. Source quality remains
    // with the source pages and is not reinterpreted as result completeness.
    Ok(DirectoryPage {
        items,
        truncated: lhs.truncated || rhs.truncated,
        data_quality_issues: Vec::new(),
    })
}
fn lifecycle(start: Option<i64>, end: Option<i64>) -> Option<TraceTimeRange> {
    start.and_then(|s| TraceTimeRange::event(s, end.unwrap_or(s).max(s)).ok())
}
fn prefixed_identity(text: &str, prefix: &str) -> Option<i64> {
    // Foundation CharacterSet.whitespacesAndNewlines also includes U+200B.
    let text = text.trim_matches(|c: char| c.is_whitespace() || c == '\u{200b}');
    text.get(..prefix.len())
        .filter(|head| head.eq_ignore_ascii_case(prefix))?;
    text.get(prefix.len()..)?.parse().ok()
}

pub fn search<R: SearchRepository>(
    repository: &R,
    request: &TraceSearchRequest,
    check: &mut Check<'_>,
) -> Result<TraceSearchResults, SearchError<R::Error>> {
    request
        .validate()
        .map_err(|_| AnalysisError::InvalidBounds)?;
    check()?;
    let duration = repository.duration_ns().map_err(SearchError::Repository)?;
    check()?;
    let limit = request.limit + 1;
    let processes = request.domains.contains(SearchDomains::PROCESS);
    let threads = request.domains.contains(SearchDomains::THREAD);
    let mut process_page = DirectoryPage {
        items: Vec::new(),
        truncated: false,
        data_quality_issues: Vec::new(),
    };
    let mut thread_page = DirectoryPage {
        items: Vec::new(),
        truncated: false,
        data_quality_issues: Vec::new(),
    };
    let process_query = ProcessQuery {
        process_key: None,
        pid: None,
        name: None,
        name_match: DirectoryNameMatch::Exact,
        limit,
    };
    let thread_query = ThreadQuery {
        process_key: None,
        pid: None,
        thread_key: None,
        tid: None,
        name: None,
        name_match: DirectoryNameMatch::Exact,
        limit,
    };
    if processes {
        process_page = bounded(
            repository
                .processes(&ProcessQuery {
                    name: Some(request.text.clone()),
                    name_match: DirectoryNameMatch::Contains,
                    ..process_query.clone()
                })
                .map_err(SearchError::Repository)?,
            limit,
        )?;
    }
    if threads {
        thread_page = bounded(
            repository
                .threads(&ThreadQuery {
                    name: Some(request.text.clone()),
                    name_match: DirectoryNameMatch::Contains,
                    ..thread_query.clone()
                })
                .map_err(SearchError::Repository)?,
            limit,
        )?;
    }
    if let Ok(numeric) = request.text.parse::<i64>() {
        if processes {
            let rhs = bounded(
                repository
                    .processes(&ProcessQuery {
                        pid: Some(numeric),
                        ..process_query.clone()
                    })
                    .map_err(SearchError::Repository)?,
                limit,
            )?;
            process_page = merged(process_page, rhs, |v| v.key, check)?;
        }
        if threads {
            let rhs = bounded(
                repository
                    .threads(&ThreadQuery {
                        tid: Some(numeric),
                        ..thread_query.clone()
                    })
                    .map_err(SearchError::Repository)?,
                limit,
            )?;
            thread_page = merged(thread_page, rhs, |v| v.key, check)?;
        }
    }
    if processes && let Some(key) = prefixed_identity(&request.text, "ipid:") {
        let rhs = bounded(
            repository
                .processes(&ProcessQuery {
                    process_key: Some(key),
                    ..process_query
                })
                .map_err(SearchError::Repository)?,
            limit,
        )?;
        process_page = merged(process_page, rhs, |v| v.key, check)?;
    }
    if threads && let Some(key) = prefixed_identity(&request.text, "itid:") {
        let rhs = bounded(
            repository
                .threads(&ThreadQuery {
                    thread_key: Some(key),
                    ..thread_query
                })
                .map_err(SearchError::Repository)?,
            limit,
        )?;
        thread_page = merged(thread_page, rhs, |v| v.key, check)?;
    }
    // Swift validates this full range even when slices are excluded.
    let range = TraceTimeRange::query(0, duration).map_err(|_| AnalysisError::InvalidBounds)?;
    let slice_page = if request.domains.contains(SearchDomains::SLICE) {
        let page = repository
            .slices(&TraceSliceQuery {
                range,
                event_key: None,
                process_key: None,
                pid: None,
                thread_key: None,
                tid: None,
                name: Some(request.text.clone()),
                name_match: DirectoryNameMatch::Contains,
                minimum_duration_ns: None,
                depth: None,
                unattributed_only: false,
                includes_argument_set: false,
                limit,
            })
            .map_err(SearchError::Repository)?;
        if page.items.len() > limit {
            return Err(AnalysisError::InputBudgetExceeded.into());
        }
        if !page.capability_available && (!page.items.is_empty() || page.truncated) {
            return Err(AnalysisError::InvalidEvidence.into());
        }
        page
    } else {
        EventPage {
            items: Vec::new(),
            truncated: false,
            capability_available: true,
            data_quality: arktrace_contract::DataQuality::machine(
                arktrace_contract::QualityStatus::Ok,
                Vec::new(),
            )
            .map_err(AnalysisError::from)?,
        }
    };
    check()?;
    let truncated = process_page.truncated || thread_page.truncated || slice_page.truncated;
    let mut items = Vec::new();
    for (index, p) in process_page.items.into_iter().enumerate() {
        checkpoint(index, check)?;
        items.push(TraceSearchResult {
            kind: TraceSearchResultKind::Process,
            title: p.name.unwrap_or_else(|| format!("PID {}", p.pid)),
            subtitle: Some(format!("PID {} · ipid {}", p.pid, p.key)),
            process_key: Some(ProcessKey { ipid: p.key }),
            thread_key: None,
            event_key: None,
            range: lifecycle(p.start_ns, p.end_ns),
        });
    }
    for (index, t) in thread_page.items.into_iter().enumerate() {
        checkpoint(index, check)?;
        items.push(TraceSearchResult {
            kind: TraceSearchResultKind::Thread,
            title: t.name.unwrap_or_else(|| format!("TID {}", t.tid)),
            subtitle: Some(format!("TID {} · itid {}", t.tid, t.key)),
            process_key: t.process_key.map(|ipid| ProcessKey { ipid }),
            thread_key: Some(ThreadKey { itid: t.key }),
            event_key: None,
            range: lifecycle(t.start_ns, t.end_ns),
        });
    }
    for (index, s) in slice_page.items.into_iter().enumerate() {
        checkpoint(index, check)?;
        items.push(TraceSearchResult {
            kind: TraceSearchResultKind::Slice,
            title: s.name,
            subtitle: s.category,
            process_key: s.process_key,
            thread_key: s.thread_key,
            event_key: Some(s.key),
            range: Some(s.range),
        });
    }
    checked_sort(
        &mut items,
        |a, b| {
            (
                a.kind,
                a.title.as_bytes(),
                a.process_key.map(|k| k.ipid),
                a.thread_key.map(|k| k.itid),
                a.event_key.map(|k| k.row_id),
            )
                .cmp(&(
                    b.kind,
                    b.title.as_bytes(),
                    b.process_key.map(|k| k.ipid),
                    b.thread_key.map(|k| k.itid),
                    b.event_key.map(|k| k.row_id),
                ))
        },
        check,
    )?;
    let truncated = truncated || items.len() > request.limit;
    items.truncate(request.limit);
    check()?;
    Ok(TraceSearchResults { items, truncated })
}

#[cfg(test)]
mod tests;
