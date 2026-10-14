#[cfg(any(target_os = "macos", windows, test))]
use arktrace_platform::CancellationToken;
use serde::Serialize;
#[cfg(any(target_os = "macos", windows, test))]
use std::{
    io::{self, Write},
    time::Instant,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub enum CommandError {
    InvalidArguments,
    InvalidMachineValue,
    OutputLimitExceeded,
    Cancelled,
    DeadlineExceeded,
    #[cfg(any(target_os = "macos", windows))]
    Engine(arktrace_engine::EngineError),
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OutputFormat {
    Machine { pretty: bool },
    Human,
}
impl std::fmt::Display for CommandError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for CommandError {}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandLimits {
    pub timeout_ms: u64,
    pub max_rows: usize,
    pub max_events: usize,
    pub max_output_bytes: usize,
}
impl CommandLimits {
    pub fn validate(&self) -> Result<(), CommandError> {
        if !(100..=120_000).contains(&self.timeout_ms)
            || !(1..=100_000).contains(&self.max_rows)
            || !(1..=100_000).contains(&self.max_events)
            || !(1024..=67_108_864).contains(&self.max_output_bytes)
        {
            return Err(CommandError::InvalidArguments);
        }
        Ok(())
    }
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolIdentity {
    name: &'static str,
    version: &'static str,
    build_revision: String,
}
fn digest(value: &str, length: usize) -> bool {
    value.len() == length
        && value
            .bytes()
            .all(|v| v.is_ascii_digit() || (b'a'..=b'f').contains(&v))
}
impl ToolIdentity {
    /// The composition caller must obtain this digest from its verified
    /// executable. Git revision and the old Swift artifact are not substitutes.
    pub fn from_executable_sha256(build_revision: String) -> Result<Self, CommandError> {
        if !digest(&build_revision, 64) {
            return Err(CommandError::InvalidMachineValue);
        }
        Ok(Self {
            name: "arktrace",
            version: env!("CARGO_PKG_VERSION"),
            build_revision,
        })
    }
}
#[cfg(any(target_os = "macos", windows, test))]
struct BoundedWriter<'a> {
    bytes: Vec<u8>,
    maximum: usize,
    deadline: Instant,
    cancellation: &'a CancellationToken,
    failure: Option<CommandError>,
}
#[cfg(any(target_os = "macos", windows, test))]
impl Write for BoundedWriter<'_> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        let error = if self.cancellation.is_cancelled() {
            Some(CommandError::Cancelled)
        } else if Instant::now() >= self.deadline {
            Some(CommandError::DeadlineExceeded)
        } else if bytes.len() > self.maximum.saturating_sub(self.bytes.len()) {
            Some(CommandError::OutputLimitExceeded)
        } else {
            None
        };
        if let Some(error) = error {
            self.failure = Some(error);
            return Err(io::Error::other("bounded machine output"));
        }
        self.bytes.extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
#[cfg(test)]
fn encode(
    value: &impl Serialize,
    maximum: usize,
    deadline: Instant,
    cancellation: &CancellationToken,
) -> Result<Vec<u8>, CommandError> {
    encode_formatted(value, maximum, deadline, cancellation, false)
}
#[cfg(any(target_os = "macos", windows, test))]
pub(crate) fn encode_formatted(
    value: &impl Serialize,
    maximum: usize,
    deadline: Instant,
    cancellation: &CancellationToken,
    pretty: bool,
) -> Result<Vec<u8>, CommandError> {
    let mut writer = BoundedWriter {
        bytes: Vec::new(),
        maximum,
        deadline,
        cancellation,
        failure: None,
    };
    let outcome = if pretty {
        serde_json::to_writer_pretty(&mut writer, value)
    } else {
        serde_json::to_writer(&mut writer, value)
    };
    if outcome.is_err() {
        return Err(writer.failure.unwrap_or(CommandError::InvalidMachineValue));
    }
    writer
        .write_all(b"\n")
        .map_err(|_| writer.failure.unwrap_or(CommandError::InvalidMachineValue))?;
    Ok(writer.bytes)
}

#[cfg(any(target_os = "macos", windows))]
mod macos {
    use super::*;
    use arktrace_contract::{
        CounterScope, CpuSlice, DataQuality, DirectoryNameMatch, DirectoryPage, EventKey,
        EventPage, EventTable, ProcessQuery, QualityCategory, QualityStatus, ThreadQuery,
        ThreadStateInterval, TraceAgentCounterEvent, TraceCapabilities, TraceProcess, TraceSlice,
        TraceThread, TraceTimeRange,
    };
    use arktrace_engine::{EngineBudget, NoCacheSession};
    use std::collections::{BTreeMap, BTreeSet};

    pub enum DirectoryCommand {
        Inspect,
        Summary(Option<TraceTimeRange>),
        Processes(ProcessQuery),
        Threads(ThreadQuery),
        Query(crate::EventQuery),
        Context {
            time: arktrace_engine::ContextTime,
            filters: arktrace_engine::AgentFilters,
        },
        Analyze(crate::arguments::AnalyzeOptions),
    }
    /// Swift `CLIMachineSummaryResult`: the summary without its fingerprint,
    /// quality and truncated sections, which the envelope carries.
    #[derive(Serialize)]
    #[serde(rename_all = "camelCase")]
    struct SummaryResult<'a> {
        range: TraceTimeRange,
        duration_ns: i64,
        cpu_count: Option<i64>,
        process_count: i64,
        thread_count: i64,
        cpu_slice_count: Option<i64>,
        thread_state_count: Option<i64>,
        named_slice_count: Option<i64>,
        counter_series_count: Option<i64>,
        event_count_by_source: Option<Vec<arktrace_contract::TraceEventSourceCount>>,
        capabilities: &'a TraceCapabilities,
    }
    impl HumanResult for SummaryResult<'_> {
        fn human(
            &self,
            trace: &Trace<'_>,
            quality: &DataQuality,
            truncation: &Truncation,
            writer: &mut BoundedWriter<'_>,
        ) -> std::io::Result<()> {
            let count = |value: Option<i64>| {
                value
                    .map(|v| v.to_string())
                    .unwrap_or_else(|| "unavailable".to_owned())
            };
            writeln!(
                writer,
                "Trace SHA-256: {}\nRange ns: [{}, {})\nDuration ns: {}\nCPUs: {}\nProcesses: {}\nThreads: {}\nCPU slices: {}\nThread states: {}\nNamed slices: {}\nCounter series: {}\nData quality: {}",
                trace.sha256,
                self.range.start_ns(),
                self.range.end_ns(),
                self.duration_ns,
                count(self.cpu_count),
                self.process_count,
                self.thread_count,
                count(self.cpu_slice_count),
                count(self.thread_state_count),
                count(self.named_slice_count),
                count(self.counter_series_count),
                if quality.status == QualityStatus::Ok {
                    "ok"
                } else {
                    "warnings"
                },
            )?;
            if truncation.truncated {
                writeln!(writer, "Truncated: {}", truncation.sections.join(","))?;
            }
            Ok(())
        }
    }
    /// Swift `TraceSummaryEngine.summarize` plus the CLI summary contract
    /// checks: resolved range, fixed truncation section order, event sources
    /// stably ordered by UTF-8 bytes then count, and capability nullability.
    fn summary_result<'a>(
        session: &'a NoCacheSession,
        requested: Option<TraceTimeRange>,
        limits: CommandLimits,
        budget: &EngineBudget,
    ) -> Result<
        (
            SummaryResult<'a>,
            Vec<arktrace_contract::QualityIssue>,
            Vec<&'static str>,
        ),
        CommandError,
    > {
        let inspection = session.inspection();
        let duration = inspection.duration_ns;
        let range = match requested {
            Some(range) if range.end_ns() <= duration => range,
            Some(_) => return Err(CommandError::InvalidArguments),
            None => {
                TraceTimeRange::query(0, duration).map_err(|_| CommandError::InvalidMachineValue)?
            }
        };
        let facts = session
            .summary_facts(
                &arktrace_contract::TraceSummaryQuery {
                    range: requested,
                    maximum_rows_per_section: limits.max_rows,
                    maximum_events_per_section: limits.max_events,
                },
                budget,
            )
            .map_err(CommandError::Engine)?;
        check(budget)?;
        let mut sections = Vec::new();
        for (name, value) in [
            ("cpuCount", facts.cpu_count),
            ("processCount", Some(facts.process_count)),
            ("threadCount", Some(facts.thread_count)),
            ("cpuSliceCount", facts.cpu_slice_count),
            ("threadStateCount", facts.thread_state_count),
            ("namedSliceCount", facts.named_slice_count),
            ("counterSeriesCount", facts.counter_series_count),
        ] {
            if value.is_some_and(|v| v.truncated) {
                sections.push(name);
            }
        }
        if facts
            .event_count_by_source
            .as_ref()
            .is_some_and(|v| v.truncated)
        {
            sections.push("eventCountBySource");
        }
        let event_count_by_source = facts.event_count_by_source.map(|counts| {
            let mut items = counts.items;
            // Stable: equal sources keep repository order after count order.
            items.sort_by(|a, b| {
                a.source
                    .as_bytes()
                    .cmp(b.source.as_bytes())
                    .then(a.count.cmp(&b.count))
            });
            items
        });
        let c = &inspection.capabilities;
        let value = |v: Option<arktrace_contract::TraceBoundedCount>| v.map(|v| v.value);
        let result = SummaryResult {
            range,
            duration_ns: range.duration_ns(),
            cpu_count: value(facts.cpu_count),
            process_count: facts.process_count.value,
            thread_count: facts.thread_count.value,
            cpu_slice_count: value(facts.cpu_slice_count),
            thread_state_count: value(facts.thread_state_count),
            named_slice_count: value(facts.named_slice_count),
            counter_series_count: value(facts.counter_series_count),
            event_count_by_source,
            capabilities: c,
        };
        let counts = [
            result.cpu_count,
            result.cpu_slice_count,
            result.thread_state_count,
            result.named_slice_count,
            result.counter_series_count,
        ];
        let sources = result.event_count_by_source.as_deref().unwrap_or_default();
        if result.duration_ns < 0
            || result.process_count < 0
            || result.thread_count < 0
            || counts.iter().any(|v| v.is_some_and(|v| v < 0))
            || result.cpu_count.is_some() != c.cpu_scheduling
            || result.cpu_slice_count.is_some() != c.cpu_scheduling
            || result.thread_state_count.is_some() != c.thread_states
            || result.named_slice_count.is_some() != c.named_slices
            || result.counter_series_count.is_some() != (c.cpu_counters || c.process_counters)
            || result.process_count > limits.max_rows as i64
            || result.thread_count > limits.max_rows as i64
            || counts
                .iter()
                .flatten()
                .any(|v| *v > limits.max_events as i64)
            || sources.len() > limits.max_events
            || sources.iter().any(|v| v.count < 0 || v.source.len() > 1024)
            || sources
                .windows(2)
                .any(|pair| pair[0].source.as_bytes() >= pair[1].source.as_bytes())
        {
            return Err(CommandError::InvalidMachineValue);
        }
        sections.sort_unstable();
        Ok((result, facts.data_quality_issues, sections))
    }
    #[derive(Serialize)]
    #[serde(rename_all = "camelCase")]
    struct Trace<'a> {
        sha256: &'a str,
        byte_count: i64,
        duration_ns: i64,
        parser: Parser<'a>,
        schema_fingerprint: &'a str,
    }
    #[derive(Serialize)]
    #[serde(rename_all = "camelCase")]
    struct Parser<'a> {
        name: &'a str,
        version: &'a str,
        upstream_revision: &'a str,
        binary_sha256: &'a str,
    }
    #[derive(Serialize)]
    #[serde(rename_all = "camelCase")]
    struct Provenance<'a> {
        parser_adapter_version: &'a str,
        parser_build_recipe_version: &'a str,
        schema_adapter_version: &'a str,
        index_schema_version: u32,
        upstream_database_sha256: &'a str,
        upstream_database_byte_count: i64,
    }
    #[derive(Serialize)]
    struct Request<'a> {
        command: &'a str,
        parameters: BTreeMap<&'static str, serde_json::Value>,
    }
    #[derive(Serialize)]
    struct Truncation {
        truncated: bool,
        sections: Vec<&'static str>,
    }
    #[derive(Serialize)]
    #[serde(rename_all = "camelCase")]
    struct Envelope<'a, R: Serialize> {
        schema_version: &'static str,
        tool: &'a ToolIdentity,
        trace: Trace<'a>,
        request: Request<'a>,
        limits: CommandLimits,
        result: R,
        data_quality: DataQuality,
        truncation: Truncation,
        provenance: Provenance<'a>,
    }
    #[derive(Serialize)]
    #[serde(rename_all = "camelCase")]
    struct InspectResult<'a> {
        cache_hit: bool,
        capabilities: &'a TraceCapabilities,
        index_schema_version: u32,
    }
    #[derive(Serialize)]
    struct Items<T: Serialize> {
        items: Vec<T>,
    }
    #[derive(Serialize)]
    enum EventItems {
        #[serde(rename = "cpuSlices")]
        Cpu(Vec<CpuSlice>),
        #[serde(rename = "threadStates")]
        States(Vec<ThreadStateInterval>),
        #[serde(rename = "slices")]
        Slices(Vec<TraceSlice>),
        #[serde(rename = "counters")]
        Counters(Vec<TraceAgentCounterEvent>),
    }
    #[derive(Serialize)]
    #[serde(rename_all = "camelCase")]
    struct QueryResult {
        view: &'static str,
        range: TraceTimeRange,
        filters: BTreeMap<&'static str, serde_json::Value>,
        capability_available: bool,
        truncated: bool,
        data_quality: DataQuality,
        #[serde(flatten)]
        events: EventItems,
    }
    trait HumanResult: Serialize {
        fn human(
            &self,
            trace: &Trace<'_>,
            quality: &DataQuality,
            truncation: &Truncation,
            writer: &mut BoundedWriter<'_>,
        ) -> std::io::Result<()>;
    }
    fn terminal(value: &str) -> String {
        let mut output = String::new();
        for c in value.chars() {
            // Cc/Cf/Zl/Zp terminal controls. These ranges cover the Unicode
            // format controls accepted by current Swift terminalField.
            let format = matches!(c as u32,0x00ad|0x0600..=0x0605|0x061c|0x06dd|0x070f|0x0890..=0x0891|0x08e2|0x180e|0x200b..=0x200f|0x2028..=0x202e|0x2060..=0x2064|0x2066..=0x206f|0xfeff|0xfff9..=0xfffb|0x110bd|0x110cd|0x13430..=0x1343f|0x1bca0..=0x1bca3|0x1d173..=0x1d17a|0xe0001|0xe0020..=0xe007f);
            let component = if c.is_control() || format {
                format!("\\u{{{:X}}}", c as u32)
            } else {
                c.to_string()
            };
            if output.len() + component.len() > 4093 {
                output.push('…');
                break;
            }
            output.push_str(&component);
        }
        output
    }
    fn optional(value: Option<i64>) -> String {
        value
            .map(|v| v.to_string())
            .unwrap_or_else(|| "-".to_owned())
    }
    impl HumanResult for InspectResult<'_> {
        fn human(
            &self,
            trace: &Trace<'_>,
            quality: &DataQuality,
            _: &Truncation,
            writer: &mut BoundedWriter<'_>,
        ) -> std::io::Result<()> {
            let c = self.capabilities;
            let capabilities = [
                ("cpuScheduling", c.cpu_scheduling),
                ("threadStates", c.thread_states),
                ("namedSlices", c.named_slices),
                ("cpuCounters", c.cpu_counters),
                ("processCounters", c.process_counters),
            ]
            .into_iter()
            .filter_map(|(name, yes)| yes.then_some(name))
            .collect::<Vec<_>>()
            .join(",");
            writeln!(
                writer,
                "Trace SHA-256: {}\nBytes: {}\nDuration ns: {}\nParser: {} {}\nSchema: {}\nCapabilities: {}\nData quality: {}\nCache hit: {}",
                trace.sha256,
                trace.byte_count,
                trace.duration_ns,
                trace.parser.name,
                trace.parser.version,
                trace.schema_fingerprint,
                if capabilities.is_empty() {
                    "none"
                } else {
                    &capabilities
                },
                if quality.status == QualityStatus::Ok {
                    "ok"
                } else {
                    "warnings"
                },
                if self.cache_hit { "yes" } else { "no" }
            )
        }
    }
    impl HumanResult for Items<TraceProcess> {
        fn human(
            &self,
            _: &Trace<'_>,
            _: &DataQuality,
            truncation: &Truncation,
            writer: &mut BoundedWriter<'_>,
        ) -> std::io::Result<()> {
            writeln!(writer, "IPID\tPID\tNAME\tSTART_NS\tEND_NS\tTHREADS")?;
            for r in &self.items {
                writeln!(
                    writer,
                    "{}\t{}\t{}\t{}\t{}\t{}",
                    r.key,
                    r.pid,
                    r.name
                        .as_deref()
                        .map(terminal)
                        .unwrap_or_else(|| "-".to_owned()),
                    optional(r.start_ns),
                    optional(r.end_ns),
                    optional(r.thread_count)
                )?;
            }
            if truncation.truncated {
                writeln!(writer, "… processes truncated")?
            }
            Ok(())
        }
    }
    impl HumanResult for Items<TraceThread> {
        fn human(
            &self,
            _: &Trace<'_>,
            _: &DataQuality,
            truncation: &Truncation,
            writer: &mut BoundedWriter<'_>,
        ) -> std::io::Result<()> {
            writeln!(writer, "ITID\tIPID\tPID\tTID\tNAME\tSTART_NS\tEND_NS\tMAIN")?;
            for r in &self.items {
                writeln!(
                    writer,
                    "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
                    r.key,
                    optional(r.process_key),
                    optional(r.pid),
                    r.tid,
                    r.name
                        .as_deref()
                        .map(terminal)
                        .unwrap_or_else(|| "-".to_owned()),
                    optional(r.start_ns),
                    optional(r.end_ns),
                    r.is_main_thread
                        .map(|v| v.to_string())
                        .unwrap_or_else(|| "-".to_owned())
                )?;
            }
            if truncation.truncated {
                writeln!(writer, "… threads truncated")?
            }
            Ok(())
        }
    }
    impl HumanResult for QueryResult {
        fn human(
            &self,
            _: &Trace<'_>,
            _: &DataQuality,
            _: &Truncation,
            writer: &mut BoundedWriter<'_>,
        ) -> std::io::Result<()> {
            writeln!(writer, "View: {}", self.view)?;
            writeln!(
                writer,
                "Range ns: [{}, {})",
                self.range.start_ns(),
                self.range.end_ns()
            )?;
            writeln!(
                writer,
                "Capability available: {}",
                self.capability_available
            )?;
            match &self.events {
                EventItems::Cpu(items) => {
                    for r in items {
                        writeln!(
                            writer,
                            "{}\t{}\tcpu={}\tevent=sched_slice:{}",
                            r.range.start_ns(),
                            r.range.end_ns(),
                            r.cpu,
                            r.key.row_id
                        )?;
                    }
                }
                EventItems::States(items) => {
                    for r in items {
                        writeln!(
                            writer,
                            "{}\t{}\tstate={}\tevent=thread_state:{}",
                            r.range.start_ns(),
                            r.range.end_ns(),
                            terminal(&r.state),
                            r.key.row_id
                        )?;
                    }
                }
                EventItems::Counters(items) => {
                    for r in items {
                        writeln!(
                            writer,
                            "{}\tvalue={}\tname={}\tevent={}:{}",
                            r.sample.timestamp_ns,
                            r.sample.value,
                            terminal(&r.name),
                            if r.sample.key.table == EventTable::Measure {
                                "measure"
                            } else {
                                "process_measure"
                            },
                            r.sample.key.row_id
                        )?;
                    }
                }
                EventItems::Slices(items) => {
                    for r in items {
                        writeln!(
                            writer,
                            "{}\t{}\tname={}\tevent=callstack:{}",
                            r.range.start_ns(),
                            r.range.end_ns(),
                            terminal(&r.name),
                            r.key.row_id
                        )?;
                    }
                }
            }
            if self.truncated {
                writeln!(writer, "… result truncated")?;
            }
            Ok(())
        }
    }
    fn range(start: Option<i64>, end: Option<i64>, duration: i64) -> bool {
        start.is_none_or(|v| (0..=duration).contains(&v))
            && end.is_none_or(|v| (0..=duration).contains(&v))
            && match (start, end) {
                (Some(start), Some(end)) => start <= end,
                _ => true,
            }
    }
    fn name(value: Option<&str>) -> bool {
        value.is_none_or(|v| !v.is_empty() && v.len() <= 4096)
    }
    fn count<T>(
        page: &DirectoryPage<T>,
        requested: usize,
        global: usize,
    ) -> Result<(), CommandError> {
        if page.items.len() > requested
            || page.items.len() > global
            || (page.truncated && page.items.len() != requested)
        {
            return Err(CommandError::InvalidMachineValue);
        }
        Ok(())
    }
    fn validate_processes(
        page: &DirectoryPage<TraceProcess>,
        query: &ProcessQuery,
        duration: i64,
        budget: &EngineBudget,
    ) -> Result<(), CommandError> {
        let mut keys = BTreeSet::new();
        let mut previous = None;
        for row in &page.items {
            check(budget)?;
            let order = (row.pid, row.key);
            if !keys.insert(row.key)
                || previous.is_some_and(|p| order < p)
                || !name(row.name.as_deref())
                || !range(row.start_ns, row.end_ns, duration)
                || row.thread_count.is_some_and(|v| v < 0)
                || query.pid.is_some_and(|pid| row.pid != pid)
                || query
                    .name
                    .as_deref()
                    .is_some_and(|name| row.name.as_deref() != Some(name))
            {
                return Err(CommandError::InvalidMachineValue);
            }
            previous = Some(order);
        }
        Ok(())
    }
    fn validate_threads(
        page: &DirectoryPage<TraceThread>,
        query: &ThreadQuery,
        duration: i64,
        budget: &EngineBudget,
    ) -> Result<(), CommandError> {
        let mut keys = BTreeSet::new();
        let mut previous = None;
        for row in &page.items {
            check(budget)?;
            let order = (row.pid.is_none(), row.pid.unwrap_or(0), row.tid, row.key);
            if !keys.insert(row.key)
                || previous.is_some_and(|p| order < p)
                || !name(row.name.as_deref())
                || !name(row.process_name.as_deref())
                || !range(row.start_ns, row.end_ns, duration)
                || query
                    .process_key
                    .is_some_and(|key| row.process_key != Some(key))
                || query.pid.is_some_and(|pid| row.pid != Some(pid))
                || query.thread_key.is_some_and(|key| row.key != key)
                || query.tid.is_some_and(|tid| row.tid != tid)
                || query
                    .name
                    .as_deref()
                    .is_some_and(|name| row.name.as_deref() != Some(name))
            {
                return Err(CommandError::InvalidMachineValue);
            }
            previous = Some(order);
        }
        Ok(())
    }
    fn check(budget: &EngineBudget) -> Result<(), CommandError> {
        if budget.cancellation.is_cancelled() {
            Err(CommandError::Cancelled)
        } else if Instant::now() >= budget.deadline {
            Err(CommandError::DeadlineExceeded)
        } else {
            Ok(())
        }
    }
    fn event_count<T>(
        page: &EventPage<T>,
        query: &crate::EventQuery,
        limits: CommandLimits,
    ) -> Result<(), CommandError> {
        if query.limit() > limits.max_rows.min(limits.max_events)
            || page.items.len() > query.limit()
            || (!page.capability_available && (!page.items.is_empty() || page.truncated))
        {
            return Err(CommandError::InvalidMachineValue);
        }
        Ok(())
    }
    fn validate_events<T>(
        items: &[T],
        query: &crate::EventQuery,
        duration: i64,
        table: EventTable,
        budget: &EngineBudget,
        facts: impl Fn(&T) -> (EventKey, TraceTimeRange, bool),
        values: impl Fn(&T) -> bool,
    ) -> Result<(), CommandError> {
        let mut ids = BTreeSet::new();
        let mut previous = None;
        for row in items {
            check(budget)?;
            let (key, range, open) = facts(row);
            let order = (range.start_ns(), key.row_id);
            if key.table != table
                || !ids.insert(key.row_id)
                || previous.is_some_and(|p| order < p)
                || range.end_ns() > duration
                || (open && range.end_ns() != duration)
                || !range.intersects(query.range())
                || !values(row)
            {
                return Err(CommandError::InvalidMachineValue);
            }
            previous = Some(order);
        }
        Ok(())
    }
    fn event_text(value: Option<&str>, maximum: usize) -> bool {
        value.is_none_or(|text| text.len() <= maximum)
    }
    fn event_result(
        context: &CommandContext<'_>,
        query: &crate::EventQuery,
    ) -> Result<QueryResult, CommandError> {
        use crate::EventQuery;
        let limits = context.limits;
        if query.limit() > limits.max_rows.min(limits.max_events) {
            return Err(CommandError::InvalidArguments);
        }
        let (view, available, truncated, quality, events) = match query {
            EventQuery::CpuSlices(q) => {
                q.validate().map_err(|_| CommandError::InvalidArguments)?;
                if q.cpu.is_some_and(|v| v < 0)
                    || q.pid.is_some_and(|v| v < 0)
                    || q.tid.is_some_and(|v| v < 0)
                    || (q.process_key.is_some() && q.pid.is_some())
                    || (q.thread_key.is_some() && q.tid.is_some())
                {
                    return Err(CommandError::InvalidArguments);
                }
                let page = context
                    .session
                    .query_cpu_slices(q, context.budget)
                    .map_err(CommandError::Engine)?;
                event_count(&page, query, limits)?;
                validate_events(
                    &page.items,
                    query,
                    context.session.inspection().duration_ns,
                    EventTable::SchedSlice,
                    context.budget,
                    |r| (r.key, r.range, r.is_open_ended),
                    |r| {
                        r.thread_key.is_none_or(|k| k.itid != 0)
                            && r.process_key.is_none_or(|k| k.ipid != 0)
                            && event_text(r.thread_name.as_deref(), 4096)
                            && event_text(r.process_name.as_deref(), 4096)
                            && event_text(r.end_state.as_deref(), 256)
                            && q.cpu.is_none_or(|v| r.cpu == v)
                            && q.process_key
                                .is_none_or(|v| r.process_key.is_some_and(|k| k.ipid == v))
                            && q.thread_key
                                .is_none_or(|v| r.thread_key.is_some_and(|k| k.itid == v))
                            && q.pid.is_none_or(|v| r.pid == Some(v))
                            && q.tid.is_none_or(|v| r.tid == Some(v))
                    },
                )?;
                (
                    "cpuSlices",
                    page.capability_available,
                    page.truncated,
                    page.data_quality,
                    EventItems::Cpu(page.items),
                )
            }
            EventQuery::ThreadStates(q) => {
                q.validate().map_err(|_| CommandError::InvalidArguments)?;
                if q.cpu.is_some_and(|v| v < 0)
                    || q.pid.is_some_and(|v| v < 0)
                    || q.tid.is_some_and(|v| v < 0)
                    || (q.process_key.is_some() && q.pid.is_some())
                    || (q.thread_key.is_some() && q.tid.is_some())
                {
                    return Err(CommandError::InvalidArguments);
                }
                let page = context
                    .session
                    .query_thread_states(q, context.budget)
                    .map_err(CommandError::Engine)?;
                event_count(&page, query, limits)?;
                validate_events(
                    &page.items,
                    query,
                    context.session.inspection().duration_ns,
                    EventTable::ThreadState,
                    context.budget,
                    |r| (r.key, r.range, r.is_open_ended),
                    |r| {
                        r.thread_key.itid != 0
                            && r.process_key.is_none_or(|k| k.ipid != 0)
                            && event_text(r.thread_name.as_deref(), 4096)
                            && event_text(r.process_name.as_deref(), 4096)
                            && r.state.len() <= 256
                            && q.cpu.is_none_or(|v| r.cpu == Some(v))
                            && q.process_key
                                .is_none_or(|v| r.process_key.is_some_and(|k| k.ipid == v))
                            && q.thread_key.is_none_or(|v| r.thread_key.itid == v)
                            && q.pid.is_none_or(|v| r.pid == Some(v))
                            && q.tid.is_none_or(|v| r.tid == Some(v))
                            && q.raw_state.as_ref().is_none_or(|v| r.state == *v)
                            && q.state.is_none_or(|v| r.normalized_state == Some(v))
                    },
                )?;
                (
                    "threadStates",
                    page.capability_available,
                    page.truncated,
                    page.data_quality,
                    EventItems::States(page.items),
                )
            }
            EventQuery::Counters(q) => {
                q.validate().map_err(|_| CommandError::InvalidArguments)?;
                if q.cpu.is_some_and(|v| v < 0)
                    || q.pid.is_some_and(|v| v < 0)
                    || q.process_key == Some(0)
                    || (q.process_key.is_some() && q.pid.is_some())
                {
                    return Err(CommandError::InvalidArguments);
                }
                let page = context
                    .session
                    .query_counters(q, context.budget)
                    .map_err(CommandError::Engine)?;
                event_count(&page, query, limits)?;
                let mut seen = BTreeSet::new();
                let mut previous = None;
                let duration = context.session.inspection().duration_ns;
                for row in &page.items {
                    check(context.budget)?;
                    let sample = &row.sample;
                    let table = match sample.key.table {
                        EventTable::Measure => 0,
                        EventTable::ProcessMeasure => 1,
                        _ => return Err(CommandError::InvalidMachineValue),
                    };
                    let order = (sample.timestamp_ns, table, sample.key.row_id);
                    let end = sample.duration_ns.map_or(Some(duration), |d| {
                        if d < 0 {
                            None
                        } else {
                            sample.timestamp_ns.checked_add(d)
                        }
                    });
                    let sample_range =
                        end.and_then(|end| TraceTimeRange::event(sample.timestamp_ns, end).ok());
                    let scope = match row.scope {
                        CounterScope::Cpu => {
                            row.cpu.is_some()
                                && row.process_key.is_none()
                                && row.pid.is_none()
                                && row.process_name.is_none()
                                && sample.key.table == EventTable::Measure
                        }
                        CounterScope::Process => {
                            row.cpu.is_none() && row.process_key.is_none_or(|k| k.ipid != 0)
                        }
                    };
                    if !seen.insert((table, sample.key.row_id))
                        || previous.is_some_and(|p| order < p)
                        || !scope
                        || sample_range
                            .is_none_or(|r| r.end_ns() > duration || !r.intersects(query.range()))
                        || row.name.len() > 256
                        || !event_text(row.unit.as_deref(), 256)
                        || !event_text(row.process_name.as_deref(), 4096)
                        || q.filter_id.is_some_and(|v| row.filter_id != v)
                        || q.cpu.is_some_and(|v| row.cpu != Some(v))
                        || q.process_key
                            .is_some_and(|v| row.process_key.is_none_or(|k| k.ipid != v))
                        || q.pid.is_some_and(|v| row.pid != Some(v))
                        || (q.name_match == DirectoryNameMatch::Exact
                            && q.name.as_ref().is_some_and(|n| row.name != *n))
                    {
                        return Err(CommandError::InvalidMachineValue);
                    }
                    previous = Some(order);
                }
                (
                    "counters",
                    page.capability_available,
                    page.truncated,
                    page.data_quality,
                    EventItems::Counters(page.items),
                )
            }
            EventQuery::Slices(q) => {
                q.validate().map_err(|_| CommandError::InvalidArguments)?;
                if q.event_key.is_some()
                    || q.includes_argument_set
                    || q.name
                        .as_ref()
                        .is_some_and(|n| n.is_empty() || n.len() > 256)
                    || (q.name.is_none() && q.name_match != DirectoryNameMatch::Exact)
                    || q.pid.is_some_and(|v| v < 0)
                    || q.tid.is_some_and(|v| v < 0)
                    || (q.process_key.is_some() && q.pid.is_some())
                    || (q.thread_key.is_some() && q.tid.is_some())
                {
                    return Err(CommandError::InvalidArguments);
                }
                let page = context
                    .session
                    .query_slices(q, context.budget)
                    .map_err(CommandError::Engine)?;
                event_count(&page, query, limits)?;
                validate_events(
                    &page.items,
                    query,
                    context.session.inspection().duration_ns,
                    EventTable::Callstack,
                    context.budget,
                    |r| (r.key, r.range, r.is_open_ended),
                    |r| {
                        r.thread_key.is_none_or(|k| k.itid != 0)
                            && r.process_key.is_none_or(|k| k.ipid != 0)
                            && r.name.len() <= 4096
                            && event_text(r.category.as_deref(), 1024)
                            && event_text(r.thread_name.as_deref(), 4096)
                            && event_text(r.process_name.as_deref(), 4096)
                            && r.parent_event_key.is_none_or(|k| {
                                k.table == EventTable::Callstack
                                    && k.row_id > 0
                                    && k.row_id != 4_294_967_295
                            })
                            && r.arg_set_id.is_none()
                            && q.process_key
                                .is_none_or(|v| r.process_key.is_some_and(|k| k.ipid == v))
                            && q.thread_key
                                .is_none_or(|v| r.thread_key.is_some_and(|k| k.itid == v))
                            && q.pid.is_none_or(|v| r.pid == Some(v))
                            && q.tid.is_none_or(|v| r.tid == Some(v))
                            && q.depth.is_none_or(|v| r.depth == Some(v))
                            && q.minimum_duration_ns
                                .is_none_or(|v| r.range.duration_ns() >= v)
                            && (q.name_match != DirectoryNameMatch::Exact
                                || q.name.as_ref().is_none_or(|n| r.name == *n))
                    },
                )?;
                (
                    "slices",
                    page.capability_available,
                    page.truncated,
                    page.data_quality,
                    EventItems::Slices(page.items),
                )
            }
        };
        Ok(QueryResult {
            view,
            range: query.range(),
            filters: query.filters(true),
            capability_available: available,
            truncated,
            data_quality: quality,
            events,
        })
    }
    #[derive(Clone, Copy)]
    struct CommandContext<'a> {
        session: &'a NoCacheSession,
        tool: &'a ToolIdentity,
        limits: CommandLimits,
        budget: &'a EngineBudget,
        format: OutputFormat,
    }
    fn envelope<R: HumanResult>(
        context: &CommandContext<'_>,
        request: Request<'_>,
        result: R,
        issues: Vec<arktrace_contract::QualityIssue>,
        sections: Vec<&'static str>,
    ) -> Result<Vec<u8>, CommandError> {
        let maximum = context.limits.max_output_bytes;
        envelope_bounded(context, request, result, issues, sections, maximum)
    }
    /// `maximum` bounds only the encoding; the envelope still reports the
    /// invocation's own limits.
    fn envelope_bounded<R: HumanResult>(
        context: &CommandContext<'_>,
        request: Request<'_>,
        result: R,
        issues: Vec<arktrace_contract::QualityIssue>,
        sections: Vec<&'static str>,
        maximum: usize,
    ) -> Result<Vec<u8>, CommandError> {
        let CommandContext {
            session,
            tool,
            limits,
            budget,
            format,
        } = *context;
        let metadata = session.metadata();
        let inspection = session.inspection();
        metadata
            .validate()
            .map_err(|_| CommandError::InvalidMachineValue)?;
        if !digest(&metadata.parser.upstream_revision, 40)
            || metadata.schema_fingerprint != inspection.schema_fingerprint
            || inspection.duration_ns < 0
        {
            return Err(CommandError::InvalidMachineValue);
        }
        let mut seen = BTreeSet::new();
        let warnings = inspection
            .data_quality
            .warnings
            .iter()
            .cloned()
            .chain(issues)
            .filter(|issue| seen.insert((issue.category, issue.scope.clone(), issue.count)))
            .collect::<Vec<_>>();
        let data_quality = DataQuality::machine(
            if warnings.is_empty() {
                QualityStatus::Ok
            } else {
                QualityStatus::Warnings
            },
            warnings,
        )
        .map_err(|_| CommandError::InvalidMachineValue)?;
        let prep = &metadata.database_preparation;
        let value = Envelope {
            schema_version: arktrace_contract::MACHINE_JSON_VERSION,
            tool,
            trace: Trace {
                sha256: &metadata.trace_sha256,
                byte_count: metadata.source_byte_count,
                duration_ns: inspection.duration_ns,
                parser: Parser {
                    name: &metadata.parser.name,
                    version: &metadata.parser.reported_version,
                    upstream_revision: &metadata.parser.upstream_revision,
                    binary_sha256: &metadata.parser.binary_sha256,
                },
                schema_fingerprint: &metadata.schema_fingerprint,
            },
            request,
            limits,
            result,
            data_quality,
            truncation: Truncation {
                truncated: !sections.is_empty(),
                sections,
            },
            provenance: Provenance {
                parser_adapter_version: &metadata.parser.adapter_version,
                parser_build_recipe_version: &metadata.parser.build_recipe_version,
                schema_adapter_version: &prep.schema_adapter_version,
                index_schema_version: metadata.index_schema_version,
                upstream_database_sha256: &prep.upstream_database_sha256,
                upstream_database_byte_count: prep.upstream_database_byte_count,
            },
        };
        match format {
            OutputFormat::Machine { pretty } => encode_formatted(
                &value,
                maximum,
                budget.deadline,
                &budget.cancellation,
                pretty,
            ),
            OutputFormat::Human => {
                let mut writer = BoundedWriter {
                    bytes: Vec::new(),
                    maximum,
                    deadline: budget.deadline,
                    cancellation: &budget.cancellation,
                    failure: None,
                };
                value
                    .result
                    .human(
                        &value.trace,
                        &value.data_quality,
                        &value.truncation,
                        &mut writer,
                    )
                    .map_err(|_| writer.failure.unwrap_or(CommandError::InvalidMachineValue))?;
                Ok(writer.bytes)
            }
        }
    }
    #[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
    #[serde(rename_all = "camelCase")]
    pub enum DoctorStatus {
        Ok,
        Warning,
        Failed,
    }
    /// Swift `CLIMachineDoctorCheck` canonical identities, names and order.
    pub const DOCTOR_CHECKS: [(&str, &str); 9] = [
        ("tool", "ArkTrace tool"),
        ("os", "Operating system"),
        ("architecture", "Architecture"),
        ("parserManifest", "Parser manifest"),
        ("parserIdentity", "Parser identity"),
        ("sqlite", "SQLite"),
        ("cache", "Trace cache"),
        ("schemaAdapter", "Schema adapter"),
        ("selfTest", "End-to-end self-test"),
    ];
    #[derive(Serialize)]
    struct DoctorCheck {
        code: &'static str,
        name: &'static str,
        status: DoctorStatus,
    }
    #[derive(Serialize)]
    #[serde(rename_all = "camelCase")]
    struct DoctorResult {
        self_test: bool,
        checks: Vec<DoctorCheck>,
    }
    #[derive(Serialize)]
    #[serde(rename_all = "camelCase")]
    struct DoctorEnvelope<'a> {
        schema_version: &'static str,
        tool: &'a ToolIdentity,
        trace: Option<()>,
        request: Request<'a>,
        limits: CommandLimits,
        result: DoctorResult,
        data_quality: DataQuality,
        truncation: Truncation,
        provenance: Option<()>,
    }
    /// The doctor document: checks in canonical order (a prefix when
    /// `maxRows` is smaller, reported as the `checks` truncation section),
    /// no trace, no provenance and empty quality.
    pub fn doctor_document(
        tool: &ToolIdentity,
        self_test: bool,
        statuses: &[(&'static str, DoctorStatus)],
        limits: CommandLimits,
        deadline: Instant,
        cancellation: &CancellationToken,
        format: OutputFormat,
    ) -> Result<Vec<u8>, CommandError> {
        limits.validate()?;
        let mut checks = Vec::new();
        let mut rank = 0;
        for (code, status) in statuses {
            let position = DOCTOR_CHECKS
                .iter()
                .position(|(known, _)| known == code)
                .ok_or(CommandError::InvalidMachineValue)?;
            if position < rank || (position == 8) != (*code == "selfTest") {
                return Err(CommandError::InvalidMachineValue);
            }
            rank = position + 1;
            checks.push(DoctorCheck {
                code: DOCTOR_CHECKS[position].0,
                name: DOCTOR_CHECKS[position].1,
                status: *status,
            });
        }
        let truncated = checks.len() > limits.max_rows;
        checks.truncate(limits.max_rows);
        let value = DoctorEnvelope {
            schema_version: arktrace_contract::MACHINE_JSON_VERSION,
            tool,
            trace: None,
            request: Request {
                command: "doctor",
                parameters: BTreeMap::from([("selfTest", serde_json::json!(self_test))]),
            },
            limits,
            result: DoctorResult { self_test, checks },
            data_quality: DataQuality::machine(QualityStatus::Ok, Vec::new())
                .map_err(|_| CommandError::InvalidMachineValue)?,
            truncation: Truncation {
                truncated,
                sections: if truncated {
                    vec!["checks"]
                } else {
                    Vec::new()
                },
            },
            provenance: None,
        };
        match format {
            OutputFormat::Machine { pretty } => encode_formatted(
                &value,
                limits.max_output_bytes,
                deadline,
                cancellation,
                pretty,
            ),
            OutputFormat::Human => {
                let mut writer = BoundedWriter {
                    bytes: Vec::new(),
                    maximum: limits.max_output_bytes,
                    deadline,
                    cancellation,
                    failure: None,
                };
                let written = (|| {
                    for check in &value.result.checks {
                        let status = match check.status {
                            DoctorStatus::Ok => "ok",
                            DoctorStatus::Warning => "warning",
                            DoctorStatus::Failed => "failed",
                        };
                        writeln!(writer, "{}: {status}", check.name)?;
                    }
                    if truncated {
                        writeln!(writer, "… checks truncated")?;
                    }
                    Ok::<_, std::io::Error>(())
                })();
                written.map_err(|_| writer.failure.unwrap_or(CommandError::InvalidMachineValue))?;
                Ok(writer.bytes)
            }
        }
    }
    /// Consumes an ephemeral session. No success bytes escape until bounded
    /// serialization and explicit checked close both finish, including failures.
    pub fn execute_no_cache(
        session: NoCacheSession,
        command: DirectoryCommand,
        tool: &ToolIdentity,
        limits: CommandLimits,
        budget: &EngineBudget,
    ) -> Result<Vec<u8>, CommandError> {
        execute_no_cache_formatted(
            session,
            command,
            tool,
            limits,
            budget,
            OutputFormat::Machine { pretty: false },
        )
    }
    pub fn execute_no_cache_formatted(
        session: NoCacheSession,
        command: DirectoryCommand,
        tool: &ToolIdentity,
        limits: CommandLimits,
        budget: &EngineBudget,
        format: OutputFormat,
    ) -> Result<Vec<u8>, CommandError> {
        let output = (|| {
            limits.validate()?;
            check(budget)?;
            let context = CommandContext {
                session: &session,
                tool,
                limits,
                budget,
                format,
            };
            match command {
                DirectoryCommand::Inspect => {
                    session.verify(budget).map_err(CommandError::Engine)?;
                    let inspection = session.inspection();
                    let sections = if inspection
                        .data_quality
                        .warnings
                        .iter()
                        .any(|v| v.category == QualityCategory::ProbeTruncated)
                    {
                        vec!["dataQualityProbes"]
                    } else {
                        Vec::new()
                    };
                    envelope(
                        &context,
                        Request {
                            command: "inspect",
                            parameters: BTreeMap::new(),
                        },
                        InspectResult {
                            cache_hit: false,
                            capabilities: &inspection.capabilities,
                            index_schema_version: session.metadata().index_schema_version,
                        },
                        Vec::new(),
                        sections,
                    )
                }
                DirectoryCommand::Summary(requested) => {
                    let (result, issues, sections) =
                        summary_result(&session, requested, limits, budget)?;
                    let parameters = BTreeMap::from([
                        ("endNs", serde_json::json!(requested.map(|r| r.end_ns()))),
                        (
                            "startNs",
                            serde_json::json!(requested.map(|r| r.start_ns())),
                        ),
                    ]);
                    envelope(
                        &context,
                        Request {
                            command: "summary",
                            parameters,
                        },
                        result,
                        issues,
                        sections,
                    )
                }
                DirectoryCommand::Processes(query) => {
                    query
                        .validate()
                        .map_err(|_| CommandError::InvalidArguments)?;
                    if query.process_key.is_some() || query.name_match != DirectoryNameMatch::Exact
                    {
                        return Err(CommandError::InvalidArguments);
                    }
                    let page = session
                        .processes(&query, budget)
                        .map_err(CommandError::Engine)?;
                    count(&page, query.limit, limits.max_rows)?;
                    validate_processes(&page, &query, session.inspection().duration_ns, budget)?;
                    let parameters = BTreeMap::from([
                        ("limit", serde_json::json!(query.limit)),
                        ("name", serde_json::json!(query.name)),
                        ("pid", serde_json::json!(query.pid)),
                    ]);
                    let sections = if page.truncated {
                        vec!["processes"]
                    } else {
                        Vec::new()
                    };
                    envelope(
                        &context,
                        Request {
                            command: "processes",
                            parameters,
                        },
                        Items { items: page.items },
                        page.data_quality_issues,
                        sections,
                    )
                }
                DirectoryCommand::Threads(query) => {
                    query
                        .validate()
                        .map_err(|_| CommandError::InvalidArguments)?;
                    if query.name_match != DirectoryNameMatch::Exact {
                        return Err(CommandError::InvalidArguments);
                    }
                    let page = session
                        .threads(&query, budget)
                        .map_err(CommandError::Engine)?;
                    count(&page, query.limit, limits.max_rows)?;
                    validate_threads(&page, &query, session.inspection().duration_ns, budget)?;
                    let parameters = BTreeMap::from([
                        ("limit", serde_json::json!(query.limit)),
                        ("name", serde_json::json!(query.name)),
                        ("pid", serde_json::json!(query.pid)),
                        ("processKey", serde_json::json!(query.process_key)),
                        ("threadKey", serde_json::json!(query.thread_key)),
                        ("tid", serde_json::json!(query.tid)),
                    ]);
                    let sections = if page.truncated {
                        vec!["threads"]
                    } else {
                        Vec::new()
                    };
                    envelope(
                        &context,
                        Request {
                            command: "threads",
                            parameters,
                        },
                        Items { items: page.items },
                        page.data_quality_issues,
                        sections,
                    )
                }
                DirectoryCommand::Query(query) => {
                    let result = event_result(&context, &query)?;
                    let sections = if result.truncated {
                        vec![query.cli_view()]
                    } else {
                        Vec::new()
                    };
                    let issues = result.data_quality.warnings.clone();
                    envelope(
                        &context,
                        Request {
                            command: "query",
                            parameters: query.parameters(),
                        },
                        result,
                        issues,
                        sections,
                    )
                }
                DirectoryCommand::Context { time, filters } => {
                    context_command(&context, time, filters)
                }
                DirectoryCommand::Analyze(options) => analyze_command(&context, options),
            }
        })();
        session.close().map_err(CommandError::Engine)?;
        check(budget)?;
        output
    }
    // ---- context / analyze (AT-RUST-009, AT-RUST-010) ----

    /// The engine's analysis-stage mapping (`no_cache::analysis_error`); a
    /// request-bound failure stays the usage error Swift reports.
    fn analysis_failure(error: arktrace_engine::AnalysisError) -> CommandError {
        use arktrace_engine::{
            AnalysisError as E, AnalysisFailure, EngineError, EngineFailure, EngineStage,
        };
        use arktrace_platform::HostError;
        let failure = match error {
            E::InvalidBounds => return CommandError::InvalidArguments,
            E::Cancelled => EngineFailure::Host(HostError::Cancelled),
            E::DeadlineReached => EngineFailure::Host(HostError::DeadlineExceeded),
            E::InputBudgetExceeded => EngineFailure::Analysis(AnalysisFailure::InputBudgetExceeded),
            E::InvalidEvidence => EngineFailure::Analysis(AnalysisFailure::InvalidEvidence),
            E::Quality(_) => EngineFailure::Analysis(AnalysisFailure::InvalidQuality),
        };
        CommandError::Engine(EngineError {
            stage: EngineStage::Analyzing,
            failure,
        })
    }
    fn analysis_check(
        budget: &EngineBudget,
    ) -> impl FnMut() -> Result<(), arktrace_engine::AnalysisError> + '_ {
        move || {
            if budget.cancellation.is_cancelled() {
                Err(arktrace_engine::AnalysisError::Cancelled)
            } else if Instant::now() >= budget.deadline {
                Err(arktrace_engine::AnalysisError::DeadlineReached)
            } else {
                Ok(())
            }
        }
    }

    #[derive(Serialize)]
    struct AnalyzeResult {
        analysis: arktrace_engine::DeterministicAnalysis,
        kind: &'static str,
    }
    impl HumanResult for AnalyzeResult {
        /// Swift `CLIHumanRenderer.analyze`.
        fn human(
            &self,
            _trace: &Trace<'_>,
            quality: &DataQuality,
            _truncation: &Truncation,
            writer: &mut BoundedWriter<'_>,
        ) -> std::io::Result<()> {
            let a = &self.analysis;
            writeln!(writer, "Analysis: {}", self.kind)?;
            writeln!(
                writer,
                "Range ns: [{}, {})",
                a.range.start_ns(),
                a.range.end_ns()
            )?;
            match self.kind {
                "cpu" => {
                    for item in &a.cpu_utilization {
                        writeln!(
                            writer,
                            "cpu={} runningNs={} rawRunningNs={} slices={}",
                            item.cpu, item.occupied_ns, item.raw_running_ns, item.slice_count
                        )?;
                    }
                }
                "scheduling" => {
                    let s = &a.scheduling_latency;
                    writeln!(writer, "Supported: {}", s.supported)?;
                    writeln!(writer, "Count: {}", s.count)?;
                    if let Some(p) = &s.percentiles {
                        writeln!(
                            writer,
                            "p50={} p90={} p95={} p99={} max={}",
                            p.p50_ns, p.p90_ns, p.p95_ns, p.p99_ns, p.max_ns
                        )?;
                    }
                }
                "slices" => {
                    for item in &a.long_slices {
                        writeln!(
                            writer,
                            "durationNs={} name={} event={}:{}",
                            item.range.duration_ns(),
                            terminal(&item.name),
                            table_raw(item.key.table),
                            item.key.row_id
                        )?;
                    }
                }
                "range" => {
                    writeln!(writer, "CPUs: {}", a.cpu_utilization.len())?;
                    writeln!(writer, "Top processes: {}", a.top_processes.len())?;
                    writeln!(writer, "Top threads: {}", a.top_threads.len())?;
                    writeln!(writer, "State rows: {}", a.thread_state_distribution.len())?;
                    writeln!(writer, "Long slices: {}", a.long_slices.len())?;
                }
                _ => {
                    for item in &a.hot_intervals {
                        writeln!(
                            writer,
                            "[{},{}) score={} cpuBusyNs={}",
                            item.range.start_ns(),
                            item.range.end_ns(),
                            item.score.total,
                            item.score.cpu_busy_ns
                        )?;
                    }
                }
            }
            writeln!(
                writer,
                "Data quality: {}",
                if quality.status == QualityStatus::Ok {
                    "ok"
                } else {
                    "warnings"
                }
            )
        }
    }
    fn table_raw(table: EventTable) -> &'static str {
        match table {
            EventTable::SchedSlice => "sched_slice",
            EventTable::ThreadState => "thread_state",
            EventTable::Callstack => "callstack",
            EventTable::Measure => "measure",
            EventTable::ProcessMeasure => "process_measure",
            EventTable::FrameSlice => "frame_slice",
        }
    }

    /// Swift `CLIProductionCommandExecutor` `.analyze` + the deterministic
    /// engine: one event budget per section, the global row retention, and
    /// the envelope truncation sections.
    fn analyze_command(
        context: &CommandContext<'_>,
        options: crate::arguments::AnalyzeOptions,
    ) -> Result<Vec<u8>, CommandError> {
        let (session, budget, limits) = (context.session, context.budget, context.limits);
        let inspection = session.inspection();
        let duration = inspection.duration_ns;
        let range = match options.range {
            Some(range) => range,
            None => {
                TraceTimeRange::query(0, duration).map_err(|_| CommandError::InvalidArguments)?
            }
        };
        if range.end_ns() > duration {
            return Err(CommandError::InvalidArguments);
        }
        let f = &options.filters;
        let filters = arktrace_engine::IdentityFilters {
            process_key: f.process_key,
            pid: f.pid,
            thread_key: f.thread_key,
            tid: f.tid,
        };
        let request = arktrace_engine::DeterministicRequest::cli(
            range,
            filters,
            limits.max_events,
            options.limit,
            options.threshold_ns,
            limits.timeout_ms,
        );
        request.validate().map_err(analysis_failure)?;
        // Swift deduplicates identical typed queries: with one event budget
        // every CPU role, and every named role, shares one immutable page.
        let events = limits.max_events;
        let cpu = session
            .cpu_slices(
                &arktrace_contract::CpuSliceQuery {
                    range,
                    cpu: None,
                    process_key: f.process_key,
                    pid: f.pid,
                    thread_key: f.thread_key,
                    tid: f.tid,
                    limit: events,
                },
                budget,
            )
            .map_err(CommandError::Engine)?;
        let state_query = arktrace_contract::ThreadStateQuery {
            range,
            cpu: None,
            process_key: f.process_key,
            pid: f.pid,
            thread_key: f.thread_key,
            tid: f.tid,
            raw_state: None,
            state: None,
            limit: events,
        };
        let states = session
            .thread_states(&state_query, budget)
            .map_err(CommandError::Engine)?;
        let runnable = session
            .thread_states(
                &arktrace_contract::ThreadStateQuery {
                    state: Some(arktrace_contract::TraceThreadState::Runnable),
                    ..state_query
                },
                budget,
            )
            .map_err(CommandError::Engine)?;
        let named = session
            .slices(
                &arktrace_contract::TraceSliceQuery {
                    range,
                    event_key: None,
                    process_key: f.process_key,
                    pid: f.pid,
                    thread_key: f.thread_key,
                    tid: f.tid,
                    name: None,
                    name_match: DirectoryNameMatch::Exact,
                    minimum_duration_ns: Some(options.threshold_ns),
                    depth: None,
                    unattributed_only: false,
                    includes_argument_set: false,
                    limit: events,
                },
                budget,
            )
            .map_err(CommandError::Engine)?;
        let capabilities = &inspection.capabilities;
        let mut checker = analysis_check(budget);
        let mut analysis = arktrace_engine::deterministic_analysis(
            &request,
            arktrace_engine::DeterministicInput {
                cpu: &cpu,
                processes: &cpu,
                threads: &cpu,
                states: &states,
                named: &named,
                scheduling_cpu: &cpu,
                scheduling_states: &runnable,
                hot_cpu: &cpu,
                hot_named: &named,
                scheduling_capable: capabilities.cpu_scheduling && capabilities.thread_states,
                trace_quality: &inspection.data_quality.warnings,
            },
            &mut checker,
        )
        .map_err(analysis_failure)?;
        // Recheck retained Ready authority after the pure reduction.
        session.verify(budget).map_err(CommandError::Engine)?;
        analysis.retain_rows(limits.max_rows);
        let mut sections = analysis.sections.truncated_names();
        sections.sort_unstable();
        let issues = analysis.data_quality.warnings.clone();
        envelope(
            context,
            Request {
                command: "analyze",
                parameters: crate::event_query::analyze_parameters(&options),
            },
            AnalyzeResult {
                analysis,
                kind: options.kind,
            },
            issues,
            sections,
        )
    }

    /// Swift `TraceSummary` in its Machine context shape (`CLIMachineContextSummary`).
    #[derive(Serialize)]
    #[serde(rename_all = "camelCase")]
    struct ContextSummary<'a> {
        #[serde(flatten)]
        base: SummaryResult<'a>,
        schema_fingerprint: &'a str,
        data_quality: DataQuality,
        truncated_sections: Vec<&'static str>,
    }
    #[derive(Serialize)]
    #[serde(transparent)]
    struct ContextResult<'a>(arktrace_engine::ContextDocument<'a, ContextSummary<'a>>);
    impl HumanResult for ContextResult<'_> {
        /// Swift `CLIHumanRenderer.context`.
        fn human(
            &self,
            _trace: &Trace<'_>,
            quality: &DataQuality,
            _truncation: &Truncation,
            writer: &mut BoundedWriter<'_>,
        ) -> std::io::Result<()> {
            let c = &self.0;
            writeln!(
                writer,
                "Range ns: [{}, {})\nProcesses: {}\nThreads: {}\nCPU slices: {}\nThread states: {}\nNamed slices: {}\nCounter samples: {}\nData quality: {}\nTruncated: {}",
                c.range.start_ns(),
                c.range.end_ns(),
                c.processes.len(),
                c.threads.len(),
                c.cpu_slices.len(),
                c.thread_states.len(),
                c.slices.len(),
                c.counters.iter().map(|v| v.samples.len()).sum::<usize>(),
                if quality.status == QualityStatus::Ok {
                    "ok"
                } else {
                    "warnings"
                },
                c.truncation.truncated(),
            )
        }
    }
    /// One-row identity probes (Swift `repository.processes/threads(limit: 1)`).
    struct DirectoryProbe<'s> {
        session: &'s NoCacheSession,
        budget: &'s EngineBudget,
        failure: Option<CommandError>,
    }
    impl arktrace_engine::ContextDirectory for DirectoryProbe<'_> {
        fn process(
            &mut self,
            key: i64,
        ) -> Result<Option<TraceProcess>, arktrace_engine::AnalysisError> {
            let query = ProcessQuery {
                process_key: Some(key),
                pid: None,
                name: None,
                name_match: DirectoryNameMatch::Exact,
                limit: 1,
            };
            match self.session.processes(&query, self.budget) {
                Ok(page) => Ok(page.items.into_iter().next()),
                Err(error) => {
                    self.failure = Some(CommandError::Engine(error));
                    Err(arktrace_engine::AnalysisError::InvalidEvidence)
                }
            }
        }
        fn thread(
            &mut self,
            key: i64,
        ) -> Result<Option<TraceThread>, arktrace_engine::AnalysisError> {
            let query = ThreadQuery {
                process_key: None,
                pid: None,
                thread_key: Some(key),
                tid: None,
                name: None,
                name_match: DirectoryNameMatch::Exact,
                limit: 1,
            };
            match self.session.threads(&query, self.budget) {
                Ok(page) => Ok(page.items.into_iter().next()),
                Err(error) => {
                    self.failure = Some(CommandError::Engine(error));
                    Err(arktrace_engine::AnalysisError::InvalidEvidence)
                }
            }
        }
    }
    /// Exact compact UTF-8 JSON byte count, stopping once past `maximum`.
    struct CountingWriter {
        count: usize,
        maximum: usize,
    }
    impl Write for CountingWriter {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            self.count = self.count.saturating_add(bytes.len());
            if self.count > self.maximum {
                return Err(io::Error::other("measured past maximum"));
            }
            Ok(bytes.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
    fn measured<T: Serialize>(
        value: &T,
        maximum: usize,
    ) -> Result<usize, arktrace_engine::AnalysisError> {
        let mut writer = CountingWriter { count: 0, maximum };
        match serde_json::to_writer(&mut writer, value) {
            Ok(()) => Ok(writer.count),
            Err(_) if writer.count > maximum => Ok(writer.count),
            Err(_) => Err(arktrace_engine::AnalysisError::InvalidEvidence),
        }
    }
    fn context_failure(error: arktrace_engine::ContextError) -> CommandError {
        match error {
            arktrace_engine::ContextError::Analysis(error) => analysis_failure(error),
            arktrace_engine::ContextError::OutputLimitExceeded { .. } => {
                CommandError::OutputLimitExceeded
            }
            arktrace_engine::ContextError::DuplicateDirectoryIdentity
            | arktrace_engine::ContextError::Inconsistent => CommandError::InvalidMachineValue,
        }
    }
    const SUMMARY_SECTION_ORDER: [&str; 8] = [
        "cpuCount",
        "processCount",
        "threadCount",
        "cpuSliceCount",
        "threadStateCount",
        "namedSliceCount",
        "counterSeriesCount",
        "eventCountBySource",
    ];

    /// Swift `TraceContextBuilder.build` behind `envelopeFittedContext`.
    fn context_command(
        context: &CommandContext<'_>,
        time: arktrace_engine::ContextTime,
        filters: arktrace_engine::AgentFilters,
    ) -> Result<Vec<u8>, CommandError> {
        let (session, budget, limits) = (context.session, context.budget, context.limits);
        time.validate().map_err(analysis_failure)?;
        filters.validate().map_err(analysis_failure)?;
        let inspection = session.inspection();
        let (range, center) = time
            .normalized(inspection.duration_ns)
            .map_err(analysis_failure)?;
        let (events, rows) = (limits.max_events, limits.max_rows);
        let engine = CommandError::Engine;
        let cpu = session
            .query_cpu_slices(
                &arktrace_contract::CpuSliceQuery {
                    range,
                    cpu: filters.cpu,
                    process_key: filters.process_key,
                    pid: filters.pid,
                    thread_key: filters.thread_key,
                    tid: filters.tid,
                    limit: events,
                },
                budget,
            )
            .map_err(engine)?;
        let states = session
            .query_thread_states(
                &arktrace_contract::ThreadStateQuery {
                    range,
                    cpu: filters.cpu,
                    process_key: filters.process_key,
                    pid: filters.pid,
                    thread_key: filters.thread_key,
                    tid: filters.tid,
                    raw_state: filters.raw_state.clone(),
                    state: filters.normalized_state,
                    limit: events,
                },
                budget,
            )
            .map_err(engine)?;
        let slices = session
            .query_slices(
                &arktrace_contract::TraceSliceQuery {
                    range,
                    event_key: None,
                    process_key: filters.process_key,
                    pid: filters.pid,
                    thread_key: filters.thread_key,
                    tid: filters.tid,
                    name: filters.name.clone(),
                    name_match: filters.name_match,
                    minimum_duration_ns: filters.minimum_duration_ns,
                    depth: filters.depth,
                    unattributed_only: false,
                    includes_argument_set: false,
                    limit: events,
                },
                budget,
            )
            .map_err(engine)?;
        let capabilities = &inspection.capabilities;
        let scope_conflict =
            filters.cpu.is_some() && (filters.process_key.is_some() || filters.pid.is_some());
        let counters = if scope_conflict {
            EventPage {
                items: Vec::new(),
                truncated: false,
                capability_available: capabilities.cpu_counters || capabilities.process_counters,
                data_quality: inspection.data_quality.clone(),
            }
        } else {
            session
                .query_counters(
                    &arktrace_contract::CounterQuery {
                        range,
                        scope: None,
                        filter_id: filters.counter_filter_id,
                        cpu: filters.cpu,
                        process_key: filters.process_key,
                        pid: filters.pid,
                        name: None,
                        name_match: DirectoryNameMatch::Exact,
                        limit: events,
                    },
                    budget,
                )
                .map_err(engine)?
        };
        let processes = session
            .processes(
                &ProcessQuery {
                    process_key: filters.process_key,
                    pid: filters.pid,
                    name: None,
                    name_match: DirectoryNameMatch::Exact,
                    limit: rows,
                },
                budget,
            )
            .map_err(engine)?;
        let threads = session
            .threads(
                &ThreadQuery {
                    process_key: filters.process_key,
                    pid: filters.pid,
                    thread_key: filters.thread_key,
                    tid: filters.tid,
                    name: None,
                    name_match: DirectoryNameMatch::Exact,
                    limit: rows,
                },
                budget,
            )
            .map_err(engine)?;
        let (summary_base, facts_issues, sorted_sections) =
            summary_result(session, Some(range), limits, budget)?;
        let mut summary_quality = inspection.data_quality.warnings.clone();
        summary_quality.extend(facts_issues);
        let summary_dq = {
            let mut seen = BTreeSet::new();
            let unique: Vec<_> = summary_quality
                .iter()
                .filter(|issue| {
                    seen.insert((
                        issue.category,
                        issue.scope.clone(),
                        issue.count,
                        issue.message.clone(),
                    ))
                })
                .cloned()
                .collect();
            DataQuality::machine(
                if unique.is_empty() {
                    QualityStatus::Ok
                } else {
                    QualityStatus::Warnings
                },
                unique,
            )
            .map_err(|_| CommandError::InvalidMachineValue)?
        };
        let truncated_sections: Vec<&'static str> = SUMMARY_SECTION_ORDER
            .into_iter()
            .filter(|name| sorted_sections.contains(name))
            .collect();
        let summary_truncated = !truncated_sections.is_empty();
        let metadata = session.metadata();
        let summary = ContextSummary {
            base: summary_base,
            schema_fingerprint: &metadata.schema_fingerprint,
            data_quality: summary_dq,
            truncated_sections,
        };
        let loaded = arktrace_engine::ContextLoaded {
            range,
            center,
            filters: &filters,
            processes,
            threads,
            cpu,
            states,
            slices,
            counters,
            summary: &summary,
            summary_quality: &summary_quality,
            summary_truncated,
        };
        let mut probe = DirectoryProbe {
            session,
            budget,
            failure: None,
        };
        let mut checker = analysis_check(budget);
        let prepared = arktrace_engine::prepare_context(&loaded, rows, &mut probe, &mut checker)
            .map_err(|error| {
                probe
                    .failure
                    .take()
                    .unwrap_or_else(|| context_failure(error))
            })?;
        let mut measure = |document: &arktrace_engine::ContextDocument<'_, ContextSummary<'_>>,
                           maximum: usize| measured(document, maximum);
        let request = || Request {
            command: "context",
            parameters: crate::event_query::context_parameters(&time, &filters),
        };
        let finish = |document: arktrace_engine::ContextDocument<'_, ContextSummary<'_>>,
                      maximum: usize| {
            let mut sections = document.truncation.truncated_names();
            sections.sort_unstable();
            let issues = document.data_quality.warnings.clone();
            envelope_bounded(
                context,
                request(),
                ContextResult(document),
                issues,
                sections,
                maximum,
            )
        };
        let mut maximum_bytes = limits.max_output_bytes;
        if !matches!(context.format, OutputFormat::Machine { .. }) {
            let document = arktrace_engine::retain_context(
                &prepared,
                events,
                rows,
                maximum_bytes,
                &mut measure,
                &mut checker,
            )
            .map_err(context_failure)?;
            session.verify(budget).map_err(engine)?;
            return finish(document, limits.max_output_bytes);
        }
        // Swift `envelopeFittedContext`: near the boundary, the measured full
        // envelope overage tightens the domain limit for a bounded re-run.
        let mut prior_raw = None;
        for _ in 0..16 {
            check(budget)?;
            let document = arktrace_engine::retain_context(
                &prepared,
                events,
                rows,
                maximum_bytes,
                &mut measure,
                &mut checker,
            )
            .map_err(context_failure)?;
            let raw = measured(&document, usize::MAX).map_err(analysis_failure)?;
            let bytes = finish(document, usize::MAX)?;
            if bytes.len() <= limits.max_output_bytes {
                session.verify(budget).map_err(engine)?;
                return Ok(bytes);
            }
            let overage = bytes.len() - limits.max_output_bytes;
            let Some(candidate) = raw.checked_sub(overage) else {
                return Err(CommandError::OutputLimitExceeded);
            };
            let next = (maximum_bytes - 1).min(candidate);
            if next < 1_024 || next >= maximum_bytes || prior_raw == Some(raw) {
                return Err(CommandError::OutputLimitExceeded);
            }
            prior_raw = Some(raw);
            maximum_bytes = next;
        }
        Err(CommandError::OutputLimitExceeded)
    }
    #[cfg(test)]
    mod tests {
        use super::*;
        use std::time::Duration;
        #[test]
        fn terminal_controls_are_visible_and_expansion_stays_bounded_on_scalar_boundaries() {
            assert_eq!(
                terminal("a\n\t\u{1b}\u{200b}\u{2028}尾"),
                "a\\u{A}\\u{9}\\u{1B}\\u{200B}\\u{2028}尾"
            );
            assert_eq!(
                terminal(&"界".repeat(2000)),
                format!("{}…", "界".repeat(1364))
            );
            let escaped = terminal(&"\u{1b}".repeat(1000));
            assert!(escaped.len() <= 4096);
            assert!(escaped.ends_with("}…"));
        }
        fn budget() -> EngineBudget {
            EngineBudget {
                maximum_source_bytes: 1024,
                maximum_database_bytes: 1024,
                deadline: Instant::now() + Duration::from_secs(1),
                cancellation: CancellationToken::default(),
            }
        }
        fn cpu_query() -> crate::EventQuery {
            crate::EventQuery::CpuSlices(arktrace_contract::CpuSliceQuery {
                range: TraceTimeRange::query(0, 10).unwrap(),
                cpu: None,
                process_key: None,
                pid: None,
                thread_key: None,
                tid: None,
                limit: 2,
            })
        }
        #[test]
        fn event_payload_rejects_duplicate_keys_bad_table_and_nonintersecting_times() {
            let key = EventKey {
                table: EventTable::SchedSlice,
                row_id: 0,
            };
            let good = (key, TraceTimeRange::event(0, 5).unwrap(), false);
            let query = cpu_query();
            let request = budget();
            validate_events(
                &[good],
                &query,
                10,
                EventTable::SchedSlice,
                &request,
                |r| *r,
                |_| true,
            )
            .unwrap();
            for items in [
                vec![good, good],
                vec![(
                    EventKey {
                        table: EventTable::ThreadState,
                        ..key
                    },
                    good.1,
                    false,
                )],
                vec![(key, TraceTimeRange::event(10, 10).unwrap(), false)],
                vec![(key, TraceTimeRange::event(0, 11).unwrap(), false)],
                vec![(key, TraceTimeRange::event(0, 5).unwrap(), true)],
                vec![(EventKey { row_id: 2, ..key }, good.1, false), good],
            ] {
                assert_eq!(
                    validate_events(
                        &items,
                        &query,
                        10,
                        EventTable::SchedSlice,
                        &request,
                        |r| *r,
                        |_| true
                    ),
                    Err(CommandError::InvalidMachineValue)
                );
            }
            let page = EventPage::<CpuSlice> {
                items: Vec::new(),
                truncated: true,
                capability_available: true,
                data_quality: DataQuality::machine(QualityStatus::Ok, Vec::new()).unwrap(),
            };
            let limits = CommandLimits {
                timeout_ms: 100,
                max_rows: 2,
                max_events: 2,
                max_output_bytes: 1024,
            };
            event_count(&page, &query, limits).unwrap();
            let mut unavailable = page;
            unavailable.capability_available = false;
            assert_eq!(
                event_count(&unavailable, &query, limits),
                Err(CommandError::InvalidMachineValue)
            );
        }
        #[test]
        fn query_machine_has_exact_selected_array_and_scalar_request_nested_result_keys() {
            let query = crate::EventQuery::ThreadStates(arktrace_contract::ThreadStateQuery {
                range: TraceTimeRange::query(0, 10).unwrap(),
                cpu: None,
                process_key: Some(-10),
                pid: None,
                thread_key: Some(-11),
                tid: None,
                raw_state: Some("R+".to_owned()),
                state: Some(arktrace_contract::TraceThreadState::Runnable),
                limit: 2,
            });
            let result = QueryResult {
                view: "threadStates",
                range: query.range(),
                filters: query.filters(true),
                capability_available: true,
                truncated: false,
                data_quality: DataQuality::machine(QualityStatus::Ok, Vec::new()).unwrap(),
                events: EventItems::States(Vec::new()),
            };
            let json = serde_json::to_value(&result).unwrap();
            assert_eq!(
                json.as_object()
                    .unwrap()
                    .keys()
                    .map(String::as_str)
                    .collect::<BTreeSet<_>>(),
                BTreeSet::from([
                    "view",
                    "range",
                    "filters",
                    "capabilityAvailable",
                    "truncated",
                    "dataQuality",
                    "threadStates"
                ])
            );
            assert_eq!(
                json["filters"]["processKey"],
                serde_json::json!({"ipid":-10})
            );
            assert_eq!(
                json["filters"]["threadKey"],
                serde_json::json!({"itid":-11})
            );
            assert_eq!(json["filters"]["normalizedState"], "runnable");
            assert!(json["filters"]["counterFilterID"].is_null());
            assert_eq!(query.parameters()["processKey"], -10);
            assert_eq!(query.parameters()["threadKey"], -11);
            assert_eq!(query.parameters()["view"], "thread-states");
            assert_eq!(query.parameters().len(), 16);
            let request = budget();
            let bytes = encode(&result, 1024, request.deadline, &request.cancellation).unwrap();
            assert_eq!(
                serde_json::from_slice::<serde_json::Value>(&bytes).unwrap(),
                json
            );
        }
        #[test]
        fn query_human_escapes_raw_state_and_keeps_half_open_and_truncated_labels() {
            let query = cpu_query();
            let request = budget();
            let result = QueryResult {
                view: "threadStates",
                range: query.range(),
                filters: BTreeMap::new(),
                capability_available: true,
                truncated: true,
                data_quality: DataQuality::machine(QualityStatus::Ok, Vec::new()).unwrap(),
                events: EventItems::States(vec![ThreadStateInterval {
                    key: EventKey {
                        table: EventTable::ThreadState,
                        row_id: 0,
                    },
                    range: TraceTimeRange::event(0, 5).unwrap(),
                    thread_key: arktrace_contract::ThreadKey { itid: -11 },
                    process_key: None,
                    state: "R\n\u{1b}".to_owned(),
                    normalized_state: None,
                    cpu: None,
                    tid: None,
                    pid: None,
                    process_name: None,
                    thread_name: None,
                    is_open_ended: false,
                }]),
            };
            let trace = Trace {
                sha256: "",
                byte_count: 0,
                duration_ns: 10,
                parser: Parser {
                    name: "",
                    version: "",
                    upstream_revision: "",
                    binary_sha256: "",
                },
                schema_fingerprint: "",
            };
            let mut writer = BoundedWriter {
                bytes: Vec::new(),
                maximum: 1024,
                deadline: request.deadline,
                cancellation: &request.cancellation,
                failure: None,
            };
            result
                .human(
                    &trace,
                    &result.data_quality,
                    &Truncation {
                        truncated: true,
                        sections: Vec::new(),
                    },
                    &mut writer,
                )
                .unwrap();
            assert_eq!(
                String::from_utf8(writer.bytes).unwrap(),
                "View: threadStates\nRange ns: [0, 10)\nCapability available: true\n0\t5\tstate=R\\u{A}\\u{1B}\tevent=thread_state:0\n… result truncated\n"
            );
        }
        fn process_query() -> ProcessQuery {
            ProcessQuery {
                process_key: None,
                pid: None,
                name: None,
                name_match: DirectoryNameMatch::Exact,
                limit: 10,
            }
        }
        fn thread_query() -> ThreadQuery {
            ThreadQuery {
                process_key: None,
                pid: None,
                thread_key: None,
                tid: None,
                name: None,
                name_match: DirectoryNameMatch::Exact,
                limit: 10,
            }
        }
        fn page<T>(items: Vec<T>) -> DirectoryPage<T> {
            DirectoryPage {
                items,
                truncated: false,
                data_quality_issues: Vec::new(),
            }
        }
        #[test]
        fn process_machine_boundary_rejects_bad_count_identity_order_range_and_filter() {
            let row = TraceProcess {
                key: 1,
                pid: 2,
                name: Some("safe".to_owned()),
                start_ns: Some(0),
                end_ns: Some(10),
                thread_count: Some(2),
            };
            let query = process_query();
            assert!(validate_processes(&page(vec![row.clone()]), &query, 10, &budget()).is_ok());
            for rows in [
                vec![TraceProcess {
                    thread_count: Some(-1),
                    ..row.clone()
                }],
                vec![row.clone(), row.clone()],
                vec![
                    TraceProcess {
                        key: 2,
                        ..row.clone()
                    },
                    row.clone(),
                ],
                vec![TraceProcess {
                    end_ns: Some(11),
                    ..row.clone()
                }],
                vec![TraceProcess {
                    name: Some(String::new()),
                    ..row.clone()
                }],
            ] {
                assert_eq!(
                    validate_processes(&page(rows), &query, 10, &budget()),
                    Err(CommandError::InvalidMachineValue)
                );
            }
            let query = ProcessQuery {
                pid: Some(3),
                ..query
            };
            assert_eq!(
                validate_processes(&page(vec![row]), &query, 10, &budget()),
                Err(CommandError::InvalidMachineValue)
            );
        }
        #[test]
        fn thread_machine_boundary_rejects_nil_pid_order_filter_and_inverted_range() {
            let row = TraceThread {
                key: 1,
                process_key: Some(1),
                tid: 2,
                pid: Some(3),
                name: None,
                process_name: None,
                start_ns: None,
                end_ns: Some(10),
                is_main_thread: None,
            };
            let query = thread_query();
            assert!(validate_threads(&page(vec![row.clone()]), &query, 10, &budget()).is_ok());
            for rows in [
                vec![
                    TraceThread {
                        key: 2,
                        pid: None,
                        ..row.clone()
                    },
                    row.clone(),
                ],
                vec![row.clone(), row.clone()],
                vec![TraceThread {
                    start_ns: Some(9),
                    end_ns: Some(2),
                    ..row.clone()
                }],
            ] {
                assert_eq!(
                    validate_threads(&page(rows), &query, 10, &budget()),
                    Err(CommandError::InvalidMachineValue)
                );
            }
            let query = ThreadQuery {
                process_key: Some(0),
                ..query
            };
            assert_eq!(
                validate_threads(&page(vec![row]), &query, 10, &budget()),
                Err(CommandError::InvalidMachineValue)
            );
        }
    }
}
#[cfg(any(target_os = "macos", windows))]
pub use macos::{
    DOCTOR_CHECKS, DirectoryCommand, DoctorStatus, doctor_document, execute_no_cache,
    execute_no_cache_formatted,
};

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    #[test]
    fn pretty_whitespace_and_newline_share_the_same_complete_output_budget() {
        let token = CancellationToken::default();
        let deadline = Instant::now() + Duration::from_secs(1);
        let value = serde_json::json!({"nested":{"value":"\u{2028}\n"}});
        let pretty = encode_formatted(&value, 1024, deadline, &token, true).unwrap();
        let compact = encode(&value, 1024, deadline, &token).unwrap();
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&pretty).unwrap(),
            value
        );
        assert!(pretty.len() > compact.len());
        assert_eq!(
            encode_formatted(&value, pretty.len() - 1, deadline, &token, true),
            Err(CommandError::OutputLimitExceeded)
        );
        assert!(pretty.ends_with(b"\n"));
    }
    #[test]
    fn whole_output_budget_includes_json_escaping_and_newline() {
        let token = CancellationToken::default();
        let deadline = Instant::now() + Duration::from_secs(1);
        let value = "\"\n".repeat(100);
        let bytes = encode(&value, 1000, deadline, &token).unwrap();
        assert!(bytes.len() > value.len());
        assert_eq!(
            encode(&value, bytes.len() - 1, deadline, &token),
            Err(CommandError::OutputLimitExceeded)
        );
        assert_eq!(
            encode(&value, bytes.len(), deadline, &token).unwrap(),
            bytes
        );
        token.cancel();
        assert_eq!(
            encode(&value, 1000, deadline, &token),
            Err(CommandError::Cancelled)
        );
        assert_eq!(
            encode(
                &value,
                1000,
                Instant::now() - Duration::from_secs(1),
                &CancellationToken::default()
            ),
            Err(CommandError::DeadlineExceeded)
        );
    }
    #[test]
    fn identity_and_limits_reject_path_or_oversized_echo() {
        assert!(ToolIdentity::from_executable_sha256("/private/raw.trace".to_owned()).is_err());
        let valid = CommandLimits {
            timeout_ms: 30000,
            max_rows: 128,
            max_events: 128,
            max_output_bytes: 8388608,
        };
        assert!(valid.validate().is_ok());
        for invalid in [
            CommandLimits {
                timeout_ms: 99,
                ..valid
            },
            CommandLimits {
                max_rows: 100001,
                ..valid
            },
            CommandLimits {
                max_output_bytes: 1023,
                ..valid
            },
            CommandLimits {
                max_events: 0,
                ..valid
            },
        ] {
            assert_eq!(invalid.validate(), Err(CommandError::InvalidArguments));
        }
    }
}
