//! Fresh private writable candidates and SQLite's actual handle binding.
//! No schema, SQL statements, or domain readiness live in this native port.
use super::{
    Access, FileIdentity, FileSnapshot, HeldDirectory, HeldFile, Stat, component, flush,
    require_private_security, stat_child, write_all_at,
};
use crate::{HostError, IoBudget};
use std::{
    ffi::{CString, OsStr},
    fs::File,
    mem::ManuallyDrop,
    os::windows::io::FromRawHandle,
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
    /// Exclusive fresh output only. Never changes security on an input file.
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
        let identity = Stat::of(&file)?.identity()?;
        let result = (|| {
            let facts = source.scan(budget, |offset, bytes| write_all_at(&file, bytes, offset))?;
            flush(&file)?;
            self.sync()?;
            // A separately held handle and independent full scan confirm the
            // completed copy before any SQLite connection can mutate it.
            let check = self.open_file_component(name.clone(), true)?;
            if check.initial.identity != identity || check.facts(budget)? != facts {
                return Err(HostError::Changed);
            }
            let initial = FileSnapshot::of(&file)?;
            Ok((initial, facts))
        })();
        match result {
            Ok((initial, facts)) => {
                let owned = Arc::new(WritableFile {
                    file,
                    parent: self.clone(),
                    name,
                    initial,
                });
                owned.revalidate(budget)?;
                Ok((owned, facts))
            }
            Err(error) => {
                drop(file);
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
        require_private_security(&self.file)
    }
    /// Cheap VM-callback observation. Full ancestor/security checks occur
    /// around statements. This still binds the directory-relative link and handle.
    pub fn observe_write_size(&self, maximum_bytes: u64) -> Result<(), HostError> {
        let stat = Stat::of(&self.file)?;
        if stat.identity()? != self.initial.identity
            || stat.links != 1
            || stat.delete_pending
            || !Access::of(&self.file)?.owner_read_write()
        {
            return Err(HostError::Changed);
        }
        let linked = stat_child(&self.parent.0.file, &self.name)?;
        if !linked.is_file() || linked.identity()? != self.initial.identity {
            return Err(HostError::IdentityMismatch);
        }
        if stat.size > maximum_bytes {
            return Err(HostError::LimitExceeded);
        }
        Ok(())
    }
    fn path(&self) -> std::path::PathBuf {
        self.parent
            .path()
            .join(self.name.to_str().unwrap_or_default())
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
        let flags =
            rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX;
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
    /// Native FILESTAT before SQL/schema preparation. The pinned SQLite JSON
    /// layout supplies its real main-file HANDLE; the volume/file id of that
    /// borrowed handle must be this file's. No handle ownership transfer.
    pub fn verify_sqlite_connection(
        &self,
        connection: &rusqlite::Connection,
        budget: &IoBudget,
    ) -> Result<(), HostError> {
        self.revalidate(budget)?;
        if sqlite_handle_identity(connection)? != self.initial.identity {
            return Err(HostError::IdentityMismatch);
        }
        self.revalidate(budget)
    }
    fn require_no_sidecars(&self) -> Result<(), HostError> {
        let base = self.name.to_str().map_err(|_| HostError::InvalidPath)?;
        for suffix in ["-journal", "-wal", "-shm"] {
            let name = component(OsStr::new(&format!("{base}{suffix}")))?;
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
        // SAFETY: owned accumulator finished exactly once; SQLite owns the
        // matching allocator/free pair. Null free is explicitly allowed.
        unsafe {
            rusqlite::ffi::sqlite3_free(rusqlite::ffi::sqlite3_str_finish(self.0).cast());
        }
    }
}

/// The volume/file id of the HANDLE SQLite's win32 VFS holds for "main".
pub(super) fn sqlite_handle_identity(
    connection: &rusqlite::Connection,
) -> Result<FileIdentity, HostError> {
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
    // SAFETY: the value is live for `length` bytes until the next accumulator
    // mutation or finish; neither happens while it is borrowed.
    let bytes = unsafe { std::slice::from_raw_parts(data.cast::<u8>(), length as usize) };
    let json: serde_json::Value =
        serde_json::from_slice(bytes).map_err(|_| HostError::InvalidEvidence)?;
    if !json
        .get("vfs")
        .and_then(serde_json::Value::as_str)
        .is_some_and(|vfs| vfs.starts_with("win32"))
    {
        return Err(HostError::InvalidEvidence);
    }
    let raw_handle = json
        .get("h")
        .and_then(serde_json::Value::as_u64)
        .filter(|h| *h != 0 && *h != u64::MAX)
        .ok_or(HostError::InvalidEvidence)?;
    // SAFETY: SQLite owns this live handle for the borrowed connection's
    // lifetime. ManuallyDrop borrows it for metadata only and never closes it.
    let borrowed = ManuallyDrop::new(unsafe { File::from_raw_handle(raw_handle as usize as _) });
    let stat = Stat::of(&borrowed)?;
    if !stat.is_file() {
        return Err(HostError::IdentityMismatch);
    }
    stat.identity()
}
