#[cfg(target_os = "macos")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use arktrace_contract::{
        DirectoryNameMatch, EventKey, TraceArgumentQuery, TraceParserIdentity, TraceSliceQuery,
        TraceTimeRange,
    };
    use arktrace_engine::{
        EngineBudget, EngineFailure, EngineStage, ParserTools, SourceFormat, open_no_cache,
    };
    use arktrace_platform::{
        CancellationToken, CodeTrustPolicy, HeldDirectory, HeldFile, HostError, IoBudget,
        OwnerStore, VerifiedExecutable,
    };
    use arktrace_store::StoreError;
    use serde::Deserialize;
    use std::{
        fs,
        path::Path,
        process::Command,
        time::{Duration, Instant},
    };
    #[derive(Deserialize, serde::Serialize)]
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
    struct Case {
        fixture: String,
        id: String,
        query: TraceArgumentQuery,
        lookup: Option<Lookup>,
    }
    #[derive(Deserialize, serde::Serialize)]
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
    struct Lookup {
        range: TraceTimeRange,
        event_key: EventKey,
    }
    #[derive(Deserialize, serde::Serialize)]
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
    struct SampleSets {
        sampled_rows: usize,
        prefix_truncated: bool,
        sets: Vec<i64>,
    }
    let slice_query = |lookup: &Lookup, include| TraceSliceQuery {
        range: lookup.range,
        event_key: Some(lookup.event_key),
        unattributed_only: false,
        includes_argument_set: include,
        process_key: None,
        pid: None,
        thread_key: None,
        tid: None,
        name: None,
        name_match: DirectoryNameMatch::Exact,
        minimum_duration_ns: None,
        depth: None,
        limit: 1,
    };
    let args = std::env::args_os().skip(1).collect::<Vec<_>>();
    if args.len() != 6 {
        return Err(
            "owned root, fixtures, identity, helper pin, cases, Swift probe required".into(),
        );
    }
    let root = HeldDirectory::open_private(Path::new(&args[0]))?;
    let fixtures = Path::new(&args[1]);
    let identity: TraceParserIdentity = serde_json::from_str(args[2].to_str().ok_or("identity")?)?;
    let input = args[4].to_str().ok_or("cases")?;
    if input.len() > 65536 {
        return Err("case byte budget".into());
    }
    let cases: Vec<Case> = serde_json::from_str(input)?;
    if cases.is_empty()
        || cases.len() > 64
        || cases.iter().any(|c| c.id.len() > 128 || c.query.limit > 64)
    {
        return Err("case budget".into());
    }
    let io = || IoBudget {
        maximum_bytes: 256 * 1024 * 1024,
        deadline: Instant::now() + Duration::from_secs(60),
        cancellation: CancellationToken::default(),
    };
    let tool_root = root.open_private_child("tools")?;
    let helper = VerifiedExecutable::verify(
        tool_root.open_file("host-process")?,
        args[3].to_str().ok_or("helper pin")?,
        CodeTrustPolicy::DevelopmentPinned,
        &io(),
    )?;
    let parser = VerifiedExecutable::verify(
        tool_root.open_file("trace-streamer")?,
        &identity.binary_sha256,
        CodeTrustPolicy::DevelopmentPinned,
        &io(),
    )?;
    let tools = ParserTools {
        helper: &helper,
        parser: &parser,
        identity,
    };
    let workspace = root.create_private_child("arguments-no-cache")?;
    let budget = || EngineBudget {
        maximum_source_bytes: 256 * 1024 * 1024,
        maximum_database_bytes: 256 * 1024 * 1024,
        deadline: Instant::now() + Duration::from_secs(30),
        cancellation: CancellationToken::default(),
    };
    let mut results = Vec::new();
    let mut negatives = Vec::new();
    let mut sources = Vec::new();
    for fixture in [
        "zlib.htrace",
        "hiprofiler_data_ability.htrace",
        "trace_small_10.systrace",
    ] {
        let source = HeldFile::open_explicit_source(&fixtures.join(fixture))?;
        let original = source.facts(&io())?;
        let format = if fixture.ends_with(".systrace") {
            SourceFormat::Systrace
        } else {
            SourceFormat::Htrace
        };
        let session = open_no_cache(&source, format, &tools, &workspace, &budget(), |_| {})?;
        let mut selected = cases
            .iter()
            .filter(|c| c.fixture == fixture)
            .collect::<Vec<_>>();
        if selected.is_empty() {
            return Err("missing fixture".into());
        }
        let range =
            TraceTimeRange::query(0, session.inspection().duration_ns).map_err(|_| "range")?;
        let base = TraceSliceQuery {
            range,
            event_key: None,
            process_key: None,
            pid: None,
            thread_key: None,
            tid: None,
            name: None,
            name_match: DirectoryNameMatch::Exact,
            minimum_duration_ns: None,
            depth: None,
            unattributed_only: false,
            includes_argument_set: true,
            limit: 128,
        };
        let slices = session.slices(&base, &budget())?;
        let mut lookup_cases = Vec::new();
        for (index, slice) in slices
            .items
            .iter()
            .filter(|v| v.arg_set_id.is_some())
            .take(3)
            .enumerate()
        {
            lookup_cases.push(Case {
                fixture: fixture.into(),
                id: format!("{fixture}/inspector/{index}"),
                query: TraceArgumentQuery {
                    arg_set_id: slice.arg_set_id.ok_or("handle")?,
                    limit: 64,
                },
                lookup: Some(Lookup {
                    range,
                    event_key: slice.key,
                }),
            });
        }
        selected.extend(lookup_cases.iter());
        // This test-only subprocess reads the same immutable Ready inode while
        // Engine retains its lease. Production queries never accept a DB path.
        let ready = fs::read_dir(workspace.path().join(".ready"))?
            .next()
            .ok_or("Ready absent")??
            .path()
            .join("trace.db");
        let sampled = Command::new(&args[5])
            .args([
                ready.as_os_str(),
                args[2].as_os_str(),
                std::ffi::OsStr::new(&serde_json::to_string(
                    &serde_json::json!({"sha256":original.sha256,"byteCount":original.byte_count}),
                )?),
                std::ffi::OsStr::new("--sample-sets"),
            ])
            .output()?;
        if !sampled.status.success() || sampled.stdout.len() > 65536 {
            return Err("bounded Swift argument set sample failed".into());
        }
        let sampled: SampleSets = serde_json::from_slice(&sampled.stdout)?;
        if sampled.sampled_rows > 128
            || sampled.sets.len() > 3
            || !sampled.sets.windows(2).all(|w| w[0] < w[1])
        {
            return Err("argument sample shape".into());
        }
        let sampled_cases = sampled
            .sets
            .iter()
            .enumerate()
            .map(|(index, id)| Case {
                fixture: fixture.into(),
                id: format!("{fixture}/actual-argument-set/{index}"),
                query: TraceArgumentQuery {
                    arg_set_id: *id,
                    limit: 64,
                },
                lookup: None,
            })
            .collect::<Vec<_>>();
        selected.extend(sampled_cases.iter());
        let swift = Command::new(&args[5])
            .args([
                ready.as_os_str(),
                args[2].as_os_str(),
                std::ffi::OsStr::new(&serde_json::to_string(
                    &serde_json::json!({"sha256":original.sha256,"byteCount":original.byte_count}),
                )?),
                std::ffi::OsStr::new(&serde_json::to_string(&selected)?),
            ])
            .output()?;
        if !swift.status.success() {
            return Err(format!(
                "Swift oracle failed: {}",
                String::from_utf8_lossy(&swift.stderr)
            )
            .into());
        }
        if swift.stdout.len() > 8 * 1024 * 1024 {
            return Err("Swift output byte budget".into());
        }
        let oracle: Vec<serde_json::Value> = serde_json::from_slice(&swift.stdout)?;
        if oracle.len() != selected.len() {
            return Err("Swift case budget".into());
        }
        for (case, expected) in selected.iter().zip(oracle) {
            let mut row = serde_json::json!({"id":case.id,"fixture":fixture,"query":case.query,"page":session.arguments(&case.query,&budget())?});
            let mut fields = vec!["id", "page"];
            if let Some(lookup) = &case.lookup {
                let plain = session.slices(&slice_query(lookup, false), &budget())?;
                let requested = session.slices(&slice_query(lookup, true), &budget())?;
                assert_eq!(
                    requested.items.first().and_then(|v| v.arg_set_id),
                    Some(case.query.arg_set_id)
                );
                row["unrequestedHandles"] = serde_json::to_value(
                    plain.items.iter().map(|v| v.arg_set_id).collect::<Vec<_>>(),
                )?;
                row["requestedHandles"] = serde_json::to_value(
                    requested
                        .items
                        .iter()
                        .map(|v| v.arg_set_id)
                        .collect::<Vec<_>>(),
                )?;
                fields.extend(["unrequestedHandles", "requestedHandles"]);
            }
            for field in fields {
                if row[field] != expected[field] {
                    eprintln!(
                        "{}",
                        serde_json::json!({"case":case.id,"field":field,"rust":row,"swift":expected})
                    );
                    return Err("argument parity".into());
                }
            }
            results.push(serde_json::json!({"rust":row,"swift":expected,"parity":"T0"}));
        }
        let good = selected[0].query.clone();
        let expected = session.arguments(&good, &budget())?;
        for scenario in [
            "cancelled",
            "deadline",
            "database-budget",
            "invalid-limit",
            "over-limit",
        ] {
            let mut b = budget();
            let mut q = good.clone();
            let failure = match scenario {
                "cancelled" => {
                    b.cancellation.cancel();
                    EngineFailure::Host(HostError::Cancelled)
                }
                "deadline" => {
                    b.deadline = Instant::now() - Duration::from_millis(1);
                    EngineFailure::Host(HostError::DeadlineExceeded)
                }
                "database-budget" => {
                    b.maximum_database_bytes = 1;
                    EngineFailure::Store(StoreError::Host(HostError::LimitExceeded))
                }
                _ => {
                    q.limit = if scenario == "invalid-limit" { 0 } else { 65 };
                    EngineFailure::Store(StoreError::InvalidQuery)
                }
            };
            let error = session.arguments(&q, &b).unwrap_err();
            assert_eq!(error.stage, EngineStage::Querying);
            assert_eq!(error.failure, failure);
            assert_eq!(session.arguments(&good, &budget())?, expected);
            negatives.push(serde_json::json!({"fixture":fixture,"scenario":scenario,"error":error,"publicError":error.public_error(),"nextRequestUnchanged":true}));
        }
        let inspection = session.inspection().clone();
        session.close()?;
        assert_eq!(fs::read_dir(workspace.path().join(".ready"))?.count(), 0);
        assert_eq!(fs::read_dir(workspace.path().join(".leases"))?.count(), 0);
        let staging = workspace.open_private_child(".staging")?;
        assert!(
            OwnerStore::open(&staging, &workspace)?
                .identifiers(&io())?
                .is_empty()
        );
        assert_eq!(source.facts(&io())?, original);
        sources.push(serde_json::json!({"fixture":fixture,"source":{"sha256":original.sha256,"byteCount":original.byte_count},"inspection":inspection,"boundedInspectorScan":{"slices":slices.items.len(),"slicePageTruncated":slices.truncated,"slicesWithArgumentHandle":slices.items.iter().filter(|s|s.arg_set_id.is_some()).count(),"actualLookupsCompared":lookup_cases.len()},"boundedArgumentTableScan":sampled,"rawBytesUnchanged":true,"explicitCloseRemovedReadyOwnersAndLeases":true}));
    }
    println!(
        "{}",
        serde_json::json!({"results":results,"negativeCases":negatives,"sources":sources,"developmentTrustOnly":true,"readyAcceptance":false,"productionCliReplacement":false})
    );
    Ok(())
}
#[cfg(not(target_os = "macos"))]
fn main() {
    panic!("native macOS required; no simulated PASS");
}
