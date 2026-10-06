use crate::{DatabaseInspection, SQLITE_SOURCE_ID, SQLITE_VERSION, StoreError, ValidationBudget};
#[cfg(target_os = "macos")]
use rusqlite::OpenFlags;
use rusqlite::{Connection, Params, Row, config::DbConfig, limits::Limit, types::ValueRef};
use std::{
    sync::{
        Arc,
        atomic::{AtomicU8, AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};

const PROGRESS_INTERVAL: i32 = 100;
pub(crate) const DEFAULT_VM_BUDGET: u64 = 2_000_000;

#[cfg(target_os = "macos")]
pub(crate) struct ReadonlyOpenError {
    pub(crate) error: StoreError,
    pub(crate) transient_descriptor_failure: bool,
}
#[cfg(target_os = "macos")]
pub(crate) fn open_readonly(path: &std::path::Path) -> Result<Connection, ReadonlyOpenError> {
    Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY
            | OpenFlags::SQLITE_OPEN_NO_MUTEX
            | OpenFlags::SQLITE_OPEN_NOFOLLOW,
    )
    .map_err(|error| {
        // Capture errno before any further native call. macOS fdescfs lstat
        // can transiently report EBADF during other threads' fd churn while
        // the held descriptor itself remains valid.
        let bad_descriptor = std::io::Error::last_os_error().raw_os_error() == Some(9);
        let error = sqlite_error(error);
        ReadonlyOpenError {
            transient_descriptor_failure: bad_descriptor
                && error == StoreError::SQLite { code: 14 },
            error,
        }
    })
}

pub(crate) fn sqlite_error(error: rusqlite::Error) -> StoreError {
    match error {
        rusqlite::Error::SqliteFailure(code, _) => StoreError::SQLite {
            code: code.extended_code,
        },
        _ => StoreError::InvalidDatabase,
    }
}

pub(crate) struct Database<'a> {
    connection: ConnectionOwner<'a>,
    budget: &'a ValidationBudget,
    resources: Option<Arc<crate::query_resources::QueryResources>>,
    vm_work: Option<Arc<crate::query_resources::VmWork>>,
    query_deadline: Option<arktrace_platform::ContinuousDeadline>,
    #[cfg(target_os = "macos")]
    writable: Option<Arc<arktrace_platform::WritableFile>>,
}
enum ConnectionOwner<'a> {
    Owned(Connection),
    Borrowed(&'a Connection),
}
impl std::ops::Deref for ConnectionOwner<'_> {
    type Target = Connection;
    fn deref(&self) -> &Self::Target {
        match self {
            Self::Owned(conn) => conn,
            Self::Borrowed(conn) => conn,
        }
    }
}
impl<'a> Database<'a> {
    pub(crate) fn new(
        connection: Connection,
        budget: &'a ValidationBudget,
    ) -> Result<Self, StoreError> {
        Self::configure(ConnectionOwner::Owned(connection), budget, true)
    }
    pub(crate) fn borrow_writable(
        connection: &'a Connection,
        budget: &'a ValidationBudget,
    ) -> Result<Self, StoreError> {
        Self::configure(ConnectionOwner::Borrowed(connection), budget, false)
    }
    pub(crate) fn borrow_readonly(
        connection: &'a Connection,
        budget: &'a ValidationBudget,
    ) -> Result<Self, StoreError> {
        Self::configure(ConnectionOwner::Borrowed(connection), budget, true)
    }
    fn configure(
        connection: ConnectionOwner<'a>,
        budget: &'a ValidationBudget,
        readonly: bool,
    ) -> Result<Self, StoreError> {
        budget.check()?;
        if rusqlite::version() != SQLITE_VERSION {
            return Err(StoreError::SQLiteRuntimeMismatch);
        }
        connection
            .busy_timeout(Duration::ZERO)
            .map_err(sqlite_error)?;
        for (config, value) in [
            (DbConfig::SQLITE_DBCONFIG_DEFENSIVE, true),
            (DbConfig::SQLITE_DBCONFIG_TRUSTED_SCHEMA, false),
            (DbConfig::SQLITE_DBCONFIG_DQS_DDL, false),
            (DbConfig::SQLITE_DBCONFIG_DQS_DML, false),
            (DbConfig::SQLITE_DBCONFIG_ENABLE_TRIGGER, false),
            (DbConfig::SQLITE_DBCONFIG_ENABLE_VIEW, false),
        ] {
            if connection
                .set_db_config(config, value)
                .map_err(sqlite_error)?
                != value
            {
                return Err(StoreError::InvalidDatabase);
            }
        }
        // Bounds apply before schema loading/preparing any input-derived SQL.
        for (limit, value) in [
            (Limit::SQLITE_LIMIT_LENGTH, 8 * 1024 * 1024),
            (Limit::SQLITE_LIMIT_SQL_LENGTH, 256 * 1024),
            (Limit::SQLITE_LIMIT_COLUMN, 2000),
            (Limit::SQLITE_LIMIT_ATTACHED, 0),
            (Limit::SQLITE_LIMIT_VARIABLE_NUMBER, 128),
            (Limit::SQLITE_LIMIT_WORKER_THREADS, 0),
        ] {
            connection.set_limit(limit, value).map_err(sqlite_error)?;
        }
        let result = Self {
            connection,
            budget,
            resources: None,
            vm_work: None,
            query_deadline: None,
            #[cfg(target_os = "macos")]
            writable: None,
        };
        for pragma in [
            if readonly {
                "PRAGMA query_only=ON"
            } else {
                "PRAGMA query_only=OFF"
            },
            "PRAGMA mmap_size=0",
            "PRAGMA cache_size=-2000",
        ] {
            result.query(pragma, [], 1, DEFAULT_VM_BUDGET, |row| integer(row, 0))?;
        }
        let identity = result.query(
            "SELECT sqlite_source_id()",
            [],
            1,
            DEFAULT_VM_BUDGET,
            |row| text(row, 0),
        )?;
        if identity != [SQLITE_SOURCE_ID.to_owned()] {
            return Err(StoreError::SQLiteRuntimeMismatch);
        }
        Ok(result)
    }

