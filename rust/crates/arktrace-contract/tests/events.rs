use arktrace_contract::{
    CpuSlice, CpuSliceQuery, EventKey, EventTable, ThreadStateQuery, TraceTimeRange,
};
use serde_json::json;

#[test]
fn event_dto_keeps_table_identity_int64_precision_and_explicit_nulls() {
    let item = CpuSlice {
        key: EventKey {
            table: EventTable::SchedSlice,
            row_id: 0,
        },
        range: TraceTimeRange::event(9_007_199_254_740_993, i64::MAX).unwrap(),
        cpu: 3,
        thread_key: None,
        process_key: None,
        tid: None,
        pid: None,
        thread_name: None,
        process_name: None,
        end_state: None,
        priority: None,
        is_open_ended: true,
    };
    let value = serde_json::to_value(&item).unwrap();
    assert_eq!(
        value,
        json!({
            "key":{"table":"sched_slice","rowID":0},
            "range":{"startNs":9_007_199_254_740_993_i64,"endNs":i64::MAX},
            "cpu":3,"threadKey":null,"processKey":null,"tid":null,"pid":null,
            "threadName":null,"processName":null,"endState":null,"priority":null,"isOpenEnded":true,
        })
    );
    let decoded: CpuSlice = serde_json::from_slice(&serde_json::to_vec(&item).unwrap()).unwrap();
    assert_eq!(decoded, item);
    assert_ne!(
        item.key,
        EventKey {
            table: EventTable::ThreadState,
            row_id: 0
        }
    );
    assert!(serde_json::from_value::<EventKey>(json!({"table":"sched_slice","rowId":0})).is_err());
    assert!(serde_json::from_value::<EventKey>(json!({"table":"unknown","rowID":0})).is_err());
}

#[test]
fn query_contract_is_closed_and_bounds_source_rows_and_raw_state_utf8() {
    let value = json!({"range":{"startNs":0,"endNs":1},"cpu":null,"processKey":-10,
        "pid":null,"threadKey":-11,"tid":null,"limit":100000});
    let query: CpuSliceQuery = serde_json::from_value(value.clone()).unwrap();
    query.validate().unwrap();
    let mut unknown = value.clone();
    unknown["sql"] = json!("SELECT *");
    assert!(serde_json::from_value::<CpuSliceQuery>(unknown).is_err());
    for limit in [0, 100001, usize::MAX] {
        let mut query = query.clone();
        query.limit = limit;
        assert!(query.validate().is_err());
    }
    let mut state = value;
    state["state"] = json!("runnable");
    state["rawState"] = json!("界".repeat(85));
    serde_json::from_value::<ThreadStateQuery>(state.clone())
        .unwrap()
        .validate()
        .unwrap();
    state["rawState"] = json!("界".repeat(86));
    assert!(
        serde_json::from_value::<ThreadStateQuery>(state.clone())
            .unwrap()
            .validate()
            .is_err()
    );
    state["rawState"] = json!("");
    serde_json::from_value::<ThreadStateQuery>(state.clone())
        .unwrap()
        .validate()
        .unwrap();
    state["state"] = json!("unknown");
    assert!(serde_json::from_value::<ThreadStateQuery>(state).is_err());
}
