use arktrace_contract::*;

fn query() -> TraceSliceQuery {
    TraceSliceQuery {
        range: TraceTimeRange::query(0, i64::MAX).unwrap(),
        event_key: None,
        process_key: None,
        pid: None,
        thread_key: None,
        tid: None,
        name: None,
        name_match: DirectoryNameMatch::Exact,
        minimum_duration_ns: None,
        depth: None,
        unattributed_only: false,
        includes_argument_set: false,
        limit: 100_000,
    }
}
#[test]
fn named_query_keeps_int64_identity_and_closes_bounds_and_fields() {
    let mut q = query();
    q.event_key = Some(EventKey {
        table: EventTable::Callstack,
        row_id: -9_007_199_254_740_993,
    });
    q.process_key = Some(-1);
    q.name = Some(String::new());
    q.validate().unwrap();
    assert_eq!(
        serde_json::from_str::<TraceSliceQuery>(&serde_json::to_string(&q).unwrap()).unwrap(),
        q
    );
    for change in 0..6 {
        let mut q = query();
        match change {
            0 => q.limit = 0,
            1 => q.limit = 100_001,
            2 => q.depth = Some(-1),
            3 => q.minimum_duration_ns = Some(-1),
            4 => q.name = Some("é".repeat(2049)),
            _ => {
                q.event_key = Some(EventKey {
                    table: EventTable::SchedSlice,
                    row_id: 1,
                })
            }
        }
        assert_eq!(q.validate(), Err(ContractError::InvalidEventQuery));
    }
    let mut v = serde_json::to_value(query()).unwrap();
    v["sql"] = serde_json::json!("SELECT");
    assert!(serde_json::from_value::<TraceSliceQuery>(v).is_err());
}
#[test]
fn unattributed_scope_is_opt_in_and_rejects_conflicting_identity_filters() {
    let q = query();
    let wire = serde_json::to_value(&q).unwrap();
    assert!(!wire.as_object().unwrap().contains_key("unattributedOnly"));
    assert_eq!(serde_json::from_value::<TraceSliceQuery>(wire).unwrap(), q);
    let mut scoped = q;
    scoped.unattributed_only = true;
    scoped.validate().unwrap();
    assert_eq!(
        serde_json::to_value(&scoped).unwrap()["unattributedOnly"],
        true
    );
    for field in 0..4 {
        let mut invalid = scoped.clone();
        match field {
            0 => invalid.process_key = Some(1),
            1 => invalid.pid = Some(1),
            2 => invalid.thread_key = Some(1),
            _ => invalid.tid = Some(1),
        }
        assert_eq!(invalid.validate(), Err(ContractError::InvalidEventQuery));
    }
}
#[test]
fn slice_coded_shape_preserves_nulls_parent_identity_and_omits_argument_handle() {
    let slice = TraceSlice {
        key: EventKey {
            table: EventTable::Callstack,
            row_id: i64::MAX,
        },
        range: TraceTimeRange::event(9_007_199_254_740_993, 9_007_199_254_740_993).unwrap(),
        thread_key: None,
        process_key: Some(ProcessKey { ipid: -1 }),
        pid: None,
        tid: None,
        process_name: None,
        thread_name: Some(String::new()),
        name: "\0é".into(),
        category: None,
        depth: None,
        parent_event_key: Some(EventKey {
            table: EventTable::Callstack,
            row_id: i64::MAX - 1,
        }),
        is_async: true,
        is_open_ended: false,
        arg_set_id: Some(42),
    };
    assert!(slice.is_instant());
    let v = serde_json::to_value(&slice).unwrap();
    assert_eq!(v.as_object().unwrap().len(), 14);
    assert_eq!(v["key"]["rowID"], i64::MAX);
    assert!(v["threadKey"].is_null());
    assert!(!v.as_object().unwrap().contains_key("argSetID"));
    let decoded: TraceSlice = serde_json::from_value(v).unwrap();
    assert_eq!(decoded.arg_set_id, None);
    let mut expected = slice;
    expected.arg_set_id = None;
    assert_eq!(decoded, expected);
}
