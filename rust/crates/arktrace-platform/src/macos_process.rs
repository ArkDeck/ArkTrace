//! Verified native processes. A fixed supervisor owns parser process groups;
//! its private control pipe closes on Engine death, independently of callbacks.
use super::{
    FileIdentity, FileSnapshot, HeldDirectory, HeldFile,
    trust::{self, CodeTrustPolicy, TrustVerdict},
};
use crate::{CancellationToken, HostError, IoBudget};
use serde::{Deserialize, Serialize};
use std::{
    ffi::{CString, OsString},
    fs::File,
    io::{Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::ffi::{OsStrExt, OsStringExt},
    },
    path::{Path, PathBuf},
    ptr,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, Instant},
};

const REQUEST_LIMIT: usize = 131_072;
const RESPONSE_LIMIT: usize = 600_000;
const DIAGNOSTIC_LIMIT: usize = 65_536;
const TOOL_LIMIT: u64 = 256 * 1024 * 1024;
const CLEANUP_TIME: Duration = Duration::from_secs(2);

#[path = "macos_process_outputs.rs"]
mod outputs;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub enum ProcessError {
    Host(HostError),
    InvalidPolicy,
    InvalidArguments,
    InvalidExecutable,
    DigestMismatch,
    SignatureInvalid,
    TrustRejected,
    TrustUnavailable,
    LaunchFailed { code: i32 },
    StdoutLimitExceeded,
    StderrLimitExceeded,
    OutputFileLimitExceeded { index: u8 },
    ProtocolInvalid,
    Cancelled,
    DeadlineExceeded,
    CleanupFailed,
}
impl From<HostError> for ProcessError {
    fn from(value: HostError) -> Self {
        Self::Host(value)
    }
}
impl std::fmt::Display for ProcessError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for ProcessError {}

#[derive(Clone, Debug)]
pub struct ProcessOutputFileBudget {
    /// Fresh relative file path: at most eight no-follow private components,
    /// 1024 total bytes. The topmost output object must be initially absent.
    pub name: OsString,
    pub maximum_bytes: u64,
}

