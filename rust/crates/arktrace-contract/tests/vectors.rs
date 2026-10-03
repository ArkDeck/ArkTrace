use arktrace_contract::{
    DataQuality, QualityIssue, QualityStatus, TraceCacheKey, TraceTimeRange, WINDOWS_LEASE_LENGTH,
    WINDOWS_LEASE_OFFSET,
};
use serde_json::{Value, json};

#[test]
fn swift_time_contract_vectors() {
    let corpus: Value = serde_json::from_str(include_str!(
        "../../../../contracts/time-range-vectors.json"
    ))
    .unwrap();
    for vector in corpus["vectors"].as_array().unwrap() {
        let event = &vector["event"];
        let query = &vector["query"];
        let event = TraceTimeRange::event(event[0].as_i64().unwrap(), event[1].as_i64().unwrap());
        let query = TraceTimeRange::query(query[0].as_i64().unwrap(), query[1].as_i64().unwrap());
        assert_eq!(
            event.is_ok(),
            vector["eventValid"].as_bool().unwrap(),
            "{}",
            vector["id"]
        );
        assert_eq!(
            query.is_ok(),
            vector["queryValid"].as_bool().unwrap(),
            "{}",
            vector["id"]
        );
        if let (Ok(event), Ok(query)) = (event, query) {
            assert_eq!(
                event.intersects(query),
                vector["intersects"].as_bool().unwrap()
            );
            assert_eq!(
                event.clipped_overlap_ns(query),
                vector["overlapNs"].as_i64().unwrap()
            );
            let encoded = serde_json::to_value(event).unwrap();
            assert_eq!(
                serde_json::from_value::<TraceTimeRange>(encoded).unwrap(),
                event
            );
        }
    }
}

#[test]
fn swift_quality_contract_vectors() {
    let corpus: Value =
        serde_json::from_str(include_str!("../../../../contracts/quality-vectors.json")).unwrap();
    for vector in corpus["vectors"].as_array().unwrap() {
        let input: QualityIssue = serde_json::from_value(vector["issue"].clone()).unwrap();
        let machine = input.into_machine();
        assert_eq!(
            machine.is_ok(),
            vector["valid"].as_bool().unwrap(),
            "{}",
            vector["id"]
        );
        if let Ok(issue) = machine {
            assert_eq!(serde_json::to_value(issue).unwrap(), vector["machineIssue"]);
        }
    }
}

#[test]
fn machine_quality_is_closed_bounded_and_sorted() {
    let issue = |category, scope| QualityIssue {
        category,
        scope: Some(String::from(scope)),
        count: Some(1),
        message: Some("private".into()),
    };
    use arktrace_contract::QualityCategory::*;
    let quality = DataQuality::machine(
        QualityStatus::Warnings,
        vec![
            issue(ProbeTruncated, "stat.count"),
            issue(ClampedValue, "stat.count"),
        ],
    )
    .unwrap();
    assert_eq!(quality.warnings[0].category, ClampedValue);
    assert!(!serde_json::to_string(&quality).unwrap().contains("private"));
    assert!(DataQuality::machine(QualityStatus::Ok, quality.warnings.clone()).is_err());
    assert!(DataQuality::machine(QualityStatus::Warnings, Vec::new()).is_err());
    assert!(
        DataQuality::machine(
            QualityStatus::Warnings,
            vec![quality.warnings[0].clone(); 4097]
        )
        .is_err()
    );
    assert!(
        serde_json::from_value::<QualityIssue>(
            json!({"category":"future","scope":null,"count":null,"message":null})
        )
        .is_err()
    );
    assert!(
        serde_json::from_value::<QualityIssue>(
            json!({"category":"invalidValue","scope":null,"count":null,"message":null,"extra":true})
        )
        .is_err()
    );
    assert!(serde_json::from_value::<TraceTimeRange>(json!({"startNs":-1,"endNs":0})).is_err());
    assert!(
        serde_json::from_value::<TraceTimeRange>(json!({"startNs":0,"endNs":1,"extra":true}))
            .is_err()
    );
}

#[test]
fn swift_cache_key_and_lease_protocol_vectors() {
    let corpus: Value = serde_json::from_str(include_str!(
        "../../../../contracts/cache-lease-vectors.json"
    ))
    .unwrap();
    assert_eq!(
        corpus["protocol"]["windows"]["offsetDecimal"],
        WINDOWS_LEASE_OFFSET.to_string()
    );
    assert_eq!(
        corpus["protocol"]["windows"]["lengthBytes"],
        WINDOWS_LEASE_LENGTH
    );
    for vector in corpus["vectors"].as_array().unwrap() {
        let input = &vector["input"];
        let result = TraceCacheKey::new(
            input["traceSHA256"].as_str().unwrap(),
            input["parserBinarySHA256"].as_str().unwrap(),
            input["upstreamRevision"].as_str().unwrap(),
            input["schemaAdapterVersion"].as_str().unwrap(),
            input["indexSchemaVersion"].as_i64().unwrap(),
        );
        assert_eq!(
            result.is_ok(),
            vector["valid"].as_bool().unwrap(),
            "{}",
            vector["id"]
        );
        if let Ok(key) = result {
            assert_eq!(key.parser_key(), vector["parserKey"]);
            assert_eq!(key.entry_identifier(), vector["entryIdentifier"]);
            assert_eq!(key.lock_relative_path(), vector["lockRelativePath"]);
            assert_eq!(key.lease_relative_path(), vector["leaseRelativePath"]);
            let encoded = serde_json::to_value(&key).unwrap();
            assert_eq!(
                serde_json::from_value::<TraceCacheKey>(encoded.clone()).unwrap(),
                key
            );
            let mut wrong_key = encoded.clone();
            wrong_key["parserKey"] = json!("0".repeat(64));
            assert!(serde_json::from_value::<TraceCacheKey>(wrong_key).is_err());
            let mut extra = encoded;
            extra["unknown"] = json!(true);
            assert!(serde_json::from_value::<TraceCacheKey>(extra).is_err());
        }
    }
}
