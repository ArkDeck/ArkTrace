//! CLI-only kernel image, OS-owned temporary root and POSIX signal boundary.
use super::{
    CodeTrustPolicy, FileIdentity, HeldDirectory, HeldFile, HostError, IoBudget, ProcessError,
    SourceFacts, TrustVerdict, descriptor, trust,
};
use crate::CancellationToken;
use std::{
    ffi::{OsStr, OsString, c_void},
    fs::File,
    io::{Read, Write},
    marker::PhantomData,
    os::{fd::AsRawFd, unix::ffi::OsStringExt},
    path::{Path, PathBuf},
    ptr,
    rc::Rc,
    sync::{
        Arc, OnceLock,
        atomic::{AtomicBool, AtomicI32, AtomicU8, Ordering},
    },
    thread::{self, JoinHandle},
};

// Public sys/proc_info.h in the selected Xcode 27 SDK. libc already supplies
// vnode_info_path/vinfo_stat, but not proc_regioninfo/regionwithpathinfo.
#[repr(C)]
struct RegionInfo {
    protection: [u32; 4],
    offset: u64,
    counts: [u32; 14],
    address: u64,
    size: u64,
}
#[repr(C)]
struct RegionPath {
    region: RegionInfo,
    vnode: libc::vnode_info_path,
}
const _: () = assert!(std::mem::size_of::<RegionInfo>() == 96);
const _: () = assert!(std::mem::size_of::<RegionPath>() == 1272);
unsafe extern "C" {
    fn _dyld_get_image_header(index: u32) -> *const c_void;
}
fn mapped_image() -> Result<(PathBuf, FileIdentity), HostError> {
    // SAFETY: image zero is this process's mapped main Mach-O image; query
    // address is used only as a kernel proc_pidinfo input, never dereferenced.
    let header = unsafe { _dyld_get_image_header(0) };
    if header.is_null() {
        return Err(HostError::InvalidEvidence);
    }
    // SAFETY: all fields are integer/byte POD and zero is valid initialization.
    let mut info: RegionPath = unsafe { std::mem::zeroed() };
    // SAFETY: kernel writes exactly a public fixed-layout RegionPath buffer.
    let read = unsafe {
        libc::proc_pidinfo(
            libc::getpid(),
            8,
            header as usize as u64,
            (&mut info as *mut RegionPath).cast(),
            std::mem::size_of::<RegionPath>() as i32,
        )
    };
    if read != std::mem::size_of::<RegionPath>() as i32 {
        return Err(HostError::InvalidEvidence);
    }
    let stat = &info.vnode.vip_vi.vi_stat;
    if stat.vst_mode as u32 & libc::S_IFMT as u32 != libc::S_IFREG as u32 || stat.vst_ino == 0 {
        return Err(HostError::InvalidEvidence);
    }
    let bytes = info
        .vnode
        .vip_path
        .iter()
        .flatten()
        .map(|v| *v as u8)
        .collect::<Vec<_>>();
    let end = bytes
        .iter()
        .position(|v| *v == 0)
        .ok_or(HostError::InvalidPath)?;
    if end == 0 || bytes[0] != b'/' {
        return Err(HostError::InvalidPath);
    }
    Ok((
        PathBuf::from(OsString::from_vec(bytes[..end].to_vec())),
        FileIdentity {
            device: stat.vst_dev as u64,
            inode: stat.vst_ino,
        },
    ))
}
pub struct MappedExecutable {
    path: PathBuf,
    file: HeldFile,
    identity: FileIdentity,
}
impl MappedExecutable {
    pub fn current() -> Result<Self, HostError> {
        let (path, identity) = mapped_image()?;
        let file = HeldFile::open_explicit_source(&path)?;
        if file.snapshot().identity != identity {
            return Err(HostError::IdentityMismatch);
        }
        Ok(Self {
            path,
            file,
            identity,
        })
    }
    pub fn path(&self) -> &Path {
        &self.path
    }
    pub fn facts(&self, budget: &IoBudget) -> Result<SourceFacts, HostError> {
        self.verify()?;
        let facts = self.file.facts(budget)?;
        self.verify()?;
        Ok(facts)
    }
    fn verify(&self) -> Result<(), HostError> {
        self.file.verify()?;
        if mapped_image()?.1 != self.identity {
            return Err(HostError::IdentityMismatch);
        }
        Ok(())
    }
    /// The bundle's sealed resource table must belong to the actual mapped
    /// main CodeDirectory, rather than a different App at a replaced path.
    pub fn verify_bundle(
        &self,
        bundle: &Path,
        policy: &CodeTrustPolicy,
    ) -> Result<TrustVerdict, ProcessError> {
        self.verify()?;
        let image = trust::verify_path(&self.file.path(), policy)?;
        let sealed = trust::verify_path(bundle, policy)?;
        if image.code_directory_hash != sealed.code_directory_hash {
            return Err(ProcessError::TrustRejected);
        }
        self.verify()?;
        Ok(sealed)
    }
}

