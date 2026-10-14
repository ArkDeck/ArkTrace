//! Parser stand-in for the Windows process tests (`tests/windows_process.rs`).
//! Plain std only; the first argument selects the behaviour.
#[allow(clippy::zombie_processes)]
fn main() {
    use std::io::{Read, Write};
    let args: Vec<String> = std::env::args().skip(1).collect();
    let number = |index: usize| args[index].parse::<usize>().unwrap();
    match args.first().map(String::as_str) {
        Some("exit") => std::process::exit(number(1) as i32),
        Some("version") => {
            println!("TraceStreamer version 4.3.7");
            std::process::exit(1);
        }
        Some("out") => {
            std::io::stdout().write_all(&vec![b'a'; number(1)]).unwrap();
        }
        Some("err") => {
            std::io::stderr().write_all(&vec![b'e'; number(1)]).unwrap();
        }
        Some("sleep") => loop {
            std::thread::sleep(std::time::Duration::from_secs(1));
        },
        Some("env") => {
            let mut rows: Vec<String> = std::env::vars().map(|(k, v)| format!("{k}={v}")).collect();
            rows.sort();
            println!("{}", rows.join("\n"));
        }
        Some("stdin") => {
            let mut bytes = Vec::new();
            std::io::stdin().read_to_end(&mut bytes).unwrap();
            println!("{}", bytes.len());
        }
        Some("cwd") => println!("{}", std::env::current_dir().unwrap().display()),
        Some("write") => {
            let path = std::path::Path::new(&args[1]);
            if let Some(parent) = path.parent()
                && !parent.as_os_str().is_empty()
            {
                std::fs::create_dir_all(parent).unwrap();
            }
            std::fs::write(path, vec![b'w'; number(2)]).unwrap();
            if args.get(3).map(String::as_str) == Some("hold") {
                loop {
                    std::thread::sleep(std::time::Duration::from_secs(1));
                }
            }
        }
        Some("spawn") => {
            // A grandchild that outlives this process unless its Job ends it.
            let child = std::process::Command::new(std::env::current_exe().unwrap())
                .arg("sleep")
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .spawn()
                .unwrap();
            let report = std::path::Path::new(&args[1]);
            let partial = report.with_extension("partial");
            std::fs::write(&partial, child.id().to_string()).unwrap();
            std::fs::rename(&partial, report).unwrap();
            if args.get(2).map(String::as_str) == Some("hold") {
                loop {
                    std::thread::sleep(std::time::Duration::from_secs(1));
                }
            }
        }
        Some("guard-out") => {
            // The CLI's whole-buffer commit through the console guard.
            use arktrace_platform::{CancellationToken, CliSignalGuard, IoBudget};
            let token = CancellationToken::default();
            let guard = CliSignalGuard::install(token.clone()).unwrap();
            let budget = IoBudget {
                maximum_bytes: 1 << 30,
                deadline: std::time::Instant::now() + std::time::Duration::from_secs(20),
                cancellation: token,
            };
            if let Err(failure) = guard.write_stdout(&vec![b'g'; number(1)], &budget) {
                eprintln!("{:?} {}", failure.error, failure.written);
                std::process::exit(3);
            }
        }
        _ => std::process::exit(64),
    }
}
