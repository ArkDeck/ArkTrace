#[cfg(any(target_os = "macos", windows))]
use crate::ToolIdentity;
#[cfg(any(target_os = "macos", windows))]
use crate::arguments::Presentation;
use crate::arguments::{self, Command, Invocation};
use crate::public_error::{Code, PublicError, Stage};
#[cfg(any(target_os = "macos", windows))]
use serde::Serialize;
use std::ffi::OsString;
#[cfg(not(any(target_os = "macos", windows)))]
use std::io::{self, Write};
#[cfg(any(target_os = "macos", windows))]
use std::{
    collections::BTreeMap,
    time::{Duration, Instant},
};

#[cfg(any(target_os = "macos", windows))]
const HELP: &str = "ArkTrace Rust migration CLI\n\nUsage: arktrace [options] <command> <trace>\n\nCommands: doctor, inspect, summary, processes, threads, query, context, analyze\nContext: --timestamp-ns N --window-ms N | --start-ns N --end-ns N, plus query filters\nAnalyze: --kind cpu|scheduling|slices|range|hot-intervals [--start-ns N --end-ns N]\n         --process-key N|--pid N --thread-key N|--tid N --threshold-ns N --limit N\nQuery: --view cpu-slices|thread-states|slices|counters --start-ns N --end-ns N\n       --cpu N --process-key N|--pid N --thread-key N|--tid N\n       --raw-state TEXT --state running|runnable|sleeping|blocked|stopped\n       --name TEXT --name-match exact|prefix|contains\n       --min-duration-ns N --depth N --filter-id N --limit N\nOptions: --json --pretty --no-cache --timeout-ms N --max-rows N\n         --max-events N --max-output-bytes N --trace-streamer /absolute/path\n         --help --version\n\nThis migration executable currently requires --no-cache.\n";
#[cfg(not(any(target_os = "macos", windows)))]
const HELP: &str = "ArkTrace Rust migration CLI\n\nThe native trace runtime is not implemented on this platform yet.\nOptions: --help --version\n";
#[derive(Serialize)]
#[cfg(any(target_os = "macos", windows))]
struct Request {
    command: &'static str,
    parameters: BTreeMap<&'static str, serde_json::Value>,
}
#[cfg(any(target_os = "macos", windows))]
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
        Command::Summary { range, .. } => BTreeMap::from([
            ("endNs", serde_json::json!(range.map(|r| r.end_ns()))),
            ("startNs", serde_json::json!(range.map(|r| r.start_ns()))),
        ]),
        Command::Doctor { self_test } => {
            BTreeMap::from([("selfTest", serde_json::json!(self_test))])
        }
        Command::Context { time, filters, .. } => {
            crate::event_query::context_parameters(time, filters)
        }
        Command::Analyze { options, .. } => crate::event_query::analyze_parameters(options),
        _ => BTreeMap::new(),
    };
    Request {
        command: invocation.command.name(),
        parameters,
    }
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
#[cfg(any(target_os = "macos", windows))]
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
#[cfg(not(any(target_os = "macos", windows)))]
fn stderr(error: &PublicError, maximum: usize) {
    let message = diagnostic(error);
    if message.len() <= maximum {
        let _ = io::stderr().lock().write_all(&message);
    }
}
#[cfg(any(target_os = "macos", windows))]
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
#[cfg(not(any(target_os = "macos", windows)))]
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
#[cfg(any(target_os = "macos", windows))]
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
#[cfg(any(target_os = "macos", windows))]
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

