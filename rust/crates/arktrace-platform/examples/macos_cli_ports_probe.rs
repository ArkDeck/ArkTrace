#[cfg(target_os = "macos")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use arktrace_platform::{
        CancellationToken, IoBudget, MappedExecutable, OwnerKind, OwnerStore,
        user_temporary_workspace,
    };
    use std::time::{Duration, Instant};
    let budget = IoBudget {
        maximum_bytes: 256 * 1024 * 1024,
        deadline: Instant::now() + Duration::from_secs(5),
        cancellation: CancellationToken::default(),
    };
    let image = MappedExecutable::current()?;
    let facts = image.facts(&budget)?;
    println!("mapped image: {}", facts.sha256);
    let root = user_temporary_workspace("com.arktrace.ArkTrace.rust-tools")?;
    println!("OS temporary root held");
    let staging = root.ensure_private_child(".tool-staging")?;
    println!("tool staging held");
    let owners = OwnerStore::open(&staging, &root)?;
    println!("owner store held");
    let mut owner = owners.create(OwnerKind::Session, &budget)?;
    println!("owner created");
    owner.cleanup(&budget)?;
    println!("owner removed");
    Ok(())
}
#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("native macOS required");
    std::process::exit(1)
}
