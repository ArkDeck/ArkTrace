fn main() {
    #[cfg(target_os = "macos")]
    std::process::exit(arktrace_platform::supervisor_main());
    #[cfg(not(target_os = "macos"))]
    {
        eprintln!("native macOS supervisor; Windows uses Job Objects");
        std::process::exit(1);
    }
}
