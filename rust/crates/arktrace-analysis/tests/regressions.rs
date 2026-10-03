use arktrace_analysis::*;
use arktrace_contract::*;

fn range(a: i64, b: i64) -> TraceTimeRange {
    TraceTimeRange::event(a, b).unwrap()
}
fn quality() -> DataQuality {
    DataQuality::machine(QualityStatus::Ok, vec![]).unwrap()
}
fn page<T>(items: Vec<T>) -> EventPage<T> {
    EventPage {
        items,
        truncated: false,
        capability_available: true,
        data_quality: quality(),
    }
}
fn cpu(id: i64, a: i64, b: i64, ipid: i64, itid: i64) -> CpuSlice {
    CpuSlice {
        key: EventKey {
            table: EventTable::SchedSlice,
            row_id: id,
        },
        range: range(a, b),
        cpu: 0,
        process_key: Some(ProcessKey { ipid }),
        thread_key: Some(ThreadKey { itid }),
        pid: Some(42),
        tid: Some(7),
        thread_name: None,
        process_name: None,
        end_state: None,
        priority: None,
        is_open_ended: false,
    }
}
fn state(id: i64, a: i64, b: i64, itid: i64) -> ThreadStateInterval {
    ThreadStateInterval {
        key: EventKey {
            table: EventTable::ThreadState,
            row_id: id,
        },
        range: range(a, b),
        thread_key: ThreadKey { itid },
        process_key: Some(ProcessKey { ipid: 1 }),
        state: "R".into(),
        normalized_state: Some(TraceThreadState::Runnable),
        cpu: None,
        tid: Some(7),
        pid: Some(42),
        process_name: None,
        thread_name: None,
        is_open_ended: false,
    }
}
fn input<'a>(
    cpu: &'a EventPage<CpuSlice>,
    states: &'a EventPage<ThreadStateInterval>,
    q: &'a DataQuality,
) -> AnalysisInput<'a> {
    AnalysisInput {
        cpu,
        processes: cpu,
        threads: cpu,
        states,
        scheduling_cpu: cpu,
        scheduling_states: states,
        runnable_semantics: RunnableSemantics::ProvenNormalizedIntervals,
        hot_cpu: cpu,
        hot_named: None,
        named_slices_available: false,
        trace_quality: q,
    }
}

