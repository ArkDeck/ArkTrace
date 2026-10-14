//! Verified native processes on Windows. The parser is created suspended,
//! admitted into a kill-on-close Job object, proved to run the held verified
//! image, and only then resumed. Where macOS needs a separately launched
//! supervisor whose control pipe closes on Engine death (POSIX has no
//! kill-on-parent-death), the Job object is that guarantee in the kernel: the
//! Engine owns the only Job handle, so its death closes the handle and ends
//! the whole tree. The supervisor executable is therefore verified and kept
//! bound, but not launched (see [`supervisor_main`]). There is no SIGTERM:
//! after the parser exits its descendants get the termination grace to end
//! on their own; a stop the Engine asks for terminates the Job at once.
//! Process, pipe and Job primitives adapted from ArkDeck
//! `arkdeck-platform/src/windows/{process.rs,tool.rs}` (MIT, same organization).
use super::{
    Access, HeldDirectory, HeldFile, WRITE_RIGHTS,
    trust::{self, CodeTrustPolicy, TrustVerdict},
    wide_terminated,
};
use crate::{CancellationToken, HostError, IoBudget};
use serde::{Deserialize, Serialize};
use std::{
    ffi::{OsStr, OsString},
    fs::File,
    io::Read,
    mem::size_of,
    os::windows::{
        ffi::OsStrExt,
        io::{AsRawHandle, FromRawHandle, OwnedHandle},
    },
    ptr::{null, null_mut},
    thread,
    time::{Duration, Instant},
};
use windows_sys::Win32::Foundation::{
    ERROR_BROKEN_PIPE, ERROR_PIPE_NOT_CONNECTED, GENERIC_READ, HANDLE, HANDLE_FLAG_INHERIT,
    INVALID_HANDLE_VALUE, SetHandleInformation, WAIT_OBJECT_0, WAIT_TIMEOUT,
};
use windows_sys::Win32::Security::SECURITY_ATTRIBUTES;
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, FILE_APPEND_DATA, FILE_ATTRIBUTE_NORMAL, FILE_EXECUTE, FILE_SHARE_READ,
    FILE_SHARE_WRITE, FILE_WRITE_DATA, OPEN_EXISTING,
};
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION,
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, JOBOBJECT_BASIC_ACCOUNTING_INFORMATION,
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectBasicAccountingInformation,
    JobObjectExtendedLimitInformation, QueryInformationJobObject, SetInformationJobObject,
    TerminateJobObject,
};
use windows_sys::Win32::System::Pipes::{CreatePipe, PeekNamedPipe};
use windows_sys::Win32::System::SystemInformation::GetWindowsDirectoryW;
use windows_sys::Win32::System::Threading::{
    CREATE_NO_WINDOW, CREATE_SUSPENDED, CREATE_UNICODE_ENVIRONMENT, CreateProcessW,
    DeleteProcThreadAttributeList, EXTENDED_STARTUPINFO_PRESENT, GetExitCodeProcess,
    InitializeProcThreadAttributeList, LPPROC_THREAD_ATTRIBUTE_LIST,
    PROC_THREAD_ATTRIBUTE_HANDLE_LIST, PROCESS_INFORMATION, ResumeThread, STARTF_USESTDHANDLES,
    STARTUPINFOEXW, STARTUPINFOW, TerminateProcess, UpdateProcThreadAttribute, WaitForSingleObject,
};

const DIAGNOSTIC_LIMIT: usize = 65_536;
const TOOL_LIMIT: u64 = 256 * 1024 * 1024;
const CLEANUP_TIME: Duration = Duration::from_secs(2);
/// The exit code a Job terminated by its owner reports.
const TERMINATED_EXIT_CODE: u32 = 1;
/// Each output pipe's buffer: a writer blocks only once this much is unread.
const OUTPUT_PIPE_BYTES: u32 = 64 * 1024;

