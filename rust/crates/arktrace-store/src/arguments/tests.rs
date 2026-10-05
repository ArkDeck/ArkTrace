use super::*;
use crate::{ValidationBudget, database::Database};
use arktrace_platform::CancellationToken;
use rusqlite::Connection;
use std::time::{Duration, Instant};

const SCHEMA: &str = "CREATE TABLE callstack(id INTEGER,ts INTEGER,dur INTEGER,callid INTEGER,name TEXT,argsetid INTEGER);
CREATE TABLE args(id INTEGER,key INTEGER,datatype INTEGER,value INTEGER,argset INTEGER);
CREATE TABLE data_dict(id INTEGER,data TEXT);
CREATE TABLE data_type(typeId INTEGER,desc TEXT);
INSERT INTO data_dict VALUES(10,'key'),(11,''),(12,'string value'),(13,''),(14,CAST(x'ff' AS TEXT));
INSERT INTO data_type VALUES(0,'int32_t'),(1,'string'),(2,'double'),(3,'boolean');";
fn budget() -> ValidationBudget {
    ValidationBudget {
        maximum_database_bytes: 256 * 1024 * 1024,
        deadline: Instant::now() + Duration::from_secs(10),
        cancellation: CancellationToken::default(),
    }
}
fn fixture(sql: &str) -> Connection {
    let c = Connection::open_in_memory().unwrap();
    c.execute_batch(SCHEMA).unwrap();
    c.execute_batch(sql).unwrap();
    c
}
fn query(id: i64, limit: usize) -> TraceArgumentQuery {
    TraceArgumentQuery {
        arg_set_id: id,
        limit,
    }
}
fn arguments(
    c: &Connection,
    q: &TraceArgumentQuery,
) -> Result<EventPage<TraceEventArgument>, StoreError> {
    let b = budget();
    let db = Database::borrow_readonly(c, &b)?;
    ArgumentSchema::read(&db)?.arguments(&db, q)
}

