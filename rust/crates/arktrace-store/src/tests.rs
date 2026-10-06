use super::*;
use crate::database::{DEFAULT_VM_BUDGET, Database, integer};
use rusqlite::Connection;
use std::time::{Duration, Instant};

const SCHEMA: &str = "
CREATE TABLE trace_range(start_ts INTEGER,end_ts INTEGER);
INSERT INTO trace_range VALUES(100,1000);
CREATE TABLE process(ipid INTEGER,pid INTEGER,name TEXT,start_ts INTEGER);
CREATE TABLE thread(itid INTEGER,tid INTEGER,name TEXT,start_ts INTEGER,ipid INTEGER);
CREATE TABLE sched_slice(id INTEGER,ts INTEGER,dur INTEGER,cpu INTEGER,itid INTEGER,ipid INTEGER);
CREATE TABLE thread_state(id INTEGER,ts INTEGER,dur INTEGER,itid INTEGER,state TEXT);
CREATE TABLE callstack(id INTEGER,ts INTEGER,dur INTEGER,callid INTEGER,name TEXT);";
fn budget() -> ValidationBudget {
    ValidationBudget {
        maximum_database_bytes: 256 * 1024 * 1024,
        deadline: Instant::now() + Duration::from_secs(10),
        cancellation: CancellationToken::default(),
    }
}
fn fixture(extra: &str) -> Connection {
    let db = Connection::open_in_memory().unwrap();
    db.execute_batch(SCHEMA).unwrap();
    db.execute_batch(extra).unwrap();
    db
}
fn inspect(extra: &str) -> Result<DatabaseInspection, StoreError> {
    Database::new(fixture(extra), &budget())?.inspect()
}

#[test]
fn empty_compatible_trace_has_no_capabilities_or_quality_warnings() {
    let result = inspect("").unwrap();
    assert_eq!(result.duration_ns, 900);
    assert_eq!(
        result.data_quality.status,
        arktrace_contract::QualityStatus::Ok
    );
    assert_eq!(
        result.capabilities,
        TraceCapabilities {
            cpu_scheduling: false,
            thread_states: false,
            named_slices: false,
            cpu_counters: false,
            process_counters: false
        }
    );
}
#[test]
fn required_affinity_accepts_canonical_declarations_and_rejects_missing_or_real() {
    for extra in [
        "DROP TABLE process",
        "DROP TABLE process;CREATE TABLE process(ipid REAL,pid INTEGER,name TEXT,start_ts INTEGER)",
    ] {
        assert_eq!(inspect(extra), Err(StoreError::SchemaUnsupported));
    }
    let result=inspect("DROP TABLE process;CREATE TABLE process(ipid UNSIGNED BIG INT,pid INT,name VARCHAR(300),start_ts BIGINT)").unwrap();
    assert_eq!(result.duration_ns, 900);
}
#[test]
fn trace_range_rejects_coercion_multiple_rows_and_int64_overflow() {
    for values in [
        "('bad',1000)",
        "(1.5,1000)",
        "(NULL,1000)",
        "(1000,1000)",
        "(-9223372036854775808,9223372036854775807)",
        "(100,1000),(101,1000)",
    ] {
        assert_eq!(
            inspect(&format!(
                "DELETE FROM trace_range;INSERT INTO trace_range VALUES{values}"
            )),
            Err(StoreError::InvalidDatabase)
        );
    }
}
#[test]
fn identities_reject_non_integer_storage_without_forging_zero() {
    for id in ["NULL", "'abc'", "1.5"] {
        assert_eq!(
            inspect(&format!("INSERT INTO process VALUES({id},2,'process',100)")),
            Err(StoreError::InvalidIdentity)
        );
    }
    assert_eq!(
        inspect("INSERT INTO thread VALUES(1,2,'t',100,'bad')"),
        Err(StoreError::InvalidIdentity)
    );
    assert_eq!(
        inspect("INSERT INTO callstack VALUES(1,100,0,'bad','slice')"),
        Err(StoreError::InvalidIdentity)
    );
}
#[test]
fn required_relationships_accept_absent_sentinels_but_reject_missing_identity() {
    inspect(
        "INSERT INTO thread VALUES(1,2,'t',100,NULL),(2,3,'t',100,0);
        INSERT INTO sched_slice VALUES(1,100,1,0,NULL,0)",
    )
    .unwrap();
    assert_eq!(
        inspect("INSERT INTO thread VALUES(1,2,'t',100,99)"),
        Err(StoreError::BrokenRelationship)
    );
    assert_eq!(
        inspect("INSERT INTO thread_state VALUES(1,100,1,99,'Running')"),
        Err(StoreError::BrokenRelationship)
    );
}
const COUNTER_SCHEMA: &str = "
CREATE TABLE measure(ts INTEGER,value INTEGER,filter_id INTEGER);
CREATE TABLE process_measure(ts INTEGER,value INTEGER,filter_id INTEGER);
CREATE TABLE cpu_measure_filter(id INTEGER,name TEXT,cpu INTEGER);
CREATE TABLE process_measure_filter(id INTEGER,name TEXT,ipid INTEGER);";
#[test]
fn counters_require_an_integer_join_and_read_process_measure_before_legacy_measure() {
    let extra = format!(
        "{COUNTER_SCHEMA}
        INSERT INTO process_measure_filter VALUES(1,'memory',8);
        INSERT INTO process_measure VALUES(100,2,1);
        INSERT INTO measure VALUES(101,3,1);"
    );
    let result = inspect(&extra).unwrap();
    assert!(result.capabilities.process_counters);
    assert!(!result.capabilities.cpu_counters);
    assert_eq!(
        result.process_counter_sample_tables,
        [
            CounterSampleTable::ProcessMeasure,
            CounterSampleTable::Measure
        ]
    );
    let result=inspect(&format!("{COUNTER_SCHEMA} INSERT INTO cpu_measure_filter VALUES(1,'cpu',0);INSERT INTO measure VALUES(100,2,'bad');")).unwrap();
    assert!(!result.capabilities.cpu_counters);
}
#[test]
fn independent_counter_tables_allow_same_ids_but_shared_tables_reject_ambiguity() {
    let extra=format!("{COUNTER_SCHEMA}
        INSERT INTO cpu_measure_filter VALUES(1,'cpu',0),(3,'unused',2); INSERT INTO process_measure_filter VALUES(2,'mem',8),(3,'unused',9);
        INSERT INTO measure VALUES(100,2,1); INSERT INTO process_measure VALUES(100,2,2);");
    let separate = inspect(&extra).unwrap();
    assert!(separate.capabilities.process_counters);
    assert!(separate.capabilities.cpu_counters);
    assert_eq!(
        inspect(&format!("{extra} INSERT INTO measure VALUES(100,3,2)")),
        Err(StoreError::AmbiguousCounterIdentity)
    );
}
#[test]
fn duplicate_filter_identity_is_a_fatal_schema_ambiguity() {
    assert_eq!(
        inspect(&format!(
            "{COUNTER_SCHEMA} INSERT INTO measure VALUES(100,2,1);
        INSERT INTO cpu_measure_filter VALUES(1,'cpu',0),(1,'different',1)"
        )),
        Err(StoreError::AmbiguousCounterIdentity)
    );
}
#[test]
fn optional_counter_budget_records_unproven_relationship_without_reading_it() {
    let result = inspect(&format!(
        "{COUNTER_SCHEMA}
        INSERT INTO cpu_measure_filter VALUES(2,'cpu',0);
        WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100000)
        INSERT INTO measure SELECT 100,2,1 FROM n;"
    ))
    .unwrap();
    assert!(!result.capabilities.cpu_counters);
    assert!(
        result
            .data_quality
            .warnings
            .iter()
            .any(
                |issue| issue.category == arktrace_contract::QualityCategory::ProbeTruncated
                    && issue.scope.as_deref() == Some("schema.counterSource")
            )
    );
}
#[test]
fn negative_duration_preserves_open_ended_semantics_and_bad_time_remains_visible() {
    let result = inspect(
        "INSERT INTO callstack VALUES(1,99,-1,1,'open'),(2,1001,-9,1,'open'),(3,'bad',0,1,'bad')",
    )
    .unwrap();
    let warnings = &result.data_quality.warnings;
    assert_eq!(warnings.len(), 3);
    assert!(
        warnings
            .iter()
            .all(|issue| issue.scope.as_deref() == Some("callstack.ts") && issue.message.is_none())
    );
    assert!(warnings.iter().any(|issue| issue.category
        == arktrace_contract::QualityCategory::DroppedValue
        && issue.count == Some(1)));
}
#[test]
fn clock_epoch_outlier_requires_two_independent_tables_and_reports_clamping() {
    let base="DELETE FROM trace_range;INSERT INTO trace_range VALUES(0,1000000000000);
        INSERT INTO sched_slice VALUES(1,999000000000,0,0,0,0);
        INSERT INTO callstack VALUES(1,0,0,0,'outlier'),(2,998999999999,0,0,'real'),(3,999000000000,0,0,'real');";
    let result = inspect(base).unwrap();
    assert_eq!(result.trace_start_ts, 998999999999);
    assert_eq!(result.duration_ns, 1000000001);
    assert!(
        result
            .data_quality
            .warnings
            .iter()
            .any(
                |issue| issue.category == arktrace_contract::QualityCategory::ClampedValue
                    && issue.scope.as_deref() == Some("callstack.ts")
            )
    );
    let one = inspect(&format!("{base} DELETE FROM sched_slice;")).unwrap();
    assert_eq!(one.trace_start_ts, 0);
}
#[test]
fn quoted_names_delimiters_and_generated_kinds_have_distinct_fingerprints() {
    let normal = inspect("CREATE TABLE \"奇怪\"\";\n名\"(\"a|b\" INTEGER)").unwrap();
    let virtual_col=inspect("CREATE TABLE \"奇怪\"\";\n名\"(\"a|b\" INTEGER,calc INTEGER GENERATED ALWAYS AS (\"a|b\"+1) VIRTUAL)").unwrap();
    let stored=inspect("CREATE TABLE \"奇怪\"\";\n名\"(\"a|b\" INTEGER,calc INTEGER GENERATED ALWAYS AS (\"a|b\"+1) STORED)").unwrap();
    assert_ne!(normal.schema_fingerprint, virtual_col.schema_fingerprint);
    assert_ne!(virtual_col.schema_fingerprint, stored.schema_fingerprint);
    let unrelated = inspect("CREATE TABLE extra(x TEXT)").unwrap();
    assert_ne!(normal.schema_fingerprint, unrelated.schema_fingerprint);
}
#[test]
fn vm_interruption_resets_handler_and_cancellation_and_deadline_are_distinct() {
    let request = budget();
    let db = Database::new(fixture(""), &request).unwrap();
    let sql = "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1000000) SELECT SUM(x) FROM n";
    assert_eq!(
        db.query(sql, [], 1, 100, |row| integer(row, 0)),
        Err(StoreError::VmBudgetExceeded)
    );
    assert_eq!(
        db.query("SELECT 7", [], 1, DEFAULT_VM_BUDGET, |row| integer(row, 0))
            .unwrap(),
        [7]
    );
    request.cancellation.cancel();
    assert_eq!(db.inspect(), Err(StoreError::Cancelled));
    let expired = ValidationBudget {
        deadline: Instant::now() - Duration::from_millis(1),
        ..budget()
    };
    assert!(matches!(
        Database::new(fixture(""), &expired),
        Err(StoreError::DeadlineExceeded)
    ));
}

