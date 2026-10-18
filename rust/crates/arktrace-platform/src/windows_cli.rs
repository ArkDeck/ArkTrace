//! CLI-only mapped image, console control and bounded standard output
//! boundary: the Windows reading of `macos_cli.rs`.
//!
//! * The mapped image is named by the loader (`GetModuleFileNameW`) and
//!   identified by a kernel comparison with its image file object
//!   (`ProcessImageFileMapping`), never by a cached mapped-image pathname.
//! * The first Ctrl+C, Ctrl+Break or close/logoff/shutdown event cancels the
//!   invocation's token (the macOS first SIGINT/SIGTERM); a second one ends
//!   the process at once with 128 + the POSIX signal number (130 for
//!   Ctrl+C/Ctrl+Break, 143 for the others), as macOS `_exit` does.
//! * Standard handles cannot be made nonblocking, so a whole-buffer commit
//!   runs on a writer thread whose blocked `WriteFile` is cancelled
//!   (`CancelSynchronousIo`) on cancellation or deadline; the exact committed
//!   byte count is reported, as on macOS.
use super::{
    FileIdentity, FileSnapshot, HeldFile, HostError, IoBudget, SourceFacts, from_io,
    process::ProcessError,
    trust::{self, CodeTrustPolicy, TrustVerdict},
};
use crate::{CancellationToken, HostOperation};
use std::{
    ffi::OsString,
    marker::PhantomData,
    os::windows::{ffi::OsStringExt, io::AsRawHandle},
    path::{Component, Path, PathBuf},
    ptr::null_mut,
    rc::Rc,
    sync::{
        Arc, OnceLock,
        atomic::{AtomicBool, AtomicU8, AtomicUsize, Ordering},
    },
    thread,
    time::{Duration, Instant},
};
use windows_sys::Wdk::Storage::FileSystem::FILE_OPEN;
use windows_sys::Wdk::System::Threading::{NtQueryInformationProcess, ProcessImageFileMapping};
use windows_sys::Win32::Foundation::{ERROR_INVALID_HANDLE, INVALID_HANDLE_VALUE};
use windows_sys::Win32::Storage::FileSystem::{FILE_EXECUTE, WriteFile};
use windows_sys::Win32::System::Console::{
    CTRL_BREAK_EVENT, CTRL_C_EVENT, CTRL_CLOSE_EVENT, CTRL_LOGOFF_EVENT, CTRL_SHUTDOWN_EVENT,
    GetStdHandle, STD_ERROR_HANDLE, STD_HANDLE, STD_OUTPUT_HANDLE, SetConsoleCtrlHandler,
};
use windows_sys::Win32::System::IO::CancelSynchronousIo;
use windows_sys::Win32::System::LibraryLoader::GetModuleFileNameW;
use windows_sys::Win32::System::Threading::{GetCurrentProcess, TerminateProcess};
use windows_sys::core::BOOL;

const LONG_PATH: usize = 32_768;

fn module_path() -> Result<PathBuf, HostError> {
    let mut buffer = vec![0_u16; LONG_PATH];
    // SAFETY: the main module of this process and a bounded output buffer.
    let length = unsafe { GetModuleFileNameW(null_mut(), buffer.as_mut_ptr(), buffer.len() as u32) }
        as usize;
    if length == 0 || length >= buffer.len() {
        return Err(HostError::InvalidEvidence);
    }
    let path = PathBuf::from(OsString::from_wide(&buffer[..length]));
    if !path.is_absolute() {
        return Err(HostError::InvalidPath);
    }
    Ok(path)
}