#[path = "windows_process_outputs.rs"]
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
    /// 1024 total bytes, `/`-separated. The topmost output object must be
    /// initially absent.
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
    /// entire Job has stopped. Polling rejects excess, not a quota.
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
    /// The parser's own exit code. Windows has no signals: `signal` is
    /// always `None`, and a Job this side terminated never yields an outcome.
    pub exit_code: Option<i32>,
    pub signal: Option<i32>,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    /// Descendants outlived the parser and the grace; the Job was terminated.
    pub escalated_to_kill: bool,
    /// Final sizes in declaration order; None means the optional file was never created.
    pub output_file_bytes: Vec<Option<u64>>,
}

pub struct VerifiedExecutable {
    file: HeldFile,
    sha256: String,
    verdict: TrustVerdict,
}

/// An AMD64 PE32+ executable image (not a DLL), from its headers.
fn amd64_executable(header: &[u8]) -> bool {
    let word = |at: usize| {
        header
            .get(at..at + 2)
            .map(|b| u16::from_le_bytes([b[0], b[1]]))
    };
    let Some(offset) = header
        .get(0x3c..0x40)
        .map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]) as usize)
    else {
        return false;
    };
    header.get(..2) == Some(b"MZ")
        && offset <= header.len().saturating_sub(26)
        && header.get(offset..offset + 4) == Some(b"PE\0\0")
        && word(offset + 4) == Some(0x8664)
        && word(offset + 22).is_some_and(|c| c & 0x0002 != 0 && c & 0x2000 == 0)
        && word(offset + 24) == Some(0x020b)
}

/// The Windows reading of macOS `require_signed_code_file`: installed code
/// that is not a private copy must be immutable to everyone but its trusted
/// owner, held under trusted ancestors, with one link.
fn require_code_file(file: &HeldFile) -> Result<(), HostError> {
    let access = Access::of(&file.file)?;
    if !file.parent.0.trusted_ancestors
        || file.initial.links != 1
        || !access.owner_trusted
        || access.untrusted & WRITE_RIGHTS != 0
        || access.user & (FILE_WRITE_DATA | FILE_APPEND_DATA) != 0
    {
        return Err(HostError::NotPrivate);
    }
    file.verify()
}

impl VerifiedExecutable {
    pub fn verify(
        file: HeldFile,
        expected_sha256: &str,
        policy: CodeTrustPolicy,
        budget: &IoBudget,
    ) -> Result<Self, ProcessError> {
        if file.private {
            // Unix `mode & 0o100 != 0 && mode & 0o200 == 0` on a private copy.
            let access = Access::of(&file.file)?;
            if access.user & FILE_EXECUTE == 0 || !access.readonly() {
                return Err(ProcessError::InvalidExecutable);
            }
        } else {
            if !matches!(policy, CodeTrustPolicy::AuthenticodePublisher { .. }) {
                return Err(ProcessError::InvalidExecutable);
            }
            require_code_file(&file)?;
        }
        if expected_sha256.len() != 64
            || !expected_sha256
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(ProcessError::InvalidPolicy);
        }
        // CreateProcessW appends `.exe` to an application name without an
        // extension, which would name a different file than the held one.
        if file.initial.byte_count > TOOL_LIMIT
            || !std::path::Path::new(
                file.name
                    .to_str()
                    .map_err(|_| ProcessError::InvalidExecutable)?,
            )
            .extension()
            .is_some_and(|extension| extension.eq_ignore_ascii_case("exe"))
        {
            return Err(ProcessError::InvalidExecutable);
        }
        let header = file.read_prefix(
            4096,
            &IoBudget {
                maximum_bytes: TOOL_LIMIT,
                ..budget.clone()
            },
        )?;
        if !amd64_executable(&header) {
            return Err(ProcessError::InvalidExecutable);
        }
        let facts = file.facts(budget)?;
        if facts.sha256 != expected_sha256 {
            return Err(ProcessError::DigestMismatch);
        }
        let verdict = trust::verify_file(&file, &policy)?;
        file.verify()?;
        budget.check()?;
        Ok(Self {
            file,
            sha256: facts.sha256,
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
            require_code_file(&self.file)?;
        }
        self.file.verify().map_err(Into::into)
    }
}

fn launch_error() -> ProcessError {
    ProcessError::LaunchFailed {
        code: std::io::Error::last_os_error().raw_os_error().unwrap_or(-1),
    }
}

