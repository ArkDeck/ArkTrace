use arktrace_counter_reveal_compat::{Case, all_observations};
use std::{env, fs};
fn main() {
    let args = env::args().collect::<Vec<_>>();
    assert_eq!(args.len(), 3);
    let cases: Vec<Case> = serde_json::from_slice(&fs::read(&args[1]).unwrap()).unwrap();
    let swift: Vec<serde_json::Value> =
        serde_json::from_slice(&fs::read(&args[2]).unwrap()).unwrap();
    println!(
        "{}",
        serde_json::to_string_pretty(&all_observations(&cases, &swift)).unwrap()
    );
}
