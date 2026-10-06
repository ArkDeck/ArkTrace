//! Read-only catalog diagnostics on an already prepared immutable database.
#[cfg(target_os = "macos")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use arktrace_contract::{
        CounterSeriesQuery, CpuCatalogQuery, CpuSliceQuery, DirectoryNameMatch, ThreadQuery,
        ThreadStateQuery, TraceDensityQuery, TraceDensitySource, TraceSliceQuery, TraceTimeRange,
    };
    use arktrace_platform::{CancellationToken, HeldDirectory};
    use arktrace_store::{StoreReader, ValidationBudget};
    use std::{
        path::Path,
        sync::Arc,
        time::{Duration, Instant},
    };

    let args = std::env::args_os().skip(1).collect::<Vec<_>>();
    if args.len() != 1 {
        return Err("prepared immutable database required".into());
    }
    let path = Path::new(&args[0]);
    let parent = HeldDirectory::open_private(path.parent().ok_or("database parent required")?)?;
    let name = path
        .file_name()
        .and_then(|v| v.to_str())
        .ok_or("database name required")?;
    let snapshot = Arc::new(parent.open_file(name)?);
    let budget = || ValidationBudget {
        maximum_database_bytes: arktrace_engine::DEFAULT_MAXIMUM_DATABASE_BYTES,
        deadline: Instant::now() + Duration::from_secs(300),
        cancellation: CancellationToken::default(),
    };
    let started = Instant::now();
    let reader = StoreReader::open(snapshot.clone(), &budget())?;
    println!(
        "{}",
        serde_json::json!({"readerOpenedSeconds":started.elapsed().as_secs_f64(), "inspection":reader.inspection()})
    );
    let range = TraceTimeRange::query(0, reader.inspection().duration_ns)
        .map_err(|_| "invalid trace range")?;
    let started = Instant::now();
    let cpu = reader.cpu_catalog(
        &CpuCatalogQuery {
            range,
            limit: 4096,
            activity_limit: 20_000,
        },
        &budget(),
    );
    let cpu_ids = cpu
        .as_ref()
        .map(|value| {
            value
                .cpus
                .items
                .iter()
                .map(|item| item.cpu)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    println!(
        "{}",
        serde_json::json!({"operation":"cpuCatalog", "elapsedSeconds":started.elapsed().as_secs_f64(), "result":cpu.map(|value| (value.cpus.items.len(), value.cpus.truncated, value.activity.items.len(), value.activity.truncated))})
    );
    let started = Instant::now();
    let threads = reader.threads(
        &ThreadQuery {
            process_key: None,
            pid: None,
            thread_key: None,
            tid: None,
            name: None,
            name_match: DirectoryNameMatch::Exact,
            limit: 1000,
        },
        &budget(),
    );
    println!(
        "{}",
        serde_json::json!({"operation":"threads", "elapsedSeconds":started.elapsed().as_secs_f64(), "result":threads.map(|value| (value.items.len(),value.truncated))})
    );
    let started = Instant::now();
    let counters = reader.counter_series(&CounterSeriesQuery { range, limit: 2000 }, &budget());
    println!(
        "{}",
        serde_json::json!({"operation":"counterSeries", "elapsedSeconds":started.elapsed().as_secs_f64(), "result":counters.map(|value| (value.items.len(),value.truncated))})
    );
    for cpu in cpu_ids {
        let started = Instant::now();
        let density = reader.density(
            &TraceDensityQuery {
                range,
                source: TraceDensitySource::Cpu { cpu },
                bucket_count: 300,
            },
            &budget(),
        );
        println!(
            "{}",
            serde_json::json!({"operation":"cpuDensity", "cpu":cpu,
                "elapsedSeconds":started.elapsed().as_secs_f64(),
                "result":density.map(|value| (value.buckets.len(),
                    value.buckets.iter().map(|bucket| bucket.event_count).sum::<i64>()))})
        );
    }
    // Match the viewer's three independent, bounded range-analysis pages.
    // Keep both the prescribed short range and a later GUI selection: a short
    // result does not imply a short scan through earlier trace history.
    for (start, end) in [
        (10_100_000_000, 10_300_000_000),
        (40_554_000_000, 40_720_000_000),
    ] {
        let range = TraceTimeRange::query(start, end).map_err(|_| "invalid analysis range")?;
        let started = Instant::now();
        let result = reader.cpu_slices(
            &CpuSliceQuery {
                range,
                cpu: None,
                process_key: None,
                pid: None,
                thread_key: None,
                tid: None,
                limit: 20_000,
            },
            &budget(),
        );
        println!(
            "{}",
            serde_json::json!({"operation":"rangeCpuSlices", "range":range,
            "elapsedSeconds":started.elapsed().as_secs_f64(),
            "result":result.map(|value| (value.items.len(), value.truncated))})
        );
        let started = Instant::now();
        let result = reader.thread_states(
            &ThreadStateQuery {
                range,
                cpu: None,
                process_key: None,
                pid: None,
                thread_key: None,
                tid: None,
                raw_state: None,
                state: None,
                limit: 20_000,
            },
            &budget(),
        );
        println!(
            "{}",
            serde_json::json!({"operation":"rangeThreadStates", "range":range,
            "elapsedSeconds":started.elapsed().as_secs_f64(),
            "result":result.map(|value| (value.items.len(), value.truncated))})
        );
        let started = Instant::now();
        let result = reader.slices(
            &TraceSliceQuery {
                range,
                event_key: None,
                process_key: None,
                pid: None,
                thread_key: None,
                tid: None,
                unattributed_only: false,
                name: None,
                name_match: DirectoryNameMatch::Exact,
                minimum_duration_ns: Some(0),
                depth: None,
                includes_argument_set: false,
                limit: 20_000,
            },
            &budget(),
        );
        println!(
            "{}",
            serde_json::json!({"operation":"rangeNamedSlices", "range":range,
            "elapsedSeconds":started.elapsed().as_secs_f64(),
            "result":result.map(|value| (value.items.len(), value.truncated))})
        );
    }
    snapshot.verify()?;
    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("native macOS required; no simulated acceptance");
    std::process::exit(2);
}
