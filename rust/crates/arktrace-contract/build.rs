use std::{env, fs, path::PathBuf};

fn main() {
    let source =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../contracts/quality-scopes.json");
    println!("cargo:rerun-if-changed={}", source.display());
    let scopes: Vec<String> = serde_json::from_slice(&fs::read(source).expect("quality scopes"))
        .expect("closed scope vocabulary");
    assert!(scopes.windows(2).all(|pair| pair[0] < pair[1]));
    fs::write(
        PathBuf::from(env::var_os("OUT_DIR").expect("OUT_DIR")).join("quality-scopes.rs"),
        format!("&{:?}", scopes),
    )
    .expect("generated scope vocabulary");
}