#[test]
fn quick_check_accepts_valid_database_beyond_small_trace_vm_work() {
    // NOT NULL checks make a compact, valid database exceed the former fixed
    // 50M instruction ceiling without requiring a reviewed large trace in CI.
    let connection = Connection::open_in_memory().unwrap();
    let columns = (0..32)
        .map(|index| format!("c{index} INTEGER NOT NULL"))
        .collect::<Vec<_>>()
        .join(",");
    let values = ["0"; 32].join(",");
    connection
        .execute_batch(&format!(
            "CREATE TABLE compact({columns});
             WITH RECURSIVE rows(n) AS (
                 VALUES(1) UNION ALL SELECT n+1 FROM rows WHERE n<1000000
             ) INSERT INTO compact SELECT {values} FROM rows;"
        ))
        .unwrap();
    {
        let mut statement = connection.prepare("PRAGMA quick_check(1)").unwrap();
        assert_eq!(
            statement
                .query_row([], |row| row.get::<_, String>(0))
                .unwrap(),
            "ok"
        );
        assert!(statement.get_status(rusqlite::StatementStatus::VmStep) > 50_000_000);
    }
    let request = ValidationBudget {
        deadline: Instant::now() + Duration::from_secs(30),
        ..budget()
    };
    let db = Database::new(connection, &request).unwrap();
    assert_eq!(
        db.query("PRAGMA quick_check(1)", [], 2, 50_000_000, |row| {
            crate::database::text(row, 0)
        }),
        Err(StoreError::VmBudgetExceeded)
    );
    db.quick_check().unwrap();
    // The larger validation workload must still honor request cancellation.
    request.cancellation.cancel();
    assert_eq!(db.quick_check(), Err(StoreError::Cancelled));
}

#[test]
fn quick_check_does_not_expand_work_for_database_over_the_byte_limit() {
    let request = ValidationBudget {
        maximum_database_bytes: 1,
        ..budget()
    };
    let db = Database::new(fixture(""), &request).unwrap();
    assert_eq!(
        db.quick_check(),
        Err(StoreError::Host(
            arktrace_platform::HostError::LimitExceeded
        ))
    );
}
#[test]
fn active_sqlite_statement_observes_external_cancellation() {
    let request = budget();
    let db = Database::new(fixture(""), &request).unwrap();
    let token = request.cancellation.clone();
    let thread = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(5));
        token.cancel();
    });
    let sql = "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100000000) SELECT SUM(x) FROM n";
    assert_eq!(
        db.query(sql, [], 1, u64::MAX, |row| integer(row, 0)),
        Err(StoreError::Cancelled)
    );
    thread.join().unwrap();
}

#[test]
fn batch_memory_is_charged_before_row_mapping_and_resets_for_the_next_request() {
    use crate::query_resources::QueryResources;
    use std::{cell::Cell, sync::Arc};
    let request = budget();
    let connection = fixture("");
    let resources = Arc::new(
        QueryResources::new(ReadPoolLimits {
            maximum_workers: 1,
            maximum_decoded_bytes: 1000,
        })
        .unwrap(),
    );
    let mapped = Cell::new(false);
    let db = Database::borrow_readonly(&connection, &request)
        .unwrap()
        .with_resources(Some(resources.clone()));
    assert_eq!(
        db.query(
            "SELECT printf('%1000s','x')",
            [],
            1,
            DEFAULT_VM_BUDGET,
            |_| {
                mapped.set(true);
                Ok(())
            }
        ),
        Err(StoreError::DecodedBudgetExceeded)
    );
    assert!(
        !mapped.get(),
        "budget rejection must precede copying input strings"
    );
    assert_eq!(resources.used(), 0);
    drop(db);
    let normal = Database::borrow_readonly(&connection, &request).unwrap();
    assert_eq!(
        normal
            .query("SELECT 7", [], 1, DEFAULT_VM_BUDGET, |r| integer(r, 0))
            .unwrap(),
        [7]
    );
}

