use crate::{CommandError, CommandLimits, EventQuery};
use arktrace_contract::{
    CounterQuery, CpuSliceQuery, DirectoryNameMatch, ProcessQuery, ThreadQuery, ThreadStateQuery,
    TraceSliceQuery, TraceThreadState, TraceTimeRange,
};
use std::{collections::BTreeSet, ffi::OsString, path::PathBuf};

pub const MAXIMUM_ARGUMENTS: usize = 256;
pub const MAXIMUM_ARGUMENT_BYTES: usize = 16 * 1024;
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Presentation {
    pub json: bool,
    pub pretty: bool,
    pub limits: CommandLimits,
}
impl Default for Presentation {
    fn default() -> Self {
        Self {
            json: false,
            pretty: false,
            limits: CommandLimits {
                timeout_ms: 30000,
                max_rows: 10000,
                max_events: 10000,
                max_output_bytes: 8388608,
            },
        }
    }
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Invocation {
    pub presentation: Presentation,
    pub parser_override: Option<PathBuf>,
    pub no_cache: bool,
    pub command: Command,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Command {
    Help,
    Version,
    Inspect { trace: PathBuf },
    Processes { trace: PathBuf, query: ProcessQuery },
    Threads { trace: PathBuf, query: ThreadQuery },
    Query { trace: PathBuf, query: EventQuery },
}
impl Command {
    pub fn name(&self) -> &'static str {
        match self {
            Self::Help => "help",
            Self::Version => "version",
            Self::Inspect { .. } => "inspect",
            Self::Processes { .. } => "processes",
            Self::Threads { .. } => "threads",
            Self::Query { .. } => "query",
        }
    }
}
pub fn hint(arguments: &[OsString]) -> Presentation {
    let mut result = Presentation::default();
    let mut index = 0;
    let bounded = &arguments[..arguments.len().min(MAXIMUM_ARGUMENTS + 1)];
    while index < bounded.len() {
        let Some(value) = bounded[index]
            .to_str()
            .filter(|v| v.len() <= MAXIMUM_ARGUMENT_BYTES)
        else {
            index += 1;
            continue;
        };
        if value == "--" {
            break;
        }
        match value {
            "--json" => result.json = true,
            "--pretty" => result.pretty = true,
            "--timeout-ms" | "--max-output-bytes" => {
                if let Some(next) = bounded
                    .get(index + 1)
                    .and_then(|v| v.to_str())
                    .filter(|v| v.len() <= MAXIMUM_ARGUMENT_BYTES)
                    .and_then(|v| v.parse::<usize>().ok())
                {
                    if value == "--timeout-ms" && (100..=120000).contains(&next) {
                        result.limits.timeout_ms = next as u64;
                        index += 1;
                    }
                    if value == "--max-output-bytes" && (1024..=67108864).contains(&next) {
                        result.limits.max_output_bytes = next;
                        index += 1;
                    }
                }
            }
            _ => {}
        }
        index += 1;
    }
    result.pretty &= result.json;
    result
}
pub fn command_hint(arguments: &[OsString]) -> &'static str {
    arguments
        .iter()
        .take(MAXIMUM_ARGUMENTS + 1)
        .filter_map(|v| v.to_str())
        .filter(|v| v.len() <= MAXIMUM_ARGUMENT_BYTES)
        .find_map(|v| match v {
            "doctor" => Some("doctor"),
            "inspect" => Some("inspect"),
            "summary" => Some("summary"),
            "processes" => Some("processes"),
            "threads" => Some("threads"),
            "licenses" => Some("licenses"),
            "query" => Some("query"),
            "context" => Some("context"),
            "analyze" => Some("analyze"),
            _ => None,
        })
        .unwrap_or("unknown")
}
fn invalid<T>() -> Result<T, CommandError> {
    Err(CommandError::InvalidArguments)
}
fn once(seen: &mut BTreeSet<String>, option: &str) -> Result<(), CommandError> {
    if !seen.insert(option.to_owned()) {
        return invalid();
    }
    Ok(())
}
fn value<'a>(args: &[&'a str], index: &mut usize) -> Result<&'a str, CommandError> {
    *index += 1;
    let next = args
        .get(*index)
        .copied()
        .ok_or(CommandError::InvalidArguments)?;
    if next.starts_with("--") {
        return invalid();
    }
    Ok(next)
}
fn number(args: &[&str], index: &mut usize) -> Result<i64, CommandError> {
    value(args, index)?
        .parse()
        .map_err(|_| CommandError::InvalidArguments)
}
pub fn parse(arguments: &[OsString]) -> Result<Invocation, CommandError> {
    if arguments.len() > MAXIMUM_ARGUMENTS {
        return invalid();
    }
    let args = arguments
        .iter()
        .map(|v| {
            v.to_str()
                .filter(|v| v.len() <= MAXIMUM_ARGUMENT_BYTES)
                .ok_or(CommandError::InvalidArguments)
        })
        .collect::<Result<Vec<_>, _>>()?;
    let (mut presentation, mut no_cache, mut parser_override) =
        (Presentation::default(), false, None);
    let (mut help, mut version, mut terminated) = (false, false, false);
    let (mut seen, mut remaining, mut index) = (BTreeSet::new(), Vec::new(), 0);
    while index < args.len() {
        let token = args[index];
        if terminated {
            remaining.push(token);
            index += 1;
            continue;
        }
        if token == "--" {
            terminated = true;
            remaining.push(token);
            index += 1;
            continue;
        }
        let option = if token == "-h" { "--help" } else { token };
        match option {
            "--help" | "--version" | "--json" | "--pretty" | "--no-cache" => {
                once(&mut seen, option)?;
                match option {
                    "--help" => help = true,
                    "--version" => version = true,
                    "--json" => presentation.json = true,
                    "--pretty" => presentation.pretty = true,
                    _ => no_cache = true,
                }
            }
            "--timeout-ms" | "--max-rows" | "--max-events" | "--max-output-bytes" => {
                once(&mut seen, option)?;
                let n = number(&args, &mut index)?;
                if n < 0 {
                    return invalid();
                }
                match option {
                    "--timeout-ms" => presentation.limits.timeout_ms = n as u64,
                    "--max-rows" => presentation.limits.max_rows = n as usize,
                    "--max-events" => presentation.limits.max_events = n as usize,
                    _ => presentation.limits.max_output_bytes = n as usize,
                }
            }
            "--trace-streamer" => {
                once(&mut seen, option)?;
                let path = value(&args, &mut index)?;
                if path.len() > 4096 || !std::path::Path::new(path).is_absolute() {
                    return invalid();
                }
                parser_override = Some(PathBuf::from(path));
            }
            _ => {
                if remaining.is_empty() && token.starts_with('-') {
                    return invalid();
                }
                remaining.push(token);
            }
        }
        index += 1;
    }
    presentation.limits.validate()?;
    if help && version || presentation.pretty && !presentation.json {
        return invalid();
    }
    let command = if help || version {
        for token in &remaining {
            if *token == "--" {
                break;
            }
            if token.starts_with('-') {
                return invalid();
            }
        }
        if help {
            Command::Help
        } else {
            Command::Version
        }
    } else {
        let mut local_terminated = remaining.first() == Some(&"--");
        if local_terminated {
            remaining.remove(0);
        }
        let name = remaining
            .first()
            .copied()
            .ok_or(CommandError::InvalidArguments)?;
        if !["inspect", "processes", "threads", "query"].contains(&name) {
            return invalid();
        }
        let tail = &remaining[1..];
        let (mut seen, mut positionals, mut index) = (BTreeSet::new(), Vec::new(), 0);
        let (mut process_key, mut pid, mut thread_key, mut tid, mut text) =
            (None, None, None, None, None);
        let maximum = if name == "query" {
            presentation
                .limits
                .max_rows
                .min(presentation.limits.max_events)
        } else {
            presentation.limits.max_rows
        };
        let mut limit = maximum;
        let (mut view, mut start, mut end, mut cpu, mut raw_state, mut normalized_state) =
            (None, None, None, None, None, None);
        let (mut name_match, mut minimum_duration, mut depth) =
            (DirectoryNameMatch::Exact, None, None);
        let mut counter_filter_id = None;
        while index < tail.len() {
            let token = tail[index];
            if token == "--" && !local_terminated {
                local_terminated = true;
            } else if token.starts_with("--") && !local_terminated {
                once(&mut seen, token)?;
                if name == "inspect" {
                    return invalid();
                }
                match token {
                    "--pid" | "--tid" | "--process-key" | "--thread-key" => {
                        if name == "processes" && token != "--pid" {
                            return invalid();
                        }
                        let n = number(tail, &mut index)?;
                        if (["--pid", "--tid"].contains(&token) && n < 0)
                            || (["--process-key", "--thread-key"].contains(&token) && n == 0)
                        {
                            return invalid();
                        }
                        match token {
                            "--pid" => pid = Some(n),
                            "--tid" => tid = Some(n),
                            "--process-key" => process_key = Some(n),
                            _ => thread_key = Some(n),
                        }
                    }
                    "--name" => {
                        let filter_name = value(tail, &mut index)?;
                        if filter_name.is_empty()
                            || filter_name.len() > if name == "query" { 256 } else { 4096 }
                        {
                            return invalid();
                        }
                        text = Some(filter_name.to_owned());
                    }
                    "--limit" => {
                        let n = number(tail, &mut index)?;
                        if n < 1 || n as u64 > maximum as u64 {
                            return invalid();
                        }
                        limit = n as usize;
                    }
                    "--view" if name == "query" => {
                        view = Some(match value(tail, &mut index)? {
                            "cpu-slices" => "cpu-slices",
                            "thread-states" => "thread-states",
                            "slices" => "slices",
                            "counters" => "counters",
                            _ => return invalid(),
                        });
                    }
                    "--start-ns" | "--end-ns" | "--cpu" if name == "query" => {
                        let n = number(tail, &mut index)?;
                        if n < 0 {
                            return invalid();
                        }
                        match token {
                            "--start-ns" => start = Some(n),
                            "--end-ns" => end = Some(n),
                            _ => cpu = Some(n),
                        }
                    }
                    "--filter-id" if name == "query" => {
                        counter_filter_id = Some(number(tail, &mut index)?);
                    }
                    "--raw-state" if name == "query" => {
                        let text = value(tail, &mut index)?;
                        if text.is_empty() || text.len() > 256 {
                            return invalid();
                        }
                        raw_state = Some(text.to_owned());
                    }
                    "--state" if name == "query" => {
                        normalized_state = Some(match value(tail, &mut index)? {
                            "running" => TraceThreadState::Running,
                            "runnable" => TraceThreadState::Runnable,
                            "sleeping" => TraceThreadState::Sleeping,
                            "blocked" => TraceThreadState::Blocked,
                            "stopped" => TraceThreadState::Stopped,
                            _ => return invalid(),
                        });
                    }
                    "--name-match" if name == "query" => {
                        name_match = match value(tail, &mut index)? {
                            "exact" => DirectoryNameMatch::Exact,
                            "prefix" => DirectoryNameMatch::Prefix,
                            "contains" => DirectoryNameMatch::Contains,
                            _ => return invalid(),
                        };
                    }
                    "--min-duration-ns" | "--depth" if name == "query" => {
                        let n = number(tail, &mut index)?;
                        if n < 0 {
                            return invalid();
                        }
                        if token == "--depth" {
                            depth = Some(n);
                        } else {
                            minimum_duration = Some(n);
                        }
                    }
                    _ => return invalid(),
                }
            } else {
                positionals.push(token);
            }
            index += 1;
        }
        if positionals.len() != 1
            || positionals[0].is_empty()
            || process_key.is_some() && pid.is_some()
            || thread_key.is_some() && tid.is_some()
        {
            return invalid();
        }
        let trace = PathBuf::from(positionals[0]);
        match name {
            "inspect" => Command::Inspect { trace },
            "processes" => Command::Processes {
                trace,
                query: ProcessQuery {
                    process_key: None,
                    pid,
                    name: text,
                    name_match: DirectoryNameMatch::Exact,
                    limit,
                },
            },
            "threads" => Command::Threads {
                trace,
                query: ThreadQuery {
                    process_key,
                    pid,
                    thread_key,
                    tid,
                    name: text,
                    name_match: DirectoryNameMatch::Exact,
                    limit,
                },
            },
            _ => {
                if text.is_none() && name_match != DirectoryNameMatch::Exact {
                    return invalid();
                }
                let range = TraceTimeRange::query(
                    start.ok_or(CommandError::InvalidArguments)?,
                    end.ok_or(CommandError::InvalidArguments)?,
                )
                .map_err(|_| CommandError::InvalidArguments)?;
                let selected_view = view.ok_or(CommandError::InvalidArguments)?;
                if selected_view != "counters" && counter_filter_id.is_some() {
                    return invalid();
                }
                let query = match selected_view {
                    "cpu-slices" => {
                        if raw_state.is_some()
                            || normalized_state.is_some()
                            || text.is_some()
                            || minimum_duration.is_some()
                            || depth.is_some()
                        {
                            return invalid();
                        }
                        EventQuery::CpuSlices(CpuSliceQuery {
                            range,
                            cpu,
                            process_key,
                            pid,
                            thread_key,
                            tid,
                            limit,
                        })
                    }
                    "thread-states" => {
                        if text.is_some() || minimum_duration.is_some() || depth.is_some() {
                            return invalid();
                        }
                        EventQuery::ThreadStates(ThreadStateQuery {
                            range,
                            cpu,
                            process_key,
                            pid,
                            thread_key,
                            tid,
                            raw_state,
                            state: normalized_state,
                            limit,
                        })
                    }
                    "counters" => {
                        if thread_key.is_some()
                            || tid.is_some()
                            || raw_state.is_some()
                            || normalized_state.is_some()
                            || minimum_duration.is_some()
                            || depth.is_some()
                            || (cpu.is_some() && (process_key.is_some() || pid.is_some()))
                        {
                            return invalid();
                        }
                        EventQuery::Counters(CounterQuery {
                            range,
                            filter_id: counter_filter_id,
                            cpu,
                            process_key,
                            pid,
                            name: text,
                            name_match,
                            limit,
                        })
                    }
                    _ => {
                        if cpu.is_some() || raw_state.is_some() || normalized_state.is_some() {
                            return invalid();
                        }
                        EventQuery::Slices(TraceSliceQuery {
                            range,
                            event_key: None,
                            process_key,
                            pid,
                            thread_key,
                            tid,
                            name: text,
                            name_match,
                            minimum_duration_ns: minimum_duration,
                            depth,
                            includes_argument_set: false,
                            limit,
                        })
                    }
                };
                Command::Query { trace, query }
            }
        }
    };
    Ok(Invocation {
        presentation,
        parser_override,
        no_cache,
        command,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn args(values: &[&str]) -> Vec<OsString> {
        values.iter().map(OsString::from).collect()
    }
    #[test]
    fn counter_filters_keep_signed_filter_ids_and_one_scope() {
        let base = [
            "query",
            "空 格.htrace",
            "--view",
            "counters",
            "--start-ns",
            "0",
            "--end-ns",
            "10",
        ];
        for id in ["0", "-1", "-9223372036854775808", "9223372036854775807"] {
            let mut values = args(&base);
            values.extend(args(&[
                "--filter-id",
                id,
                "--name",
                "%_\\中文",
                "--name-match",
                "contains",
            ]));
            let invocation = parse(&values).unwrap();
            let Command::Query {
                query: EventQuery::Counters(q),
                ..
            } = invocation.command
            else {
                panic!("counter query required")
            };
            assert_eq!(q.filter_id, Some(id.parse().unwrap()));
            assert_eq!(q.name_match, DirectoryNameMatch::Contains);
        }
        for suffix in [
            vec!["--cpu", "0", "--process-key", "1"],
            vec!["--cpu", "0", "--pid", "1"],
            vec!["--thread-key", "1"],
            vec!["--tid", "1"],
            vec!["--depth", "0"],
            vec!["--min-duration-ns", "0"],
            vec!["--raw-state", "R"],
            vec!["--state", "running"],
            vec!["--filter-id", "9223372036854775808"],
            vec!["--filter-id", "1", "--filter-id", "1"],
            vec!["--name-match", "prefix"],
        ] {
            let mut values = args(&base);
            values.extend(args(&suffix));
            assert!(parse(&values).is_err(), "{suffix:?}");
        }
        for view in ["slices", "cpu-slices", "thread-states"] {
            assert!(
                parse(&args(&[
                    "query",
                    "a",
                    "--view",
                    view,
                    "--start-ns",
                    "0",
                    "--end-ns",
                    "10",
                    "--filter-id",
                    "0"
                ]))
                .is_err()
            );
        }
    }
    #[test]
    fn named_query_filters_obey_agent_utf8_and_closed_view_contracts() {
        let base = [
            "query",
            "空 格.htrace",
            "--view",
            "slices",
            "--start-ns",
            "0",
            "--end-ns",
            "10",
        ];
        let mut values = args(&base);
        let name = "é".repeat(128);
        values.extend(args(&[
            "--name",
            &name,
            "--name-match",
            "contains",
            "--min-duration-ns",
            "9223372036854775807",
            "--depth",
            "0",
            "--process-key",
            "-10",
        ]));
        let Command::Query {
            query: EventQuery::Slices(q),
            ..
        } = parse(&values).unwrap().command
        else {
            panic!("named query");
        };
        assert_eq!(q.name.as_ref().unwrap().len(), 256);
        assert_eq!(q.minimum_duration_ns, Some(i64::MAX));
        assert_eq!(q.name_match, DirectoryNameMatch::Contains);
        assert_eq!(q.process_key, Some(-10));
        assert_eq!(q.depth, Some(0));
        assert!(!q.includes_argument_set && q.event_key.is_none());
        for extra in [
            vec!["--cpu", "0"],
            vec!["--state", "running"],
            vec!["--raw-state", "R"],
            vec!["--min-duration-ns", "-1"],
            vec!["--depth", "-1"],
            vec!["--name", ""],
            vec!["--name-match", "prefix"],
            vec!["--name", "a", "--name-match", "regex"],
            vec!["--name", "a", "--name", "a"],
            vec!["--includes-argument-set"],
        ] {
            let mut values = args(&base);
            values.extend(args(&extra));
            assert_eq!(
                parse(&values),
                Err(CommandError::InvalidArguments),
                "{extra:?}"
            );
        }
        let mut values = args(&base);
        values.extend(args(&["--name", &format!("{name}a")]));
        assert_eq!(parse(&values), Err(CommandError::InvalidArguments));
        let mut directory = args(&["processes", "a", "--name"]);
        directory.push("é".repeat(2048).into());
        parse(&directory).unwrap();
    }
    #[test]
    fn global_options_anywhere_and_terminator_preserve_literal_operands() {
        let invocation = parse(&args(&[
            "threads",
            "空 格.htrace",
            "--json",
            "--max-rows",
            "12",
            "--limit",
            "9",
            "--process-key",
            "7",
            "--tid",
            "0",
            "--no-cache",
        ]))
        .unwrap();
        assert!(invocation.presentation.json && invocation.no_cache);
        assert_eq!(invocation.presentation.limits.max_rows, 12);
        let Command::Threads { query, .. } = invocation.command else {
            panic!("thread command")
        };
        assert_eq!(
            (query.process_key, query.tid, query.limit),
            (Some(7), Some(0), 9)
        );
        let invocation = parse(&args(&["--json", "inspect", "--", "--json"])).unwrap();
        assert_eq!(
            invocation.command,
            Command::Inspect {
                trace: PathBuf::from("--json")
            }
        );
        assert!(parse(&args(&["--", "inspect", "--json", "operand"])).is_err());
    }
    #[test]
    fn duplicates_conflicts_bounds_and_missing_values_are_usage_errors() {
        for values in [
            vec!["inspect", "a", "--json", "--json"],
            vec!["--help", "--version"],
            vec!["--pretty", "inspect", "a"],
            vec!["processes", "a", "--pid", "-1"],
            vec!["threads", "a", "--process-key", "0"],
            vec!["threads", "a", "--pid", "1", "--process-key", "2"],
            vec!["processes", "a", "--max-rows", "2", "--limit", "3"],
            vec!["inspect", "a", "--timeout-ms", "99"],
            vec!["inspect", "a", "--max-events", "100001"],
            vec!["processes", "a", "--name", ""],
            vec!["inspect", "a", "--trace-streamer", "relative"],
            vec!["inspect", "a", "--json=value"],
            vec!["processes", "a", "--pid", "--json"],
            vec!["inspect", "a", "b"],
        ] {
            assert_eq!(
                parse(&args(&values)),
                Err(CommandError::InvalidArguments),
                "{values:?}"
            );
        }
    }
    #[test]
    fn presentation_hint_is_bounded_and_never_reparses_after_terminator() {
        let values = args(&[
            "--json",
            "--timeout-ms",
            "400",
            "inspect",
            "--",
            "--pretty",
            "--max-output-bytes",
            "1024",
        ]);
        let p = hint(&values);
        assert!(p.json && !p.pretty);
        assert_eq!(p.limits.timeout_ms, 400);
        assert_eq!(p.limits.max_output_bytes, 8388608);
        let mut values = vec![OsString::from("argument"); MAXIMUM_ARGUMENTS + 1];
        values.push("--json".into());
        assert!(!hint(&values).json);
        assert_eq!(parse(&values), Err(CommandError::InvalidArguments));
    }
    #[test]
    fn query_uses_both_row_budgets_and_preserves_relative_time_and_internal_keys() {
        let values = args(&[
            "query",
            "空 格.systrace",
            "--view",
            "cpu-slices",
            "--start-ns",
            "9007199254740993",
            "--end-ns",
            "9223372036854775807",
            "--process-key",
            "-10",
            "--thread-key",
            "-11",
            "--cpu",
            "0",
            "--max-rows",
            "10",
            "--max-events",
            "3",
            "--json",
            "--no-cache",
        ]);
        let invocation = parse(&values).unwrap();
        let Command::Query {
            query: EventQuery::CpuSlices(query),
            ..
        } = invocation.command
        else {
            panic!("CPU query")
        };
        assert_eq!(query.range.start_ns(), 9_007_199_254_740_993);
        assert_eq!(query.range.end_ns(), i64::MAX);
        assert_eq!(
            (query.limit, query.process_key, query.thread_key, query.cpu),
            (3, Some(-10), Some(-11), Some(0))
        );
        let invocation = parse(&args(&[
            "--json",
            "--no-cache",
            "query",
            "--view",
            "thread-states",
            "--start-ns",
            "0",
            "--end-ns",
            "10",
            "--raw-state",
            "R+",
            "--state",
            "runnable",
            "--",
            "--json.htrace",
        ]))
        .unwrap();
        let Command::Query {
            trace,
            query: EventQuery::ThreadStates(query),
        } = invocation.command
        else {
            panic!("state query")
        };
        assert_eq!(trace, PathBuf::from("--json.htrace"));
        assert_eq!(query.raw_state.as_deref(), Some("R+"));
        assert_eq!(query.state, Some(TraceThreadState::Runnable));
    }
    #[test]
    fn query_rejects_missing_fields_inapplicable_filters_and_budget_bypasses() {
        let base = [
            "query",
            "a",
            "--view",
            "cpu-slices",
            "--start-ns",
            "0",
            "--end-ns",
            "10",
        ];
        for extra in [
            vec!["--view", "cpu-slices"],
            vec!["--state", "running"],
            vec!["--raw-state", "R"],
            vec!["--name", "name"],
            vec!["--cpu", "-1"],
            vec!["--process-key", "0"],
            vec!["--pid", "1", "--process-key", "2"],
            vec!["--thread-key", "1", "--tid", "2"],
            vec!["--max-rows", "10", "--max-events", "1", "--limit", "2"],
            vec!["--max-rows", "1", "--max-events", "10", "--limit", "2"],
            vec!["--start-ns", "1"],
        ] {
            let mut values = args(&base);
            values.extend(args(&extra));
            assert_eq!(
                parse(&values),
                Err(CommandError::InvalidArguments),
                "{extra:?}"
            );
        }
        for values in [
            vec!["query", "a", "--start-ns", "0", "--end-ns", "10"],
            vec!["query", "a", "--view", "cpu-slices", "--start-ns", "0"],
            vec![
                "query",
                "a",
                "--view",
                "cpu-slices",
                "--start-ns",
                "1",
                "--end-ns",
                "1",
            ],
            vec![
                "query",
                "a",
                "--view",
                "cpu-slices",
                "--start-ns",
                "-1",
                "--end-ns",
                "1",
            ],
            vec![
                "query",
                "a",
                "--view",
                "cpu-slices",
                "--start-ns",
                "0",
                "--end-ns",
                "9223372036854775808",
            ],
            vec![
                "query",
                "a",
                "--view",
                "thread-states",
                "--start-ns",
                "0",
                "--end-ns",
                "1",
                "--raw-state",
                "",
            ],
            vec![
                "query",
                "a",
                "--view",
                "thread-states",
                "--start-ns",
                "0",
                "--end-ns",
                "1",
                "--state",
                "unknown",
            ],
        ] {
            assert_eq!(
                parse(&args(&values)),
                Err(CommandError::InvalidArguments),
                "{values:?}"
            );
        }
        let mut values = args(&[
            "query",
            "a",
            "--view",
            "thread-states",
            "--start-ns",
            "0",
            "--end-ns",
            "1",
            "--raw-state",
        ]);
        values.push("界".repeat(86).into());
        assert_eq!(parse(&values), Err(CommandError::InvalidArguments));
    }
}
