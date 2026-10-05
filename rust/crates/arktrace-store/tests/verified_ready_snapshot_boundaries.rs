#![cfg(all(target_os = "macos", target_arch = "aarch64"))]

//! Synthetic schema-4 SQLite fixtures exercising the public Ready-reader fast
//! verification path after successful open. No Engine/Controller or user trace.
use arktrace_contract::{CpuCatalogQuery, SCHEMA_ADAPTER_VERSION, TraceTimeRange};
use arktrace_platform::{CancellationToken, HeldDirectory, HeldFile, HostError};
use arktrace_store::{
    IndexedDatabaseInspection, StoreError, StoreReader, ValidationBudget, prepare_snapshot,
};
use rusqlite::Connection;
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{
    error::Error,
    fs::{self, DirBuilder, OpenOptions, Permissions},
    io::Write,
    os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, Instant},
};

type TestResult = Result<(), Box<dyn Error>>;
const SCHEMA: &str = "
CREATE TABLE trace_range(start_ts INTEGER,end_ts INTEGER);
INSERT INTO trace_range VALUES(100,1000);
CREATE TABLE process(ipid INTEGER,pid INTEGER,name TEXT,start_ts INTEGER);
INSERT INTO process VALUES(1,11,'original',100);
CREATE TABLE thread(itid INTEGER,tid INTEGER,name TEXT,start_ts INTEGER,ipid INTEGER);
INSERT INTO thread VALUES(1,12,'thread',100,1);
CREATE TABLE sched_slice(id INTEGER,ts INTEGER,dur INTEGER,cpu INTEGER,itid INTEGER,ipid INTEGER);
INSERT INTO sched_slice VALUES(1,200,10,7,1,1);
CREATE TABLE thread_state(id INTEGER,ts INTEGER,dur INTEGER,itid INTEGER,state TEXT);
CREATE TABLE callstack(id INTEGER,ts INTEGER,dur INTEGER,callid INTEGER,name TEXT);";

#[derive(Clone, Serialize)]
struct Bytes {
    byte_count: u64,
    sha256: String,
}
fn bytes(path: &Path) -> Result<Bytes, Box<dyn Error>> {
    let data = fs::read(path)?;
    Ok(Bytes {
        byte_count: data.len() as u64,
        sha256: format!("{:x}", Sha256::digest(data)),
    })
}
#[derive(Serialize)]
struct CaseEvidence {
    case: String,
    source: Bytes,
    original_ready: Bytes,
    errors: Vec<StoreError>,
    cached_inspection_unchanged: bool,
    normal_query_before: Vec<i64>,
    normal_query_after: Option<Vec<i64>>,
    replacement: Option<Bytes>,
    replacement_inspection_duration: Option<i64>,
    close: Result<(), StoreError>,
}
#[derive(Serialize)]
struct Observation {
    group: String,
    synthetic_sqlite: bool,
    actual_public_verify_snapshot_calls: usize,
    original_child_budget_seconds: u64,
    cases: Vec<CaseEvidence>,
}