#[test]
fn batch_abort_interrupts_active_sql_without_cancelling_the_parent_or_next_request() {
    use crate::query_resources::QueryResources;
    use std::sync::Arc;
    let request = budget();
    let connection = fixture("");
    let resources = Arc::new(QueryResources::new(ReadPoolLimits::default()).unwrap());
    let db = Database::borrow_readonly(&connection, &request)
        .unwrap()
        .with_resources(Some(resources.clone()));
    let stop = resources.clone();
    let worker = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(5));
        stop.abort.cancel();
    });
    let sql = "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100000000) SELECT SUM(x) FROM n";
    assert_eq!(
        db.query(sql, [], 1, u64::MAX, |row| integer(row, 0)),
        Err(StoreError::Cancelled)
    );
    worker.join().unwrap();
    assert!(!request.cancellation.is_cancelled());
    drop(db);
    let normal = Database::borrow_readonly(&connection, &request).unwrap();
    assert_eq!(
        normal
            .query("SELECT 7", [], 1, DEFAULT_VM_BUDGET, |r| integer(r, 0))
            .unwrap(),
        [7]
    );
}
#[test]
fn public_errors_contain_no_sqlite_prose_or_user_path() {
    let request = budget();
    let db = Database::new(fixture(""), &request).unwrap();
    let error = db
        .query(
            "SELECT * FROM \"/Users/private/missing\"",
            [],
            1,
            DEFAULT_VM_BUDGET,
            |row| integer(row, 0),
        )
        .unwrap_err();
    let serialized = serde_json::to_string(&error).unwrap();
    assert!(!serialized.contains("stat"));
    assert!(!serialized.contains("no such column"));
    assert!(!serialized.contains('/'));
}

#[test]
fn partial_optional_stat_schema_preserves_trace_and_disables_event_counts() {
    let result = inspect(
        "CREATE TABLE stat(stat_type TEXT,count INTEGER);INSERT INTO stat VALUES('received',1)",
    )
    .unwrap();
    assert!(!result.event_source_counts_available);
    assert_eq!(result.duration_ns, 900);
    assert_eq!(
        result.data_quality.status,
        arktrace_contract::QualityStatus::Ok
    );
}

#[cfg(target_os = "macos")]
#[test]
fn native_descriptor_open_reads_exact_readonly_database_with_unicode_path() {
    use arktrace_platform::{HeldDirectory, HostError};
    use std::{
        fs::{self, DirBuilder, Permissions},
        os::unix::fs::{DirBuilderExt, PermissionsExt},
    };
    let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
        "arktrace-store-native-{}-空 格",
        std::process::id()
    ));
    DirBuilder::new().mode(0o700).create(&path).unwrap();
    let connection = Connection::open(path.join("数据库.db")).unwrap();
    connection.execute_batch(SCHEMA).unwrap();
    drop(connection);
    fs::set_permissions(path.join("数据库.db"), Permissions::from_mode(0o600)).unwrap();
    let directory = HeldDirectory::open_private(&path).unwrap();
    let writable = directory.open_file("数据库.db").unwrap();
    assert_eq!(
        inspect_snapshot(&writable, &budget()),
        Err(StoreError::Host(HostError::NotPrivate))
    );
    fs::set_permissions(path.join("数据库.db"), Permissions::from_mode(0o400)).unwrap();
    let held = directory.open_file("数据库.db").unwrap();
    assert_eq!(inspect_snapshot(&held, &budget()).unwrap().duration_ns, 900);
    assert_eq!(fs::read_dir(&path).unwrap().count(), 1);
    fs::remove_dir_all(path).unwrap();
}

#[test]
fn running_statement_stops_at_deadline() {
    let request = ValidationBudget {
        deadline: Instant::now() + Duration::from_millis(200),
        ..budget()
    };
    let db = Database::new(fixture(""), &request).unwrap();
    assert_eq!(db.query("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1000000000) SELECT SUM(x) FROM n",[],1,u64::MAX,|row|integer(row,0)),Err(StoreError::DeadlineExceeded));
}

#[cfg(target_os = "macos")]
#[test]
fn native_snapshot_refuses_wal_sidecars_and_excess_without_modifying_input() {
    use arktrace_platform::{HeldDirectory, IoBudget};
    use std::{
        fs::{self, DirBuilder, Permissions},
        os::unix::fs::{DirBuilderExt, PermissionsExt},
    };
    let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
        "arktrace-store-header-{}-空 格",
        std::process::id()
    ));
    DirBuilder::new().mode(0o700).create(&path).unwrap();
    let connection = Connection::open(path.join("database.db")).unwrap();
    connection.execute_batch(SCHEMA).unwrap();
    drop(connection);
    fs::set_permissions(path.join("database.db"), Permissions::from_mode(0o400)).unwrap();
    let directory = HeldDirectory::open_private(&path).unwrap();
    let held = directory.open_file("database.db").unwrap();
    let request = budget();
    let io = IoBudget {
        maximum_bytes: request.maximum_database_bytes,
        deadline: request.deadline,
        cancellation: request.cancellation.clone(),
    };
    let before = held.facts(&io).unwrap();
    let capped = ValidationBudget {
        maximum_database_bytes: 100,
        ..budget()
    };
    assert_eq!(
        inspect_snapshot(&held, &capped),
        Err(StoreError::Host(HostError::LimitExceeded))
    );
    assert_eq!(held.read_prefix(16, &io).unwrap(), b"SQLite format 3\0");
    assert_eq!(held.read_prefix(0, &io), Err(HostError::InvalidLimit));
    assert_eq!(
        held.read_prefix(1024 * 1024 + 1, &io),
        Err(HostError::InvalidLimit)
    );
    for suffix in ["-journal", "-wal", "-shm"] {
        fs::write(path.join(format!("database.db{suffix}")), b"sidecar").unwrap();
        assert_eq!(
            inspect_snapshot(&held, &request),
            Err(StoreError::Host(HostError::InvalidEvidence))
        );
        fs::remove_file(path.join(format!("database.db{suffix}"))).unwrap();
    }
    assert_eq!(before, held.facts(&io).unwrap());
    let mut bytes = fs::read(path.join("database.db")).unwrap();
    bytes[18] = 2;
    bytes[19] = 2;
    directory.write_new_readonly("wal.db", &bytes, &io).unwrap();
    let wal = directory.open_file("wal.db").unwrap();
    assert_eq!(
        inspect_snapshot(&wal, &request),
        Err(StoreError::InvalidDatabase)
    );
    assert_eq!(fs::read(path.join("wal.db")).unwrap(), bytes);
    fs::remove_dir_all(path).unwrap();
}

#[test]
fn runtime_identity_and_private_readonly_configuration_are_enforced() {
    let request = budget();
    let db = Database::new(fixture(""), &request).unwrap();
    let facts = db.runtime_facts().unwrap();
    assert_eq!(facts.version, SQLITE_VERSION);
    assert_eq!(facts.source_id, SQLITE_SOURCE_ID);
    assert!(
        facts
            .compile_options
            .iter()
            .any(|option| option == "THREADSAFE=1")
    );
    assert!(
        db.query(
            "CREATE TABLE forbidden(x)",
            [],
            1,
            DEFAULT_VM_BUDGET,
            |row| integer(row, 0)
        )
        .is_err()
    );
    assert!(
        db.query(
            "SELECT load_extension('/Users/private/library')",
            [],
            1,
            DEFAULT_VM_BUDGET,
            |row| integer(row, 0)
        )
        .is_err()
    );
    let invalid = ValidationBudget {
        maximum_database_bytes: 0,
        ..budget()
    };
    assert!(matches!(
        Database::new(fixture(""), &invalid),
        Err(StoreError::InvalidBudget)
    ));
}

