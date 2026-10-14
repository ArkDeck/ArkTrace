#![cfg(windows)]
//! Real children under the Windows supervision port: the parser stand-in
//! `arktrace-windows-process-child` is copied into a private directory,
//! verified by its whole SHA-256 and run in a kill-on-close Job object.
use arktrace_platform::{
    CancellationToken, CodeTrustPolicy, HeldDirectory, HeldFile, HostError, IoBudget,
    ProcessBudget, ProcessError, ProcessOutputFileBudget, VerifiedExecutable, run_supervised,
    user_temporary_workspace,
};
use std::{
    ffi::OsString,
    path::{Path, PathBuf},
    process::Command,
    sync::atomic::{AtomicU64, Ordering},
    time::{Duration, Instant},
};

static NEXT: AtomicU64 = AtomicU64::new(0);

fn io() -> IoBudget {
    IoBudget {
        maximum_bytes: 1 << 30,
        deadline: Instant::now() + Duration::from_secs(60),
        cancellation: CancellationToken::default(),
    }
}

fn budget() -> ProcessBudget {
    ProcessBudget {
        deadline: Instant::now() + Duration::from_secs(30),
        cancellation: CancellationToken::default(),
        stdout_bytes: 65_536,
        stderr_bytes: 65_536,
        termination_grace: Duration::from_millis(200),
        output_files: Vec::new(),
    }
}

struct Fixture {
    root: PathBuf,
    work: HeldDirectory,
    tool: VerifiedExecutable,
    supervisor: VerifiedExecutable,
}
impl Fixture {
    fn new() -> Self {
        let parent = user_temporary_workspace("arktrace-windows-process-tests").unwrap();
        let name = format!(
            "run-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        );
        let root = parent.create_private_child(&name).unwrap();
        let work = root.create_private_child("work").unwrap();
        let tool = Self::copy(&root, "child.exe");
        let supervisor = Self::copy(&root, "supervisor.exe");
        Self {
            root: root.path().to_path_buf(),
            work,
            tool,
            supervisor,
        }
    }
    fn source() -> HeldFile {
        HeldFile::open_explicit_source(Path::new(env!(
            "CARGO_BIN_EXE_arktrace-windows-process-child"
        )))
        .unwrap()
    }
    fn copy(directory: &HeldDirectory, name: &str) -> VerifiedExecutable {
        let (copy, facts) = directory
            .copy_snapshot(&Self::source(), name, true, &io())
            .unwrap();
        VerifiedExecutable::verify(
            copy,
            &facts.sha256,
            CodeTrustPolicy::DevelopmentPinned,
            &io(),
        )
        .unwrap()
    }
    fn run(
        &self,
        arguments: &[&str],
        budget: &ProcessBudget,
    ) -> Result<arktrace_platform::ProcessOutcome, ProcessError> {
        let arguments: Vec<OsString> = arguments.iter().map(OsString::from).collect();
        run_supervised(&self.supervisor, &self.tool, &self.work, &arguments, budget)
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn alive(pid: u32) -> bool {
    let output = Command::new("tasklist")
        .args(["/FI", &format!("PID eq {pid}"), "/NH", "/FO", "CSV"])
        .output()
        .unwrap();
    String::from_utf8_lossy(&output.stdout).contains(&format!("\"{pid}\""))
}

fn wait_for(path: &Path) -> u32 {
    let end = Instant::now() + Duration::from_secs(20);
    loop {
        if let Some(pid) = std::fs::read_to_string(path)
            .ok()
            .and_then(|text| text.parse().ok())
        {
            return pid;
        }
        assert!(Instant::now() < end, "the grandchild was never named");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn success_failure_and_version_exits_are_reported_exactly() {
    let f = Fixture::new();
    let outcome = f.run(&["out", "10"], &budget()).unwrap();
    assert_eq!(outcome.exit_code, Some(0));
    assert_eq!(outcome.signal, None);
    assert_eq!(outcome.stdout, b"aaaaaaaaaa");
    assert!(outcome.stderr.is_empty());
    assert!(!outcome.escalated_to_kill);
    assert_eq!(f.run(&["exit", "3"], &budget()).unwrap().exit_code, Some(3));
    let version = f.run(&["version"], &budget()).unwrap();
    assert_eq!(version.exit_code, Some(1));
    assert!(
        String::from_utf8(version.stdout)
            .unwrap()
            .contains("version 4.3.7")
    );
}

#[test]
fn the_child_gets_nul_stdin_a_minimal_environment_and_the_private_cwd() {
    let f = Fixture::new();
    assert_eq!(f.run(&["stdin"], &budget()).unwrap().stdout, b"0\n");
    let environment = String::from_utf8(f.run(&["env"], &budget()).unwrap().stdout).unwrap();
    let names: Vec<&str> = environment
        .lines()
        .map(|row| row.split('=').next().unwrap())
        .collect();
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
        ],
        "{environment}"
    );
    assert!(environment.contains(&format!("TMP={}", f.work.path().display())));
    assert!(!environment.contains("USERPROFILE"));
    let cwd = String::from_utf8(f.run(&["cwd"], &budget()).unwrap().stdout).unwrap();
    assert_eq!(
        Path::new(cwd.trim()).canonicalize().unwrap(),
        f.work.path().canonicalize().unwrap()
    );
}

#[test]
fn stream_limits_are_enforced() {
    let f = Fixture::new();
    let limited = ProcessBudget {
        stdout_bytes: 10,
        stderr_bytes: 10,
        ..budget()
    };
    assert_eq!(
        f.run(&["out", "11"], &limited),
        Err(ProcessError::StdoutLimitExceeded)
    );
    assert_eq!(
        f.run(&["err", "100000"], &limited),
        Err(ProcessError::StderrLimitExceeded)
    );
    assert_eq!(f.run(&["out", "10"], &limited).unwrap().stdout.len(), 10);
}

#[test]
fn deadline_and_cancellation_terminate_the_job() {
    let f = Fixture::new();
    let started = Instant::now();
    let expired = ProcessBudget {
        deadline: Instant::now() + Duration::from_millis(500),
        ..budget()
    };
    assert_eq!(
        f.run(&["sleep"], &expired),
        Err(ProcessError::DeadlineExceeded)
    );
    assert!(started.elapsed() < Duration::from_secs(10));
    let cancelled = budget();
    let token = cancelled.cancellation.clone();
    let canceller = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(300));
        token.cancel();
    });
    assert_eq!(f.run(&["sleep"], &cancelled), Err(ProcessError::Cancelled));
    canceller.join().unwrap();
}