fn owned(handle: HANDLE) -> Result<OwnedHandle, ProcessError> {
    if handle.is_null() || handle == INVALID_HANDLE_VALUE {
        return Err(launch_error());
    }
    // SAFETY: a fresh handle returned to this process, owned exactly once.
    Ok(unsafe { OwnedHandle::from_raw_handle(handle) })
}

fn inheritable() -> SECURITY_ATTRIBUTES {
    SECURITY_ATTRIBUTES {
        nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: null_mut(),
        bInheritHandle: 1,
    }
}

/// An output pipe: the write end inheritable, the read end this side's alone.
fn output_pipe() -> Result<(File, OwnedHandle), ProcessError> {
    let (mut read, mut write) = (null_mut(), null_mut());
    let attributes = inheritable();
    // SAFETY: valid output pointers; both handles are owned at once.
    if unsafe { CreatePipe(&mut read, &mut write, &attributes, OUTPUT_PIPE_BYTES) } == 0 {
        return Err(launch_error());
    }
    let read = owned(read)?;
    let write = owned(write)?;
    // SAFETY: only the read handle's inheritance flag is changed.
    if unsafe { SetHandleInformation(read.as_raw_handle(), HANDLE_FLAG_INHERIT, 0) } == 0 {
        return Err(launch_error());
    }
    Ok((File::from(read), write))
}

fn null_input() -> Result<OwnedHandle, ProcessError> {
    let name = wide_terminated(OsStr::new("NUL"))?;
    let attributes = inheritable();
    // SAFETY: NUL is a fixed host device; read-only, explicitly inheritable.
    owned(unsafe {
        CreateFileW(
            name.as_ptr(),
            GENERIC_READ,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            &attributes,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            null_mut(),
        )
    })
}

/// The explicit list of handles the child inherits.
struct Attributes {
    storage: Vec<usize>,
    initialized: bool,
}
impl Attributes {
    fn handles(handles: &mut [HANDLE]) -> Result<Self, ProcessError> {
        let mut length = 0;
        // SAFETY: documented size query.
        unsafe { InitializeProcThreadAttributeList(null_mut(), 1, 0, &mut length) };
        if length == 0 || length > 1024 * 1024 {
            return Err(launch_error());
        }
        let mut value = Self {
            storage: vec![0; length.div_ceil(size_of::<usize>())],
            initialized: false,
        };
        // SAFETY: pointer-aligned storage covers the requested byte length.
        if unsafe { InitializeProcThreadAttributeList(value.pointer(), 1, 0, &mut length) } == 0 {
            return Err(launch_error());
        }
        value.initialized = true;
        // SAFETY: the handle slice outlives CreateProcessW; the list is live.
        if unsafe {
            UpdateProcThreadAttribute(
                value.pointer(),
                0,
                PROC_THREAD_ATTRIBUTE_HANDLE_LIST as usize,
                handles.as_mut_ptr().cast(),
                std::mem::size_of_val(handles),
                null_mut(),
                null(),
            )
        } == 0
        {
            return Err(launch_error());
        }
        Ok(value)
    }
    fn pointer(&mut self) -> LPPROC_THREAD_ATTRIBUTE_LIST {
        self.storage.as_mut_ptr().cast()
    }
}
impl Drop for Attributes {
    fn drop(&mut self) {
        if self.initialized {
            // SAFETY: initialized list, freed before its storage.
            unsafe { DeleteProcThreadAttributeList(self.pointer()) };
        }
    }
}

/// Encode argv for CreateProcessW's C-runtime parser (never a shell).
fn command_line(executable: &OsStr, arguments: &[OsString]) -> Result<Vec<u16>, ProcessError> {
    let mut output = Vec::new();
    for argument in std::iter::once(executable).chain(arguments.iter().map(OsString::as_os_str)) {
        if !output.is_empty() {
            output.push(b' ' as u16);
        }
        output.push(b'"' as u16);
        let mut slashes = 0;
        for unit in argument.encode_wide() {
            if unit == 0 {
                return Err(ProcessError::InvalidArguments);
            }
            if unit == b'\\' as u16 {
                slashes += 1;
                continue;
            }
            let escapes = if unit == b'"' as u16 {
                slashes * 2 + 1
            } else {
                slashes
            };
            output.extend(std::iter::repeat_n(b'\\' as u16, escapes));
            slashes = 0;
            output.push(unit);
        }
        output.extend(std::iter::repeat_n(b'\\' as u16, slashes * 2));
        output.push(b'"' as u16);
    }
    output.push(0);
    if output.len() > 32_767 {
        return Err(ProcessError::InvalidArguments);
    }
    Ok(output)
}

