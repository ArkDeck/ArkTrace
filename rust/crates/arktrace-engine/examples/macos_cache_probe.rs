#[cfg(target_os = "macos")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use arktrace_contract::{ProcessQuery, TraceParserIdentity};
    use arktrace_engine::{
        EngineBudget, EngineFailure, EngineProgress, ParserTools, SourceFormat, open_cached,
    };
    use arktrace_platform::{
        CancellationToken, CodeTrustPolicy, HeldDirectory, HeldFile, IoBudget, Lease, LeaseMode,
        OwnerStore, VerifiedExecutable,
    };
    use std::{
        fs,
        path::Path,
        time::{Duration, Instant},
    };
    let args = std::env::args_os().skip(1).collect::<Vec<_>>();
    if args.len() != 5 {
        return Err(
            "private root, source, identity JSON, helper pin, source format required".into(),
        );
    }
    let root = HeldDirectory::open_private(Path::new(&args[0]))?;
    let source = HeldFile::open_explicit_source(Path::new(&args[1]))?;
    let identity: TraceParserIdentity =
        serde_json::from_str(args[2].to_str().ok_or("invalid identity")?)?;
    let format = match args[4].to_str() {
        Some("htrace") => SourceFormat::Htrace,
        Some("systrace") => SourceFormat::Systrace,
        _ => return Err("invalid format".into()),
    };
    let io = || IoBudget {
        maximum_bytes: 256 * 1024 * 1024,
        deadline: Instant::now() + Duration::from_secs(120),
        cancellation: CancellationToken::default(),
    };
    let budget = || EngineBudget {
        maximum_source_bytes: 256 * 1024 * 1024,
        maximum_database_bytes: 256 * 1024 * 1024,
        deadline: Instant::now() + Duration::from_secs(120),
        cancellation: CancellationToken::default(),
    };
    let tool_root = root.open_private_child("tools")?;
    let helper = VerifiedExecutable::verify(
        tool_root.open_file("helper")?,
        args[3].to_str().ok_or("invalid helper pin")?,
        CodeTrustPolicy::DevelopmentPinned,
        &io(),
    )?;
    let parser = VerifiedExecutable::verify(
        tool_root.open_file("parser")?,
        &identity.binary_sha256,
        CodeTrustPolicy::DevelopmentPinned,
        &io(),
    )?;
    let tools = ParserTools {
        helper: &helper,
        parser: &parser,
        identity,
    };
    let cache = root.create_private_child("cache")?;
    let before = source.facts(&io())?;
    let mut cold_progress = vec![];
    let first = open_cached(&source, format, &tools, &cache, &budget(), |p| {
        cold_progress.push(p)
    })?;
    assert!(!first.cache_hit() && cold_progress.contains(&EngineProgress::Parsing));
    let query = ProcessQuery {
        process_key: None,
        pid: None,
        name: None,
        name_match: arktrace_contract::DirectoryNameMatch::Exact,
        limit: 100,
    };
    let original_page = serde_json::to_value(first.processes(&query, &budget())?)?;
    let metadata = first.metadata().clone();
    let key = metadata.cache_key.clone();
    let directory = cache
        .open_private_child(key.trace_sha256())?
        .open_private_child(key.parser_key())?;
    let database_before = directory.open_file("trace.sqlite")?.facts(&io())?;
    std::thread::sleep(Duration::from_secs(1));
    let mut warm_progress = vec![];
    let second = open_cached(&source, format, &tools, &cache, &budget(), |p| {
        warm_progress.push(p)
    })?;
    assert!(
        second.cache_hit()
            && !warm_progress.contains(&EngineProgress::Parsing)
            && !warm_progress.contains(&EngineProgress::ParserIdentity)
    );
    assert_eq!(second.metadata().created_at, metadata.created_at);
    assert!(second.metadata().last_accessed_at > metadata.last_accessed_at);
    assert_eq!(
        serde_json::to_value(first.processes(&query, &budget())?)?,
        original_page
    );
    first.verify(&budget())?;
    second.verify(&budget())?;
    let mut too_small = budget();
    too_small.maximum_database_bytes = 1;
    assert!(open_cached(&source, format, &tools, &cache, &too_small, |_| {}).is_err());
    assert_eq!(
        directory.open_file("trace.sqlite")?.facts(&io())?,
        database_before
    );
    first.verify(&budget())?;
    second.verify(&budget())?;
    assert!(!cache.path().join(".corrupt").exists());
    let leases = cache.open_private_child(".leases")?;
    let lease_name = format!("{}.lease", key.entry_identifier());
    assert!(Lease::try_acquire(&leases, &lease_name, LeaseMode::Exclusive, false)?.is_none());
    directory.write_new_readonly("view-state.json", b"{\"fixtureUserState\":true}", &io())?;
    let current = directory.open_file("metadata.json")?;
    let saved = current.read_bounded(&io())?;
    let mut corrupt: serde_json::Value = serde_json::from_slice(&saved)?;
    corrupt["databaseByteCount"] = serde_json::json!(0);
    let corrupt_bytes = serde_json::to_vec(&corrupt)?;
    directory.replace_readonly(&current, &corrupt_bytes, &io())?;
    let started = Instant::now();
    let error = match open_cached(&source, format, &tools, &cache, &budget(), |_| {}) {
        Ok(_) => return Err("active corrupt cache admitted".into()),
        Err(e) => e,
    };
    assert_eq!(error.failure, EngineFailure::CacheBusy);
    assert!(started.elapsed() < Duration::from_secs(5));
    assert_eq!(
        directory.open_file("metadata.json")?.read_bounded(&io())?,
        corrupt_bytes
    );
    assert_eq!(
        directory.open_file("trace.sqlite")?.facts(&io())?,
        database_before
    );
    first.close()?;
    second.close()?;
    assert!(directory.path().join("trace.sqlite").exists());
    let mut rebuild_progress = vec![];
    let rebuilt = open_cached(&source, format, &tools, &cache, &budget(), |p| {
        rebuild_progress.push(p)
    })?;
    assert!(!rebuilt.cache_hit() && rebuild_progress.contains(&EngineProgress::Parsing));
    assert_eq!(
        serde_json::to_value(rebuilt.processes(&query, &budget())?)?,
        original_page
    );
    rebuilt.close()?;
    let corrupt_root = cache.open_private_child(".corrupt")?;
    let quarantine_entries = fs::read_dir(corrupt_root.path())?.collect::<Result<Vec<_>, _>>()?;
    assert_eq!(quarantine_entries.len(), 1);
    let quarantined = corrupt_root.open_private_child(
        quarantine_entries[0]
            .file_name()
            .to_str()
            .ok_or("invalid quarantine name")?,
    )?;
    assert_eq!(
        quarantined
            .open_file("metadata.json")?
            .read_bounded(&io())?,
        corrupt_bytes
    );
    assert_eq!(
        quarantined
            .open_file("view-state.json")?
            .read_bounded(&io())?,
        b"{\"fixtureUserState\":true}"
    );
    assert_eq!(
        quarantined.open_file("trace.sqlite")?.facts(&io())?,
        database_before
    );
    let directory = cache
        .open_private_child(key.trace_sha256())?
        .open_private_child(key.parser_key())?;
    let current = directory.open_file("metadata.json")?;
    let valid = current.read_bounded(&io())?;
    let mut future: serde_json::Value = serde_json::from_slice(&valid)?;
    future["formatVersion"] = serde_json::json!(999);
    let future_bytes = serde_json::to_vec(&future)?;
    directory.replace_readonly(&current, &future_bytes, &io())?;
    let error = match open_cached(&source, format, &tools, &cache, &budget(), |_| {}) {
        Ok(_) => return Err("future metadata admitted".into()),
        Err(e) => e,
    };
    assert_eq!(error.failure, EngineFailure::CacheUnsupported);
    assert_eq!(
        directory.open_file("metadata.json")?.read_bounded(&io())?,
        future_bytes
    );
    assert_eq!(fs::read_dir(corrupt_root.path())?.count(), 1);
    directory.replace_readonly(&directory.open_file("metadata.json")?, &valid, &io())?;
    let third = open_cached(&source, format, &tools, &cache, &budget(), |_| {})?;
    assert!(third.cache_hit());
    third.close()?;
    let mut cancelled = vec![];
    for phase in [EngineProgress::Publishing, EngineProgress::OpeningDatabase] {
        let isolated = root.create_private_child(if phase == EngineProgress::Publishing {
            "cancel-before-publication"
        } else {
            "cancel-after-publication"
        })?;
        let b = budget();
        let error = match open_cached(&source, format, &tools, &isolated, &b, |p| {
            if p == phase {
                b.cancellation.cancel();
            }
        }) {
            Ok(_) => return Err("cancelled opening admitted".into()),
            Err(e) => e,
        };
        assert_eq!(
            error.public_error().code(),
            arktrace_contract::Code::Cancelled
        );
        let owners = OwnerStore::open(&isolated.open_private_child(".staging")?, &isolated)?;
        assert!(owners.identifiers(&io())?.is_empty());
        assert!(
            !isolated
                .path()
                .join(key.trace_sha256())
                .join(key.parser_key())
                .exists()
        );
        assert_eq!(fs::read_dir(isolated.path().join(".leases"))?.count(), 1);
        cancelled.push(phase);
    }
    assert_eq!(source.facts(&io())?, before);
    let stage = cache.open_private_child(".staging")?;
    let owners = OwnerStore::open(&stage, &cache)?;
    assert_eq!(owners.identifiers(&io())?.len(), 2); // Ready + preserved quarantine proof.
    assert_eq!(fs::read_dir(stage.path())?.count(), 1); // Only .owners.
    assert_eq!(fs::read_dir(leases.path())?.count(), 1);
    println!(
        "{}",
        serde_json::json!({"coldProgress":cold_progress,"warmProgress":warm_progress,"rebuildProgress":rebuild_progress,
        "coldParsed":true,"warmDidNotParse":true,"warmTimestampAdvanced":true,"concurrentSessionSurvivesTouch":true,
        "closePreservesReady":true,"exclusiveLeaseBlockedByReaders":true,"activeCorruptionBoundedBusy":true,"lowDatabaseBudgetPreservesReady":true,
        "corruptionQuarantinedWithUserSidecar":true,"futureFormatPreserved":true,"cancelledPhases":cancelled,
        "stableLeaseCount":1,"ownerProofCount":2,"stagingPayloadCount":0,"rawSourceUnchanged":true,
        "sourceSHA256":before.sha256,"sourceBytes":before.byte_count,"databaseSHA256":database_before.sha256,"databaseBytes":database_before.byte_count,
        "processPage":original_page,"fullCacheAcceptance":false,"appCutover":false})
    );
    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("macOS cache probe requires a native macOS runner");
}
