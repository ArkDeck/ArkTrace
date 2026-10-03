#![cfg(target_os = "macos")]
use arktrace_platform::{
    CancellationToken, CodeTrustPolicy, HeldDirectory, HeldFile, HostError, IoBudget,
    ProcessBudget, ProcessError, ProcessOutputFileBudget, VerifiedExecutable, run_supervised,
};
use std::{
    ffi::OsString,
    fs::{self, DirBuilder},
    os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt},
    path::{Path, PathBuf},
    process::{Child, Command},
    sync::atomic::{AtomicU64, Ordering},
    time::{Duration, Instant},
};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Fixture {
    path: PathBuf,
    root: HeldDirectory,
    helper: VerifiedExecutable,
    tool: VerifiedExecutable,
}
fn io_budget() -> IoBudget {
    IoBudget {
        maximum_bytes: 256 * 1024 * 1024,
        deadline: Instant::now() + Duration::from_secs(10),
        cancellation: CancellationToken::default(),
    }
}
fn process_budget() -> ProcessBudget {
    ProcessBudget {
        deadline: Instant::now() + Duration::from_secs(5),
        cancellation: CancellationToken::default(),
        stdout_bytes: 65_536,
        stderr_bytes: 65_536,
        termination_grace: Duration::from_millis(50),
        output_files: Vec::new(),
    }
}
impl Fixture {
    fn new() -> Self {
        let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arktrace-process-{}-{}-空 格",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        DirBuilder::new().mode(0o700).create(&path).unwrap();
        let root = HeldDirectory::open_private(&path).unwrap();
        let tools = root.create_private_child("tools").unwrap();
        let helper = Self::copy(
            &tools,
            Path::new(env!("CARGO_BIN_EXE_arktrace-host-process")),
            "supervisor",
        );
        let tool = Self::copy(
            &tools,
            Path::new(env!("CARGO_BIN_EXE_arktrace-process-fixture")),
            "fixture",
        );
        Self {
            path,
            root,
            helper,
            tool,
        }
    }
    fn copy(directory: &HeldDirectory, path: &Path, name: &str) -> VerifiedExecutable {
        let raw = HeldFile::open_explicit_source(path).unwrap();
        let (snapshot, facts) = directory
            .copy_snapshot(&raw, name, true, &io_budget())
            .unwrap();
        VerifiedExecutable::verify(
            snapshot,
            &facts.sha256,
            CodeTrustPolicy::DevelopmentPinned,
            &io_budget(),
        )
        .unwrap()
    }
    fn run(
        &self,
        args: &[&str],
        budget: &ProcessBudget,
    ) -> Result<arktrace_platform::ProcessOutcome, ProcessError> {
        run_supervised(
            &self.helper,
            &self.tool,
            &self.root,
            &args.iter().map(OsString::from).collect::<Vec<_>>(),
            budget,
        )
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.path).unwrap();
    }
}

#[test]
fn preserves_literal_arguments_unicode_empty_value_cwd_and_minimal_environment() {
    let fixture = Fixture::new();
    let args = ["echo", "", "空 格", "a\"b'c", "$(no-shell); * \\ value"];
    let outcome = fixture.run(&args, &process_budget()).unwrap();
    assert_eq!(
        fs::read(fixture.path.join(".supervisor-entered")).unwrap(),
        b"entered"
    );
    assert_eq!(outcome.exit_code, Some(0));
    assert!(outcome.stderr.is_empty());
    let value: serde_json::Value = serde_json::from_slice(&outcome.stdout).unwrap();
    assert_eq!(value["fds"], serde_json::json!([]));
    assert_eq!(value["args"], serde_json::json!(&args[1..]));
    assert_eq!(value["cwd"], fixture.path.to_str().unwrap());
    let mut environment = value["env"].as_object().unwrap().clone();
    // CoreFoundation can initialize asynchronously and add its own per-user
    // encoding value. The spawn environment itself is exactly the fixed four
    // keys; no parent-supplied CF, DYLD, HOME or PATH override is forwarded.
    if let Some(encoding) = environment.remove("__CF_USER_TEXT_ENCODING") {
        let values = encoding
            .as_str()
            .unwrap()
            .split(':')
            .map(|part| u32::from_str_radix(part.strip_prefix("0x").unwrap(), 16).unwrap())
            .collect::<Vec<_>>();
        assert_eq!(values.len(), 3);
        assert_eq!(values[0], fs::metadata(&fixture.path).unwrap().uid());
    }
    assert_eq!(
        serde_json::Value::Object(environment),
        serde_json::json!({"LANG":"C","LC_ALL":"C","PATH":"/usr/bin:/bin","TMPDIR":fixture.path})
    );
}

