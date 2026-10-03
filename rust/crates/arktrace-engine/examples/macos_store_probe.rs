#[cfg(target_os = "macos")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use arktrace_platform::{CancellationToken, HeldDirectory, IoBudget, OwnerKind, OwnerStore};
    use arktrace_store::{
        SQLITE_SOURCE_ID, SQLITE_VERSION, ValidationBudget, inspect_snapshot, prepare_snapshot,
        sqlite_runtime_facts,
    };
    use std::{
        path::PathBuf,
        time::{Duration, Instant},
    };
    let args = std::env::args_os().skip(1).collect::<Vec<_>>();
    if args.len() != 1 {
        return Err("expected owned probe root".into());
    }
    let root = PathBuf::from(&args[0]);
    let runtime = sqlite_runtime_facts(&ValidationBudget {
        maximum_database_bytes: 256 * 1024 * 1024,
        deadline: Instant::now() + Duration::from_secs(5),
        cancellation: CancellationToken::default(),
    })?;
    let mut results = Vec::new();
    let held_root = HeldDirectory::open_private(&root)?;
    let owners = OwnerStore::open(
        &HeldDirectory::open_private(&root.join("stage"))?,
        &held_root,
    )?;
    for index in 0..3 {
        let directory =
            HeldDirectory::open_private(&root.join("published").join(format!("case-{index}")))?;
        let source = directory.open_file("trace.db")?;
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
        let inspection = inspect_snapshot(&source, &budget)?;
        let mut building = owners.create(OwnerKind::Building, &io)?;
        let mut progress = Vec::new();
        let prepared = prepare_snapshot(
            &source,
            building.directory(),
            "indexed.db",
            &budget,
            |event| progress.push(event),
        )?;
        let reopened = inspect_snapshot(&prepared.snapshot, &budget)?;
        if reopened != inspection || prepared.preparation.inspection != inspection {
            return Err("indexed semantic facts changed".into());
        }
        let prep = prepared.preparation.clone();
        let copy = root.join(format!("indexed-case-{index}.db"));
        // Development evidence: Engine hands a readonly copy to Python for
        // independent quick_check/index introspection before owned-root cleanup.
        held_root.copy_snapshot(
            &prepared.snapshot,
            copy.file_name()
                .and_then(|n| n.to_str())
                .ok_or("invalid probe name")?,
            false,
            &io,
        )?;
        drop(prepared);
        building.cleanup(&io)?;
        let after = source.facts(&io)?;
        if before != after {
            return Err("snapshot changed".into());
        }
        results.push(
            serde_json::json!({"caseIndex":index,"databaseSHA256":before.sha256,
            "databaseByteCount":before.byte_count,"inspection":inspection,"snapshotUnchanged":true,
            "preparation":prep,"indexProgress":progress,"preparedOwnerCleaned":true}),
        );
    }
    println!(
        "{}",
        serde_json::json!({"version":1,"readyAcceptance":false,"sqliteVersion":SQLITE_VERSION,
        "sqliteSourceID":SQLITE_SOURCE_ID,"sqliteRuntime":runtime,"results":results})
    );
    Ok(())
}
#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("native macOS required; no simulated acceptance");
    std::process::exit(2);
}