#[cfg(any(target_os = "macos", windows))]
mod macos {
    use super::*;
    use crate::public_error::{command_error, host_error};
    use arktrace_engine::{EngineBudget, NoCacheSession, ParserTools, SourceFormat, open_no_cache};
    use arktrace_platform::{
        CancellationToken, CliSignalGuard, HeldFile, HostError, IoBudget, MappedExecutable,
        OwnedDirectory, OwnerKind, OwnerStore, user_temporary_workspace,
    };
    /// The private per-product working root. On Windows a host that runs this
    /// CLI as its own private child (ArkDeck) names a root it owns with
    /// `ARKTRACE_STORAGE_ROOT`: an absolute, existing, owner-private directory,
    /// refused otherwise (never created, repaired or replaced). Without it the
    /// known LocalAppData folder is used. macOS has no override.
    fn workspace(name: &str) -> Result<arktrace_platform::HeldDirectory, HostError> {
        #[cfg(windows)]
        if let Some(root) = std::env::var_os(STORAGE_ROOT_VARIABLE) {
            let root = std::path::PathBuf::from(root);
            if !root.is_absolute() {
                return Err(HostError::InvalidPath);
            }
            return arktrace_platform::HeldDirectory::open_private(&root)?
                .ensure_private_child(name);
        }
        user_temporary_workspace(name)
    }
    #[cfg(windows)]
    pub(crate) const STORAGE_ROOT_VARIABLE: &str = "ARKTRACE_STORAGE_ROOT";
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
            Command::Summary { trace, range } => (trace, crate::DirectoryCommand::Summary(*range)),
            Command::Processes { trace, query } => {
                (trace, crate::DirectoryCommand::Processes(query.clone()))
            }
            Command::Threads { trace, query } => {
                (trace, crate::DirectoryCommand::Threads(query.clone()))
            }
            Command::Query { trace, query } => {
                (trace, crate::DirectoryCommand::Query(query.clone()))
            }
            Command::Context {
                trace,
                time,
                filters,
            } => (
                trace,
                crate::DirectoryCommand::Context {
                    time: *time,
                    filters: filters.clone(),
                },
            ),
            Command::Analyze { trace, options } => {
                (trace, crate::DirectoryCommand::Analyze(options.clone()))
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
            None => SourceFormat::Automatic,
            _ => {
                return Err(PublicError::new(
                    Code::TraceFormatUnsupported,
                    Stage::Parsing,
                ));
            }
        };
        with_owner(budget, |owner| {
            let resources = crate::resources::load(
                image,
                owner,
                invocation.parser_override.as_deref(),
                budget,
            )?;
            let (session, engine_budget) = open_session(&source, format, &resources, budget)?;
            crate::execute_no_cache_formatted(
                session,
                command,
                tool,
                invocation.presentation.limits,
                &engine_budget,
                output_format(invocation),
            )
            .map_err(command_error)
        })
    }
    fn output_format(invocation: &Invocation) -> crate::OutputFormat {
        if invocation.presentation.json {
            crate::OutputFormat::Machine {
                pretty: invocation.presentation.pretty,
            }
        } else {
            crate::OutputFormat::Human
        }
    }
    fn preparing(error: HostError) -> PublicError {
        host_error(
            error,
            PublicError::new(Code::TraceParseFailed, Stage::Preparing),
        )
    }
    /// One session-owned private directory (helper/parser snapshots) for the
    /// whole invocation, always cleaned up, cleanup failure taking priority.
    fn with_owner<T>(
        budget: &IoBudget,
        operation: impl FnOnce(&OwnedDirectory) -> Result<T, PublicError>,
    ) -> Result<T, PublicError> {
        let root = workspace("com.arktrace.ArkTrace.rust-tools").map_err(preparing)?;
        let staging = root
            .ensure_private_child(".tool-staging")
            .map_err(preparing)?;
        let owners = OwnerStore::open(&staging, &root).map_err(preparing)?;
        let mut owner = owners
            .create(OwnerKind::Session, budget)
            .map_err(preparing)?;
        let result = operation(&owner);
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
    fn open_session(
        source: &HeldFile,
        format: SourceFormat,
        resources: &crate::resources::Resources,
        budget: &IoBudget,
    ) -> Result<(NoCacheSession, EngineBudget), PublicError> {
        let namespace = workspace(&resources.storage_namespace).map_err(preparing)?;
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
        let session = open_no_cache(source, format, &tools, &namespace, &engine_budget, |_| {})
            .map_err(|e| e.public_error())?;
        Ok((session, engine_budget))
    }
    /// Swift `doctor`: the nine canonical checks; the first failing check's
    /// typed error is returned instead of a document, as in Swift.
    fn doctor(
        invocation: &Invocation,
        image: &MappedExecutable,
        tool: &ToolIdentity,
        budget: &IoBudget,
        self_test: bool,
    ) -> Result<Vec<u8>, PublicError> {
        use crate::DoctorStatus::{Failed, Ok as Passed};
        let mut first: Option<PublicError> = None;
        let mut statuses = vec![("tool", Passed), ("os", Passed)];
        if arktrace_platform::native_host().is_some() {
            statuses.push(("architecture", Passed));
        } else {
            statuses.push(("architecture", Failed));
            first = Some(PublicError::new(
                Code::AnalysisUnsupported,
                Stage::Analyzing,
            ));
        }
        with_owner(budget, |owner| {
            let resources =
                crate::resources::load(image, owner, invocation.parser_override.as_deref(), budget);
            let parser = if resources.is_ok() { Passed } else { Failed };
            statuses.push(("parserManifest", parser));
            statuses.push(("parserIdentity", parser));
            let resources = match resources {
                Ok(resources) => Some(resources),
                Err(error) if matches!(error.code(), Code::Cancelled) => return Err(error),
                Err(error) => {
                    first.get_or_insert(error);
                    None
                }
            };
            let sqlite = arktrace_engine::sqlite_runtime_available(
                budget.deadline,
                budget.cancellation.clone(),
            );
            statuses.push(("sqlite", if sqlite { Passed } else { Failed }));
            if !sqlite {
                first.get_or_insert(PublicError::new(
                    Code::AnalysisUnsupported,
                    Stage::Analyzing,
                ));
            }
            let namespace = resources
                .as_ref()
                .map_or("com.arktrace.ArkTrace.rust-tools", |r| &r.storage_namespace);
            let cache = workspace(namespace).is_ok();
            statuses.push(("cache", if cache { Passed } else { Failed }));
            if !cache {
                first.get_or_insert(PublicError::new(
                    Code::TraceCacheCorrupt,
                    Stage::CacheLookup,
                ));
            }
            let schema = !arktrace_contract::SCHEMA_ADAPTER_VERSION.is_empty();
            statuses.push(("schemaAdapter", if schema { Passed } else { Failed }));
            if !schema {
                first.get_or_insert(PublicError::new(Code::InternalError, Stage::Analyzing));
            }
            if self_test {
                let outcome = match &resources {
                    Some(resources) => self_test_summary(invocation, resources, budget),
                    None => Err(PublicError::new(Code::TraceParseFailed, Stage::Parsing)),
                };
                match outcome {
                    Ok(()) => statuses.push(("selfTest", Passed)),
                    Err(error) if matches!(error.code(), Code::Cancelled) => return Err(error),
                    Err(error) => {
                        statuses.push(("selfTest", Failed));
                        first.get_or_insert(error);
                    }
                }
            }
            Ok(())
        })?;
        if let Some(error) = first {
            return Err(error);
        }
        crate::doctor_document(
            tool,
            self_test,
            &statuses,
            invocation.presentation.limits,
            budget.deadline,
            &budget.cancellation,
            output_format(invocation),
        )
        .map_err(command_error)
    }
    /// Windows `licenses`: the verified installed attribution set; any drift,
    /// extra or missing file refuses the whole command.
    #[cfg(windows)]
    fn licenses(
        invocation: &Invocation,
        image: &MappedExecutable,
        tool: &ToolIdentity,
        budget: &IoBudget,
    ) -> Result<Vec<u8>, PublicError> {
        let set = crate::resources::licenses(image, budget)?;
        let value = |files: Vec<crate::resources::LicenseFile>| {
            files
                .into_iter()
                .map(|file| crate::LicenseFileValue {
                    byte_count: file.byte_count,
                    license_expression: file.license_expression,
                    owner: file.owner,
                    resource: file.resource,
                    sha256: file.sha256,
                })
                .collect()
        };
        let document = crate::LicensesValue {
            build_tool_count: set.build_tool_count,
            component_count: set.component_count,
            inventory: "license-inventory.json",
            license_files: value(set.files),
            notice: "THIRD_PARTY_NOTICES.md",
            product_license: "LICENSE",
            product_license_bytes: set.product_license_bytes,
            rust: crate::RustLicenseValue {
                dependency_count: set.rust_dependency_count,
                inventory: "rust/dependency-licenses.json",
                license_files: value(set.rust_files),
            },
            windows: crate::WindowsLicenseValue {
                build_tool_count: set.windows_build_tool_count,
                inventory: "windows-license-inventory.json",
                license_files: value(set.windows_files),
                static_runtime_count: set.windows_static_runtime_count,
            },
        };
        crate::licenses_document(
            tool,
            &document,
            invocation.presentation.limits,
            budget.deadline,
            &budget.cancellation,
            output_format(invocation),
        )
        .map_err(command_error)
    }
    /// The bundled reviewed trace (whole SHA-256 pinned) parsed and
    /// summarized end to end; the summary's schema must be the session's.
    fn self_test_summary(
        invocation: &Invocation,
        resources: &crate::resources::Resources,
        budget: &IoBudget,
    ) -> Result<(), PublicError> {
        let unreadable = |e| {
            host_error(
                e,
                PublicError::new(Code::TraceFileUnreadable, Stage::Preparing),
            )
        };
        let source =
            HeldFile::open_explicit_source(&resources.self_test_trace).map_err(unreadable)?;
        if source.facts(budget).map_err(unreadable)?.sha256
            != crate::resources::SELF_TEST_TRACE_SHA256
        {
            return Err(PublicError::new(
                Code::TraceFileUnreadable,
                Stage::Preparing,
            ));
        }
        let (session, engine_budget) =
            open_session(&source, SourceFormat::Htrace, resources, budget)?;
        let limits = invocation.presentation.limits;
        let summary = session
            .summary_facts(
                &arktrace_contract::TraceSummaryQuery {
                    range: None,
                    maximum_rows_per_section: limits.max_rows,
                    maximum_events_per_section: limits.max_events,
                },
                &engine_budget,
            )
            .map_err(|e| e.public_error());
        let consistent =
            session.metadata().schema_fingerprint == session.inspection().schema_fingerprint;
        let closed = session.close().map_err(|e| e.public_error());
        summary?;
        closed?;
        if !consistent {
            return Err(PublicError::new(
                Code::TraceDatabaseInvalid,
                Stage::Querying,
            ));
        }
        Ok(())
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
                let help = HELP.as_bytes().to_vec();
                #[cfg(windows)]
                let help = [
                    help,
                    b"\nWindows attribution: arktrace licenses [--json|--pretty]\n".to_vec(),
                ]
                .concat();
                return Ok(help);
            }
            if invocation.command == Command::Version {
                return Ok(format!("arktrace {}\n", env!("CARGO_PKG_VERSION")).into_bytes());
            }
            let current = MappedExecutable::current()
                .map_err(|_| PublicError::new(Code::InternalError, Stage::Request))?;
            tool = Some(identify(&current, &budget)?);
            image = Some(current);
            if let Command::Doctor { self_test } = invocation.command {
                return doctor(
                    invocation,
                    image.as_ref().unwrap(),
                    tool.as_ref().unwrap(),
                    &budget,
                    self_test,
                );
            }
            #[cfg(windows)]
            if invocation.command == Command::Licenses {
                return licenses(
                    invocation,
                    image.as_ref().unwrap(),
                    tool.as_ref().unwrap(),
                    &budget,
                );
            }
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
    #[cfg(any(target_os = "macos", windows))]
    {
        macos::run(arguments)
    }
    #[cfg(not(any(target_os = "macos", windows)))]
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
