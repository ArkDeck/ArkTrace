use arktrace_contract::*;
use arktrace_viewer::*;

#[test]
fn typed_detail_queries_keep_lane_identity_and_prelimit_unattributed_scope() {
    let range = TraceTimeRange::query(10, 50).unwrap();
    for source in [
        TraceDensitySource::Cpu { cpu: 3 },
        TraceDensitySource::ThreadState {
            thread: ThreadKey { itid: -7 },
        },
        TraceDensitySource::NamedSlice {
            thread: Some(ThreadKey { itid: -7 }),
        },
        TraceDensitySource::NamedSlice { thread: None },
        TraceDensitySource::Frame {
            process_key: Some(ProcessKey { ipid: -9 }),
        },
        TraceDensitySource::CpuCounter {
            filter_id: 42,
            cpu: Some(3),
        },
        TraceDensitySource::ProcessCounter {
            filter_id: 42,
            process_key: Some(ProcessKey { ipid: -9 }),
        },
    ] {
        match detail_query(&source, range, 17).unwrap() {
            RepositoryDetailQuery::Cpu(q) => {
                q.validate().unwrap();
                assert_eq!(q.cpu, Some(3));
                assert_eq!(q.limit, 17);
            }
            RepositoryDetailQuery::ThreadState(q) => {
                q.validate().unwrap();
                assert_eq!(q.thread_key, Some(-7));
                assert_eq!(q.limit, 17);
            }
            RepositoryDetailQuery::NamedSlice(q) => {
                q.validate().unwrap();
                assert_eq!(q.limit, 17);
                let TraceDensitySource::NamedSlice { thread } = source else {
                    unreachable!()
                };
                assert_eq!(q.thread_key, thread.map(|t| t.itid));
                assert_eq!(q.unattributed_only, thread.is_none());
                assert!(!q.includes_argument_set);
            }
            RepositoryDetailQuery::Frame(q) => {
                q.validate().unwrap();
                assert_eq!(q.process_key, Some(-9));
                assert_eq!(q.limit, 17);
            }
            RepositoryDetailQuery::Counter(q) => {
                q.validate().unwrap();
                assert_eq!(q.filter_id, Some(42));
                assert_eq!(q.limit, 17);
                match source {
                    TraceDensitySource::CpuCounter { .. } => {
                        assert_eq!(q.scope, Some(CounterScope::Cpu));
                        assert_eq!(q.cpu, Some(3));
                        assert_eq!(q.process_key, None);
                    }
                    TraceDensitySource::ProcessCounter { .. } => {
                        assert_eq!(q.scope, Some(CounterScope::Process));
                        assert_eq!(q.cpu, None);
                        assert_eq!(q.process_key, Some(-9));
                    }
                    _ => unreachable!(),
                }
            }
        }
    }
    let source = TraceDensitySource::NamedSlice { thread: None };
    for limit in [0, 20_001, usize::MAX] {
        assert_eq!(
            detail_query(&source, range, limit),
            Err(ViewerError::InvalidRequest)
        );
    }
    assert_eq!(
        detail_query(&source, TraceTimeRange::event(10, 10).unwrap(), 17),
        Err(ViewerError::InvalidRequest)
    );
}
