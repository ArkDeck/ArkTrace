//! Swift `TraceDeterministicAnalysisEngine` / `TraceContextBuilder` rules that
//! the real-trace oracle cannot reach on its own: row-retention priority,
//! the scheduling capability gate, long-slice order, candidate ranking,
//! referential closure, probe budgets and byte-bounded retention.
use arktrace_analysis::*;
use arktrace_contract::*;

fn quality() -> DataQuality {
    DataQuality::machine(QualityStatus::Ok, Vec::new()).unwrap()
}
fn page<T>(items: Vec<T>) -> EventPage<T> {
    EventPage {
        items,
        truncated: false,
        capability_available: true,
        data_quality: quality(),
    }
}
fn range(start: i64, end: i64) -> TraceTimeRange {
    TraceTimeRange::event(start, end).unwrap()
}
fn cpu(row: i64, cpu: i64, start: i64, end: i64, ipid: i64, itid: i64) -> CpuSlice {
    CpuSlice {
        key: EventKey {
            table: EventTable::SchedSlice,
            row_id: row,
        },
        range: range(start, end),
        cpu,
        thread_key: Some(ThreadKey { itid }),
        process_key: Some(ProcessKey { ipid }),
        tid: Some(itid + 100),
        pid: Some(ipid + 100),
        thread_name: None,
        process_name: None,
        end_state: None,
        priority: None,
        is_open_ended: false,
    }
}
fn state(
    row: i64,
    start: i64,
    end: i64,
    itid: i64,
    normalized: TraceThreadState,
) -> ThreadStateInterval {
    ThreadStateInterval {
        key: EventKey {
            table: EventTable::ThreadState,
            row_id: row,
        },
        range: range(start, end),
        thread_key: ThreadKey { itid },
        process_key: Some(ProcessKey { ipid: 1 }),
        state: "R".into(),
        normalized_state: Some(normalized),
        cpu: None,
        tid: Some(itid + 100),
        pid: Some(101),
        process_name: None,
        thread_name: None,
        is_open_ended: false,
    }
}
fn slice(row: i64, start: i64, end: i64, itid: Option<i64>) -> TraceSlice {
    TraceSlice {
        key: EventKey {
            table: EventTable::Callstack,
            row_id: row,
        },
        range: range(start, end),
        thread_key: itid.map(|itid| ThreadKey { itid }),
        process_key: None,
        pid: None,
        tid: None,
        process_name: None,
        thread_name: None,
        name: format!("s{row}"),
        category: None,
        depth: Some(0),
        parent_event_key: None,
        is_async: false,
        is_open_ended: false,
        arg_set_id: None,
    }
}
fn checker() -> impl FnMut() -> Result<(), AnalysisError> {
    || Ok(())
}

fn analysis(
    cpus: Vec<CpuSlice>,
    named: Vec<TraceSlice>,
    capable: bool,
    limit: usize,
) -> DeterministicAnalysis {
    let request = DeterministicRequest::cli(
        TraceTimeRange::query(0, 1_000).unwrap(),
        IdentityFilters::default(),
        100,
        limit,
        0,
        1_000,
    );
    let cpu = page(cpus);
    let states = page(vec![state(1, 0, 10, 7, TraceThreadState::Runnable)]);
    let runnable = page(vec![state(1, 0, 10, 7, TraceThreadState::Runnable)]);
    let named = page(named);
    deterministic_analysis(
        &request,
        DeterministicInput {
            cpu: &cpu,
            processes: &cpu,
            threads: &cpu,
            states: &states,
            named: &named,
            scheduling_cpu: &cpu,
            scheduling_states: &runnable,
            hot_cpu: &cpu,
            hot_named: &named,
            scheduling_capable: capable,
            trace_quality: &[],
        },
        &mut checker(),
    )
    .unwrap()
}