fn windows_directory() -> Result<String, ProcessError> {
    let mut buffer = vec![0_u16; 32_768];
    // SAFETY: bounded UTF-16 output buffer.
    let length = unsafe { GetWindowsDirectoryW(buffer.as_mut_ptr(), buffer.len() as u32) } as usize;
    if length == 0 || length >= buffer.len() {
        return Err(launch_error());
    }
    String::from_utf16(&buffer[..length]).map_err(|_| ProcessError::InvalidArguments)
}

fn uppercase(name: &str) -> String {
    name.to_uppercase()
}

/// The macOS child environment (`LANG`, `LC_ALL`, `PATH`, `TMPDIR`) in its
/// Windows spelling: the system directory as the only search path, the two
/// names the system itself needs, and the private CWD as the temporary root.
fn environment_block(cwd: &HeldDirectory) -> Result<Vec<u16>, ProcessError> {
    let root = windows_directory()?;
    let temporary = cwd.path().to_str().ok_or(ProcessError::InvalidArguments)?;
    let mut rows = [
        ("LANG", "C".to_owned()),
        ("LC_ALL", "C".to_owned()),
        ("PATH", format!("{root}\\System32")),
        ("SystemRoot", root.clone()),
        ("TEMP", temporary.to_owned()),
        ("TMP", temporary.to_owned()),
        ("WINDIR", root),
    ];
    // CreateProcessW takes the block sorted by name, case-insensitively.
    rows.sort_by_key(|(key, _)| uppercase(key));
    let mut block = Vec::new();
    for (key, value) in rows {
        if value.contains('\0') {
            return Err(ProcessError::InvalidArguments);
        }
        block.extend(key.encode_utf16());
        block.push(u16::from(b'='));
        block.extend(value.encode_utf16());
        block.push(0);
    }
    block.push(0);
    Ok(block)
}

struct Child {
    process: OwnedHandle,
    job: OwnedHandle,
    assigned: bool,
    cleaned: bool,
}
impl Child {
    fn exited(&self) -> Result<bool, ProcessError> {
        // SAFETY: retained process handle; a zero wait only reads state.
        match unsafe { WaitForSingleObject(self.process.as_raw_handle(), 0) } {
            WAIT_OBJECT_0 => Ok(true),
            WAIT_TIMEOUT => Ok(false),
            _ => Err(ProcessError::CleanupFailed),
        }
    }
    fn active(&self) -> Result<u32, ProcessError> {
        if !self.assigned {
            return Ok(u32::from(!self.exited()?));
        }
        let mut accounting = JOBOBJECT_BASIC_ACCOUNTING_INFORMATION::default();
        // SAFETY: class and output length match the accounting structure.
        if unsafe {
            QueryInformationJobObject(
                self.job.as_raw_handle(),
                JobObjectBasicAccountingInformation,
                std::ptr::from_mut(&mut accounting).cast(),
                size_of::<JOBOBJECT_BASIC_ACCOUNTING_INFORMATION>() as u32,
                null_mut(),
            )
        } == 0
        {
            return Err(ProcessError::CleanupFailed);
        }
        Ok(accounting.ActiveProcesses)
    }
    fn terminate(&self) -> Result<(), ProcessError> {
        // SAFETY: this unnamed Job holds only this child and its descendants;
        // before assignment the child is still suspended and alone.
        let result = unsafe {
            if self.assigned {
                TerminateJobObject(self.job.as_raw_handle(), TERMINATED_EXIT_CODE)
            } else {
                TerminateProcess(self.process.as_raw_handle(), TERMINATED_EXIT_CODE)
            }
        };
        if result == 0 && !self.exited()? {
            return Err(ProcessError::CleanupFailed);
        }
        Ok(())
    }
    fn exit_code(&self) -> Result<i32, ProcessError> {
        let mut code = 0_u32;
        // SAFETY: a live handle to an ended process; plain output.
        if unsafe { GetExitCodeProcess(self.process.as_raw_handle(), &mut code) } == 0 {
            return Err(ProcessError::CleanupFailed);
        }
        Ok(code as i32)
    }
}
impl Drop for Child {
    fn drop(&mut self) {
        if !self.cleaned {
            // Closing the Job handle below is the kernel-enforced second
            // termination of every assigned descendant.
            let _ = self.terminate();
        }
    }
}