pub(super) struct SQLiteDiskFixture {
    pub(super) connection: Option<Connection>,
    directory: std::path::PathBuf,
}
impl SQLiteDiskFixture {
    pub(super) fn new(extra: &str) -> Self {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let directory = std::env::temp_dir().join(format!(
            "arktrace-sqlite-unit-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        std::fs::create_dir(&directory).unwrap();
        let connection = Connection::open(directory.join("unit.db")).unwrap();
        connection.execute_batch(SCHEMA).unwrap();
        connection.execute_batch(extra).unwrap();
        Self {
            connection: Some(connection),
            directory,
        }
    }
}
impl Drop for SQLiteDiskFixture {
    fn drop(&mut self) {
        drop(self.connection.take());
        std::fs::remove_dir_all(&self.directory).unwrap();
    }
}

#[test]
fn index_preparation_creates_complete_applicable_closure_and_keeps_fingerprint() {
    let request = budget();
    let disk = SQLiteDiskFixture::new("");
    let connection = disk.connection.as_ref().unwrap();
    let db = Database::borrow_writable(connection, &request).unwrap();
    let before = db.inspect().unwrap();
    let mut events = Vec::new();
    let (inspection, names) = crate::indexes::prepare(&db, |event| events.push(event)).unwrap();
    assert_eq!(inspection, before);
    assert_eq!(names.len(), 17);
    assert_eq!(crate::indexes::validate(&db).unwrap(), names);
    assert_eq!(
        events
            .iter()
            .filter(|e| e.phase == crate::indexes::IndexPhase::Bootstrap)
            .count(),
        2
    );
    assert_eq!(
        events
            .iter()
            .filter(|e| e.phase == crate::indexes::IndexPhase::Ready)
            .count(),
        15
    );
    assert_eq!(
        db.inspect().unwrap().schema_fingerprint,
        before.schema_fingerprint
    );
}
#[test]
fn ready_index_validation_rejects_partial_unique_collated_descending_and_wrong_columns() {
    for replacement in [
        "CREATE INDEX arktrace_v1_process_pid ON process(ipid)",
        "CREATE UNIQUE INDEX arktrace_v1_process_pid ON process(pid)",
        "CREATE INDEX arktrace_v1_process_pid ON process(pid) WHERE pid>0",
        "CREATE INDEX arktrace_v1_process_pid ON process(pid DESC)",
        "CREATE INDEX arktrace_v1_process_pid ON process(pid COLLATE NOCASE)",
        "CREATE INDEX arktrace_v1_process_pid ON process(pid+1)",
    ] {
        let request = budget();
        let disk = SQLiteDiskFixture::new("");
        let connection = disk.connection.as_ref().unwrap();
        let db = Database::borrow_writable(connection, &request).unwrap();
        crate::indexes::prepare(&db, |_| {}).unwrap();
        db.execute("DROP INDEX arktrace_v1_process_pid", DEFAULT_VM_BUDGET)
            .unwrap();
        db.execute(replacement, DEFAULT_VM_BUDGET).unwrap();
        assert_eq!(
            crate::indexes::validate(&db),
            Err(StoreError::InvalidReadyIndexes),
            "{replacement}"
        );
    }
}
#[test]
fn optional_index_inputs_enable_full_closure_and_missing_required_inputs_fail() {
    let extra="ALTER TABLE sched_slice ADD COLUMN end_state TEXT;ALTER TABLE sched_slice ADD COLUMN priority INTEGER;
        ALTER TABLE thread_state ADD COLUMN cpu INTEGER;
        ALTER TABLE callstack ADD COLUMN cat TEXT;ALTER TABLE callstack ADD COLUMN depth INTEGER;
        ALTER TABLE callstack ADD COLUMN parent_id INTEGER;ALTER TABLE callstack ADD COLUMN cookie INTEGER;
        CREATE TABLE measure(filter_id INTEGER,ts INTEGER,value INTEGER);
        CREATE TABLE cpu_measure_filter(id INTEGER,name TEXT,cpu INTEGER);
        CREATE TABLE process_measure_filter(id INTEGER,name TEXT,ipid INTEGER);
        CREATE TABLE args(id INTEGER,key INTEGER,datatype INTEGER,value INTEGER,argset INTEGER);
        CREATE TABLE data_dict(id INTEGER,data TEXT);
        CREATE TABLE data_type(typeId INTEGER,desc TEXT);";
    let request = budget();
    let disk = SQLiteDiskFixture::new(extra);
    let connection = disk.connection.as_ref().unwrap();
    let db = Database::borrow_writable(connection, &request).unwrap();
    let (_, names) = crate::indexes::prepare(&db, |_| {}).unwrap();
    assert_eq!(names.len(), 28);
    let bad = SQLiteDiskFixture::new(
        "DROP TABLE sched_slice;CREATE TABLE sched_slice(id INTEGER,ts INTEGER,dur INTEGER,cpu INTEGER,itid INTEGER)",
    );
    let db = Database::borrow_writable(bad.connection.as_ref().unwrap(), &request).unwrap();
    assert_eq!(
        crate::indexes::prepare(&db, |_| {}),
        Err(StoreError::SchemaUnsupported)
    );
}
#[test]
fn index_transaction_rolls_back_before_returning_cancellation() {
    let request = budget();
    let disk = SQLiteDiskFixture::new("");
    let connection = disk.connection.as_ref().unwrap();
    let db = Database::borrow_writable(connection, &request).unwrap();
    let result = crate::indexes::prepare(&db, |event| {
        if event.phase == crate::indexes::IndexPhase::Ready && event.completed == 3 {
            request.cancellation.cancel();
        }
    });
    assert_eq!(result, Err(StoreError::Cancelled));
    assert!(connection.is_autocommit());
    let names = connection
        .prepare("SELECT name FROM sqlite_master WHERE type='index'")
        .unwrap()
        .query_map([], |row| row.get::<_, String>(0))
        .unwrap()
        .collect::<rusqlite::Result<Vec<_>>>()
        .unwrap();
    assert_eq!(names.len(), 2); // Previously committed bootstrap, no partial Ready transaction.
}

#[cfg(target_os = "macos")]
mod native_indexing {
    use super::*;
    use arktrace_platform::{HeldDirectory, IoBudget};
    use std::{
        fs::{self, DirBuilder, Permissions},
        os::unix::fs::{DirBuilderExt, PermissionsExt},
        path::PathBuf,
        sync::atomic::{AtomicU64, Ordering},
    };
    static NEXT: AtomicU64 = AtomicU64::new(0);
    struct Fixture(PathBuf);
    impl Fixture {
        fn new(extra: &str) -> Self {
            let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
                "arktrace-store-index-{}-{}-空 格",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            DirBuilder::new().mode(0o700).create(&path).unwrap();
            let conn = Connection::open(path.join("source.db")).unwrap();
            conn.execute_batch(SCHEMA).unwrap();
            conn.execute_batch(extra).unwrap();
            drop(conn);
            fs::set_permissions(path.join("source.db"), Permissions::from_mode(0o400)).unwrap();
            Self(path)
        }
        fn root(&self) -> HeldDirectory {
            HeldDirectory::open_private(&self.0).unwrap()
        }
        fn io(request: &ValidationBudget) -> IoBudget {
            IoBudget {
                maximum_bytes: request.maximum_database_bytes,
                deadline: request.deadline,
                cancellation: request.cancellation.clone(),
            }
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }
    fn batch() -> arktrace_contract::TraceRepositoryEventBatch {
        use arktrace_contract::*;
        let range = TraceTimeRange::query(0, 900).unwrap();
        TraceRepositoryEventBatch {
            cpu_slices: (0..20)
                .map(|i| CpuSliceQuery {
                    range,
                    cpu: Some(i % 2),
                    process_key: None,
                    pid: None,
                    thread_key: None,
                    tid: None,
                    limit: 8,
                })
                .collect(),
            densities: (0..8)
                .map(|i| TraceDensityQuery {
                    range,
                    source: TraceDensitySource::Cpu { cpu: i % 2 },
                    bucket_count: 8,
                })
                .collect(),
            threads: (0..4)
                .map(|_| ThreadQuery {
                    process_key: None,
                    pid: None,
                    thread_key: None,
                    tid: None,
                    name: None,
                    name_match: DirectoryNameMatch::Exact,
                    limit: 8,
                })
                .collect(),
            ..Default::default()
        }
    }
    fn deadline_after_seconds(seconds: i64) -> arktrace_platform::ContinuousDeadline {
        let mut value = arktrace_platform::ContinuousDeadline::now().unwrap();
        value.seconds += seconds;
        value
    }
    fn ready_reader(fixture: &Fixture) -> StoreReader {
        let root = fixture.root();
        let source = root.open_file("source.db").unwrap();
        let prepared = prepare_snapshot(
            &source,
            &root.create_private_child("deadline-stage").unwrap(),
            "ready.db",
            &budget(),
            |_| {},
        )
        .unwrap();
        StoreReader::open(std::sync::Arc::new(prepared.snapshot), &budget()).unwrap()
    }
    #[test]
    fn verified_snapshot_rejects_budget_cancellation_and_expiry_without_refreshing() {
        let fixture = Fixture::new("INSERT INTO sched_slice VALUES(1,100,20,0,NULL,NULL);");
        let reader = ready_reader(&fixture);
        reader.verify_snapshot(&budget()).unwrap();
        let verified = reader.verified_snapshot();
        let resources = || {
            std::sync::Arc::new(
                crate::query_resources::QueryResources::new(ReadPoolLimits::default()).unwrap(),
            )
        };
        let cancelled = budget();
        cancelled.cancellation.cancel();
        assert_eq!(
            reader.verify_snapshot(&cancelled),
            Err(StoreError::Cancelled)
        );
        assert_eq!(
            verified.open_worker(&cancelled, resources()).err(),
            Some(StoreError::Cancelled)
        );
        let expired = ValidationBudget {
            deadline: Instant::now() - Duration::from_millis(1),
            ..budget()
        };
        assert_eq!(
            reader.verify_snapshot(&expired),
            Err(StoreError::DeadlineExceeded)
        );
        assert_eq!(
            verified.open_worker(&expired, resources()).err(),
            Some(StoreError::DeadlineExceeded)
        );
        let small = ValidationBudget {
            maximum_database_bytes: 1,
            ..budget()
        };
        assert_eq!(
            reader.verify_snapshot(&small),
            Err(StoreError::Host(
                arktrace_platform::HostError::LimitExceeded
            ))
        );
        assert_eq!(
            verified.open_worker(&small, resources()).err(),
            Some(StoreError::Host(
                arktrace_platform::HostError::LimitExceeded
            ))
        );
        let worker = verified.open_worker(&budget(), resources()).unwrap();
        assert_eq!(worker.indexed_inspection(), reader.indexed_inspection());
        worker.close().unwrap();
        reader.verify_snapshot(&budget()).unwrap();
        reader.close().unwrap();
    }
    #[test]
    fn verified_snapshot_rejects_in_place_changes_even_after_readonly_mode_is_restored() {
        use std::os::unix::{fs::FileExt, fs::PermissionsExt};
        let fixture = Fixture::new("INSERT INTO sched_slice VALUES(1,100,20,0,NULL,NULL);");
        let reader = ready_reader(&fixture);
        reader.verify_snapshot(&budget()).unwrap();
        let verified = reader.verified_snapshot();
        let snapshot = reader.snapshot_for_test();
        let path = snapshot.path();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        let file = fs::OpenOptions::new().write(true).open(&path).unwrap();
        file.write_all_at(&[0], 24).unwrap();
        file.sync_all().unwrap();
        drop(file);
        fs::set_permissions(&path, fs::Permissions::from_mode(0o400)).unwrap();
        assert_eq!(
            reader.verify_snapshot(&budget()),
            Err(StoreError::Host(arktrace_platform::HostError::Changed))
        );
        assert_eq!(
            verified
                .open_worker(
                    &budget(),
                    std::sync::Arc::new(
                        crate::query_resources::QueryResources::new(ReadPoolLimits::default())
                            .unwrap(),
                    ),
                )
                .err(),
            Some(StoreError::Host(arktrace_platform::HostError::Changed))
        );
        reader.close().unwrap();
    }
    #[test]
    fn completed_slot_deadline_is_not_rechecked_while_a_later_slot_waits() {
        let fixture = Fixture::new("INSERT INTO sched_slice VALUES(1,100,20,0,NULL,NULL);");
        let reader = ready_reader(&fixture);
        let mut queries = batch();
        queries.cpu_slices.truncate(2);
        queries.densities.clear();
        queries.threads.clear();
        let first_deadline = deadline_after_seconds(2);
        let deadlines = [Some(first_deadline), Some(deadline_after_seconds(7))];
        let result = crate::read_pool::run_inner_with_deadlines(
            reader.verified_snapshot(),
            &queries,
            Some(&deadlines),
            &budget(),
            ReadPoolLimits {
                maximum_workers: 1,
                ..Default::default()
            },
            &|index| {
                if index == 1 {
                    while !first_deadline.expired().unwrap() {
                        std::thread::yield_now();
                    }
                }
            },
        )
        .unwrap();
        assert!(first_deadline.expired().unwrap());
        assert_eq!(result.statistics.completed_queries, 2);
        assert_eq!(result.statistics.workers_opened, 1);
        assert_eq!(result.statistics.connections_closed, 1);
        assert_eq!(result.result.cpu_slices[0].items.len(), 1);
        assert!(result.result.cpu_slices[1].items.is_empty());
    }
    #[test]
    fn expired_slot_rejects_available_queries_but_preserves_unavailable_error_timing() {
        use arktrace_platform::ContinuousDeadline;
        let expired = Some(ContinuousDeadline {
            seconds: 0,
            attoseconds: 0,
        });
        for (extra, available) in [
            ("", false),
            (
                "INSERT INTO sched_slice VALUES(1,100,20,0,NULL,NULL);",
                true,
            ),
        ] {
            let fixture = Fixture::new(extra);
            let reader = ready_reader(&fixture);
            let mut queries = batch();
            queries.cpu_slices.truncate(1);
            queries.densities.clear();
            queries.threads.clear();
            let result = reader.event_batch_with_deadlines(
                &queries,
                &[expired],
                &budget(),
                ReadPoolLimits::default(),
            );
            if available {
                assert_eq!(result.unwrap_err(), StoreError::DeadlineExceeded);
            } else {
                assert!(result.unwrap().result.cpu_slices[0].items.is_empty());
            }
            queries.cpu_slices.clear();
            queries.densities = batch().densities[..1].to_vec();
            assert_eq!(
                reader
                    .event_batch_with_deadlines(
                        &queries,
                        &[expired],
                        &budget(),
                        ReadPoolLimits::default()
                    )
                    .unwrap_err(),
                StoreError::DeadlineExceeded
            );
            // A failed slot does not cancel the caller or poison its next pool.
            queries.densities.clear();
            queries.threads = batch().threads[..1].to_vec();
            let next = reader
                .event_batch_with_deadlines(&queries, &[None], &budget(), ReadPoolLimits::default())
                .unwrap();
            assert_eq!(next.statistics.completed_queries, 1);
            assert_eq!(next.statistics.connections_closed, 1);
        }
    }
    #[test]
    fn viewport_scope_deadline_reaches_density_workers_and_restores_for_retry() {
        let fixture = Fixture::new("INSERT INTO sched_slice VALUES(1,100,20,0,NULL,NULL);");
        let reader = ready_reader(&fixture);
        let mut queries = batch();
        queries.cpu_slices.clear();
        queries.threads.clear();
        queries.densities.truncate(2);
        let past = Some(arktrace_platform::ContinuousDeadline {
            seconds: 0,
            attoseconds: 0,
        });
        assert_eq!(
            reader
                .with_query_deadline(past, || {
                    reader.event_batch(&queries, &budget(), ReadPoolLimits::default())
                })
                .unwrap_err(),
            StoreError::DeadlineExceeded
        );
        let retry = reader
            .event_batch(&queries, &budget(), ReadPoolLimits::default())
            .unwrap();
        assert_eq!(retry.result.densities.len(), 2);
        assert_eq!(retry.statistics.completed_queries, 2);
        assert_eq!(
            retry.statistics.workers_opened,
            retry.statistics.connections_closed
        );
    }
    #[test]
    fn scoped_deadline_restores_on_error_panic_and_nested_nil_override() {
        use arktrace_platform::ContinuousDeadline;
        let fixture = Fixture::new("INSERT INTO thread VALUES(1,11,'t',100,NULL);");
        let reader = ready_reader(&fixture);
        let past = Some(ContinuousDeadline {
            seconds: 0,
            attoseconds: 0,
        });
        let query = &batch().threads[0];
        reader
            .with_query_deadline(past, || {
                assert_eq!(
                    reader.threads(query, &budget()).unwrap_err(),
                    StoreError::DeadlineExceeded
                );
                assert_eq!(
                    reader
                        .with_query_deadline(None, || reader.threads(query, &budget()))
                        .unwrap()
                        .items
                        .len(),
                    1
                );
                assert_eq!(
                    reader.threads(query, &budget()).unwrap_err(),
                    StoreError::DeadlineExceeded
                );
                Ok(())
            })
            .unwrap();
        assert_eq!(reader.threads(query, &budget()).unwrap().items.len(), 1);
        assert!(
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                let _ = reader.with_query_deadline(past, || -> Result<(), StoreError> {
                    panic!("deadline scope fault");
                });
            }))
            .is_err()
        );
        assert_eq!(reader.threads(query, &budget()).unwrap().items.len(), 1);
    }
    #[test]
    fn deadline_admission_rejects_mismatched_slots_and_noncanonical_epoch() {
        let fixture = Fixture::new("");
        let reader = ready_reader(&fixture);
        let queries = batch();
        let valid = vec![None; 32];
        assert_eq!(
            reader
                .event_batch_with_deadlines(
                    &queries,
                    &valid[..31],
                    &budget(),
                    ReadPoolLimits::default()
                )
                .unwrap_err(),
            StoreError::InvalidBudget
        );
        let mut invalid = valid.clone();
        invalid[31] = Some(arktrace_platform::ContinuousDeadline {
            seconds: 1,
            attoseconds: -1,
        });
        assert_eq!(
            reader
                .event_batch_with_deadlines(
                    &queries,
                    &invalid,
                    &budget(),
                    ReadPoolLimits::default()
                )
                .unwrap_err(),
            StoreError::InvalidBudget
        );
        let result = reader
            .event_batch_with_deadlines(&queries, &valid, &budget(), ReadPoolLimits::default())
            .unwrap();
        assert_eq!(result.statistics.completed_queries, 32);
        assert_eq!(result.statistics.connections_closed, 3);
    }
    #[test]
    fn continuous_deadline_interrupts_running_sql_and_removes_progress_handler() {
        let request = budget();
        let db = Database::new(fixture(""), &request).unwrap();
        let mut deadline = arktrace_platform::ContinuousDeadline::now().unwrap();
        // One second permits admission even under load; the recursive aggregate
        // has enough work to remain in SQLite until the progress check fires.
        deadline.seconds += 1;
        let timed = db
            .summary_request(100_000_000_000)
            .unwrap()
            .with_query_deadline(Some(deadline));
        let before = timed.remaining_vm_work_for_test();
        let result = timed.query("WITH RECURSIVE n(v) AS (VALUES(0) UNION ALL SELECT v+1 FROM n WHERE v<1000000000) SELECT sum(v) FROM n", [], 1, 100_000_000_000, |row| integer(row, 0));
        assert_eq!(result, Err(StoreError::DeadlineExceeded));
        assert!(
            timed.remaining_vm_work_for_test() < before,
            "SQLite executed VM steps before the interrupt"
        );
        drop(timed);
        assert_eq!(
            db.query("SELECT 7", [], 1, DEFAULT_VM_BUDGET, |row| integer(row, 0))
                .unwrap(),
            [7]
        );
    }
    #[test]
    fn scalar_deadlines_keep_directory_nil_and_summary_validation_order() {
        use arktrace_contract::*;
        let fixture = Fixture::new("INSERT INTO process VALUES(1,10,'p',100);");
        let reader = ready_reader(&fixture);
        let past = Some(arktrace_platform::ContinuousDeadline {
            seconds: 0,
            attoseconds: 1,
        });
        let process = ProcessQuery {
            process_key: None,
            pid: None,
            name: None,
            name_match: DirectoryNameMatch::Exact,
            limit: 1,
        };
        assert_eq!(
            reader
                .with_query_deadline(past, || reader.processes(&process, &budget()))
                .unwrap_err(),
            StoreError::DeadlineExceeded
        );
        assert_eq!(
            reader
                .with_query_deadline(None, || reader.processes(&process, &budget()))
                .unwrap()
                .items
                .len(),
            1
        );
        let summary = TraceSummaryQuery {
            range: None,
            maximum_rows_per_section: 1,
            maximum_events_per_section: 1,
        };
        assert_eq!(
            reader
                .with_query_deadline(past, || reader.summary_facts(&summary, &budget()))
                .unwrap_err(),
            StoreError::DeadlineExceeded
        );
        let invalid = TraceSummaryQuery {
            range: Some(TraceTimeRange::query(0, 901).unwrap()),
            ..summary
        };
        assert_eq!(
            reader
                .with_query_deadline(past, || reader.summary_facts(&invalid, &budget()))
                .unwrap_err(),
            StoreError::InvalidSummaryQuery
        );
        assert_eq!(
            reader
                .summary_facts(&summary, &budget())
                .unwrap()
                .process_count
                .value,
            1
        );
    }
    #[test]
    fn frame_and_argument_expired_deadlines_respect_capability_before_sql() {
        use arktrace_contract::*;
        let enabled = "INSERT INTO process VALUES(1,10,'p',100);
            CREATE TABLE frame_slice(id INTEGER,ts INTEGER,dur INTEGER,vsync INTEGER,ipid INTEGER,type INTEGER,flag INTEGER);
            INSERT INTO frame_slice VALUES(1,100,20,1,1,0,1);
            ALTER TABLE callstack ADD COLUMN argsetid INTEGER;
            INSERT INTO callstack VALUES(1,100,20,0,'slice',7);
            CREATE TABLE args(key INTEGER,datatype INTEGER,value INTEGER,argset INTEGER);
            CREATE TABLE data_dict(id INTEGER,data TEXT);
            CREATE TABLE data_type(typeId INTEGER,desc TEXT);
            INSERT INTO data_dict VALUES(1,'key'),(2,'text');
            INSERT INTO data_type VALUES(1,'string');
            INSERT INTO args VALUES(1,1,2,7);";
        for (extra, available) in [("", false), (enabled, true)] {
            let fixture = Fixture::new(extra);
            let reader = ready_reader(&fixture);
            let past = Some(arktrace_platform::ContinuousDeadline {
                seconds: 0,
                attoseconds: 0,
            });
            let frame = TraceFrameQuery {
                range: TraceTimeRange::query(0, 900).unwrap(),
                process_key: None,
                limit: 1,
            };
            let argument = TraceArgumentQuery {
                arg_set_id: 7,
                limit: 64,
            };
            let frames = reader.with_query_deadline(past, || reader.frames(&frame, &budget()));
            let args = reader.with_query_deadline(past, || reader.arguments(&argument, &budget()));
            if available {
                assert_eq!(frames.unwrap_err(), StoreError::DeadlineExceeded);
                assert_eq!(args.unwrap_err(), StoreError::DeadlineExceeded);
                assert_eq!(reader.frames(&frame, &budget()).unwrap().items.len(), 1);
                assert_eq!(
                    reader.arguments(&argument, &budget()).unwrap().items.len(),
                    1
                );
            } else {
                assert!(!frames.unwrap().capability_available);
                assert!(!args.unwrap().capability_available);
            }
        }
    }
    #[test]
    fn native_descriptor_reopens_are_stable_under_concurrent_worker_churn() {
        use std::sync::{Arc, Barrier};
        let fixture = Fixture::new("");
        let source = Arc::new(fixture.root().open_file("source.db").unwrap());
        let request = budget();
        let before = source.facts(&Fixture::io(&request)).unwrap();
        let start = Barrier::new(3);
        let errors = std::thread::scope(|scope| {
            let mut handles = Vec::new();
            for _ in 0..3 {
                let source = source.clone();
                let start = &start;
                handles.push(scope.spawn(move || {
                    start.wait();
                    let mut errors = Vec::new();
                    for _ in 0..512 {
                        let result = (|| {
                            let conn = open_snapshot_connection(&source, &budget())?;
                            let value: i64 = conn
                                .query_row("SELECT count(*) FROM trace_range", [], |row| row.get(0))
                                .map_err(crate::database::sqlite_error)?;
                            conn.close().map_err(|_| StoreError::CleanupFailed)?;
                            if value != 1 {
                                return Err(StoreError::InvalidDatabase);
                            }
                            source.verify()?;
                            Ok(())
                        })();
                        if let Err(error) = result {
                            errors.push(error);
                        }
                    }
                    errors
                }));
            }
            handles
                .into_iter()
                .flat_map(|handle| handle.join().unwrap())
                .collect::<Vec<_>>()
        });
        assert!(errors.is_empty(), "descriptor reopens failed: {errors:?}");
        assert_eq!(source.facts(&Fixture::io(&request)).unwrap(), before);
    }
    #[test]
    fn native_read_pool_preserves_all_32_positions_and_closes_on_success_and_panic() {
        use std::sync::Arc;
        let fixture = Fixture::new(
            "INSERT INTO process VALUES(1,10,'p',100);
            INSERT INTO thread VALUES(1,11,'t',100,1);
            INSERT INTO sched_slice VALUES(1,100,20,0,1,1),(2,200,20,1,1,1);",
        );
        let root = fixture.root();
        let source = root.open_file("source.db").unwrap();
        let request = budget();
        let prepared = prepare_snapshot(
            &source,
            &root.create_private_child("stage").unwrap(),
            "ready.db",
            &request,
            |_| {},
        )
        .unwrap();
        let snapshot = Arc::new(prepared.snapshot);
        let reader = StoreReader::open(snapshot.clone(), &request).unwrap();
        let before = snapshot.facts(&Fixture::io(&request)).unwrap();
        let batch = batch();
        let serial = reader
            .event_batch(
                &batch,
                &request,
                ReadPoolLimits {
                    maximum_workers: 1,
                    ..Default::default()
                },
            )
            .unwrap();
        let parallel = reader
            .event_batch(&batch, &request, ReadPoolLimits::default())
            .unwrap();
        assert_eq!(serial.result, parallel.result);
        assert_eq!(parallel.statistics.workers_opened, 3);
        assert_eq!(parallel.statistics.connections_closed, 3);
        assert_eq!(parallel.statistics.completed_queries, 32);
        assert!((1..=3).contains(&parallel.statistics.peak_active_queries));
        for (i, page) in parallel.result.cpu_slices.iter().enumerate() {
            assert_eq!(
                page.items.iter().map(|v| v.key.row_id).collect::<Vec<_>>(),
                [1 + i as i64 % 2]
            );
        }
        assert_eq!(
            crate::read_pool::run_inner(
                reader.verified_snapshot(),
                &batch,
                &request,
                ReadPoolLimits::default(),
                &|index| {
                    if index == 0 {
                        panic!("deliberate worker fault after opening owned connection");
                    }
                }
            )
            .unwrap_err(),
            StoreError::WorkerFailed
        );
        // The same request token and primary connection are still usable.
        assert!(!request.cancellation.is_cancelled());
        let cancelled_panic = budget();
        assert_eq!(
            reader
                .with_database(&cancelled_panic, |_| crate::read_pool::run_inner(
                    reader.verified_snapshot(),
                    &batch,
                    &cancelled_panic,
                    ReadPoolLimits::default(),
                    &|index| {
                        if index == 0 {
                            cancelled_panic.cancellation.cancel();
                            panic!("worker fault racing caller cancellation");
                        }
                    }
                ))
                .unwrap_err(),
            StoreError::WorkerFailed
        );
        let cancelled_cleanup = budget();
        assert_eq!(
            reader.with_database(&cancelled_cleanup, |_| {
                cancelled_cleanup.cancellation.cancel();
                Err::<(), _>(StoreError::CleanupFailed)
            }),
            Err(StoreError::CleanupFailed)
        );
        assert_eq!(
            reader
                .event_batch(&batch, &request, ReadPoolLimits::default())
                .unwrap()
                .result,
            serial.result
        );
        assert_eq!(snapshot.facts(&Fixture::io(&request)).unwrap(), before);
        reader.close().unwrap();
    }

