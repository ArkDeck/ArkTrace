//! Reviewed real-trace cold-open diagnostics through the production Engine.
//! Internal closed error variants are recorded without paths or SQLite prose.
#[cfg(target_os = "macos")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use arktrace_contract::TraceParserIdentity;
    use arktrace_engine::{EngineBudget, ParserTools, SourceFormat, open_no_cache};
    use arktrace_platform::{
        CancellationToken, CodeTrustPolicy, HeldDirectory, HeldFile, IoBudget, VerifiedExecutable,
    };
    use std::{
        path::Path,
        time::{Duration, Instant},
    };

    let args = std::env::args_os().skip(1).collect::<Vec<_>>();
    if !(4..=5).contains(&args.len()) {
        return Err("private root, reviewed source, parser identity, helper pin, optional database byte limit required".into());
    }
    let maximum_database_bytes = match args.get(4) {
        Some(value) => value
            .to_str()
            .ok_or("invalid database limit")?
            .parse::<u64>()?,
        None => arktrace_engine::DEFAULT_MAXIMUM_DATABASE_BYTES,
    };
    let root = HeldDirectory::open_private(Path::new(&args[0]))?;
    let identity: TraceParserIdentity =
        serde_json::from_str(args[2].to_str().ok_or("invalid identity")?)?;
    let started = Instant::now();
    let deadline = started + Duration::from_secs(15 * 60);
    let cancellation = CancellationToken::default();
    let io = IoBudget {
        maximum_bytes: 2 * 1024 * 1024 * 1024,
        deadline,
        cancellation: cancellation.clone(),
    };
    let tools = root.open_private_child("tools")?;
    let helper = VerifiedExecutable::verify(
        tools.open_file("host-process")?,
        args[3].to_str().ok_or("invalid helper pin")?,
        CodeTrustPolicy::DevelopmentPinned,
        &io,
    )?;
    let parser = VerifiedExecutable::verify(
        tools.open_file("trace-streamer")?,
        &identity.binary_sha256,
        CodeTrustPolicy::DevelopmentPinned,
        &io,
    )?;
    let source = HeldFile::open_explicit_source(Path::new(&args[1]))?;
    let before = source.facts(&io)?;
    let workspace = root.ensure_private_child("cold-open")?;
    let budget = EngineBudget {
        maximum_source_bytes: io.maximum_bytes,
        maximum_database_bytes,
        deadline,
        cancellation,
    };
    let outcome = open_no_cache(
        &source,
        SourceFormat::Htrace,
        &ParserTools {
            helper: &helper,
            parser: &parser,
            identity,
        },
        &workspace,
        &budget,
        |event| {
            println!(
                "{}",
                serde_json::json!({
                    "event": event, "elapsedSeconds": started.elapsed().as_secs_f64(),
                })
            )
        },
    );
    match outcome {
        Ok(session) => {
            session.verify(&budget)?;
            println!(
                "{}",
                serde_json::json!({
                    "sourceSHA256": before.sha256, "sourceByteCount": before.byte_count,
                    "coldOpenSucceeded": true,
                    "maximumDatabaseBytes": maximum_database_bytes,
                    "metadata": session.metadata(),
                    "elapsedSeconds": started.elapsed().as_secs_f64(),
                })
            );
            session.close()?;
        }
        Err(error) => {
            println!(
                "{}",
                serde_json::json!({
                    "sourceSHA256": before.sha256, "sourceByteCount": before.byte_count,
                    "coldOpenSucceeded": false,
                    "maximumDatabaseBytes": maximum_database_bytes,
                    "error": error, "elapsedSeconds": started.elapsed().as_secs_f64(),
                })
            );
            return Err(error.into());
        }
    }
    assert_eq!(source.facts(&io)?, before, "original source changed");
    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("native macOS required; no simulated acceptance");
    std::process::exit(2);
}