struct Group {
    name: &'static str,
    root: PathBuf,
    deadline: Instant,
    retain: bool,
}
impl Group {
    fn new(name: &'static str) -> Result<Self, Box<dyn Error>> {
        let deadline = Instant::now() + Duration::from_secs(8);
        let configured = std::env::var_os("ARKTRACE_N20_FIXTURE_ROOT");
        let retain = configured.is_some();
        let parent = match configured {
            Some(path) => PathBuf::from(path),
            None => std::env::temp_dir().canonicalize()?,
        };
        let root = if retain {
            parent.join(name)
        } else {
            parent.join(format!("arktrace-n20-{}-{name}", std::process::id()))
        };
        DirBuilder::new().mode(0o700).create(&root)?;
        Ok(Self {
            name,
            root,
            deadline,
            retain,
        })
    }
    fn budget(&self) -> ValidationBudget {
        // Every prepare/open/verify/query in this group uses this same Instant.
        ValidationBudget {
            maximum_database_bytes: 4 * 1024 * 1024,
            deadline: self.deadline,
            cancellation: CancellationToken::default(),
        }
    }
    fn check(&self) {
        assert!(
            Instant::now() < self.deadline,
            "original child group budget expired"
        );
    }
    fn emit(&self, calls: usize, cases: Vec<CaseEvidence>) -> TestResult {
        self.check();
        let observation = Observation {
            group: self.name.to_owned(),
            synthetic_sqlite: true,
            actual_public_verify_snapshot_calls: calls,
            original_child_budget_seconds: 8,
            cases,
        };
        let data = serde_json::to_vec(&observation)?;
        assert!(data.len() <= 64 * 1024);
        if let Some(parent) = std::env::var_os("ARKTRACE_N20_OBSERVATION_ROOT") {
            let path = PathBuf::from(parent).join(format!("{}.json", self.name));
            let mut file = OpenOptions::new()
                .create_new(true)
                .write(true)
                .mode(0o600)
                .open(path)?;
            file.write_all(&data)?;
            file.sync_all()?;
            drop(file);
        }
        println!(
            "N20_OBSERVATION {} {:x} {}",
            self.name,
            Sha256::digest(&data),
            data.len()
        );
        self.check();
        Ok(())
    }
}
impl Drop for Group {
    fn drop(&mut self) {
        if !self.retain
            && let Err(error) = fs::remove_dir_all(&self.root)
        {
            eprintln!("N20 owned temporary-fixture cleanup failed: {error}");
        }
    }
}
struct Ready {
    root: HeldDirectory,
    stage_path: PathBuf,
    snapshot: Arc<HeldFile>,
    reader: StoreReader,
    cached: IndexedDatabaseInspection,
    source_path: PathBuf,
    source: Bytes,
    original_ready: Bytes,
}
fn query_cpus(reader: &StoreReader, group: &Group) -> Result<Vec<i64>, StoreError> {
    let page = reader.cpu_catalog(
        &CpuCatalogQuery {
            range: TraceTimeRange::query(0, 900).expect("valid synthetic relative range"),
            limit: 4,
            activity_limit: 8,
        },
        &group.budget(),
    )?;
    Ok(page.cpus.items.iter().map(|item| item.cpu).collect())
}
fn ready(group: &Group, name: &str) -> Result<Ready, Box<dyn Error>> {
    group.check();
    let path = group.root.join(name);
    DirBuilder::new().mode(0o700).create(&path)?;
    let source_path = path.join("source.db");
    let connection = Connection::open(&source_path)?;
    connection.execute_batch(SCHEMA)?;
    connection.close().map_err(|(_, error)| error)?;
    fs::set_permissions(&source_path, Permissions::from_mode(0o400))?;
    let source = bytes(&source_path)?;
    let root = HeldDirectory::open_private(&path)?;
    let source_file = root.open_file("source.db")?;
    let stage = root.create_private_child("stage")?;
    let prepared = prepare_snapshot(&source_file, &stage, "ready.db", &group.budget(), |_| {})?;
    assert_eq!(
        prepared.preparation.schema_adapter_version,
        SCHEMA_ADAPTER_VERSION
    );
    let original_ready = bytes(&prepared.snapshot.path())?;
    assert_eq!(
        original_ready.sha256,
        prepared.preparation.prepared_database_sha256
    );
    assert_eq!(
        original_ready.byte_count,
        prepared.preparation.prepared_database_byte_count
    );
    assert!(original_ready.byte_count <= 4 * 1024 * 1024);
    // Preserve original bytes before a later atomic replacement unlinks its
    // path. This is a byte copy, never a hard link or product validator clone.
    fs::copy(prepared.snapshot.path(), path.join("original-ready.db"))?;
    let snapshot = Arc::new(prepared.snapshot);
    let reader = StoreReader::open(snapshot.clone(), &group.budget())?;
    reader.verify_snapshot(&group.budget())?;
    let cached = reader.indexed_inspection().clone();
    assert_eq!(cached.inspection.duration_ns, 900);
    assert_eq!(query_cpus(&reader, group)?, vec![7]);
    assert_eq!(bytes(&source_path)?.sha256, source.sha256);
    group.check();
    Ok(Ready {
        root,
        stage_path: stage.path().to_path_buf(),
        snapshot,
        reader,
        cached,
        source_path,
        source,
        original_ready,
    })
}
fn cached_unchanged(ready: &Ready) {
    assert_eq!(ready.reader.indexed_inspection(), &ready.cached);
}
fn unchanged_source(ready: &Ready) -> TestResult {
    assert_eq!(bytes(&ready.source_path)?.sha256, ready.source.sha256);
    Ok(())
}
fn rejected(ready: &Ready, group: &Group, expected: HostError) -> StoreError {
    let error = StoreError::Host(expected);
    assert_eq!(ready.reader.verify_snapshot(&group.budget()), Err(error));
    assert_eq!(query_cpus(&ready.reader, group), Err(error));
    cached_unchanged(ready);
    group.check();
    error
}
fn evidence(
    ready: Ready,
    case: &str,
    errors: Vec<StoreError>,
    after: Option<Vec<i64>>,
    replacement: Option<Bytes>,
    replacement_duration: Option<i64>,
) -> Result<CaseEvidence, Box<dyn Error>> {
    unchanged_source(&ready)?;
    cached_unchanged(&ready);
    // Report the actual close outcome. Changed/renamed snapshot states do not
    // impose a new universal "close must succeed" contract on the product.
    let close = ready.reader.close();
    Ok(CaseEvidence {
        case: case.to_owned(),
        source: ready.source,
        original_ready: ready.original_ready,
        errors,
        cached_inspection_unchanged: true,
        normal_query_before: vec![7],
        normal_query_after: after,
        replacement,
        replacement_inspection_duration: replacement_duration,
        close,
    })
}