#[test]
fn transports_full_output_cap_without_replaying_partial_protocol_writes() {
    let fixture = Fixture::new();
    let outcome = fixture.run(&["full-out"], &process_budget()).unwrap();
    assert_eq!(outcome.exit_code, Some(0));
    assert_eq!(outcome.stdout, vec![255; 65_536]);
}

fn marker(fixture: &Fixture, name: &str) -> i32 {
    let deadline = Instant::now() + Duration::from_secs(4);
    loop {
        if let Ok(value) = fs::read_to_string(fixture.path.join(name))
            && let Ok(pid) = value.parse::<i32>()
        {
            assert!(pid > 0);
            return pid;
        }
        assert!(Instant::now() < deadline, "missing process marker: {name}");
        std::thread::sleep(Duration::from_millis(5));
    }
}
fn assert_stopped(pids: &[i32]) {
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        if pids
            .iter()
            .all(|pid| !arktrace_platform::process_fixture::is_live(*pid).unwrap())
        {
            return;
        }
        assert!(Instant::now() < deadline, "owned process tree still live");
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn cancellation_kills_term_ignoring_child_and_grandchild_before_returning() {
    let fixture = Fixture::new();
    let budget = process_budget();
    std::thread::scope(|scope| {
        let running = scope.spawn(|| fixture.run(&["tree"], &budget));
        let child = marker(&fixture, "child.pid");
        let grandchild = marker(&fixture, "grandchild.pid");
        assert!(arktrace_platform::process_fixture::is_live(child).unwrap());
        assert!(arktrace_platform::process_fixture::is_live(grandchild).unwrap());
        budget.cancellation.cancel();
        assert_eq!(running.join().unwrap(), Err(ProcessError::Cancelled));
        assert_stopped(&[child, grandchild, marker(&fixture, "supervisor.pid")]);
    });
}

#[test]
fn deadline_kills_term_ignoring_process_tree() {
    let fixture = Fixture::new();
    let budget = ProcessBudget {
        deadline: Instant::now() + Duration::from_secs(2),
        ..process_budget()
    };
    assert_eq!(
        fixture.run(&["tree"], &budget),
        Err(ProcessError::DeadlineExceeded)
    );
    assert_stopped(&[
        marker(&fixture, "child.pid"),
        marker(&fixture, "grandchild.pid"),
        marker(&fixture, "supervisor.pid"),
    ]);
}

#[test]
fn reaps_exit_and_kills_descendants_with_inherited_or_closed_pipes() {
    for mode in ["orphan-pipe", "orphan-closed"] {
        let fixture = Fixture::new();
        let outcome = fixture.run(&[mode], &process_budget()).unwrap();
        assert_eq!(outcome.exit_code, Some(0));
        assert!(outcome.escalated_to_kill);
        assert_stopped(&[
            marker(&fixture, "child.pid"),
            marker(&fixture, "grandchild.pid"),
            marker(&fixture, "supervisor.pid"),
        ]);
    }
}

struct EngineWorker(Child);
impl Drop for EngineWorker {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let end = Instant::now() + Duration::from_secs(3);
        while self.0.try_wait().unwrap().is_none() {
            assert!(Instant::now() < end, "engine worker not reaped");
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}
#[test]
fn host_sigkill_closes_control_pipe_and_independently_reclaims_process_tree() {
    let fixture = Fixture::new();
    let mut worker = EngineWorker(
        Command::new(env!("CARGO_BIN_EXE_arktrace-process-fixture"))
            .args(["engine-worker", fixture.path.to_str().unwrap()])
            .spawn()
            .unwrap(),
    );
    let child = marker(&fixture, "child.pid");
    let grandchild = marker(&fixture, "grandchild.pid");
    let helper = marker(&fixture, "supervisor.pid");
    assert!(arktrace_platform::process_fixture::is_live(helper).unwrap());
    worker.0.kill().unwrap();
    assert_stopped(&[child, grandchild, helper]);
    assert!(!fixture.path.join("engine-result.json").exists());
}

#[test]
fn host_sigkill_during_suspended_bootstrap_terminates_helper_before_entry() {
    for mode in ["engine-bootstrap", "engine-bootstrap-session"] {
        let fixture = Fixture::new();
        let mut worker = EngineWorker(
            Command::new(env!("CARGO_BIN_EXE_arktrace-process-fixture"))
                .args([mode, fixture.path.to_str().unwrap()])
                .spawn()
                .unwrap(),
        );
        let helper = marker(&fixture, "bootstrap.pid");
        assert!(arktrace_platform::process_fixture::is_stopped(helper).unwrap());
        assert!(!fixture.path.join(".supervisor-entered").exists());
        worker.0.kill().unwrap();
        assert_stopped(&[helper]);
        assert!(!fixture.path.join(".supervisor-entered").exists());
        assert!(!fixture.path.join("child.pid").exists());
        assert!(!fixture.path.join("engine-result.json").exists());
    }
}

#[test]
fn preserves_nonzero_exit_without_inventing_success() {
    let fixture = Fixture::new();
    let outcome = fixture.run(&["exit"], &process_budget()).unwrap();
    assert_eq!(outcome.exit_code, Some(17));
    assert_eq!(outcome.signal, None);
}

#[test]
fn stops_stdout_and_stderr_flood_at_separate_caps() {
    let fixture = Fixture::new();
    assert_eq!(
        fixture.run(&["flood-out"], &process_budget()),
        Err(ProcessError::StdoutLimitExceeded)
    );
    assert_eq!(
        fixture.run(&["flood-err"], &process_budget()),
        Err(ProcessError::StderrLimitExceeded)
    );
}

fn output_budget(name: &str, maximum_bytes: u64) -> ProcessOutputFileBudget {
    ProcessOutputFileBudget {
        name: OsString::from(name),
        maximum_bytes,
    }
}

#[test]
fn output_file_cap_kills_term_ignoring_writer_tree_before_return() {
    let fixture = Fixture::new();
    let budget = ProcessBudget {
        output_files: vec![output_budget("诊 断.ohos.ts", 65_536)],
        ..process_budget()
    };
    assert_eq!(
        fixture.run(&["file-tree", "诊 断.ohos.ts"], &budget),
        Err(ProcessError::OutputFileLimitExceeded { index: 0 })
    );
    assert_stopped(&[
        marker(&fixture, "child.pid"),
        marker(&fixture, "grandchild.pid"),
        marker(&fixture, "supervisor.pid"),
    ]);
    assert!(
        !serde_json::to_string(&ProcessError::OutputFileLimitExceeded { index: 0 })
            .unwrap()
            .contains(fixture.path.to_str().unwrap())
    );
}

#[test]
fn short_lived_output_obeys_exact_cap_and_reports_absent_optional_files() {
    for (size, expected) in [(65_536, true), (65_537, false)] {
        let fixture = Fixture::new();
        let budget = ProcessBudget {
            output_files: vec![
                output_budget("partial.db", 131_072),
                output_budget("诊 断.ohos.ts", 65_536),
            ],
            ..process_budget()
        };
        let result = fixture.run(&["file-once", "诊 断.ohos.ts", &size.to_string()], &budget);
        if expected {
            let outcome = result.unwrap();
            assert_eq!(outcome.exit_code, Some(0));
            assert_eq!(outcome.output_file_bytes, [None, Some(size)]);
        } else {
            assert_eq!(
                result,
                Err(ProcessError::OutputFileLimitExceeded { index: 1 })
            );
        }
    }
    let fixture = Fixture::new();
    let budget = ProcessBudget {
        output_files: vec![output_budget("optional", 1)],
        ..process_budget()
    };
    assert_eq!(
        fixture.run(&["exit"], &budget).unwrap().output_file_bytes,
        [None]
    );
}

#[test]
fn nested_output_limit_stops_term_ignoring_descendants() {
    let fixture = Fixture::new();
    let name = "ts_tmp/unzlib_file.txt";
    let budget = ProcessBudget {
        output_files: vec![output_budget(name, 65_536)],
        ..process_budget()
    };
    assert_eq!(
        fixture.run(&["file-tree", name], &budget),
        Err(ProcessError::OutputFileLimitExceeded { index: 0 })
    );
    assert_stopped(&[
        marker(&fixture, "child.pid"),
        marker(&fixture, "grandchild.pid"),
        marker(&fixture, "supervisor.pid"),
    ]);
}

#[test]
fn nested_outputs_share_parent_and_preserve_exact_cap_and_optional_absence() {
    for (size, expected) in [(65_536, true), (65_537, false)] {
        let fixture = Fixture::new();
        let name = "ts_tmp/unzlib_file.txt";
        let budget = ProcessBudget {
            output_files: vec![
                output_budget("ts_tmp/optional", 1),
                output_budget(name, 65_536),
            ],
            ..process_budget()
        };
        let result = fixture.run(&["file-once", name, &size.to_string()], &budget);
        if expected {
            assert_eq!(result.unwrap().output_file_bytes, [None, Some(size)]);
        } else {
            assert_eq!(
                result,
                Err(ProcessError::OutputFileLimitExceeded { index: 1 })
            );
        }
    }
}

#[test]
fn descendants_cannot_hide_output_excess_in_cleanup_after_leader_exit() {
    for mode in ["stdout", "file"] {
        let fixture = Fixture::new();
        let budget = ProcessBudget {
            termination_grace: Duration::from_millis(500),
            output_files: vec![output_budget("tail.ohos.ts", 65_536)],
            ..process_budget()
        };
        let expected = if mode == "stdout" {
            ProcessError::StdoutLimitExceeded
        } else {
            ProcessError::OutputFileLimitExceeded { index: 0 }
        };
        assert_eq!(
            fixture.run(&["tail-after-exit", mode], &budget),
            Err(expected)
        );
        assert_eq!(
            fs::read(fixture.path.join("tail.writing")).unwrap(),
            b"writing"
        );
        assert_stopped(&[
            marker(&fixture, "child.pid"),
            marker(&fixture, "grandchild.pid"),
            marker(&fixture, "supervisor.pid"),
        ]);
    }
}

#[test]
fn rejects_invalid_output_declarations_and_existing_objects_before_launch() {
    let fixture = Fixture::new();
    for files in [
        vec![output_budget("a", 0)],
        vec![output_budget("a", u64::MAX)],
        vec![output_budget(".", 1)],
        vec![output_budget("../outside", 1)],
        vec![output_budget("/outside", 1)],
        vec![output_budget("nested/../a", 1)],
        vec![output_budget("nested//a", 1)],
        vec![output_budget("a/b/c/d/e/f/g/h/i", 1)],
        vec![output_budget(&"a".repeat(1025), 1)],
        vec![output_budget("a", 1), output_budget("a/b", 1)],
        vec![output_budget("a\0b", 1)],
        vec![output_budget("same", 1), output_budget("same", 2)],
        (0..17)
            .map(|i| output_budget(&format!("file-{i}"), 1))
            .collect(),
    ] {
        let budget = ProcessBudget {
            output_files: files,
            ..process_budget()
        };
        assert_eq!(
            fixture.run(&["exit"], &budget),
            Err(ProcessError::InvalidArguments)
        );
        assert!(!fixture.path.join(".supervisor-entered").exists());
    }
    fs::write(fixture.path.join("existing"), b"preserve").unwrap();
    fs::create_dir(fixture.path.join("directory")).unwrap();
    std::os::unix::fs::symlink("existing", fixture.path.join("link")).unwrap();
    for name in ["existing", "directory", "link"] {
        let budget = ProcessBudget {
            output_files: vec![output_budget(name, 100)],
            ..process_budget()
        };
        assert_eq!(
            fixture.run(&["exit"], &budget),
            Err(ProcessError::Host(HostError::AlreadyExists))
        );
        assert!(!fixture.path.join(".supervisor-entered").exists());
    }
    assert_eq!(
        fs::read(fixture.path.join("existing")).unwrap(),
        b"preserve"
    );
}

#[test]
fn rejects_pre_cancel_expired_budget_and_nul_argument() {
    let fixture = Fixture::new();
    let cancelled = process_budget();
    cancelled.cancellation.cancel();
    assert_eq!(
        fixture.run(&["echo"], &cancelled),
        Err(ProcessError::Cancelled)
    );
    let expired = ProcessBudget {
        deadline: Instant::now(),
        ..process_budget()
    };
    assert_eq!(
        fixture.run(&["echo"], &expired),
        Err(ProcessError::DeadlineExceeded)
    );
    assert_eq!(
        fixture.run(&["echo", "a\0b"], &process_budget()),
        Err(ProcessError::InvalidArguments)
    );
}

#[test]
fn rejects_verified_tool_path_replacement_before_launch() {
    let fixture = Fixture::new();
    let path = fixture.path.join("tools/fixture");
    fs::rename(&path, fixture.path.join("tools/original")).unwrap();
    fs::copy(env!("CARGO_BIN_EXE_arktrace-host-process"), &path).unwrap();
    assert_eq!(
        fixture.run(&["echo"], &process_budget()),
        Err(ProcessError::Host(HostError::IdentityMismatch))
    );
    assert!(!fixture.path.join("child.pid").exists());
}

#[test]
fn rejects_kernel_identity_mismatch_before_resuming_suspended_executable() {
    let fixture = Fixture::new();
    assert_eq!(
        arktrace_platform::process_fixture::check_loaded_identity(
            &fixture.helper,
            &fixture.tool,
            &fixture.root
        ),
        Err(ProcessError::DigestMismatch)
    );
}

#[test]
fn adhoc_development_artifact_cannot_satisfy_production_identity_or_bad_pin() {
    let fixture = Fixture::new();
    let tools = HeldDirectory::open_private(&fixture.path.join("tools")).unwrap();
    let verify = |digest: &str, policy| {
        VerifiedExecutable::verify(
            tools.open_file("fixture").unwrap(),
            digest,
            policy,
            &io_budget(),
        )
        .err()
        .unwrap()
    };
    assert_eq!(
        verify(&"0".repeat(64), CodeTrustPolicy::DevelopmentPinned),
        ProcessError::DigestMismatch
    );
    assert_eq!(
        verify(
            fixture.tool.sha256(),
            CodeTrustPolicy::DeveloperId {
                team_identifier: "AAAAAAAAAA".into(),
                code_identifier: "dev.arktrace.fixture".into()
            }
        ),
        ProcessError::TrustRejected
    );
    assert_eq!(
        verify(
            fixture.tool.sha256(),
            CodeTrustPolicy::DeveloperId {
                team_identifier: "bad\" or true".into(),
                code_identifier: "dev.arktrace.fixture".into()
            }
        ),
        ProcessError::InvalidPolicy
    );
    assert!(!fixture.tool.trust().developer_id);
    assert!(!fixture.tool.trust().hardened_runtime);
}

#[test]
fn rejects_corrupted_signature_even_when_development_digest_matches_bytes() {
    use std::io::{Read, Seek, SeekFrom, Write};
    let fixture = Fixture::new();
    let tools = HeldDirectory::open_private(&fixture.path.join("tools")).unwrap();
    let raw =
        HeldFile::open_explicit_source(Path::new(env!("CARGO_BIN_EXE_arktrace-process-fixture")))
            .unwrap();
    let (copy, _) = tools
        .copy_snapshot(&raw, "corrupted", true, &io_budget())
        .unwrap();
    let path = copy.path();
    drop(copy);
    fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
    let mut writer = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(&path)
        .unwrap();
    writer.seek(SeekFrom::Start(4096)).unwrap();
    let mut byte = [0];
    writer.read_exact(&mut byte).unwrap();
    writer.seek(SeekFrom::Start(4096)).unwrap();
    writer.write_all(&[byte[0] ^ 1]).unwrap();
    writer.sync_all().unwrap();
    drop(writer);
    fs::set_permissions(&path, fs::Permissions::from_mode(0o500)).unwrap();
    let corrupted = tools.open_file("corrupted").unwrap();
    let digest = corrupted.facts(&io_budget()).unwrap().sha256;
    assert_eq!(
        VerifiedExecutable::verify(
            corrupted,
            &digest,
            CodeTrustPolicy::DevelopmentPinned,
            &io_budget()
        )
        .err()
        .unwrap(),
        ProcessError::SignatureInvalid
    );
}