#[test]
fn a_grandchild_never_outlives_the_job() {
    let f = Fixture::new();
    // The leader stays alive until the deadline ends the whole Job.
    let report = f.root.join("held.pid");
    let report_text = report.to_str().unwrap().to_owned();
    let expired = ProcessBudget {
        deadline: Instant::now() + Duration::from_secs(5),
        ..budget()
    };
    let runner = {
        let pid_file = report.clone();
        std::thread::spawn(move || wait_for(&pid_file))
    };
    assert_eq!(
        f.run(&["spawn", &report_text, "hold"], &expired),
        Err(ProcessError::DeadlineExceeded)
    );
    let pid = runner.join().unwrap();
    assert!(!alive(pid), "grandchild {pid} survived its Job");

    // The leader exits at once; its grandchild gets the grace, then the Job
    // is terminated and the outcome says so.
    let report = f.root.join("orphan.pid");
    let outcome = f
        .run(&["spawn", report.to_str().unwrap()], &budget())
        .unwrap();
    assert_eq!(outcome.exit_code, Some(0));
    assert!(outcome.escalated_to_kill);
    let pid = wait_for(&report);
    assert!(!alive(pid), "orphaned grandchild {pid} survived");
}

#[test]
fn output_files_are_capped_and_must_be_fresh() {
    let f = Fixture::new();
    let declare = |name: &str, maximum_bytes| ProcessBudget {
        output_files: vec![ProcessOutputFileBudget {
            name: name.into(),
            maximum_bytes,
        }],
        ..budget()
    };
    let outcome = f
        .run(
            &["write", "partial.db", "100"],
            &declare("partial.db", 1000),
        )
        .unwrap();
    assert_eq!(outcome.output_file_bytes, [Some(100)]);
    let fresh = |f: &Fixture, name: &str| {
        let _ = std::fs::remove_dir_all(f.work.path().join(name));
        let _ = std::fs::remove_file(f.work.path().join(name));
    };
    fresh(&f, "partial.db");
    assert_eq!(
        f.run(&["write", "partial.db", "100"], &declare("partial.db", 10)),
        Err(ProcessError::OutputFileLimitExceeded { index: 0 })
    );
    fresh(&f, "partial.db");
    let nested = f
        .run(
            &["write", "ts_tmp/unzlib_file.txt", "7"],
            &declare("ts_tmp/unzlib_file.txt", 10),
        )
        .unwrap();
    assert_eq!(nested.output_file_bytes, [Some(7)]);
    // The declared output now exists: a second launch is refused before
    // any child starts.
    assert_eq!(
        f.run(&["exit", "0"], &declare("ts_tmp/unzlib_file.txt", 10)),
        Err(ProcessError::Host(HostError::AlreadyExists))
    );
    fresh(&f, "ts_tmp");
    let absent = f.run(&["exit", "0"], &declare("partial.db", 10)).unwrap();
    assert_eq!(absent.output_file_bytes, [None]);
}