#[test]
fn verified_ready_rejects_each_new_sidecar_then_recovers_after_removal() -> TestResult {
    let group = Group::new("sidecars")?;
    let mut cases = Vec::new();
    for (name, suffix) in [("journal", "-journal"), ("wal", "-wal"), ("shm", "-shm")] {
        let ready = ready(&group, name)?;
        let sidecar = ready.stage_path.join(format!("ready.db{suffix}"));
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&sidecar)?;
        file.write_all(b"n20")?;
        file.sync_all()?;
        drop(file);
        let error = rejected(&ready, &group, HostError::InvalidEvidence);
        fs::remove_file(&sidecar)?;
        ready.reader.verify_snapshot(&group.budget())?;
        let after = query_cpus(&ready.reader, &group)?;
        assert_eq!(after, vec![7]);
        cases.push(evidence(ready, name, vec![error], Some(after), None, None)?);
    }
    // Per case: one baseline, one reject, one recovered verify_snapshot call.
    group.emit(9, cases)
}

#[test]
fn verified_ready_rejects_mode_only_and_same_size_atomic_replacement_without_refresh() -> TestResult
{
    let group = Group::new("mode-and-replacement")?;
    let mode = ready(&group, "mode-only")?;
    let path = mode.snapshot.path();
    let original_metadata = fs::metadata(&path)?;
    fs::set_permissions(&path, Permissions::from_mode(0o600))?;
    assert_eq!(bytes(&path)?.sha256, mode.original_ready.sha256);
    let mode_error = rejected(&mode, &group, HostError::Changed);
    fs::set_permissions(&path, Permissions::from_mode(0o400))?;
    assert_eq!(bytes(&path)?.sha256, mode.original_ready.sha256);
    let restored_metadata = fs::metadata(&path)?;
    assert_eq!(original_metadata.len(), restored_metadata.len());
    assert_eq!(original_metadata.ino(), restored_metadata.ino());
    assert_ne!(
        (original_metadata.ctime(), original_metadata.ctime_nsec()),
        (restored_metadata.ctime(), restored_metadata.ctime_nsec())
    );
    let restored_error = rejected(&mode, &group, HostError::Changed);
    let mode_case = evidence(
        mode,
        "mode-only-and-restored-mode",
        vec![mode_error, restored_error],
        None,
        None,
        None,
    )?;

    let atomic = ready(&group, "same-size-atomic")?;
    let replacement_path = atomic.stage_path.join("replacement.db");
    fs::copy(atomic.snapshot.path(), &replacement_path)?;
    fs::set_permissions(&replacement_path, Permissions::from_mode(0o600))?;
    let replacement_connection = Connection::open(&replacement_path)?;
    replacement_connection
        .execute_batch("UPDATE sched_slice SET cpu=8;UPDATE trace_range SET end_ts=1100;")?;
    replacement_connection.close().map_err(|(_, error)| error)?;
    fs::set_permissions(&replacement_path, Permissions::from_mode(0o400))?;
    let replacement = bytes(&replacement_path)?;
    assert_eq!(
        replacement.byte_count, atomic.original_ready.byte_count,
        "same-size replacement is required"
    );
    assert_ne!(replacement.sha256, atomic.original_ready.sha256);
    assert_ne!(
        fs::metadata(&replacement_path)?.ino(),
        fs::metadata(atomic.snapshot.path())?.ino()
    );
    // Establish that the replacement itself is a valid indexed database with
    // distinguishable inspection/query values before rebinding the old path.
    let stage = atomic.root.open_private_child("stage")?;
    let candidate = StoreReader::open(
        Arc::new(stage.open_file("replacement.db")?),
        &group.budget(),
    )?;
    candidate.verify_snapshot(&group.budget())?;
    let replacement_duration = candidate.inspection().duration_ns;
    assert_eq!(replacement_duration, 1000);
    assert_eq!(query_cpus(&candidate, &group)?, vec![8]);
    assert_eq!(candidate.close(), Ok(()));
    fs::rename(&replacement_path, atomic.snapshot.path())?;
    let atomic_error = rejected(&atomic, &group, HostError::IdentityMismatch);
    let atomic_case = evidence(
        atomic,
        "same-size-atomic",
        vec![atomic_error],
        None,
        Some(replacement),
        Some(replacement_duration),
    )?;
    // Mode baseline/reject/restored + atomic baseline/candidate/reject.
    group.emit(6, vec![mode_case, atomic_case])
}

#[test]
fn verified_ready_rejects_renamed_or_replaced_parent_then_recovers_original_binding() -> TestResult
{
    let group = Group::new("parent-binding")?;
    let ready = ready(&group, "held-parent")?;
    let detached = ready.stage_path.with_file_name("stage-detached");
    fs::rename(&ready.stage_path, &detached)?;
    let missing = rejected(&ready, &group, HostError::NotFound);
    DirBuilder::new().mode(0o700).create(&ready.stage_path)?;
    let replaced = rejected(&ready, &group, HostError::IdentityMismatch);
    fs::remove_dir(&ready.stage_path)?;
    fs::rename(&detached, &ready.stage_path)?;
    ready.reader.verify_snapshot(&group.budget())?;
    let after = query_cpus(&ready.reader, &group)?;
    assert_eq!(after, vec![7]);
    let case = evidence(
        ready,
        "rename-parent-replacement-restore",
        vec![missing, replaced],
        Some(after),
        None,
        None,
    )?;
    group.emit(4, vec![case])
}
