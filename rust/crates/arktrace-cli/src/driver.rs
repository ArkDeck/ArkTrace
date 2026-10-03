#[cfg(target_os = "macos")]
use crate::ToolIdentity;
#[cfg(target_os = "macos")]
use crate::arguments::Presentation;
use crate::arguments::{self, Command, Invocation};
use crate::public_error::{Code, PublicError, Stage};
#[cfg(target_os = "macos")]
use serde::Serialize;
use std::ffi::OsString;
#[cfg(not(target_os = "macos"))]
use std::io::{self, Write};
#[cfg(target_os = "macos")]
use std::{
    collections::BTreeMap,
    time::{Duration, Instant},
};

#[cfg(target_os = "macos")]
const HELP: &str = "ArkTrace Rust migration CLI\n\nUsage: arktrace [options] <command> <trace>\n\nCommands: inspect, processes, threads, query\nQuery: --view cpu-slices|thread-states|slices|counters --start-ns N --end-ns N\n       --cpu N --process-key N|--pid N --thread-key N|--tid N\n       --raw-state TEXT --state running|runnable|sleeping|blocked|stopped\n       --name TEXT --name-match exact|prefix|contains\n       --min-duration-ns N --depth N --filter-id N --limit N\nOptions: --json --pretty --no-cache --timeout-ms N --max-rows N\n         --max-events N --max-output-bytes N --trace-streamer /absolute/path\n         --help --version\n\nThis migration executable currently requires --no-cache.\n";
#[cfg(not(target_os = "macos"))]
const HELP: &str = "ArkTrace Rust migration CLI\n\nThe native trace runtime is not implemented on this platform yet.\nOptions: --help --version\n";
#[derive(Serialize)]
#[cfg(target_os = "macos")]
struct Request {
    command: &'static str,
    parameters: BTreeMap<&'static str, serde_json::Value>,
}
#[cfg(target_os = "macos")]
fn request(invocation: Option<&Invocation>, args: &[OsString]) -> Request {
    let Some(invocation) = invocation else {
        return Request {
            command: arguments::command_hint(args),
            parameters: BTreeMap::new(),
        };
    };
    let parameters = match &invocation.command {
        Command::Processes { query, .. } => BTreeMap::from([
            ("limit", serde_json::json!(query.limit)),
            ("name", serde_json::json!(query.name)),
            ("pid", serde_json::json!(query.pid)),
        ]),
        Command::Threads { query, .. } => BTreeMap::from([
            ("limit", serde_json::json!(query.limit)),
            ("name", serde_json::json!(query.name)),
            ("pid", serde_json::json!(query.pid)),
            ("processKey", serde_json::json!(query.process_key)),
            ("threadKey", serde_json::json!(query.thread_key)),
            ("tid", serde_json::json!(query.tid)),
        ]),
        Command::Query { query, .. } => query.parameters(),
        _ => BTreeMap::new(),
    };
    Request {
        command: invocation.command.name(),
        parameters,
    }
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
#[cfg(target_os = "macos")]
struct ErrorEnvelope<'a> {
    schema_version: &'static str,
    tool: &'a ToolIdentity,
    request: Request,
    error: &'a PublicError,
}
fn diagnostic(error: &PublicError) -> Vec<u8> {
    let code = serde_json::to_value(error.code())
        .ok()
        .and_then(|v| v.as_str().map(str::to_owned))
        .unwrap_or_else(|| "INTERNAL_ERROR".to_owned());
    format!("{code}: {}\n", error.code().message()).into_bytes()
}
#[cfg(not(target_os = "macos"))]
fn stderr(error: &PublicError, maximum: usize) {
    let message = diagnostic(error);
    if message.len() <= maximum {
        let _ = io::stderr().lock().write_all(&message);
    }
}
#[cfg(target_os = "macos")]
fn stderr(
    error: &PublicError,
    maximum: usize,
    signals: Option<&arktrace_platform::CliSignalGuard>,
) {
    let message = diagnostic(error);
    if message.len() <= maximum
        && let Some(signals) = signals
    {
        let budget = arktrace_platform::IoBudget {
            maximum_bytes: maximum as u64,
            deadline: Instant::now() + Duration::from_secs(1),
            cancellation: arktrace_platform::CancellationToken::default(),
        };
        let _ = signals.write_stderr(&message, &budget);
    }
}
#[cfg(not(target_os = "macos"))]
fn commit(bytes: &[u8], maximum: usize) -> Result<(), PublicError> {
    let mut written = 0;
    let mut output = io::stdout().lock();
    while written < bytes.len() {
        match output.write(&bytes[written..]) {
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Ok(0) | Err(_) => {
                let error = PublicError::new(Code::InternalError, Stage::Encoding);
                stderr(&error, maximum.saturating_sub(written));
                return Err(error);
            }
            Ok(count) => written += count,
        }
    }
    Ok(())
}
#[cfg(target_os = "macos")]
fn emit_error(
    mut error: PublicError,
    presentation: Presentation,
    tool: Option<&ToolIdentity>,
    req: Request,
    signals: &arktrace_platform::CliSignalGuard,
) -> i32 {
    if presentation.json
        && let Some(tool) = tool
    {
        let command = req.command;
        let envelope = ErrorEnvelope {
            schema_version: arktrace_contract::MACHINE_JSON_VERSION,
            tool,
            request: req,
            error: &error,
        };
        // Reporting cancellation/timeout has its own small deadline and token.
        // It cannot reuse the already-expired operation budget.
        let deadline = Instant::now() + Duration::from_secs(1);
        let token = arktrace_platform::CancellationToken::default();
        match crate::machine::encode_formatted(
            &envelope,
            presentation.limits.max_output_bytes,
            deadline,
            &token,
            presentation.pretty,
        ) {
            Ok(bytes) => {
                return commit_report(&bytes, presentation.limits.max_output_bytes, signals)
                    .err()
                    .unwrap_or(error)
                    .code()
                    .exit_status();
            }
            Err(crate::CommandError::OutputLimitExceeded) => {
                error = PublicError::new(Code::OutputLimitExceeded, Stage::Encoding);
                let minimum = ErrorEnvelope {
                    schema_version: arktrace_contract::MACHINE_JSON_VERSION,
                    tool,
                    request: Request {
                        command,
                        parameters: BTreeMap::new(),
                    },
                    error: &error,
                };
                if let Ok(bytes) = crate::machine::encode_formatted(
                    &minimum,
                    presentation.limits.max_output_bytes,
                    deadline,
                    &token,
                    false,
                ) {
                    return commit_report(&bytes, presentation.limits.max_output_bytes, signals)
                        .err()
                        .unwrap_or(error)
                        .code()
                        .exit_status();
                }
            }
            Err(_) => error = PublicError::new(Code::InternalError, Stage::Encoding),
        }
    }
    stderr(&error, presentation.limits.max_output_bytes, Some(signals));
    error.code().exit_status()
}
#[cfg(target_os = "macos")]
fn commit_report(
    bytes: &[u8],
    maximum: usize,
    signals: &arktrace_platform::CliSignalGuard,
) -> Result<(), PublicError> {
    let budget = arktrace_platform::IoBudget {
        maximum_bytes: maximum as u64,
        deadline: Instant::now() + Duration::from_secs(1),
        cancellation: arktrace_platform::CancellationToken::default(),
    };
    signals.write_stdout(bytes, &budget).map_err(|failure| {
        let error = crate::public_error::host_error(
            failure.error,
            PublicError::new(Code::InternalError, Stage::Encoding),
        );
        stderr(
            &error,
            maximum.saturating_sub(failure.written),
            Some(signals),
        );
        error
    })
}