/// Bind the held file to the current process's actual executable file object.
/// The memory manager can retain an old pathname after an installation directory
/// is renamed. ProcessImageFileMapping instead takes an INPUT file handle and
/// succeeds only for the process image's file, including after such a rename.
/// Unsupported or unsuccessful queries fail closed; there is no path fallback.
fn mapped_identity(held: &HeldFile) -> Result<FileIdentity, HostError> {
    held.verify()?;
    // The native comparison requires FILE_EXECUTE. Reopen through the held
    // parent without following links and bind the complete snapshot, so this
    // extra access never substitutes a different file for the held image.
    let executable = super::nt_open(
        &held.parent.0.file,
        &super::utf16(&held.name)?,
        super::READ | FILE_EXECUTE,
        FILE_OPEN,
        super::Kind::NonDirectory,
        None,
        HostOperation::Open,
    )?;
    if FileSnapshot::of(&executable)? != held.snapshot() {
        return Err(HostError::IdentityMismatch);
    }
    let mut handle = executable.as_raw_handle();
    // SAFETY: class 44 consumes a live file HANDLE in a pointer-sized input
    // buffer. The current-process pseudo handle and file remain valid through
    // the synchronous call; neither handle is transferred or closed by it.
    let status = unsafe {
        NtQueryInformationProcess(
            GetCurrentProcess(),
            ProcessImageFileMapping,
            std::ptr::from_mut(&mut handle).cast(),
            std::mem::size_of_val(&handle) as u32,
            null_mut(),
        )
    };
    if status != 0 {
        return Err(HostError::IdentityMismatch);
    }
    held.verify()?;
    if FileSnapshot::of(&executable)? != held.snapshot() {
        return Err(HostError::IdentityMismatch);
    }
    Ok(held.snapshot().identity)
}

pub struct MappedExecutable {
    path: PathBuf,
    file: HeldFile,
    identity: FileIdentity,
}
impl MappedExecutable {
    pub fn current() -> Result<Self, HostError> {
        let path = module_path()?;
        let file = HeldFile::open_explicit_source(&path)?;
        let identity = mapped_identity(&file)?;
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
        if mapped_identity(&self.file)? != self.identity {
            return Err(HostError::IdentityMismatch);
        }
        Ok(())
    }
    /// Windows has no sealed bundle resource table. The mapped image must
    /// lie inside `bundle` (an absolute installation root, compared
    /// component-wise and case-insensitively) and satisfy `policy`; the
    /// root's other files are bound by the distribution manifest's hashes.
    pub fn verify_bundle(
        &self,
        bundle: &Path,
        policy: &CodeTrustPolicy,
    ) -> Result<TrustVerdict, ProcessError> {
        self.verify()?;
        if !inside(&self.file.path(), bundle) && !inside(&self.path, bundle) {
            return Err(ProcessError::TrustRejected);
        }
        let verdict = trust::verify_file(&self.file, policy)?;
        self.verify()?;
        Ok(verdict)
    }
}

/// `path` is strictly below `root`, both absolute, every compared component
/// a plain name, compared as NTFS compares names (case-insensitively).
fn inside(path: &Path, root: &Path) -> bool {
    fn parts(path: &Path) -> Option<Vec<String>> {
        let mut parts = Vec::new();
        for component in path.components() {
            match component {
                Component::Prefix(prefix) => match prefix.kind() {
                    std::path::Prefix::Disk(letter) | std::path::Prefix::VerbatimDisk(letter) => {
                        parts.push(format!("{}:", char::from(letter).to_ascii_uppercase()));
                    }
                    _ => return None,
                },
                Component::RootDir => {}
                Component::Normal(name) => parts.push(name.to_str()?.to_uppercase()),
                Component::CurDir | Component::ParentDir => return None,
            }
        }
        Some(parts)
    }
    if !path.is_absolute() || !root.is_absolute() {
        return false;
    }
    match (parts(path), parts(root)) {
        (Some(path), Some(root)) => path.len() > root.len() && path.starts_with(&root),
        _ => false,
    }
}

static SIGNAL_USED: AtomicBool = AtomicBool::new(false);
static SIGNAL_COUNT: AtomicU8 = AtomicU8::new(0);
// The single CLI invocation's token, kept for the process lifetime so a
// handler already in flight never races its removal.
static SIGNAL_TOKEN: OnceLock<CancellationToken> = OnceLock::new();

unsafe extern "system" fn control_handler(event: u32) -> BOOL {
    let forced = match event {
        CTRL_C_EVENT | CTRL_BREAK_EVENT => 128 + 2,
        CTRL_CLOSE_EVENT | CTRL_LOGOFF_EVENT | CTRL_SHUTDOWN_EVENT => 128 + 15,
        _ => return 0,
    };
    if SIGNAL_COUNT.fetch_add(1, Ordering::SeqCst) != 0 {
        // SAFETY: the documented immediate forced exit of a second event,
        // the `_exit` of macOS; the Job handles close with the process.
        unsafe { TerminateProcess(GetCurrentProcess(), forced) };
    }
    if let Some(token) = SIGNAL_TOKEN.get() {
        token.cancel();
    }
    1
}

