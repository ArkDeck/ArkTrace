//! Darwin descriptor boundary. Every path mutation is relative to held parents.
use crate::{HostError, HostOperation, IoBudget};
use sha2::{Digest, Sha256};
use std::{
    ffi::{CString, OsStr},
    fs::{File, Metadata},
    io,
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{
            ffi::OsStrExt,
            fs::{FileExt, MetadataExt},
        },
    },
    path::{Component, Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    thread,
    time::{Duration, Instant},
};

#[path = "macos_directory.rs"]
mod directory;
#[path = "macos_owner.rs"]
mod owner;
pub use owner::{
    OwnedDirectory, OwnerKind, OwnerRecoveryOutcome, OwnerStore, PublishedOwnerEvidence,
};
#[path = "macos_writable.rs"]
mod writable;
pub use writable::WritableFile;
#[path = "macos_process.rs"]
mod process;
pub use directory::SealedDirectory;
#[path = "macos_trust.rs"]
mod trust;
pub use process::{
    ProcessBudget, ProcessError, ProcessOutcome, ProcessOutputFileBudget, VerifiedExecutable,
    run_supervised, supervisor_main,
};
pub use trust::{CodeTrustPolicy, TrustVerdict};
#[path = "macos_cli.rs"]
mod cli;
pub use cli::{CliSignalGuard, CliWriteFailure, MappedExecutable, user_temporary_workspace};

// Swift ContinuousClock.systemEpoch uses this same clock. std::time::Instant
// uses CLOCK_UPTIME_RAW and cannot substitute across machine suspension.
pub(crate) fn continuous_time() -> Result<(i64, u32), HostError> {
    let mut value = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: valid uniquely borrowed output storage, fixed supported clock ID.
    if unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC_RAW, &mut value) } != 0 {
        return Err(HostError::SystemIo {
            operation: HostOperation::Read,
            code: io::Error::last_os_error()
                .raw_os_error()
                .unwrap_or(libc::EIO),
        });
    }
    if value.tv_sec < 0 || !(0..1_000_000_000).contains(&value.tv_nsec) {
        return Err(HostError::InvalidEvidence);
    }
    Ok((value.tv_sec, value.tv_nsec as u32))
}

// Native inspection used only by the opt-in compiled process fixture. Keep
// test syscalls in the same audited boundary as production syscalls.
#[cfg(feature = "process-fixtures")]
pub mod process_fixture {
    use crate::ProcessError;
    pub fn pause_owner_creation(point: u8) -> Result<(), ProcessError> {
        if point > 2 {
            return Err(ProcessError::InvalidArguments);
        }
        super::owner::fixture_pause_create(point);
        Ok(())
    }
    pub fn pause_owner_cleanup(point: u8) -> Result<(), ProcessError> {
        if point > 4 {
            return Err(ProcessError::InvalidArguments);
        }
        super::owner::fixture_pause_cleanup(point);
        Ok(())
    }
    /// 0: publication intent; 1: rename before Ready record; 2: Removed before
    /// entry unlink; 3: entry unlink before owner artifacts are erased.
    pub fn pause_ephemeral_owner(point: u8) -> Result<(), ProcessError> {
        if point > 3 {
            return Err(ProcessError::InvalidArguments);
        }
        super::owner::fixture_pause_ephemeral(point);
        Ok(())
    }
    pub fn ignore_term() -> Result<(), ProcessError> {
        // SAFETY: fixture calls once before threads in its dedicated process.
        if unsafe { libc::signal(libc::SIGTERM, libc::SIG_IGN) } == libc::SIG_ERR {
            return Err(ProcessError::CleanupFailed);
        }
        Ok(())
    }
    pub fn parent_pid() -> i32 {
        // SAFETY: getppid has no arguments or borrowed storage.
        unsafe { libc::getppid() }
    }
    pub fn pause_next_bootstrap() {
        super::process::fixture_pause_next_bootstrap();
    }
    pub fn ignore_hup() -> Result<(), ProcessError> {
        // SAFETY: dedicated fixture changes its own inherited disposition
        // before any thread, exercising launchd/GUI callers that ignore HUP.
        if unsafe { libc::signal(libc::SIGHUP, libc::SIG_IGN) } == libc::SIG_ERR {
            return Err(ProcessError::CleanupFailed);
        }
        Ok(())
    }
    pub fn new_session() -> Result<(), ProcessError> {
        // SAFETY: dedicated fixture calls once before spawning children/threads.
        if unsafe { libc::setsid() } < 0 {
            return Err(ProcessError::CleanupFailed);
        }
        Ok(())
    }
    pub fn is_stopped(pid: i32) -> Result<bool, ProcessError> {
        if pid <= 0 {
            return Err(ProcessError::InvalidArguments);
        }
        let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::uninit();
        let size = std::mem::size_of::<libc::proc_bsdinfo>() as i32;
        // SAFETY: full bounded output, exact known fixture PID.
        if unsafe { libc::proc_pidinfo(pid, 3, 0, info.as_mut_ptr().cast(), size) } != size {
            return Err(ProcessError::CleanupFailed);
        }
        // SAFETY: initialized full structure, Darwin SSTOP=4.
        Ok(unsafe { info.assume_init() }.pbi_status == 4)
    }
    pub fn is_live(pid: i32) -> Result<bool, ProcessError> {
        if pid <= 0 {
            return Err(ProcessError::InvalidArguments);
        }
        let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::uninit();
        let size = std::mem::size_of::<libc::proc_bsdinfo>() as i32;
        // SAFETY: bounded PID inspection; a full output initializes the structure.
        let result = unsafe { libc::proc_pidinfo(pid, 3, 0, info.as_mut_ptr().cast(), size) };
        if result == 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH) {
            return Ok(false);
        }
        if result != size {
            return Err(ProcessError::CleanupFailed);
        }
        // SAFETY: full output above; Darwin SZOMB=5.
        Ok(unsafe { info.assume_init() }.pbi_status != 5)
    }
    pub fn open_descriptors() -> Result<Vec<i32>, ProcessError> {
        // SAFETY: getdtablesize has no arguments or borrowed storage.
        let bound = unsafe { libc::getdtablesize() };
        if !(3..=65_536).contains(&bound) {
            return Err(ProcessError::CleanupFailed);
        }
        let mut result = Vec::new();
        for fd in 3..bound {
            // SAFETY: read-only descriptor query, no ownership transfer.
            if unsafe { libc::fcntl(fd, libc::F_GETFD) } >= 0 {
                result.push(fd);
            }
        }
        Ok(result)
    }
    pub fn check_loaded_identity(
        expected: &super::VerifiedExecutable,
        actual: &super::VerifiedExecutable,
        cwd: &super::HeldDirectory,
    ) -> Result<(), ProcessError> {
        super::process::fixture_check_loaded_identity(expected, actual, cwd)
    }
}