#[cfg(target_os = "macos")]
mod macos {
    use super::*;
    use crate::public_error::{command_error, host_error};
    use arktrace_engine::{EngineBudget, ParserTools, SourceFormat, open_no_cache};
    use arktrace_platform::{
        CancellationToken, CliSignalGuard, HeldFile, HostError, IoBudget, MappedExecutable,
        OwnerKind, OwnerStore, user_temporary_workspace,
    };
    fn io(deadline: Instant, token: &CancellationToken) -> IoBudget {
        IoBudget {
            maximum_bytes: 256 * 1024 * 1024,
            deadline,
            cancellation: token.clone(),
        }
    }
    fn identify(image: &MappedExecutable, budget: &IoBudget) -> Result<ToolIdentity, PublicError> {
        let facts = image
            .facts(budget)
            .map_err(|e| host_error(e, PublicError::new(Code::InternalError, Stage::Request)))?;
        ToolIdentity::from_executable_sha256(facts.sha256).map_err(command_error)
    }
    fn execute(
        invocation: &Invocation,
        image: &MappedExecutable,
        tool: &ToolIdentity,
        budget: &IoBudget,
    ) -> Result<Vec<u8>, PublicError> {
        if !invocation.no_cache {
            return Err(PublicError::new(Code::InvalidArgument, Stage::Request));
        }
        budget
            .check()
            .map_err(|e| host_error(e, PublicError::new(Code::InternalError, Stage::Preparing)))?;
        let (path, command) = match &invocation.command {
            Command::Inspect { trace } => (trace, crate::DirectoryCommand::Inspect),
            Command::Processes { trace, query } => {
                (trace, crate::DirectoryCommand::Processes(query.clone()))
            }
            Command::Threads { trace, query } => {
                (trace, crate::DirectoryCommand::Threads(query.clone()))
            }
            Command::Query { trace, query } => {
                (trace, crate::DirectoryCommand::Query(query.clone()))
            }
            _ => return Err(PublicError::new(Code::InternalError, Stage::Request)),
        };
        let absolute = if path.is_absolute() {
            path.clone()
        } else {
            std::env::current_dir()
                .map_err(|_| PublicError::new(Code::TraceFileUnreadable, Stage::Preparing))?
                .join(path)
        };
        let source = HeldFile::open_explicit_source(&absolute).map_err(|e| {
            host_error(
                e,
                PublicError::new(
                    if e == HostError::NotFound {
                        Code::TraceFileNotFound
                    } else {
                        Code::TraceFileUnreadable
                    },
                    Stage::Preparing,
                ),
            )
        })?;
        let format = match path
            .extension()
            .and_then(|v| v.to_str())
            .map(str::to_ascii_lowercase)
            .as_deref()
        {
            Some("htrace") => SourceFormat::Htrace,
            Some("systrace") => SourceFormat::Systrace,
            _ => {
                return Err(PublicError::new(
                    Code::TraceFormatUnsupported,
                    Stage::Parsing,
                ));
            }
        };
        let root = user_temporary_workspace("com.arktrace.ArkTrace.rust-tools").map_err(|e| {
            host_error(
                e,
                PublicError::new(Code::TraceParseFailed, Stage::Preparing),
            )
        })?;
        let staging = root.ensure_private_child(".tool-staging").map_err(|e| {
            host_error(
                e,
                PublicError::new(Code::TraceParseFailed, Stage::Preparing),
            )
        })?;
        let owners = OwnerStore::open(&staging, &root).map_err(|e| {
            host_error(
                e,
                PublicError::new(Code::TraceParseFailed, Stage::Preparing),
            )
        })?;
        let mut owner = owners.create(OwnerKind::Session, budget).map_err(|e| {
            host_error(
                e,
                PublicError::new(Code::TraceParseFailed, Stage::Preparing),
            )
        })?;
        let result = (|| {
            let resources = crate::resources::load(
                image,
                &owner,
                invocation.parser_override.as_deref(),
                budget,
            )?;
            let namespace =
                user_temporary_workspace(&resources.storage_namespace).map_err(|e| {
                    host_error(
                        e,
                        PublicError::new(Code::TraceParseFailed, Stage::Preparing),
                    )
                })?;
            let engine_budget = EngineBudget {
                maximum_source_bytes: resources.maximum_source_bytes,
                maximum_database_bytes: resources.maximum_database_bytes,
                deadline: budget.deadline,
                cancellation: budget.cancellation.clone(),
            };
            let tools = ParserTools {
                helper: &resources.helper,
                parser: &resources.parser,
                identity: resources.identity.clone(),
            };
            let session =
                open_no_cache(&source, format, &tools, &namespace, &engine_budget, |_| {})
                    .map_err(|e| e.public_error())?;
            let format = if invocation.presentation.json {
                crate::OutputFormat::Machine {
                    pretty: invocation.presentation.pretty,
                }
            } else {
                crate::OutputFormat::Human
            };
            crate::execute_no_cache_formatted(
                session,
                command,
                tool,
                invocation.presentation.limits,
                &engine_budget,
                format,
            )
            .map_err(command_error)
        })();
        let cleanup = IoBudget {
            maximum_bytes: budget.maximum_bytes,
            deadline: Instant::now() + Duration::from_secs(5),
            cancellation: CancellationToken::default(),
        };
        owner
            .cleanup(&cleanup)
            .map_err(|_| PublicError::cleanup(Stage::Preparing, false))?;
        result
    }
    pub(super) fn run(arguments: Vec<OsString>) -> i32 {
        let started = Instant::now();
        let hint = arguments::hint(&arguments);
        let token = CancellationToken::default();
        let signals = match CliSignalGuard::install(token.clone()) {
            Ok(v) => v,
            Err(_) => {
                let e = PublicError::new(Code::InternalError, Stage::Request);
                stderr(&e, hint.limits.max_output_bytes, None);
                return e.code().exit_status();
            }
        };
        let parsed = arguments::parse(&arguments);
        let presentation = parsed.as_ref().map(|v| v.presentation).unwrap_or(hint);
        let budget = io(
            started + Duration::from_millis(presentation.limits.timeout_ms),
            &token,
        );
        let mut tool = None;
        let mut image = None;
        let result = (|| {
            let invocation = parsed.as_ref().map_err(|e| command_error(*e))?;
            signals.check_pending();
            budget.check().map_err(|e| {
                host_error(e, PublicError::new(Code::InternalError, Stage::Request))
            })?;
            if invocation.command == Command::Help {
                return Ok(HELP.as_bytes().to_vec());
            }
            if invocation.command == Command::Version {
                return Ok(format!("arktrace {}\n", env!("CARGO_PKG_VERSION")).into_bytes());
            }
            let current = MappedExecutable::current()
                .map_err(|_| PublicError::new(Code::InternalError, Stage::Request))?;
            tool = Some(identify(&current, &budget)?);
            image = Some(current);
            execute(
                invocation,
                image.as_ref().unwrap(),
                tool.as_ref().unwrap(),
                &budget,
            )
        })();
        signals.check_pending();
        let result = result.and_then(|bytes| {
            budget.check().map_err(|e| {
                host_error(e, PublicError::new(Code::InternalError, Stage::Encoding))
            })?;
            if bytes.len() > presentation.limits.max_output_bytes {
                return Err(PublicError::new(Code::OutputLimitExceeded, Stage::Encoding));
            }
            if let Some(image) = &image {
                identify(image, &budget)?;
            }
            Ok(bytes)
        });
        match result {
            Ok(bytes) => {
                let output_budget = IoBudget {
                    maximum_bytes: presentation.limits.max_output_bytes as u64,
                    ..budget.clone()
                };
                match signals.write_stdout(&bytes, &output_budget) {
                    Ok(()) => 0,
                    Err(failure) => {
                        let error = host_error(
                            failure.error,
                            PublicError::new(Code::InternalError, Stage::Encoding),
                        );
                        if failure.written == 0
                            && matches!(error.code(), Code::Cancelled | Code::QueryTimeout)
                        {
                            emit_error(
                                error,
                                presentation,
                                tool.as_ref(),
                                request(parsed.as_ref().ok(), &arguments),
                                &signals,
                            )
                        } else {
                            stderr(
                                &error,
                                presentation
                                    .limits
                                    .max_output_bytes
                                    .saturating_sub(failure.written),
                                Some(&signals),
                            );
                            error.code().exit_status()
                        }
                    }
                }
            }
            Err(mut error) => {
                if token.is_cancelled() && !error.is_cleanup_failure() {
                    error = PublicError::new(Code::Cancelled, error.stage());
                }
                if presentation.json && tool.is_none() {
                    let reporting = io(
                        Instant::now() + Duration::from_secs(5),
                        &CancellationToken::default(),
                    );
                    tool = MappedExecutable::current()
                        .ok()
                        .and_then(|v| identify(&v, &reporting).ok());
                }
                emit_error(
                    error,
                    presentation,
                    tool.as_ref(),
                    request(parsed.as_ref().ok(), &arguments),
                    &signals,
                )
            }
        }
    }
}

pub fn run(arguments: Vec<OsString>) -> i32 {
    #[cfg(target_os = "macos")]
    {
        macos::run(arguments)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let presentation = arguments::hint(&arguments);
        let result = arguments::parse(&arguments);
        let bytes = match result {
            Ok(Invocation {
                command: Command::Help,
                ..
            }) => Some(HELP.as_bytes().to_vec()),
            Ok(Invocation {
                command: Command::Version,
                ..
            }) => Some(format!("arktrace {}\n", env!("CARGO_PKG_VERSION")).into_bytes()),
            _ => None,
        };
        if let Some(bytes) = bytes {
            return commit(&bytes, presentation.limits.max_output_bytes)
                .err()
                .map_or(0, |e| e.code().exit_status());
        }
        let code = if result.is_err() {
            Code::InvalidArgument
        } else {
            Code::InternalError
        };
        let error = PublicError::new(code, Stage::Request);
        stderr(&error, presentation.limits.max_output_bytes);
        error.code().exit_status()
    }
}