#[test]
fn ready_indexes_find_a_small_argument_set_without_scanning_unrelated_rows() {
    let disk = crate::tests::SQLiteDiskFixture::new(
        "ALTER TABLE callstack ADD COLUMN argsetid INTEGER;
        CREATE TABLE args(id INTEGER,key INTEGER,datatype INTEGER,value INTEGER,argset INTEGER);
        CREATE TABLE data_dict(id INTEGER,data TEXT);
        CREATE TABLE data_type(typeId INTEGER,desc TEXT);
        INSERT INTO data_dict VALUES(10,'key'),(11,'');
        INSERT INTO data_type VALUES(0,'int32_t');
        WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<800000)
        INSERT INTO args SELECT i+100,10,0,i,99 FROM n;
        INSERT INTO args VALUES(1,10,0,9,5),(2,10,0,2,5),(3,11,0,3,5);",
    );
    let c = disk.connection.as_ref().unwrap();
    assert_eq!(
        arguments(c, &query(5, 64)),
        Err(StoreError::VmBudgetExceeded)
    );
    let b = budget();
    let db = Database::borrow_writable(c, &b).unwrap();
    crate::indexes::prepare(&db, |_| {}).unwrap();
    let p = arguments(c, &query(5, 64)).unwrap();
    assert_eq!(
        p.items.iter().map(|v| v.value.as_str()).collect::<Vec<_>>(),
        ["9", "2"]
    );
    assert!(!p.truncated && p.capability_available);
    let p = arguments(c, &query(5, 1)).unwrap();
    assert_eq!(p.items[0].value, "9");
    assert!(p.truncated);
    assert!(arguments(c, &query(7, 64)).unwrap().items.is_empty());
}
#[test]
fn only_integer_datatype_one_resolves_a_dictionary_value() {
    let c = fixture(
        "INSERT INTO args VALUES(1,10,1,12,5),(2,10,0,12,5),(3,10,2,-123,5),(4,10,3,0,5),(5,10,99,9223372036854775807,5),(6,10,NULL,-9223372036854775808,5),(7,10,1,13,5),(8,10,1.5,12,5);",
    );
    let p = arguments(&c, &query(5, 64)).unwrap();
    assert_eq!(
        p.items.iter().map(|v| v.value.as_str()).collect::<Vec<_>>(),
        [
            "string value",
            "12",
            "-123",
            "0",
            "9223372036854775807",
            "-9223372036854775808",
            "",
            "12"
        ]
    );
    assert_eq!(p.items[4].type_name, None);
    assert_eq!(p.items[7].type_name, None);
    assert!(p.capability_available && !p.truncated && p.data_quality.warnings.is_empty());
}
#[test]
fn bad_rows_are_compacted_after_mapping_the_lookahead_without_inventing_quality() {
    let c = fixture("INSERT INTO args VALUES(1,11,0,1,5),(2,10,0,2,5),(3,10,0,3,5);");
    let p = arguments(&c, &query(5, 1)).unwrap();
    assert_eq!(p.items[0].value, "2");
    assert!(p.truncated);
    let p = arguments(&c, &query(5, 2)).unwrap();
    assert_eq!(
        p.items.iter().map(|v| v.value.as_str()).collect::<Vec<_>>(),
        ["2", "3"]
    );
    assert!(p.truncated && p.data_quality.warnings.is_empty());
}
#[test]
fn required_strings_and_raw_values_are_strict_but_optional_type_text_is_nil() {
    let c = fixture("UPDATE data_type SET desc=CAST(x'ff' AS TEXT) WHERE typeId=0;
        INSERT INTO args VALUES(1,999,0,1,5),(2,14,0,1,5),(3,10,1,999,5),(4,10,1,14,5),(5,10,0,NULL,5),(6,10,0,1.5,5),(7,10,0,'bad',5),(8,10,0,7,5);");
    let p = arguments(&c, &query(5, 64)).unwrap();
    assert_eq!(
        p.items,
        [TraceEventArgument {
            key: "key".into(),
            value: "7".into(),
            type_name: None
        }]
    );
    assert!(!p.truncated && p.data_quality.warnings.is_empty());
}
#[test]
fn argument_set_filter_keeps_signed_extremes_zero_and_storage_class() {
    let c = fixture(
        "INSERT INTO args VALUES(1,10,0,1,0),(2,10,0,2,-1),(3,10,0,3,-9223372036854775808),(4,10,0,4,9223372036854775807),(5,10,0,5,'5x'),(6,10,0,6,5.5);",
    );
    for (id, value) in [(0, "1"), (-1, "2"), (i64::MIN, "3"), (i64::MAX, "4")] {
        assert_eq!(arguments(&c, &query(id, 64)).unwrap().items[0].value, value);
    }
    assert!(arguments(&c, &query(5, 64)).unwrap().items.is_empty());
}
#[test]
fn optional_tables_and_handle_column_determine_availability_not_row_count() {
    for sql in [
        "DROP TABLE args;",
        "DROP TABLE data_dict;",
        "DROP TABLE data_type;",
        "ALTER TABLE data_type DROP COLUMN desc;",
        "ALTER TABLE args DROP COLUMN value;",
        "ALTER TABLE callstack DROP COLUMN argsetid;",
    ] {
        let c = fixture(sql);
        let p = arguments(&c, &query(5, 64)).unwrap();
        assert!(!p.capability_available && p.items.is_empty() && !p.truncated);
        assert_eq!(arguments(&c, &query(5, 0)), Err(StoreError::InvalidQuery));
    }
    assert!(
        arguments(&fixture(""), &query(5, 64))
            .unwrap()
            .capability_available
    );
}
#[test]
fn additive_id_absence_has_stable_value_order_even_without_rowid() {
    for suffix in ["", ",PRIMARY KEY(key,datatype,value,argset)"] {
        let c = fixture(&format!(
            "DROP TABLE args;CREATE TABLE args(key INTEGER,datatype INTEGER,value INTEGER,argset INTEGER{suffix}){};INSERT INTO args VALUES(10,1,12,5),(10,0,7,5),(10,0,2,5);",
            if suffix.is_empty() {
                ""
            } else {
                " WITHOUT ROWID"
            }
        ));
        let p = arguments(&c, &query(5, 64)).unwrap();
        assert_eq!(
            p.items.iter().map(|v| v.value.as_str()).collect::<Vec<_>>(),
            ["2", "7", "string value"]
        );
    }
}
#[test]
fn repeated_argument_ids_use_stable_values_instead_of_source_insertion_order() {
    let c = fixture("INSERT INTO args VALUES(1,10,0,7,5),(1,10,0,2,5);");
    let p = arguments(&c, &query(5, 64)).unwrap();
    assert_eq!(
        p.items.iter().map(|v| v.value.as_str()).collect::<Vec<_>>(),
        ["2", "7"]
    );
}
#[test]
fn joined_ties_are_ordered_by_resolved_values_when_id_is_absent() {
    let c=fixture("DROP TABLE args;DELETE FROM data_dict;DELETE FROM data_type;
        CREATE TABLE args(key INTEGER,datatype INTEGER,value INTEGER,argset INTEGER);
        INSERT INTO data_dict VALUES(10,'z'),(10,'a'),(12,'z-value'),(12,'a-value');INSERT INTO data_type VALUES(1,'z-type'),(1,'a-type');INSERT INTO args VALUES(10,1,12,5);");
    let p = arguments(&c, &query(5, 64)).unwrap();
    assert_eq!(p.items.len(), 8);
    assert_eq!(
        p.items[0],
        TraceEventArgument {
            key: "a".into(),
            value: "a-value".into(),
            type_name: Some("a-type".into())
        }
    );
    assert_eq!(
        p.items[7],
        TraceEventArgument {
            key: "z".into(),
            value: "z-value".into(),
            type_name: Some("z-type".into())
        }
    );
}
#[test]
fn cancellation_and_expired_deadline_do_not_change_a_later_page() {
    let c = fixture("INSERT INTO args VALUES(1,10,0,7,5);");
    let q = query(5, 64);
    let expected = arguments(&c, &q).unwrap();
    let b = budget();
    let db = Database::borrow_readonly(&c, &b).unwrap();
    let s = ArgumentSchema::read(&db).unwrap();
    b.cancellation.cancel();
    assert_eq!(s.arguments(&db, &q), Err(StoreError::Cancelled));
    let mut b = budget();
    b.deadline = Instant::now() - Duration::from_millis(1);
    assert_eq!(
        Database::borrow_readonly(&c, &b).err(),
        Some(StoreError::DeadlineExceeded)
    );
    assert_eq!(arguments(&c, &q).unwrap(), expected);
}