    pub(crate) fn inspect(&self) -> Result<DatabaseInspection, StoreError> {
        self.quick_check()?;
        crate::schema::validate(self)
    }
    pub(crate) fn quick_check(&self) -> Result<(), StoreError> {
        // quick_check visits rows and index entries. A fixed small-trace VM
        // ceiling rejects valid large exports before bootstrap can begin.
        // Scale only this structural scan with bounded physical database size;
        // semantic probes and queries retain their independent work limits.
        let page_count = self.query("PRAGMA page_count", [], 1, DEFAULT_VM_BUDGET, |row| {
            integer(row, 0)
        })?[0];
        let page_size = self.query("PRAGMA page_size", [], 1, DEFAULT_VM_BUDGET, |row| {
            integer(row, 0)
        })?[0];
        if page_count < 0
            || !(512..=65536).contains(&page_size)
            || !(page_size as u64).is_power_of_two()
        {
            return Err(StoreError::InvalidDatabase);
        }
        let database_bytes = (page_count as u64)
            .checked_mul(page_size as u64)
            .ok_or(StoreError::InvalidDatabase)?;
        if database_bytes > self.budget.maximum_database_bytes {
            return Err(StoreError::Host(
                arktrace_platform::HostError::LimitExceeded,
            ));
        }
        let vm_budget = database_bytes
            .checked_mul(4)
            .ok_or(StoreError::InvalidBudget)?
            .max(50_000_000);
        let check = self.query("PRAGMA quick_check(1)", [], 2, vm_budget, |row| {
            text(row, 0)
        })?;
        if check != ["ok".to_owned()] {
            return Err(StoreError::InvalidDatabase);
        }
        Ok(())
    }
    pub(crate) fn maximum_database_bytes(&self) -> u64 {
        self.budget.maximum_database_bytes
    }
    pub(crate) fn execute(&self, sql: &str, vm_budget: u64) -> Result<(), StoreError> {
        let rows = self.query(sql, [], 1, vm_budget, |_| Ok(()))?;
        if !rows.is_empty() {
            return Err(StoreError::InvalidDatabase);
        }
        Ok(())
    }
    pub(crate) fn configure_private_indexes(&self) -> Result<(), StoreError> {
        let modes = self.query(
            "PRAGMA journal_mode=MEMORY",
            [],
            1,
            DEFAULT_VM_BUDGET,
            |row| text(row, 0),
        )?;
        if modes.len() != 1 || !modes[0].eq_ignore_ascii_case("memory") {
            return Err(StoreError::InvalidDatabase);
        }
        for sql in [
            "PRAGMA synchronous=OFF",
            "PRAGMA temp_store=MEMORY",
            "PRAGMA cache_size=-131072",
        ] {
            self.execute(sql, DEFAULT_VM_BUDGET)?;
        }
        let modes = self.query(
            "PRAGMA locking_mode=EXCLUSIVE",
            [],
            1,
            DEFAULT_VM_BUDGET,
            |row| text(row, 0),
        )?;
        if modes.len() != 1 || !modes[0].eq_ignore_ascii_case("exclusive") {
            return Err(StoreError::InvalidDatabase);
        }
        Ok(())
    }
    pub(crate) fn restore_private_indexes(&self) -> Result<(), StoreError> {
        let modes = self.query(
            "PRAGMA locking_mode=NORMAL",
            [],
            1,
            DEFAULT_VM_BUDGET,
            |row| text(row, 0),
        )?;
        if modes.len() != 1 || !modes[0].eq_ignore_ascii_case("normal") {
            return Err(StoreError::InvalidDatabase);
        }
        for sql in [
            "PRAGMA synchronous=FULL",
            "PRAGMA temp_store=DEFAULT",
            "PRAGMA cache_size=-2000",
        ] {
            self.execute(sql, DEFAULT_VM_BUDGET)?;
        }
        let modes = self.query(
            "PRAGMA journal_mode=DELETE",
            [],
            1,
            DEFAULT_VM_BUDGET,
            |row| text(row, 0),
        )?;
        if modes.len() != 1 || !modes[0].eq_ignore_ascii_case("delete") {
            return Err(StoreError::InvalidDatabase);
        }
        Ok(())
    }
    fn cleanup_view<'b>(&'b self, budget: &'b ValidationBudget) -> Database<'b> {
        Database {
            connection: ConnectionOwner::Borrowed(&self.connection),
            budget,
            resources: None,
            vm_work: None,
            query_deadline: None,
            #[cfg(target_os = "macos")]
            writable: self.writable.clone(),
        }
    }
    pub(crate) fn rollback_for_cleanup(&self) -> Result<(), StoreError> {
        if self.connection.is_autocommit() {
            return Ok(());
        }
        let budget = ValidationBudget {
            maximum_database_bytes: self.budget.maximum_database_bytes,
            deadline: Instant::now() + Duration::from_secs(2),
            cancellation: arktrace_platform::CancellationToken::default(),
        };
        self.cleanup_view(&budget)
            .execute("ROLLBACK", 50_000_000)
            .map_err(|_| StoreError::CleanupFailed)
    }
    pub(crate) fn restore_for_cleanup(&self) -> Result<(), StoreError> {
        let budget = ValidationBudget {
            maximum_database_bytes: self.budget.maximum_database_bytes,
            deadline: Instant::now() + Duration::from_secs(2),
            cancellation: arktrace_platform::CancellationToken::default(),
        };
        self.cleanup_view(&budget)
            .restore_private_indexes()
            .map_err(|_| StoreError::CleanupFailed)
    }
    pub(crate) fn flush(&self) -> Result<(), StoreError> {
        self.check()?;
        self.connection.cache_flush().map_err(sqlite_error)?;
        self.check()
    }