#[test]
fn clipping_overlaps_instants_and_reused_os_identities() {
    let rows = [
        cpu(1, 0, 150, 1, 11),
        cpu(2, 50, 200, 2, 12),
        cpu(3, 120, 120, 2, 12),
    ];
    let cpu_rows = cpu_utilization(&rows, range(100, 200), &mut || Ok(())).unwrap();
    assert_eq!(cpu_rows[0].raw_running_ns, 150);
    assert_eq!(cpu_rows[0].occupied_ns, 100);
    assert_eq!(cpu_rows[0].utilization, 1.0);
    assert_eq!(cpu_rows[0].slice_count, 3);
    let processes = top_processes(&rows, range(100, 200), 10, &mut || Ok(())).unwrap();
    assert_eq!(
        processes
            .items
            .iter()
            .map(|r| (r.process_key.ipid, r.running_ns, r.slice_count))
            .collect::<Vec<_>>(),
        [(2, 100, 2), (1, 50, 1)]
    );
    let threads = top_threads(&rows, range(100, 200), 10, &mut || Ok(())).unwrap();
    assert_eq!(
        threads
            .items
            .iter()
            .map(|r| r.thread_key.itid)
            .collect::<Vec<_>>(),
        [12, 11]
    );
}
#[test]
fn null_identity_is_counted_on_cpu_without_inventing_process_or_thread() {
    let mut row = cpu(1, 0, 100, 1, 11);
    row.process_key = None;
    row.thread_key = None;
    let rows = [row];
    assert_eq!(
        cpu_utilization(&rows, range(0, 100), &mut || Ok(())).unwrap()[0].slice_count,
        1
    );
    assert!(
        top_processes(&rows, range(0, 100), 10, &mut || Ok(()))
            .unwrap()
            .items
            .is_empty()
    );
    assert!(
        top_threads(&rows, range(0, 100), 10, &mut || Ok(()))
            .unwrap()
            .items
            .is_empty()
    );
}
#[test]
fn canonical_state_grouping_obeys_the_store_utf8_byte_budget() {
    let mut interval = state(1, 0, 30, 11);
    interval.state = "é".repeat(128);
    interval.normalized_state = None;
    assert_eq!(
        state_distribution(&[interval.clone()], range(0, 100), &mut || Ok(())).unwrap()[0]
            .raw_state,
        interval.state
    );
    interval.state.push('a');
    assert_eq!(
        state_distribution(&[interval], range(0, 100), &mut || Ok(())).unwrap_err(),
        AnalysisError::InvalidEvidence
    );
}
#[test]
fn tie_ranking_and_first_nonnull_metadata_follow_actual_page_order() {
    let mut a = cpu(1, 0, 100, 2, 12);
    a.thread_name = None;
    let mut b = cpu(2, 100, 200, 2, 12);
    b.thread_name = Some("worker".into());
    let c = cpu(3, 0, 200, 1, 11);
    let rows = top_threads(&[a, b, c], range(0, 200), 10, &mut || Ok(())).unwrap();
    assert_eq!(
        rows.items
            .iter()
            .map(|r| r.thread_key.itid)
            .collect::<Vec<_>>(),
        [11, 12]
    );
    assert_eq!(rows.items[1].name.as_deref(), Some("worker"));
}
#[test]
fn unknown_states_and_nullable_metadata_remain_distinct_and_ordered() {
    let mut a = state(1, 0, 30, 11);
    a.state = "未知".into();
    a.normalized_state = None;
    a.process_key = None;
    let mut b = a.clone();
    b.key.row_id = 2;
    b.process_key = Some(ProcessKey { ipid: 1 });
    let rows = state_distribution(&[b, a], range(0, 100), &mut || Ok(())).unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].process_key, None);
    assert_eq!(rows[0].raw_state, "未知");
    assert_eq!(rows[0].percentage_of_range, 0.3);
    assert_eq!(rows[0].normalized_state, None);
}
#[test]
fn saturated_nanoseconds_keep_raw_overlap_warning_and_finite_fractions() {
    let cpus = page(vec![cpu(1, 0, i64::MAX, 1, 11), cpu(2, 0, i64::MAX, 1, 11)]);
    let states = page(vec![state(1, 0, i64::MAX, 11), state(2, 0, i64::MAX, 11)]);
    let mut request = AnalysisRequest::new(range(0, i64::MAX));
    request.hot_bucket_count = 1;
    let value = analyze(&request, input(&cpus, &states, &quality()), &mut || Ok(())).unwrap();
    assert_eq!(value.cpu_utilization[0].raw_running_ns, i64::MAX);
    assert_eq!(value.thread_state_distribution[0].duration_ns, i64::MAX);
    assert_eq!(value.hot_intervals[0].score.total, i64::MAX);
    assert!(value.cpu_utilization[0].utilization.is_finite());
    // Swift compares the saturated raw value to the range duration, so no
    // overlap warning is detectable when both are MAX (documented parity).
    assert!(value.data_quality.warnings.is_empty());
}
#[test]
fn deadline_and_cancellation_are_checked_during_bounded_reductions() {
    let rows: Vec<_> = (0..1024).map(|i| cpu(i, 0, 100, 1, 11)).collect();
    let mut checks = 0;
    let result = cpu_utilization(&rows, range(0, 100), &mut || {
        checks += 1;
        if checks == 3 {
            Err(AnalysisError::Cancelled)
        } else {
            Ok(())
        }
    });
    assert_eq!(result, Err(AnalysisError::Cancelled));
    assert_eq!(checks, 3);
    assert_eq!(
        hot_intervals(&[], &[], range(0, 100), 10, 0, &mut || Err(
            AnalysisError::DeadlineReached
        )),
        Err(AnalysisError::DeadlineReached)
    );
}
#[test]
fn independent_sections_and_global_trims_do_not_change_sampling_facts() {
    let cpus = page(vec![cpu(1, 0, 50, 1, 11), cpu(2, 50, 100, 2, 12)]);
    let mut sampled = page(vec![cpus.items[0].clone()]);
    sampled.truncated = true;
    let states = page(vec![]);
    let mut request = AnalysisRequest::new(range(0, 100));
    request.maximum_cpu_slices = 1;
    request.maximum_output_rows = 2;
    let q = quality();
    let mut inputs = input(&cpus, &states, &q);
    inputs.cpu = &sampled;
    let value = analyze(&request, inputs, &mut || Ok(())).unwrap();
    assert_eq!(value.cpu_utilization[0].raw_running_ns, 50);
    assert!(value.sections.cpu_utilization.sampled);
    assert_eq!(value.sections.cpu_utilization.matched_count, None);
    assert_eq!(value.top_processes.len(), 1);
    assert_eq!(value.sections.top_processes.matched_count, Some(2));
    assert!(value.sections.top_processes.truncated);
    assert!(!value.sections.top_processes.sampled);
    assert!(value.top_threads.is_empty());
    assert!(value.sections.top_threads.truncated);
}
#[test]
fn invalid_bounds_oversized_pages_and_outside_evidence_are_rejected() {
    assert_eq!(
        cpu_utilization(&[], range(0, 0), &mut || Ok(())),
        Err(AnalysisError::InvalidBounds)
    );
    let cpus = page(vec![cpu(1, 0, 100, 1, 11), cpu(2, 100, 100, 2, 12)]);
    let states = page(vec![]);
    let q = quality();
    let request = AnalysisRequest::new(range(0, 100));
    assert_eq!(
        analyze(&request, input(&cpus, &states, &q), &mut || Ok(())).unwrap_err(),
        AnalysisError::InvalidEvidence
    );
    let mut request = request;
    request.maximum_cpu_slices = 1;
    assert_eq!(
        analyze(&request, input(&cpus, &states, &q), &mut || Ok(())).unwrap_err(),
        AnalysisError::InputBudgetExceeded
    );
    let mut unavailable = page(vec![cpu(1, 0, 50, 1, 11)]);
    unavailable.capability_available = false;
    assert_eq!(
        analyze(
            &AnalysisRequest::new(range(0, 100)),
            input(&unavailable, &states, &q),
            &mut || Ok(())
        )
        .unwrap_err(),
        AnalysisError::InvalidEvidence
    );
}
#[test]
fn missing_named_input_is_explicit_without_fabricating_complete_hot_scores() {
    let cpus = page(vec![cpu(1, 0, 100, 1, 11)]);
    let states = page(vec![]);
    let q = quality();
    let mut inputs = input(&cpus, &states, &q);
    inputs.named_slices_available = true;
    let value = analyze(&AnalysisRequest::new(range(0, 100)), inputs, &mut || Ok(())).unwrap();
    assert_eq!(
        value.hot_intervals_unsupported_reason.as_deref(),
        Some("namedSliceInputMissing")
    );
    assert!(value.hot_intervals.is_empty());
    assert!(!value.sections.hot_intervals.supported);
    assert_eq!(value.sections.hot_intervals.matched_count, None);
}
#[test]
fn safe_quality_preserves_structured_warnings_and_drops_path_messages() {
    let mut cpus = page(vec![cpu(1, 0, 100, 1, 11), cpu(2, 0, 100, 2, 12)]);
    cpus.data_quality = DataQuality {
        status: QualityStatus::Warnings,
        warnings: vec![QualityIssue {
            category: QualityCategory::DroppedValue,
            scope: Some("sched_slice.cpu".into()),
            count: Some(2),
            message: Some("/Users/private/trace".into()),
        }],
    };
    let states = page(vec![]);
    let result = analyze(
        &AnalysisRequest::new(range(0, 100)),
        input(&cpus, &states, &quality()),
        &mut || Ok(()),
    )
    .unwrap();
    let json = serde_json::to_string(&result).unwrap();
    assert!(!json.contains("/Users/private"));
    assert!(
        result
            .data_quality
            .warnings
            .iter()
            .all(|w| w.message.is_none())
    );
    assert_eq!(result.data_quality.warnings.len(), 2);
    assert!(
        result
            .data_quality
            .warnings
            .iter()
            .any(|w| w.count == Some(2))
    );
    assert!(
        result
            .data_quality
            .warnings
            .iter()
            .any(|w| w.scope.as_deref() == Some("sched_slice.overlap"))
    );
}
#[test]
fn unknown_scope_category_negative_count_and_status_mismatch_remain_rejected() {
    let states = page(vec![]);
    let q = quality();
    for issue in [
        QualityIssue {
            category: QualityCategory::DroppedValue,
            scope: Some("/not/a/scope".into()),
            count: None,
            message: None,
        },
        QualityIssue {
            category: QualityCategory::Unclassified,
            scope: None,
            count: None,
            message: Some("harmless".into()),
        },
        QualityIssue {
            category: QualityCategory::DroppedValue,
            scope: None,
            count: Some(-1),
            message: None,
        },
    ] {
        let mut cpus = page(vec![]);
        cpus.data_quality = DataQuality {
            status: QualityStatus::Warnings,
            warnings: vec![issue],
        };
        assert_eq!(
            analyze(
                &AnalysisRequest::new(range(0, 100)),
                input(&cpus, &states, &q),
                &mut || Ok(())
            )
            .unwrap_err(),
            AnalysisError::Quality(ContractError::DataQualityNotMachineSafe)
        );
    }
    let mut cpus = page(vec![]);
    cpus.data_quality.status = QualityStatus::Warnings;
    assert_eq!(
        analyze(
            &AnalysisRequest::new(range(0, 100)),
            input(&cpus, &states, &q),
            &mut || Ok(())
        )
        .unwrap_err(),
        AnalysisError::Quality(ContractError::DataQualityStatusMismatch)
    );
    assert!(serde_json::from_str::<QualityCategory>("\"unknown\"").is_err());
}
#[test]
fn scheduling_requires_semantics_identity_observed_end_and_exact_boundary() {
    let cpus = page(vec![
        cpu(9, 100, 200, 1, 11),
        cpu(2, 100, 150, 1, 11),
        cpu(3, 300, 400, 1, 12),
    ]);
    let mut unknown = state(3, 200, 300, 12);
    unknown.normalized_state = None;
    let mut open = state(4, 0, 100, 11);
    open.is_open_ended = true;
    let states = page(vec![
        state(1, 50, 100, 11),
        state(2, 200, 300, 13),
        unknown,
        open,
        state(5, 0, 99, 11),
    ]);
    let value = scheduling_latency(
        &cpus,
        &states,
        RunnableSemantics::ProvenNormalizedIntervals,
        10,
        &mut || Ok(()),
    )
    .unwrap();
    assert_eq!(value.count, 1);
    assert_eq!(value.top_samples[0].running_event_key.row_id, 2);
    assert_eq!(value.percentiles.unwrap().p50_ns, 50);
    let unproven = scheduling_latency(&cpus, &states, RunnableSemantics::Unproven, 10, &mut || {
        Ok(())
    })
    .unwrap();
    assert_eq!(
        unproven.unsupported_reason,
        Some(SchedulingUnsupportedReason::RunnableSemanticsUnproven)
    );
}
#[test]
fn nearest_rank_percentiles_are_not_interpolated_and_survive_sample_trim() {
    let durations = [1, 2, 3, 4, 100];
    let cpus = page(
        durations
            .iter()
            .enumerate()
            .map(|(i, _)| cpu(i as i64, 200, 300, 1, i as i64))
            .collect(),
    );
    let states = page(
        durations
            .iter()
            .enumerate()
            .map(|(i, d)| state(i as i64, 200 - d, 200, i as i64))
            .collect(),
    );
    let value = scheduling_latency(
        &cpus,
        &states,
        RunnableSemantics::ProvenNormalizedIntervals,
        1,
        &mut || Ok(()),
    )
    .unwrap();
    assert_eq!(value.count, 5);
    assert_eq!(value.top_samples.len(), 1);
    assert!(value.truncated);
    assert_eq!(
        value.percentiles,
        Some(Percentiles {
            p50_ns: 3,
            p90_ns: 100,
            p95_ns: 100,
            p99_ns: 100,
            max_ns: 100
        })
    );
}
#[test]
fn hot_difference_array_matches_naive_grid_across_all_small_half_open_ranges() {
    for end in 1..=12 {
        for count in 1..=15 {
            let rows: Vec<_> = (0..=end)
                .flat_map(|a| (a..=end).map(move |b| cpu(a * 100 + b, a, b, 1, 11)))
                .collect();
            let named: Vec<_> = rows
                .iter()
                .map(|r| NamedDurationEvidence {
                    key: r.key,
                    range: r.range,
                })
                .collect();
            let output =
                hot_intervals(&rows, &named, range(0, end), count, 2, &mut || Ok(())).unwrap();
            let actual_count = count.min(end as usize);
            let q = end / actual_count as i64;
            let rem = end % actual_count as i64;
            let mut start = 0;
            let mut expected = Vec::new();
            for i in 0..actual_count {
                let stop = start + q + i64::from((i as i64) < rem);
                let bucket = range(start, stop);
                let cpus: Vec<_> = rows.iter().filter(|r| r.range.intersects(bucket)).collect();
                let named: Vec<_> = named
                    .iter()
                    .filter(|r| r.range.duration_ns() >= 2 && r.range.intersects(bucket))
                    .collect();
                let busy: i64 = cpus
                    .iter()
                    .map(|r| r.range.clipped_overlap_ns(bucket))
                    .sum();
                let long: i64 = named
                    .iter()
                    .map(|r| r.range.clipped_overlap_ns(bucket))
                    .sum();
                let switches = rows
                    .iter()
                    .filter(|r| start <= r.range.start_ns() && r.range.start_ns() < stop)
                    .count();
                if !cpus.is_empty() || !named.is_empty() {
                    expected.push(HotInterval {
                        range: bucket,
                        score: HotIntervalScore {
                            cpu_busy_ns: busy,
                            context_switch_count: switches,
                            context_switch_score_ns: switches as i64 * CONTEXT_SWITCH_WEIGHT_NS,
                            long_slice_ns: long,
                            total: busy + long + switches as i64 * CONTEXT_SWITCH_WEIGHT_NS,
                        },
                        cpu_slice_count: cpus.len(),
                        named_slice_count: named.len(),
                    });
                }
                start = stop;
            }
            expected.sort_by_key(|r| (std::cmp::Reverse(r.score.total), r.range.start_ns()));
            assert_eq!(output, expected, "duration={end} buckets={count}");
        }
    }
}
#[test]
fn unsupported_and_empty_are_distinct_and_json_null_metadata_is_explicit() {
    let cpus = page(vec![]);
    let states = page(vec![]);
    let result = analyze(
        &AnalysisRequest::new(range(0, 100)),
        input(&cpus, &states, &quality()),
        &mut || Ok(()),
    )
    .unwrap();
    assert!(result.sections.cpu_utilization.supported);
    assert_eq!(result.sections.cpu_utilization.matched_count, Some(0));
    let mut cpus = cpus;
    cpus.capability_available = false;
    let result = analyze(
        &AnalysisRequest::new(range(0, 100)),
        input(&cpus, &states, &quality()),
        &mut || Ok(()),
    )
    .unwrap();
    assert!(!result.sections.cpu_utilization.supported);
    assert_eq!(
        result.scheduling_latency.unsupported_reason,
        Some(SchedulingUnsupportedReason::CapabilityUnavailable)
    );
    let value = top_threads(&[cpu(1, 0, 100, 1, 11)], range(0, 100), 10, &mut || Ok(())).unwrap();
    assert_eq!(
        serde_json::to_value(&value.items[0]).unwrap()["name"],
        serde_json::Value::Null
    );
}