#[test]
fn scheduling_requires_both_trace_capabilities_and_proves_exact_boundaries() {
    let cpus = vec![cpu(1, 0, 10, 20, 1, 7)];
    let proven = analysis(cpus.clone(), Vec::new(), true, 10);
    assert!(proven.scheduling_latency.supported);
    assert_eq!(proven.scheduling_latency.count, 1);
    assert_eq!(proven.scheduling_latency.top_samples[0].latency_ns, 10);
    let gated = analysis(cpus, Vec::new(), false, 10);
    assert!(!gated.scheduling_latency.supported);
    assert_eq!(
        gated.scheduling_latency.unsupported_reason,
        Some(SchedulingUnsupportedReason::CapabilityUnavailable)
    );
    assert!(!gated.scheduling_latency.truncated);
}

#[test]
fn long_slices_order_by_duration_then_event_key_and_report_matched_candidates() {
    let named = vec![
        slice(9, 0, 50, None),
        slice(3, 0, 80, None),
        slice(4, 10, 90, None),
        slice(5, 0, 10, None),
    ];
    let value = analysis(Vec::new(), named, true, 2);
    let rows: Vec<i64> = value.long_slices.iter().map(|v| v.key.row_id).collect();
    assert_eq!(rows, vec![3, 4]);
    assert_eq!(value.sections.long_slices.matched_count, Some(4));
    assert!(value.sections.long_slices.truncated);
    assert_eq!(
        serde_json::to_value(&value.parameters).unwrap()["filters"]["nameMatch"],
        "exact"
    );
}

#[test]
fn global_row_retention_follows_the_seven_section_priority() {
    let cpus = vec![
        cpu(1, 0, 0, 100, 1, 7),
        cpu(2, 1, 0, 100, 2, 8),
        cpu(3, 2, 0, 100, 3, 9),
    ];
    let named = vec![slice(4, 0, 30, None)];
    let mut value = analysis(cpus, named, true, 10);
    assert_eq!(value.cpu_utilization.len(), 3);
    assert_eq!(value.top_processes.len(), 3);
    value.retain_rows(4);
    assert_eq!(value.cpu_utilization.len(), 3);
    assert_eq!(value.top_processes.len(), 1);
    assert!(value.top_threads.is_empty() && value.long_slices.is_empty());
    assert!(value.hot_intervals.is_empty());
    assert!(value.sections.top_processes.truncated);
    assert!(!value.sections.cpu_utilization.truncated);
    assert_eq!(value.sections.top_threads.returned_count, 0);
    assert_eq!(
        value.sections.truncated_names(),
        vec![
            "topProcesses",
            "topThreads",
            "longSlices",
            "threadStateDistribution",
            "hotIntervals"
        ]
    );
}

struct Directory {
    probes: Vec<(char, i64)>,
}
impl ContextDirectory for Directory {
    fn process(&mut self, key: i64) -> Result<Option<TraceProcess>, AnalysisError> {
        self.probes.push(('p', key));
        Ok((key != 404).then_some(TraceProcess {
            key,
            pid: key + 100,
            name: None,
            start_ns: None,
            end_ns: None,
            thread_count: None,
        }))
    }
    fn thread(&mut self, key: i64) -> Result<Option<TraceThread>, AnalysisError> {
        self.probes.push(('t', key));
        Ok(Some(TraceThread {
            key,
            process_key: Some(1),
            tid: key + 100,
            pid: Some(101),
            name: None,
            process_name: None,
            start_ns: None,
            end_ns: None,
            is_main_thread: None,
        }))
    }
}
fn loaded<'a>(
    filters: &'a AgentFilters,
    center: Option<i64>,
    summary: &'a serde_json::Value,
) -> ContextLoaded<'a, serde_json::Value> {
    ContextLoaded {
        range: TraceTimeRange::query(0, 1_000).unwrap(),
        center,
        filters,
        processes: DirectoryPage {
            items: Vec::new(),
            truncated: false,
            data_quality_issues: Vec::new(),
        },
        threads: DirectoryPage {
            items: Vec::new(),
            truncated: false,
            data_quality_issues: Vec::new(),
        },
        cpu: page(vec![cpu(1, 0, 400, 410, 404, 7), cpu(2, 0, 0, 900, 1, 8)]),
        states: page(Vec::new()),
        slices: page(vec![slice(3, 495, 505, Some(9))]),
        counters: page(Vec::new()),
        summary,
        summary_quality: &[],
        summary_truncated: false,
    }
}
fn bytes(
    document: &ContextDocument<'_, serde_json::Value>,
    _: usize,
) -> Result<usize, AnalysisError> {
    Ok(serde_json::to_vec(document).unwrap().len())
}