    fn check_deadline(&self) -> Result<(), StoreError> {
        self.budget.check()?;
        #[cfg(target_os = "macos")]
        if let Some(deadline) = self.query_deadline
            && deadline.expired()?
        {
            return Err(StoreError::DeadlineExceeded);
        }
        Ok(())
    }
    pub(crate) fn check(&self) -> Result<(), StoreError> {
        self.check_deadline()?;
        if let Some(resources) = &self.resources {
            resources.check()?;
        }
        #[cfg(target_os = "macos")]
        if let Some(file) = &self.writable {
            file.verify_sqlite_connection(&self.connection, &self.io_budget())?;
        }
        Ok(())
    }
    #[cfg(target_os = "macos")]
    pub(crate) fn with_query_deadline(
        mut self,
        deadline: Option<arktrace_platform::ContinuousDeadline>,
    ) -> Self {
        self.query_deadline = deadline;
        self
    }
    pub(crate) fn with_resources(
        mut self,
        resources: Option<Arc<crate::query_resources::QueryResources>>,
    ) -> Self {
        self.resources = resources;
        self
    }
    pub(crate) fn reserve_decoded(&self, bytes: u64) -> Result<(), StoreError> {
        if let Some(resources) = &self.resources {
            resources.reserve(bytes)?;
        }
        Ok(())
    }
    pub(crate) fn summary_request(&self, steps: u64) -> Result<Database<'_>, StoreError> {
        Ok(Database {
            connection: ConnectionOwner::Borrowed(&self.connection),
            budget: self.budget,
            resources: Some(Arc::new(crate::query_resources::QueryResources::new(
                crate::ReadPoolLimits::default(),
            )?)),
            vm_work: Some(Arc::new(crate::query_resources::VmWork::new(steps))),
            query_deadline: self.query_deadline,
            #[cfg(target_os = "macos")]
            writable: self.writable.clone(),
        })
    }
    #[cfg(all(test, target_os = "macos"))]
    pub(crate) fn remaining_vm_work_for_test(&self) -> u64 {
        self.vm_work.as_ref().unwrap().remaining_for_test()
    }
    #[cfg(target_os = "macos")]
    pub(crate) fn bind_writable(
        &mut self,
        file: Arc<arktrace_platform::WritableFile>,
    ) -> Result<(), StoreError> {
        self.writable = Some(file);
        self.check()
    }
    #[cfg(target_os = "macos")]
    fn io_budget(&self) -> arktrace_platform::IoBudget {
        arktrace_platform::IoBudget {
            maximum_bytes: self.budget.maximum_database_bytes,
            deadline: self.budget.deadline,
            cancellation: self.budget.cancellation.clone(),
        }
    }

    pub(crate) fn runtime_facts(&self) -> Result<crate::SQLiteRuntimeFacts, StoreError> {
        let mut options = self.query(
            "PRAGMA compile_options",
            [],
            256,
            DEFAULT_VM_BUDGET,
            |row| text(row, 0),
        )?;
        if options.iter().any(|option| option.len() > 256)
            || !options.iter().any(|option| option == "THREADSAFE=1")
        {
            return Err(StoreError::SQLiteRuntimeMismatch);
        }
        self.query(
            "SELECT sqlite_filestat('main')",
            [],
            1,
            DEFAULT_VM_BUDGET,
            |row| text(row, 0),
        )?;
        options.sort_unstable();
        Ok(crate::SQLiteRuntimeFacts {
            version: SQLITE_VERSION.to_owned(),
            source_id: SQLITE_SOURCE_ID.to_owned(),
            compile_options: options,
            file_stat_function_available: true,
        })
    }

    /// Private bounded SQL; mapper repeats storage-class checks. A handler is
    /// installed for prepare + step and removed on every exit, including panic.
    pub(crate) fn query<T>(
        &self,
        sql: &str,
        params: impl Params,
        maximum_rows: usize,
        vm_budget: u64,
        mut map: impl FnMut(&Row<'_>) -> Result<T, StoreError>,
    ) -> Result<Vec<T>, StoreError> {
        self.check()?;
        if maximum_rows == 0 {
            return Err(StoreError::SchemaBudgetExceeded);
        }
        let mut result = Vec::new();
        self.visit(sql, params, vm_budget, |row| {
            if result.len() == maximum_rows {
                return Err(StoreError::SchemaBudgetExceeded);
            }
            if self.resources.is_some() {
                // Credit before the mapper can copy strings. Four copies cover
                // Vec growth and typed-page/group conversion.
                let mut bytes = (std::mem::size_of::<T>() as u64)
                    .checked_add(64)
                    .ok_or(StoreError::DecodedBudgetExceeded)?;
                for index in 0..row.as_ref().column_count() {
                    let value = row.get_ref(index).map_err(sqlite_error)?;
                    let dynamic = match value {
                        ValueRef::Text(v) | ValueRef::Blob(v) => v.len() as u64,
                        _ => 0,
                    };
                    bytes = bytes
                        .checked_add(dynamic)
                        .and_then(|b| b.checked_add(32))
                        .ok_or(StoreError::DecodedBudgetExceeded)?;
                }
                self.reserve_decoded(
                    bytes
                        .checked_mul(4)
                        .ok_or(StoreError::DecodedBudgetExceeded)?,
                )?;
            }
            result.push(map(row)?);
            Ok(())
        })?;
        Ok(result)
    }

    /// Streams borrowed rows under the same cancellation, inode, deadline and
    /// VM checks. The visitor must pre-credit its bounded aggregate state and
    /// must not retain a row or allocate a collection of source events.
    pub(crate) fn visit(
        &self,
        sql: &str,
        params: impl Params,
        vm_budget: u64,
        mut visit: impl FnMut(&Row<'_>) -> Result<(), StoreError>,
    ) -> Result<(), StoreError> {
        self.check()?;
        if vm_budget == 0 {
            return Err(StoreError::SchemaBudgetExceeded);
        }
        let reason = Arc::new(AtomicU8::new(0));
        let callback_reason = reason.clone();
        let cancellation = self.budget.cancellation.clone();
        let resources = self.resources.clone();
        let vm_work = self.vm_work.clone();
        let charged = self.vm_work.as_ref().map(|_| Arc::new(AtomicU64::new(0)));
        let callback_charged = charged.clone();
        let deadline = self.budget.deadline;
        #[cfg(target_os = "macos")]
        let query_deadline = self.query_deadline;
        let mut callbacks = vm_budget.div_ceil(PROGRESS_INTERVAL as u64);
        #[cfg(target_os = "macos")]
        let file = self.writable.clone();
        #[cfg(target_os = "macos")]
        let maximum_bytes = self.budget.maximum_database_bytes;
        let native_error = Arc::new(std::sync::Mutex::new(None::<arktrace_platform::HostError>));
        #[cfg(target_os = "macos")]
        let callback_error = native_error.clone();
        #[cfg(target_os = "macos")]
        let mut file_callbacks = 0_u16;
        self.connection
            .progress_handler(
                PROGRESS_INTERVAL,
                Some(move || {
                    #[cfg(target_os = "macos")]
                    let continuous_reason =
                        match query_deadline.map(|value| value.expired()).transpose() {
                            Ok(Some(true)) => 2,
                            Ok(_) => 0,
                            Err(error) => {
                                *callback_error.lock().unwrap_or_else(|p| p.into_inner()) =
                                    Some(error);
                                4
                            }
                        };
                    #[cfg(not(target_os = "macos"))]
                    let continuous_reason = 0;
                    let why = if cancellation.is_cancelled()
                        || resources.as_ref().is_some_and(|r| r.abort.is_cancelled())
                    {
                        1
                    } else if Instant::now() >= deadline {
                        2
                    } else if continuous_reason != 0 {
                        continuous_reason
                    } else if callbacks <= 1
                        || vm_work
                            .as_ref()
                            .is_some_and(|work| work.charge(PROGRESS_INTERVAL as u64).is_err())
                    {
                        3
                    } else {
                        callbacks -= 1;
                        if let Some(charged) = &callback_charged {
                            charged.fetch_add(PROGRESS_INTERVAL as u64, Ordering::Relaxed);
                        }
                        #[cfg(target_os = "macos")]
                        {
                            file_callbacks += 1;
                            if file_callbacks == 100 {
                                file_callbacks = 0;
                                if let Some(file) = &file
                                    && let Err(error) = file.observe_write_size(maximum_bytes)
                                {
                                    *callback_error.lock().unwrap_or_else(|p| p.into_inner()) =
                                        Some(error);
                                    callback_reason.store(4, Ordering::Relaxed);
                                    return true;
                                }
                            }
                        }
                        0
                    };
                    if why != 0 {
                        callback_reason.store(why, Ordering::Relaxed);
                    }
                    why != 0
                }),
            )
            .map_err(sqlite_error)?;
        let guard = ProgressGuard(&self.connection);
        let outcome = (|| {
            let mut statement = self.connection.prepare(sql).map_err(sqlite_error)?;
            let outcome = (|| {
                let mut rows = statement.query(params).map_err(sqlite_error)?;
                while let Some(row) = rows.next().map_err(sqlite_error)? {
                    self.check_deadline()?;
                    visit(row)?;
                }
                Ok(())
            })();
            if let Some(work) = &self.vm_work {
                // Progress checks account for complete intervals; include the
                // final short statement tail instead of resetting at each SQL.
                let actual = statement
                    .get_status(rusqlite::StatementStatus::VmStep)
                    .max(0) as u64;
                work.charge(
                    actual
                        .saturating_sub(charged.as_ref().map_or(0, |n| n.load(Ordering::Relaxed))),
                )?;
            }
            outcome
        })();
        self.connection
            .progress_handler(0, None::<fn() -> bool>)
            .map_err(sqlite_error)?;
        drop(guard);
        self.check()?;
        match reason.load(Ordering::Relaxed) {
            1 => Err(StoreError::Cancelled),
            2 => Err(StoreError::DeadlineExceeded),
            3 => Err(StoreError::VmBudgetExceeded),
            4 => Err(StoreError::Host(
                native_error
                    .lock()
                    .unwrap_or_else(|p| p.into_inner())
                    .unwrap_or(arktrace_platform::HostError::Changed),
            )),
            _ => outcome,
        }
    }
}
struct ProgressGuard<'a>(&'a Connection);
impl Drop for ProgressGuard<'_> {
    fn drop(&mut self) {
        // Connection is private, never borrowed by another thread; no ownership
        // transfer can make this reset fail. Explicit normal reset is checked.
        let _ = self.0.progress_handler(0, None::<fn() -> bool>);
    }
}
pub(crate) fn integer(row: &Row<'_>, index: usize) -> Result<i64, StoreError> {
    match row.get_ref(index).map_err(sqlite_error)? {
        ValueRef::Integer(value) => Ok(value),
        _ => Err(StoreError::InvalidDatabase),
    }
}
pub(crate) fn text(row: &Row<'_>, index: usize) -> Result<String, StoreError> {
    match row.get_ref(index).map_err(sqlite_error)? {
        ValueRef::Text(value) if value.len() <= 65536 => std::str::from_utf8(value)
            .map(str::to_owned)
            .map_err(|_| StoreError::InvalidDatabase),
        ValueRef::Text(_) => Err(StoreError::SchemaBudgetExceeded),
        _ => Err(StoreError::InvalidDatabase),
    }
}