#[test]
fn cancelling_ranking_sort_stops_after_a_bounded_comparison_batch() {
    let rows: Vec<_> = (0..1024).map(|i| cpu(i, 0, 100, i, i)).collect();
    let mut calls = 0;
    // Inputs and fraction projection each have four loop checkpoints. The
    // tenth checkpoint is at sort entry; the eleventh starts its first merge.
    let result = top_threads(&rows, range(0, 100), 1000, &mut || {
        calls += 1;
        if calls == 11 {
            Err(AnalysisError::Cancelled)
        } else {
            Ok(())
        }
    });
    assert_eq!(result, Err(AnalysisError::Cancelled));
    assert_eq!(calls, 11);
}

#[test]
fn wrong_event_tables_and_inconsistent_named_capability_are_rejected() {
    let mut cpus = page(vec![cpu(1, 0, 100, 1, 11)]);
    cpus.items[0].key.table = EventTable::ThreadState;
    let states = page(vec![]);
    let q = quality();
    assert_eq!(
        analyze(
            &AnalysisRequest::new(range(0, 100)),
            input(&cpus, &states, &q),
            &mut || Ok(())
        )
        .unwrap_err(),
        AnalysisError::InvalidEvidence
    );
    let cpus = page(vec![]);
    let named = page::<NamedDurationEvidence>(vec![]);
    let mut inputs = input(&cpus, &states, &q);
    inputs.hot_named = Some(&named);
    assert_eq!(
        analyze(&AnalysisRequest::new(range(0, 100)), inputs, &mut || Ok(())).unwrap_err(),
        AnalysisError::InvalidEvidence
    );
    let named = page(vec![NamedDurationEvidence {
        key: EventKey {
            table: EventTable::ThreadState,
            row_id: 1,
        },
        range: range(0, 100),
    }]);
    let mut inputs = input(&cpus, &states, &q);
    inputs.hot_named = Some(&named);
    inputs.named_slices_available = true;
    assert_eq!(
        analyze(&AnalysisRequest::new(range(0, 100)), inputs, &mut || Ok(())).unwrap_err(),
        AnalysisError::InvalidEvidence
    );
}

#[test]
fn contract_quality_budget_is_enforced_for_a_page_and_the_combined_report() {
    let make = |count| QualityIssue {
        category: QualityCategory::DroppedValue,
        scope: Some("sched_slice.cpu".into()),
        count: Some(count),
        message: None,
    };
    let states = page(vec![]);
    let mut cpus = page(vec![]);
    cpus.data_quality = DataQuality {
        status: QualityStatus::Warnings,
        warnings: (0..4097).map(make).collect(),
    };
    let request = AnalysisRequest::new(range(0, 100));
    assert_eq!(
        analyze(&request, input(&cpus, &states, &quality()), &mut || Ok(())).unwrap_err(),
        AnalysisError::Quality(ContractError::QualityItemBudgetExceeded)
    );
    cpus.data_quality.warnings.pop();
    let trace = DataQuality {
        status: QualityStatus::Warnings,
        warnings: vec![make(8192)],
    };
    assert_eq!(
        analyze(&request, input(&cpus, &states, &trace), &mut || Ok(())).unwrap_err(),
        AnalysisError::Quality(ContractError::QualityItemBudgetExceeded)
    );
}