const CHUNK_BYTES: usize = 1024 * 1024;
static NEXT_QUARANTINE: AtomicU64 = AtomicU64::new(0);

// Xcode 27 sys/acl.h: opaque pointer types and 32-bit C enum arguments.
// libc's Rust bindings do not currently expose these Darwin ACL functions.
unsafe extern "C" {
    fn acl_get_fd_np(fd: libc::c_int, kind: libc::c_int) -> *mut libc::c_void;
    fn acl_get_entry(
        acl: *mut libc::c_void,
        entry_id: libc::c_int,
        entry: *mut *mut libc::c_void,
    ) -> libc::c_int;
    fn acl_get_tag_type(entry: *mut libc::c_void, tag: *mut libc::c_int) -> libc::c_int;
    fn acl_free(acl: *mut libc::c_void) -> libc::c_int;
}

struct Acl(std::ptr::NonNull<libc::c_void>);
impl Drop for Acl {
    fn drop(&mut self) {
        // SAFETY: acl_get_fd_np transferred this allocation; released exactly once.
        unsafe { acl_free(self.0.as_ptr()) };
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FileIdentity {
    pub device: u64,
    pub inode: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FileSnapshot {
    pub identity: FileIdentity,
    pub byte_count: u64,
    mode: u32,
    uid: u32,
    gid: u32,
    links: u64,
    modification: (i64, i64),
    change: (i64, i64),
}

impl FileSnapshot {
    fn metadata(metadata: &Metadata) -> Self {
        Self {
            identity: FileIdentity {
                device: metadata.dev(),
                inode: metadata.ino(),
            },
            byte_count: metadata.size(),
            mode: metadata.mode(),
            uid: metadata.uid(),
            gid: metadata.gid(),
            links: metadata.nlink(),
            modification: (metadata.mtime(), metadata.mtime_nsec()),
            change: (metadata.ctime(), metadata.ctime_nsec()),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SourceFacts {
    pub sha256: String,
    pub byte_count: u64,
}

struct DirectoryNode {
    file: File,
    identity: FileIdentity,
    parent: Option<Arc<DirectoryNode>>,
    name: CString,
    path: PathBuf,
    private: bool,
    trusted_ancestors: bool,
}

#[derive(Clone)]
pub struct HeldDirectory(Arc<DirectoryNode>);

/// Immutable metadata and descriptor of the exact file bound at open time.
/// No public constructor accepts an arbitrary identity or a foreign descriptor.
pub struct HeldFile {
    file: File,
    initial: FileSnapshot,
    parent: HeldDirectory,
    name: CString,
    private: bool,
}

fn os_error(operation: HostOperation) -> HostError {
    from_io(io::Error::last_os_error(), operation)
}

fn from_io(error: io::Error, operation: HostOperation) -> HostError {
    let code = error.raw_os_error().unwrap_or(libc::EIO);
    match code {
        libc::ENOENT => HostError::NotFound,
        libc::ELOOP => HostError::LinkedObject,
        libc::EEXIST => HostError::AlreadyExists,
        libc::EXDEV => HostError::CrossVolume,
        libc::ENAMETOOLONG => HostError::InvalidPath,
        _ => HostError::SystemIo { operation, code },
    }
}

fn component(name: &OsStr) -> Result<CString, HostError> {
    let bytes = name.as_bytes();
    if bytes.is_empty()
        // Darwin dirent permits up to 1023 bytes. APFS accepts Unicode names
        // beyond 255 UTF-8 bytes; the filesystem applies its native name limit.
        || bytes.len() >= 1024
        || bytes == b"."
        || bytes == b".."
        || bytes.contains(&b'/')
    {
        return Err(HostError::InvalidPath);
    }
    CString::new(bytes).map_err(|_| HostError::InvalidPath)
}

fn descriptor(fd: i32) -> Result<File, HostError> {
    if fd < 0 {
        return Err(os_error(HostOperation::Open));
    }
    // SAFETY: open/openat returned a fresh owned descriptor, transferred once.
    Ok(unsafe { File::from_raw_fd(fd) })
}

fn stat_child(parent: &File, name: &CString) -> Result<libc::stat, HostError> {
    let mut info = std::mem::MaybeUninit::<libc::stat>::uninit();
    // SAFETY: parent remains live, name is NUL-terminated, output has stat size.
    if unsafe {
        libc::fstatat(
            parent.as_raw_fd(),
            name.as_ptr(),
            info.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    } != 0
    {
        return Err(os_error(HostOperation::Stat));
    }
    // SAFETY: successful fstatat initialized every stat field.
    Ok(unsafe { info.assume_init() })
}

fn stat_identity(info: &libc::stat) -> FileIdentity {
    FileIdentity {
        device: info.st_dev as u64,
        inode: info.st_ino,
    }
}

fn require_private(metadata: &Metadata) -> Result<(), HostError> {
    // SAFETY: geteuid has no pointers or ownership effects.
    if metadata.uid() != unsafe { libc::geteuid() } || metadata.mode() & 0o077 != 0 {
        return Err(HostError::NotPrivate);
    }
    Ok(())
}

fn require_owner_enforcement(file: &File) -> Result<(), HostError> {
    let mut info = std::mem::MaybeUninit::<libc::statfs>::uninit();
    // SAFETY: held descriptor, correctly sized output; success initializes statfs.
    if unsafe { libc::fstatfs(file.as_raw_fd(), info.as_mut_ptr()) } != 0 {
        return Err(os_error(HostOperation::Stat));
    }
    // SAFETY: successful fstatfs initialized the entire structure.
    let info = unsafe { info.assume_init() };
    if info.f_flags & libc::MNT_IGNORE_OWNERSHIP as u32 != 0 {
        return Err(HostError::NotPrivate);
    }
    Ok(())
}

fn require_private_security(file: &File, metadata: &Metadata) -> Result<(), HostError> {
    require_private(metadata)?;
    require_owner_enforcement(file)?;
    // ACL_TYPE_EXTENDED is 0x100. Existing ACLs are inspected, never removed.
    // Private storage accepts empty/deny-only ACLs; any additional allow grant
    // needs an explicit future policy instead of trusting chmod mode bits.
    // SAFETY: live held descriptor and the supported Darwin extended ACL type.
    let acl = unsafe { acl_get_fd_np(file.as_raw_fd(), 0x100) };
    if acl.is_null() && io::Error::last_os_error().raw_os_error() == Some(libc::ENOENT) {
        // On Darwin an absent extended ACL is ENOENT, including for a live FD.
        // Distinguish it from an unlinked object by checking the same descriptor.
        let current = file
            .metadata()
            .map_err(|e| from_io(e, HostOperation::Stat))?;
        if current.nlink() == 0
            || FileSnapshot::metadata(&current).identity
                != FileSnapshot::metadata(metadata).identity
        {
            return Err(HostError::IdentityMismatch);
        }
        return require_private(&current);
    }
    let acl = Acl(std::ptr::NonNull::new(acl).ok_or_else(|| os_error(HostOperation::Stat))?);
    for index in 0..=128 {
        let mut entry = std::ptr::null_mut();
        // Darwin differs from Linux: 0 means an entry, -1/EINVAL means no more.
        // SAFETY: owned valid ACL and writable opaque entry pointer output.
        if unsafe { acl_get_entry(acl.0.as_ptr(), if index == 0 { 0 } else { -1 }, &mut entry) }
            != 0
        {
            if io::Error::last_os_error().raw_os_error() == Some(libc::EINVAL) {
                return Ok(());
            }
            return Err(os_error(HostOperation::Stat));
        }
        if index == 128 || entry.is_null() {
            return Err(HostError::NotPrivate);
        }
        let mut tag = 0;
        // SAFETY: entry belongs to the live ACL and output has C enum size.
        if unsafe { acl_get_tag_type(entry, &mut tag) } != 0 {
            return Err(os_error(HostOperation::Stat));
        }
        if tag != 2 {
            // ACL_EXTENDED_DENY
            return Err(HostError::NotPrivate);
        }
    }
    Err(HostError::NotPrivate)
}

fn require_trusted_ancestor(metadata: &Metadata) -> Result<(), HostError> {
    // Root-owned sticky ancestors (e.g. /private/tmp) protect user-owned children.
    // SAFETY: geteuid has no pointers or ownership effects.
    let uid = unsafe { libc::geteuid() };
    if metadata.uid() != uid && metadata.uid() != 0 {
        return Err(HostError::NotPrivate);
    }
    let writable_by_others = metadata.mode() & 0o022 != 0;
    if writable_by_others && !(metadata.uid() == 0 && metadata.mode() & 0o1000 != 0) {
        return Err(HostError::NotPrivate);
    }
    Ok(())
}

impl HeldDirectory {
    /// Caller supplies a canonical absolute storage root. All components are
    /// opened O_NOFOLLOW; existing permissions are validated, never repaired.
    pub fn open_private(path: &Path) -> Result<Self, HostError> {
        Self::open(path, true)
    }

    fn open(path: &Path, private: bool) -> Result<Self, HostError> {
        Self::open_security(path, private, private)
    }

    fn open_trusted_temporary_parent(path: &Path) -> Result<Self, HostError> {
        Self::open_security(path, false, true)
    }

    fn open_security(
        path: &Path,
        private: bool,
        trusted_ancestors: bool,
    ) -> Result<Self, HostError> {
        if !path.is_absolute() {
            return Err(HostError::InvalidPath);
        }
        let names: Vec<_> = path
            .components()
            .filter_map(|part| match part {
                Component::RootDir => None,
                Component::Normal(name) => Some(component(name)),
                _ => Some(Err(HostError::InvalidPath)),
            })
            .collect::<Result<_, _>>()?;
        if private && names.is_empty() {
            return Err(HostError::InvalidPath);
        }
        // SAFETY: constant string, fixed flags, fresh descriptor ownership.
        let file = descriptor(unsafe {
            libc::open(
                c"/".as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        })?;
        let metadata = file
            .metadata()
            .map_err(|e| from_io(e, HostOperation::Stat))?;
        let mut current = Self(Arc::new(DirectoryNode {
            identity: FileSnapshot::metadata(&metadata).identity,
            file,
            parent: None,
            name: CString::new("/").unwrap(),
            path: PathBuf::from("/"),
            private: false,
            trusted_ancestors,
        }));
        for (index, name) in names.iter().enumerate() {
            let final_component = index + 1 == names.len();
            current = current.open_child(name, private && final_component, trusted_ancestors)?;
        }
        current.revalidate()?;
        Ok(current)
    }

    fn open_child(
        &self,
        name: &CString,
        private: bool,
        trusted_ancestors: bool,
    ) -> Result<Self, HostError> {
        // SAFETY: held parent and valid component; ownership transferred once.
        let file = descriptor(unsafe {
            libc::openat(
                self.0.file.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        })?;
        let metadata = file
            .metadata()
            .map_err(|e| from_io(e, HostOperation::Stat))?;
        if !metadata.is_dir() {
            return Err(HostError::NotDirectory);
        }
        if private {
            require_private_security(&file, &metadata)?;
        }
        if trusted_ancestors {
            require_trusted_ancestor(&metadata)?;
        }
        Ok(Self(Arc::new(DirectoryNode {
            identity: FileSnapshot::metadata(&metadata).identity,
            file,
            parent: Some(self.0.clone()),
            name: name.clone(),
            path: self.0.path.join(OsStr::from_bytes(name.as_bytes())),
            private,
            trusted_ancestors,
        })))
    }

    pub fn identity(&self) -> FileIdentity {
        self.0.identity
    }
    pub fn path(&self) -> &Path {
        &self.0.path
    }

    pub fn revalidate(&self) -> Result<(), HostError> {
        let metadata = self
            .0
            .file
            .metadata()
            .map_err(|e| from_io(e, HostOperation::Stat))?;
        if !metadata.is_dir()
            || metadata.nlink() == 0
            || FileSnapshot::metadata(&metadata).identity != self.0.identity
        {
            return Err(HostError::IdentityMismatch);
        }
        if self.0.private {
            require_private_security(&self.0.file, &metadata)?;
        }
        if self.0.trusted_ancestors {
            require_trusted_ancestor(&metadata)?;
        }
        if let Some(parent) = &self.0.parent {
            Self(parent.clone()).revalidate()?;
            let linked = stat_child(&parent.file, &self.0.name)?;
            if linked.st_mode & libc::S_IFMT != libc::S_IFDIR
                || stat_identity(&linked) != self.0.identity
            {
                return Err(HostError::IdentityMismatch);
            }
        }
        Ok(())
    }

    pub fn create_private_child(&self, name: &str) -> Result<Self, HostError> {
        if !self.0.private {
            return Err(HostError::NotPrivate);
        }
        let name = component(OsStr::new(name))?;
        self.revalidate()?;
        // SAFETY: live parent, single component, private mode for a new directory.
        if unsafe { libc::mkdirat(self.0.file.as_raw_fd(), name.as_ptr(), 0o700) } != 0 {
            return Err(os_error(HostOperation::CreateDirectory));
        }
        let child = self.open_child(&name, true, true)?;
        child.revalidate()?;
        self.sync()?;
        Ok(child)
    }

    pub fn open_private_child(&self, name: &str) -> Result<Self, HostError> {
        self.revalidate()?;
        if !self.0.private {
            return Err(HostError::NotPrivate);
        }
        self.open_child(&component(OsStr::new(name))?, true, true)
    }

    pub fn ensure_private_child(&self, name: &str) -> Result<Self, HostError> {
        match self.create_private_child(name) {
            Ok(child) => Ok(child),
            Err(HostError::AlreadyExists) => self.open_private_child(name),
            Err(error) => Err(error),
        }
    }

    /// Exact membership in a disposable private directory. Names are native
    /// components supplied by the caller; never a permissive glob or SQL rule.
    pub fn require_file_membership(
        &self,
        expected: &[&str],
        budget: &IoBudget,
    ) -> Result<(), HostError> {
        self.require_private_membership(expected, &[], budget)
    }

    pub fn require_private_membership(
        &self,
        files: &[&str],
        directories: &[&str],
        budget: &IoBudget,
    ) -> Result<(), HostError> {
        if !self.0.private {
            return Err(HostError::NotPrivate);
        }
        let expected = files.iter().chain(directories).copied().collect::<Vec<_>>();
        if expected.is_empty() || expected.len() > 64 {
            return Err(HostError::InvalidLimit);
        }
        let mut expected = expected
            .iter()
            .map(|name| component(OsStr::new(name)))
            .collect::<Result<Vec<_>, _>>()?;
        expected.sort_unstable_by(|a, b| a.as_bytes().cmp(b.as_bytes()));
        if expected.windows(2).any(|pair| pair[0] == pair[1]) {
            return Err(HostError::InvalidEvidence);
        }
        if directory::names_bounded(self, budget, 64)? != expected {
            return Err(HostError::InvalidEvidence);
        }
        for name in files {
            let name = component(OsStr::new(name))?;
            self.open_file_component(name, true)?.verify()?;
        }
        for name in directories {
            self.open_private_child(name)?.revalidate()?;
        }
        self.revalidate()
    }

    pub fn open_file(&self, name: &str) -> Result<HeldFile, HostError> {
        self.open_file_component(component(OsStr::new(name))?, self.0.private)
    }

    fn open_file_component(&self, name: CString, private: bool) -> Result<HeldFile, HostError> {
        self.revalidate()?;
        // O_NONBLOCK prevents a FIFO from blocking before fstat can reject it.
        // SAFETY: held parent, valid component; new descriptor transferred once.
        let file = descriptor(unsafe {
            libc::openat(
                self.0.file.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
            )
        })?;
        HeldFile::bound(file, self.clone(), name, private)
    }

    fn create_file(&self, name: &CString) -> Result<File, HostError> {
        if !self.0.private {
            return Err(HostError::NotPrivate);
        }
        self.revalidate()?;
        // SAFETY: fresh, exclusive regular file; no existing user file is chmod'd.
        descriptor(unsafe {
            libc::openat(
                self.0.file.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDWR | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600,
            )
        })
    }

    pub fn write_new_readonly(
        &self,
        name: &str,
        bytes: &[u8],
        budget: &IoBudget,
    ) -> Result<HeldFile, HostError> {
        if bytes.len() as u64 > budget.maximum_bytes {
            return Err(HostError::LimitExceeded);
        }
        budget.check()?;
        let name = component(OsStr::new(name))?;
        let file = self.create_file(&name)?;
        let identity = FileSnapshot::metadata(
            &file
                .metadata()
                .map_err(|e| from_io(e, HostOperation::Stat))?,
        )
        .identity;
        let result = (|| {
            for (index, chunk) in bytes.chunks(CHUNK_BYTES).enumerate() {
                budget.check()?;
                file.write_all_at(chunk, (index * CHUNK_BYTES) as u64)
                    .map_err(|e| from_io(e, HostOperation::Write))?;
            }
            self.seal(&file, &name, false, budget)
        })();
        match result {
            Ok(value) => Ok(value),
            Err(error) => {
                self.remove_owned_component(&name, identity)
                    .map_err(|_| HostError::CleanupFailed)?;
                Err(error)
            }
        }
    }

    fn seal(
        &self,
        file: &File,
        name: &CString,
        executable: bool,
        budget: &IoBudget,
    ) -> Result<HeldFile, HostError> {
        budget.check()?;
        // SAFETY: owned fresh file; set owner-only mode on its exact descriptor.
        if unsafe { libc::fchmod(file.as_raw_fd(), if executable { 0o500 } else { 0o400 }) } != 0 {
            return Err(os_error(HostOperation::SetPermissions));
        }
        file.sync_all()
            .map_err(|e| from_io(e, HostOperation::Sync))?;
        self.sync()?;
        let identity = FileSnapshot::metadata(
            &file
                .metadata()
                .map_err(|e| from_io(e, HostOperation::Stat))?,
        )
        .identity;
        let sealed = self.open_file_component(name.clone(), true)?;
        if sealed.initial.identity != identity {
            return Err(HostError::IdentityMismatch);
        }
        budget.check()?;
        Ok(sealed)
    }

    pub fn copy_snapshot(
        &self,
        source: &HeldFile,
        name: &str,
        executable: bool,
        budget: &IoBudget,
    ) -> Result<(HeldFile, SourceFacts), HostError> {
        self.copy_snapshot_observed(source, name, executable, budget, |_| Ok(()))
    }

    fn copy_snapshot_observed(
        &self,
        source: &HeldFile,
        name: &str,
        executable: bool,
        budget: &IoBudget,
        mut after_chunk: impl FnMut(u64) -> Result<(), HostError>,
    ) -> Result<(HeldFile, SourceFacts), HostError> {
        source.verify()?;
        if source.initial.byte_count > budget.maximum_bytes {
            return Err(HostError::LimitExceeded);
        }
        budget.check()?;
        let name = component(OsStr::new(name))?;
        let output = self.create_file(&name)?;
        let identity = FileSnapshot::metadata(
            &output
                .metadata()
                .map_err(|e| from_io(e, HostOperation::Stat))?,
        )
        .identity;
        let result = (|| {
            let facts = source.scan(budget, |offset, chunk| {
                output
                    .write_all_at(chunk, offset)
                    .map_err(|e| from_io(e, HostOperation::Write))?;
                after_chunk(offset)
            })?;
            let sealed = self.seal(&output, &name, executable, budget)?;
            if sealed.initial.byte_count != facts.byte_count {
                return Err(HostError::Changed);
            }
            // Verify the exact output independently, after closing writable access.
            drop(output);
            if sealed.facts(budget)? != facts {
                return Err(HostError::Changed);
            }
            Ok((sealed, facts))
        })();
        match result {
            Ok(value) => Ok(value),
            Err(error) => {
                self.remove_owned_component(&name, identity)
                    .map_err(|_| HostError::CleanupFailed)?;
                Err(error)
            }
        }
    }

    pub fn promote_noreplace(
        &self,
        file: &HeldFile,
        destination: &Self,
        name: &str,
        budget: &IoBudget,
    ) -> Result<HeldFile, HostError> {
        self.promote_observed(file, destination, name, budget, || {}, || {})
    }

    fn promote_observed(
        &self,
        file: &HeldFile,
        destination: &Self,
        name: &str,
        budget: &IoBudget,
        before_publication: impl FnOnce(),
        after_publication: impl FnOnce(),
    ) -> Result<HeldFile, HostError> {
        if file.parent.identity() != self.identity() || !file.private || !destination.0.private {
            return Err(HostError::NotPrivate);
        }
        if self.identity().device != destination.identity().device {
            return Err(HostError::CrossVolume);
        }
        if file.initial.byte_count > budget.maximum_bytes {
            return Err(HostError::LimitExceeded);
        }
        let name = component(OsStr::new(name))?;
        budget.check()?;
        file.verify()?;
        destination.revalidate()?;
        file.file
            .sync_all()
            .map_err(|e| from_io(e, HostOperation::Sync))?;
        before_publication();
        budget.cancellation.publication(|| {
            budget.check_deadline()?;
            // A caller may have waited behind cancellation or another publisher.
            // Recheck path bindings inside the publication critical section.
            file.verify()?;
            destination.revalidate()?;
            // SAFETY: live held parents and names. RENAME_EXCL is atomic and
            // refuses an existing file, directory or symlink destination.
            if unsafe {
                libc::renameatx_np(
                    self.0.file.as_raw_fd(),
                    file.name.as_ptr(),
                    destination.0.file.as_raw_fd(),
                    name.as_ptr(),
                    libc::RENAME_EXCL,
                )
            } != 0
            {
                return Err(os_error(HostOperation::Rename));
            }
            Ok(())
        })?;
        after_publication();
        let result = (|| {
            self.sync()?;
            destination.sync()?;
            let ready = destination.open_file_component(name.clone(), true)?;
            if ready.initial.identity != file.initial.identity {
                return Err(HostError::IdentityMismatch);
            }
            // rename legitimately changes ctime. Size, mode, ownership, links
            // and mtime must still match the exact sealed candidate; checking
            // only inode/size would accept a same-size in-place mutation.
            let mut expected = file.initial;
            expected.change = ready.initial.change;
            if ready.initial != expected {
                return Err(HostError::Changed);
            }
            budget.check()?;
            Ok(ready)
        })();
        match result {
            Ok(ready) => Ok(ready),
            Err(error) => {
                destination
                    .remove_owned_component(&name, file.initial.identity)
                    .map_err(|_| HostError::CleanupFailed)?;
                Err(error)
            }
        }
    }

    pub fn remove_owned_file(&self, name: &str, expected: FileIdentity) -> Result<(), HostError> {
        self.remove_owned_component(&component(OsStr::new(name))?, expected)
    }

    fn remove_owned_component(
        &self,
        name: &CString,
        expected: FileIdentity,
    ) -> Result<(), HostError> {
        if !self.0.private {
            return Err(HostError::NotPrivate);
        }
        self.revalidate()?;
        let before = stat_child(&self.0.file, name)?;
        if before.st_mode & libc::S_IFMT != libc::S_IFREG || stat_identity(&before) != expected {
            return Err(HostError::IdentityMismatch);
        }
        let quarantine = (0..8)
            .find_map(|_| {
                let serial = NEXT_QUARANTINE.fetch_add(1, Ordering::Relaxed);
                let candidate =
                    CString::new(format!(".arktrace-remove-{}-{serial}", std::process::id()))
                        .unwrap();
                // SAFETY: both names in the held private parent; refuses replacement.
                let result = unsafe {
                    libc::renameatx_np(
                        self.0.file.as_raw_fd(),
                        name.as_ptr(),
                        self.0.file.as_raw_fd(),
                        candidate.as_ptr(),
                        libc::RENAME_EXCL,
                    )
                };
                if result == 0 {
                    Some(Ok(candidate))
                } else if io::Error::last_os_error().raw_os_error() == Some(libc::EEXIST) {
                    None
                } else {
                    Some(Err(os_error(HostOperation::Rename)))
                }
            })
            .unwrap_or(Err(HostError::AlreadyExists))?;
        let moved = stat_child(&self.0.file, &quarantine)?;
        if moved.st_mode & libc::S_IFMT != libc::S_IFREG || stat_identity(&moved) != expected {
            // A replacement won the rename window. Restore it without deleting
            // either an unrelated replacement or a subsequently created target.
            // SAFETY: live directory and valid names, no overwrite on restoration.
            if unsafe {
                libc::renameatx_np(
                    self.0.file.as_raw_fd(),
                    quarantine.as_ptr(),
                    self.0.file.as_raw_fd(),
                    name.as_ptr(),
                    libc::RENAME_EXCL,
                )
            } != 0
            {
                return Err(HostError::CleanupFailed);
            }
            return Err(HostError::IdentityMismatch);
        }
        // SAFETY: unlink the quarantined, identity-checked regular file only.
        if unsafe { libc::unlinkat(self.0.file.as_raw_fd(), quarantine.as_ptr(), 0) } != 0 {
            return Err(os_error(HostOperation::Remove));
        }
        self.sync()
    }

    pub fn sync(&self) -> Result<(), HostError> {
        self.revalidate()?;
        self.0
            .file
            .sync_all()
            .map_err(|e| from_io(e, HostOperation::Sync))
    }
}

#[cfg(test)]
#[path = "macos_tests.rs"]
mod tests;

impl HeldFile {
    /// Explicit raw inputs may resolve links once. The canonical parents and
    /// final file are then opened no-follow and held for every subsequent read.
    pub fn open_explicit_source(path: &Path) -> Result<Self, HostError> {
        if !path.is_absolute() {
            return Err(HostError::InvalidPath);
        }
        let canonical = std::fs::canonicalize(path).map_err(|e| from_io(e, HostOperation::Open))?;
        let parent = HeldDirectory::open(canonical.parent().ok_or(HostError::InvalidPath)?, false)?;
        parent.open_file_component(
            component(canonical.file_name().ok_or(HostError::InvalidPath)?)?,
            false,
        )
    }

    fn bound(
        file: File,
        parent: HeldDirectory,
        name: CString,
        private: bool,
    ) -> Result<Self, HostError> {
        let metadata = file
            .metadata()
            .map_err(|e| from_io(e, HostOperation::Stat))?;
        if !metadata.is_file() {
            return Err(HostError::NotRegular);
        }
        if private {
            require_private_security(&file, &metadata)?;
            if metadata.nlink() != 1 {
                return Err(HostError::LinkedObject);
            }
        }
        let value = Self {
            file,
            initial: FileSnapshot::metadata(&metadata),
            parent,
            name,
            private,
        };
        value.verify()?;
        Ok(value)
    }

    pub fn snapshot(&self) -> FileSnapshot {
        self.initial
    }

    pub fn path(&self) -> PathBuf {
        self.parent
            .path()
            .join(OsStr::from_bytes(self.name.as_bytes()))
    }

    /// Native SQLite reopening path for this exact, private immutable file.
    /// The caller must retain this HeldFile for the connection's whole lifetime
    /// and revalidate it around database work. This is not a user input path.
    pub fn readonly_database_path(&self) -> Result<PathBuf, HostError> {
        self.verify()?;
        if !self.private || self.initial.mode & 0o7777 != 0o400 {
            return Err(HostError::NotPrivate);
        }
        for suffix in [
            b"-journal".as_slice(),
            b"-wal".as_slice(),
            b"-shm".as_slice(),
        ] {
            let mut name = self.name.as_bytes().to_vec();
            name.extend_from_slice(suffix);
            let name = component(OsStr::from_bytes(&name))?;
            match stat_child(&self.parent.0.file, &name) {
                Err(HostError::NotFound) => {}
                Ok(_) => return Err(HostError::InvalidEvidence),
                Err(error) => return Err(error),
            }
        }
        Ok(PathBuf::from(format!("/dev/fd/{}", self.file.as_raw_fd())))
    }

    /// Inspect a small header without materializing the complete source. The
    /// budget's byte bound still applies to the full file; prefix is <=1 MiB.
    pub fn read_prefix(
        &self,
        prefix_bytes: usize,
        budget: &IoBudget,
    ) -> Result<Vec<u8>, HostError> {
        if prefix_bytes == 0 || prefix_bytes > CHUNK_BYTES {
            return Err(HostError::InvalidLimit);
        }
        budget.check()?;
        if self.initial.byte_count > budget.maximum_bytes {
            return Err(HostError::LimitExceeded);
        }
        self.verify()?;
        let mut bytes = vec![0; prefix_bytes.min(self.initial.byte_count as usize)];
        let mut offset = 0;
        while offset < bytes.len() {
            budget.check()?;
            let count = match self.file.read_at(&mut bytes[offset..], offset as u64) {
                Ok(count) => count,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(from_io(error, HostOperation::Read)),
            };
            if count == 0 {
                return Err(HostError::Changed);
            }
            offset += count;
        }
        budget.check()?;
        self.verify()?;
        Ok(bytes)
    }

    pub fn verify(&self) -> Result<(), HostError> {
        self.parent.revalidate()?;
        let linked = stat_child(&self.parent.0.file, &self.name)?;
        if linked.st_mode & libc::S_IFMT != libc::S_IFREG
            || stat_identity(&linked) != self.initial.identity
        {
            return Err(HostError::IdentityMismatch);
        }
        let metadata = self
            .file
            .metadata()
            .map_err(|e| from_io(e, HostOperation::Stat))?;
        if FileSnapshot::metadata(&metadata) != self.initial {
            return Err(HostError::Changed);
        }
        if self.private {
            require_private_security(&self.file, &metadata)?;
        }
        Ok(())
    }

    fn scan(
        &self,
        budget: &IoBudget,
        mut consume: impl FnMut(u64, &[u8]) -> Result<(), HostError>,
    ) -> Result<SourceFacts, HostError> {
        if budget.maximum_bytes == 0 {
            return Err(HostError::InvalidLimit);
        }
        if self.initial.byte_count > budget.maximum_bytes
            || self.initial.byte_count > i64::MAX as u64
        {
            return Err(HostError::LimitExceeded);
        }
        budget.check()?;
        self.verify()?;
        let mut buffer = vec![0; CHUNK_BYTES];
        let mut offset = 0_u64;
        let mut hash = Sha256::new();
        loop {
            budget.check()?;
            let count = match self.file.read_at(&mut buffer, offset) {
                Ok(value) => value,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(from_io(error, HostOperation::Read)),
            };
            if count == 0 {
                break;
            }
            let next = offset
                .checked_add(count as u64)
                .ok_or(HostError::LimitExceeded)?;
            if next > budget.maximum_bytes || next > self.initial.byte_count {
                return Err(HostError::Changed);
            }
            hash.update(&buffer[..count]);
            consume(offset, &buffer[..count])?;
            offset = next;
        }
        budget.check()?;
        self.verify()?;
        if offset != self.initial.byte_count {
            return Err(HostError::Changed);
        }
        Ok(SourceFacts {
            sha256: format!("{:x}", hash.finalize()),
            byte_count: offset,
        })
    }

    pub fn facts(&self, budget: &IoBudget) -> Result<SourceFacts, HostError> {
        self.scan(budget, |_, _| Ok(()))
    }

    pub fn read_bounded(&self, budget: &IoBudget) -> Result<Vec<u8>, HostError> {
        if self.initial.byte_count > budget.maximum_bytes {
            return Err(HostError::LimitExceeded);
        }
        let capacity =
            usize::try_from(self.initial.byte_count).map_err(|_| HostError::LimitExceeded)?;
        let mut bytes = Vec::new();
        bytes
            .try_reserve_exact(capacity)
            .map_err(|_| HostError::LimitExceeded)?;
        self.scan(budget, |_, chunk| {
            bytes.extend_from_slice(chunk);
            Ok(())
        })?;
        Ok(bytes)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LeaseMode {
    Shared,
    Exclusive,
}

pub struct Lease {
    file: File,
    parent: HeldDirectory,
    name: CString,
    identity: FileIdentity,
    mode: LeaseMode,
    newly_created: bool,
}

/// Fresh per-session lease. Unlike stable cache locks, its name may be removed
/// after the owned ephemeral entry is gone. Existing names are never admitted.
pub struct EphemeralLease(Lease);
impl EphemeralLease {
    pub fn acquire(
        parent: &HeldDirectory,
        name: &str,
        budget: &IoBudget,
    ) -> Result<Self, HostError> {
        budget.check()?;
        Lease::try_acquire_impl(parent, name, LeaseMode::Exclusive, true, true)?
            .map(Self)
            .ok_or(HostError::Busy)
    }
    pub fn revalidate(&self) -> Result<(), HostError> {
        self.0.revalidate()
    }
    pub fn remove(self) -> Result<(), HostError> {
        self.0.revalidate()?;
        if !self.0.newly_created || self.0.mode != LeaseMode::Exclusive {
            return Err(HostError::InvalidEvidence);
        }
        self.0
            .parent
            .remove_owned_component(&self.0.name, self.0.identity)?;
        self.0.parent.sync()
    }
}

impl Lease {
    /// Uses the same empty-file flock protocol as the existing Swift writer and
    /// ArkDeck purger. Existing lease modes/owners/links are validated unchanged.
    pub fn try_acquire(
        parent: &HeldDirectory,
        name: &str,
        mode: LeaseMode,
        create: bool,
    ) -> Result<Option<Self>, HostError> {
        Self::try_acquire_impl(parent, name, mode, create, false)
    }
    fn try_acquire_impl(
        parent: &HeldDirectory,
        name: &str,
        mode: LeaseMode,
        create: bool,
        require_fresh: bool,
    ) -> Result<Option<Self>, HostError> {
        if !parent.0.private {
            return Err(HostError::NotPrivate);
        }
        parent.revalidate()?;
        let name = component(OsStr::new(name))?;
        let flags = libc::O_RDWR | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK;
        // SAFETY: held parent and component; exclusive create never chmods an existing file.
        let mut fd = if create {
            unsafe {
                libc::openat(
                    parent.0.file.as_raw_fd(),
                    name.as_ptr(),
                    flags | libc::O_CREAT | libc::O_EXCL,
                    0o600,
                )
            }
        } else {
            -1
        };
        let newly_created = create && fd >= 0;
        if require_fresh && !newly_created {
            return Err(os_error(HostOperation::Open));
        }
        if !create || (fd < 0 && io::Error::last_os_error().raw_os_error() == Some(libc::EEXIST)) {
            // SAFETY: existing file opened without following links.
            fd = unsafe { libc::openat(parent.0.file.as_raw_fd(), name.as_ptr(), flags) };
        }
        let file = descriptor(fd)?;
        let metadata = file
            .metadata()
            .map_err(|e| from_io(e, HostOperation::Stat))?;
        if !metadata.is_file() {
            return Err(HostError::NotRegular);
        }
        require_private_security(&file, &metadata)?;
        if metadata.nlink() != 1 {
            return Err(HostError::LinkedObject);
        }
        let operation = if mode == LeaseMode::Shared {
            libc::LOCK_SH
        } else {
            libc::LOCK_EX
        };
        // SAFETY: live owned descriptor. Nonblocking prevents an unbounded wait.
        if unsafe { libc::flock(file.as_raw_fd(), operation | libc::LOCK_NB) } != 0 {
            let error = os_error(HostOperation::Lock);
            if require_fresh {
                parent
                    .remove_owned_component(&name, FileSnapshot::metadata(&metadata).identity)
                    .map_err(|_| HostError::CleanupFailed)?;
                parent.sync().map_err(|_| HostError::CleanupFailed)?;
                return Err(error);
            }
            if io::Error::last_os_error().raw_os_error() == Some(libc::EWOULDBLOCK) {
                return Ok(None);
            }
            return Err(os_error(HostOperation::Lock));
        }
        let lease = Self {
            file,
            parent: parent.clone(),
            name,
            identity: FileSnapshot::metadata(&metadata).identity,
            mode,
            newly_created,
        };
        lease.revalidate()?;
        Ok(Some(lease))
    }

    pub fn acquire(
        parent: &HeldDirectory,
        name: &str,
        mode: LeaseMode,
        budget: &IoBudget,
    ) -> Result<Self, HostError> {
        loop {
            budget.check()?;
            if let Some(lease) = Self::try_acquire(parent, name, mode, true)? {
                return Ok(lease);
            }
            thread::sleep(
                Duration::from_millis(5)
                    .min(budget.deadline.saturating_duration_since(Instant::now())),
            );
        }
    }

    pub fn mode(&self) -> LeaseMode {
        self.mode
    }

    pub fn revalidate(&self) -> Result<(), HostError> {
        self.parent.revalidate()?;
        let linked = stat_child(&self.parent.0.file, &self.name)?;
        let metadata = self
            .file
            .metadata()
            .map_err(|e| from_io(e, HostOperation::Stat))?;
        if linked.st_mode & libc::S_IFMT != libc::S_IFREG
            || stat_identity(&linked) != self.identity
            || FileSnapshot::metadata(&metadata).identity != self.identity
            || metadata.nlink() != 1
        {
            return Err(HostError::IdentityMismatch);
        }
        require_private_security(&self.file, &metadata)
    }
}