#[test]
fn the_executable_pin_and_binding_are_enforced() {
    let f = Fixture::new();
    let root = HeldDirectory::open_private(&f.root).unwrap();
    let (copy, facts) = root
        .copy_snapshot(&Fixture::source(), "pinned.exe", true, &io())
        .unwrap();
    let wrong = format!("{:0>64}", "1");
    assert!(matches!(
        VerifiedExecutable::verify(copy, &wrong, CodeTrustPolicy::DevelopmentPinned, &io()),
        Err(ProcessError::DigestMismatch)
    ));
    // A name without `.exe` would make CreateProcessW name another file.
    let (bare, bare_facts) = root
        .copy_snapshot(&Fixture::source(), "trace-streamer", true, &io())
        .unwrap();
    assert!(matches!(
        VerifiedExecutable::verify(
            bare,
            &bare_facts.sha256,
            CodeTrustPolicy::DevelopmentPinned,
            &io()
        ),
        Err(ProcessError::InvalidExecutable)
    ));
    // A non-private copy needs a publisher policy.
    let source = Fixture::source();
    let source_facts = source.facts(&io()).unwrap();
    assert!(matches!(
        VerifiedExecutable::verify(
            source,
            &source_facts.sha256,
            CodeTrustPolicy::DevelopmentPinned,
            &io()
        ),
        Err(ProcessError::InvalidExecutable)
    ));
    let _ = facts;
    // Replace the verified copy after verification: the run is refused
    // before any child code runs.
    let child = f.root.join("child.exe");
    std::fs::rename(&child, f.root.join("moved.exe")).unwrap();
    std::fs::copy(f.root.join("supervisor.exe"), &child).unwrap();
    assert!(matches!(
        f.run(&["exit", "0"], &budget()),
        Err(ProcessError::Host(
            HostError::IdentityMismatch | HostError::Changed | HostError::NotPrivate
        ))
    ));
}

#[test]
fn cli_writes_commit_whole_buffers_and_report_a_closed_reader() {
    use std::io::Read;
    use std::process::Stdio;
    let child = env!("CARGO_BIN_EXE_arktrace-windows-process-child");
    let mut running = Command::new(child)
        .args(["guard-out", "1048576"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut bytes = Vec::new();
    // Read slowly at first: the writer must wait on the full pipe, not drop.
    std::thread::sleep(Duration::from_millis(200));
    running
        .stdout
        .take()
        .unwrap()
        .read_to_end(&mut bytes)
        .unwrap();
    assert!(running.wait().unwrap().success());
    assert_eq!(bytes.len(), 1_048_576);
    assert!(bytes.iter().all(|byte| *byte == b'g'));

    let mut closed = Command::new(child)
        .args(["guard-out", "1048576"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    drop(closed.stdout.take());
    let output = closed.wait_with_output().unwrap();
    assert_eq!(output.status.code(), Some(3), "{output:?}");
    let report = String::from_utf8(output.stderr).unwrap();
    assert!(report.starts_with("SystemIo"), "{report}");
}