#[derive(Clone, Debug)]
pub struct ProcessBudget {
    pub deadline: Instant,
    pub cancellation: CancellationToken,
    pub stdout_bytes: usize,
    pub stderr_bytes: usize,
    pub termination_grace: Duration,
    /// Up to 16 optional, initially absent output files, monitored until the
    /// entire process group has stopped. Polling rejects excess, not a quota.
    pub output_files: Vec<ProcessOutputFileBudget>,
}
impl ProcessBudget {
    pub fn check(&self) -> Result<(), ProcessError> {
        if self.stdout_bytes == 0
            || self.stderr_bytes == 0
            || self.stdout_bytes > DIAGNOSTIC_LIMIT
            || self.stderr_bytes > DIAGNOSTIC_LIMIT
            || self.termination_grace > Duration::from_millis(500)
        {
            return Err(ProcessError::InvalidArguments);
        }
        outputs::validate(&self.output_files)?;
        if self.cancellation.is_cancelled() {
            return Err(ProcessError::Cancelled);
        }
        if Instant::now() >= self.deadline {
            return Err(ProcessError::DeadlineExceeded);
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProcessOutcome {
    pub exit_code: Option<i32>,
    pub signal: Option<i32>,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub escalated_to_kill: bool,
    /// Final sizes in declaration order; None means the optional file was never created.
    pub output_file_bytes: Vec<Option<u64>>,
}

pub struct VerifiedExecutable {
    file: HeldFile,
    sha256: String,
    policy: CodeTrustPolicy,
    verdict: TrustVerdict,
}
impl VerifiedExecutable {
    pub fn verify(
        file: HeldFile,
        expected_sha256: &str,
        policy: CodeTrustPolicy,
        budget: &IoBudget,
    ) -> Result<Self, ProcessError> {
        if file.initial.mode & 0o100 == 0 || file.initial.mode & 0o200 != 0 {
            return Err(ProcessError::InvalidExecutable);
        }
        if !file.private {
            if !matches!(policy, CodeTrustPolicy::DeveloperId { .. }) {
                return Err(ProcessError::InvalidExecutable);
            }
            file.require_signed_code_file()?;
        }
        if expected_sha256.len() != 64
            || !expected_sha256
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(ProcessError::InvalidPolicy);
        }
        if file.initial.byte_count > TOOL_LIMIT {
            return Err(ProcessError::InvalidExecutable);
        }
        let mut header = [0; 8];
        use std::os::unix::fs::FileExt;
        if file
            .file
            .read_at(&mut header, 0)
            .map_err(|_| ProcessError::InvalidExecutable)?
            != 8
            || header != [0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1]
        {
            return Err(ProcessError::InvalidExecutable);
        }
        let facts = file.facts(budget)?;
        if facts.sha256 != expected_sha256 {
            return Err(ProcessError::DigestMismatch);
        }
        let verdict = trust::verify_path(&file.path(), &policy)?;
        file.verify()?;
        budget.check()?;
        Ok(Self {
            file,
            sha256: facts.sha256,
            policy,
            verdict,
        })
    }
    pub fn sha256(&self) -> &str {
        &self.sha256
    }
    pub fn trust(&self) -> &TrustVerdict {
        &self.verdict
    }
    pub fn verify_binding(&self) -> Result<(), ProcessError> {
        if !self.file.private {
            self.file.require_signed_code_file()?;
        }
        self.file.verify().map_err(Into::into)
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    version: u32,
    executable: Vec<u8>,
    snapshot: FileSnapshot,
    sha256: String,
    policy: CodeTrustPolicy,
    cwd: Vec<u8>,
    cwd_identity: FileIdentity,
    arguments: Vec<Vec<u8>>,
    timeout_ns: u64,
    stdout_bytes: usize,
    stderr_bytes: usize,
    grace_ms: u64,
    output_files: Vec<OutputFileRequest>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct OutputFileRequest {
    name: Vec<u8>,
    maximum_bytes: u64,
}
#[derive(Serialize, Deserialize)]
#[serde(tag = "event", deny_unknown_fields)]
enum Event {
    Launched {
        pid: i32,
    },
    Finished {
        result: Result<ProcessOutcome, ProcessError>,
    },
}

fn errno() -> i32 {
    std::io::Error::last_os_error()
        .raw_os_error()
        .unwrap_or(libc::EIO)
}
fn launch_error(code: i32) -> ProcessError {
    ProcessError::LaunchFailed { code }
}
fn nonblocking(fd: i32) -> Result<(), ProcessError> {
    // SAFETY: live owned descriptor; preserve all original flags.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(launch_error(errno()));
    }
    Ok(())
}
fn pipe() -> Result<(File, File), ProcessError> {
    let mut fds = [-1; 2];
    // SAFETY: pipe initializes two fresh descriptors on success.
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(launch_error(errno()));
    }
    // SAFETY: each fresh descriptor is transferred to exactly one File owner.
    let pair = unsafe { (File::from_raw_fd(fds[0]), File::from_raw_fd(fds[1])) };
    for fd in fds {
        // SAFETY: fresh live descriptors, close on exec before exposure to callers.
        if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } < 0 {
            return Err(launch_error(errno()));
        }
    }
    // Readers poll within their budget. Child stdout/stderr stay blocking so
    // ordinary write_all callers cannot silently truncate on pipe backpressure.
    nonblocking(fds[0])?;
    Ok(pair)
}

unsafe extern "C" {
    fn posix_spawn_file_actions_addfchdir(
        actions: *mut libc::posix_spawn_file_actions_t,
        fd: i32,
    ) -> i32;
}
struct SpawnAttributes(libc::posix_spawnattr_t);
impl Drop for SpawnAttributes {
    fn drop(&mut self) {
        // SAFETY: initialized spawn attributes, destroyed once.
        unsafe { libc::posix_spawnattr_destroy(&mut self.0) };
    }
}
struct SpawnActions(libc::posix_spawn_file_actions_t);
impl Drop for SpawnActions {
    fn drop(&mut self) {
        // SAFETY: initialized actions, destroyed once.
        unsafe { libc::posix_spawn_file_actions_destroy(&mut self.0) };
    }
}

struct Child {
    pid: i32,
    reaped: bool,
    control_cleanup: bool,
    watch_target: Option<Arc<Mutex<Option<i32>>>>,
}
impl Child {
    fn exited(&self) -> Result<bool, ProcessError> {
        let mut info = std::mem::MaybeUninit::<libc::siginfo_t>::zeroed();
        // SAFETY: exact owned child, correctly sized output; WNOWAIT retains its
        // PID until all group signals and watcher callbacks have stopped.
        if unsafe {
            libc::waitid(
                libc::P_PID,
                self.pid as u32,
                info.as_mut_ptr(),
                libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
            )
        } != 0
        {
            return Err(ProcessError::CleanupFailed);
        }
        // SAFETY: successful waitid initialized output; zero PID means no exit yet.
        Ok(unsafe { info.assume_init() }.si_pid == self.pid)
    }
    fn reap(&mut self, deadline: Instant) -> Result<i32, ProcessError> {
        loop {
            let mut status = 0;
            // SAFETY: exact unreaped child and writable status; no unbounded wait.
            let result = unsafe { libc::waitpid(self.pid, &mut status, libc::WNOHANG) };
            if result == self.pid {
                self.reaped = true;
                return Ok(status);
            }
            if result < 0 && errno() != libc::EINTR {
                return Err(ProcessError::CleanupFailed);
            }
            if Instant::now() >= deadline {
                return Err(ProcessError::CleanupFailed);
            }
            thread::sleep(Duration::from_millis(2));
        }
    }
}
impl Drop for Child {
    fn drop(&mut self) {
        if !self.reaped {
            // Client scopes drop the control writer before this helper guard.
            // Give its independent parent watcher time to kill/reap the parser
            // before considering termination of the supervisor itself.
            if self.control_cleanup {
                let deadline = Instant::now() + Duration::from_secs(4);
                while Instant::now() < deadline {
                    if self.exited().unwrap_or(false) {
                        let _ = self.reap(deadline);
                        return;
                    }
                    thread::sleep(Duration::from_millis(2));
                }
            }
            // Panic unwinding must clear the watcher target before reaping the
            // leader, so no callback can later signal a reused process-group ID.
            let target = self.watch_target.take();
            let mut target_guard = target
                .as_ref()
                .map(|target| target.lock().unwrap_or_else(|p| p.into_inner()));
            if let Some(guard) = target_guard.as_mut() {
                **guard = None;
            }
            let _ = signal_group(self.pid, libc::SIGKILL);
            let _ = self.reap(Instant::now() + CLEANUP_TIME);
        }
    }
}
fn signal_group(pid: i32, signal: i32) -> Result<(), ProcessError> {
    if pid <= 0 {
        return Err(ProcessError::CleanupFailed);
    }
    // SAFETY: caller retains the exact unreaped leader PID; never signal a
    // guessed historical PID. All spawned descendants inherit this group.
    if unsafe { libc::kill(-pid, signal) } != 0 {
        let code = errno();
        // Darwin returns EPERM for a group whose only member is the unreaped
        // zombie leader. Preserve its PID while proving no live member remains;
        // do not ignore EPERM for a live child or descendant.
        if code != libc::ESRCH && (code != libc::EPERM || group_has_live_members(pid)?) {
            return Err(ProcessError::CleanupFailed);
        }
    }
    Ok(())
}

fn group_has_live_members(group: i32) -> Result<bool, ProcessError> {
    let mut members = [0_i32; 1024];
    let byte_capacity = std::mem::size_of_val(&members) as i32;
    // SAFETY: PROC_PGRP_ONLY=2, owned leader keeps this group ID from reuse,
    // bounded, correctly sized PID output. A full result fails closed.
    let count =
        unsafe { libc::proc_listpids(2, group as u32, members.as_mut_ptr().cast(), byte_capacity) };
    if count < 0 || count >= byte_capacity || count % 4 != 0 {
        return Err(ProcessError::CleanupFailed);
    }
    for pid in members[..count as usize / 4]
        .iter()
        .copied()
        .filter(|p| *p > 0)
    {
        let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::uninit();
        let size = std::mem::size_of::<libc::proc_bsdinfo>() as i32;
        // SAFETY: PROC_PIDTBSDINFO=3, initialized on a full result, bounded output.
        let returned = unsafe { libc::proc_pidinfo(pid, 3, 0, info.as_mut_ptr().cast(), size) };
        if returned != size {
            if errno() == libc::ESRCH {
                continue;
            }
            return Err(ProcessError::CleanupFailed);
        }
        // SAFETY: a full-size successful result initialized the entire structure.
        let info = unsafe { info.assume_init() };
        if info.pbi_status != 5 {
            // SZOMB=5 in the current Darwin SDK
            return Ok(true);
        }
    }
    Ok(false)
}

fn spawn(
    executable: &VerifiedExecutable,
    cwd: &HeldDirectory,
    arguments: &[OsString],
    stdio: [i32; 3],
    suspended: bool,
) -> Result<Child, ProcessError> {
    executable.verify_binding()?;
    cwd.revalidate()?;
    if arguments.len() > 64 || arguments.iter().map(|a| a.as_bytes().len()).sum::<usize>() > 16_384
    {
        return Err(ProcessError::InvalidArguments);
    }
    let path = CString::new(executable.file.path().as_os_str().as_bytes())
        .map_err(|_| ProcessError::InvalidArguments)?;
    let argv: Vec<CString> = std::iter::once(path.clone())
        .chain(
            arguments
                .iter()
                .map(|a| CString::new(a.as_bytes()))
                .collect::<Result<Vec<_>, _>>()
                .map_err(|_| ProcessError::InvalidArguments)?,
        )
        .collect();
    let mut argv_ptrs: Vec<_> = argv.iter().map(|a| a.as_ptr().cast_mut()).collect();
    argv_ptrs.push(ptr::null_mut());
    let mut tmp = b"TMPDIR=".to_vec();
    tmp.extend_from_slice(cwd.path().as_os_str().as_bytes());
    let environment = [
        CString::new("LANG=C").unwrap(),
        CString::new("LC_ALL=C").unwrap(),
        CString::new("PATH=/usr/bin:/bin").unwrap(),
        CString::new(tmp).map_err(|_| ProcessError::InvalidArguments)?,
    ];
    let mut env_ptrs: Vec<_> = environment.iter().map(|e| e.as_ptr().cast_mut()).collect();
    env_ptrs.push(ptr::null_mut());
    let mut attributes = ptr::null_mut();
    // SAFETY: writable opaque attribute output, owned by the RAII guard on success.
    let code = unsafe { libc::posix_spawnattr_init(&mut attributes) };
    if code != 0 {
        return Err(launch_error(code));
    }
    let mut attributes = SpawnAttributes(attributes);
    let mut actions = ptr::null_mut();
    // SAFETY: writable opaque actions output, owned by the RAII guard on success.
    let code = unsafe { libc::posix_spawn_file_actions_init(&mut actions) };
    if code != 0 {
        return Err(launch_error(code));
    }
    let mut actions = SpawnActions(actions);
    let mut empty = std::mem::MaybeUninit::<libc::sigset_t>::uninit();
    // SAFETY: sigemptyset initializes the entire sigset output.
    unsafe { libc::sigemptyset(empty.as_mut_ptr()) };
    // SAFETY: initialized above, used only as a signal set.
    let empty = unsafe { empty.assume_init() };
    let mut defaults = empty;
    for signal in [
        libc::SIGHUP,
        libc::SIGTERM,
        libc::SIGINT,
        libc::SIGPIPE,
        libc::SIGCHLD,
    ] {
        // SAFETY: initialized sigset and valid signal number.
        unsafe { libc::sigaddset(&mut defaults, signal) };
    }
    let flags = libc::POSIX_SPAWN_SETPGROUP
        | libc::POSIX_SPAWN_SETSIGDEF
        | libc::POSIX_SPAWN_SETSIGMASK
        | libc::POSIX_SPAWN_CLOEXEC_DEFAULT
        | if suspended {
            libc::POSIX_SPAWN_START_SUSPENDED
        } else {
            0
        };
    // SAFETY: every opaque attribute/action is live and initialized, FDs are
    // held through spawn. Only 0/1/2 inherit; cwd is the exact held directory.
    let codes = unsafe {
        [
            libc::posix_spawnattr_setflags(&mut attributes.0, flags as i16),
            libc::posix_spawnattr_setpgroup(&mut attributes.0, 0),
            libc::posix_spawnattr_setsigmask(&mut attributes.0, &empty),
            libc::posix_spawnattr_setsigdefault(&mut attributes.0, &defaults),
            posix_spawn_file_actions_addfchdir(&mut actions.0, cwd.0.file.as_raw_fd()),
        ]
    };
    for code in codes {
        if code != 0 {
            return Err(launch_error(code));
        }
    }
    for (destination, source) in stdio.iter().enumerate() {
        // SAFETY: exact live stdio descriptors, duplicated into their fixed slots.
        let code = unsafe {
            libc::posix_spawn_file_actions_adddup2(&mut actions.0, *source, destination as i32)
        };
        if code != 0 {
            return Err(launch_error(code));
        }
    }
    let mut close_fds = stdio.to_vec();
    close_fds.push(cwd.0.file.as_raw_fd());
    close_fds.sort_unstable();
    close_fds.dedup();
    for fd in close_fds.into_iter().filter(|fd| *fd > 2) {
        // SAFETY: actions first duplicate stdio and select cwd, then close their
        // source descriptors. CLOEXEC_DEFAULT alone retains referenced FDs.
        let code = unsafe { libc::posix_spawn_file_actions_addclose(&mut actions.0, fd) };
        if code != 0 {
            return Err(launch_error(code));
        }
    }
    executable.verify_binding()?;
    cwd.revalidate()?;
    let mut pid = 0;
    // SAFETY: owned CString/array storage lives through posix_spawn, null terminated.
    let code = unsafe {
        libc::posix_spawn(
            &mut pid,
            path.as_ptr(),
            &actions.0,
            &attributes.0,
            argv_ptrs.as_ptr(),
            env_ptrs.as_ptr(),
        )
    };
    if code != 0 {
        return Err(launch_error(code));
    }
    Ok(Child {
        pid,
        reaped: false,
        control_cleanup: false,
        watch_target: None,
    })
}

#[cfg(feature = "process-fixtures")]
pub(super) fn fixture_check_loaded_identity(
    expected: &VerifiedExecutable,
    actual: &VerifiedExecutable,
    cwd: &HeldDirectory,
) -> Result<(), ProcessError> {
    let null = File::options()
        .read(true)
        .write(true)
        .open("/dev/null")
        .map_err(|_| launch_error(errno()))?;
    let child = spawn(actual, cwd, &[], [null.as_raw_fd(); 3], true)?;
    // The actual executable is never resumed. Child guard kills/reaps even when
    // the path is stable but kernel code identity differs from the expected pin.
    trust::verify_loaded(
        child.pid,
        &expected.file,
        &expected.verdict,
        &expected.policy,
    )
}

#[cfg(feature = "process-fixtures")]
std::thread_local! {
    static PAUSE_BOOTSTRAP: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}
#[cfg(feature = "process-fixtures")]
pub(super) fn fixture_pause_next_bootstrap() {
    PAUSE_BOOTSTRAP.set(true);
}

struct Reader {
    file: File,
    bytes: Vec<u8>,
    limit: usize,
    eof: bool,
}
impl Reader {
    fn new(file: File, limit: usize) -> Self {
        Self {
            file,
            bytes: Vec::new(),
            limit,
            eof: false,
        }
    }
    fn drain(&mut self, exceeded: ProcessError) -> Result<(), ProcessError> {
        let mut chunk = [0; 8192];
        loop {
            match self.file.read(&mut chunk) {
                Ok(0) => {
                    self.eof = true;
                    return Ok(());
                }
                Ok(n) => {
                    let remaining = self.limit.saturating_sub(self.bytes.len());
                    self.bytes.extend_from_slice(&chunk[..n.min(remaining)]);
                    if n > remaining {
                        return Err(exceeded);
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => return Ok(()),
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => return Err(ProcessError::CleanupFailed),
            }
        }
    }
}

struct ParentWatch {
    target: Arc<Mutex<Option<i32>>>,
    stop: Arc<AtomicBool>,
    thread: Option<thread::JoinHandle<()>>,
}
impl ParentWatch {
    fn start(token: CancellationToken, grace: Duration) -> Result<Self, ProcessError> {
        nonblocking(0)?;
        let target = Arc::new(Mutex::new(None::<i32>));
        let stop = Arc::new(AtomicBool::new(false));
        let (watch_target, watch_stop) = (target.clone(), stop.clone());
        let worker = thread::Builder::new()
            .name("arktrace-parent-watch".into())
            .spawn(move || {
                let mut terminated = false;
                while !watch_stop.load(Ordering::Acquire) {
                    let mut byte = 0_u8;
                    // SAFETY: supervisor exclusively owns stdin after its bounded request frame.
                    let read = unsafe { libc::read(0, (&mut byte as *mut u8).cast(), 1) };
                    if read >= 0 || (read < 0 && ![libc::EAGAIN, libc::EINTR].contains(&errno())) {
                        token.cancel();
                    }
                    if token.is_cancelled() && !terminated {
                        let guard = watch_target.lock().unwrap_or_else(|p| p.into_inner());
                        if let Some(pid) = *guard {
                            let _ = signal_group(pid, libc::SIGTERM);
                            thread::sleep(grace);
                            let _ = signal_group(pid, libc::SIGKILL);
                            terminated = true;
                        }
                    }
                    thread::sleep(Duration::from_millis(2));
                }
            })
            .map_err(|_| ProcessError::LaunchFailed { code: libc::EAGAIN })?;
        Ok(Self {
            target,
            stop,
            thread: Some(worker),
        })
    }
    fn attach(&self, child: &mut Child) {
        child.watch_target = Some(self.target.clone());
        *self.target.lock().unwrap_or_else(|p| p.into_inner()) = Some(child.pid);
    }
    fn finish(&mut self) {
        *self.target.lock().unwrap_or_else(|p| p.into_inner()) = None;
        self.stop.store(true, Ordering::Release);
        if let Some(worker) = self.thread.take() {
            let _ = worker.join();
        }
    }
}
impl Drop for ParentWatch {
    fn drop(&mut self) {
        self.finish();
    }
}

fn emit(event: Event) -> Result<(), ProcessError> {
    let mut bytes = serde_json::to_vec(&event).map_err(|_| ProcessError::ProtocolInvalid)?;
    if bytes.len() > RESPONSE_LIMIT {
        return Err(ProcessError::ProtocolInvalid);
    }
    bytes.push(b'\n');
    nonblocking(1)?;
    let deadline = Instant::now() + CLEANUP_TIME;
    let mut written = 0;
    while written < bytes.len() {
        // SAFETY: dedicated helper owns stdout, slice bounds stay live through
        // write; explicit offsets avoid partial-write replay by buffered stdio.
        let result =
            unsafe { libc::write(1, bytes[written..].as_ptr().cast(), bytes.len() - written) };
        if result > 0 {
            written += result as usize;
        } else if result < 0 && [libc::EAGAIN, libc::EINTR].contains(&errno()) {
            thread::sleep(Duration::from_millis(2));
        } else {
            return Err(ProcessError::ProtocolInvalid);
        }
        if Instant::now() >= deadline {
            return Err(ProcessError::ProtocolInvalid);
        }
    }
    Ok(())
}

fn open_tool_file(path: &Path, policy: &CodeTrustPolicy) -> Result<HeldFile, ProcessError> {
    let path_parent = path.parent().ok_or(ProcessError::InvalidArguments)?;
    let parent = match policy {
        CodeTrustPolicy::DeveloperId { .. } => HeldDirectory::open_code_directory(path_parent)?,
        CodeTrustPolicy::DevelopmentPinned => HeldDirectory::open_private(path_parent)?,
    };
    let name = super::component(path.file_name().ok_or(ProcessError::InvalidArguments)?)?;
    Ok(parent.open_file_component(name, parent.0.private)?)
}

fn local_run(request: Request) -> Result<ProcessOutcome, ProcessError> {
    if request.version != 3
        || request.timeout_ns == 0
        || request.timeout_ns > 24 * 3600 * 1_000_000_000
    {
        return Err(ProcessError::ProtocolInvalid);
    }
    let token = CancellationToken::default();
    let budget = ProcessBudget {
        deadline: Instant::now() + Duration::from_nanos(request.timeout_ns),
        cancellation: token.clone(),
        stdout_bytes: request.stdout_bytes,
        stderr_bytes: request.stderr_bytes,
        termination_grace: Duration::from_millis(request.grace_ms),
        output_files: request
            .output_files
            .into_iter()
            .map(|file| ProcessOutputFileBudget {
                name: OsString::from_vec(file.name),
                maximum_bytes: file.maximum_bytes,
            })
            .collect(),
    };
    budget.check()?;
    let mut watcher = ParentWatch::start(token, budget.termination_grace)?;
    let path = PathBuf::from(OsString::from_vec(request.executable));
    let file = open_tool_file(&path, &request.policy)?;
    if file.snapshot() != request.snapshot {
        return Err(ProcessError::Host(HostError::Changed));
    }
    let executable = VerifiedExecutable::verify(
        file,
        &request.sha256,
        request.policy,
        &IoBudget {
            maximum_bytes: TOOL_LIMIT,
            deadline: budget.deadline,
            cancellation: budget.cancellation.clone(),
        },
    )?;
    let cwd = HeldDirectory::open_private(&PathBuf::from(OsString::from_vec(request.cwd)))?;
    if cwd.identity() != request.cwd_identity {
        return Err(ProcessError::Host(HostError::IdentityMismatch));
    }
    let mut outputs = outputs::Watch::new(&cwd, &budget.output_files)?;
    let arguments: Vec<_> = request
        .arguments
        .into_iter()
        .map(OsString::from_vec)
        .collect();
    let (out_read, out_write) = pipe()?;
    let (err_read, err_write) = pipe()?;
    let null = File::open("/dev/null").map_err(|_| launch_error(errno()))?;
    budget.check()?;
    let mut child = spawn(
        &executable,
        &cwd,
        &arguments,
        [
            null.as_raw_fd(),
            out_write.as_raw_fd(),
            err_write.as_raw_fd(),
        ],
        true,
    )?;
    watcher.attach(&mut child);
    drop(out_write);
    drop(err_write);
    let mut stdout = Reader::new(out_read, budget.stdout_bytes);
    let mut stderr = Reader::new(err_read, budget.stderr_bytes);
    let mut result = (|| {
        emit(Event::Launched { pid: child.pid })?;
        budget.check()?;
        trust::verify_loaded(
            child.pid,
            &executable.file,
            &executable.verdict,
            &executable.policy,
        )?;
        budget.check()?;
        // SAFETY: resume only the owned, suspended, code-identity-checked process group.
        if unsafe { libc::kill(child.pid, libc::SIGCONT) } != 0 {
            return Err(launch_error(errno()));
        }
        loop {
            budget.check()?;
            stdout.drain(ProcessError::StdoutLimitExceeded)?;
            stderr.drain(ProcessError::StderrLimitExceeded)?;
            outputs.check()?;
            if child.exited()? {
                return Ok(());
            }
            thread::sleep(Duration::from_millis(2));
        }
    })();
    let mut escalated = false;
    signal_group(child.pid, libc::SIGTERM)?;
    let grace_end = Instant::now() + budget.termination_grace;
    while Instant::now() < grace_end {
        retain_failure(&mut result, stdout.drain(ProcessError::StdoutLimitExceeded));
        retain_failure(&mut result, stderr.drain(ProcessError::StderrLimitExceeded));
        retain_failure(&mut result, outputs.check().map(|_| ()));
        if child.exited()? && stdout.eof && stderr.eof && !group_has_live_members(child.pid)? {
            break;
        }
        thread::sleep(Duration::from_millis(2));
    }
    // Keep the leader unreaped across final group kill and watcher shutdown.
    // ESRCH is harmless; a still-live descendant is never left behind for EOF.
    if !child.exited()? || !stdout.eof || !stderr.eof || group_has_live_members(child.pid)? {
        signal_group(child.pid, libc::SIGKILL)?;
        escalated = true;
    }
    let end = Instant::now() + CLEANUP_TIME;
    while !(stdout.eof && stderr.eof && !group_has_live_members(child.pid)?) {
        retain_failure(&mut result, stdout.drain(ProcessError::StdoutLimitExceeded));
        retain_failure(&mut result, stderr.drain(ProcessError::StderrLimitExceeded));
        retain_failure(&mut result, outputs.check().map(|_| ()));
        if Instant::now() >= end {
            return Err(ProcessError::CleanupFailed);
        }
        thread::sleep(Duration::from_millis(2));
    }
    watcher.finish();
    let status = child.reap(end)?;
    // A short-lived parser or a descendant can write after the last live poll.
    // Enforce all limits once more after group cleanup, before exposing success.
    retain_failure(&mut result, stdout.drain(ProcessError::StdoutLimitExceeded));
    retain_failure(&mut result, stderr.drain(ProcessError::StderrLimitExceeded));
    let output_file_bytes = outputs.check();
    retain_failure(
        &mut result,
        output_file_bytes.as_ref().map(|_| ()).map_err(|e| *e),
    );
    if let Err(error) = result {
        return Err(
            if error != ProcessError::CleanupFailed && budget.cancellation.is_cancelled() {
                ProcessError::Cancelled
            } else {
                error
            },
        );
    }
    budget.check()?;
    executable.verify_binding()?;
    cwd.revalidate()?;
    Ok(ProcessOutcome {
        exit_code: libc::WIFEXITED(status).then(|| libc::WEXITSTATUS(status)),
        signal: libc::WIFSIGNALED(status).then(|| libc::WTERMSIG(status)),
        stdout: stdout.bytes,
        stderr: stderr.bytes,
        escalated_to_kill: escalated,
        output_file_bytes: output_file_bytes?,
    })
}

fn retain_failure(result: &mut Result<(), ProcessError>, check: Result<(), ProcessError>) {
    if let Err(error) = check
        && (result.is_ok() || error == ProcessError::CleanupFailed)
    {
        *result = Err(error);
    }
}

fn read_request() -> Result<Request, ProcessError> {
    nonblocking(0)?;
    let mut stdin = std::io::stdin();
    let end = Instant::now() + Duration::from_secs(5);
    let mut bytes = Vec::new();
    let mut wanted = 4;
    loop {
        let mut chunk = [0; 8192];
        let remaining = (wanted - bytes.len()).min(chunk.len());
        match stdin.read(&mut chunk[..remaining]) {
            Ok(0) => return Err(ProcessError::Cancelled),
            Ok(n) => bytes.extend_from_slice(&chunk[..n]),
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(2))
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => return Err(ProcessError::ProtocolInvalid),
        }
        if bytes.len() == 4 && wanted == 4 {
            wanted = 4 + u32::from_be_bytes(bytes[..4].try_into().unwrap()) as usize;
            if wanted <= 4 || wanted > REQUEST_LIMIT {
                return Err(ProcessError::ProtocolInvalid);
            }
        }
        if bytes.len() == wanted {
            return serde_json::from_slice(&bytes[4..]).map_err(|_| ProcessError::ProtocolInvalid);
        }
        if Instant::now() >= end {
            return Err(ProcessError::DeadlineExceeded);
        }
    }
}

/// Entry point for the separately packaged, pinned host helper; no product CLI.
#[doc(hidden)]
pub fn supervisor_main() -> i32 {
    // SAFETY: this entry runs only in the dedicated helper process, before its
    // watcher thread. Child-created DB/sidecars inherit owner-only permissions.
    unsafe { libc::umask(0o077) };
    #[cfg(feature = "process-fixtures")]
    {
        // Test-only entry marker proves orphan-group termination occurred
        // before this entry point. Production does not write this marker.
        if std::fs::write(".supervisor-entered", b"entered").is_err() {
            return 1;
        }
    }
    // SAFETY: set only in this dedicated process before threads. A broken
    // control/output pipe must unwind ownership guards, never kill the helper
    // while a suspended parser still needs cleanup. Parser spawn restores SIGPIPE.
    if unsafe { libc::signal(libc::SIGPIPE, libc::SIG_IGN) } == libc::SIG_ERR {
        return 1;
    }
    let result = std::panic::catch_unwind(|| read_request().and_then(local_run))
        .unwrap_or(Err(ProcessError::CleanupFailed));
    if emit(Event::Finished { result }).is_ok() {
        0
    } else {
        1
    }
}

pub fn run_supervised(
    supervisor: &VerifiedExecutable,
    executable: &VerifiedExecutable,
    cwd: &HeldDirectory,
    arguments: &[OsString],
    budget: &ProcessBudget,
) -> Result<ProcessOutcome, ProcessError> {
    budget.check()?;
    executable.verify_binding()?;
    supervisor.verify_binding()?;
    cwd.revalidate()?;
    // Refuse existing outputs before any helper is started. The helper repeats
    // admission against the same held directory identity before parser launch.
    let _ = outputs::Watch::new(cwd, &budget.output_files)?;
    let remaining = budget
        .deadline
        .saturating_duration_since(Instant::now())
        .as_nanos();
    let request = Request {
        version: 3,
        executable: executable.file.path().as_os_str().as_bytes().to_vec(),
        snapshot: executable.file.snapshot(),
        sha256: executable.sha256.clone(),
        policy: executable.policy.clone(),
        cwd: cwd.path().as_os_str().as_bytes().to_vec(),
        cwd_identity: cwd.identity(),
        arguments: arguments.iter().map(|a| a.as_bytes().to_vec()).collect(),
        timeout_ns: u64::try_from(remaining).map_err(|_| ProcessError::InvalidArguments)?,
        stdout_bytes: budget.stdout_bytes,
        stderr_bytes: budget.stderr_bytes,
        grace_ms: budget.termination_grace.as_millis() as u64,
        output_files: budget
            .output_files
            .iter()
            .map(|file| OutputFileRequest {
                name: file.name.as_bytes().to_vec(),
                maximum_bytes: file.maximum_bytes,
            })
            .collect(),
    };
    let body = serde_json::to_vec(&request).map_err(|_| ProcessError::ProtocolInvalid)?;
    if body.len() + 4 > REQUEST_LIMIT {
        return Err(ProcessError::InvalidArguments);
    }
    let mut packet = (body.len() as u32).to_be_bytes().to_vec();
    packet.extend(body);
    let (input_read, input_write) = pipe()?;
    nonblocking(input_write.as_raw_fd())?;
    let (out_read, out_write) = pipe()?;
    let (err_read, err_write) = pipe()?;
    let mut helper = spawn(
        supervisor,
        cwd,
        &[],
        [
            input_read.as_raw_fd(),
            out_write.as_raw_fd(),
            err_write.as_raw_fd(),
        ],
        true,
    )?;
    #[cfg(feature = "process-fixtures")]
    if PAUSE_BOOTSTRAP.replace(false) {
        if !super::process_fixture::is_stopped(helper.pid)? {
            return Err(ProcessError::CleanupFailed);
        }
        std::fs::write(cwd.path().join("bootstrap.pid"), helper.pid.to_string())
            .map_err(|_| ProcessError::CleanupFailed)?;
        loop {
            budget.check()?;
            thread::sleep(Duration::from_millis(5));
        }
    }
    drop(input_read);
    drop(out_write);
    drop(err_write);
    let mut input_write = Some(input_write);
    let mut written = 0;
    let mut stdout = Reader::new(out_read, RESPONSE_LIMIT);
    let mut stderr = Reader::new(err_read, 4096);
    let mut cause = None;
    let mut cleanup_end = None;
    let verification = trust::verify_loaded(
        helper.pid,
        &supervisor.file,
        &supervisor.verdict,
        &supervisor.policy,
    )
    .and_then(|_| {
        budget.check()?;
        // SAFETY: helper remains an owned suspended child until kernel code
        // identity matches the fixed snapshot; no helper instruction runs first.
        if unsafe { libc::kill(helper.pid, libc::SIGCONT) } != 0 {
            return Err(launch_error(errno()));
        }
        Ok(())
    });
    if let Err(error) = verification {
        // No parser exists before the request frame. Kill/reap the suspended
        // helper immediately rather than waiting for a watcher not yet running.
        signal_group(helper.pid, libc::SIGKILL)?;
        helper.reap(Instant::now() + CLEANUP_TIME)?;
        return Err(error);
    }
    helper.control_cleanup = true;
    loop {
        if cause.is_none()
            && let Err(error) = budget.check()
        {
            cause = Some(error);
            input_write.take();
            cleanup_end = Some(Instant::now() + CLEANUP_TIME);
        }
        if let Some(input) = input_write.as_mut()
            && written < packet.len()
        {
            match input.write(&packet[written..]) {
                Ok(0) => return Err(ProcessError::ProtocolInvalid),
                Ok(n) => written += n,
                Err(e)
                    if e.kind() == std::io::ErrorKind::WouldBlock
                        || e.kind() == std::io::ErrorKind::Interrupted => {}
                Err(_) => {
                    cause = Some(ProcessError::ProtocolInvalid);
                    input_write.take();
                    cleanup_end = Some(Instant::now() + CLEANUP_TIME);
                }
            }
        }
        stdout.drain(ProcessError::ProtocolInvalid)?;
        stderr.drain(ProcessError::ProtocolInvalid)?;
        if helper.exited()? && stdout.eof && stderr.eof {
            break;
        }
        if cleanup_end.is_some_and(|end| Instant::now() >= end) {
            return Err(ProcessError::CleanupFailed);
        }
        thread::sleep(Duration::from_millis(2));
    }
    input_write.take();
    let status = helper.reap(Instant::now() + CLEANUP_TIME)?;
    if !libc::WIFEXITED(status) || libc::WEXITSTATUS(status) != 0 || !stderr.bytes.is_empty() {
        return Err(ProcessError::CleanupFailed);
    }
    let mut result = None;
    let mut launched = false;
    for line in stdout
        .bytes
        .split(|b| *b == b'\n')
        .filter(|line| !line.is_empty())
    {
        let event: Event =
            serde_json::from_slice(line).map_err(|_| ProcessError::ProtocolInvalid)?;
        match event {
            Event::Launched { pid } if !launched && result.is_none() && pid > 0 => launched = true,
            Event::Finished { result: value } if result.is_none() => result = Some(value),
            _ => return Err(ProcessError::ProtocolInvalid),
        }
    }
    let result = result.ok_or(ProcessError::ProtocolInvalid)?;
    if result == Err(ProcessError::CleanupFailed) {
        return result;
    }
    if let Some(cause) = cause {
        return Err(cause);
    }
    budget.check()?;
    result
}