fn spawn(
    executable: &VerifiedExecutable,
    cwd: &HeldDirectory,
    arguments: &[OsString],
    stdout: &OwnedHandle,
    stderr: &OwnedHandle,
) -> Result<(Child, OwnedHandle), ProcessError> {
    executable.verify_binding()?;
    cwd.revalidate()?;
    if arguments.len() > 64
        || arguments
            .iter()
            .map(|a| a.encode_wide().count() * 2)
            .sum::<usize>()
            > 16_384
    {
        return Err(ProcessError::InvalidArguments);
    }
    let image = executable.file.path().into_os_string();
    let application = wide_terminated(&image)?;
    let mut command = command_line(&image, arguments)?;
    let directory = wide_terminated(cwd.path().as_os_str())?;
    let environment = environment_block(cwd)?;
    let stdin = null_input()?;
    let mut inherited = [
        stdin.as_raw_handle(),
        stdout.as_raw_handle(),
        stderr.as_raw_handle(),
    ];
    let mut attributes = Attributes::handles(&mut inherited)?;
    let startup = STARTUPINFOEXW {
        StartupInfo: STARTUPINFOW {
            cb: size_of::<STARTUPINFOEXW>() as u32,
            dwFlags: STARTF_USESTDHANDLES,
            hStdInput: stdin.as_raw_handle(),
            hStdOutput: stdout.as_raw_handle(),
            hStdError: stderr.as_raw_handle(),
            ..Default::default()
        },
        lpAttributeList: attributes.pointer(),
    };
    // SAFETY: unnamed Job, default security, owned at once.
    let job = owned(unsafe { CreateJobObjectW(null(), null()) })?;
    let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
    limits.BasicLimitInformation.LimitFlags =
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION;
    // SAFETY: limit structure size and class agree.
    if unsafe {
        SetInformationJobObject(
            job.as_raw_handle(),
            JobObjectExtendedLimitInformation,
            std::ptr::from_ref(&limits).cast(),
            size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
        )
    } == 0
    {
        return Err(launch_error());
    }
    executable.verify_binding()?;
    cwd.revalidate()?;
    let mut info = PROCESS_INFORMATION::default();
    // SAFETY: every pointer names a live local; the application name is the
    // absolute held image path; only the listed handles are inherited; the
    // child starts suspended, so none of its code runs before the checks.
    if unsafe {
        CreateProcessW(
            application.as_ptr(),
            command.as_mut_ptr(),
            null(),
            null(),
            1,
            CREATE_SUSPENDED
                | CREATE_UNICODE_ENVIRONMENT
                | EXTENDED_STARTUPINFO_PRESENT
                | CREATE_NO_WINDOW,
            environment.as_ptr().cast(),
            directory.as_ptr(),
            &startup.StartupInfo,
            &mut info,
        )
    } == 0
    {
        return Err(launch_error());
    }
    let process = owned(info.hProcess)?;
    let thread = owned(info.hThread)?;
    let mut child = Child {
        process,
        job,
        assigned: false,
        cleaned: false,
    };
    // SAFETY: the child is suspended and has created no descendant.
    if unsafe { AssignProcessToJobObject(child.job.as_raw_handle(), child.process.as_raw_handle()) }
        == 0
    {
        let error = launch_error();
        child.terminate()?;
        return Err(error);
    }
    child.assigned = true;
    drop(attributes);
    Ok((child, thread))
}

