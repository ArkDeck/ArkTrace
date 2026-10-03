//! Fresh private writable candidates and SQLite's actual descriptor binding.
//! No schema, SQL statements, or domain readiness live in this native port.
use super::{
    FileSnapshot, HeldDirectory, HeldFile, component, from_io, os_error, require_private_security,
    stat_child, stat_identity,
};
use crate::{HostError, HostOperation, IoBudget};
use std::{
    ffi::{CString, OsStr},
    fs::File,
    sync::Arc,
    time::{Duration, Instant},
};

pub struct WritableFile {
    file: File,
    parent: HeldDirectory,
    name: CString,
    initial: FileSnapshot,
}
impl HeldDirectory {
    /// O_EXCL fresh output only. Never changes permissions on an input file.
    pub fn copy_writable_candidate(
        &self,
        source: &HeldFile,
        name: &str,
        budget: &IoBudget,
    ) -> Result<(Arc<WritableFile>, super::SourceFacts), HostError> {
        budget.check()?;
        source.verify()?;
        let name = component(OsStr::new(name))?;
        let file = self.create_file(&name)?;
        let identity = FileSnapshot::metadata(
            &file
                .metadata()
                .map_err(|e| from_io(e, HostOperation::Stat))?,
        )
        .identity;
        let result = (|| {
            let facts = source.scan(budget, |offset, bytes| {
                use std::os::unix::fs::FileExt;
                file.write_all_at(bytes, offset)
                    .map_err(|e| from_io(e, HostOperation::Write))
            })?;
            file.sync_all()
                .map_err(|e| from_io(e, HostOperation::Sync))?;
            self.sync()?;
            // A separately held descriptor and independent full scan confirm
            // the completed copy before any SQLite connection can mutate it.
            let check = self.open_file_component(name.clone(), true)?;
            if check.initial.identity != identity || check.facts(budget)? != facts {
                return Err(HostError::Changed);
            }
            let initial = FileSnapshot::metadata(
                &file
                    .metadata()
                    .map_err(|e| from_io(e, HostOperation::Stat))?,
            );
            let owned = Arc::new(WritableFile {
                file,
                parent: self.clone(),
                name: name.clone(),
                initial,
            });
            owned.revalidate(budget)?;
            Ok((owned, facts))
        })();
        match result {
            Ok(candidate) => Ok(candidate),
            Err(error) => {
                self.remove_owned_component(&name, identity)
                    .map_err(|_| HostError::CleanupFailed)?;
                Err(error)
            }
        }
    }
}
impl WritableFile {
    pub fn revalidate(&self, budget: &IoBudget) -> Result<(), HostError> {
        budget.check()?;
        self.parent.revalidate()?;
        self.observe_write_size(budget.maximum_bytes)?;
        let current = self
            .file
            .metadata()
            .map_err(|e| from_io(e, HostOperation::Stat))?;
        require_private_security(&self.file, &current)
    }
    /// Cheap VM-callback observation. Full ancestor/mount/ACL checks occur
    /// around statements. This still binds the directory-relative link and FD.
    pub fn observe_write_size(&self, maximum_bytes: u64) -> Result<(), HostError> {
        let current = self
            .file
            .metadata()
            .map_err(|e| from_io(e, HostOperation::Stat))?;
        let snapshot = FileSnapshot::metadata(&current);
        if snapshot.identity != self.initial.identity
            || snapshot.uid != self.initial.uid
            || snapshot.gid != self.initial.gid
            || snapshot.mode != self.initial.mode
            || snapshot.mode & 0o7777 != 0o600
            || snapshot.links != 1
        {
            return Err(HostError::Changed);
        }
        let linked = stat_child(&self.parent.0.file, &self.name)?;
        if linked.st_mode & libc::S_IFMT != libc::S_IFREG
            || stat_identity(&linked) != self.initial.identity
        {
            return Err(HostError::IdentityMismatch);
        }
        if current.len() > maximum_bytes {
            return Err(HostError::LimitExceeded);
        }
        Ok(())
    }
    fn path(&self) -> std::path::PathBuf {
        use std::os::unix::ffi::OsStrExt;
        self.parent
            .path()
            .join(OsStr::from_bytes(self.name.as_bytes()))
    }
    pub fn with_sqlite_connection<T, E>(
        &self,
        budget: &IoBudget,
        body: impl FnOnce(&rusqlite::Connection) -> Result<T, E>,
    ) -> Result<T, E>
    where
        E: From<HostError>,
    {
        self.revalidate(budget)?;
        self.require_no_sidecars()?;
        let flags = rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE
            | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX
            | rusqlite::OpenFlags::SQLITE_OPEN_NOFOLLOW;
        let connection = rusqlite::Connection::open_with_flags(self.path(), flags)
            .map_err(|_| HostError::InvalidEvidence)?;
        self.verify_sqlite_connection(&connection, budget)?;
        let result = body(&connection);
        let cleanup = IoBudget {
            maximum_bytes: budget.maximum_bytes,
            deadline: Instant::now() + Duration::from_secs(2),
            cancellation: crate::CancellationToken::default(),
        };
        let binding = self.verify_sqlite_connection(&connection, &cleanup);
        connection.close().map_err(|_| HostError::CleanupFailed)?;
        binding?;
        budget.check()?;
        result
    }
    /// Direct native FILESTAT before SQL/schema preparation. The pinned SQLite
    /// JSON layout supplies its real main-file fd; fstat verifies both dev/ino.
    /// No unixFile layout casts, FD ownership transfer or statement execution.
    pub fn verify_sqlite_connection(
        &self,
        connection: &rusqlite::Connection,
        budget: &IoBudget,
    ) -> Result<(), HostError> {
        self.revalidate(budget)?;
        if connection.path() != self.path().to_str() {
            return Err(HostError::IdentityMismatch);
        }
        let info = sqlite_file_descriptor(connection)?;
        let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
        // SAFETY: connection is borrowed and remains alive. Its native VFS fd
        // is read from its own bounded FILESTAT; fstat borrows, never closes it.
        if unsafe { libc::fstat(info, stat.as_mut_ptr()) } != 0 {
            return Err(os_error(HostOperation::Stat));
        }
        // SAFETY: successful fstat initialized the complete Darwin stat.
        let stat = unsafe { stat.assume_init() };
        if stat.st_mode & libc::S_IFMT != libc::S_IFREG
            || stat_identity(&stat) != self.initial.identity
        {
            return Err(HostError::IdentityMismatch);
        }
        self.revalidate(budget)
    }
    fn require_no_sidecars(&self) -> Result<(), HostError> {
        use std::os::unix::ffi::OsStrExt;
        for suffix in [
            b"-journal".as_slice(),
            b"-wal".as_slice(),
            b"-shm".as_slice(),
        ] {
            let mut bytes = self.name.as_bytes().to_vec();
            bytes.extend_from_slice(suffix);
            let name = component(OsStr::from_bytes(&bytes))?;
            match stat_child(&self.parent.0.file, &name) {
                Err(HostError::NotFound) => {}
                Ok(_) => return Err(HostError::InvalidEvidence),
                Err(error) => return Err(error),
            }
        }
        Ok(())
    }
    /// The Store must close SQLite first. Every retained mutable alias is then
    /// drained before owner-only readonly sealing and independent hashing.
    pub fn seal_readonly(self, budget: &IoBudget) -> Result<HeldFile, HostError> {
        self.revalidate(budget)?;
        self.require_no_sidecars()?;
        let sealed = self.parent.seal(&self.file, &self.name, false, budget)?;
        if sealed.snapshot().identity != self.initial.identity {
            return Err(HostError::IdentityMismatch);
        }
        drop(self.file);
        sealed.verify()?;
        sealed.facts(budget)?;
        Ok(sealed)
    }
}
struct SQLiteString(*mut rusqlite::ffi::sqlite3_str);
impl Drop for SQLiteString {
    fn drop(&mut self) {
        // SAFETY: owned accumulator is finished exactly once, and SQLite owns
        // the matching allocator/free pair. Null free is explicitly allowed.
        unsafe {
            rusqlite::ffi::sqlite3_free(rusqlite::ffi::sqlite3_str_finish(self.0).cast());
        }
    }
}
fn sqlite_file_descriptor(connection: &rusqlite::Connection) -> Result<i32, HostError> {
    // SAFETY: borrowed live connection, same calling thread; native metadata
    // control only. The accumulator is owned by this frame, never escapes.
    let handle = unsafe { connection.handle() };
    let raw = unsafe { rusqlite::ffi::sqlite3_str_new(handle) };
    if raw.is_null() {
        return Err(HostError::InvalidEvidence);
    }
    let string = SQLiteString(raw);
    let code = unsafe {
        rusqlite::ffi::sqlite3_file_control(
            handle,
            c"main".as_ptr(),
            rusqlite::ffi::SQLITE_FCNTL_FILESTAT,
            string.0.cast(),
        )
    };
    if code != rusqlite::ffi::SQLITE_OK {
        return Err(HostError::InvalidEvidence);
    }
    let length = unsafe { rusqlite::ffi::sqlite3_str_length(string.0) };
    let data = unsafe { rusqlite::ffi::sqlite3_str_value(string.0) };
    if !(1..=16384).contains(&length) || data.is_null() {
        return Err(HostError::InvalidEvidence);
    }
    // SAFETY: SQLite guarantees value is live for length bytes until the next
    // accumulator mutation or finish. No mutation occurs while it is borrowed.
    let bytes = unsafe { std::slice::from_raw_parts(data.cast::<u8>(), length as usize) };
    let json: serde_json::Value =
        serde_json::from_slice(bytes).map_err(|_| HostError::InvalidEvidence)?;
    let fd = json
        .get("h")
        .and_then(serde_json::Value::as_i64)
        .and_then(|fd| i32::try_from(fd).ok())
        .filter(|fd| *fd >= 0)
        .ok_or(HostError::InvalidEvidence)?;
    if json.get("vfs").and_then(serde_json::Value::as_str) != Some("unix") {
        return Err(HostError::InvalidEvidence);
    }
    Ok(fd)
}
