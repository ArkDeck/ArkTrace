//! Development-only comparison against independently frozen Swift databases.
//! Prepares an owned indexed copy; the source remains immutable throughout.
#[cfg(target_os = "macos")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use arktrace_contract::TraceSummaryQuery;
    use arktrace_platform::{CancellationToken, HeldDirectory, IoBudget, OwnerKind, OwnerStore};
    use arktrace_store::{StoreReader, ValidationBudget, inspect_snapshot, prepare_snapshot};
    use serde::Deserialize;
    use std::{
        path::PathBuf,
        sync::Arc,
        time::{Duration, Instant},
    };
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
    struct Request {
        id: String,
        query: TraceSummaryQuery,
        expired: bool,
        cancelled: bool,
    }
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
    struct Fixture {
        id: String,
        file: String,
        requests: Vec<Request>,
    }
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
    struct Input {
        fixtures: Vec<Fixture>,
    }
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.len() != 2 {
        return Err("expected owned root and input JSON".into());
    }
    let root = HeldDirectory::open_private(&PathBuf::from(&args[0]))?;
    let input: Input = serde_json::from_slice(&std::fs::read(&args[1])?)?;
    let owners = OwnerStore::open(
        &HeldDirectory::open_private(&root.path().join("stage"))?,
        &root,
    )?;
    let mut records = Vec::new();
    let mut sources = Vec::new();
    for fixture in input.fixtures {
        let source = root.open_file(&fixture.file)?;
        let budget = ValidationBudget {
            maximum_database_bytes: 256 * 1024 * 1024,
            deadline: Instant::now() + Duration::from_secs(30),
            cancellation: CancellationToken::default(),
        };
        let io = IoBudget {
            maximum_bytes: budget.maximum_database_bytes,
            deadline: budget.deadline,
            cancellation: budget.cancellation.clone(),
        };
        let before = source.facts(&io)?;
        let original = inspect_snapshot(&source, &budget)?;
        let mut building = owners.create(OwnerKind::Building, &io)?;
        let prepared =
            prepare_snapshot(&source, building.directory(), "indexed.db", &budget, |_| {})?;
        if prepared.preparation.inspection != original {
            return Err("preparation changed semantic inspection".into());
        }
        let reader = StoreReader::open(Arc::new(prepared.snapshot), &budget)?;
        for request in fixture.requests {
            let token = CancellationToken::default();
            if request.cancelled {
                token.cancel();
            }
            let request_budget = ValidationBudget {
                maximum_database_bytes: budget.maximum_database_bytes,
                deadline: if request.expired {
                    Instant::now() - Duration::from_secs(1)
                } else {
                    Instant::now() + Duration::from_secs(30)
                },
                cancellation: token,
            };
            let result = match reader.summary_facts(&request.query, &request_budget) {
                Ok(facts) => {
                    serde_json::json!({"id":request.id,"fixture":fixture.id,"facts":facts})
                }
                Err(error) => {
                    serde_json::json!({"id":request.id,"fixture":fixture.id,"error":error})
                }
            };
            records.push(result);
        }
        // Each reader must remain usable after the expected failed requests.
        reader.summary_facts(
            &TraceSummaryQuery {
                range: None,
                maximum_rows_per_section: 100_000,
                maximum_events_per_section: 100_000,
            },
            &budget,
        )?;
        reader.close()?;
        building.cleanup(&io)?;
        let after = source.facts(&io)?;
        if before != after {
            return Err("frozen source changed".into());
        }
        sources.push(serde_json::json!({"fixture":fixture.id,
            "before":{"sha256":before.sha256,"byteCount":before.byte_count},
            "after":{"sha256":after.sha256,"byteCount":after.byte_count},
            "inspection":original,"indexedCopyCleaned":true,"postErrorQueryPassed":true}));
    }
    println!(
        "{}",
        serde_json::json!({"version":1,"nativeMacOS":true,"records":records,"sources":sources,"appAcceptance":false})
    );
    Ok(())
}
#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("native macOS required; no simulated acceptance");
    std::process::exit(2);
}