/// Nonblocking pipe reader: `PeekNamedPipe` then a bounded read.
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
        while !self.eof {
            let mut available = 0_u32;
            // SAFETY: sole reader of this anonymous pipe; peek consumes nothing.
            if unsafe {
                PeekNamedPipe(
                    self.file.as_raw_handle(),
                    null_mut(),
                    0,
                    null_mut(),
                    &mut available,
                    null_mut(),
                )
            } == 0
            {
                let code = std::io::Error::last_os_error().raw_os_error();
                if matches!(
                    code.map(|c| c as u32),
                    Some(ERROR_BROKEN_PIPE | ERROR_PIPE_NOT_CONNECTED)
                ) {
                    self.eof = true;
                    return Ok(());
                }
                return Err(ProcessError::CleanupFailed);
            }
            if available == 0 {
                return Ok(());
            }
            let wanted = chunk.len().min(available as usize);
            let n = match self.file.read(&mut chunk[..wanted]) {
                Ok(0) => {
                    self.eof = true;
                    return Ok(());
                }
                Ok(n) => n,
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(e) if e.kind() == std::io::ErrorKind::BrokenPipe => {
                    self.eof = true;
                    return Ok(());
                }
                Err(_) => return Err(ProcessError::CleanupFailed),
            };
            let remaining = self.limit.saturating_sub(self.bytes.len());
            self.bytes.extend_from_slice(&chunk[..n.min(remaining)]);
            if n > remaining {
                return Err(exceeded);
            }
        }
        Ok(())
    }
}

fn retain_failure(result: &mut Result<(), ProcessError>, check: Result<(), ProcessError>) {
    if let Err(error) = check
        && (result.is_ok() || error == ProcessError::CleanupFailed)
    {
        *result = Err(error);
    }
}

