#[cfg(target_os = "macos")]
// Intentionally exercises orphaned descendants. The supervisor, rather than
// this parser stand-in, must stop the group and retain/reap its leader safely.
#[allow(clippy::zombie_processes)]
fn main() {
    use std::{
        io::Write,
        process::{Command, Stdio},
        time::Duration,
    };
    let args: Vec<_> = std::env::args().skip(1).collect();
    fn private_output_parent(path: &str) {
        use std::os::unix::fs::DirBuilderExt;
        if let Some(parent) = std::path::Path::new(path).parent()
            && !parent.as_os_str().is_empty()
        {
            std::fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(parent)
                .unwrap();
        }
    }
    match args.first().map(String::as_str) {
        Some("owner-worker") => {
            use arktrace_platform::{
                CancellationToken, HeldDirectory, IoBudget, OwnerKind, OwnerStore,
            };
            let root = HeldDirectory::open_private(std::path::Path::new(&args[1])).unwrap();
            let stage = HeldDirectory::open_private(&root.path().join("stage")).unwrap();
            let store = OwnerStore::open(&stage, &root).unwrap();
            if let Some(point) = args.get(2).and_then(|v| v.strip_prefix("create-")) {
                arktrace_platform::process_fixture::pause_owner_creation(point.parse().unwrap())
                    .unwrap();
            }
            let budget = IoBudget {
                maximum_bytes: 4096,
                deadline: std::time::Instant::now() + Duration::from_secs(10),
                cancellation: CancellationToken::default(),
            };
            let mut owned = store.create(OwnerKind::Building, &budget).unwrap();
            owned
                .directory()
                .write_new_readonly("partial.db", b"partial", &budget)
                .unwrap();
            std::fs::write(root.path().join("worker-owner.json"), serde_json::to_vec(&serde_json::json!({"identifier":owned.identifier(),"relativePath":format!("stage/{}",owned.identifier())})).unwrap()).unwrap();
            if let Some(point) = args.get(2).and_then(|v| v.strip_prefix("cleanup-")) {
                arktrace_platform::process_fixture::pause_owner_cleanup(point.parse().unwrap())
                    .unwrap();
                owned.cleanup(&budget).unwrap();
                std::process::exit(3);
            }
            loop {
                std::thread::sleep(Duration::from_secs(1));
                std::hint::black_box(&owned);
            }
        }
        Some("echo") => {
            println!(
                "{}",
                serde_json::json!({"args":&args[1..],"cwd":std::env::current_dir().unwrap(),"env":std::env::vars().collect::<std::collections::BTreeMap<_,_>>(),"fds":arktrace_platform::process_fixture::open_descriptors().unwrap()})
            );
        }
        Some("full-out") => std::io::stdout().write_all(&vec![255; 65_536]).unwrap(),
        Some("flood-out") | Some("flood-err") => {
            let bytes = vec![42; 131_072];
            if args[0] == "flood-out" {
                let _ = std::io::stdout().write_all(&bytes);
            } else {
                let _ = std::io::stderr().write_all(&bytes);
            }
        }
        Some("exit") => std::process::exit(17),
        Some("file-once") => {
            let count: usize = args[2].parse().unwrap();
            assert!(count <= 131_073);
            private_output_parent(&args[1]);
            std::fs::write(&args[1], vec![42; count]).unwrap();
        }
        Some("file-tree") => {
            arktrace_platform::process_fixture::ignore_term().unwrap();
            std::fs::write("child.pid", std::process::id().to_string()).unwrap();
            std::fs::write(
                "supervisor.pid",
                arktrace_platform::process_fixture::parent_pid().to_string(),
            )
            .unwrap();
            let child = Command::new(std::env::current_exe().unwrap())
                .args(["file-linger", &args[1]])
                .spawn()
                .unwrap();
            std::fs::write("spawned.pid", child.id().to_string()).unwrap();
            loop {
                std::thread::sleep(Duration::from_secs(1));
            }
        }
        Some("file-linger") => {
            arktrace_platform::process_fixture::ignore_term().unwrap();
            std::fs::write("grandchild.pid", std::process::id().to_string()).unwrap();
            private_output_parent(&args[1]);
            std::fs::write(&args[1], vec![42; 65_537]).unwrap();
            loop {
                std::thread::sleep(Duration::from_secs(1));
            }
        }
        Some("tail-after-exit") => {
            let child = Command::new(std::env::current_exe().unwrap())
                .args(["tail-writer", &args[1]])
                .spawn()
                .unwrap();
            std::fs::write("child.pid", std::process::id().to_string()).unwrap();
            std::fs::write("spawned.pid", child.id().to_string()).unwrap();
            std::fs::write(
                "supervisor.pid",
                arktrace_platform::process_fixture::parent_pid().to_string(),
            )
            .unwrap();
            let end = std::time::Instant::now() + Duration::from_secs(3);
            while !std::path::Path::new("tail.ready").exists() {
                assert!(std::time::Instant::now() < end);
                std::thread::sleep(Duration::from_millis(2));
            }
        }
        Some("tail-writer") => {
            arktrace_platform::process_fixture::ignore_term().unwrap();
            let parent = arktrace_platform::process_fixture::parent_pid();
            std::fs::write("grandchild.pid", std::process::id().to_string()).unwrap();
            std::fs::write("tail.ready", b"ready").unwrap();
            let end = std::time::Instant::now() + Duration::from_secs(3);
            while arktrace_platform::process_fixture::parent_pid() == parent {
                assert!(std::time::Instant::now() < end);
                std::thread::sleep(Duration::from_millis(2));
            }
            std::thread::sleep(Duration::from_millis(30));
            // Write only after the parser leader has exited. TERM is ignored so
            // this exercises the supervisor's drain/cleanup interval.
            std::fs::write("tail.writing", b"writing").unwrap();
            if args[1] == "stdout" {
                let _ = std::io::stdout().write_all(&vec![42; 131_072]);
            } else {
                std::fs::write("tail.ohos.ts", vec![42; 65_537]).unwrap();
            }
            loop {
                std::thread::sleep(Duration::from_secs(1));
            }
        }
        Some("tree") | Some("orphan-pipe") | Some("orphan-closed") => {
            arktrace_platform::process_fixture::ignore_term().unwrap();
            let self_path = std::env::current_exe().unwrap();
            // The parent and grandchild write independent proof markers.
            let mut command = Command::new(self_path);
            command.args(["linger", "grandchild.pid"]);
            if args[0] == "orphan-closed" {
                command
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null());
            }
            let child = command.spawn().unwrap();
            std::fs::write("child.pid", std::process::id().to_string()).unwrap();
            std::fs::write("spawned.pid", child.id().to_string()).unwrap();
            std::fs::write(
                "supervisor.pid",
                arktrace_platform::process_fixture::parent_pid().to_string(),
            )
            .unwrap();
            if args[0] != "tree" {
                return;
            }
            loop {
                std::thread::sleep(Duration::from_secs(1));
            }
        }
        Some("linger") => {
            arktrace_platform::process_fixture::ignore_term().unwrap();
            std::fs::write(&args[1], std::process::id().to_string()).unwrap();
            loop {
                std::thread::sleep(Duration::from_secs(1));
            }
        }
        Some("engine-worker") | Some("engine-bootstrap") | Some("engine-bootstrap-session") => {
            use arktrace_platform::{
                CancellationToken, CodeTrustPolicy, HeldDirectory, HeldFile, IoBudget,
                ProcessBudget, VerifiedExecutable, run_supervised,
            };
            use std::{ffi::OsString, path::Path, time::Instant};
            let root = HeldDirectory::open_private(Path::new(&args[1])).unwrap();
            if args[0] != "engine-worker" {
                if args[0] == "engine-bootstrap-session" {
                    arktrace_platform::process_fixture::new_session().unwrap();
                }
                arktrace_platform::process_fixture::ignore_hup().unwrap();
                arktrace_platform::process_fixture::pause_next_bootstrap();
            }
            let tools = HeldDirectory::open_private(&root.path().join("tools")).unwrap();
            let io = IoBudget {
                maximum_bytes: 256 * 1024 * 1024,
                deadline: Instant::now() + Duration::from_secs(10),
                cancellation: CancellationToken::default(),
            };
            let verify = |name| {
                let path = tools.path().join(name);
                let digest = HeldFile::open_explicit_source(&path)
                    .unwrap()
                    .facts(&io)
                    .unwrap()
                    .sha256;
                VerifiedExecutable::verify(
                    tools.open_file(name).unwrap(),
                    &digest,
                    CodeTrustPolicy::DevelopmentPinned,
                    &io,
                )
                .unwrap()
            };
            let helper = verify("supervisor");
            let tool = verify("fixture");
            let budget = ProcessBudget {
                deadline: Instant::now() + Duration::from_secs(20),
                cancellation: CancellationToken::default(),
                stdout_bytes: 65_536,
                stderr_bytes: 65_536,
                termination_grace: Duration::from_millis(50),
                output_files: Vec::new(),
            };
            let result = run_supervised(&helper, &tool, &root, &[OsString::from("tree")], &budget);
            std::fs::write(
                root.path().join("engine-result.json"),
                serde_json::to_vec(&result).unwrap(),
            )
            .unwrap();
        }
        _ => std::process::exit(2),
    }
}
#[cfg(not(target_os = "macos"))]
fn main() {
    std::process::exit(1);
}