/// Never consults TMPDIR/HOME. Existing permissions/ACLs are validated, not
/// repaired. Names are supplied by the consuming product configuration.
pub fn user_temporary_workspace(name: &str) -> Result<HeldDirectory, HostError> {
    let _ = super::component(OsStr::new(name))?;
    // Darwin confstr(USER_TEMP_DIR) may fall back to caller TMPDIR when the
    // directory-helper service is unavailable (including process sandboxes).
    // The CLI uses the canonical system sticky parent plus an euid-scoped
    // private product directory. No environment fallback or permission repair.
    let parent = HeldDirectory::open_trusted_temporary_parent(Path::new("/private/tmp"))?;
    let metadata = parent
        .0
        .file
        .metadata()
        .map_err(|e| super::from_io(e, super::HostOperation::Stat))?;
    use std::os::unix::fs::MetadataExt;
    if metadata.uid() != 0 || metadata.mode() & 0o1000 == 0 {
        return Err(HostError::NotPrivate);
    }
    // SAFETY: geteuid has no pointers, ownership, or environment dependence.
    let uid = unsafe { libc::geteuid() };
    let name = super::component(OsStr::new(&format!("{name}-u{uid}")))?;
    parent.revalidate()?;
    // This narrowly scoped public sticky-parent creation is separate from
    // ordinary private staging, whose parent must already be owner-only.
    // SAFETY: retained trusted parent, validated one-component name, fresh
    // directory requested with 0700; an existing object is never chmod'd.
    if unsafe { libc::mkdirat(parent.0.file.as_raw_fd(), name.as_ptr(), 0o700) } != 0 {
        let error = super::os_error(super::HostOperation::CreateDirectory);
        if error != HostError::AlreadyExists {
            return Err(error);
        }
    }
    let child = parent.open_child(&name, true, true)?;
    child.revalidate()?;
    parent.sync()?;
    Ok(child)
}