fn run_local(
    executable: &VerifiedExecutable,
    cwd: &HeldDirectory,
    arguments: &[OsString],
    budget: &ProcessBudget,
) -> Result<ProcessOutcome, ProcessError> {
    budget.check()?;
    let mut outputs = outputs::Watch::new(cwd, &budget.output_files)?;
    let (out_read, out_write) = output_pipe()?;
    let (err_read, err_write) = output_pipe()?;
    budget.check()?;
    let (mut child, thread) = spawn(executable, cwd, arguments, &out_write, &err_write)?;
    // The child holds its own copies of the write ends.
    drop(out_write);
    drop(err_write);
    let mut stdout = Reader::new(out_read, budget.stdout_bytes);
    let mut stderr = Reader::new(err_read, budget.stderr_bytes);
    let mut result = (|| {
        budget.check()?;
        trust::verify_loaded(child.process.as_raw_handle(), &executable.file)?;
        budget.check()?;
        // SAFETY: resume only the owned, suspended, identity-checked child.
        if unsafe { ResumeThread(thread.as_raw_handle()) } == u32::MAX {
            return Err(launch_error());
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
    drop(thread);
    let mut escalated = false;
    if result.is_err() {
        // A stop this side asks for: no TERM exists, end the whole Job now.
        child.terminate()?;
        escalated = true;
    } else {
        // The parser exited; descendants get the grace to end on their own.
        let grace_end = Instant::now() + budget.termination_grace;
        while Instant::now() < grace_end {
            retain_failure(&mut result, stdout.drain(ProcessError::StdoutLimitExceeded));
            retain_failure(&mut result, stderr.drain(ProcessError::StderrLimitExceeded));
            retain_failure(&mut result, outputs.check().map(|_| ()));
            if child.active()? == 0 && stdout.eof && stderr.eof {
                break;
            }
            thread::sleep(Duration::from_millis(2));
        }
        if child.active()? != 0 || !stdout.eof || !stderr.eof {
            child.terminate()?;
            escalated = true;
        }
    }
    let end = Instant::now() + CLEANUP_TIME;
    while !(child.exited()? && child.active()? == 0 && stdout.eof && stderr.eof) {
        retain_failure(&mut result, stdout.drain(ProcessError::StdoutLimitExceeded));
        retain_failure(&mut result, stderr.drain(ProcessError::StderrLimitExceeded));
        retain_failure(&mut result, outputs.check().map(|_| ()));
        if Instant::now() >= end {
            return Err(ProcessError::CleanupFailed);
        }
        thread::sleep(Duration::from_millis(2));
    }
    child.cleaned = true;
    let exit_code = child.exit_code()?;
    // A short-lived parser or a descendant can write after the last live poll.
    retain_failure(&mut result, stdout.drain(ProcessError::StdoutLimitExceeded));
    retain_failure(&mut result, stderr.drain(ProcessError::StderrLimitExceeded));
    let output_file_bytes = outputs.check();
    retain_failure(
        &mut result,
        output_file_bytes.as_ref().map(|_| ()).map_err(|e| *e),
    );
    drop(outputs);
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
        exit_code: Some(exit_code),
        signal: None,
        stdout: stdout.bytes,
        stderr: stderr.bytes,
        escalated_to_kill: escalated,
        output_file_bytes: output_file_bytes?,
    })
}

/// The macOS helper's entry point. Windows supervises in process (the
/// kill-on-close Job object owned by the Engine), so no helper protocol
/// exists and this entry refuses with exit status 1 without reading input.
#[doc(hidden)]
pub fn supervisor_main() -> i32 {
    1
}

/// Run `executable` once under the budget. `supervisor` keeps the macOS
/// signature: it is verified and must stay bound, but Windows does not
/// launch it (the Job object replaces its parent-death guarantee).
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
    let result = run_local(executable, cwd, arguments, budget)?;
    supervisor.verify_binding()?;
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn argv_keeps_quotes_backslashes_and_shell_metacharacters_literal() {
        let encoded = command_line(
            OsStr::new(r"C:\Program Files\trace_streamer.exe"),
            &["".into(), "a\"b\\".into(), "& | %PATH%".into()],
        )
        .unwrap();
        assert_eq!(
            String::from_utf16(&encoded[..encoded.len() - 1]).unwrap(),
            "\"C:\\Program Files\\trace_streamer.exe\" \"\" \"a\\\"b\\\\\" \"& | %PATH%\""
        );
        assert!(command_line(OsStr::new("x.exe"), &["bad\0".into()]).is_err());
    }

    #[test]
    fn pe_header_check_accepts_only_amd64_executables() {
        let mut image = vec![0_u8; 512];
        image[..2].copy_from_slice(b"MZ");
        image[0x3c..0x40].copy_from_slice(&0x80_u32.to_le_bytes());
        image[0x80..0x84].copy_from_slice(b"PE\0\0");
        image[0x84..0x86].copy_from_slice(&0x8664_u16.to_le_bytes());
        image[0x96..0x98].copy_from_slice(&0x0022_u16.to_le_bytes());
        image[0x98..0x9a].copy_from_slice(&0x020b_u16.to_le_bytes());
        assert!(amd64_executable(&image));
        let mut dll = image.clone();
        dll[0x96..0x98].copy_from_slice(&0x2022_u16.to_le_bytes());
        assert!(!amd64_executable(&dll));
        let mut arm = image.clone();
        arm[0x84..0x86].copy_from_slice(&0xaa64_u16.to_le_bytes());
        assert!(!amd64_executable(&arm));
        let mut pe32 = image.clone();
        pe32[0x98..0x9a].copy_from_slice(&0x010b_u16.to_le_bytes());
        assert!(!amd64_executable(&pe32));
        assert!(!amd64_executable(b"MZ"));
        let mut far = image;
        far[0x3c..0x40].copy_from_slice(&0xffff_fff0_u32.to_le_bytes());
        assert!(!amd64_executable(&far));
    }

    #[test]
    fn the_child_environment_is_minimal_and_sorted() {
        let fixture = super::super::tests::Fixture::new();
        let block = environment_block(&fixture.1).unwrap();
        let text = String::from_utf16(&block).unwrap();
        let rows: Vec<&str> = text.split('\0').filter(|r| !r.is_empty()).collect();
        let names: Vec<&str> = rows.iter().map(|r| r.split('=').next().unwrap()).collect();
        assert_eq!(
            names,
            [
                "LANG",
                "LC_ALL",
                "PATH",
                "SystemRoot",
                "TEMP",
                "TMP",
                "WINDIR"
            ]
        );
        assert!(rows.contains(&format!("TMP={}", fixture.0.display()).as_str()));
    }
}