    #[test]
    fn native_read_pool_memory_and_cancellation_failures_leave_next_request_unchanged() {
        use std::sync::Arc;
        let fixture = Fixture::new("");
        let root = fixture.root();
        let request = budget();
        let source = root.open_file("source.db").unwrap();
        let prepared = prepare_snapshot(
            &source,
            &root.create_private_child("stage").unwrap(),
            "ready.db",
            &request,
            |_| {},
        )
        .unwrap();
        let reader = StoreReader::open(Arc::new(prepared.snapshot), &request).unwrap();
        let batch = batch();
        let before = reader
            .event_batch(&batch, &request, ReadPoolLimits::default())
            .unwrap()
            .result;
        assert_eq!(
            reader
                .event_batch(
                    &batch,
                    &request,
                    ReadPoolLimits {
                        maximum_workers: 3,
                        maximum_decoded_bytes: 1
                    }
                )
                .unwrap_err(),
            StoreError::DecodedBudgetExceeded
        );
        assert_eq!(
            reader
                .event_batch(&batch, &request, ReadPoolLimits::default())
                .unwrap()
                .result,
            before
        );
        let cancelled = budget();
        cancelled.cancellation.cancel();
        assert_eq!(
            reader
                .event_batch(&batch, &cancelled, ReadPoolLimits::default())
                .unwrap_err(),
            StoreError::Cancelled
        );
        assert_eq!(
            reader
                .event_batch(&batch, &request, ReadPoolLimits::default())
                .unwrap()
                .result,
            before
        );
        // Cancel after a worker has entered a real typed query, before SQL
        // steps; the pool drains every other worker before returning.
        let active = budget();
        assert_eq!(
            crate::read_pool::run_inner(
                reader.verified_snapshot(),
                &batch,
                &active,
                ReadPoolLimits::default(),
                &|index| {
                    if index == 0 {
                        active.cancellation.cancel();
                    }
                }
            )
            .unwrap_err(),
            StoreError::Cancelled
        );
        assert_eq!(
            reader
                .event_batch(&batch, &request, ReadPoolLimits::default())
                .unwrap()
                .result,
            before
        );
        reader.close().unwrap();
    }
    #[test]
    fn real_disk_preparation_preserves_source_closes_sqlite_and_seals_readonly() {
        let fixture = Fixture::new("");
        let root = fixture.root();
        let source = root.open_file("source.db").unwrap();
        let stage = root.create_private_child("stage").unwrap();
        let request = budget();
        let before = source.facts(&Fixture::io(&request)).unwrap();
        let prepared = prepare_snapshot(&source, &stage, "数据库.db", &request, |_| {}).unwrap();
        assert_eq!(prepared.preparation.applicable_index_names.len(), 17);
        assert_eq!(prepared.preparation.upstream_database_sha256, before.sha256);
        assert_ne!(prepared.preparation.prepared_database_sha256, before.sha256);
        assert_eq!(source.facts(&Fixture::io(&request)).unwrap(), before);
        assert_eq!(
            fs::metadata(stage.path().join("数据库.db"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o400
        );
        assert_eq!(fs::read_dir(stage.path()).unwrap().count(), 1);
        assert_eq!(
            inspect_snapshot(&prepared.snapshot, &request).unwrap(),
            prepared.preparation.inspection
        );
    }
    #[test]
    fn restored_path_cannot_hide_sqlite_opening_the_foreign_inode() {
        let fixture = Fixture::new("");
        let root = fixture.root();
        let source = root.open_file("source.db").unwrap();
        let request = budget();
        let io = Fixture::io(&request);
        let stage = root.create_private_child("stage").unwrap();
        let (owned, _) = stage
            .copy_writable_candidate(&source, "candidate.db", &io)
            .unwrap();
        let (foreign, _) = stage
            .copy_writable_candidate(&source, "foreign.db", &io)
            .unwrap();
        let foreign_before = fs::read(stage.path().join("foreign.db")).unwrap();
        fs::rename(
            stage.path().join("candidate.db"),
            stage.path().join("original.db"),
        )
        .unwrap();
        fs::rename(
            stage.path().join("foreign.db"),
            stage.path().join("candidate.db"),
        )
        .unwrap();
        let wrong = Connection::open_with_flags(
            stage.path().join("candidate.db"),
            rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE | rusqlite::OpenFlags::SQLITE_OPEN_NOFOLLOW,
        )
        .unwrap();
        fs::rename(
            stage.path().join("candidate.db"),
            stage.path().join("foreign.db"),
        )
        .unwrap();
        fs::rename(
            stage.path().join("original.db"),
            stage.path().join("candidate.db"),
        )
        .unwrap();
        // The pathname is exactly right again; only SQLite's actual fd is wrong.
        assert_eq!(
            owned.verify_sqlite_connection(&wrong, &io),
            Err(HostError::IdentityMismatch)
        );
        drop(wrong);
        assert_eq!(
            fs::read(stage.path().join("foreign.db")).unwrap(),
            foreign_before
        );
        foreign.revalidate(&io).unwrap();
        owned
            .with_sqlite_connection(&io, |_| Ok::<_, HostError>(()))
            .unwrap();
    }
    #[test]
    fn native_cancellation_keeps_disposable_candidate_writable_and_no_ready_result() {
        let fixture = Fixture::new("");
        let root = fixture.root();
        let source = root.open_file("source.db").unwrap();
        let request = budget();
        let before = source.facts(&Fixture::io(&request)).unwrap();
        let stage = root.create_private_child("stage").unwrap();
        let result = prepare_snapshot(&source, &stage, "candidate.db", &request, |event| {
            if event.phase == IndexPhase::Ready && event.completed == 2 {
                request.cancellation.cancel();
            }
        });
        assert!(matches!(result, Err(StoreError::Cancelled)));
        assert_eq!(
            fs::metadata(stage.path().join("candidate.db"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        assert_eq!(fs::read_dir(stage.path()).unwrap().count(), 1);
        assert_eq!(source.facts(&Fixture::io(&budget())).unwrap(), before);
        let conn = Connection::open(stage.path().join("candidate.db")).unwrap();
        assert_eq!(
            conn.query_row("PRAGMA quick_check", [], |row| row.get::<_, String>(0))
                .unwrap(),
            "ok"
        );
        let count = conn
            .query_row(
                "SELECT count(*) FROM sqlite_master WHERE type='index'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap();
        assert_eq!(count, 2);
        drop(conn);
    }
    #[test]
    fn page_count_budget_exhaustion_rolls_back_and_never_seals_partial_indexes() {
        let fixture = Fixture::new(
            "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<4000)
            INSERT INTO process SELECT x,x,'large',100 FROM n;",
        );
        let root = fixture.root();
        let source = root.open_file("source.db").unwrap();
        let stage = root.create_private_child("stage").unwrap();
        let request = ValidationBudget {
            maximum_database_bytes: source.snapshot().byte_count,
            ..budget()
        };
        let result = prepare_snapshot(&source, &stage, "candidate.db", &request, |_| {});
        assert!(
            matches!(result, Err(StoreError::SQLite { code: 13 })),
            "{:?}",
            result.err()
        );
        assert_eq!(
            fs::metadata(stage.path().join("candidate.db"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        assert!(
            fs::metadata(stage.path().join("candidate.db"))
                .unwrap()
                .len()
                <= request.maximum_database_bytes
        );
        let conn = Connection::open(stage.path().join("candidate.db")).unwrap();
        assert_eq!(
            conn.query_row("PRAGMA quick_check", [], |row| row.get::<_, String>(0))
                .unwrap(),
            "ok"
        );
        drop(conn);
    }

    #[test]
    fn panic_during_index_transaction_closes_connection_and_owner_cleanup_removes_candidate() {
        use arktrace_platform::{OwnerKind, OwnerStore};
        let fixture = Fixture::new("");
        let root = fixture.root();
        let source = root.open_file("source.db").unwrap();
        let request = budget();
        let io = Fixture::io(&request);
        let before = source.facts(&io).unwrap();
        let owner_root = root.create_private_child("owned-stage").unwrap();
        let owners = OwnerStore::open(&owner_root, &root).unwrap();
        let mut building = owners.create(OwnerKind::Building, &io).unwrap();
        let directory = building.directory().clone();
        let panic = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            prepare_snapshot(&source, &directory, "candidate.db", &request, |event| {
                if event.phase == IndexPhase::Ready && event.completed == 3 {
                    panic!("injected index consumer panic");
                }
            })
        }));
        assert!(panic.is_err());
        assert_eq!(fs::read_dir(directory.path()).unwrap().count(), 1);
        assert_eq!(
            fs::metadata(directory.path().join("candidate.db"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        let conn = Connection::open(directory.path().join("candidate.db")).unwrap();
        assert_eq!(
            conn.query_row("PRAGMA quick_check", [], |row| row.get::<_, String>(0))
                .unwrap(),
            "ok"
        );
        assert_eq!(
            conn.query_row(
                "SELECT count(*) FROM sqlite_master WHERE type='index'",
                [],
                |row| row.get::<_, i64>(0)
            )
            .unwrap(),
            2
        );
        drop(conn);
        building.cleanup(&io).unwrap();
        assert!(!directory.path().exists());
        assert_eq!(source.facts(&io).unwrap(), before);
    }

    #[test]
    fn missing_required_column_and_existing_destination_never_produce_prepared_snapshot() {
        let fixture = Fixture::new("ALTER TABLE sched_slice DROP COLUMN ipid;");
        let root = fixture.root();
        let source = root.open_file("source.db").unwrap();
        let stage = root.create_private_child("stage").unwrap();
        let request = budget();
        let io = Fixture::io(&request);
        let before = source.facts(&io).unwrap();
        assert!(matches!(
            prepare_snapshot(&source, &stage, "candidate.db", &request, |_| {}),
            Err(StoreError::SchemaUnsupported)
        ));
        let existing = fs::read(stage.path().join("candidate.db")).unwrap();
        assert!(matches!(
            prepare_snapshot(&source, &stage, "candidate.db", &request, |_| {}),
            Err(StoreError::Host(HostError::AlreadyExists))
        ));
        assert_eq!(
            fs::read(stage.path().join("candidate.db")).unwrap(),
            existing
        );
        assert_eq!(
            fs::metadata(stage.path().join("candidate.db"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        assert_eq!(source.facts(&io).unwrap(), before);
    }
}