static SIGNAL_USED: AtomicBool = AtomicBool::new(false);
static SIGNAL_COUNT: AtomicU8 = AtomicU8::new(0);
static SIGNAL_WRITE: AtomicI32 = AtomicI32::new(-1);
// Keep the single CLI invocation's write descriptor alive until process exit.
// A handler already in flight cannot write to a closed/reused descriptor.
static SIGNAL_FILE: OnceLock<Arc<File>> = OnceLock::new();
extern "C" fn signal_handler(number: i32) {
    // SAFETY: errno is thread-local. Handler uses lock-free atomics and POSIX
    // async-signal-safe write/_exit only; cancellation work runs on the reader.
    let saved = unsafe { *libc::__error() };
    if SIGNAL_COUNT.fetch_add(1, Ordering::Relaxed) != 0 {
        // SAFETY: second signal is the documented immediate forced exit.
        unsafe { libc::_exit(128 + number) };
    }
    let fd = SIGNAL_WRITE.load(Ordering::Relaxed);
    let byte = number as u8;
    if fd >= 0 {
        // SAFETY: process-lifetime descriptor and one stack byte; nonblocking.
        let _ = unsafe { libc::write(fd, (&byte as *const u8).cast(), 1) };
    }
    // SAFETY: restore the interrupted thread's errno before returning.
    unsafe { *libc::__error() = saved };
}
pub struct CliSignalGuard {
    previous: Vec<(i32, libc::sigaction)>,
    writer: Arc<File>,
    worker: Option<JoinHandle<()>>,
    token: CancellationToken,
    previous_mask: Option<libc::sigset_t>,
    same_thread: PhantomData<Rc<()>>,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CliWriteFailure {
    pub error: HostError,
    pub written: usize,
}
struct OutputFlags {
    file: File,
    original: i32,
}
impl OutputFlags {
    fn restore(&self) -> Result<(), HostError> {
        // SAFETY: retained output descriptor and flags read from this same OFD.
        if unsafe { libc::fcntl(self.file.as_raw_fd(), libc::F_SETFL, self.original) } != 0 {
            return Err(super::os_error(super::HostOperation::Write));
        }
        Ok(())
    }
}
impl Drop for OutputFlags {
    fn drop(&mut self) {
        let _ = self.restore();
    }
}
impl CliSignalGuard {
    /// Whole-buffer stdout commit with request cancellation/deadline and
    /// bounded poll waits. Restores inherited OFD flags on every ordinary exit.
    /// The exact committed byte count prevents a second JSON frame after a
    /// partial write; SIGPIPE is ignored by this CLI-only guard.
    pub fn write_stdout(&self, bytes: &[u8], budget: &IoBudget) -> Result<(), CliWriteFailure> {
        self.write_descriptor(libc::STDOUT_FILENO, bytes, budget)
    }
    pub fn write_stderr(&self, bytes: &[u8], budget: &IoBudget) -> Result<(), CliWriteFailure> {
        self.write_descriptor(libc::STDERR_FILENO, bytes, budget)
    }
    fn write_descriptor(
        &self,
        descriptor_number: i32,
        bytes: &[u8],
        budget: &IoBudget,
    ) -> Result<(), CliWriteFailure> {
        let mut written = 0;
        let result = (|| {
            // SAFETY: borrow the inherited stdout via a fresh owned duplicate.
            let file = descriptor(unsafe { libc::dup(descriptor_number) })?;
            // SAFETY: fixed fcntl query for a live owned descriptor.
            let original = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETFL) };
            if original < 0 {
                return Err(super::os_error(super::HostOperation::Write));
            }
            let flags = OutputFlags { file, original };
            // SAFETY: temporary nonblocking flag, restored before return.
            if unsafe {
                libc::fcntl(
                    flags.file.as_raw_fd(),
                    libc::F_SETFL,
                    original | libc::O_NONBLOCK,
                )
            } != 0
            {
                return Err(super::os_error(super::HostOperation::Write));
            }
            let result = (|| {
                if bytes.len() as u64 > budget.maximum_bytes {
                    return Err(HostError::LimitExceeded);
                }
                while written < bytes.len() {
                    self.check_pending();
                    budget.check()?;
                    let count = (bytes.len() - written).min(65536);
                    // SAFETY: live fd and bounded readable remaining buffer.
                    let n = unsafe {
                        libc::write(
                            flags.file.as_raw_fd(),
                            bytes[written..].as_ptr().cast(),
                            count,
                        )
                    };
                    if n > 0 {
                        written += n as usize;
                        continue;
                    }
                    if n == 0 {
                        return Err(HostError::InvalidEvidence);
                    }
                    let error = std::io::Error::last_os_error();
                    if error.kind() == std::io::ErrorKind::Interrupted {
                        continue;
                    }
                    if error.kind() != std::io::ErrorKind::WouldBlock {
                        return Err(super::from_io(error, super::HostOperation::Write));
                    }
                    let mut poll = libc::pollfd {
                        fd: flags.file.as_raw_fd(),
                        events: libc::POLLOUT,
                        revents: 0,
                    };
                    let remaining = budget
                        .deadline
                        .saturating_duration_since(std::time::Instant::now());
                    let timeout = remaining.as_millis().min(25) as i32;
                    // SAFETY: one live pollfd; bounded by request deadline and
                    // 25ms cancellation latency, including a sub-ms final poll.
                    if unsafe { libc::poll(&mut poll, 1, timeout) } < 0
                        && std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted
                    {
                        return Err(super::os_error(super::HostOperation::Write));
                    }
                }
                Ok(())
            })();
            flags.restore()?;
            result
        })();
        result.map_err(|error| CliWriteFailure { error, written })
    }
    pub fn install(token: CancellationToken) -> Result<Self, HostError> {
        if SIGNAL_USED.swap(true, Ordering::SeqCst) {
            return Err(HostError::Busy);
        }
        let mut fds = [-1; 2];
        // SAFETY: valid two-fd output storage; owned descriptors below.
        if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
            return Err(HostError::InvalidEvidence);
        }
        let mut reader = descriptor(fds[0])?;
        let writer = Arc::new(descriptor(fds[1])?);
        for fd in [reader.as_raw_fd(), writer.as_raw_fd()] {
            // SAFETY: owned live pipe descriptor; no descriptors pass to exec.
            if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } != 0 {
                return Err(HostError::InvalidEvidence);
            }
        }
        // SAFETY: the writer must never block inside a signal handler.
        if unsafe { libc::fcntl(writer.as_raw_fd(), libc::F_SETFL, libc::O_NONBLOCK) } != 0 {
            return Err(HostError::InvalidEvidence);
        }
        SIGNAL_FILE
            .set(writer.clone())
            .map_err(|_| HostError::Busy)?;
        SIGNAL_WRITE.store(writer.as_raw_fd(), Ordering::SeqCst);
        let mut previous = Vec::new();
        for number in [libc::SIGINT, libc::SIGTERM, libc::SIGPIPE] {
            // SAFETY: sigaction is public POD; empty mask explicitly initialized.
            let mut action: libc::sigaction = unsafe { std::mem::zeroed() };
            let mut old: libc::sigaction = unsafe { std::mem::zeroed() };
            action.sa_sigaction = if number == libc::SIGPIPE {
                libc::SIG_IGN
            } else {
                signal_handler as *const () as usize
            };
            action.sa_flags = libc::SA_RESTART;
            // SAFETY: live action/out buffers and supported POSIX signals.
            if unsafe { libc::sigemptyset(&mut action.sa_mask) } != 0
                || unsafe { libc::sigaction(number, &action, &mut old) } != 0
            {
                for (number, old) in &previous {
                    // SAFETY: restore dispositions installed in this scope.
                    unsafe { libc::sigaction(*number, old, ptr::null_mut()) };
                }
                return Err(HostError::InvalidEvidence);
            }
            previous.push((number, old));
        }
        let cancellation = token.clone();
        let worker = thread::Builder::new()
            .name("arktrace-signals".to_owned())
            .spawn(move || {
                let mut byte = [0u8; 1];
                loop {
                    match reader.read(&mut byte) {
                        Ok(1) if byte[0] != 0 => cancellation.cancel(),
                        Ok(_) => break,
                        Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                        Err(_) => break,
                    }
                }
            })
            .map_err(|_| {
                for (number, old) in &previous {
                    // SAFETY: thread creation failed; restore installed actions.
                    unsafe { libc::sigaction(*number, old, ptr::null_mut()) };
                }
                HostError::InvalidEvidence
            })?;
        let mut guard = Self {
            previous,
            writer,
            worker: Some(worker),
            token,
            previous_mask: None,
            same_thread: PhantomData,
        };
        // A caller may have inherited a blocked INT/TERM mask. Explicitly
        // unblock on this invocation thread after installing safe handlers.
        // SAFETY: sigset_t is public POD; both output buffers are initialized.
        let mut unblocked: libc::sigset_t = unsafe { std::mem::zeroed() };
        let mut previous_mask: libc::sigset_t = unsafe { std::mem::zeroed() };
        // SAFETY: valid initialized masks; mask belongs to this thread only.
        if unsafe { libc::sigemptyset(&mut unblocked) } != 0
            || unsafe { libc::sigaddset(&mut unblocked, libc::SIGINT) } != 0
            || unsafe { libc::sigaddset(&mut unblocked, libc::SIGTERM) } != 0
            || unsafe { libc::pthread_sigmask(libc::SIG_UNBLOCK, &unblocked, &mut previous_mask) }
                != 0
        {
            return Err(HostError::InvalidEvidence);
        }
        guard.previous_mask = Some(previous_mask);
        Ok(guard)
    }
    pub fn check_pending(&self) {
        if SIGNAL_COUNT.load(Ordering::SeqCst) != 0 {
            self.token.cancel();
        }
    }
}
impl Drop for CliSignalGuard {
    fn drop(&mut self) {
        if let Some(mask) = &self.previous_mask {
            // SAFETY: !Send/!Sync guard restores the original thread's mask.
            unsafe { libc::pthread_sigmask(libc::SIG_SETMASK, mask, ptr::null_mut()) };
        }
        for (number, old) in &self.previous {
            // SAFETY: restore process dispositions while retaining handler fd.
            unsafe { libc::sigaction(*number, old, ptr::null_mut()) };
        }
        let _ = (&*self.writer).write_all(&[0]);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}
