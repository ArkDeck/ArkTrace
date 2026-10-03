fn main() {
    let (host, duration_ns) = arktrace_engine::contract_smoke().expect("time contract smoke");
    assert!(host.is_some(), "unsupported product host");
    assert_eq!(duration_ns, 1);
    println!("ArkTrace migration workspace smoke: {host:?}");
}
