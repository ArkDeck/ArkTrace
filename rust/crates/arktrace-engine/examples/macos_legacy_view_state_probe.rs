#[cfg(target_os = "macos")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use arktrace_contract::TraceParserIdentity;
    use arktrace_engine::{
        EngineBudget, LegacyViewStateMigration, ParserTools, SourceFormat, open_cached,
    };
    use arktrace_platform::{
        CancellationToken, CodeTrustPolicy, HeldDirectory, HeldFile, IoBudget, VerifiedExecutable,
    };
    use std::{
        path::Path,
        time::{Duration, Instant},
    };
    let args = std::env::args_os().skip(1).collect::<Vec<_>>();
    if args.len() != 8 {
        return Err("private case root, source, identity file, helper pin, format, tools root, selection, interruption point required".into());
    }
    let root = HeldDirectory::open_private(Path::new(&args[0]))?;
    let source = HeldFile::open_explicit_source(Path::new(&args[1]))?;
    let identity: TraceParserIdentity = serde_json::from_slice(&std::fs::read(&args[2])?)?;
    let io = || IoBudget {
        maximum_bytes: 256 * 1024 * 1024,
        deadline: Instant::now() + Duration::from_secs(60),
        cancellation: CancellationToken::default(),
    };
    let budget = || EngineBudget {
        maximum_source_bytes: 256 * 1024 * 1024,
        maximum_database_bytes: 256 * 1024 * 1024,
        deadline: Instant::now() + Duration::from_secs(60),
        cancellation: CancellationToken::default(),
    };
    let tools_root = HeldDirectory::open_private(Path::new(&args[5]))?;
    let helper = VerifiedExecutable::verify(
        tools_root.open_file("helper")?,
        args[3].to_str().ok_or("invalid helper pin")?,
        CodeTrustPolicy::DevelopmentPinned,
        &io(),
    )?;
    let parser = VerifiedExecutable::verify(
        tools_root.open_file("parser")?,
        &identity.binary_sha256,
        CodeTrustPolicy::DevelopmentPinned,
        &io(),
    )?;
    let tools = ParserTools {
        helper: &helper,
        parser: &parser,
        identity,
    };
    let format = match args[4].to_str() {
        Some("htrace") => SourceFormat::Htrace,
        Some("systrace") => SourceFormat::Systrace,
        _ => return Err("invalid format".into()),
    };
    let selection = match args[6].to_str() {
        Some("-") => None,
        Some(value) => Some(value),
        None => return Err("invalid selection".into()),
    };
    let point: u8 = args[7].to_str().ok_or("invalid point")?.parse()?;
    let cache = root.ensure_private_child("native")?;
    let backup = root.ensure_private_child("migration-backup")?;
    let migration = LegacyViewStateMigration::new(
        root.open_private_child("legacy")?,
        cache.clone(),
        backup,
        &io(),
    )?;
    let before = source.facts(&io())?;
    let session = open_cached(&source, format, &tools, &cache, &budget(), |p| {
        eprintln!("MIGRATION_PROGRESS={p:?}")
    })?;
    let metadata = session.metadata().clone();
    let cache_hit = session.cache_hit();
    if point != 0 {
        #[cfg(feature = "process-fixtures")]
        LegacyViewStateMigration::development_pause_next_import(point)?;
        #[cfg(not(feature = "process-fixtures"))]
        return Err("interruption requires development fixtures".into());
    }
    let result = session
        .migrate_legacy_view_state(&migration, selection, &budget())
        .map(|report| (report, session.read_view_state(&budget())));
    session.close()?;
    let (report, view_state) = result?;
    let after = source.facts(&io())?;
    assert_eq!(before, after);
    println!(
        "{}",
        serde_json::to_string(
            &serde_json::json!({"cacheHit":cache_hit,"metadata":metadata,
        "report":report,"viewState":view_state?,"sourceFacts":{"sha256":before.sha256,"byteCount":before.byte_count},"rawTraceUnchanged":true,"resourcesClosed":true})
        )?
    );
    Ok(())
}
#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("native macOS legacy-state probe unavailable");
}