pub struct CliSignalGuard {
    token: CancellationToken,
    same_thread: PhantomData<Rc<()>>,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CliWriteFailure {
    pub error: HostError,
    pub written: usize,
}

/// A raw standard handle carried into the writer thread.
#[derive(Clone, Copy)]
struct RawHandle(usize);

impl CliSignalGuard {
    /// Whole-buffer stdout commit with request cancellation/deadline. The
    /// exact committed byte count prevents a second JSON frame after a
    /// partial write; a closed reader is a write error, never a signal.
    pub fn write_stdout(&self, bytes: &[u8], budget: &IoBudget) -> Result<(), CliWriteFailure> {
        self.write_standard(STD_OUTPUT_HANDLE, bytes, budget)
    }
    pub fn write_stderr(&self, bytes: &[u8], budget: &IoBudget) -> Result<(), CliWriteFailure> {
        self.write_standard(STD_ERROR_HANDLE, bytes, budget)
    }
    fn write_standard(
        &self,
        which: STD_HANDLE,
        bytes: &[u8],
        budget: &IoBudget,
    ) -> Result<(), CliWriteFailure> {
        let failure = |error, written| CliWriteFailure { error, written };
        if bytes.len() as u64 > budget.maximum_bytes {
            return Err(failure(HostError::LimitExceeded, 0));
        }
        self.check_pending();
        budget.check().map_err(|error| failure(error, 0))?;
        // SAFETY: GetStdHandle only reads this process's standard handle table.
        let handle = unsafe { GetStdHandle(which) };
        if handle.is_null() || handle == INVALID_HANDLE_VALUE {
            return Err(failure(
                HostError::SystemIo {
                    operation: HostOperation::Write,
                    code: ERROR_INVALID_HANDLE as i32,
                },
                0,
            ));
        }
        let target = RawHandle(handle as usize);
        let written = Arc::new(AtomicUsize::new(0));
        let stop = Arc::new(AtomicBool::new(false));
        let data = bytes.to_vec();
        let (worker_written, worker_stop) = (written.clone(), stop.clone());
        let worker = thread::Builder::new()
            .name("arktrace-stdout".to_owned())
            .spawn(move || -> Result<(), HostError> {
                let mut offset = 0;
                while offset < data.len() {
                    if worker_stop.load(Ordering::Acquire) {
                        return Err(HostError::Cancelled);
                    }
                    let count = (data.len() - offset).min(65_536) as u32;
                    let mut done = 0_u32;
                    // SAFETY: the inherited standard handle stays open for the
                    // process; the slice bounds are live through the call.
                    if unsafe {
                        WriteFile(
                            target.0 as *mut std::ffi::c_void,
                            data[offset..].as_ptr(),
                            count,
                            &mut done,
                            null_mut(),
                        )
                    } == 0
                    {
                        return Err(from_io(
                            std::io::Error::last_os_error(),
                            HostOperation::Write,
                        ));
                    }
                    if done == 0 {
                        return Err(HostError::InvalidEvidence);
                    }
                    offset += done as usize;
                    worker_written.store(offset, Ordering::Release);
                }
                Ok(())
            })
            .map_err(|_| failure(HostError::InvalidEvidence, 0))?;
        let mut stopped: Option<HostError> = None;
        let mut cancel_deadline = None;
        while !worker.is_finished() {
            self.check_pending();
            if stopped.is_none()
                && let Err(error) = budget.check()
            {
                stopped = Some(error);
                stop.store(true, Ordering::Release);
                cancel_deadline = Some(Instant::now() + Duration::from_secs(2));
            }
            if stopped.is_some() {
                // SAFETY: the writer thread's handle is live while its
                // JoinHandle is held; with no pending read this cancels nothing.
                unsafe { CancelSynchronousIo(worker.as_raw_handle()) };
                if cancel_deadline.is_some_and(|end| Instant::now() >= end) {
                    // A write the system will not cancel: report without it.
                    return Err(failure(
                        stopped.unwrap_or(HostError::Cancelled),
                        written.load(Ordering::Acquire),
                    ));
                }
            }
            thread::sleep(Duration::from_millis(5));
        }
        let result = worker.join().unwrap_or(Err(HostError::InvalidEvidence));
        let count = written.load(Ordering::Acquire);
        match (stopped, result) {
            (Some(error), _) if count < bytes.len() => Err(failure(error, count)),
            (_, Ok(())) => Ok(()),
            (_, Err(error)) => Err(failure(error, count)),
        }
    }
    pub fn install(token: CancellationToken) -> Result<Self, HostError> {
        if SIGNAL_USED.swap(true, Ordering::SeqCst) {
            return Err(HostError::Busy);
        }
        SIGNAL_TOKEN
            .set(token.clone())
            .map_err(|_| HostError::Busy)?;
        // A caller may have started this process with Ctrl+C ignored (a new
        // process group); restore normal processing, then add the handler.
        // A process without a console answers an error here, which is not a
        // failure: it receives no console control events at all.
        // SAFETY: the documented null-handler form.
        unsafe { SetConsoleCtrlHandler(None, 0) };
        // SAFETY: a static handler that only touches atomics and the token.
        if unsafe { SetConsoleCtrlHandler(Some(control_handler), 1) } == 0 {
            return Err(HostError::InvalidEvidence);
        }
        Ok(Self {
            token,
            same_thread: PhantomData,
        })
    }
    pub fn check_pending(&self) {
        if SIGNAL_COUNT.load(Ordering::SeqCst) != 0 {
            self.token.cancel();
        }
    }
}
impl Drop for CliSignalGuard {
    fn drop(&mut self) {
        // SAFETY: removes exactly the handler this guard installed.
        unsafe { SetConsoleCtrlHandler(Some(control_handler), 0) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundle_membership_is_component_wise_and_case_insensitive() {
        let root = Path::new(r"C:\Program Files\ArkTrace");
        assert!(inside(
            Path::new(r"C:\Program Files\ArkTrace\bin\arktrace.exe"),
            root
        ));
        assert!(inside(
            Path::new(r"\\?\c:\program files\arktrace\arktrace.exe"),
            root
        ));
        assert!(!inside(
            Path::new(r"C:\Program Files\ArkTraceX\arktrace.exe"),
            root
        ));
        assert!(!inside(root, root));
        assert!(!inside(
            Path::new(r"C:\Program Files\ArkTrace\..\x.exe"),
            root
        ));
        assert!(!inside(Path::new(r"D:\Program Files\ArkTrace\a.exe"), root));
        assert!(!inside(
            Path::new(r"\\server\share\a.exe"),
            Path::new(r"\\server\share")
        ));
    }

    /// The handler state machine, driven directly: a second event would end
    /// the test process, so only the first one is delivered.
    #[test]
    fn a_first_control_event_cancels_once_and_others_pass_through() {
        let token = CancellationToken::default();
        let guard = CliSignalGuard::install(token.clone()).unwrap();
        assert_eq!(
            CliSignalGuard::install(token.clone()).err(),
            Some(HostError::Busy)
        );
        // SAFETY: the handler only touches atomics and the token.
        assert_eq!(unsafe { control_handler(99) }, 0);
        assert!(!token.is_cancelled());
        // SAFETY: as above; the first event never exits.
        assert_eq!(unsafe { control_handler(CTRL_BREAK_EVENT) }, 1);
        assert!(token.is_cancelled());
        guard.check_pending();
        drop(guard);
    }

    #[test]
    fn the_running_test_image_is_identified_by_its_mapping() {
        let image = MappedExecutable::current().unwrap();
        assert_eq!(
            image.path().canonicalize().unwrap(),
            std::env::current_exe().unwrap().canonicalize().unwrap()
        );
        let facts = image
            .facts(&IoBudget {
                maximum_bytes: 1 << 30,
                deadline: Instant::now() + Duration::from_secs(60),
                cancellation: CancellationToken::default(),
            })
            .unwrap();
        assert_eq!(facts.sha256.len(), 64);
    }

    #[test]
    fn identical_bytes_in_another_file_are_not_the_running_image() {
        let image = MappedExecutable::current().unwrap();
        let fixture = super::super::tests::Fixture::new();
        let budget = IoBudget {
            maximum_bytes: 1 << 30,
            deadline: Instant::now() + Duration::from_secs(60),
            cancellation: CancellationToken::default(),
        };
        let (copy, facts) = fixture
            .1
            .copy_snapshot(&image.file, "copy.exe", true, &budget)
            .unwrap();
        assert_eq!(facts, image.facts(&budget).unwrap());
        assert_ne!(copy.snapshot().identity, image.identity);
        assert_eq!(mapped_identity(&copy), Err(HostError::IdentityMismatch));
        image.verify().unwrap();
    }
}