#[test]
fn context_ranks_by_center_distance_and_closes_thread_processes() {
    let filters = AgentFilters::default();
    let summary = serde_json::json!({"s": 1});
    let value = loaded(&filters, Some(500), &summary);
    let mut directory = Directory { probes: Vec::new() };
    let prepared = prepare_context(&value, 10, &mut directory, &mut checker()).unwrap();
    // Candidate order: slice 3 (distance 0), cpu 2 (distance 50), cpu 1 (95);
    // entities keep that order (thread 9, process 1, thread 8, process 404,
    // thread 7) and a probed thread's process is already scheduled.
    assert_eq!(
        directory.probes,
        vec![('t', 9), ('p', 1), ('t', 8), ('p', 404), ('t', 7)]
    );
    let mut measure = bytes;
    let document = retain_context(&prepared, 2, 10, 1 << 20, &mut measure, &mut checker()).unwrap();
    assert_eq!(document.slices.len(), 1);
    assert_eq!(document.cpu_slices[0].key.row_id, 2);
    assert_eq!(document.cpu_slices.len(), 1);
    assert!(document.truncation.cpu_slices.truncated);
    // Missing process 404 is a referential warning without a message.
    assert!(
        document
            .data_quality
            .warnings
            .iter()
            .any(|w| w.category == QualityCategory::ReferentialIntegrity && w.count == Some(1))
    );
    assert!(
        document
            .data_quality
            .warnings
            .iter()
            .all(|w| w.message.is_none())
    );
    assert_eq!(document.threads.len(), 2);
    assert_eq!(document.processes.len(), 1);
}

#[test]
fn probe_budget_and_byte_budget_shrink_retention_deterministically() {
    let filters = AgentFilters::default();
    let summary = serde_json::json!({"s": 1});
    let value = loaded(&filters, None, &summary);
    let mut directory = Directory { probes: Vec::new() };
    let prepared = prepare_context(&value, 1, &mut directory, &mut checker()).unwrap();
    assert_eq!(directory.probes.len(), 1);
    let mut measure = bytes;
    let full = retain_context(&prepared, 10, 10, 1 << 20, &mut measure, &mut checker()).unwrap();
    assert!(full.truncation.reference_omitted_by_budget);
    assert!(full.truncation.truncated_names().contains(&"references"));
    assert!(
        full.data_quality
            .warnings
            .iter()
            .any(|w| w.category == QualityCategory::ProbeTruncated)
    );
    let full_bytes = serde_json::to_vec(&full).unwrap().len();
    let fewer = retain_context(
        &prepared,
        10,
        10,
        full_bytes - 1,
        &mut measure,
        &mut checker(),
    )
    .unwrap();
    assert!(fewer.event_count() < full.event_count());
    assert!(serde_json::to_vec(&fewer).unwrap().len() < full_bytes);
    let none = retain_context(&prepared, 10, 10, 64, &mut measure, &mut checker());
    assert!(matches!(
        none,
        Err(ContextError::OutputLimitExceeded { maximum: 64, .. })
    ));
}

#[test]
fn context_time_and_filters_follow_swift_request_validation() {
    assert!(
        ContextTime::Timestamp {
            timestamp_ns: 5,
            window_before_ns: 0,
            window_after_ns: 0
        }
        .validate()
        .is_err()
    );
    let window = ContextTime::Timestamp {
        timestamp_ns: 30,
        window_before_ns: 50,
        window_after_ns: 50,
    };
    assert_eq!(window.normalized(60).unwrap(), (range(0, 60), Some(30)));
    assert!(window.normalized(20).is_err());
    let mut filters = AgentFilters {
        name_match: DirectoryNameMatch::Prefix,
        ..AgentFilters::default()
    };
    assert!(filters.validate().is_err());
    filters.name = Some("x".into());
    assert!(filters.validate().is_ok());
    filters.process_key = Some(0);
    assert!(filters.validate().is_err());
}
